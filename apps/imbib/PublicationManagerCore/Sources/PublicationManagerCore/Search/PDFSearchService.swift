//
//  PDFSearchService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-12.
//

import Foundation
import CoreData
import PDFKit
import OSLog

// MARK: - PDF Search Result

/// A search result from PDF content search
public struct PDFSearchResult: Identifiable, Sendable {
    public let id: UUID
    public let publicationID: UUID
    public let pdfURL: URL
    public let snippet: String
    public let pageNumber: Int?

    public init(publicationID: UUID, pdfURL: URL, snippet: String, pageNumber: Int? = nil) {
        self.id = UUID()
        self.publicationID = publicationID
        self.pdfURL = pdfURL
        self.snippet = snippet
        self.pageNumber = pageNumber
    }
}

// MARK: - PDF Search Provider Protocol

/// Protocol for platform-specific PDF search implementations
public protocol PDFSearchProvider: Sendable {
    /// Search for text within PDFs
    /// - Parameters:
    ///   - query: The search query
    ///   - pdfURLs: URLs of PDFs to search (with associated publication IDs)
    /// - Returns: Array of search results
    func search(query: String, in pdfURLs: [(publicationID: UUID, url: URL)]) async -> [PDFSearchResult]

    /// Check if a PDF contains the given text (quick check)
    func contains(query: String, in url: URL) async -> Bool
}

// MARK: - PDF Search Service

/// Cross-platform service for searching within PDF content
///
/// Uses platform-optimal strategies:
/// - macOS: Spotlight (NSMetadataQuery) for pre-indexed, instant search
/// - iOS: PDFKit text extraction with caching
public actor PDFSearchService {

    // MARK: - Shared Instance

    public static let shared = PDFSearchService()

    // MARK: - Properties

    private let provider: any PDFSearchProvider

    // MARK: - Initialization

    public init() {
        #if os(macOS)
        self.provider = SpotlightPDFSearchProvider()
        #else
        self.provider = PDFKitSearchProvider()
        #endif
    }

    /// Initialize with custom provider (for testing)
    public init(provider: any PDFSearchProvider) {
        self.provider = provider
    }

    // MARK: - Search

    /// Search for text within PDFs in a library
    /// - Parameters:
    ///   - query: The search query
    ///   - publications: Publications to search (must have linked PDFs)
    ///   - library: The library containing the PDFs
    /// - Returns: Publication IDs that match the search
    public func search(
        query: String,
        in publications: [CDPublication],
        library: CDLibrary?
    ) async -> Set<UUID> {
        guard !query.isEmpty else { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()

        // THREAD SAFETY: Extract all needed Core Data properties on main actor FIRST
        // CDPublication, CDLinkedFile, and CDLibrary are bound to the main actor context,
        // so we cannot access their properties directly from this actor's thread.
        let extractedData: [(publicationID: UUID, relativePath: String)] = await MainActor.run {
            publications.compactMap { publication -> (UUID, String)? in
                guard let linkedFiles = publication.linkedFiles,
                      let pdfFile = linkedFiles.first(where: { $0.isPDF }) else {
                    return nil
                }
                return (publication.id, pdfFile.relativePath)
            }
        }

        // Extract library container URL on main actor (only once)
        let containerURL: URL? = await MainActor.run {
            library?.containerURL
        }

        // Resolve PDF URLs using extracted Sendable values (nonisolated, safe on any thread)
        let pdfURLs: [(publicationID: UUID, url: URL)] = extractedData.compactMap { item in
            guard let url = resolvePDFURL(relativePath: item.relativePath, containerURL: containerURL) else {
                return nil
            }
            return (item.publicationID, url)
        }

        Logger.search.debugCapture("PDF search: checking \(pdfURLs.count) PDFs for '\(query)'", category: "pdfsearch")

        // Perform the search using only Sendable data
        let results = await provider.search(query: query, in: pdfURLs)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.search.infoCapture(
            "PDF search completed: \(results.count) matches in \(String(format: "%.0f", elapsed))ms",
            category: "pdfsearch"
        )

        return Set(results.map { $0.publicationID })
    }

    /// Quick check if a single PDF contains the query
    public func contains(query: String, in publication: CDPublication, library: CDLibrary?) async -> Bool {
        guard !query.isEmpty else { return false }

        // THREAD SAFETY: Extract Core Data properties on main actor before processing
        let (relativePath, containerURL): (String?, URL?) = await MainActor.run {
            guard let linkedFiles = publication.linkedFiles,
                  let pdfFile = linkedFiles.first(where: { $0.isPDF }) else {
                return (nil, nil)
            }
            return (pdfFile.relativePath, library?.containerURL)
        }

        guard let relativePath = relativePath,
              let pdfURL = resolvePDFURL(relativePath: relativePath, containerURL: containerURL) else {
            return false
        }
        return await provider.contains(query: query, in: pdfURL)
    }

    // MARK: - Helpers

    /// Resolve PDF URL from pre-extracted values (nonisolated for thread safety).
    /// - Parameters:
    ///   - relativePath: The relative path from CDLinkedFile.relativePath
    ///   - containerURL: The library container URL (nil for default library)
    /// - Returns: The resolved PDF URL if found
    nonisolated private func resolvePDFURL(relativePath: String, containerURL: URL?) -> URL? {
        let normalizedPath = relativePath.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("imbib")

        if let containerURL = containerURL {
            // Primary: container-based path (iCloud-only storage)
            let fullContainerURL = containerURL.appendingPathComponent(normalizedPath)
            // Fallback: legacy path (pre-v1.3.0 downloads went to imbib/Papers/)
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)

            if fileManager.fileExists(atPath: fullContainerURL.path) {
                return fullContainerURL
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                return legacyURL
            }
            return fullContainerURL
        } else {
            let defaultURL = appSupport.appendingPathComponent("DefaultLibrary/\(normalizedPath)")
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)
            if fileManager.fileExists(atPath: defaultURL.path) {
                return defaultURL
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                return legacyURL
            }
            return defaultURL
        }
    }
}

