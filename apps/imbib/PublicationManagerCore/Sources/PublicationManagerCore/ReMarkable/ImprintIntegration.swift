//
//  ImprintIntegration.swift
//  PublicationManagerCore
//
//  Integration with imprint for exporting reMarkable annotations as quotable content.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation

#if os(macOS)
import AppKit
#endif

// MARK: - RemarkableQuote

/// A quote extracted from reMarkable annotations for use in imprint manuscripts.
///
/// This struct provides a standardized format for exporting annotation content
/// from reMarkable to imprint, including:
/// - Text content (OCR text for handwritten notes, or empty for pure drawings)
/// - Page reference and citation key for academic citation
/// - Optional image data for ink annotations
public struct RemarkableQuote: Codable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let pageNumber: Int
    public let citeKey: String
    public let publicationTitle: String
    public let annotationType: String  // highlight, ink, text
    public let extractedAt: Date
    public let hasImage: Bool
    public let imageData: Data?

    public init(
        id: UUID,
        text: String,
        pageNumber: Int,
        citeKey: String,
        publicationTitle: String,
        annotationType: String,
        extractedAt: Date,
        hasImage: Bool,
        imageData: Data?
    ) {
        self.id = id
        self.text = text
        self.pageNumber = pageNumber
        self.citeKey = citeKey
        self.publicationTitle = publicationTitle
        self.annotationType = annotationType
        self.extractedAt = extractedAt
        self.hasImage = hasImage
        self.imageData = imageData
    }
}

// MARK: - AnnotationModel Extension for Quotes

public extension AnnotationModel {

    /// Convert this annotation to a quotable format for imprint.
    ///
    /// - Parameters:
    ///   - citeKey: The publication's citation key
    ///   - publicationTitle: The publication's title
    /// - Returns: A `RemarkableQuote` suitable for export to imprint
    func toQuote(citeKey: String, publicationTitle: String) -> RemarkableQuote {
        RemarkableQuote(
            id: id,
            text: selectedText ?? contents ?? "",
            pageNumber: pageNumber,
            citeKey: citeKey,
            publicationTitle: publicationTitle,
            annotationType: annotationType,
            extractedAt: Date(),
            hasImage: false,
            imageData: nil  // Image rendering done on-demand by imprint
        )
    }
}

// MARK: - Remarkable Quotes Response

/// Response format for reMarkable quotes export to imprint.
public struct RemarkableQuotesResponse: Codable, Sendable {
    public let quotes: [RemarkableQuote]
    public let citeKey: String
    public let publicationTitle: String
    public let error: String?

    public init(
        quotes: [RemarkableQuote],
        citeKey: String,
        publicationTitle: String,
        error: String? = nil
    ) {
        self.quotes = quotes
        self.citeKey = citeKey
        self.publicationTitle = publicationTitle
        self.error = error
    }
}

// MARK: - Remarkable Quotes Service

/// Service for exporting reMarkable annotations as quotes for imprint.
public actor RemarkableQuotesService {
    public static let shared = RemarkableQuotesService()

    private init() {}

    /// Get all reMarkable annotation quotes for a publication.
    ///
    /// - Parameter citeKey: The citation key of the publication
    /// - Returns: Response containing quotes or error
    public func getQuotes(forCiteKey citeKey: String) async -> RemarkableQuotesResponse {
        // Find publication by cite key via RustStoreAdapter
        let pub = await MainActor.run {
            RustStoreAdapter.shared.findByCiteKey(citeKey: citeKey)
        }

        guard let pub else {
            return RemarkableQuotesResponse(
                quotes: [],
                citeKey: citeKey,
                publicationTitle: "",
                error: "Publication not found: \(citeKey)"
            )
        }

        // Get full detail for the title
        let detail = await MainActor.run {
            RustStoreAdapter.shared.getPublicationDetail(id: pub.id)
        }

        let publicationTitle = detail?.title ?? pub.title

        // Find linked PDF files and their annotations
        let linkedFiles = await MainActor.run {
            RustStoreAdapter.shared.listLinkedFiles(publicationId: pub.id)
        }

        guard let pdfFile = linkedFiles.first(where: { $0.isPDF }) else {
            return RemarkableQuotesResponse(
                quotes: [],
                citeKey: citeKey,
                publicationTitle: publicationTitle,
                error: "No PDF linked file found for this publication"
            )
        }

        // Get annotations for this file
        let annotations = await MainActor.run {
            RustStoreAdapter.shared.listAnnotations(linkedFileId: pdfFile.id)
        }

        // Filter to reMarkable-sourced annotations (author == "reMarkable")
        let rmAnnotations = annotations.filter { $0.authorName == "reMarkable" }

        guard !rmAnnotations.isEmpty else {
            return RemarkableQuotesResponse(
                quotes: [],
                citeKey: citeKey,
                publicationTitle: publicationTitle,
                error: "No reMarkable annotations found for this publication"
            )
        }

        // Convert annotations to quotes
        let quotes = rmAnnotations.map { annotation in
            annotation.toQuote(citeKey: citeKey, publicationTitle: publicationTitle)
        }

        return RemarkableQuotesResponse(
            quotes: quotes,
            citeKey: citeKey,
            publicationTitle: publicationTitle
        )
    }

    /// Export quotes to pasteboard for imprint pickup.
    ///
    /// - Parameter citeKey: The citation key of the publication
    /// - Returns: Number of quotes exported, or throws on error
    #if os(macOS)
    public func exportToPasteboard(forCiteKey citeKey: String) async throws -> Int {
        let response = await getQuotes(forCiteKey: citeKey)

        if let error = response.error {
            throw RemarkableQuotesError.exportFailed(error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(response)

        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.imbib.remarkable-quotes"))
        }

        return response.quotes.count
    }
    #endif
}

// MARK: - Errors

public enum RemarkableQuotesError: LocalizedError {
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .exportFailed(let reason):
            return "Failed to export reMarkable quotes: \(reason)"
        }
    }
}
