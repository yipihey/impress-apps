//
//  PDFTextExtractor.swift
//  ImpressEmbeddings
//
//  Extracts full text from PDFs using macOS-native PDFKit,
//  preserving page boundaries for chunk metadata.
//

#if canImport(PDFKit)
import PDFKit
#endif
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.impress.embeddings", category: "PDFExtractor")

/// Extracts text from PDF documents page by page.
///
/// Uses Apple's `PDFKit` framework (macOS native, no external dependencies).
/// Each page's text is returned separately to enable page-accurate chunk metadata.
public struct PDFTextExtractor {

    /// A single page's extracted text.
    public struct PageText: Sendable {
        public let page: Int
        public let text: String

        public init(page: Int, text: String) {
            self.page = page
            self.text = text
        }
    }

    /// Extract full text from a PDF, preserving page boundaries.
    ///
    /// - Parameter url: File URL of the PDF.
    /// - Returns: Array of (page number, text) pairs, 0-indexed.
    public static func extract(from url: URL) -> [PageText] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            logger.warning("Failed to open PDF: \(url.lastPathComponent)")
            return []
        }

        return extractPages(from: document, range: 0..<document.pageCount)
        #else
        logger.warning("PDFKit not available on this platform")
        return []
        #endif
    }

    /// Extract text from a specific page range.
    ///
    /// - Parameters:
    ///   - url: File URL of the PDF.
    ///   - pages: Range of pages to extract (0-indexed).
    /// - Returns: Array of (page number, text) pairs.
    public static func extract(from url: URL, pages: Range<Int>) -> [PageText] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            logger.warning("Failed to open PDF: \(url.lastPathComponent)")
            return []
        }

        let clampedRange = max(0, pages.lowerBound)..<min(document.pageCount, pages.upperBound)
        return extractPages(from: document, range: clampedRange)
        #else
        return []
        #endif
    }

    /// Get the page count of a PDF without extracting text.
    public static func pageCount(for url: URL) -> Int {
        #if canImport(PDFKit)
        return PDFDocument(url: url)?.pageCount ?? 0
        #else
        return 0
        #endif
    }

    // MARK: - Private

    #if canImport(PDFKit)
    private static func extractPages(from document: PDFDocument, range: Range<Int>) -> [PageText] {
        var results: [PageText] = []
        results.reserveCapacity(range.count)

        for pageIndex in range {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = page.string ?? ""

            // Skip pages with negligible text (likely images/figures only)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 20 { continue }

            // Clean up common PDF extraction artifacts
            let cleaned = cleanExtractedText(trimmed)
            results.append(PageText(page: pageIndex, text: cleaned))
        }

        logger.info("Extracted \(results.count) pages from \(document.pageCount)-page PDF")
        return results
    }
    #endif

    /// Clean common PDF text extraction artifacts.
    private static func cleanExtractedText(_ text: String) -> String {
        var result = text

        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Fix hyphenated line breaks (common in two-column PDFs)
        // "computa-\ntional" → "computational"
        result = result.replacingOccurrences(
            of: "([a-z])-\\s*\n\\s*([a-z])",
            with: "$1$2",
            options: .regularExpression
        )

        // Collapse single newlines within paragraphs (keep double newlines)
        // This handles PDFs where each line is a separate string
        result = result.replacingOccurrences(
            of: "([^\n])\n([^\n])",
            with: "$1 $2",
            options: .regularExpression
        )

        return result
    }
}
