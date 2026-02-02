//
//  DragDropCoordinator.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import OSLog
import CoreData

// MARK: - Drag Drop Coordinator

/// Central coordinator for all drag-and-drop operations.
///
/// Routes drops to the appropriate handler based on content type and target:
/// - PDF files → PDFImportHandler (creates publications)
/// - .bib/.ris files → BibDropHandler (batch import)
/// - Publication UUIDs → move/copy between libraries/collections
/// - Other files → FileDropHandler (attach to publications)
@MainActor
@Observable
public final class DragDropCoordinator {

    // MARK: - Singleton

    public static let shared = DragDropCoordinator()

    // MARK: - Observable State

    /// Whether a drop operation is being processed
    public var isProcessing = false

    /// Pending preview data for user confirmation
    public var pendingPreview: DropPreviewData?

    /// Current target being hovered
    public var currentTarget: DropTarget?

    /// Last error that occurred
    public var lastError: Error?

    // MARK: - Handlers

    private let fileDropHandler: FileDropHandler
    private let pdfImportHandler: PDFImportHandler
    private let bibDropHandler: BibDropHandler

    // MARK: - Initialization

    public init(
        fileDropHandler: FileDropHandler? = nil,
        pdfImportHandler: PDFImportHandler? = nil,
        bibDropHandler: BibDropHandler? = nil
    ) {
        self.fileDropHandler = fileDropHandler ?? FileDropHandler()
        self.pdfImportHandler = pdfImportHandler ?? .shared
        self.bibDropHandler = bibDropHandler ?? .shared
    }

    // MARK: - UTTypes

    /// All UTTypes accepted for drops
    public static let acceptedTypes: [UTType] = [
        .publicationID,     // Internal publication transfer
        .fileURL,           // File URLs
        .pdf,               // PDFs explicitly
        .item,              // Generic items
        .data,              // Raw data
    ]

    /// UTTypes for bibliography files
    public static let bibTypes: [UTType] = [
        UTType(filenameExtension: "bib") ?? .plainText,
        UTType(filenameExtension: "ris") ?? .plainText,
    ]

    // MARK: - Validation

    /// Validate a drop operation from SwiftUI DropInfo.
    ///
    /// - Parameters:
    ///   - info: Drop info from SwiftUI
    ///   - target: The drop target
    /// - Returns: Validation result with badge info
    public func validateDrop(_ info: SwiftUI.DropInfo, target: DropTarget) -> DropValidation {
        let dragDropInfo = DragDropInfo(providers: Array(info.itemProviders(for: Self.acceptedTypes)))
        return validateDrop(dragDropInfo, target: target)
    }

    /// Validate a drop operation from DragDropInfo.
    ///
    /// - Parameters:
    ///   - info: DragDrop info with providers
    ///   - target: The drop target
    /// - Returns: Validation result with badge info
    public func validateDrop(_ info: DragDropInfo, target: DropTarget) -> DropValidation {
        // Categorize dropped items
        let category = categorizeDropInfo(info)
        let counts = countDroppedFiles(info)

        // Check if target accepts this category
        switch (category, target) {
        case (.publicationTransfer, .library), (.publicationTransfer, .collection):
            // Publication transfers to libraries/collections are valid
            let count = counts[.publicationTransfer] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Add \(count)" : "Add",
                badgeIcon: "plus.circle.fill"
            )

        case (.pdf, .library), (.pdf, .collection), (.pdf, .inbox):
            // PDFs can create new publications in libraries/collections
            let count = counts[.pdf] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Import \(count) PDFs" : "Import PDF",
                badgeIcon: "doc.badge.plus"
            )

