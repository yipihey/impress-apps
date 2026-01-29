//
//  ImbibIntegrationService.swift
//  imprint
//
//  Integration service for communicating with imbib citation manager.
//  Uses URL schemes for actions and pasteboard for data exchange.
//

import Foundation
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "imbibIntegration")

// MARK: - Imbib Integration Service

/// Service for integrating with the imbib citation manager.
///
/// This service provides:
/// - App availability detection via NSWorkspace
/// - Citation search via URL scheme + pasteboard
/// - BibTeX retrieval for cite keys
/// - PDF/notes/paper opening via URL scheme
@MainActor @Observable
public final class ImbibIntegrationService {

    // MARK: - Singleton

    public static let shared = ImbibIntegrationService()

    // MARK: - Published State

    /// Whether imbib is installed on the system
    public private(set) var isAvailable: Bool = false

    /// Whether imbib automation is enabled (requires user opt-in in imbib settings)
    public private(set) var isAutomationEnabled: Bool = false

    /// Last error encountered during integration
    public private(set) var lastError: ImbibIntegrationError?

    // MARK: - Constants

    private let imbibBundleID = "com.imbib.app"
    private let imbibURLScheme = "imbib"
    private let pasteboardType = NSPasteboard.PasteboardType("com.imbib.citation-data")

    // MARK: - Initialization

    private init() {
        Task {
            await checkAvailability()
        }
    }

    // MARK: - Availability Check