// MARK: - Spotlight PDF Search Provider (macOS)

#if os(macOS)
import AppKit

/// macOS implementation using Spotlight for fast, pre-indexed search
public final class SpotlightPDFSearchProvider: PDFSearchProvider, @unchecked Sendable {

    public init() {}

    public func search(query: String, in pdfURLs: [(publicationID: UUID, url: URL)]) async -> [PDFSearchResult] {
        guard !pdfURLs.isEmpty else { return [] }

        // Build a lookup map from URL to publication ID
        var urlToPublication: [URL: UUID] = [:]
        for (pubID, url) in pdfURLs {
            urlToPublication[url.standardizedFileURL] = pubID
        }

        // Get the search scope (directories containing the PDFs)
        let searchScopes = Set(pdfURLs.map { $0.url.deletingLastPathComponent() })

        return await withCheckedContinuation { continuation in
            let mdQuery = NSMetadataQuery()

            // Search for PDFs containing the text
            // kMDItemTextContent searches the full text content indexed by Spotlight
            mdQuery.predicate = NSPredicate(
                format: "kMDItemContentTypeTree == 'com.adobe.pdf' AND kMDItemTextContent CONTAINS[cd] %@",
                query
            )
            mdQuery.searchScopes = Array(searchScopes)

            // Handle completion
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: mdQuery,
                queue: .main
            ) { [weak mdQuery] _ in
                defer {
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    mdQuery?.stop()
                }

                guard let mdQuery else {
                    continuation.resume(returning: [])
                    return
                }

                var results: [PDFSearchResult] = []

                mdQuery.disableUpdates()
                for item in mdQuery.results {
                    guard let metadataItem = item as? NSMetadataItem,
                          let path = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String else {
                        continue
                    }

                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard let publicationID = urlToPublication[url] else {
                        continue  // Not one of our PDFs
                    }

                    // Try to extract a snippet from the content
                    let snippet = self.extractSnippet(from: metadataItem, query: query) ?? "Match found in PDF"

                    results.append(PDFSearchResult(
                        publicationID: publicationID,
                        pdfURL: url,
                        snippet: snippet
                    ))
                }
                mdQuery.enableUpdates()

                Logger.search.debugCapture("Spotlight found \(results.count) PDF matches", category: "pdfsearch")
                continuation.resume(returning: results)
            }

            // Start the query
            DispatchQueue.main.async {
                mdQuery.start()
            }

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak mdQuery] in
                if mdQuery?.isGathering == true {
                    Logger.search.warningCapture("Spotlight query timed out", category: "pdfsearch")
                    mdQuery?.stop()
                }
            }
        }
    }

    public func contains(query: String, in url: URL) async -> Bool {
        // For single file check, use PDFKit directly (faster than Spotlight query)
        guard let document = PDFDocument(url: url) else { return false }
        let results = document.findString(query, withOptions: [.caseInsensitive])
        return !results.isEmpty
    }

    /// Extract a text snippet around the match from Spotlight metadata
    private func extractSnippet(from item: NSMetadataItem, query: String) -> String? {
        // Spotlight doesn't directly provide snippets, but we can try to get some context
        // from the text content if available (note: this may be large)
        guard let textContent = item.value(forAttribute: kMDItemTextContent as String) as? String else {
            return nil
        }

        // Find the query in the text and extract surrounding context
        guard let range = textContent.range(of: query, options: .caseInsensitive) else {
            return nil
        }

        // Get ~50 characters before and after
        let snippetStart = textContent.index(range.lowerBound, offsetBy: -50, limitedBy: textContent.startIndex) ?? textContent.startIndex
        let snippetEnd = textContent.index(range.upperBound, offsetBy: 50, limitedBy: textContent.endIndex) ?? textContent.endIndex

        var snippet = String(textContent[snippetStart..<snippetEnd])

        // Clean up whitespace
        snippet = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add ellipsis if truncated
        if snippetStart != textContent.startIndex {
            snippet = "..." + snippet
        }
        if snippetEnd != textContent.endIndex {
            snippet = snippet + "..."
        }

        return snippet
    }
}

