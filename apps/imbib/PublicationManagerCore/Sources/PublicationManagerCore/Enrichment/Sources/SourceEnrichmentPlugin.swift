//
//  SourceEnrichmentPlugin.swift
//  PublicationManagerCore
//
//  The enrichment plugin over the Rust source verbs (source convention S6).
//  It replaces `ADSSource: EnrichmentPlugin`, which drove scix-client-ffi's
//  ADS calls from Swift: a paper's citation count, abstract, PDF links and
//  resolved identifiers are one `bib-source-service_fetch` (or, for a batch,
//  one `imbib-sources-service_search-sources` with an ADS `identifier:(…)`
//  query); its references and citations are `bib-source-service_related`
//  (`cites`, `cited_by`). Nothing here reads a credential: the adapter does,
//  from the secret `SourceSecrets.push` handed to Rust.
//

import Foundation
import OSLog

/// Enrichment through one online source's verbs — ADS by default.
public actor SourceEnrichmentPlugin: EnrichmentPlugin {

    public nonisolated let metadata: SourceMetadata
    private let sourceID: String
    private let client: SourceClient

    public init(sourceID: String = "ads", client: SourceClient = SourceClient()) {
        self.sourceID = sourceID
        self.client = client
        self.metadata = SourceMetadata(
            id: sourceID,
            name: SourceMetadata.displayName(for: sourceID),
            description: "Enrichment through the \(SourceMetadata.displayName(for: sourceID)) adapter",
            credentialRequirement: sourceID == "ads" || sourceID == "scix" ? .apiKey : .none
        )
    }

    // MARK: - Capabilities

    public nonisolated var enrichmentCapabilities: EnrichmentCapabilities {
        [.citationCount, .references, .citations, .abstract]
    }

    // MARK: - Enrichment

    public func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult {
        let id = try Self.canonicalIdentifier(from: identifiers)
        Logger.sources.infoCapture("enrich requested: \(sourceID) \(id)", category: "sources")

        let work: SearchResult
        do {
            guard let fetched = try await client.fetchWork(id: id, sources: [sourceID]) else {
                throw EnrichmentError.notFound
            }
            work = fetched
        } catch let error as SourceError {
            throw Self.enrichmentError(error)
        }

        guard let bibcode = work.bibcode, !bibcode.isEmpty else {
            throw EnrichmentError.notFound
        }

        var references: [PaperStub]?
        do {
            references = try await client.related(id: "bibcode:\(bibcode)", relation: .cites, limit: 200)
        } catch {
            Logger.sources.warningCapture("enrich: references of \(bibcode) failed: \(error.localizedDescription)", category: "sources")
        }

        var citations: [PaperStub]?
        if let count = work.citationCount, count > 0 {
            do {
                citations = try await client.related(id: "bibcode:\(bibcode)", relation: .citedBy, limit: 200)
            } catch {
                Logger.sources.warningCapture("enrich: citations of \(bibcode) failed: \(error.localizedDescription)", category: "sources")
            }
        }

        let data = EnrichmentData(
            citationCount: work.citationCount,
            referenceCount: references?.count,
            references: references,
            citations: citations,
            abstract: work.abstract,
            pdfLinks: work.pdfLinks.isEmpty ? nil : work.pdfLinks,
            source: Self.enrichmentSource(sourceID)
        )

        var resolved = identifiers
        resolved[.bibcode] = bibcode
        if let arxiv = work.arxivID, resolved[.arxiv] == nil { resolved[.arxiv] = arxiv }
        if let doi = work.doi, resolved[.doi] == nil { resolved[.doi] = doi }

        Logger.sources.infoCapture(
            "enrich answered: \(bibcode) citations=\(work.citationCount ?? 0) references=\(references?.count ?? 0) citing=\(citations?.count ?? 0)",
            category: "sources"
        )
        let final = existingData.map { data.merging(with: $0) } ?? data
        return EnrichmentResult(data: final, resolvedIdentifiers: resolved)
    }

    // MARK: - Identifier Resolution

    public func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String] {
        if identifiers[.bibcode] != nil { return identifiers }
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

    /// One ADS `identifier:(a OR b …)` search per chunk of fifty, through
    /// the search verb: basic data (citation count, abstract, PDF links)
    /// for each paper; reference and citation lists are not fetched in
    /// batch mode.
    public func enrichBatch(
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>] {
        guard !requests.isEmpty else { return [:] }
        Logger.sources.infoCapture("enrich batch requested: \(requests.count) papers via \(sourceID) in chunks of \(Self.batchSize)", category: "sources")

        var termToPubID: [String: UUID] = [:]
        var valid: [(publicationID: UUID, term: String)] = []
        for request in requests {
            if let term = try? Self.adsQueryTerm(from: request.identifiers) {
                termToPubID[term] = request.publicationID
                valid.append((request.publicationID, term))
            }
        }
        guard !valid.isEmpty else {
            return Dictionary(uniqueKeysWithValues: requests.map { ($0.publicationID, .failure(EnrichmentError.noIdentifier)) })
        }

        var all: [UUID: Result<EnrichmentResult, Error>] = [:]
        for start in stride(from: 0, to: valid.count, by: Self.batchSize) {
            let chunk = Array(valid[start..<min(start + Self.batchSize, valid.count)])
            let query = "identifier:(" + chunk.map(\.term).joined(separator: " OR ") + ")"
            do {
                let rows = try await client.search(
                    query: query,
                    options: SearchOptions(maxResults: chunk.count, sourceIDs: [sourceID])
                )
                for row in rows {
                    guard let bibcode = row.bibcode,
                          let pubID = Self.publicationID(bibcode: bibcode, arxivID: row.arxivID, doi: row.doi, termToPubID: termToPubID, requests: requests)
                    else { continue }
                    let data = EnrichmentData(
                        citationCount: row.citationCount,
                        referenceCount: nil,
                        references: nil,
                        citations: nil,
                        abstract: row.abstract,
                        pdfLinks: row.pdfLinks.isEmpty ? nil : row.pdfLinks,
                        source: Self.enrichmentSource(sourceID)
                    )
                    var resolved: [IdentifierType: String] = [.bibcode: bibcode]
                    if let arxiv = row.arxivID { resolved[.arxiv] = arxiv }
                    if let doi = row.doi { resolved[.doi] = doi }
                    all[pubID] = .success(EnrichmentResult(data: data, resolvedIdentifiers: resolved))
                }
                Logger.sources.infoCapture("enrich batch: chunk \(start / Self.batchSize + 1): \(rows.count)/\(chunk.count) found", category: "sources")
            } catch let error as SourceError {
                let mapped = Self.enrichmentError(error)
                Logger.sources.errorCapture("enrich batch: chunk failed: \(mapped.localizedDescription)", category: "sources")
                for request in chunk { all[request.publicationID] = .failure(mapped) }
            } catch {
                Logger.sources.errorCapture("enrich batch: chunk failed: \(error.localizedDescription)", category: "sources")
                for request in chunk { all[request.publicationID] = .failure(error) }
            }
        }

        for request in requests where all[request.publicationID] == nil {
            all[request.publicationID] = .failure(EnrichmentError.notFound)
        }
        let found = all.values.filter { if case .success = $0 { return true } else { return false } }.count
        Logger.sources.infoCapture("enrich batch answered: \(found)/\(requests.count) found", category: "sources")
        return all
    }

    // MARK: - Helpers

    /// The canonical id `fetch` takes: bibcode, DOI, then arXiv.
    static func canonicalIdentifier(from identifiers: [IdentifierType: String]) throws -> String {
        if let bibcode = identifiers[.bibcode] {
            // A `resolveIdentifier` placeholder (`doi:…`, `arXiv:…`) is already canonical.
            return bibcode.contains(":") ? bibcode : "bibcode:\(bibcode)"
        }
        if let doi = identifiers[.doi] { return "doi:\(doi)" }
        if let arxiv = identifiers[.arxiv] { return "arxiv:\(stripArxivVersion(arxiv))" }
        throw EnrichmentError.noIdentifier
    }

    /// The ADS `identifier:` term for a batch search.
    static func adsQueryTerm(from identifiers: [IdentifierType: String]) throws -> String {
        if let bibcode = identifiers[.bibcode] { return bibcode }
        if let doi = identifiers[.doi] { return "doi:\"\(doi)\"" }
        if let arxiv = identifiers[.arxiv] { return "arXiv:\(stripArxivVersion(arxiv))" }
        throw EnrichmentError.noIdentifier
    }

    static func stripArxivVersion(_ arxivID: String) -> String {
        if let range = arxivID.range(of: #"v\d+$"#, options: .regularExpression) {
            return String(arxivID[..<range.lowerBound])
        }
        return arxivID
    }

    static func enrichmentSource(_ sourceID: String) -> EnrichmentSource {
        EnrichmentSource(rawValue: sourceID) ?? .ads
    }

    static func enrichmentError(_ error: SourceError) -> EnrichmentError {
        switch error {
        case .authenticationRequired(let source): return .authenticationRequired(source)
        case .unauthorized: return .authenticationRequired("ads")
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .notFound: return .notFound
        case .networkError(let underlying): return .networkError(underlying.localizedDescription)
        default: return .parseError(error.localizedDescription)
        }
    }

    static func publicationID(
        bibcode: String,
        arxivID: String?,
        doi: String?,
        termToPubID: [String: UUID],
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) -> UUID? {
        if let id = termToPubID[bibcode] { return id }
        if let arxivID {
            if let id = termToPubID["arXiv:\(arxivID)"] { return id }
            let stripped = stripArxivVersion(arxivID)
            if stripped != arxivID, let id = termToPubID["arXiv:\(stripped)"] { return id }
        }
        if let doi, let id = termToPubID["doi:\"\(doi)\""] { return id }
        for request in requests {
            if request.identifiers[.bibcode] == bibcode { return request.publicationID }
            if let arxivID, let reqArxiv = request.identifiers[.arxiv],
               stripArxivVersion(reqArxiv) == stripArxivVersion(arxivID) {
                return request.publicationID
            }
            if let doi, let reqDOI = request.identifiers[.doi], reqDOI.lowercased() == doi.lowercased() {
                return request.publicationID
            }
        }
        return nil
    }
}
