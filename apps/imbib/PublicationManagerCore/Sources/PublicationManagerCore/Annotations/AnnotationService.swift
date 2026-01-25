//
//  AnnotationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import Foundation
import PDFKit
import OSLog

#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

// MARK: - Highlight Color

/// Available highlight colors for PDF annotations
public enum HighlightColor: String, CaseIterable, Sendable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case orange

    /// Platform color for this highlight
    public var platformColor: PlatformColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .orange: return .systemOrange
        }
    }

    /// Display name for UI
    public var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Annotation Error

/// Errors that can occur during annotation operations
public enum AnnotationError: LocalizedError {
    case saveFailed(URL)
    case noSelection
    case invalidPage
    case documentNotFound

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let url):
            return "Failed to save annotations to \(url.lastPathComponent)"
        case .noSelection:
            return "No text selected"
        case .invalidPage:
            return "Invalid page reference"
        case .documentNotFound:
            return "PDF document not found"
        }
    }
}

// MARK: - Annotation Service

/// Service for managing PDF annotations.
///
/// Supports:
/// - Highlighting text selections
/// - Adding text notes (sticky notes)
/// - Underline and strikethrough
/// - Saving annotations to PDF files
/// - Listing all annotations in a document
@MainActor
public final class AnnotationService {

    // MARK: - Singleton

    public static let shared = AnnotationService()

    private init() {}

    // MARK: - Highlight Annotations

    /// Add highlight annotation to the current selection in a PDFView.
    ///
    /// - Parameters:
    ///   - pdfView: The PDFView containing the selection
    ///   - color: Highlight color (default: yellow)
    /// - Returns: Array of created annotations (one per line of selection)
    @discardableResult
    public func addHighlight(
        to pdfView: PDFView,
        color: HighlightColor = .yellow
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            Logger.files.warningCapture("No selection for highlight", category: "annotation")
            return []
        }

        var annotations: [PDFAnnotation] = []

