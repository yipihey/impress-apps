//
//  ADSSource.swift
//  PublicationManagerCore
//
//  NASA ADS source plugin — powered by scix-client-ffi (Rust).
//  All HTTP and parsing is handled by the scix-client Rust crate;
//  this actor is a thin async wrapper with credential lookup.
//

import Foundation
import ImpressScixCore
import OSLog

// MARK: - NASA ADS Source

/// Source plugin for NASA ADS (Astrophysics Data System).
/// Requires API key from https://ui.adsabs.harvard.edu/user/settings/token
public actor ADSSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "ads",
        name: "NASA ADS",
        description: "Astrophysics Data System - astronomy, physics, and space sciences",
        rateLimit: RateLimit(requestsPerInterval: 5, intervalSeconds: 1),
        credentialRequirement: .apiKey,
        registrationURL: URL(string: "https://ui.adsabs.harvard.edu/user/settings/token"),
        deduplicationPriority: 30,
        iconName: "sparkles"
    )

    let credentialManager: any CredentialProviding

    // MARK: - Initialization

    public init(credentialManager: any CredentialProviding = CredentialManager()) {
        self.credentialManager = credentialManager
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixSearch(token: apiKey, query: query, maxResults: UInt32(maxResults))
            }.value
            Logger.sources.info("ADS: search returned \(papers.count) results")
            return papers.map { $0.toSearchResult(sourceID: "ads") }
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        guard let bibcode = result.bibcode else {
            throw SourceError.notFound("No bibcode")
        }

        return try await fetchBibTeX(bibcode: bibcode, apiKey: apiKey)
    }

    /// Fetch BibTeX for a paper by its ADS bibcode (for import from citation explorer).
    public func fetchBibTeX(bibcode: String) async throws -> BibTeXEntry {
        Logger.sources.info("ADS: Fetching BibTeX for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        return try await fetchBibTeX(bibcode: bibcode, apiKey: apiKey)
    }

    private func fetchBibTeX(bibcode: String, apiKey: String) async throws -> BibTeXEntry {
        do {
            let bibtexString = try await Task.detached(priority: .userInitiated) {
                try scixExportBibtex(token: apiKey, bibcodes: [bibcode])
            }.value

            let parser = BibTeXParserFactory.createParser()
            let entries = try parser.parseEntries(bibtexString)

            guard let entry = entries.first else {
                throw SourceError.parseError("No entry in BibTeX response")
            }

            return entry
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }

    public nonisolated var supportsRIS: Bool { true }

    public func fetchRIS(for result: SearchResult) async throws -> RISEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        guard let bibcode = result.bibcode else {
            throw SourceError.notFound("No bibcode")
        }

        do {
            let risString = try await Task.detached(priority: .userInitiated) {
                try scixExportRis(token: apiKey, bibcodes: [bibcode])
            }.value

            let parser = RISParserFactory.createParser()
            let entries = try parser.parse(risString)

            guard let entry = entries.first else {
                throw SourceError.parseError("No entry in RIS response")
            }

            return entry
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var fields = entry.fields

        if let bibcode = fields["bibcode"], fields["adsurl"] == nil {
            fields["adsurl"] = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }

    // MARK: - References & Citations

    /// Fetch papers that this paper references (papers it cites).
    public func fetchReferences(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching references for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixFetchReferences(token: apiKey, bibcode: bibcode, maxResults: UInt32(maxResults))
            }.value
            let stubs = papers.map { $0.toPaperStub() }
            Logger.sources.info("ADS: Found \(stubs.count) references for \(bibcode)")
            return stubs
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }

    /// Fetch papers that cite this paper.
    public func fetchCitations(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching citations for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixFetchCitations(token: apiKey, bibcode: bibcode, maxResults: UInt32(maxResults))
            }.value
            let stubs = papers.map { $0.toPaperStub() }
            Logger.sources.info("ADS: Found \(stubs.count) citations for \(bibcode)")
            return stubs
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }

    /// Fetch papers similar to this one by content.
    public func fetchSimilar(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching similar papers for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixFetchSimilar(token: apiKey, bibcode: bibcode, maxResults: UInt32(maxResults))
            }.value
            let stubs = papers.map { $0.toPaperStub() }
            Logger.sources.info("ADS: Found \(stubs.count) similar papers for \(bibcode)")
            return stubs
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }

    /// Fetch papers frequently co-read with this one.
    public func fetchCoReads(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching co-reads for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixFetchCoreads(token: apiKey, bibcode: bibcode, maxResults: UInt32(maxResults))
            }.value
            let stubs = papers.map { $0.toPaperStub() }
            Logger.sources.info("ADS: Found \(stubs.count) co-reads for \(bibcode)")
            return stubs
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "ads")
        }
    }
}

// MARK: - BrowserURLProvider Conformance

extension ADSSource: BrowserURLProvider {

    public static var sourceID: String { "ads" }

    /// Build the best URL to open in browser for interactive PDF fetch.
    ///
    /// Priority: DOI resolver → ADS abstract page → arXiv PDF.
    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("ADS: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }

        if let bibcode = publication.bibcode {
            Logger.pdfBrowser.debug("ADS: Using abstract page for bibcode: \(bibcode)")
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/abstract")
        }

        if let arxivID = publication.arxivID, !arxivID.isEmpty {
            Logger.pdfBrowser.debug("ADS: Using arXiv PDF for: \(arxivID)")
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }

        return nil
    }
}
