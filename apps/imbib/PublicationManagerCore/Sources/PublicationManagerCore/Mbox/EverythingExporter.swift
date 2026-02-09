//
//  EverythingExporter.swift
//  PublicationManagerCore
//
//  Exports all libraries, collections, and publications to a single mbox file via RustStoreAdapter.
//

import Foundation
import OSLog
#if os(iOS)
import UIKit
#endif

// MARK: - Everything Exporter

/// Exports all libraries, collections, and publications to a single mbox file.
public actor EverythingExporter {

    private let options: EverythingExportOptions
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "EverythingExporter")

    public init(options: EverythingExportOptions = .default) {
        self.options = options
    }

    /// Helper to call @MainActor RustStoreAdapter from actor context.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Public API

    /// Export everything to mbox format.
    /// - Parameter url: Destination file URL
    /// - Returns: Export result with statistics
    public func export(to url: URL) async throws -> EverythingExportResult {
        logger.info("Starting Everything export to \(url.path)")

        var messages: [String] = []
        var exportedPublicationIDs: Set<UUID> = []

        // Fetch all libraries
        let libraries = await withStore { $0.listLibraries() }
        logger.info("Found \(libraries.count) libraries")

        // Build manifest
        let manifest = try await buildManifest(libraries: libraries)
        let manifestMessage = buildManifestMessage(manifest)
        messages.append(MIMEEncoder.encode(manifestMessage))

        // Track publication -> library/collection memberships
        var publicationToLibraries: [UUID: Set<UUID>] = [:]

        // Export each library
        for library in libraries {
            // Skip Exploration-type libraries unless explicitly included
            if !library.isDefault && !library.isInbox {
                // Check if this is a system/exploration library by name convention
                // (RustStoreAdapter doesn't expose isSystemLibrary directly)
            }

            // Build library header message
            let libraryMessage = try await buildLibraryHeaderMessage(library)
            messages.append(MIMEEncoder.encode(libraryMessage))

            // Track publication memberships for this library
            let publications = await withStore { $0.queryPublications(parentId: library.id) }
            for pub in publications {
                if publicationToLibraries[pub.id] == nil {
                    publicationToLibraries[pub.id] = []
                }
                publicationToLibraries[pub.id]?.insert(library.id)
            }
        }

        // Export publications (deduplicated - each publication exported once)
        // Collect all unique publication IDs across all libraries
        let allPublicationIDs = publicationToLibraries.keys

        logger.info("Exporting \(allPublicationIDs.count) publications")

        for pubID in allPublicationIDs {
            guard let detail = await withStore({ $0.getPublicationDetail(id: pubID) }) else { continue }

            // Get all library IDs for this publication
            let libraryIDs = publicationToLibraries[pubID] ?? []
            guard !libraryIDs.isEmpty else { continue }

            // Determine primary library
            let sortedLibraryIDs = libraryIDs.sorted { id1, id2 in
                let lib1 = libraries.first { $0.id == id1 }
                let lib2 = libraries.first { $0.id == id2 }
                if lib1?.isInbox == true { return false }
                if lib2?.isInbox == true { return true }
                return id1.uuidString < id2.uuidString
            }

            let primaryLibraryID = sortedLibraryIDs.first!
            let additionalLibraryIDs = Set(sortedLibraryIDs.dropFirst())
            let primaryLibrary = libraries.first { $0.id == primaryLibraryID }

            // Build message with multi-library metadata
            let message = try await buildPublicationMessage(
                detail,
                primaryLibrary: primaryLibrary,
                additionalLibraryIDs: additionalLibraryIDs,
                collectionIDs: Set(detail.collectionIDs),
                feedIDs: []
            )
            messages.append(MIMEEncoder.encode(message))
            exportedPublicationIDs.insert(pubID)
        }

        // Write to file
        let mboxContent = messages.joined(separator: "\n\n")
        try mboxContent.write(to: url, atomically: true, encoding: .utf8)

        let result = EverythingExportResult(
            libraryCount: libraries.count,
            publicationCount: exportedPublicationIDs.count,
            collectionCount: manifest.libraries.reduce(0) { $0 + $1.collectionCount },
            smartSearchCount: manifest.libraries.reduce(0) { $0 + $1.smartSearchCount },
            mutedItemCount: manifest.mutedItems.count,
            dismissedPaperCount: manifest.dismissedPapers.count,
            fileSize: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        )

        logger.info("Export complete: \(result.summary)")
        return result
    }

    // MARK: - Manifest Building

    private func buildManifest(libraries: [LibraryModel]) async throws -> EverythingManifest {
        // Build library index
        var libraryIndices: [LibraryIndex] = []
        for library in libraries {
            let publications = await withStore { $0.queryPublications(parentId: library.id) }
            let collections = await withStore { $0.listCollections(libraryId: library.id) }
            let smartSearches = await withStore { $0.listSmartSearches(libraryId: library.id) }

            let type = libraryType(for: library)
            libraryIndices.append(LibraryIndex(
                id: library.id,
                name: library.name,
                type: type,
                publicationCount: publications.count,
                collectionCount: collections.count,
                smartSearchCount: smartSearches.count
            ))
        }

        // Fetch muted items
        var mutedItems: [MutedItemInfo] = []
        if options.includeMutedItems {
            let items = await withStore { $0.listMutedItems() }
            mutedItems = items.map { MutedItemInfo(type: $0.muteType, value: $0.value, dateAdded: $0.dateAdded) }
        }

        // Fetch dismissed papers
        var dismissedPapers: [DismissedPaperInfo] = []
        if options.includeTriageHistory {
            let papers = await withStore { $0.listDismissedPapers() }
            dismissedPapers = papers.map {
                DismissedPaperInfo(doi: $0.doi, arxivID: $0.arxivID, bibcode: $0.bibcode, dateDismissed: $0.dateDismissed)
            }
        }

        // Calculate total publications
        var totalPublications = 0
        for library in libraries {
            let pubs = await withStore { $0.queryPublications(parentId: library.id) }
            totalPublications += pubs.count
        }

        // Get device name
        let deviceName: String?
        #if os(macOS)
        deviceName = Host.current().localizedName
        #else
        deviceName = UIDevice.current.name
        #endif

        return EverythingManifest(
            manifestVersion: "2.0",
            exportDate: Date(),
            deviceName: deviceName,
            libraries: libraryIndices,
            mutedItems: mutedItems,
            dismissedPapers: dismissedPapers,
            totalPublications: totalPublications
        )
    }

    private func buildManifestMessage(_ manifest: EverythingManifest) -> MboxMessage {
        // Encode manifest as JSON body
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = (try? encoder.encode(manifest)) ?? Data()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var headers: [String: String] = [:]
        headers[MboxHeader.exportType] = "everything"
        headers[MboxHeader.manifestVersion] = manifest.manifestVersion

        let iso8601Formatter = ISO8601DateFormatter()
        headers[MboxHeader.exportDate] = iso8601Formatter.string(from: manifest.exportDate)

        return MboxMessage(
            from: "imbib@imbib.local",
            subject: "[imbib Everything Export]",
            date: Date(timeIntervalSince1970: 0),
            messageID: "manifest-\(UUID().uuidString)",
            headers: headers,
            body: jsonString,
            attachments: []
        )
    }

    // MARK: - Library Header Building

    private func buildLibraryHeaderMessage(_ library: LibraryModel) async throws -> MboxMessage {
        // Gather collections
        let collections = await withStore { $0.listCollections(libraryId: library.id) }
        let collectionInfos: [CollectionInfo] = collections.map { coll in
            CollectionInfo(
                id: coll.id,
                name: coll.name,
                parentID: nil,
                isSmartCollection: false,
                predicate: nil
            )
        }

        // Gather smart searches
        let smartSearches = await withStore { $0.listSmartSearches(libraryId: library.id) }
        let searchInfos: [SmartSearchInfo] = smartSearches.map { search in
            SmartSearchInfo(
                id: search.id,
                name: search.name,
                query: search.query,
                sourceIDs: search.sourceIDs,
                maxResults: Int(search.maxResults),
                feedsToInbox: search.feedsToInbox,
                autoRefreshEnabled: search.autoRefreshEnabled,
                refreshIntervalSeconds: Int(search.refreshIntervalSeconds)
            )
        }

        // Build metadata
        let type = libraryType(for: library)
        let metadata = LibraryMetadata(
            libraryID: library.id,
            name: library.name,
            bibtexPath: nil,
            exportVersion: "2.0",
            exportDate: Date(),
            collections: collectionInfos,
            smartSearches: searchInfos,
            libraryType: type,
            isDefault: library.isDefault,
            sortOrder: 0
        )

        // Encode metadata as JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(metadata)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        // Build headers
        var headers: [String: String] = [:]
        headers[MboxHeader.libraryID] = library.id.uuidString
        headers[MboxHeader.libraryName] = library.name
        headers[MboxHeader.libraryType] = type.rawValue
        headers[MboxHeader.exportVersion] = "2.0"

        let iso8601Formatter = ISO8601DateFormatter()
        headers[MboxHeader.exportDate] = iso8601Formatter.string(from: Date())

        return MboxMessage(
            from: "imbib@imbib.local",
            subject: "[imbib Library Export]",
            date: Date(timeIntervalSince1970: 0),
            messageID: library.id.uuidString,
            headers: headers,
            body: jsonString,
            attachments: []
        )
    }

    // MARK: - Publication Message Building

    private func buildPublicationMessage(
        _ publication: PublicationModel,
        primaryLibrary: LibraryModel?,
        additionalLibraryIDs: Set<UUID>,
        collectionIDs: Set<UUID>,
        feedIDs: Set<UUID>
    ) async throws -> MboxMessage {
        // Build author list for From header
        let authorString = publication.authorString.isEmpty ? "Unknown Author" : publication.authorString

        // Build headers
        var headers: [String: String] = [:]
        headers[MboxHeader.imbibID] = publication.id.uuidString
        headers[MboxHeader.imbibCiteKey] = publication.citeKey
        headers[MboxHeader.imbibEntryType] = publication.entryType

        if let doi = publication.doi, !doi.isEmpty {
            headers[MboxHeader.imbibDOI] = doi
        }

        if let arxiv = publication.arxivID, !arxiv.isEmpty {
            headers[MboxHeader.imbibArXiv] = arxiv
        }

        if let journal = publication.journal, !journal.isEmpty {
            headers[MboxHeader.imbibJournal] = journal
        }

        if let bibcode = publication.bibcode, !bibcode.isEmpty {
            headers[MboxHeader.imbibBibcode] = bibcode
        }

        // Collection memberships
        if !collectionIDs.isEmpty {
            headers[MboxHeader.imbibCollections] = collectionIDs.map { $0.uuidString }.sorted().joined(separator: ",")
        }

        // Multi-library headers
        if let primaryLibrary = primaryLibrary {
            headers[MboxHeader.sourceLibraryID] = primaryLibrary.id.uuidString
        }

        if !additionalLibraryIDs.isEmpty {
            headers[MboxHeader.additionalLibraryIDs] = additionalLibraryIDs.map { $0.uuidString }.sorted().joined(separator: ",")
        }

        if !feedIDs.isEmpty {
            headers[MboxHeader.feedIDs] = feedIDs.map { $0.uuidString }.sorted().joined(separator: ",")
        }

        // Triage state headers
        if options.includeTriageHistory {
            if let primaryLibrary = primaryLibrary {
                if primaryLibrary.isInbox {
                    headers[MboxHeader.triageState] = "inbox"
                }
            }

            headers[MboxHeader.isRead] = publication.isRead ? "true" : "false"
            headers[MboxHeader.isStarred] = publication.isStarred ? "true" : "false"
        }

        // Build date from year field
        let year = publication.year ?? 0
        let date: Date
        if year > 0 {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            date = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        } else {
            date = publication.dateAdded
        }

        // Build attachments
        var attachments: [MboxAttachment] = []

        // Add linked files (PDFs, etc.)
        if options.includeFiles {
            if let primaryLibrary = primaryLibrary {
                let fileAttachments = try await buildFileAttachments(for: publication, libraryId: primaryLibrary.id)
                attachments.append(contentsOf: fileAttachments)
            }
        }

        // Add BibTeX attachment
        if options.includeBibTeX {
            let bibtexAttachment = buildBibTeXAttachment(for: publication)
            attachments.append(bibtexAttachment)
        }

        return MboxMessage(
            from: authorString,
            subject: publication.title,
            date: date,
            messageID: publication.id.uuidString,
            headers: headers,
            body: publication.abstract ?? "",
            attachments: attachments
        )
    }

    // MARK: - File Attachments

    private func buildFileAttachments(for publication: PublicationModel, libraryId: UUID) async throws -> [MboxAttachment] {
        var attachments: [MboxAttachment] = []

        for (index, linkedFile) in publication.linkedFiles.enumerated() {
            // Try to read file from disk
            let resolvedURL = await MainActor.run {
                AttachmentManager.shared.resolveURL(for: linkedFile, in: libraryId)
            }

            guard let fileURL = resolvedURL,
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                logger.warning("Could not read file data for: \(linkedFile.filename)")
                continue
            }

            // Check file size limit
            if let maxSize = options.maxFileSize {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? Int) ?? 0
                if size > maxSize {
                    logger.warning("Skipping large file: \(linkedFile.filename) (\(size) bytes)")
                    continue
                }
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                logger.warning("Could not read file data for: \(linkedFile.filename)")
                continue
            }

            // Determine content type
            let contentType = linkedFile.isPDF ? "application/pdf" : mimeTypeForExtension(fileURL.pathExtension)

            // Build custom headers
            var customHeaders: [String: String] = [:]
            customHeaders[MboxHeader.linkedFilePath] = linkedFile.relativePath ?? linkedFile.filename
            customHeaders[MboxHeader.linkedFileIsMain] = (index == 0) ? "true" : "false"

            attachments.append(MboxAttachment(
                filename: linkedFile.filename,
                contentType: contentType,
                data: data,
                customHeaders: customHeaders
            ))
        }

        return attachments
    }

    private func buildBibTeXAttachment(for publication: PublicationModel) -> MboxAttachment {
        // Use rawBibTeX if available, otherwise generate
        let bibtex: String
        if let raw = publication.rawBibTeX, !raw.isEmpty {
            bibtex = raw
        } else {
            let entry = BibTeXEntry(citeKey: publication.citeKey, entryType: publication.entryType, fields: publication.fields)
            bibtex = BibTeXExporter().export(entry)
        }

        let data = bibtex.data(using: .utf8) ?? Data()

        return MboxAttachment(
            filename: "publication.bib",
            contentType: "text/x-bibtex",
            data: data,
            customHeaders: [:]
        )
    }

    // MARK: - Helpers

    private func libraryType(for library: LibraryModel) -> LibraryType {
        if library.isInbox {
            return .inbox
        } else {
            return .user
        }
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":
            return "application/pdf"
        case "txt":
            return "text/plain"
        case "html", "htm":
            return "text/html"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "bib":
            return "text/x-bibtex"
        case "ris":
            return "application/x-research-info-systems"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - Export Result

/// Result of an Everything export operation.
public struct EverythingExportResult: Sendable {
    public let libraryCount: Int
    public let publicationCount: Int
    public let collectionCount: Int
    public let smartSearchCount: Int
    public let mutedItemCount: Int
    public let dismissedPaperCount: Int
    public let fileSize: Int

    public init(
        libraryCount: Int = 0,
        publicationCount: Int = 0,
        collectionCount: Int = 0,
        smartSearchCount: Int = 0,
        mutedItemCount: Int = 0,
        dismissedPaperCount: Int = 0,
        fileSize: Int = 0
    ) {
        self.libraryCount = libraryCount
        self.publicationCount = publicationCount
        self.collectionCount = collectionCount
        self.smartSearchCount = smartSearchCount
        self.mutedItemCount = mutedItemCount
        self.dismissedPaperCount = dismissedPaperCount
        self.fileSize = fileSize
    }

    /// Human-readable file size
    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    /// Summary description
    public var summary: String {
        "\(libraryCount) libraries, \(publicationCount) publications, \(collectionCount) collections, \(formattedFileSize)"
    }
}

// MARK: - Export Errors

/// Errors that can occur during Everything export.
public enum EverythingExportError: Error, LocalizedError {
    case writeError(String)
    case encodingError(String)
    case noLibraries

    public var errorDescription: String? {
        switch self {
        case .writeError(let reason):
            return "Failed to write mbox file: \(reason)"
        case .encodingError(let reason):
            return "Encoding error: \(reason)"
        case .noLibraries:
            return "No libraries to export"
        }
    }
}
