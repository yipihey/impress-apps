//
//  AnnotationPersistence.swift
//  PublicationManagerCore
//
//  Service for persisting PDF annotations via RustStoreAdapter.
//
//  Bridges AnnotationService (PDFKit) with AnnotationModel (domain) for:
//  - Searchable annotation index
//  - Annotation history across devices
//

import Foundation
import PDFKit
import OSLog

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Annotation Persistence Service

/// Service for persisting PDF annotations to the Rust store.
///
/// Bridges AnnotationService (PDFKit) with AnnotationModel (domain) for:
/// - Searchable annotation index
/// - Annotation history across devices
@MainActor
public final class AnnotationPersistence {

    // MARK: - Singleton

    public static let shared = AnnotationPersistence()

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    private init() {}

    // MARK: - Author Resolution

    /// Resolve the author name for a new annotation.
    /// Uses device name as the default.
    private func resolveAuthorName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Unknown"
        #else
        return UIDevice.current.name
        #endif
    }

    // MARK: - Author Color Assignment

    /// Palette of colors assigned to different authors in shared libraries
    private static let authorColorPalette: [HighlightColor] = [.blue, .green, .pink, .purple, .orange, .yellow]

    /// Get the assigned color for an author in a shared library context.
    /// Colors are deterministically assigned based on author name hash.
    public func authorColor(for authorName: String) -> HighlightColor {
        let hash = abs(authorName.hashValue)
        let index = hash % Self.authorColorPalette.count
        return Self.authorColorPalette[index]
    }

    // MARK: - Save Annotation

    /// Save a PDFAnnotation to the store.
    ///
    /// - Parameters:
    ///   - pdfAnnotation: The PDFKit annotation
    ///   - pageIndex: Page number (0-indexed)
    ///   - linkedFileID: The UUID of the linked file for this PDF
    ///   - selectedText: Optional text that was selected for markup annotations
    /// - Returns: The created AnnotationModel, or nil on failure
    @discardableResult
    public func save(
        _ pdfAnnotation: PDFAnnotation,
        pageIndex: Int,
        linkedFileID: UUID,
        selectedText: String? = nil
    ) -> AnnotationModel? {
        // Map annotation type
        let annotationType: String
        if let type = pdfAnnotation.type {
            annotationType = mapAnnotationType(type)
        } else {
            annotationType = "unknown"
        }

        // Encode bounds as JSON
        let boundsJson = encodeBounds(pdfAnnotation.bounds)

        let result = store.createAnnotation(
            linkedFileId: linkedFileID,
            annotationType: annotationType,
            pageNumber: Int64(pageIndex),
            boundsJson: boundsJson,
            color: pdfAnnotation.color.hexString,
            contents: pdfAnnotation.contents,
            selectedText: selectedText
        )

        if result != nil {
            Logger.files.debugCapture("Saved annotation to store: \(annotationType) on page \(pageIndex)", category: "annotation-persistence")
        }

        return result
    }

    // MARK: - Batch Save

    /// Save multiple PDFAnnotations to the store.
    ///
    /// - Parameters:
    ///   - pdfAnnotations: Array of (annotation, pageIndex, selectedText) tuples
    ///   - linkedFileID: The UUID of the linked file
    /// - Returns: Array of created AnnotationModel entities
    @discardableResult
    public func saveAll(
        _ pdfAnnotations: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)],
        linkedFileID: UUID
    ) -> [AnnotationModel] {
        var results: [AnnotationModel] = []

        for item in pdfAnnotations {
            if let model = save(
                item.annotation,
                pageIndex: item.pageIndex,
                linkedFileID: linkedFileID,
                selectedText: item.selectedText
            ) {
                results.append(model)
            }
        }

        Logger.files.infoCapture("Saved \(results.count) annotations to store", category: "annotation-persistence")

        return results
    }

    // MARK: - Load Annotations

    /// Load all annotations for a linked file.
    ///
    /// - Parameter linkedFileID: The UUID of the linked file
    /// - Returns: Array of AnnotationModel sorted by page and position
    public func loadAnnotations(for linkedFileID: UUID) -> [AnnotationModel] {
        store.listAnnotations(linkedFileId: linkedFileID)
    }

    /// Load annotations and apply them to a PDFDocument.
    ///
    /// - Parameters:
    ///   - linkedFileID: The UUID of the linked file
    ///   - document: The PDF document to apply annotations to
    public func applyAnnotations(
        from linkedFileID: UUID,
        to document: PDFDocument
    ) {
        let annotations = loadAnnotations(for: linkedFileID)

        for annotation in annotations {
            let pageIndex = annotation.pageNumber
            guard let page = document.page(at: pageIndex) else {
                continue
            }

            // Create PDFAnnotation from AnnotationModel
            if let pdfAnnotation = createPDFAnnotation(from: annotation) {
                page.addAnnotation(pdfAnnotation)
            }
        }

        Logger.files.debugCapture("Applied \(annotations.count) annotations from store to PDF", category: "annotation-persistence")
    }

    // MARK: - Delete Annotation

    /// Delete an annotation by ID.
    ///
    /// - Parameter annotationID: The UUID of the annotation to delete
    public func delete(annotationID: UUID) {
        store.deleteItem(id: annotationID)
        Logger.files.debugCapture("Deleted annotation from store", category: "annotation-persistence")
    }

    /// Delete all annotations for a linked file.
    ///
    /// - Parameter linkedFileID: The UUID of the linked file
    public func deleteAllAnnotations(for linkedFileID: UUID) {
        let annotations = loadAnnotations(for: linkedFileID)
        for annotation in annotations {
            store.deleteItem(id: annotation.id)
        }
        Logger.files.infoCapture("Deleted \(annotations.count) annotations from store", category: "annotation-persistence")
    }

    // MARK: - Sync with PDF

    /// Sync store annotations with actual PDF annotations.
    /// This reconciles any discrepancies between stored metadata and the PDF file.
    ///
    /// - Parameters:
    ///   - document: The PDF document
    ///   - linkedFileID: The UUID of the linked file
    public func syncWithPDF(document: PDFDocument, linkedFileID: UUID) {
        // Get existing stored annotations
        let storedAnnotations = loadAnnotations(for: linkedFileID)
        var matchedIDs: Set<UUID> = []

        // Scan PDF for annotations
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            for pdfAnnotation in page.annotations {
                // Skip non-user annotations (links, etc.)
                guard isUserAnnotation(pdfAnnotation) else { continue }

                // Try to find matching stored annotation
                if let match = findMatching(
                    pdfAnnotation: pdfAnnotation,
                    pageIndex: pageIndex,
                    in: storedAnnotations
                ) {
                    matchedIDs.insert(match.id)
                } else {
                    // New annotation in PDF - save it
                    if let newAnnotation = save(pdfAnnotation, pageIndex: pageIndex, linkedFileID: linkedFileID) {
                        matchedIDs.insert(newAnnotation.id)
                    }
                }
            }
        }

        // Remove stored annotations that are no longer in the PDF
        let orphanedCount = storedAnnotations.filter { !matchedIDs.contains($0.id) }.count
        for annotation in storedAnnotations where !matchedIDs.contains(annotation.id) {
            store.deleteItem(id: annotation.id)
        }

        if orphanedCount > 0 {
            Logger.files.infoCapture("Removed \(orphanedCount) orphaned annotations from store", category: "annotation-persistence")
        }
    }

    // MARK: - Helper Methods

    private func mapAnnotationType(_ pdfType: String) -> String {
        switch pdfType {
        case PDFAnnotationSubtype.highlight.rawValue:
            return "highlight"
        case PDFAnnotationSubtype.underline.rawValue:
            return "underline"
        case PDFAnnotationSubtype.strikeOut.rawValue:
            return "strikethrough"
        case PDFAnnotationSubtype.text.rawValue:
            return "note"
        case PDFAnnotationSubtype.freeText.rawValue:
            return "freeText"
        case PDFAnnotationSubtype.ink.rawValue:
            return "ink"
        default:
            return pdfType
        }
    }

    private func createPDFAnnotation(from annotation: AnnotationModel) -> PDFAnnotation? {
        let annotationType: PDFAnnotationSubtype
        switch annotation.annotationType {
        case "highlight":
            annotationType = .highlight
        case "underline":
            annotationType = .underline
        case "strikethrough":
            annotationType = .strikeOut
        case "note":
            annotationType = .text
        case "freeText":
            annotationType = .freeText
        case "ink":
            annotationType = .ink
        default:
            return nil
        }

        // Decode bounds from JSON
        let bounds: CGRect
        if let boundsJSON = annotation.boundsJSON {
            bounds = decodeBounds(boundsJSON) ?? .zero
        } else {
            bounds = .zero
        }

        let pdfAnnotation = PDFAnnotation(
            bounds: bounds,
            forType: annotationType,
            withProperties: nil
        )

        // Set color
        if let hexColor = annotation.color,
           let color = PlatformColor(hex: hexColor) {
            pdfAnnotation.color = color
        }

        // Set contents
        pdfAnnotation.contents = annotation.contents

        return pdfAnnotation
    }

    private func isUserAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let userTypes: [PDFAnnotationSubtype] = [
            .highlight, .underline, .strikeOut,
            .text, .freeText, .ink, .line, .circle, .square
        ]

        guard let type = annotation.type else { return false }
        return userTypes.contains { $0.rawValue == type }
    }

    private func findMatching(
        pdfAnnotation: PDFAnnotation,
        pageIndex: Int,
        in storedAnnotations: [AnnotationModel]
    ) -> AnnotationModel? {
        return storedAnnotations.first { stored in
            stored.pageNumber == pageIndex &&
            boundsMatch(stored: stored.boundsJSON, pdf: pdfAnnotation.bounds)
        }
    }

    private func boundsMatch(stored boundsJSON: String?, pdf pdfBounds: CGRect) -> Bool {
        guard let json = boundsJSON, let storedBounds = decodeBounds(json) else {
            return false
        }
        return abs(storedBounds.origin.x - pdfBounds.origin.x) < 1 &&
            abs(storedBounds.origin.y - pdfBounds.origin.y) < 1 &&
            abs(storedBounds.width - pdfBounds.width) < 1 &&
            abs(storedBounds.height - pdfBounds.height) < 1
    }

    private func encodeBounds(_ rect: CGRect) -> String {
        "{\"x\":\(rect.origin.x),\"y\":\(rect.origin.y),\"width\":\(rect.width),\"height\":\(rect.height)}"
    }

    private func decodeBounds(_ json: String) -> CGRect? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = dict["x"],
              let y = dict["y"],
              let width = dict["width"],
              let height = dict["height"] else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Color Extensions