        // Create annotation for each line of selection
        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page)

                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.color = color.platformColor

                page.addAnnotation(annotation)
                annotations.append(annotation)

                Logger.files.debugCapture("Added highlight at \(bounds) on page \(pdfView.document?.index(for: page) ?? -1)", category: "annotation")
            }
        }

        // Clear selection after highlighting
        pdfView.clearSelection()

        return annotations
    }

    // MARK: - Underline Annotations

    /// Add underline annotation to the current selection in a PDFView.
    ///
    /// - Parameters:
    ///   - pdfView: The PDFView containing the selection
    ///   - color: Line color (default: red)
    /// - Returns: Array of created annotations
    @discardableResult
    public func addUnderline(
        to pdfView: PDFView,
        color: PlatformColor = .systemRed
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            Logger.files.warningCapture("No selection for underline", category: "annotation")
            return []
        }

        var annotations: [PDFAnnotation] = []

        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page)

                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .underline,
                    withProperties: nil
                )
                annotation.color = color

                page.addAnnotation(annotation)
                annotations.append(annotation)
            }
        }

        pdfView.clearSelection()
        return annotations
    }

    // MARK: - Strikethrough Annotations

    /// Add strikethrough annotation to the current selection in a PDFView.
    ///
    /// - Parameters:
    ///   - pdfView: The PDFView containing the selection
    ///   - color: Line color (default: red)
    /// - Returns: Array of created annotations
    @discardableResult
    public func addStrikethrough(
        to pdfView: PDFView,
        color: PlatformColor = .systemRed
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            Logger.files.warningCapture("No selection for strikethrough", category: "annotation")
            return []
        }

        var annotations: [PDFAnnotation] = []

        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page)

                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .strikeOut,
                    withProperties: nil
                )
                annotation.color = color

                page.addAnnotation(annotation)
                annotations.append(annotation)
            }
        }

        pdfView.clearSelection()
        return annotations
    }

    // MARK: - Text Note Annotations

    /// Add a text note (sticky note) at a specific location.
    ///
    /// - Parameters:
    ///   - page: The page to add the note to
    ///   - point: Location in page coordinates
    ///   - text: The note content
    ///   - color: Note color (default: yellow)
    /// - Returns: The created annotation
    @discardableResult
    public func addTextNote(
        to page: PDFPage,
        at point: CGPoint,
        text: String,
        color: PlatformColor = .systemYellow
    ) -> PDFAnnotation {
        // Standard sticky note size
        let noteSize: CGFloat = 24

        let annotation = PDFAnnotation(
            bounds: CGRect(x: point.x, y: point.y, width: noteSize, height: noteSize),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = text
        annotation.color = color

        page.addAnnotation(annotation)

        Logger.files.debugCapture("Added text note at \(point)", category: "annotation")

        return annotation
    }

    /// Add a text note at the current selection location.
    ///
    /// - Parameters:
    ///   - pdfView: The PDFView containing the selection
    ///   - text: The note content
    ///   - color: Note color (default: yellow)
    /// - Returns: The created annotation, or nil if no selection
    @discardableResult
    public func addTextNoteAtSelection(
        in pdfView: PDFView,
        text: String,
        color: PlatformColor = .systemYellow
    ) -> PDFAnnotation? {
        guard let selection = pdfView.currentSelection,
              let page = selection.pages.first else {
            Logger.files.warningCapture("No selection for text note", category: "annotation")
            return nil
        }

        // Place note at top-right of selection
        let bounds = selection.bounds(for: page)
        let point = CGPoint(x: bounds.maxX + 4, y: bounds.maxY)

        pdfView.clearSelection()

        return addTextNote(to: page, at: point, text: text, color: color)
    }

    // MARK: - Free Text Annotations

    /// Add a free text annotation (text box) at a specific location.
    ///
    /// - Parameters:
    ///   - page: The page to add the text to
    ///   - bounds: The bounds of the text box
    ///   - text: The text content
    ///   - fontSize: Font size (default: 12)
    /// - Returns: The created annotation
    @discardableResult
    public func addFreeText(
        to page: PDFPage,
        bounds: CGRect,
        text: String,
        fontSize: CGFloat = 12
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text
        annotation.font = .systemFont(ofSize: fontSize)

        page.addAnnotation(annotation)

        return annotation
    }

    // MARK: - Remove Annotations

    /// Remove an annotation from its page.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to remove
    ///   - page: The page containing the annotation
    public func removeAnnotation(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
        Logger.files.debugCapture("Removed annotation from page", category: "annotation")
    }

    /// Remove an annotation from the document.
    ///
    /// - Parameter annotation: The annotation to remove (must have a valid page reference)
    public func removeAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else {
            Logger.files.warningCapture("Annotation has no page reference", category: "annotation")
            return
        }
        removeAnnotation(annotation, from: page)
    }

    // MARK: - Save Document

    /// Save a PDF document with its annotations.
    ///
    /// - Parameters:
    ///   - document: The document to save
    ///   - url: The file URL to save to
    /// - Throws: AnnotationError if save fails
    public func save(_ document: PDFDocument, to url: URL) throws {
        Logger.files.infoCapture("Saving PDF with annotations to: \(url.path)", category: "annotation")

        guard document.write(to: url) else {
            Logger.files.errorCapture("Failed to save PDF to: \(url.path)", category: "annotation")
            throw AnnotationError.saveFailed(url)
        }

        Logger.files.infoCapture("Successfully saved PDF with annotations", category: "annotation")
    }

    // MARK: - Query Annotations

    /// Get all annotations in a document.
    ///
    /// - Parameter document: The PDF document
    /// - Returns: Array of (page, annotation) tuples
    public func allAnnotations(in document: PDFDocument) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        var results: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            for annotation in page.annotations {
                // Filter out link annotations and other system annotations
                let userTypes: [PDFAnnotationSubtype] = [
                    .highlight, .underline, .strikeOut,
                    .text, .freeText, .ink, .line, .circle, .square
                ]

                if let type = annotation.type,
                   userTypes.contains(where: { $0.rawValue == type }) {
                    results.append((page: page, annotation: annotation))
                }
            }
        }

        return results
    }

    /// Get annotations of a specific type in a document.
    ///
    /// - Parameters:
    ///   - type: The annotation type to filter by
    ///   - document: The PDF document
    /// - Returns: Array of (page, annotation) tuples
    public func annotations(
        ofType type: PDFAnnotationSubtype,
        in document: PDFDocument
    ) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        allAnnotations(in: document).filter { item in
            item.annotation.type == type.rawValue
        }
    }

    /// Count annotations in a document.
    ///
    /// - Parameter document: The PDF document
    /// - Returns: Total count of user annotations
    public func annotationCount(in document: PDFDocument) -> Int {
        allAnnotations(in: document).count
    }

    /// Check if a document has any user annotations.
    ///
    /// - Parameter document: The PDF document
    /// - Returns: True if the document has annotations
    public func hasAnnotations(_ document: PDFDocument) -> Bool {
        annotationCount(in: document) > 0
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when user requests to highlight current selection
    static let highlightSelection = Notification.Name("highlightSelection")

    /// Posted when user requests to add a note at current selection
    static let addNoteAtSelection = Notification.Name("addNoteAtSelection")

    /// Posted when user requests to underline current selection
    static let underlineSelection = Notification.Name("underlineSelection")

    /// Posted when user requests to strikethrough current selection
    static let strikethroughSelection = Notification.Name("strikethroughSelection")

    /// Posted when annotations were modified (added/removed)
    static let annotationsDidChange = Notification.Name("annotationsDidChange")
}
