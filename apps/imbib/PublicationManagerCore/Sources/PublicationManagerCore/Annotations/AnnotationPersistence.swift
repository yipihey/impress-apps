//
//  AnnotationPersistence.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import PDFKit
import CoreData
import OSLog

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Annotation Persistence Service

/// Service for persisting PDF annotations to Core Data.
///
/// Bridges AnnotationService (PDFKit) with CDAnnotation (Core Data) for:
/// - CloudKit sync of annotations
/// - Searchable annotation index
/// - Annotation history across devices
@MainActor
public final class AnnotationPersistence {

    // MARK: - Singleton

    public static let shared = AnnotationPersistence()

    private let persistenceController: PersistenceController

    private init() {
        self.persistenceController = .shared
    }

    /// Initialize with custom persistence controller (for testing)
    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - Author Resolution

    /// Resolve the author name for a new annotation.
    /// For shared libraries, uses CloudKit participant display name.
    /// For private libraries, uses device name.
    private func resolveAuthorName(for linkedFile: CDLinkedFile) -> String {
        #if canImport(CloudKit)
        if let publication = linkedFile.publication,
           let library = publication.libraries?.first(where: { $0.isSharedLibrary }),
           let share = PersistenceController.shared.share(for: library),
           let participant = share.currentUserParticipant,
           let nameComponents = participant.userIdentity.nameComponents {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let name = formatter.string(from: nameComponents)
            if !name.isEmpty { return name }
        }
        #endif

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

    /// Save a PDFAnnotation to Core Data
    ///
    /// - Parameters:
    ///   - pdfAnnotation: The PDFKit annotation
    ///   - pageIndex: Page number (0-indexed)
    ///   - linkedFile: The linked file entity for this PDF
    ///   - selectedText: Optional text that was selected for markup annotations
    /// - Returns: The created CDAnnotation entity
    @discardableResult
    public func save(
        _ pdfAnnotation: PDFAnnotation,
        pageIndex: Int,
        linkedFile: CDLinkedFile,
        selectedText: String? = nil
    ) throws -> CDAnnotation {
        let context = persistenceController.viewContext

        let cdAnnotation = CDAnnotation(context: context)
        cdAnnotation.id = UUID()
        cdAnnotation.pageNumber = Int32(pageIndex)
        cdAnnotation.bounds = pdfAnnotation.bounds
        cdAnnotation.linkedFile = linkedFile
        cdAnnotation.dateCreated = Date()
        cdAnnotation.dateModified = Date()
        cdAnnotation.selectedText = selectedText

        // Map annotation type
        if let type = pdfAnnotation.type {
            switch type {
            case PDFAnnotationSubtype.highlight.rawValue:
                cdAnnotation.annotationType = CDAnnotation.AnnotationType.highlight.rawValue
            case PDFAnnotationSubtype.underline.rawValue:
                cdAnnotation.annotationType = CDAnnotation.AnnotationType.underline.rawValue
            case PDFAnnotationSubtype.strikeOut.rawValue:
                cdAnnotation.annotationType = CDAnnotation.AnnotationType.strikethrough.rawValue
            case PDFAnnotationSubtype.text.rawValue:
                cdAnnotation.annotationType = CDAnnotation.AnnotationType.note.rawValue
            case PDFAnnotationSubtype.freeText.rawValue:
                cdAnnotation.annotationType = CDAnnotation.AnnotationType.freeText.rawValue
            case PDFAnnotationSubtype.ink.rawValue:
                cdAnnotation.annotationType = CDAnnotation.AnnotationType.ink.rawValue
            default:
                cdAnnotation.annotationType = type
            }
        }

        // Save color as hex
        cdAnnotation.color = pdfAnnotation.color.hexString

        // Save contents
        cdAnnotation.contents = pdfAnnotation.contents

        // Set author (uses CloudKit participant name for shared libraries)
        cdAnnotation.author = resolveAuthorName(for: linkedFile)

        try context.save()

        Logger.files.debugCapture("Saved annotation to Core Data: \(cdAnnotation.annotationType) on page \(pageIndex)", category: "annotation-persistence")

        return cdAnnotation
    }

    // MARK: - Batch Save

    /// Save multiple PDFAnnotations to Core Data
    ///
    /// - Parameters:
    ///   - pdfAnnotations: Array of (annotation, pageIndex, selectedText) tuples
    ///   - linkedFile: The linked file entity
    /// - Returns: Array of created CDAnnotation entities
    @discardableResult
    public func saveAll(
        _ pdfAnnotations: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)],
        linkedFile: CDLinkedFile
    ) throws -> [CDAnnotation] {
        let context = persistenceController.viewContext
        let authorName = resolveAuthorName(for: linkedFile)

        var results: [CDAnnotation] = []

        for item in pdfAnnotations {
            let cdAnnotation = CDAnnotation(context: context)
            cdAnnotation.id = UUID()
            cdAnnotation.pageNumber = Int32(item.pageIndex)
            cdAnnotation.bounds = item.annotation.bounds
            cdAnnotation.linkedFile = linkedFile
            cdAnnotation.dateCreated = Date()
            cdAnnotation.dateModified = Date()
            cdAnnotation.selectedText = item.selectedText

            // Map type
            if let type = item.annotation.type {
                cdAnnotation.annotationType = mapAnnotationType(type)
            }

            // Color
            cdAnnotation.color = item.annotation.color.hexString

            // Contents
            cdAnnotation.contents = item.annotation.contents

            cdAnnotation.author = authorName

            results.append(cdAnnotation)
        }

        try context.save()

        Logger.files.infoCapture("Saved \(results.count) annotations to Core Data", category: "annotation-persistence")

        return results
    }

    // MARK: - Load Annotations

    /// Load all annotations for a linked file
    ///
    /// - Parameter linkedFile: The linked file entity
    /// - Returns: Array of CDAnnotation entities sorted by page and position
    public func loadAnnotations(for linkedFile: CDLinkedFile) -> [CDAnnotation] {
        linkedFile.sortedAnnotations
    }

    /// Load annotations and apply them to a PDFDocument
    ///
    /// - Parameters:
    ///   - linkedFile: The linked file entity
    ///   - document: The PDF document to apply annotations to
    public func applyAnnotations(
        from linkedFile: CDLinkedFile,
        to document: PDFDocument
    ) {
        let annotations = loadAnnotations(for: linkedFile)

        for cdAnnotation in annotations {
            let pageIndex = Int(cdAnnotation.pageNumber)
            guard let page = document.page(at: pageIndex) else {
                continue
            }

            // Create PDFAnnotation from CDAnnotation
            if let pdfAnnotation = createPDFAnnotation(from: cdAnnotation) {
                page.addAnnotation(pdfAnnotation)
            }
        }

        Logger.files.debugCapture("Applied \(annotations.count) annotations from Core Data to PDF", category: "annotation-persistence")
    }

    // MARK: - Delete Annotation

    /// Delete a CDAnnotation
    ///
    /// - Parameter annotation: The annotation to delete
    public func delete(_ annotation: CDAnnotation) throws {
        let context = persistenceController.viewContext
        context.delete(annotation)
        try context.save()

        Logger.files.debugCapture("Deleted annotation from Core Data", category: "annotation-persistence")
    }

    /// Delete all annotations for a linked file
    ///
    /// - Parameter linkedFile: The linked file
    public func deleteAllAnnotations(for linkedFile: CDLinkedFile) throws {
        let context = persistenceController.viewContext

        let annotations = linkedFile.annotations ?? []
        for annotation in annotations {
            context.delete(annotation)
        }

        try context.save()

        Logger.files.infoCapture("Deleted \(annotations.count) annotations from Core Data", category: "annotation-persistence")
    }

    // MARK: - Sync with PDF

    /// Sync Core Data annotations with actual PDF annotations.
    /// This reconciles any discrepancies between stored metadata and the PDF file.
    ///
    /// - Parameters:
    ///   - document: The PDF document
    ///   - linkedFile: The linked file entity
    public func syncWithPDF(document: PDFDocument, linkedFile: CDLinkedFile) throws {
        let context = persistenceController.viewContext

        // Get existing stored annotations
        var storedAnnotations = Set(linkedFile.annotations ?? [])

        // Track which stored annotations are still in the PDF
        var foundAnnotations: Set<CDAnnotation> = []

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
                    foundAnnotations.insert(match)
                } else {
                    // New annotation in PDF - save it
                    let newAnnotation = try save(pdfAnnotation, pageIndex: pageIndex, linkedFile: linkedFile)
                    foundAnnotations.insert(newAnnotation)
                }
            }
        }

        // Remove stored annotations that are no longer in the PDF
        let orphaned = storedAnnotations.subtracting(foundAnnotations)
        for annotation in orphaned {
            context.delete(annotation)
        }

        if !orphaned.isEmpty {
            try context.save()
            Logger.files.infoCapture("Removed \(orphaned.count) orphaned annotations from Core Data", category: "annotation-persistence")
        }
    }

    // MARK: - Helper Methods

    private func mapAnnotationType(_ pdfType: String) -> String {
        switch pdfType {
        case PDFAnnotationSubtype.highlight.rawValue:
            return CDAnnotation.AnnotationType.highlight.rawValue
        case PDFAnnotationSubtype.underline.rawValue:
            return CDAnnotation.AnnotationType.underline.rawValue
        case PDFAnnotationSubtype.strikeOut.rawValue:
            return CDAnnotation.AnnotationType.strikethrough.rawValue
        case PDFAnnotationSubtype.text.rawValue:
            return CDAnnotation.AnnotationType.note.rawValue
        case PDFAnnotationSubtype.freeText.rawValue:
            return CDAnnotation.AnnotationType.freeText.rawValue
        case PDFAnnotationSubtype.ink.rawValue:
            return CDAnnotation.AnnotationType.ink.rawValue
        default:
            return pdfType
        }
    }

    private func createPDFAnnotation(from cdAnnotation: CDAnnotation) -> PDFAnnotation? {
        guard let typeEnum = cdAnnotation.typeEnum else { return nil }

        let annotationType: PDFAnnotationSubtype
        switch typeEnum {
        case .highlight:
            annotationType = .highlight
        case .underline:
            annotationType = .underline
        case .strikethrough:
            annotationType = .strikeOut
        case .note:
            annotationType = .text
        case .freeText:
            annotationType = .freeText
        case .ink:
            annotationType = .ink
        }

        let pdfAnnotation = PDFAnnotation(
            bounds: cdAnnotation.bounds,
            forType: annotationType,
            withProperties: nil
        )

        // Set color
        if let hexColor = cdAnnotation.color,
           let color = PlatformColor(hex: hexColor) {
            pdfAnnotation.color = color
        }

        // Set contents
        pdfAnnotation.contents = cdAnnotation.contents

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
        in storedAnnotations: Set<CDAnnotation>
    ) -> CDAnnotation? {
        // Match by page, bounds, and type
        return storedAnnotations.first { stored in
            stored.pageNumber == Int32(pageIndex) &&
            abs(stored.bounds.origin.x - pdfAnnotation.bounds.origin.x) < 1 &&
            abs(stored.bounds.origin.y - pdfAnnotation.bounds.origin.y) < 1 &&
            abs(stored.bounds.width - pdfAnnotation.bounds.width) < 1 &&
            abs(stored.bounds.height - pdfAnnotation.bounds.height) < 1
        }
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

        #if os(macOS)
        return String(format: "#%02X%02X%02X", red, green, blue)
        #endif
    }
}