        case (.pdf, .publication):
            // PDFs can be attached to existing publications
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: "Attach",
                badgeIcon: "paperclip"
            )

        case (.bibtex, .library), (.bibtex, .collection), (.bibtex, .inbox):
            // BibTeX files can be imported to libraries
            let count = counts[.bibtex] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Import \(count) files" : "Import BibTeX",
                badgeIcon: "doc.text.fill"
            )

        case (.ris, .library), (.ris, .collection), (.ris, .inbox):
            // RIS files can be imported to libraries
            let count = counts[.ris] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Import \(count) files" : "Import RIS",
                badgeIcon: "doc.text.fill"
            )

        case (.attachment, .publication):
            // Generic files can be attached to publications
            let total = counts.values.reduce(0, +)
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: total > 1 ? "Attach \(total)" : "Attach",
                badgeIcon: "paperclip"
            )

        case (_, .newLibraryZone):
            // Files can create a new library
            if category == .pdf || category == .bibtex || category == .ris {
                return DropValidation(
                    isValid: true,
                    category: category,
                    fileCounts: counts,
                    badgeText: "New Library",
                    badgeIcon: "building.columns.fill"
                )
            }
            return .invalid

        default:
            return .invalid
        }
    }

    // MARK: - Drop Handling

    /// Perform a drop operation from SwiftUI DropInfo.
    ///
    /// - Parameters:
    ///   - info: Drop info from SwiftUI
    ///   - target: The drop target
    /// - Returns: Result of the drop operation
    @discardableResult
    public func performDrop(_ info: SwiftUI.DropInfo, target: DropTarget) async -> DropResult {
        let dragDropInfo = DragDropInfo(providers: Array(info.itemProviders(for: Self.acceptedTypes)))
        return await performDrop(dragDropInfo, target: target)
    }

    /// Perform a drop operation from DragDropInfo.
    ///
    /// - Parameters:
    ///   - info: DragDrop info with providers
    ///   - target: The drop target
    /// - Returns: Result of the drop operation
    @discardableResult
    public func performDrop(_ info: DragDropInfo, target: DropTarget) async -> DropResult {
        Logger.files.infoCapture("Performing drop on target: \(String(describing: target))", category: "files")

        isProcessing = true
        lastError = nil

        defer {
            isProcessing = false
            currentTarget = nil
        }

        let category = categorizeDropInfo(info)

        do {
            switch category {
            case .publicationTransfer:
                return try await handlePublicationTransfer(info: info, target: target)

            case .pdf:
                return try await handlePDFDrop(info: info, target: target)

            case .bibtex, .ris:
                return try await handleBibDrop(info: info, target: target)

            case .attachment:
                return try await handleAttachmentDrop(info: info, target: target)

            case .unknown:
                Logger.files.warningCapture("Unknown drop category", category: "files")
                return .failure(error: DragDropError.unsupportedContent)
            }
        } catch {
            Logger.files.errorCapture("Drop failed: \(error.localizedDescription)", category: "files")
            lastError = error
            return .failure(error: error)
        }
    }

    // MARK: - Category Detection

    /// Categorize dropped items by type.
    private func categorizeDropInfo(_ info: DragDropInfo) -> DroppedFileCategory {
        let providers = info.providers

        // Check for publication transfer first
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) }) {
            return .publicationTransfer
        }

        // Check file types
        for provider in providers {
            // Check for PDF
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                return .pdf
            }

            // Check for BibTeX/RIS by suggested filename
            if let filename = provider.suggestedName?.lowercased() {
                if filename.hasSuffix(".bib") || filename.hasSuffix(".bibtex") {
                    return .bibtex
                }
                if filename.hasSuffix(".ris") {
                    return .ris
                }
            }

            // Check file URL type
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // Will need to check actual file to determine type
                return .unknown  // Will be refined when URL is loaded
            }
        }

        // Default to attachment
        if !providers.isEmpty {
            return .attachment
        }

        return .unknown
    }

    /// Count files by category.
    private func countDroppedFiles(_ info: DragDropInfo) -> [DroppedFileCategory: Int] {
        var counts: [DroppedFileCategory: Int] = [:]
        let providers = info.providers

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) {
                counts[.publicationTransfer, default: 0] += 1
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                counts[.pdf, default: 0] += 1
            } else if let filename = provider.suggestedName?.lowercased() {
                if filename.hasSuffix(".bib") || filename.hasSuffix(".bibtex") {
                    counts[.bibtex, default: 0] += 1
                } else if filename.hasSuffix(".ris") {
                    counts[.ris, default: 0] += 1
                } else {
                    counts[.attachment, default: 0] += 1
                }
            } else {
                counts[.attachment, default: 0] += 1
            }
        }

        return counts
    }

    // MARK: - Handler Dispatch

    /// Handle publication UUID transfer.
    private func handlePublicationTransfer(info: DragDropInfo, target: DropTarget) async throws -> DropResult {
        let providers = info.providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) }
        var uuids: [UUID] = []

        for provider in providers {
            let extracted = await extractPublicationIDs(from: provider)
            uuids.append(contentsOf: extracted)
        }

        guard !uuids.isEmpty else {
            throw DragDropError.noPublicationsFound
        }

        switch target {
        case .library(let libraryID):
            await addPublicationsToLibrary(uuids, libraryID: libraryID)
            return .success(message: "Added \(uuids.count) publication(s) to library")

        case .collection(let collectionID, _):
            await addPublicationsToCollection(uuids, collectionID: collectionID)
            return .success(message: "Added \(uuids.count) publication(s) to collection")

        default:
            throw DragDropError.invalidTarget
        }
    }

    /// Handle PDF file drop.
    private func handlePDFDrop(info: DragDropInfo, target: DropTarget) async throws -> DropResult {
        let urls = await extractFileURLs(from: info, matching: ["pdf"])

        guard !urls.isEmpty else {
            throw DragDropError.noFilesFound
        }

        switch target {
        case .publication(let publicationID, let libraryID):
            // Attach PDF to existing publication
            return try await attachFilesToPublication(urls, publicationID: publicationID, libraryID: libraryID)

        case .library(let libraryID), .collection(_, let libraryID):
            // Create new publications from PDFs
            let previews = await pdfImportHandler.preparePDFImport(urls: urls, target: target)

            if previews.isEmpty {
                throw DragDropError.noFilesFound
            }

            // Show preview for user confirmation
            pendingPreview = .pdfImport(previews)
            return .needsConfirmation

        case .inbox:
            // Import to inbox library
            guard let inboxLibrary = InboxManager.shared.inboxLibrary else {
                throw DragDropError.noInboxLibrary
            }
            let previews = await pdfImportHandler.preparePDFImport(urls: urls, target: .library(libraryID: inboxLibrary.id))
            if previews.isEmpty {
                throw DragDropError.noFilesFound
            }
            pendingPreview = .pdfImport(previews)
            return .needsConfirmation

        case .newLibraryZone:
            // Create new library and import
            throw DragDropError.notImplemented("New library from PDF drop")
        }
    }

    /// Handle BibTeX/RIS file drop.
    private func handleBibDrop(info: DragDropInfo, target: DropTarget) async throws -> DropResult {
        let urls = await extractFileURLs(from: info, matching: ["bib", "bibtex", "ris"])

        guard let url = urls.first else {
            throw DragDropError.noFilesFound
        }

        let preview = try await bibDropHandler.prepareBibImport(url: url, target: target)

        // Show preview for user confirmation
        pendingPreview = .bibImport(preview)
        return .needsConfirmation
    }

    /// Handle generic attachment drop.
    private func handleAttachmentDrop(info: DragDropInfo, target: DropTarget) async throws -> DropResult {
        guard case .publication(let publicationID, let libraryID) = target else {
            throw DragDropError.invalidTarget
        }

        let urls = await extractFileURLs(from: info, matching: nil)

        guard !urls.isEmpty else {
            throw DragDropError.noFilesFound
        }

        return try await attachFilesToPublication(urls, publicationID: publicationID, libraryID: libraryID)
    }

    // MARK: - Confirmation Actions

    /// Confirm and execute a pending PDF import.
    /// - Returns: Array of created/affected publication UUIDs
    @discardableResult
    public func confirmPDFImport(_ previews: [PDFImportPreview], to libraryID: UUID) async throws -> [UUID] {
        isProcessing = true
        defer {
            isProcessing = false
            pendingPreview = nil
        }

        var importedIDs: [UUID] = []

        for preview in previews where preview.selectedAction != .skip {
            if let pubID = try await pdfImportHandler.commitImport(preview, to: libraryID) {
                importedIDs.append(pubID)
            }
        }

        // Post notification with imported publication IDs for UI to respond
        if !importedIDs.isEmpty {
            NotificationCenter.default.post(
                name: .pdfImportCompleted,
                object: importedIDs
            )
        }

        return importedIDs
    }

    /// Confirm and execute a pending BibTeX/RIS import.
    public func confirmBibImport(_ preview: BibImportPreview, to libraryID: UUID) async throws {
        isProcessing = true
        defer {
            isProcessing = false
            pendingPreview = nil
        }

        try await bibDropHandler.commitImport(preview, to: libraryID)
    }

    /// Cancel a pending import.
    public func cancelImport() {
        pendingPreview = nil
    }

    // MARK: - Metadata Lookup

    /// Look up metadata from online sources using provided identifiers or title/author.
    ///
    /// This is used by the import preview to allow users to re-lookup metadata
    /// after correcting extracted values.
    ///
    /// - Parameters:
    ///   - doi: DOI to look up
    ///   - arxivID: arXiv ID to look up
    ///   - title: Title for title-based search
    ///   - authors: Authors for title-based search
    ///   - year: Year for title-based search
    /// - Returns: Enriched metadata if found, nil otherwise
    public func lookupMetadata(
        doi: String?,
        arxivID: String?,
        title: String?,
        authors: [String],
        year: Int?
    ) async throws -> EnrichedMetadata? {
        Logger.files.info("Manual lookup requested - DOI: \(doi ?? "none"), arXiv: \(arxivID ?? "none"), title: \(title ?? "none")")

        // 1. Try DOI lookup first (most reliable)
        if let doi, !doi.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromCrossrefDOI(doi) {
                return enriched
            }
        }

        // 2. Try arXiv lookup
        if let arxivID, !arxivID.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromArXiv(arxivID) {
                return enriched
            }
        }

        // 3. Try ADS search by title/author/year
        if let title, !title.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromADSSearch(
                title: title,
                authors: authors,
                year: year,
                abstract: nil
            ) {
                return enriched
            }
        }

        // 4. Try Crossref title search as fallback
        if let title, !title.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromTitleSearch(title, authors: authors) {
                return enriched
            }
        }

        return nil
    }

    // MARK: - Helper Methods

    /// Extract publication UUIDs from a provider.
    /// Supports both JSON array format (multi-selection) and single UUID string (legacy).
    private func extractPublicationIDs(from provider: NSItemProvider) async -> [UUID] {
        guard provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) else {
            return []
        }

        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, _ in
                guard let data else {
                    continuation.resume(returning: [])
                    return
                }

                // Try to decode as JSON array of UUID strings first (multi-selection)
                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    let uuids = uuidStrings.compactMap { UUID(uuidString: $0) }
                    continuation.resume(returning: uuids)
                    return
                }

                // Fallback: try single UUID (legacy Codable format)
                if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    continuation.resume(returning: [uuid])
                    return
                }

                // Fallback: try single UUID string (legacy string format)
                if let idString = String(data: data, encoding: .utf8),
                   let uuid = UUID(uuidString: idString) {
                    continuation.resume(returning: [uuid])
                    return
                }

                continuation.resume(returning: [])
            }
        }
    }

    /// Extract file URLs from drop info.
    private func extractFileURLs(from info: DragDropInfo, matching extensions: [String]?) async -> [URL] {
        let providers = info.providers
        var urls: [URL] = []

        for provider in providers {
            if let url = await extractURL(from: provider) {
                // Filter by extension if specified
                if let extensions {
                    let ext = url.pathExtension.lowercased()
                    if extensions.contains(ext) {
                        urls.append(url)
                    }
                } else {
                    urls.append(url)
                }
            }
        }

        return urls
    }

    /// Extract a URL from a provider.
    private func extractURL(from provider: NSItemProvider) async -> URL? {
        // Try file URL first
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Copy to temp since the provided URL is temporary
                    let tempDir = FileManager.default.temporaryDirectory
                    let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)

                    do {
                        try? FileManager.default.removeItem(at: tempURL)
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        continuation.resume(returning: tempURL)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        // Try PDF type
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                    let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".pdf")

                    do {
                        try? FileManager.default.removeItem(at: tempURL)
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        continuation.resume(returning: tempURL)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        return nil
    }

    /// Add publications to a library.
    private func addPublicationsToLibrary(_ uuids: [UUID], libraryID: UUID) async {
        let context = PersistenceController.shared.viewContext

        await context.perform {
            // Fetch library
            let libraryRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            libraryRequest.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
            libraryRequest.fetchLimit = 1

            guard let library = try? context.fetch(libraryRequest).first else {
                return
            }

            // Batch fetch all publications at once
            let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            pubRequest.predicate = NSPredicate(format: "id IN %@", uuids)

            guard let publications = try? context.fetch(pubRequest) else { return }

            for publication in publications {
                publication.addToLibrary(library)
            }

            try? context.save()
        }
    }

    /// Add publications to a collection.
    private func addPublicationsToCollection(_ uuids: [UUID], collectionID: UUID) async {
        let context = PersistenceController.shared.viewContext

        await context.perform {
            // Fetch collection
            let collectionRequest = NSFetchRequest<CDCollection>(entityName: "Collection")
            collectionRequest.predicate = NSPredicate(format: "id == %@", collectionID as CVarArg)
            collectionRequest.fetchLimit = 1

            guard let collection = try? context.fetch(collectionRequest).first else {
                return
            }

            // Batch fetch all publications at once
            let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            pubRequest.predicate = NSPredicate(format: "id IN %@", uuids)

            guard let publications = try? context.fetch(pubRequest) else { return }

            var pubs = collection.publications ?? []
            let collectionLibrary = collection.effectiveLibrary

            for publication in publications {
                pubs.insert(publication)
                if let library = collectionLibrary {
                    publication.addToLibrary(library)
                }
            }
            collection.publications = pubs

            try? context.save()
        }
    }

    /// Attach files to an existing publication.
    private func attachFilesToPublication(_ urls: [URL], publicationID: UUID, libraryID: UUID?) async throws -> DropResult {
        let context = PersistenceController.shared.viewContext

        // Fetch publication and library
        let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        pubRequest.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
        pubRequest.fetchLimit = 1

        guard let publication = try? context.fetch(pubRequest).first else {
            throw DragDropError.publicationNotFound
        }

        var library: CDLibrary?
        if let libraryID {
            let libRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            libRequest.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
            libRequest.fetchLimit = 1
            library = try? context.fetch(libRequest).first
        }

        // Import files
        var imported = 0
        for url in urls {
            do {
                _ = try fileDropHandler.attachmentManager.importAttachment(
                    from: url,
                    for: publication,
                    in: library
                )
                imported += 1
            } catch {
                Logger.files.errorCapture("Failed to import \(url.lastPathComponent): \(error.localizedDescription)", category: "files")
            }
        }

        if imported == 0 {
            throw DragDropError.importFailed
        }

        return .success(message: "Attached \(imported) file(s)")
    }
}

// MARK: - Drag Drop Error

/// Errors that can occur during drag-and-drop operations.
public enum DragDropError: LocalizedError {
    case unsupportedContent
    case invalidTarget
    case noFilesFound
    case noPublicationsFound
    case publicationNotFound
    case libraryNotFound
    case noInboxLibrary
    case importFailed
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContent:
            return "Unsupported content type"
        case .invalidTarget:
            return "Cannot drop here"
        case .noFilesFound:
            return "No compatible files found"
        case .noPublicationsFound:
            return "No publications found in drop"
        case .publicationNotFound:
            return "Publication not found"
        case .libraryNotFound:
            return "Library not found"
        case .noInboxLibrary:
            return "Inbox library not available"
        case .importFailed:
            return "Import failed"
        case .notImplemented(let feature):
            return "\(feature) is not yet implemented"
        }
    }
}