#endif

// MARK: - PDFKit Search Provider (iOS and fallback)

/// iOS implementation using PDFKit text extraction
/// Also serves as fallback for macOS when Spotlight isn't available
public final class PDFKitSearchProvider: PDFSearchProvider, @unchecked Sendable {

    /// Cache of extracted text (URL path -> extracted text)
    private var textCache: [String: String] = [:]
    private let cacheQueue = DispatchQueue(label: "com.imbib.pdfsearch.cache")

    public init() {}

    public func search(query: String, in pdfURLs: [(publicationID: UUID, url: URL)]) async -> [PDFSearchResult] {
        var results: [PDFSearchResult] = []
        let lowercaseQuery = query.lowercased()

        // Process PDFs concurrently but with limited parallelism
        await withTaskGroup(of: PDFSearchResult?.self) { group in
            for (pubID, url) in pdfURLs {
                group.addTask {
                    await self.searchInPDF(query: lowercaseQuery, publicationID: pubID, url: url)
                }
            }

            for await result in group {
                if let result {
                    results.append(result)
                }
            }
        }

        return results
    }

    public func contains(query: String, in url: URL) async -> Bool {
        let text = await extractText(from: url)
        return text?.localizedCaseInsensitiveContains(query) ?? false
    }

    /// Search within a single PDF
    private func searchInPDF(query: String, publicationID: UUID, url: URL) async -> PDFSearchResult? {
        guard let text = await extractText(from: url) else { return nil }

        let lowercaseText = text.lowercased()
        guard let range = lowercaseText.range(of: query) else { return nil }

        // Extract snippet
        let snippet = extractSnippet(from: text, range: range, query: query)

        return PDFSearchResult(
            publicationID: publicationID,
            pdfURL: url,
            snippet: snippet
        )
    }

    /// Extract text from a PDF (cached)
    private func extractText(from url: URL) async -> String? {
        let key = url.path

        // Check cache first
        let cached: String? = cacheQueue.sync { textCache[key] }
        if let cached { return cached }

        // Extract text using PDFKit
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url) else { return nil }

        // PDFDocument.string extracts all text from the document
        guard let text = document.string, !text.isEmpty else { return nil }

        // Cache the result
        cacheQueue.sync { textCache[key] = text }

        return text
    }

    /// Extract a snippet around the match
    private func extractSnippet(from text: String, range: Range<String.Index>, query: String) -> String {
        // Get ~50 characters before and after
        let snippetStart = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let snippetEnd = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex

        var snippet = String(text[snippetStart..<snippetEnd])

        // Clean up whitespace
        snippet = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add ellipsis if truncated
        if snippetStart != text.startIndex {
            snippet = "..." + snippet
        }
        if snippetEnd != text.endIndex {
            snippet = snippet + "..."
        }

        return snippet
    }

    /// Clear the text cache (call when PDFs change)
    public func clearCache() {
        cacheQueue.sync { textCache.removeAll() }
    }

    /// Clear cache for a specific URL
    public func clearCache(for url: URL) {
        _ = cacheQueue.sync { textCache.removeValue(forKey: url.path) }
    }
}
