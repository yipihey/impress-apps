//
//  EverythingExporter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData
import OSLog
#if os(iOS)
import UIKit
#endif

// MARK: - Everything Exporter

/// Exports all libraries, collections, and publications to a single mbox file.
public actor EverythingExporter {

    private let context: NSManagedObjectContext
    private let options: EverythingExportOptions
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "EverythingExporter")

    public init(context: NSManagedObjectContext, options: EverythingExportOptions = .default) {
        self.context = context
        self.options = options
    }

    // MARK: - Public API

    /// Export everything to mbox format.
    /// - Parameter url: Destination file URL
    /// - Returns: Export result with statistics
    public func export(to url: URL) async throws -> EverythingExportResult {
        logger.info("Starting Everything export to \(url.path)")

        var messages: [String] = []
        var exportedPublicationIDs: Set<UUID> = []
        var publicationToLibraries: [UUID: Set<UUID>] = [:]
        var publicationToCollections: [UUID: Set<UUID>] = [:]
        var publicationToFeeds: [UUID: Set<UUID>] = [:]

        // Fetch all libraries
        let libraries = try await fetchAllLibraries()
        logger.info("Found \(libraries.count) libraries")

        // Build manifest
        let manifest = try await buildManifest(libraries: libraries)
        let manifestMessage = buildManifestMessage(manifest)
        messages.append(MIMEEncoder.encode(manifestMessage))

        // Export each library
        for library in libraries {
            // Skip Exploration library unless explicitly included
            if library.isSystemLibrary && !library.isInbox && !library.isSaveLibrary && !library.isDismissedLibrary {
                if !options.includeExploration {
                    logger.info("Skipping Exploration library: \(library.displayName)")
                    continue
                }
            }

            // Build library header message
            let libraryMessage = try await buildLibraryHeaderMessage(library)
            messages.append(MIMEEncoder.encode(libraryMessage))

            // Track publication memberships for this library
            if let publications = library.publications {
                for pub in publications {
                    if publicationToLibraries[pub.id] == nil {
                        publicationToLibraries[pub.id] = []
                    }
                    publicationToLibraries[pub.id]?.insert(library.id)

                    // Track collection memberships
                    if let collections = pub.collections {
                        for collection in collections where collection.library?.id == library.id {
                            if publicationToCollections[pub.id] == nil {
                                publicationToCollections[pub.id] = []
                            }
                            publicationToCollections[pub.id]?.insert(collection.id)
                        }
                    }
                }
            }

            // Track smart search feed memberships
            if let searches = library.smartSearches {
                for search in searches {
                    if let resultCollection = search.resultCollection,
                       let pubs = resultCollection.publications {
                        for pub in pubs {
                            if publicationToFeeds[pub.id] == nil {
                                publicationToFeeds[pub.id] = []
                            }
                            publicationToFeeds[pub.id]?.insert(search.id)
                        }
                    }
                }
            }
        }

        // Export publications (deduplicated - each publication exported once)
        let allPublications = try await fetchAllPublications()
        logger.info("Exporting \(allPublications.count) publications")

        for publication in allPublications {
            // Get all library IDs for this publication
            let libraryIDs = publicationToLibraries[publication.id] ?? []
            guard !libraryIDs.isEmpty else { continue }

            // Get collection and feed IDs
            let collectionIDs = publicationToCollections[publication.id] ?? []
            let feedIDs = publicationToFeeds[publication.id] ?? []

            // Determine primary library (first one, or Inbox if present)
            let sortedLibraryIDs = libraryIDs.sorted { id1, id2 in
                // Prioritize non-system libraries
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
                publication,
                primaryLibrary: primaryLibrary,
                additionalLibraryIDs: additionalLibraryIDs,
                collectionIDs: collectionIDs,
                feedIDs: feedIDs
            )
            messages.append(MIMEEncoder.encode(message))
            exportedPublicationIDs.insert(publication.id)
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

    private func buildManifest(libraries: [CDLibrary]) async throws -> EverythingManifest {
        // Build library index
        var libraryIndices: [LibraryIndex] = []
        for library in libraries {
            if library.isSystemLibrary && !library.isInbox && !library.isSaveLibrary && !library.isDismissedLibrary {
                if !options.includeExploration { continue }
            }

            let type = libraryType(for: library)
            libraryIndices.append(LibraryIndex(
                id: library.id,
                name: library.displayName,
                type: type,
                publicationCount: library.publications?.count ?? 0,
                collectionCount: library.collections?.count ?? 0,
                smartSearchCount: library.smartSearches?.count ?? 0
            ))
        }

        // Fetch muted items
        var mutedItems: [MutedItemInfo] = []
        if options.includeMutedItems {
            mutedItems = try await fetchMutedItems()
        }

        // Fetch dismissed papers
        var dismissedPapers: [DismissedPaperInfo] = []
        if options.includeTriageHistory {
            dismissedPapers = try await fetchDismissedPapers()
        }

        // Calculate total publications
        let totalPublications = try await fetchAllPublications().count

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

    private func buildLibraryHeaderMessage(_ library: CDLibrary) async throws -> MboxMessage {
        // Gather collections
        let collections: [CollectionInfo] = (library.collections ?? []).compactMap { collection in
            CollectionInfo(
                id: collection.id,
                name: collection.name,
                parentID: collection.parentCollection?.id,
                isSmartCollection: collection.isSmartCollection,
                predicate: collection.predicate
            )
        }

        // Gather smart searches
        let smartSearches: [SmartSearchInfo] = (library.smartSearches ?? []).compactMap { search in
            SmartSearchInfo(
                id: search.id,
                name: search.name,
                query: search.query,
                sourceIDs: search.sources,
                maxResults: Int(search.maxResults),
                feedsToInbox: search.feedsToInbox,
                autoRefreshEnabled: search.autoRefreshEnabled,
                refreshIntervalSeconds: Int(search.refreshIntervalSeconds),
                resultCollectionID: search.resultCollection?.id
            )
        }

        // Build metadata
        let type = libraryType(for: library)
        let metadata = LibraryMetadata(
            libraryID: library.id,
            name: library.displayName,
            bibtexPath: library.bibFilePath,
            exportVersion: "2.0",
            exportDate: Date(),
            collections: collections,
            smartSearches: smartSearches,
            libraryType: type,
            isDefault: library.isDefault,
            sortOrder: Int(library.sortOrder)
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
        headers[MboxHeader.libraryName] = library.displayName
        headers[MboxHeader.libraryType] = type.rawValue
        if let bibPath = library.bibFilePath {
            headers[MboxHeader.libraryBibtexPath] = bibPath
        }
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
        _ publication: CDPublication,
        primaryLibrary: CDLibrary?,
        additionalLibraryIDs: Set<UUID>,
        collectionIDs: Set<UUID>,
        feedIDs: Set<UUID>
    ) async throws -> MboxMessage {
        let fields = publication.fields

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

        if let journal = fields["journal"], !journal.isEmpty {
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
                } else if primaryLibrary.isSaveLibrary {
                    headers[MboxHeader.triageState] = "saved"
                } else if primaryLibrary.isDismissedLibrary {
                    headers[MboxHeader.triageState] = "dismissed"
                }
            }

            headers[MboxHeader.isRead] = publication.isRead ? "true" : "false"
            headers[MboxHeader.isStarred] = publication.isStarred ? "true" : "false"
        }

        // Build date from year field
        let year = Int(publication.year)
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
            let fileAttachments = try await buildFileAttachments(for: publication, library: primaryLibrary)
            attachments.append(contentsOf: fileAttachments)
        }

        // Add BibTeX attachment
        if options.includeBibTeX {
            let bibtexAttachment = buildBibTeXAttachment(for: publication)
            attachments.append(bibtexAttachment)
        }

        return MboxMessage(
            from: authorString,
            subject: publication.title ?? "Untitled",
            date: date,
            messageID: publication.id.uuidString,
            headers: headers,
            body: publication.abstract ?? "",
            attachments: attachments
        )
    }

    // MARK: - File Attachments

    private func buildFileAttachments(for publication: CDPublication, library: CDLibrary?) async throws -> [MboxAttachment] {
        var attachments: [MboxAttachment] = []

        guard let linkedFiles = publication.linkedFiles else { return attachments }

        for (index, linkedFile) in linkedFiles.enumerated() {
            // Try to read file data
            let fileData: Data?

            // First check if fileData is stored in Core Data (for CloudKit sync)
            if let storedData = linkedFile.fileData, !storedData.isEmpty {
                fileData = storedData
            } else if let library = library {
                // Try to read from disk
                let fileURL = library.papersContainerURL.appendingPathComponent(linkedFile.relativePath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    // Check file size limit
                    if let maxSize = options.maxFileSize {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                        let size = (attrs?[.size] as? Int) ?? 0
                        if size > maxSize {
                            logger.warning("Skipping large file: \(linkedFile.filename) (\(size) bytes)")
                            continue
                        }
                    }
                    fileData = try? Data(contentsOf: fileURL)
                } else {
                    fileData = nil
                }
            } else {
                fileData = nil
            }

            guard let data = fileData else {
                logger.warning("Could not read file data for: \(linkedFile.filename)")
                continue
            }

            // Determine content type
            let contentType = linkedFile.mimeType ?? mimeTypeForExtension(linkedFile.fileExtension)

            // Build custom headers
            var customHeaders: [String: String] = [:]
            customHeaders[MboxHeader.linkedFilePath] = linkedFile.relativePath
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

    private func buildBibTeXAttachment(for publication: CDPublication) -> MboxAttachment {
        // Use rawBibTeX if available, otherwise generate
        let bibtex: String
        if let raw = publication.rawBibTeX, !raw.isEmpty {
            bibtex = raw
        } else {
            let entry = publication.toBibTeXEntry()
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

    // MARK: - Data Fetching

    private func fetchAllLibraries() async throws -> [CDLibrary] {
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDLibrary.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \CDLibrary.name, ascending: true)
        ]

        return try context.performAndWait {
            try context.fetch(request)
        }
    }

    private func fetchAllPublications() async throws -> [CDPublication] {
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPublication.citeKey, ascending: true)]

        return try context.performAndWait {
            try context.fetch(request)
        }
    }

    private func fetchMutedItems() async throws -> [MutedItemInfo] {
        let request = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMutedItem.dateAdded, ascending: true)]

        let items = try context.performAndWait {
            try context.fetch(request)
        }

        return items.map { item in
            MutedItemInfo(
                type: item.type,
                value: item.value,
                dateAdded: item.dateAdded
            )
        }
    }

    private func fetchDismissedPapers() async throws -> [DismissedPaperInfo] {
        let request = NSFetchRequest<CDDismissedPaper>(entityName: "DismissedPaper")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDDismissedPaper.dateDismissed, ascending: true)]

        let papers = try context.performAndWait {
            try context.fetch(request)
        }

        return papers.map { paper in
            DismissedPaperInfo(
                doi: paper.doi,
                arxivID: paper.arxivID,
                bibcode: paper.bibcode,
                dateDismissed: paper.dateDismissed
            )
        }
    }

    // MARK: - Helpers

    private func libraryType(for library: CDLibrary) -> LibraryType {
        if library.isInbox {
            return .inbox
        } else if library.isSaveLibrary {
            return .save
        } else if library.isDismissedLibrary {
            return .dismissed
        } else if library.isSystemLibrary {
            return .exploration
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