extension PlatformColor {
    /// Create color from hex string
    convenience init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)

        let red = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let green = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let blue = CGFloat(rgb & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }

    /// Convert color to hex string
    var hexString: String {
        #if os(macOS)
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let red = Int(rgbColor.redComponent * 255)
        let green = Int(rgbColor.greenComponent * 255)
        let blue = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redInt = Int(red * 255)
        let greenInt = Int(green * 255)
        let blueInt = Int(blue * 255)
        return String(format: "#%02X%02X%02X", redInt, greenInt, blueInt)
        #endif
    }
}

// MARK: - AnnotationService Integration

extension AnnotationService {

    /// Add highlight with persistence.
    @discardableResult
    public func addHighlightWithPersistence(
        to pdfView: PDFView,
        color: HighlightColor = .yellow,
        linkedFileID: UUID?
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            return []
        }

        // Get selected text for storage
        let selectedText = selection.string

        // Create annotations
        let annotations = addHighlight(to: pdfView, color: color)

        // Persist if we have a linked file ID
        if let linkedFileID, let document = pdfView.document {
            Task { @MainActor in
                let items: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)] = annotations.compactMap { annotation in
                    guard let page = annotation.page else {
                        return nil
                    }
                    let pageIndex = document.index(for: page)
                    return (annotation, pageIndex, selectedText)
                }

