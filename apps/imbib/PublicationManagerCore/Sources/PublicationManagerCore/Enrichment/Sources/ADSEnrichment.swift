//
//  ADSEnrichment.swift
//  PublicationManagerCore
//
//  ADS enrichment plugin — powered by scix-client-ffi (Rust).
//  Fetches citation counts, reference/citation lists, abstracts, and PDF links.
//

import Foundation
import ImpressScixCore
import OSLog

// MARK: - ADS Enrichment Plugin

/// Extension to make ADSSource conform to EnrichmentPlugin.
///
/// ADS provides enrichment data including:
/// - Citation count
/// - Reference list with full paper metadata
/// - Citations list with full paper metadata
/// - Abstract
/// - PDF links
extension ADSSource: EnrichmentPlugin {

    // MARK: - Capabilities

    public nonisolated var enrichmentCapabilities: EnrichmentCapabilities {
        [.citationCount, .references, .citations, .abstract]
    }

    // MARK: - Enrichment

    public func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult {
        Logger.sources.info("ADS: enriching paper with identifiers: \(identifiers)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw EnrichmentError.authenticationRequired("ads")
        }

        let bibcodeQuery = try resolveBibcode(from: identifiers)

        // Fetch basic info (citation count, abstract, PDF links, resolved bibcode)
        let (basicInfo, resolvedBibcode) = try await fetchBasicInfo(
            bibcodeQuery: bibcodeQuery,
            apiKey: apiKey
        )

        // Fetch references (gives us the reference list and reference count)
        var references: [PaperStub]?
        do {
            references = try await fetchReferences(bibcode: resolvedBibcode, maxResults: 200)
        } catch {
            Logger.sources.warning("ADS: Failed to fetch references: \(error.localizedDescription)")
        }

        // Fetch citations
        var citations: [PaperStub]?
        if let citCount = basicInfo.citationCount, citCount > 0 {
            do {
                citations = try await fetchCitations(bibcode: resolvedBibcode, maxResults: 200)
            } catch {
                Logger.sources.warning("ADS: Failed to fetch citations: \(error.localizedDescription)")
            }
        }

        let enrichmentData = EnrichmentData(
            citationCount: basicInfo.citationCount,
            referenceCount: references?.count,  // Derived from fetched list
            references: references,
            citations: citations,
            abstract: basicInfo.abstract,
            pdfLinks: basicInfo.pdfLinks,
            source: .ads
        )

        var resolvedIdentifiers = identifiers
        resolvedIdentifiers[.bibcode] = resolvedBibcode
        if let arxivID = basicInfo.arxivID, resolvedIdentifiers[.arxiv] == nil {
            resolvedIdentifiers[.arxiv] = arxivID
        }

        Logger.sources.info("ADS: enrichment complete - citations: \(enrichmentData.citationCount ?? 0), references: \(references?.count ?? 0), citing: \(citations?.count ?? 0)")

        let finalData = existingData.map { enrichmentData.merging(with: $0) } ?? enrichmentData

        return EnrichmentResult(
            data: finalData,
            resolvedIdentifiers: resolvedIdentifiers
        )
    }

    // MARK: - Private: Basic Info

    private struct BasicInfo {
        let citationCount: Int?
        let abstract: String?
        let pdfLinks: [PDFLink]?
        let arxivID: String?
    }

