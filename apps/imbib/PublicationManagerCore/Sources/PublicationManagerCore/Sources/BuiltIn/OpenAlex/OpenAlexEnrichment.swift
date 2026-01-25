//
//  OpenAlexEnrichment.swift
//  PublicationManagerCore
//
//  Enrichment plugin extension for OpenAlex.
//

import Foundation
import OSLog

// MARK: - OpenAlex Enrichment Extension

extension OpenAlexSource: EnrichmentPlugin {

    public nonisolated var enrichmentCapabilities: EnrichmentCapabilities {
        [.citationCount, .references, .citations, .abstract, .pdfURL, .openAccess, .venue]
    }

    public func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult {
        Logger.enrichment.info("OpenAlex: Enriching with identifiers: \(identifiers.keys.map(\.rawValue))")

        // Try to find the work using available identifiers
        let work = try await resolveWork(from: identifiers)

        // Build enrichment data from the work
        let data = buildEnrichmentData(from: work)

        // Resolve additional identifiers from the work
        var resolvedIdentifiers = identifiers
        if let openAlexID = extractOpenAlexID(from: work) {
            resolvedIdentifiers[.openAlex] = openAlexID
        }
        if let doi = OpenAlexResponseParser.cleanDOI(work.doi) {
            resolvedIdentifiers[.doi] = doi
        }
        if let pmid = OpenAlexResponseParser.cleanPMID(work.ids?.pmid) {
            resolvedIdentifiers[.pmid] = pmid
        }

        return EnrichmentResult(data: data, resolvedIdentifiers: resolvedIdentifiers)
    }

    public func enrichBatch(
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>] {
        Logger.enrichment.info("OpenAlex: Batch enriching \(requests.count) publications")

        // Group requests by identifier type for efficient batch lookup
        var results: [UUID: Result<EnrichmentResult, Error>] = [:]

        // Collect DOIs for batch lookup
        var doiRequests: [(UUID, String, [IdentifierType: String])] = []
        var otherRequests: [(UUID, [IdentifierType: String])] = []

        for request in requests {
            if let doi = request.identifiers[.doi] {
                doiRequests.append((request.publicationID, doi, request.identifiers))
            } else {
                otherRequests.append((request.publicationID, request.identifiers))
            }
        }

        // Batch fetch by DOI (up to 50 at a time)
        if !doiRequests.isEmpty {
            let batchResults = await batchEnrichByDOI(doiRequests)
            for (id, result) in batchResults {
                results[id] = result
            }
        }

        // Process other requests individually
        for (pubID, identifiers) in otherRequests {
            do {
                let result = try await enrich(identifiers: identifiers, existingData: nil)
                results[pubID] = .success(result)
            } catch {
                results[pubID] = .failure(error)
            }
        }

        return results
    }

