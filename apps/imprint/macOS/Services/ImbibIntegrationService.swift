//
//  ImbibIntegrationService.swift
//  imprint
//
//  Facade for all imbib-side citation operations used by imprint.
//
//  Local lookups (by cite key / DOI / arXiv / bibcode) go through the shared
//  SQLite store via `ImprintPublicationService` — fast, offline, no HTTP. Any
//  operation that needs to reach imbib's in-process services (external search,
//  add-to-library, list libraries/collections, create library) goes through
//  `ImbibBridge` over HTTP on localhost:23120.
//
//  This replaces the legacy URL-scheme + pasteboard-polling search path, which
//  was flaky and silently swallowed errors.
//

import Foundation
import AppKit
import ImpressKit
import ImpressLogging
import OSLog

/// Central entry point for imbib operations from imprint.
@MainActor @Observable
public final class ImbibIntegrationService {

    // MARK: - Singleton

    public static let shared = ImbibIntegrationService()

    // MARK: - Published state

    /// Whether imbib is installed on the system (via NSWorkspace bundle lookup).
    public private(set) var isAvailable: Bool = false

    /// Filesystem path where imbib was found. `nil` if not installed.
    public private(set) var foundPath: String?

    /// Whether imbib's HTTP automation server is currently reachable. Refreshed
    /// by `checkAvailability()` and before each HTTP-dependent operation
    /// (with a short cache, so rapid sequential calls don't spam).
    public private(set) var isAutomationEnabled: Bool = false

    /// Last error observed on an HTTP-dependent operation. UI components can
    /// read this to render an actionable message.
    public private(set) var lastError: ImbibIntegrationError?

    // MARK: - Constants

    private let imbibBundleID = "com.impress.imbib"
    private let imbibURLScheme = "imbib"

    /// How long a successful ping is considered fresh. Keeps per-keystroke
    /// searches from hammering /api/status.
    private let pingFreshness: TimeInterval = 2.0
    private var lastPingAt: Date?

    // MARK: - Initialization

    private init() {
        Task {
            await checkAvailability()
        }
    }

    // MARK: - Availability