    /// Fetch citation count, abstract, and PDF links for a single paper.
    private func fetchBasicInfo(bibcodeQuery: String, apiKey: String) async throws -> (BasicInfo, String) {
        let query: String
        if bibcodeQuery.hasPrefix("arXiv:") || bibcodeQuery.hasPrefix("doi:") {
            query = "identifier:\(bibcodeQuery)"
        } else {
            query = "bibcode:\(bibcodeQuery)"
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixSearch(token: apiKey, query: query, maxResults: 1)
            }.value

            guard let paper = papers.first else {
                throw EnrichmentError.notFound
            }

            let pdfLinks = paper.toPdfLinks(sourceID: "ads")

            return (BasicInfo(
                citationCount: paper.citationCount.map { Int($0) },
                abstract: paper.abstractText,
                pdfLinks: pdfLinks.isEmpty ? nil : pdfLinks,
                arxivID: paper.arxivId
            ), paper.bibcode)
        } catch let error as ScixFfiError {
            throw error.toEnrichmentError(sourceID: "ads")
        }
    }

    // MARK: - Identifier Resolution

    public func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String] {
        if identifiers[.bibcode] != nil {
            return identifiers
        }
        if let doi = identifiers[.doi] {
            var result = identifiers
            result[.bibcode] = "doi:\(doi)"
            return result
        }
        if let arxiv = identifiers[.arxiv] {
            var result = identifiers
            result[.bibcode] = "arXiv:\(arxiv)"
            return result
        }
        return identifiers
    }

    // MARK: - Batch Enrichment

    private static let batchSize = 50

    /// Batch enrich multiple papers using ADS OR-query syntax.
    ///
    /// Returns basic enrichment data (citation count, abstract, PDF links) for each paper.
    /// Reference/citation lists are NOT fetched in batch mode — too expensive.
    public func enrichBatch(
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>] {
        guard !requests.isEmpty else { return [:] }

        Logger.sources.info("ADS: batch enriching \(requests.count) papers in chunks of \(Self.batchSize)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            return Dictionary(uniqueKeysWithValues: requests.map {
                ($0.publicationID, .failure(EnrichmentError.authenticationRequired("ads")))
            })
        }

        // Build mapping from bibcode query → publication ID
        var queryToPubID: [String: UUID] = [:]
        var validRequests: [(publicationID: UUID, bibcodeQuery: String)] = []

        for request in requests {
            if let bibcodeQuery = try? resolveBibcode(from: request.identifiers) {
                queryToPubID[bibcodeQuery] = request.publicationID
                validRequests.append((request.publicationID, bibcodeQuery))
            }
        }

        guard !validRequests.isEmpty else {
            return Dictionary(uniqueKeysWithValues: requests.map {
                ($0.publicationID, .failure(EnrichmentError.noIdentifier))
            })
        }

        var allResults: [UUID: Result<EnrichmentResult, Error>] = [:]

        for chunkStart in stride(from: 0, to: validRequests.count, by: Self.batchSize) {
            let chunkEnd = min(chunkStart + Self.batchSize, validRequests.count)
            let chunk = Array(validRequests[chunkStart..<chunkEnd])
            let queryTerms = chunk.map { $0.bibcodeQuery }

            // Build OR query: identifier:(term1 OR term2 OR term3)
            let query = "identifier:(" + queryTerms.joined(separator: " OR ") + ")"

            do {
                let papers = try await Task.detached(priority: .userInitiated) {
                    try scixSearch(token: apiKey, query: query, maxResults: UInt32(chunk.count))
                }.value

                for paper in papers {
                    if let pubID = findPublicationID(
                        bibcode: paper.bibcode,
                        arxivID: paper.arxivId,
                        queryToPubID: queryToPubID,
                        requests: requests
                    ) {
                        let pdfLinks = paper.toPdfLinks(sourceID: "ads")
                        let enrichmentData = EnrichmentData(
                            citationCount: paper.citationCount.map { Int($0) },
                            referenceCount: nil,  // Not fetched in batch mode
                            references: nil,
                            citations: nil,
                            abstract: paper.abstractText,
                            pdfLinks: pdfLinks.isEmpty ? nil : pdfLinks,
                            source: .ads
                        )

                        var resolvedIdentifiers: [IdentifierType: String] = [.bibcode: paper.bibcode]
                        if let arxivID = paper.arxivId {
                            resolvedIdentifiers[.arxiv] = arxivID
                        }

                        allResults[pubID] = .success(EnrichmentResult(
                            data: enrichmentData,
                            resolvedIdentifiers: resolvedIdentifiers
                        ))
                    }
                }

                Logger.sources.debug("ADS: chunk \(chunkStart / Self.batchSize + 1) complete - \(papers.count)/\(chunk.count) found")

            } catch let error as ScixFfiError {
                let enrichErr = error.toEnrichmentError(sourceID: "ads")
                Logger.sources.error("ADS: chunk enrichment failed: \(enrichErr.localizedDescription)")
                for request in chunk {
                    allResults[request.publicationID] = .failure(enrichErr)
                }
            } catch {
                Logger.sources.error("ADS: chunk enrichment failed: \(error.localizedDescription)")
                for request in chunk {
                    allResults[request.publicationID] = .failure(error)
                }
            }
        }

        // Mark papers not found as failures
        for request in requests {
            if allResults[request.publicationID] == nil {
                allResults[request.publicationID] = .failure(EnrichmentError.notFound)
            }
        }

        let successCount = allResults.values.filter {
            if case .success = $0 { return true } else { return false }
        }.count
        Logger.sources.info("ADS: batch enrichment complete - \(successCount)/\(requests.count) found")
        return allResults
    }

    // MARK: - Private Helpers

    private func resolveBibcode(from identifiers: [IdentifierType: String]) throws -> String {
        if let bibcode = identifiers[.bibcode] { return bibcode }
        if let doi = identifiers[.doi] { return "doi:\"\(doi)\"" }
        if let arxiv = identifiers[.arxiv] { return "arXiv:\(stripArxivVersion(arxiv))" }
        throw EnrichmentError.noIdentifier
    }

    private func stripArxivVersion(_ arxivID: String) -> String {
        if let range = arxivID.range(of: #"v\d+$"#, options: .regularExpression) {
            return String(arxivID[..<range.lowerBound])
        }
        return arxivID
    }

    private func findPublicationID(
        bibcode: String,
        arxivID: String?,
        queryToPubID: [String: UUID],
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) -> UUID? {
        if let pubID = queryToPubID[bibcode] { return pubID }

        if let arxivID {
            if let pubID = queryToPubID["arXiv:\(arxivID)"] { return pubID }
            let stripped = stripArxivVersion(arxivID)
            if stripped != arxivID, let pubID = queryToPubID["arXiv:\(stripped)"] { return pubID }
        }

        for request in requests {
            if request.identifiers[.bibcode] == bibcode { return request.publicationID }
            if let arxivID, let reqArxiv = request.identifiers[.arxiv],
               stripArxivVersion(reqArxiv) == stripArxivVersion(arxivID) {
                return request.publicationID
            }
        }

        return nil
    }
}