// MARK: - AnnotationService Integration

extension AnnotationService {

    /// Add highlight with persistence
    @discardableResult
    public func addHighlightWithPersistence(
        to pdfView: PDFView,
        color: HighlightColor = .yellow,
        linkedFile: CDLinkedFile?
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            return []
        }

        // Get selected text for storage
        let selectedText = selection.string

        // Create annotations
        let annotations = addHighlight(to: pdfView, color: color)

        // Persist if we have a linked file
        if let linkedFile = linkedFile, let document = pdfView.document {
            Task { @MainActor in
                let items: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)] = annotations.compactMap { annotation in
                    guard let page = annotation.page else {
                        return nil
                    }
                    let pageIndex = document.index(for: page)
                    return (annotation, pageIndex, selectedText)
                }

                try? await AnnotationPersistence.shared.saveAll(items, linkedFile: linkedFile)
            }
        }

        return annotations
    }

    /// Add underline with persistence
    @discardableResult
    public func addUnderlineWithPersistence(
        to pdfView: PDFView,
        color: PlatformColor = .systemRed,
        linkedFile: CDLinkedFile?
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            return []
        }

        let selectedText = selection.string
        let annotations = addUnderline(to: pdfView, color: color)

        if let linkedFile = linkedFile, let document = pdfView.document {
            Task { @MainActor in
                let items: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)] = annotations.compactMap { annotation in
                    guard let page = annotation.page else {
                        return nil
                    }
                    let pageIndex = document.index(for: page)
                    return (annotation, pageIndex, selectedText)
                }

                try? await AnnotationPersistence.shared.saveAll(items, linkedFile: linkedFile)
            }
        }

        return annotations
    }

    /// Add strikethrough with persistence
    @discardableResult
    public func addStrikethroughWithPersistence(
        to pdfView: PDFView,
        color: PlatformColor = .systemRed,
        linkedFile: CDLinkedFile?
    ) -> [PDFAnnotation] {
        guard let selection = pdfView.currentSelection else {
            return []
        }

        let selectedText = selection.string
        let annotations = addStrikethrough(to: pdfView, color: color)

        if let linkedFile = linkedFile, let document = pdfView.document {
            Task { @MainActor in
                let items: [(annotation: PDFAnnotation, pageIndex: Int, selectedText: String?)] = annotations.compactMap { annotation in
                    guard let page = annotation.page else {
                        return nil
                    }
                    let pageIndex = document.index(for: page)
                    return (annotation, pageIndex, selectedText)
                }

                try? await AnnotationPersistence.shared.saveAll(items, linkedFile: linkedFile)
            }
        }

        return annotations
    }

    /// Add text note with persistence
    @discardableResult
    public func addTextNoteWithPersistence(
        to page: PDFPage,
        at point: CGPoint,
        text: String,
        color: PlatformColor = .systemYellow,
        linkedFile: CDLinkedFile?,
        document: PDFDocument
    ) -> PDFAnnotation {
        let annotation = addTextNote(to: page, at: point, text: text, color: color)

        if let linkedFile = linkedFile {
            let pageIndex = document.index(for: page)
            Task { @MainActor in
                try? await AnnotationPersistence.shared.save(
                    annotation,
                    pageIndex: pageIndex,
                    linkedFile: linkedFile
                )
            }
        }

        return annotation
    }
}