    /// Probe installation (synchronous NSWorkspace) + HTTP reachability.
    public func checkAvailability() async {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: imbibBundleID) {
            isAvailable = true
            foundPath = url.path
            Logger.imbibIntegration.infoCapture("imbib installed at \(url.path)", category: "imbib")
        } else {
            isAvailable = false
            foundPath = nil
            isAutomationEnabled = false
            Logger.imbibIntegration.infoCapture("imbib not installed", category: "imbib")
            return
        }
        await refreshHTTPAvailability(force: true)
    }

    /// Re-check whether imbib's HTTP server is reachable. The result is cached
    /// for `pingFreshness` seconds; pass `force: true` to bypass the cache.
    public func refreshHTTPAvailability(force: Bool = false) async {
        if !force, let t = lastPingAt, Date().timeIntervalSince(t) < pingFreshness {
            return
        }
        let up = await ImbibBridge.isAvailable()
        lastPingAt = Date()
        if up != isAutomationEnabled {
            Logger.imbibIntegration.infoCapture(
                "imbib HTTP automation \(up ? "came up" : "went down")",
                category: "imbib"
            )
        }
        isAutomationEnabled = up
    }

    /// Returns true when imbib's HTTP automation server responded within the
    /// last `pingFreshness` seconds, probing now if the cached status is stale.
    private func requireHTTP() async throws {
        await refreshHTTPAvailability()
        guard isAutomationEnabled else {
            throw ImbibIntegrationError.automationDisabled
        }
    }

    // MARK: - Search

    /// Search imbib's library for papers matching a query. Uses the local
    /// SQLite store when available (fast, no HTTP); falls back to HTTP when
    /// the store isn't open yet.
    public func searchPapers(query: String, maxResults: Int = 20) async throws -> [CitationResult] {
        guard isAvailable else { throw ImbibIntegrationError.notInstalled }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        Logger.imbibIntegration.infoCapture("Search: '\(trimmed)' (limit \(maxResults))", category: "citations")

        let pubs = ImprintPublicationService.shared
        if pubs.isReady {
            let rows = pubs.search(trimmed, limit: maxResults)
            let results = rows.map { row -> CitationResult in
                let year = row.year.map(Int.init) ?? 0
                let bib = pubs.detail(id: row.id)?.rawBibtex ?? ""
                return CitationResult(
                    id: UUID(uuidString: row.id) ?? UUID(),
                    citeKey: row.citeKey,
                    title: row.title,
                    authors: row.authorString,
                    year: year,
                    venue: row.venue ?? "",
                    formattedPreview: formatCitation(authors: row.authorString, year: year),
                    bibtex: bib,
                    hasPDF: row.hasDownloadedPdf
                )
            }
            Logger.imbibIntegration.infoCapture("Search returned \(results.count) local hits", category: "citations")
            return results
        }

        // HTTP fallback: shared store not open. Uses ImbibBridge.
        try await requireHTTP()
        do {
            let papers = try await ImbibBridge.searchLibrary(query: trimmed, limit: maxResults)
            let results = papers.map(Self.citationResult(from:))
            Logger.imbibIntegration.infoCapture("Search returned \(results.count) HTTP hits", category: "citations")
            return results
        } catch {
            let ie = mapBridgeError(error, fallback: .searchFailed(error.localizedDescription))
            lastError = ie
            Logger.imbibIntegration.warningCapture("HTTP search failed: \(error.localizedDescription)", category: "citations")
            throw ie
        }
    }

    /// Search external sources (ADS, arXiv, Crossref, …) via imbib.
    public func searchExternal(query: String, source: String? = nil, limit: Int = 10) async throws -> [ImbibExternalCandidate] {
        guard isAvailable else { throw ImbibIntegrationError.notInstalled }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try await requireHTTP()

        Logger.imbibIntegration.infoCapture("External search: '\(trimmed)' source=\(source ?? "all")", category: "citations")
        do {
            let results = try await ImbibBridge.searchExternal(query: trimmed, source: source, limit: limit)
            Logger.imbibIntegration.infoCapture("External search returned \(results.count) candidates", category: "citations")
            return results
        } catch {
            let ie = mapBridgeError(error, fallback: .searchFailed(error.localizedDescription))
            lastError = ie
            throw ie
        }
    }

    // MARK: - BibTeX

    /// Fetch BibTeX entries for the given cite keys. Reads from the shared
    /// store when available; falls back to HTTP.
    public func getBibTeX(forCiteKeys citeKeys: [String]) async throws -> String {
        guard isAvailable else { throw ImbibIntegrationError.notInstalled }
        guard !citeKeys.isEmpty else { return "" }

        Logger.imbibIntegration.infoCapture("getBibTeX for \(citeKeys.count) keys", category: "citations")

        let pubs = ImprintPublicationService.shared
        if pubs.isReady {
            var pieces: [String] = []
            var missing: [String] = []
            for key in citeKeys {
                if let row = pubs.findByCiteKey(key),
                   let detail = pubs.detail(id: row.id),
                   let bib = detail.rawBibtex, !bib.isEmpty {
                    pieces.append(bib)
                } else {
                    missing.append(key)
                }
            }
            if missing.isEmpty {
                return pieces.joined(separator: "\n\n")
            }
            Logger.imbibIntegration.infoCapture("getBibTeX: \(missing.count) keys missing in store, asking HTTP", category: "citations")
            // fall through to HTTP for the missing keys below; we still want
            // one combined string at the end.
            do {
                try await requireHTTP()
                let extra = try await ImbibBridge.exportBibTeX(citeKeys: missing)
                if extra.isEmpty { return pieces.joined(separator: "\n\n") }
                return (pieces + [extra]).joined(separator: "\n\n")
            } catch {
                // Partial result is still useful.
                Logger.imbibIntegration.warningCapture(
                    "getBibTeX HTTP fetch for missing keys failed: \(error.localizedDescription)",
                    category: "citations"
                )
                return pieces.joined(separator: "\n\n")
            }
        }

        try await requireHTTP()
        do {
            return try await ImbibBridge.exportBibTeX(citeKeys: citeKeys)
        } catch {
            let ie = mapBridgeError(error, fallback: .bibtexFetchFailed(error.localizedDescription))
            lastError = ie
            throw ie
        }
    }

    /// Fetch metadata for a single cite key. Returns `nil` when not found.
    /// Never throws for "not found" — only for infrastructure errors.
    public func getPaperMetadata(citeKey: String) async throws -> CitationResult? {
        guard isAvailable else { throw ImbibIntegrationError.notInstalled }

        let pubs = ImprintPublicationService.shared
        if pubs.isReady {
            guard let row = pubs.findByCiteKey(citeKey) else {
                Logger.imbibIntegration.debugCapture("getPaperMetadata: '\(citeKey)' not in store", category: "citations")
                return nil
            }
            let year = row.year.map(Int.init) ?? 0
            let bib = pubs.detail(id: row.id)?.rawBibtex ?? ""
            return CitationResult(
                id: UUID(uuidString: row.id) ?? UUID(),
                citeKey: row.citeKey,
                title: row.title,
                authors: row.authorString,
                year: year,
                venue: row.venue ?? "",
                formattedPreview: formatCitation(authors: row.authorString, year: year),
                bibtex: bib,
                hasPDF: row.hasDownloadedPdf
            )
        }

        try await requireHTTP()
        do {
            guard let paper = try await ImbibBridge.getPaper(citeKey: citeKey) else {
                return nil
            }
            return Self.citationResult(from: paper)
        } catch SiblingBridgeError.httpError(statusCode: 404) {
            return nil
        } catch {
            let ie = mapBridgeError(error, fallback: .metadataFetchFailed(error.localizedDescription))
            lastError = ie
            throw ie
        }
    }

    // MARK: - Import destinations

    /// A library or collection destination in imbib. Surfaced in the
    /// "import to imbib" picker.
    public struct ImportDestination: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let type: DestinationType
        public let parentName: String?

        public enum DestinationType: Hashable {
            case library
            case collection
        }

        public var displayName: String {
            if let parent = parentName { return "\(parent) / \(name)" }
            return name
        }
    }

    /// List libraries and non-smart collections from imbib. Inboxes are hidden
    /// from the picker (they're not a meaningful import destination).
    public func listDestinations() async throws -> [ImportDestination] {
        try await requireHTTP()
        do {
            async let libsTask = ImbibBridge.listLibraries()
            async let colsTask = ImbibBridge.listCollections()
            let (libs, cols) = try await (libsTask, colsTask)

            var destinations: [ImportDestination] = []
            for lib in libs where !(lib.isInbox ?? false) {
                destinations.append(.init(id: lib.id, name: lib.name, type: .library, parentName: nil))
            }
            for col in cols where !(col.isSmartCollection ?? false) {
                destinations.append(.init(id: col.id, name: col.name, type: .collection, parentName: col.libraryName))
            }
            return destinations
        } catch {
            let ie = mapBridgeError(error, fallback: .searchFailed(error.localizedDescription))
            lastError = ie
            throw ie
        }
    }

    /// Import papers into imbib. `identifiers` should be DOIs / arXiv ids /
    /// ADS bibcodes — bare cite keys won't trigger an external fetch.
    public func importPapers(
        citeKeys identifiers: [String],
        libraryID: String? = nil,
        collectionID: String? = nil
    ) async throws -> (added: Int, failed: Int, duplicates: Int) {
        try await requireHTTP()
        let libUUID = libraryID.flatMap(UUID.init(uuidString:))
        let colUUID = collectionID.flatMap(UUID.init(uuidString:))

        Logger.imbibIntegration.infoCapture("importPapers: \(identifiers.count) identifiers", category: "citations")
        do {
            let result = try await ImbibBridge.addPapers(
                identifiers: identifiers,
                library: libUUID,
                collection: colUUID,
                downloadPDFs: true
            )
            Logger.imbibIntegration.infoCapture(
                "importPapers result: added=\(result.addedCount) failed=\(result.failedCount) duplicates=\(result.duplicateCount)",
                category: "citations"
            )
            ImprintPublicationService.shared.invalidateCaches()
            return (result.addedCount, result.failedCount, result.duplicateCount)
        } catch {
            let ie = mapBridgeError(error, fallback: .searchFailed(error.localizedDescription))
            lastError = ie
            throw ie
        }
    }

    /// Create a new library in imbib and return its id as a string.
    public func createLibrary(name: String) async throws -> String {
        try await requireHTTP()
        do {
            let id = try await ImbibBridge.createLibrary(name: name)
            return id.uuidString
        } catch {
            let ie = mapBridgeError(error, fallback: .searchFailed(error.localizedDescription))
            lastError = ie
            throw ie
        }
    }

    // MARK: - URL-scheme actions (launch only)

    public func openPDF(citeKey: String) { openURL(path: "paper/\(citeKey)/open-pdf") }
    public func openNotes(citeKey: String) { openURL(path: "paper/\(citeKey)/notes") }
    public func showPaper(citeKey: String) { openURL(path: "paper/\(citeKey)") }
    public func findRelatedPapers(citeKey: String) { openURL(path: "paper/\(citeKey)/related") }
    public func openImbib() { openURL(path: "") }
    public func openAutomationSettings() { openURL(path: "settings/automation") }

    /// Open imbib with a pre-populated search query. Used by context-menu
    /// "Search imbib for…" and similar affordances.
    public func searchForCitation(query: String) {
        guard !query.isEmpty else {
            openImbib()
            return
        }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(imbibURLScheme)://search?query=\(encoded)") else {
            openImbib()
            return
        }
        Logger.imbibIntegration.infoCapture("Opening imbib search for: \(query)", category: "imbib")
        NSWorkspace.shared.open(url)
    }

    /// Extract `@citeKey` references from arbitrary text. Used by the AI
    /// context-menu service to spot citations the user has selected.
    public func extractCiteKeys(from text: String) -> [String] {
        let pattern = "@([a-zA-Z0-9_:-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func openURL(path: String) {
        guard let url = URL(string: "\(imbibURLScheme)://\(path)") else {
            Logger.imbibIntegration.errorCapture("Invalid imbib URL path: \(path)", category: "imbib")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Mapping helpers

    private static func citationResult(from paper: ImbibPaper) -> CitationResult {
        let year = paper.year ?? 0
        return CitationResult(
            id: UUID(uuidString: paper.id) ?? UUID(),
            citeKey: paper.citeKey,
            title: paper.title,
            authors: paper.authors,
            year: year,
            venue: paper.venue ?? "",
            formattedPreview: formatCitationStatic(authors: paper.authors, year: year),
            bibtex: paper.bibtex ?? "",
            hasPDF: paper.hasPDF ?? false
        )
    }

    private func formatCitation(authors: String, year: Int) -> String {
        Self.formatCitationStatic(authors: authors, year: year)
    }

    private static func formatCitationStatic(authors: String, year: Int) -> String {
        let firstAuthor = authors
            .components(separatedBy: ",").first?
            .components(separatedBy: " and ").first?
            .trimmingCharacters(in: .whitespaces) ?? authors
        let authorPart = (authors.contains(" and ") || authors.contains(","))
            ? "\(firstAuthor) et al."
            : firstAuthor
        if year > 0 { return "\(authorPart) (\(year))" }
        return authorPart
    }

    private func mapBridgeError(_ error: Error, fallback: ImbibIntegrationError) -> ImbibIntegrationError {
        if let bridge = error as? SiblingBridgeError {
            switch bridge {
            case .httpError(statusCode: 403):
                return .automationDisabled
            case .appNotAvailable:
                return .automationDisabled
            case .httpError(statusCode: 404):
                return .metadataFetchFailed("Not found")
            default:
                return fallback
            }
        }
        return fallback
    }
}

// MARK: - Errors

/// Errors surfaced from ImbibIntegrationService. UI layers should display
/// `localizedDescription` to the user and suggest enabling automation when
/// appropriate.
public enum ImbibIntegrationError: LocalizedError, Equatable {
    case notInstalled
    case automationDisabled
    case searchFailed(String)
    case bibtexFetchFailed(String)
    case metadataFetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "imbib is not installed. Please install imbib to use citation features."
        case .automationDisabled:
            return "imbib automation is disabled. Please enable automation in imbib → Settings → Automation."
        case .searchFailed(let message):
            return "Failed to search papers: \(message)"
        case .bibtexFetchFailed(let message):
            return "Failed to fetch BibTeX: \(message)"
        case .metadataFetchFailed(let message):
            return "Failed to fetch paper metadata: \(message)"
        }
    }
}