    /// Check if imbib is installed and available.
    public func checkAvailability() async {
        // Check if imbib app is installed using NSWorkspace
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: imbibBundleID) {
            logger.info("imbib found at: \(url.path)")
            isAvailable = true

            // Assume automation is enabled if app is installed
            // User will see error if they try to use a feature that requires it
            isAutomationEnabled = true
        } else {
            logger.info("imbib not found")
            isAvailable = false
            isAutomationEnabled = false
        }
    }

    // MARK: - Search Operations

    /// Search papers in imbib library using URL scheme.
    ///
    /// This opens imbib with a search query and reads results from pasteboard.
    ///
    /// - Parameters:
    ///   - query: Search query (title, authors, cite key)
    ///   - maxResults: Maximum number of results to return
    /// - Returns: Array of citation results
    @available(macOS 13.0, *)
    public func searchPapers(query: String, maxResults: Int = 20) async throws -> [CitationResult] {
        guard isAvailable else {
            throw ImbibIntegrationError.notInstalled
        }

        logger.info("Searching imbib for: \(query)")

        // URL encode the query
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ImbibIntegrationError.searchFailed("Invalid search query")
        }

        // Clear pasteboard and set request
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Create search URL with callback to pasteboard
        let urlString = "\(imbibURLScheme)://search?query=\(encodedQuery)&maxResults=\(maxResults)&returnTo=pasteboard"
        guard let url = URL(string: urlString) else {
            throw ImbibIntegrationError.searchFailed("Invalid URL")
        }

        // Open imbib with search URL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false // Don't bring imbib to front

        do {
            try await NSWorkspace.shared.open(url, configuration: config)
        } catch {
            throw ImbibIntegrationError.searchFailed("Failed to open imbib: \(error.localizedDescription)")
        }

        // Wait for imbib to respond with data on pasteboard
        // Poll for up to 5 seconds
        var results: [CitationResult] = []
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            if let data = pasteboard.data(forType: pasteboardType),
               let response = try? JSONDecoder().decode(ImbibSearchResponse.self, from: data) {
                if let error = response.error {
                    if error.contains("automation") || error.contains("disabled") {
                        isAutomationEnabled = false
                        throw ImbibIntegrationError.automationDisabled
                    }
                    throw ImbibIntegrationError.searchFailed(error)
                }

                results = response.papers.map { paper in
                    CitationResult(
                        id: UUID(uuidString: paper.id) ?? UUID(),
                        citeKey: paper.citeKey,
                        title: paper.title,
                        authors: paper.authors,
                        year: paper.year ?? 0,
                        venue: paper.venue ?? "",
                        formattedPreview: formatCitation(authors: paper.authors, year: paper.year),
                        bibtex: paper.bibtex ?? "",
                        hasPDF: paper.hasPDF
                    )
                }
                break
            }
        }

        logger.info("Search returned \(results.count) results")
        return results
    }

    // MARK: - BibTeX Operations

    /// Get BibTeX entries for the given cite keys.
    ///
    /// - Parameter citeKeys: Array of cite keys to fetch
    /// - Returns: Combined BibTeX string
    @available(macOS 13.0, *)
    public func getBibTeX(forCiteKeys citeKeys: [String]) async throws -> String {
        guard isAvailable else {
            throw ImbibIntegrationError.notInstalled
        }

        guard !citeKeys.isEmpty else {
            return ""
        }

        logger.info("Fetching BibTeX for \(citeKeys.count) keys")

        // Clear pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Create URL with cite keys
        let keysParam = citeKeys.joined(separator: ",")
        guard let encodedKeys = keysParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ImbibIntegrationError.bibtexFetchFailed("Invalid cite keys")
        }

        let urlString = "\(imbibURLScheme)://export/bibtex?citeKeys=\(encodedKeys)&returnTo=pasteboard"
        guard let url = URL(string: urlString) else {
            throw ImbibIntegrationError.bibtexFetchFailed("Invalid URL")
        }

        // Open imbib
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        do {
            try await NSWorkspace.shared.open(url, configuration: config)
        } catch {
            throw ImbibIntegrationError.bibtexFetchFailed("Failed to open imbib: \(error.localizedDescription)")
        }

        // Wait for response
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)

            if let string = pasteboard.string(forType: .string),
               string.contains("@") { // BibTeX entries start with @
                return string
            }
        }

        throw ImbibIntegrationError.bibtexFetchFailed("Timeout waiting for BibTeX data")
    }

    /// Get metadata for a specific paper.
    ///
    /// - Parameter citeKey: The cite key to look up
    /// - Returns: Citation result or nil if not found
    @available(macOS 13.0, *)
    public func getPaperMetadata(citeKey: String) async throws -> CitationResult? {
        guard isAvailable else {
            throw ImbibIntegrationError.notInstalled
        }

        logger.info("Fetching metadata for: \(citeKey)")

        // Search for the specific cite key
        let results = try await searchPapers(query: citeKey, maxResults: 1)
        return results.first { $0.citeKey == citeKey }
    }

    // MARK: - URL Scheme Actions

    /// Open the PDF for a paper in imbib.
    ///
    /// - Parameter citeKey: The cite key of the paper
    public func openPDF(citeKey: String) {
        openURL(path: "paper/\(citeKey)/open-pdf")
    }

    /// Open the notes for a paper in imbib.
    ///
    /// - Parameter citeKey: The cite key of the paper
    public func openNotes(citeKey: String) {
        openURL(path: "paper/\(citeKey)/notes")
    }

    /// Show a paper in imbib's main view.
    ///
    /// - Parameter citeKey: The cite key of the paper
    public func showPaper(citeKey: String) {
        openURL(path: "paper/\(citeKey)")
    }

    /// Open imbib to search for related papers.
    ///
    /// - Parameter citeKey: The cite key to find related papers for
    public func findRelatedPapers(citeKey: String) {
        openURL(path: "paper/\(citeKey)/related")
    }

    /// Open imbib's main window.
    public func openImbib() {
        openURL(path: "")
    }

    /// Open imbib's automation settings.
    public func openAutomationSettings() {
        openURL(path: "settings/automation")
    }

    // MARK: - AI Context Menu Integration

    /// Search for citations in imbib using a query derived from selected text.
    ///
    /// This opens imbib with a pre-populated search query, allowing the user
    /// to find papers that could support their writing.
    ///
    /// - Parameter query: The search query (typically from selected text or AI-extracted keywords)
    public func searchForCitation(query: String) {
        guard !query.isEmpty else {
            logger.warning("Empty search query, opening imbib without search")
            openImbib()
            return
        }

        // URL encode the query
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            logger.error("Failed to encode search query")
            openImbib()
            return
        }

        // Open imbib with search query - brings imbib to front with search populated
        let urlString = "\(imbibURLScheme)://search?query=\(encodedQuery)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid search URL")
            openImbib()
            return
        }

        logger.info("Opening imbib search for: \(query)")
        NSWorkspace.shared.open(url)
    }

    /// Extract citation keys from selected text or AI-suggested terms.
    ///
    /// This analyzes the text to find existing @citeKey references.
    ///
    /// - Parameter text: The text to analyze
    /// - Returns: Array of found cite keys
    public func extractCiteKeys(from text: String) -> [String] {
        let pattern = "@([a-zA-Z0-9_:-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        return matches.compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[keyRange])
        }
    }

    private func openURL(path: String) {
        guard let url = URL(string: "\(imbibURLScheme)://\(path)") else {
            logger.error("Invalid URL path: \(path)")
            return
        }

        logger.info("Opening imbib URL: \(url)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func formatCitation(authors: String, year: Int?) -> String {
        let authorPart: String
        if authors.contains(",") {
            // Multiple authors: "Smith, J. and Jones, B." -> "Smith et al."
            let firstAuthor = authors.components(separatedBy: ",").first ?? authors
            if authors.contains(" and ") {
                authorPart = "\(firstAuthor) et al."
            } else {
                authorPart = firstAuthor
            }
        } else {
            authorPart = authors
        }

        if let year = year, year > 0 {
            return "\(authorPart) (\(year))"
        } else {
            return authorPart
        }
    }
}

// MARK: - Error Types

/// Errors that can occur during imbib integration.
public enum ImbibIntegrationError: LocalizedError {
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
            return "imbib automation is disabled. Please enable automation in imbib Settings → Automation."
        case .searchFailed(let message):
            return "Failed to search papers: \(message)"
        case .bibtexFetchFailed(let message):
            return "Failed to fetch BibTeX: \(message)"
        case .metadataFetchFailed(let message):
            return "Failed to fetch paper metadata: \(message)"
        }
    }
}

// MARK: - Response Types

/// Response from imbib search operation via pasteboard.
struct ImbibSearchResponse: Codable {
    let papers: [ImbibPaperData]
    let error: String?
}

/// Paper data returned from imbib.
struct ImbibPaperData: Codable {
    let id: String
    let citeKey: String
    let title: String
    let authors: String
    let year: Int?
    let venue: String?
    let bibtex: String?
    let hasPDF: Bool
}