// MARK: - CloudKit Sync Extension

extension AnnotationPersistence {

    /// Convert CDAnnotation to AnnotationData for sync
    private func toAnnotationData(_ cdAnnotation: CDAnnotation) -> AnnotationData {
        AnnotationData(
            id: cdAnnotation.id.uuidString,
            pageNumber: Int(cdAnnotation.pageNumber),
            type: cdAnnotation.annotationType,
            bounds: cdAnnotation.bounds,
            color: cdAnnotation.color ?? "#FFFF00",
            content: cdAnnotation.contents,
            dateCreated: cdAnnotation.dateCreated,
            dateModified: cdAnnotation.dateModified
        )
    }

    /// Export annotations as JSON for CloudKit sync
    ///
    /// - Parameter linkedFile: The linked file to export annotations for
    /// - Returns: JSON string representation of annotations, or nil on failure
    public func exportForSync(linkedFile: CDLinkedFile) -> String? {
        let cdAnnotations = loadAnnotations(for: linkedFile)
        let data = cdAnnotations.map { toAnnotationData($0) }
        switch RustAnnotationsBridge.serialize(data) {
        case .success(let json):
            Logger.files.debugCapture("Exported \(cdAnnotations.count) annotations for sync", category: "annotation-sync")
            return json
        case .failure(let error):
            Logger.files.errorCapture("Failed to export annotations for sync: \(error)", category: "annotation-sync")
            return nil
        }
    }

