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

// MARK: - Drag Drop Coordinator

/// Central coordinator for all drag-and-drop operations.
///
/// Routes drops to the appropriate handler based on content type and target:
/// - PDF files -> PDFImportHandler (creates publications)
/// - .bib/.ris files -> BibDropHandler (batch import)
/// - Publication UUIDs -> move/copy between libraries/collections
/// - Other files -> FileDropHandler (attach to publications)
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

    /// The drop target associated with `pendingPreview` (used for collection assignment after import)
    public var pendingDropTarget: DropTarget?

    /// Current target being hovered
    public var currentTarget: DropTarget?

    /// Last error that occurred
    public var lastError: Error?

    // MARK: - Handlers

    private let fileDropHandler: FileDropHandler
    private let pdfImportHandler: PDFImportHandler
    private let bibDropHandler: BibDropHandler

    /// Source manager for URL-based paper imports
    public var sourceManager: SourceManager?

    // MARK: - Store

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

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
        .url,               // Web URLs (from browser address bar)
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
            let count = counts[.publicationTransfer] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Add \(count)" : "Add",
                badgeIcon: "plus.circle.fill"
            )

        case (.pdf, .library), (.pdf, .collection), (.pdf, .inbox):
            let count = counts[.pdf] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Import \(count) PDFs" : "Import PDF",
                badgeIcon: "doc.badge.plus"
            )

        case (.pdf, .publication):
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: "Attach",
                badgeIcon: "paperclip"
            )

        case (.bibtex, .library), (.bibtex, .collection), (.bibtex, .inbox):
            let count = counts[.bibtex] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Import \(count) files" : "Import BibTeX",
                badgeIcon: "doc.text.fill"
            )

        case (.ris, .library), (.ris, .collection), (.ris, .inbox):
            let count = counts[.ris] ?? 0
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: count > 1 ? "Import \(count) files" : "Import RIS",
                badgeIcon: "doc.text.fill"
            )

        case (.urlImport, .library), (.urlImport, .collection), (.urlImport, .inbox):
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: "Import Paper",
                badgeIcon: "link.badge.plus"
            )

        case (.attachment, .publication):
            let total = counts.values.reduce(0, +)
            return DropValidation(
                isValid: true,
                category: category,
                fileCounts: counts,
                badgeText: total > 1 ? "Attach \(total)" : "Attach",
                badgeIcon: "paperclip"
            )

        case (_, .newLibraryZone):
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
    @discardableResult
    public func performDrop(_ info: SwiftUI.DropInfo, target: DropTarget) async -> DropResult {
        let dragDropInfo = DragDropInfo(providers: Array(info.itemProviders(for: Self.acceptedTypes)))
        return await performDrop(dragDropInfo, target: target)
    }

    /// Perform a drop operation from DragDropInfo.
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
            case .urlImport:
                return try await handleURLDrop(info: info, target: target)
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

        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) }) {
            return .publicationTransfer
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                return .pdf
            }

            if let filename = provider.suggestedName?.lowercased() {
                if filename.hasSuffix(".bib") || filename.hasSuffix(".bibtex") {
                    return .bibtex
                }
                if filename.hasSuffix(".ris") {
                    return .ris
                }
            }

            if provider.hasItemConformingToTypeIdentifier("org.tug.tex.bibtex") {
                return .bibtex
            }
            if provider.hasItemConformingToTypeIdentifier("com.clarivate.ris") {
                return .ris
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return .urlImport
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return .unknown
            }
        }

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
            } else if provider.hasItemConformingToTypeIdentifier("org.tug.tex.bibtex") {
                counts[.bibtex, default: 0] += 1
            } else if provider.hasItemConformingToTypeIdentifier("com.clarivate.ris") {
                counts[.ris, default: 0] += 1
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
                      !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                counts[.urlImport, default: 0] += 1
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
            store.movePublications(ids: uuids, toLibraryId: libraryID)
            return .success(message: "Added \(uuids.count) publication(s) to library")

        case .collection(let collectionID, let libraryID):
            store.movePublications(ids: uuids, toLibraryId: libraryID)
            store.addToCollection(publicationIds: uuids, collectionId: collectionID)
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
            return try await attachFilesToPublication(urls, publicationID: publicationID, libraryID: libraryID)

        case .library(let libraryID), .collection(_, let libraryID):
            let previews = await pdfImportHandler.preparePDFImport(urls: urls, target: target)
            if previews.isEmpty {
                throw DragDropError.noFilesFound
            }
            pendingDropTarget = target
            pendingPreview = .pdfImport(previews)
            return .needsConfirmation

        case .inbox:
            guard let inboxLibrary = store.getInboxLibrary() else {
                throw DragDropError.noInboxLibrary
            }
            let previews = await pdfImportHandler.preparePDFImport(urls: urls, target: .library(libraryID: inboxLibrary.id))
            if previews.isEmpty {
                throw DragDropError.noFilesFound
            }
            pendingDropTarget = .inbox
            pendingPreview = .pdfImport(previews)
            return .needsConfirmation

        case .newLibraryZone:
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
        pendingDropTarget = target
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

    // MARK: - URL Import

    /// Handle a web URL drop (from browser address bar).
    private func handleURLDrop(info: DragDropInfo, target: DropTarget) async throws -> DropResult {
        guard let provider = info.providers.first else {
            throw DragDropError.noFilesFound
        }

        guard let url = await extractWebURL(from: provider) else {
            throw DragDropError.urlImportFailed("Could not extract URL from drop")
        }

        Logger.files.infoCapture("URL drop: \(url.absoluteString)", category: "files")

        guard let parsed = parsePaperURL(url) else {
            throw DragDropError.urlImportFailed("Unrecognized academic URL: \(url.host ?? url.absoluteString)")
        }

        guard let sourceManager else {
            Logger.files.errorCapture("URL import: sourceManager not configured", category: "files")
            throw DragDropError.urlImportFailed("Search sources not available")
        }

        let options = SearchOptions(maxResults: 1, sourceIDs: parsed.sourceIDs)
        let results = try await sourceManager.search(query: parsed.query, options: options)

        guard let result = results.first else {
            throw DragDropError.urlImportFailed("Paper not found for \(parsed.query)")
        }

        // Determine the target library
        let libraryID: UUID?
        switch target {
        case .library(let id):
            libraryID = id
        case .collection(_, let id):
            libraryID = id
        case .inbox:
            libraryID = store.getInboxLibrary()?.id
        default:
            libraryID = nil
        }

        // Import using BibTeX from search result
        let bibtex = result.toBibTeX()
        var importedIDs: [UUID] = []
        if let libID = libraryID {
            importedIDs = store.importBibTeX(bibtex, libraryId: libID)
        }

        // If target is a collection, also add to that collection
        if case .collection(let collectionID, _) = target, !importedIDs.isEmpty {
            store.addToCollection(publicationIds: importedIDs, collectionId: collectionID)
        }

        let pubID = importedIDs.first ?? UUID()
        Logger.files.infoCapture("URL import: created publication '\(result.title)' (id: \(pubID))", category: "files")

        // Post notification for auto-selection in list
        if !importedIDs.isEmpty {
            NotificationCenter.default.post(
                name: .pdfImportCompleted,
                object: importedIDs
            )
        }

        return .success(message: "Imported from URL")
    }

    /// Extract a web URL from an NSItemProvider.
    private func extractWebURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Parsed paper URL info.
    private struct ParsedPaperURL {
        let query: String
        let sourceIDs: [String]
    }

    /// Parse an academic paper URL into a search query and source IDs.
    private func parsePaperURL(_ url: URL) -> ParsedPaperURL? {
        if let arxiv = ArXivURLParser.parse(url) {
            switch arxiv {
            case .paper(let arxivID), .pdf(let arxivID):
                return ParsedPaperURL(query: arxivID, sourceIDs: ["arxiv"])
            default:
                break
            }
        }

        if let ads = ADSURLParser.parse(url) {
            if case .paper(let bibcode) = ads {
                return ParsedPaperURL(query: "bibcode:\(bibcode)", sourceIDs: ["ads"])
            }
        }

        if let scix = SciXURLParser.parse(url) {
            if case .paper(let bibcode) = scix {
                return ParsedPaperURL(query: "bibcode:\(bibcode)", sourceIDs: ["scix"])
            }
        }

        if let host = url.host?.lowercased(),
           host == "doi.org" || host == "dx.doi.org" {
            let doi = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !doi.isEmpty {
                return ParsedPaperURL(query: doi, sourceIDs: ["crossref", "ads"])
            }
        }

        // Try extracting DOI from publisher URLs
        if let doi = extractDOIFromURL(url) {
            return ParsedPaperURL(query: doi, sourceIDs: ["crossref", "ads"])
        }

        return nil
    }

    /// Extract a DOI from a publisher URL using known host→prefix mappings and path patterns.
    private func extractDOIFromURL(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path

        // Known publisher host → DOI prefix mappings
        // Nature: nature.com/articles/{doi-suffix} → 10.1038/{doi-suffix}
        if host.hasSuffix("nature.com") {
            let prefix = "/articles/"
            if path.hasPrefix(prefix) {
                let suffix = String(path.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !suffix.isEmpty {
                    return "10.1038/\(suffix)"
                }
            }
        }

        // Science: science.org/doi/{full-doi}
        if host.hasSuffix("science.org"), path.hasPrefix("/doi/") {
            let doiPart = String(path.dropFirst("/doi/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Remove action prefix (abs/, full/, pdf/) if present
            let cleanDOI: String
            if let slashRange = doiPart.range(of: "/"),
               let afterSlash = doiPart.range(of: "10.", options: .literal) {
                cleanDOI = String(doiPart[afterSlash.lowerBound...])
            } else {
                cleanDOI = doiPart
            }
            if cleanDOI.hasPrefix("10.") {
                return cleanDOI
            }
        }

        // Springer: link.springer.com/article/{doi}
        if host.hasSuffix("springer.com"), path.hasPrefix("/article/") {
            let doiPart = String(path.dropFirst("/article/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if doiPart.hasPrefix("10.") {
                return doiPart
            }
        }

        // Wiley: onlinelibrary.wiley.com/doi/{doi}
        if host.hasSuffix("wiley.com"), path.hasPrefix("/doi/") {
            let doiPart = String(path.dropFirst("/doi/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Remove action prefix (abs/, full/, pdf/) if present
            let cleanDOI: String
            if let doiStart = doiPart.range(of: "10.", options: .literal) {
                cleanDOI = String(doiPart[doiStart.lowerBound...])
            } else {
                cleanDOI = doiPart
            }
            if cleanDOI.hasPrefix("10.") {
                return cleanDOI
            }
        }

        // PNAS: pnas.org/doi/{doi}
        if host.hasSuffix("pnas.org"), path.hasPrefix("/doi/") {
            let doiPart = String(path.dropFirst("/doi/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanDOI: String
            if let doiStart = doiPart.range(of: "10.", options: .literal) {
                cleanDOI = String(doiPart[doiStart.lowerBound...])
            } else {
                cleanDOI = doiPart
            }
            if cleanDOI.hasPrefix("10.") {
                return cleanDOI
            }
        }

        // APS (Physical Review): journals.aps.org/{journal}/abstract/{doi}
        if host.hasSuffix("aps.org"), path.contains("/abstract/") {
            if let abstractRange = path.range(of: "/abstract/") {
                let doiPart = String(path[abstractRange.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if doiPart.hasPrefix("10.") {
                    return doiPart
                }
            }
        }

        // bioRxiv/medRxiv: (bio|med)rxiv.org/content/{doi}
        if host.hasSuffix("biorxiv.org") || host.hasSuffix("medrxiv.org"),
           path.hasPrefix("/content/") {
            let doiPart = String(path.dropFirst("/content/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if doiPart.hasPrefix("10.") {
                // Strip trailing version suffixes like .v1, .full, .pdf
                let cleaned = doiPart
                    .replacingOccurrences(of: #"\.(v\d+|full|pdf|abstract)$"#, with: "", options: .regularExpression)
                return cleaned
            }
        }

        // Generic fallback: try extracting DOI pattern from the full URL string
        if let doi = IdentifierExtractor.extractDOIFromText(url.absoluteString) {
            return doi
        }

        return nil
    }

    // MARK: - Confirmation Actions

    /// Confirm and execute a pending PDF import.
    @discardableResult
    public func confirmPDFImport(_ previews: [PDFImportPreview], to libraryID: UUID) async throws -> [UUID] {
        isProcessing = true
        let dropTarget = pendingDropTarget
        defer {
            isProcessing = false
            pendingPreview = nil
            pendingDropTarget = nil
        }

        var importedIDs: [UUID] = []

        for preview in previews where preview.selectedAction != .skip {
            if let pubID = try await pdfImportHandler.commitImport(preview, to: libraryID) {
                importedIDs.append(pubID)
            }
        }

        // If the drop target was a collection, add imported publications to it
        if case .collection(let collectionID, _) = dropTarget, !importedIDs.isEmpty {
            store.addToCollection(publicationIds: importedIDs, collectionId: collectionID)
            Logger.files.infoCapture("Added \(importedIDs.count) imported publications to collection \(collectionID)", category: "files")
        }

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
        let dropTarget = pendingDropTarget
        defer {
            isProcessing = false
            pendingPreview = nil
            pendingDropTarget = nil
        }

        let importedIDs = try await bibDropHandler.commitImport(preview, to: libraryID)

        // If the drop target was a collection, add imported publications to it
        if case .collection(let collectionID, _) = dropTarget, !importedIDs.isEmpty {
            store.addToCollection(publicationIds: importedIDs, collectionId: collectionID)
            Logger.files.infoCapture("Added \(importedIDs.count) imported entries to collection \(collectionID)", category: "files")
        }
    }

    /// Cancel a pending import.
    public func cancelImport() {
        pendingPreview = nil
        pendingDropTarget = nil
    }

    // MARK: - Metadata Lookup

    /// Look up metadata from online sources using provided identifiers or title/author.
    public func lookupMetadata(
        doi: String?,
        arxivID: String?,
        title: String?,
        authors: [String],
        year: Int?
    ) async throws -> EnrichedMetadata? {
        Logger.files.info("Manual lookup requested - DOI: \(doi ?? "none"), arXiv: \(arxivID ?? "none"), title: \(title ?? "none")")

        if let doi, !doi.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromCrossrefDOI(doi) {
                return enriched
            }
        }

        if let arxivID, !arxivID.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromArXiv(arxivID) {
                return enriched
            }
        }

        if let title, !title.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromADSSearch(
                title: title, authors: authors, year: year, abstract: nil
            ) {
                return enriched
            }
        }

        if let title, !title.isEmpty {
            if let enriched = await pdfImportHandler.enrichFromTitleSearch(title, authors: authors) {
                return enriched
            }
        }

        return nil
    }

    // MARK: - Helper Methods

    /// Extract publication UUIDs from a provider.
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

                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    let uuids = uuidStrings.compactMap { UUID(uuidString: $0) }
                    continuation.resume(returning: uuids)
                    return
                }

                if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    continuation.resume(returning: [uuid])
                    return
                }

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
        var urls: [URL] = []

        for provider in info.providers {
            if let url = await extractURL(from: provider) {
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
        let bibtexUTI = "org.tug.tex.bibtex"
        let risUTI = "com.clarivate.ris"

        for uti in [bibtexUTI, risUTI] {
            if provider.hasItemConformingToTypeIdentifier(uti) {
                if let url = await loadFileFromProvider(provider, typeIdentifier: uti) {
                    return url
                }
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileFromProvider(provider, typeIdentifier: UTType.fileURL.identifier) {
                return url
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let url = await loadFileFromProvider(provider, typeIdentifier: UTType.pdf.identifier) {
                return url
            }
        }

        return nil
    }

    /// Load a file representation from a provider for a given UTI, copying to a temp location.
    private func loadFileFromProvider(_ provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

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

    /// Attach files to an existing publication.
    private func attachFilesToPublication(_ urls: [URL], publicationID: UUID, libraryID: UUID?) async throws -> DropResult {
        guard store.getPublication(id: publicationID) != nil else {
            throw DragDropError.publicationNotFound
        }

        var imported = 0
        for url in urls {
            do {
                _ = try AttachmentManager.shared.importAttachment(
                    from: url,
                    for: publicationID,
                    in: libraryID
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
    case urlImportFailed(String)
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
        case .urlImportFailed(let reason):
            return "URL import failed: \(reason)"
        case .notImplemented(let feature):
            return "\(feature) is not yet implemented"
        }
    }
}
