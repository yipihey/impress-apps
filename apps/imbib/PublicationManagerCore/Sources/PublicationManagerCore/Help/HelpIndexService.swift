//
//  HelpIndexService.swift
//  PublicationManagerCore
//
//  Service for loading and searching help documentation.
//
//  Uses Rust-powered Tantivy full-text search when available for improved
//  search quality with term highlighting and relevance scoring.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.help", category: "index")

/// Service for loading help documents and performing searches.
///
/// Provides:
/// - Loading the bundled help index
/// - Loading markdown content for documents
/// - Combined keyword and semantic search (Swift fallback)
/// - Full-text search with highlighting (Rust/Tantivy when available)
public actor HelpIndexService {

    // MARK: - Singleton

    public static let shared = HelpIndexService()

    // MARK: - State

    private var index: HelpIndex?
    private var documentContent: [String: String] = [:]
    private var isLoaded = false
    private var rustSearchReady = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Index Loading

    /// Load the help index from the bundled JSON file.
    public func loadIndex() async {
        guard !isLoaded else { return }

        // Try to load from the app bundle
        if let url = Bundle.main.url(forResource: "HelpIndex", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                index = try decoder.decode(HelpIndex.self, from: data)
                isLoaded = true
                logger.info("Loaded help index with \(self.index?.documents.count ?? 0) documents")
            } catch {
                logger.error("Failed to load help index: \(error.localizedDescription)")
                // Fall back to built-in documents
                loadBuiltInDocuments()
            }
        } else {
            logger.warning("HelpIndex.json not found in bundle, using built-in documents")
            loadBuiltInDocuments()
        }

        // Initialize Rust search index if available
        await initializeRustSearch()
    }

    /// Initialize the Rust-powered search index
    private func initializeRustSearch() async {
        guard RustHelpSearchInfo.isAvailable else {
            logger.info("Rust help search not available, using Swift fallback")
            return
        }

        do {
            try await RustHelpSearchService.shared.initializeIndex()

            // Index all documents
            var rustDocs: [HelpDocumentInput] = []
            for document in index?.documents ?? [] {
                let content = await loadContent(for: document)
                let platform: RustHelpPlatform = .both // Default to both platforms

                rustDocs.append(HelpDocumentInput(
                    id: document.id,
                    title: document.title,
                    body: content,
                    keywords: document.keywords,
                    platform: platform,
                    category: document.category.rawValue
                ))
            }

            try await RustHelpSearchService.shared.indexDocuments(rustDocs)
            rustSearchReady = true
            logger.info("Rust help search index ready with \(rustDocs.count) documents")
        } catch {
            logger.warning("Failed to initialize Rust help search: \(error.localizedDescription)")
            rustSearchReady = false
        }
    }

    /// Load built-in document definitions when the JSON index is not available.
    private func loadBuiltInDocuments() {
        index = HelpIndex(version: "1.0", documents: [
            HelpDocument(
                id: "getting-started",
                title: "Getting Started",
                category: .gettingStarted,
                filename: "getting-started.md",
                keywords: ["install", "setup", "library", "import", "first", "begin"],
                summary: "Set up imbib and import your first papers.",
                sortOrder: 0
            ),
            HelpDocument(
                id: "features",
                title: "Features Overview",
                category: .features,
                filename: "features.md",
                keywords: ["feature", "capability", "function", "what can"],
                summary: "Explore imbib's key features and capabilities.",
                sortOrder: 0
            ),
            HelpDocument(
                id: "keyboard-shortcuts",
                title: "Keyboard Shortcuts",
                category: .keyboardShortcuts,
                filename: "keyboard-shortcuts.md",
                keywords: ["shortcut", "hotkey", "keybinding", "keyboard", "command"],
                summary: "Quick reference for all keyboard shortcuts.",
                sortOrder: 0
            ),
            HelpDocument(
                id: "faq",
                title: "Frequently Asked Questions",
                category: .faq,
                filename: "faq.md",
                keywords: ["question", "help", "problem", "issue", "how to"],
                summary: "Answers to common questions.",
                sortOrder: 0
            ),
            HelpDocument(
                id: "automation",
                title: "Automation & Integration",
                category: .automation,
                filename: "automation.md",
                keywords: ["automate", "script", "url scheme", "shortcuts", "siri", "api"],
                summary: "Automate imbib with URL schemes and Shortcuts.",
                sortOrder: 0
            ),
            HelpDocument(
                id: "share-extension",
                title: "Browser Extension",
                category: .automation,
                filename: "share-extension.md",
                keywords: ["browser", "safari", "extension", "share", "import", "web"],
                summary: "Import papers directly from your browser.",
                sortOrder: 1
            ),
        ])
        isLoaded = true
    }

    // MARK: - Document Access

    /// Get all documents in the index.
    public func allDocuments() async -> [HelpDocument] {
        await loadIndex()
        return index?.documents ?? []
    }

    /// Get documents filtered by category.
    public func documents(for category: HelpCategory) async -> [HelpDocument] {
        await loadIndex()
        return (index?.documents ?? [])
            .filter { $0.category == category }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Get a specific document by ID.
    public func document(id: String) async -> HelpDocument? {
        await loadIndex()
        return index?.documents.first { $0.id == id }
    }

    // MARK: - Content Loading

    /// Load the markdown content for a document.
    ///
    /// Content is cached after first load. Strips YAML front matter if present.
    public func loadContent(for document: HelpDocument) async -> String {
        // Check cache first
        if let cached = documentContent[document.id] {
            return cached
        }

        // Try to load from bundle
        let filename = document.filename.replacingOccurrences(of: ".md", with: "")
        if let url = Bundle.main.url(forResource: filename, withExtension: "md", subdirectory: "HelpDocs") {
            do {
                var content = try String(contentsOf: url, encoding: .utf8)
                content = stripYAMLFrontMatter(content)
                documentContent[document.id] = content
                return content
            } catch {
                logger.error("Failed to load content for \(document.id): \(error.localizedDescription)")
            }
        }

        // Try loading from docs directory (for development)
        let docsPath = "docs/\(document.filename)"
        if let url = Bundle.main.url(forResource: docsPath, withExtension: nil) {
            do {
                var content = try String(contentsOf: url, encoding: .utf8)
                content = stripYAMLFrontMatter(content)
                documentContent[document.id] = content
                return content
            } catch {
                logger.error("Failed to load content from docs for \(document.id): \(error.localizedDescription)")
            }
        }

        return "Content not available.\n\nThe documentation file '\(document.filename)' could not be found."
    }

    /// Strip YAML front matter from markdown content.
    private func stripYAMLFrontMatter(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)

        // Check if content starts with YAML front matter
        guard lines.first == "---" else { return content }

        // Find the closing ---
        if let endIndex = lines.dropFirst().firstIndex(of: "---") {
            let contentLines = lines.suffix(from: lines.index(after: endIndex))
            return contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return content
    }

    // MARK: - Search

    /// Search help documents using Rust full-text search when available,
    /// falling back to Swift keyword search.
    ///
    /// Rust search provides:
    /// - Tantivy full-text indexing
    /// - Term highlighting with <mark> tags
    /// - Better relevance scoring
    ///
    /// Swift fallback priority:
    /// 1. Title matches (score: 1.0)
    /// 2. Keyword matches (score: 0.8)
    /// 3. Summary matches (score: 0.5)
    /// 4. Content full-text search (score: 0.4)
    public func search(query: String) async -> [HelpSearchResult] {
        await loadIndex()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        // Try Rust search first
        if rustSearchReady {
            do {
                let rustResults = try await RustHelpSearchService.shared.search(
                    query: trimmedQuery,
                    limit: 20,
                    filterPlatform: true
                )

                // Convert Rust results to HelpSearchResult
                return rustResults.compactMap { hit -> HelpSearchResult? in
                    guard let document = index?.documents.first(where: { $0.id == hit.id }) else {
                        return nil
                    }
                    return HelpSearchResult(
                        documentID: hit.id,
                        documentTitle: hit.title,
                        category: document.category,
                        snippet: hit.snippet,
                        matchType: .content,
                        score: hit.relevanceScore
                    )
                }
            } catch {
                logger.warning("Rust search failed, falling back to Swift: \(error.localizedDescription)")
            }
        }

        // Fall back to Swift search
        return await swiftSearch(query: trimmedQuery.lowercased())
    }

    /// Swift-based fallback search implementation
    private func swiftSearch(query: String) async -> [HelpSearchResult] {
        var results: [HelpSearchResult] = []
        let queryWords = Set(query.components(separatedBy: .whitespaces))

        for document in index?.documents ?? [] {
            // 1. Title match
            if document.title.lowercased().contains(query) {
                results.append(HelpSearchResult(
                    documentID: document.id,
                    documentTitle: document.title,
                    category: document.category,
                    snippet: document.summary,
                    matchType: .title,
                    score: 1.0
                ))
                continue
            }

            // 2. Keyword match
            let matchedKeywords = document.keywords.filter { keyword in
                queryWords.contains { $0.contains(keyword.lowercased()) || keyword.lowercased().contains($0) }
            }
            if !matchedKeywords.isEmpty {
                results.append(HelpSearchResult(
                    documentID: document.id,
                    documentTitle: document.title,
                    category: document.category,
                    snippet: document.summary,
                    matchType: .keyword,
                    score: 0.8
                ))
                continue
            }

            // 3. Summary match (lightweight content search)
            if document.summary.lowercased().contains(query) {
                results.append(HelpSearchResult(
                    documentID: document.id,
                    documentTitle: document.title,
                    category: document.category,
                    snippet: document.summary,
                    matchType: .content,
                    score: 0.5
                ))
                continue
            }

            // 4. Full content search (load content if needed)
            let content = await loadContent(for: document)
            if content.lowercased().contains(query) {
                // Extract snippet around the match
                let snippet = extractSnippet(from: content, matching: query)
                results.append(HelpSearchResult(
                    documentID: document.id,
                    documentTitle: document.title,
                    category: document.category,
                    snippet: snippet,
                    matchType: .content,
                    score: 0.4
                ))
            }
        }

        // Sort by score descending
        results.sort { $0.score > $1.score }

        // Deduplicate by document ID (keep highest score)
        var seen = Set<String>()
        results = results.filter { result in
            if seen.contains(result.documentID) {
                return false
            }
            seen.insert(result.documentID)
            return true
        }

        return results
    }

    /// Extract a snippet from content around the matching query.
    private func extractSnippet(from content: String, matching query: String, maxLength: Int = 150) -> String {
        let lowercased = content.lowercased()
        guard let range = lowercased.range(of: query) else {
            // Return the beginning of the content
            let index = content.index(content.startIndex, offsetBy: min(maxLength, content.count))
            return String(content[..<index]) + "..."
        }

        // Find the start and end positions for the snippet
        let matchStart = content.distance(from: content.startIndex, to: range.lowerBound)
        let snippetStart = max(0, matchStart - 50)
        let snippetEnd = min(content.count, matchStart + query.count + 100)

        let startIndex = content.index(content.startIndex, offsetBy: snippetStart)
        let endIndex = content.index(content.startIndex, offsetBy: snippetEnd)

        var snippet = String(content[startIndex..<endIndex])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        if snippetStart > 0 {
            snippet = "..." + snippet
        }
        if snippetEnd < content.count {
            snippet = snippet + "..."
        }

        return snippet
    }
}
