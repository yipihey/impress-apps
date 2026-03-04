//
//  SciXSource.swift
//  PublicationManagerCore
//
//  SciX source plugin — powered by scix-client-ffi (Rust).
//  SciX uses the same ADS API endpoint with SciX credentials.
//  Results display scixplorer.org URLs instead of ui.adsabs.harvard.edu.
//

import Foundation
import ImpressScixCore
import OSLog

// MARK: - SciX Source

/// Source plugin for SciX (Science Explorer).
/// SciX covers Earth science, planetary science, astrophysics, heliophysics,
/// and NASA-funded biological/physical sciences.
/// Requires API key from https://scixplorer.org/user/settings/token
public actor SciXSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "scix",
        name: "SciX",
        description: "Science Explorer - Earth, planetary, helio, and life sciences",
        rateLimit: RateLimit(requestsPerInterval: 5000, intervalSeconds: 86400),
        credentialRequirement: .apiKey,
        registrationURL: URL(string: "https://scixplorer.org/user/settings/token"),
        deduplicationPriority: 31,
        iconName: "globe"
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

        guard let apiKey = await credentialManager.apiKey(for: "scix") else {
            throw SourceError.authenticationRequired("scix")
        }

        do {
            let papers = try await Task.detached(priority: .userInitiated) {
                try scixSearch(token: apiKey, query: query, maxResults: UInt32(maxResults))
            }.value
            Logger.sources.info("SciX: search returned \(papers.count) results")
            return papers.map { $0.toSearchResult(sourceID: "scix") }
        } catch let error as ScixFfiError {
            throw error.toSourceError(sourceID: "scix")
        }
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "scix") else {
            throw SourceError.authenticationRequired("scix")
        }

        guard let bibcode = result.bibcode else {
            throw SourceError.notFound("No bibcode")
        }

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
            throw error.toSourceError(sourceID: "scix")
        }
    }

    public nonisolated var supportsRIS: Bool { true }

    public func fetchRIS(for result: SearchResult) async throws -> RISEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "scix") else {
            throw SourceError.authenticationRequired("scix")
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
            throw error.toSourceError(sourceID: "scix")
        }
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var fields = entry.fields

        if let bibcode = fields["bibcode"], fields["scixurl"] == nil {
            fields["scixurl"] = "https://scixplorer.org/abs/\(bibcode)"
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }
}

// MARK: - BrowserURLProvider Conformance

extension SciXSource: BrowserURLProvider {

    public static var sourceID: String { "scix" }

    /// Build the best URL to open in browser for interactive PDF fetch.
    ///
    /// Priority: DOI resolver → SciX abstract page.
    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("SciX: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }

        if let bibcode = publication.bibcode {
            Logger.pdfBrowser.debug("SciX: Using abstract page for bibcode: \(bibcode)")
            return URL(string: "https://scixplorer.org/abs/\(bibcode)/abstract")
        }

        return nil
    }
}