                AnnotationPersistence.shared.saveAll(items, linkedFileID: linkedFileID)
            }
        }

        return annotations
    }

    /// Add underline with persistence.
    @discardableResult
    public func addUnderlineWithPersistence(
        to pdfView: PDFView,
        color: PlatformColor = .systemRed,
        linkedFileID: UUID?
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            return []
        }

        let selectedText = selection.string
        let annotations = addUnderline(to: pdfView, color: color)

        if let linkedFileID, let document = pdfView.document {
            Task { @MainActor in
                let items: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)] = annotations.compactMap { annotation in
                    guard let page = annotation.page else {
                        return nil
                    }
                    let pageIndex = document.index(for: page)
                    return (annotation, pageIndex, selectedText)
                }

                AnnotationPersistence.shared.saveAll(items, linkedFileID: linkedFileID)
            }
        }

        return annotations
    }

    /// Add strikethrough with persistence.
    @discardableResult
    public func addStrikethroughWithPersistence(
        to pdfView: PDFView,
        color: PlatformColor = .systemRed,
        linkedFileID: UUID?
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            return []
        }

        let selectedText = selection.string
        let annotations = addStrikethrough(to: pdfView, color: color)

        if let linkedFileID, let document = pdfView.document {
            Task { @MainActor in
                let items: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)] = annotations.compactMap { annotation in
                    guard let page = annotation.page else {
                        return nil
                    }
                    let pageIndex = document.index(for: page)
                    return (annotation, pageIndex, selectedText)
                }

                AnnotationPersistence.shared.saveAll(items, linkedFileID: linkedFileID)
            }
        }

        return annotations
    }

    /// Add text note with persistence.
    @discardableResult
    public func addTextNoteWithPersistence(
        to page: PDFPage,
        at point: CGPoint,
        text: String,
        color: PlatformColor = .systemYellow,
        linkedFileID: UUID?,
        document: PDFDocument
    ) -> PDFAnnotation {
        let annotation = addTextNote(to: page, at: point, text: text, color: color)

        if let linkedFileID {
            let pageIndex = document.index(for: page)
            Task { @MainActor in
                AnnotationPersistence.shared.save(
                    annotation,
                    pageIndex: pageIndex,
                    linkedFileID: linkedFileID
                )
            }
        }

        return annotation
    }
}

