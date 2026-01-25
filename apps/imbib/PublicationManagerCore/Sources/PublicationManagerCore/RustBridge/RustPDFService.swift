//
//  RustPDFService.swift
//  PublicationManagerCore
//
//  PDF processing service backed by Rust/pdfium.
//  Provides text extraction and thumbnail generation.
//

import Foundation
import ImbibRustCore

// MARK: - Rust PDF Service

/// PDF processing service backed by Rust/pdfium.
///
/// Provides:
/// - Text extraction for search indexing
/// - Thumbnail generation
/// - PDF search and metadata
///
/// This uses pdfium via Rust for cross-platform consistency,
/// while PDFKit handles interactive viewing and annotations.
public enum RustPDFService {

    /// Check if the Rust PDF service is available.
    public static var isAvailable: Bool { true }

    // MARK: - Text Extraction

    /// Extract all text from a PDF.
    ///
    /// - Parameter pdfData: Raw PDF file data
    /// - Returns: Extracted text result with per-page breakdown
    /// - Throws: PDFServiceError on failure
    public static func extractText(from pdfData: Data) throws -> PDFTextResult {
        let rustResult = try pdfExtractText(pdfBytes: pdfData)
        return PDFTextResult(from: rustResult)
    }

    /// Extract text from a PDF file URL.
    ///
    /// - Parameter url: URL to the PDF file
    /// - Returns: Extracted text result
    /// - Throws: PDFServiceError on failure
    public static func extractText(from url: URL) throws -> PDFTextResult {
        let data = try Data(contentsOf: url)
        return try extractText(from: data)
    }

    // MARK: - Thumbnail Generation

    /// Generate a thumbnail for a PDF page.
    ///
    /// - Parameters:
    ///   - pdfData: Raw PDF file data
    ///   - width: Maximum thumbnail width
    ///   - height: Maximum thumbnail height
    ///   - pageNumber: Page to render (1-indexed, default: 1)
    /// - Returns: Thumbnail result with RGBA data and dimensions
    /// - Throws: PDFServiceError on failure
    public static func generateThumbnail(
        from pdfData: Data,
        width: UInt32 = 200,
        height: UInt32 = 280,
        pageNumber: UInt32 = 1
    ) throws -> PDFThumbnailResult {
        let config = ThumbnailConfig(width: width, height: height, pageNumber: pageNumber)
        let rustResult = try pdfGenerateThumbnail(pdfBytes: pdfData, config: config)
        return PDFThumbnailResult(from: rustResult)
    }

    /// Generate a thumbnail from a PDF file URL.
    ///
    /// - Parameters:
    ///   - url: URL to the PDF file
    ///   - width: Maximum thumbnail width
    ///   - height: Maximum thumbnail height
    ///   - pageNumber: Page to render (1-indexed, default: 1)
    /// - Returns: Thumbnail result
    /// - Throws: PDFServiceError on failure
    public static func generateThumbnail(
        from url: URL,
        width: UInt32 = 200,
        height: UInt32 = 280,
        pageNumber: UInt32 = 1
    ) throws -> PDFThumbnailResult {
        let data = try Data(contentsOf: url)
        return try generateThumbnail(from: data, width: width, height: height, pageNumber: pageNumber)
    }

    // MARK: - PDF Search

    /// Search for text within a PDF.
    ///
    /// - Parameters:
    ///   - pdfData: Raw PDF file data
    ///   - query: Search query
    ///   - maxResults: Maximum number of results (default: 50)
    /// - Returns: Array of text matches with context
    /// - Throws: PDFServiceError on failure
    public static func search(
        in pdfData: Data,
        query: String,
        maxResults: UInt32 = 50
    ) throws -> [PDFTextMatch] {
        let matches = try pdfSearch(pdfBytes: pdfData, query: query, maxResults: maxResults)
        return matches.map { PDFTextMatch(from: $0) }
    }

    // MARK: - Metadata

    /// Get the number of pages in a PDF.
    ///
    /// - Parameter pdfData: Raw PDF file data
    /// - Returns: Page count
    /// - Throws: PDFServiceError on failure
    public static func getPageCount(from pdfData: Data) throws -> UInt32 {
        try pdfGetPageCount(pdfBytes: pdfData)
    }

    /// Get dimensions of a specific page.
    ///
    /// - Parameters:
    ///   - pdfData: Raw PDF file data
    ///   - pageNumber: Page number (1-indexed)
    /// - Returns: Page dimensions
    /// - Throws: PDFServiceError on failure
    public static func getPageDimensions(
        from pdfData: Data,
        pageNumber: UInt32
    ) throws -> PDFPageDimensions {
        let dims = try pdfGetPageDimensions(pdfBytes: pdfData, pageNumber: pageNumber)
        return PDFPageDimensions(width: dims.width, height: dims.height)
    }
}

// MARK: - Swift Types

/// Result of PDF text extraction.
public struct PDFTextResult: Sendable {
    /// All extracted text concatenated
    public let fullText: String
    /// Total number of pages
    public let pageCount: UInt32
    /// Per-page text breakdown
    public let pages: [PDFPageText]

    init(from rust: ImbibRustCore.PdfTextResult) {
        self.fullText = rust.fullText
        self.pageCount = rust.pageCount
        self.pages = rust.pages.map { PDFPageText(from: $0) }
    }
}

/// Text content from a single PDF page.
public struct PDFPageText: Sendable {
    /// Page number (1-indexed)
    public let pageNumber: UInt32
    /// Extracted text
    public let text: String
    /// Character count
    public let charCount: UInt32

    init(from rust: ImbibRustCore.PageText) {
        self.pageNumber = rust.pageNumber
        self.text = rust.text
        self.charCount = rust.charCount
    }
}

/// Result of PDF thumbnail generation.
public struct PDFThumbnailResult: Sendable {
    /// Raw RGBA pixel data (4 bytes per pixel)
    public let rgbaBytes: Data
    /// Actual rendered width
    public let width: UInt32
    /// Actual rendered height
    public let height: UInt32
    /// Total page count in the PDF
    public let pageCount: UInt32

    init(from rust: ImbibRustCore.PdfThumbnail) {
        self.rgbaBytes = rust.rgbaBytes
        self.width = rust.width
        self.height = rust.height
        self.pageCount = rust.pageCount
    }
}

/// A text match found during PDF search.
public struct PDFTextMatch: Sendable {
    /// Page number where match was found (1-indexed)
    public let pageNumber: UInt32
    /// Text context around the match
    public let text: String
    /// Character index of match start
    public let charIndex: UInt32

    init(from rust: ImbibRustCore.TextMatch) {
        self.pageNumber = rust.pageNumber
        self.text = rust.text
        self.charIndex = rust.charIndex
    }
}

/// Dimensions of a PDF page.
public struct PDFPageDimensions: Sendable {
    public let width: Float
    public let height: Float
}

// MARK: - Errors

/// Errors that can occur during PDF service operations.
public enum PDFServiceError: LocalizedError {
    case notAvailable
    case loadFailed(String)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Rust PDF service is not available"
        case .loadFailed(let message):
            return "Failed to load PDF: \(message)"
        case .extractionFailed(let message):
            return "Failed to extract from PDF: \(message)"
        }
    }
}