    /// Import annotations from CloudKit JSON
    ///
    /// Merges remote annotations with local annotations and saves the result.
    ///
    /// - Parameters:
    ///   - json: JSON string from CloudKit
    ///   - linkedFile: The linked file to import annotations into
    public func importFromSync(json: String, linkedFile: CDLinkedFile) {
        switch RustAnnotationsBridge.deserialize(json) {
        case .success(let remoteAnnotations):
            // Get existing local annotations
            let localAnnotations = loadAnnotations(for: linkedFile).map { toAnnotationData($0) }

            // Merge local and remote
            let merged = RustAnnotationsBridge.merge(local: localAnnotations, remote: remoteAnnotations)

            // Save merged annotations
            do {
                try saveFromSync(merged, linkedFile: linkedFile)
                Logger.files.infoCapture("Imported and merged \(merged.count) annotations from sync", category: "annotation-sync")
            } catch {
                Logger.files.errorCapture("Failed to save merged annotations: \(error)", category: "annotation-sync")
            }

        case .failure(let error):
            Logger.files.errorCapture("Failed to deserialize annotations from sync: \(error)", category: "annotation-sync")
        }
    }

    /// Save annotations from sync data
    ///
    /// - Parameters:
    ///   - annotations: Array of AnnotationData from sync
    ///   - linkedFile: The linked file to save to
    private func saveFromSync(_ annotations: [AnnotationData], linkedFile: CDLinkedFile) throws {
        let context = persistenceController.viewContext

        // Delete existing annotations
        let existingAnnotations = linkedFile.annotations ?? []
        for annotation in existingAnnotations {
            context.delete(annotation)
        }

        // Create new annotations from sync data
        for data in annotations {
            let cdAnnotation = CDAnnotation(context: context)
            cdAnnotation.id = UUID(uuidString: data.id) ?? UUID()
            cdAnnotation.pageNumber = Int32(data.pageNumber)
            cdAnnotation.annotationType = data.type
            cdAnnotation.color = data.color
            cdAnnotation.contents = data.content
            cdAnnotation.dateCreated = data.dateCreated
            cdAnnotation.dateModified = data.dateModified
            cdAnnotation.linkedFile = linkedFile

            // Set bounds from first rect (primary bounds)
            if let firstRect = data.bounds.first {
                cdAnnotation.bounds = firstRect.cgRect
            }
        }

        try context.save()
    }
}