// MARK: - Sync Extension

extension AnnotationPersistence {

    /// Convert AnnotationModel to AnnotationData for sync.
    private func toAnnotationData(_ annotation: AnnotationModel) -> AnnotationData {
        AnnotationData(
            id: annotation.id.uuidString,
            pageNumber: annotation.pageNumber,
            type: annotation.annotationType,
            bounds: annotation.boundsJSON.flatMap { decodeBounds($0) }.map { [AnnotationRect(from: $0)] } ?? [],
            color: annotation.color ?? "#FFFF00",
            content: annotation.contents,
            dateCreated: annotation.dateCreated,
            dateModified: annotation.dateModified
        )
    }

    /// Export annotations as JSON for sync.
    ///
    /// - Parameter linkedFileID: The UUID of the linked file to export annotations for
    /// - Returns: JSON string representation of annotations, or nil on failure
    public func exportForSync(linkedFileID: UUID) -> String? {
        let annotations = loadAnnotations(for: linkedFileID)
        let data = annotations.map { toAnnotationData($0) }
        switch RustAnnotationsBridge.serialize(data) {
        case .success(let json):
            Logger.files.debugCapture("Exported \(annotations.count) annotations for sync", category: "annotation-sync")
            return json
        case .failure(let error):
            Logger.files.errorCapture("Failed to export annotations for sync: \(error)", category: "annotation-sync")
            return nil
        }
    }

    /// Import annotations from sync JSON.
    ///
    /// Merges remote annotations with local annotations and saves the result.
    ///
    /// - Parameters:
    ///   - json: JSON string from sync
    ///   - linkedFileID: The UUID of the linked file to import annotations into
    public func importFromSync(json: String, linkedFileID: UUID) {
        switch RustAnnotationsBridge.deserialize(json) {
        case .success(let remoteAnnotations):
            // Get existing local annotations
            let localAnnotations = loadAnnotations(for: linkedFileID).map { toAnnotationData($0) }

            // Merge local and remote
            let merged = RustAnnotationsBridge.merge(local: localAnnotations, remote: remoteAnnotations)

            // Delete existing and recreate from merged data
            deleteAllAnnotations(for: linkedFileID)

            for data in merged {
                let bounds = data.bounds.first.map { encodeBounds($0.cgRect) }
                _ = store.createAnnotation(
                    linkedFileId: linkedFileID,
                    annotationType: data.type,
                    pageNumber: Int64(data.pageNumber),
                    boundsJson: bounds,
                    color: data.color,
                    contents: data.content,
                    selectedText: nil
                )
            }

            Logger.files.infoCapture("Imported and merged \(merged.count) annotations from sync", category: "annotation-sync")

        case .failure(let error):
            Logger.files.errorCapture("Failed to deserialize annotations from sync: \(error)", category: "annotation-sync")
        }
    }
}
