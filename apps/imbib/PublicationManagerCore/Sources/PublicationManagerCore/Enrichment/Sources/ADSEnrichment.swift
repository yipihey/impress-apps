//
//  ADSEnrichment.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - ADS Enrichment Plugin

/// Extension to make ADSSource conform to EnrichmentPlugin.
///
/// ADS provides enrichment data including:
/// - Citation count
/// - Reference count and list (with full paper metadata)
/// - Citations list (with full paper metadata)
/// - Abstract
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

        // Get API key
        guard await credentialManager.apiKey(for: "ads") != nil else {
            throw EnrichmentError.authenticationRequired("ads")
        }

        // Resolve bibcode from identifiers
        let bibcodeQuery = try resolveBibcode(from: identifiers)

        // First, get basic info (citation count, abstract, reference count) and resolve actual bibcode
        let (basicInfo, resolvedBibcode) = try await fetchBasicInfo(bibcodeQuery: bibcodeQuery)

        // Fetch full references with paper metadata
        var references: [PaperStub]?
        if let refCount = basicInfo.referenceCount, refCount > 0 {
            do {
                references = try await fetchReferences(bibcode: resolvedBibcode, maxResults: 200)
            } catch {
                Logger.sources.warning("ADS: Failed to fetch references: \(error.localizedDescription)")
                // Continue without references rather than failing entirely
            }
        }

        // Fetch full citations with paper metadata
        var citations: [PaperStub]?
        if let citCount = basicInfo.citationCount, citCount > 0 {
            do {
                citations = try await fetchCitations(bibcode: resolvedBibcode, maxResults: 200)
            } catch {
                Logger.sources.warning("ADS: Failed to fetch citations: \(error.localizedDescription)")
                // Continue without citations rather than failing entirely
            }
        }

        // Build final enrichment data
        let enrichmentData = EnrichmentData(
            citationCount: basicInfo.citationCount,
            referenceCount: basicInfo.referenceCount,
            references: references,
            citations: citations,
            abstract: basicInfo.abstract,
            pdfLinks: basicInfo.pdfLinks,
            source: .ads
        )

        // Resolved identifiers include bibcode
        var resolvedIdentifiers = identifiers
        resolvedIdentifiers[.bibcode] = resolvedBibcode

        Logger.sources.info("ADS: enrichment complete - citations: \(enrichmentData.citationCount ?? 0), references: \(references?.count ?? 0), citing: \(citations?.count ?? 0)")

        // Merge with existing data
        let finalData: EnrichmentData
        if let existing = existingData {
            finalData = enrichmentData.merging(with: existing)
        } else {
            finalData = enrichmentData
        }

        return EnrichmentResult(
            data: finalData,
            resolvedIdentifiers: resolvedIdentifiers
        )
    }

    /// Basic info from initial enrichment query
    private struct BasicInfo {
        let citationCount: Int?
        let referenceCount: Int?
        let abstract: String?
        let pdfLinks: [PDFLink]?
    }

    /// Fetch basic enrichment info and resolve actual bibcode
    private func fetchBasicInfo(bibcodeQuery: String) async throws -> (BasicInfo, String) {
        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw EnrichmentError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        // Build the query - don't add bibcode: prefix if query already has a prefix
        let query: String
        if bibcodeQuery.hasPrefix("arXiv:") || bibcodeQuery.hasPrefix("doi:") {
            // Use identifier: for arXiv and doi lookups
            query = "identifier:\(bibcodeQuery)"
        } else {
            // Direct bibcode lookup
            query = "bibcode:\(bibcodeQuery)"
        }

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            // Include esources, doi, identifier for PDF link discovery
            URLQueryItem(name: "fl", value: "bibcode,citation_count,abstract,[citations],reference,esources,doi,identifier"),
            URLQueryItem(name: "rows", value: "1"),
        ]

        guard let url = components.url else {
            throw EnrichmentError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnrichmentError.networkError("Invalid response")
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw EnrichmentError.authenticationRequired("ads")
        case 404:
            throw EnrichmentError.notFound
        case 429:
            throw EnrichmentError.rateLimited(retryAfter: nil)
        default:
            throw EnrichmentError.networkError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseObj = json["response"] as? [String: Any],
              let docs = responseObj["docs"] as? [[String: Any]] else {
            throw EnrichmentError.parseError("Invalid ADS response")
        }

        let numFound = responseObj["numFound"] as? Int ?? 0
        if numFound == 0 {
            throw EnrichmentError.notFound
        }

        guard let doc = docs.first,
              let resolvedBibcode = doc["bibcode"] as? String else {
            throw EnrichmentError.parseError("No bibcode in response")
        }

        let citationCount = doc["citation_count"] as? Int
        let referenceCount = (doc["reference"] as? [String])?.count
        let abstract = doc["abstract"] as? String

        // Build PDF links from esources
        let esources = doc["esources"] as? [String] ?? []
        let doi = (doc["doi"] as? [String])?.first
        let identifiers = doc["identifier"] as? [String]
        // Extract arXiv ID and validate it's actually an arXiv ID format (not a DOI or bibcode)
        let rawArxivID = identifiers?.first { $0.hasPrefix("arXiv:") }?.replacingOccurrences(of: "arXiv:", with: "")
        let arxivID = rawArxivID.flatMap { IdentifierExtractor.isValidArXivIDFormat($0) ? $0 : nil }

        let pdfLinks = ADSSource.buildPDFLinks(
            esources: esources,
            doi: doi,
            arxivID: arxivID,
            bibcode: resolvedBibcode
        )

        return (BasicInfo(
            citationCount: citationCount,
            referenceCount: referenceCount,
            abstract: abstract,
            pdfLinks: pdfLinks.isEmpty ? nil : pdfLinks
        ), resolvedBibcode)
    }

    // MARK: - Identifier Resolution

    public func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String] {
        // If we already have a bibcode, return as-is
        if identifiers[.bibcode] != nil {
            return identifiers
        }

        // ADS can resolve DOI to bibcode via search
        if let doi = identifiers[.doi] {
            var result = identifiers
            // DOI search in ADS uses doi: prefix
            result[.bibcode] = "doi:\(doi)"
            return result
        }

        // arXiv ID can also be resolved
        if let arxiv = identifiers[.arxiv] {
            var result = identifiers
            result[.bibcode] = "arXiv:\(arxiv)"
            return result
        }

        return identifiers
    }

    // MARK: - Batch Enrichment

    /// Batch size for ADS enrichment queries.
    /// ADS has URL length limits, so we chunk requests into smaller batches.
    private static let batchSize = 50

    /// Batch enrich multiple papers using ADS OR-query syntax.
    ///
    /// This is much more efficient than individual calls:
    /// - Chunks requests into batches of 50 papers
    /// - Single API call per batch (vs 50 individual calls)
    /// - Returns basic enrichment data (citation count, reference count, abstract)
    /// - Does NOT fetch full references/citations lists (too expensive for batch)
    public func enrichBatch(
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>] {
        guard !requests.isEmpty else { return [:] }

        Logger.sources.info("ADS: batch enriching \(requests.count) papers in chunks of \(Self.batchSize)")

        // Check API key
        guard await credentialManager.apiKey(for: "ads") != nil else {
            // Return auth error for all requests
            return Dictionary(uniqueKeysWithValues: requests.map {
                ($0.publicationID, .failure(EnrichmentError.authenticationRequired("ads")))
            })
        }

        // Build mapping from bibcode query to publication ID
        var queryToPubID: [String: UUID] = [:]
        var validRequests: [(publicationID: UUID, bibcodeQuery: String)] = []

        for request in requests {
            if let bibcodeQuery = try? resolveBibcode(from: request.identifiers) {
                queryToPubID[bibcodeQuery] = request.publicationID
                validRequests.append((request.publicationID, bibcodeQuery))
            }
        }

        guard !validRequests.isEmpty else {
            // No valid identifiers, return errors for all
            return Dictionary(uniqueKeysWithValues: requests.map {
                ($0.publicationID, .failure(EnrichmentError.noIdentifier))
            })
        }

        var allResults: [UUID: Result<EnrichmentResult, Error>] = [:]

        // Process in chunks to avoid URL length limits and ADS query limits
        for chunkStart in stride(from: 0, to: validRequests.count, by: Self.batchSize) {
            let chunkEnd = min(chunkStart + Self.batchSize, validRequests.count)
            let chunk = Array(validRequests[chunkStart..<chunkEnd])
            let queryTerms = chunk.map { $0.bibcodeQuery }

            // Build OR query: identifier:(term1 OR term2 OR term3)
            let query = "identifier:(" + queryTerms.joined(separator: " OR ") + ")"

            do {
                let batchResults = try await fetchBasicInfoBatch(query: query, maxRows: chunk.count)

                // Map results back to publication IDs
                for (bibcode, info) in batchResults {
                    // Find the publication ID for this bibcode
                    if let pubID = findPublicationID(bibcode: bibcode, queryToPubID: queryToPubID, requests: requests) {
                        let enrichmentData = EnrichmentData(
                            citationCount: info.citationCount,
                            referenceCount: info.referenceCount,
                            references: nil,  // Not fetched in batch mode
                            citations: nil,   // Not fetched in batch mode
                            abstract: info.abstract,
                            pdfLinks: info.pdfLinks,
                            source: .ads
                        )

                        var resolvedIdentifiers: [IdentifierType: String] = [:]
                        resolvedIdentifiers[.bibcode] = bibcode

                        allResults[pubID] = .success(EnrichmentResult(
                            data: enrichmentData,
                            resolvedIdentifiers: resolvedIdentifiers
                        ))
                    }
                }

                Logger.sources.debug("ADS: chunk \(chunkStart/Self.batchSize + 1) complete - \(batchResults.count)/\(chunk.count) found")

            } catch {
                Logger.sources.error("ADS: chunk enrichment failed: \(error.localizedDescription)")
                // Mark this chunk's papers as failures
                for request in chunk {
                    allResults[request.publicationID] = .failure(error)
                }
            }
        }

        // Mark papers not found in results as failures
        for request in requests {
            if allResults[request.publicationID] == nil {
                allResults[request.publicationID] = .failure(EnrichmentError.notFound)
            }
        }

        let successCount = allResults.values.filter { if case .success = $0 { return true } else { return false } }.count
        Logger.sources.info("ADS: batch enrichment complete - \(successCount)/\(requests.count) found")
        return allResults
    }

    /// Fetch basic info for multiple papers in one API call
    private func fetchBasicInfoBatch(
        query: String,
        maxRows: Int
    ) async throws -> [String: BasicInfo] {
        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw EnrichmentError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            // Include esources for PDF link discovery
            URLQueryItem(name: "fl", value: "bibcode,citation_count,abstract,reference,doi,identifier,esources"),
            URLQueryItem(name: "rows", value: "\(maxRows)"),
        ]

        guard let url = components.url else {
            throw EnrichmentError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnrichmentError.networkError("Invalid response")
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw EnrichmentError.authenticationRequired("ads")
        case 429:
            throw EnrichmentError.rateLimited(retryAfter: nil)
        default:
            throw EnrichmentError.networkError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseObj = json["response"] as? [String: Any],
              let docs = responseObj["docs"] as? [[String: Any]] else {
            throw EnrichmentError.parseError("Invalid ADS response")
        }

        var results: [String: BasicInfo] = [:]

        for doc in docs {
            guard let bibcode = doc["bibcode"] as? String else { continue }

            let citationCount = doc["citation_count"] as? Int
            let referenceCount = (doc["reference"] as? [String])?.count
            let abstract = doc["abstract"] as? String

            // Build PDF links from esources
            let esources = doc["esources"] as? [String] ?? []
            let doi = (doc["doi"] as? [String])?.first
            let identifiers = doc["identifier"] as? [String]
            // Extract arXiv ID and validate it's actually an arXiv ID format (not a DOI or bibcode)
            let rawArxivID = identifiers?.first { $0.hasPrefix("arXiv:") }?.replacingOccurrences(of: "arXiv:", with: "")
            let arxivID = rawArxivID.flatMap { IdentifierExtractor.isValidArXivIDFormat($0) ? $0 : nil }

            let pdfLinks = ADSSource.buildPDFLinks(
                esources: esources,
                doi: doi,
                arxivID: arxivID,
                bibcode: bibcode
            )

            results[bibcode] = BasicInfo(
                citationCount: citationCount,
                referenceCount: referenceCount,
                abstract: abstract,
                pdfLinks: pdfLinks.isEmpty ? nil : pdfLinks
            )
        }

        return results
    }

    /// Find publication ID for a bibcode, checking both direct match and identifier matches
    private func findPublicationID(
        bibcode: String,
        queryToPubID: [String: UUID],
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) -> UUID? {
        // Direct match
        if let pubID = queryToPubID[bibcode] {
            return pubID
        }

        // Check if any request has a matching identifier
        for request in requests {
            if request.identifiers[.bibcode] == bibcode {
                return request.publicationID
            }
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Resolve bibcode from identifiers
    private func resolveBibcode(from identifiers: [IdentifierType: String]) throws -> String {
        // Direct bibcode
        if let bibcode = identifiers[.bibcode] {
            return bibcode
        }

        // DOI search
        if let doi = identifiers[.doi] {
            return "doi:\"\(doi)\""
        }

        // arXiv search - strip version suffix (e.g., "2511.08706v1" → "2511.08706")
        if let arxiv = identifiers[.arxiv] {
            let strippedArxiv = stripArxivVersion(arxiv)
            return "arXiv:\(strippedArxiv)"
        }

        throw EnrichmentError.noIdentifier
    }

    /// Strip version suffix from arXiv ID (e.g., "2511.08706v1" → "2511.08706")
    private func stripArxivVersion(_ arxivID: String) -> String {
        // Match pattern: digits followed by v and more digits at the end
        if let range = arxivID.range(of: #"v\d+$"#, options: .regularExpression) {
            return String(arxivID[..<range.lowerBound])
        }
        return arxivID
    }

}