    public func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String] {
        let work = try await resolveWork(from: identifiers)

        var resolved = identifiers
        if let openAlexID = extractOpenAlexID(from: work) {
            resolved[.openAlex] = openAlexID
        }
        if let doi = OpenAlexResponseParser.cleanDOI(work.doi) {
            resolved[.doi] = doi
        }
        if let pmid = OpenAlexResponseParser.cleanPMID(work.ids?.pmid) {
            resolved[.pmid] = pmid
        }

        return resolved
    }

    // MARK: - Private Helpers

    private func resolveWork(from identifiers: [IdentifierType: String]) async throws -> OpenAlexWork {
        // Priority order: OpenAlex ID > DOI > PMID

        if let openAlexID = identifiers[.openAlex] {
            return try await fetchWork(id: openAlexID)
        }

        if let doi = identifiers[.doi] {
            return try await fetchWorkByDOI(doi)
        }

        if let pmid = identifiers[.pmid] {
            // Search by PMID filter
            await rateLimiter.waitIfNeeded()

            let cleanPMID = pmid.hasPrefix("https://") ? String(pmid.dropFirst(32)) : pmid

            var components = URLComponents(string: "\(baseURL)/works")!
            components.queryItems = [
                URLQueryItem(name: "filter", value: "ids.pmid:\(cleanPMID)"),
                URLQueryItem(name: "per-page", value: "1"),
            ]

            if let email = await credentialManager.email(for: "openalex") {
                components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
            }

            guard let url = components.url else {
                throw EnrichmentError.noIdentifier
            }

            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw EnrichmentError.notFound
            }

            let decoder = JSONDecoder()
            let searchResponse = try decoder.decode(OpenAlexSearchResponse.self, from: data)

            guard let work = searchResponse.results.first else {
                throw EnrichmentError.notFound
            }

            return work
        }

        throw EnrichmentError.noIdentifier
    }

    private func buildEnrichmentData(from work: OpenAlexWork) -> EnrichmentData {
        // Build PDF links
        let pdfLinks = OpenAlexResponseParser.buildPDFLinks(from: work)

        // Determine OA status
        let oaStatus: OpenAccessStatus?
        if let status = work.openAccess?.oaStatus {
            oaStatus = status.enrichmentStatus
        } else if work.openAccess?.isOa == true {
            oaStatus = .green  // Assume green if OA but no specific status
        } else {
            oaStatus = .closed
        }

        return EnrichmentData(
            citationCount: work.citedByCount,
            referenceCount: work.referencedWorksCount,
            references: nil,  // Would need separate fetch
            citations: nil,   // Would need separate fetch
            abstract: OpenAlexResponseParser.decodeInvertedIndexAbstract(work.abstractInvertedIndex),
            pdfURLs: pdfLinks.map(\.url),
            pdfLinks: pdfLinks,
            openAccessStatus: oaStatus,
            venue: work.primaryLocation?.source?.displayName,
            authorStats: nil,  // Would need separate author fetch
            source: .openalex,
            fetchedAt: Date()
        )
    }

    private func batchEnrichByDOI(
        _ requests: [(UUID, String, [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>] {
        var results: [UUID: Result<EnrichmentResult, Error>] = [:]

        // Process in batches of 50
        let batchSize = 50
        for chunk in stride(from: 0, to: requests.count, by: batchSize) {
            let endIndex = min(chunk + batchSize, requests.count)
            let batch = Array(requests[chunk..<endIndex])

            // Build filter with multiple DOIs
            let doiFilter = batch.map { "doi:\($0.1)" }.joined(separator: "|")

            await rateLimiter.waitIfNeeded()

            var components = URLComponents(string: "\(baseURL)/works")!
            components.queryItems = [
                URLQueryItem(name: "filter", value: doiFilter),
                URLQueryItem(name: "per-page", value: "\(batch.count)"),
            ]

            if let email = await credentialManager.email(for: "openalex") {
                components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
            }

            guard let url = components.url else {
                // Mark all as failed
                for (pubID, _, _) in batch {
                    results[pubID] = .failure(EnrichmentError.noIdentifier)
                }
                continue
            }

            do {
                let (data, response) = try await session.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    for (pubID, _, _) in batch {
                        results[pubID] = .failure(EnrichmentError.networkError("HTTP error"))
                    }
                    continue
                }

                let decoder = JSONDecoder()
                let searchResponse = try decoder.decode(OpenAlexSearchResponse.self, from: data)

                // Build DOI to work mapping
                var doiToWork: [String: OpenAlexWork] = [:]
                for work in searchResponse.results {
                    if let doi = OpenAlexResponseParser.cleanDOI(work.doi)?.lowercased() {
                        doiToWork[doi] = work
                    }
                }

                // Match results to requests
                for (pubID, doi, identifiers) in batch {
                    if let work = doiToWork[doi.lowercased()] {
                        let enrichmentData = buildEnrichmentData(from: work)
                        var resolvedIdentifiers = identifiers
                        if let openAlexID = extractOpenAlexID(from: work) {
                            resolvedIdentifiers[.openAlex] = openAlexID
                        }
                        results[pubID] = .success(EnrichmentResult(
                            data: enrichmentData,
                            resolvedIdentifiers: resolvedIdentifiers
                        ))
                    } else {
                        results[pubID] = .failure(EnrichmentError.notFound)
                    }
                }

            } catch {
                for (pubID, _, _) in batch {
                    results[pubID] = .failure(error)
                }
            }
        }

        return results
    }

    private func extractOpenAlexID(from work: OpenAlexWork) -> String? {
        let id = OpenAlexResponseParser.extractOpenAlexID(from: work.id)
        return id.isEmpty ? nil : id
    }
}
