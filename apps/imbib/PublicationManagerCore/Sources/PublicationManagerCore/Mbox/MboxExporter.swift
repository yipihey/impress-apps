//
//  MboxExporter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation
import CoreData
import OSLog

// MARK: - Mbox Exporter

/// Exports CDLibrary and publications to mbox format.
public actor MboxExporter {

    private let context: NSManagedObjectContext
    private let options: MboxExportOptions
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "MboxExporter")

    public init(context: NSManagedObjectContext, options: MboxExportOptions = .default) {
        self.context = context
        self.options = options
    }

    // MARK: - Public API

    /// Export a library to mbox format.
    /// - Parameters:
    ///   - library: The library to export
    ///   - url: Destination file URL
    public func export(library: CDLibrary, to url: URL) async throws {
        logger.info("Exporting library '\(library.displayName)' to mbox")

        // Build all messages
        var messages: [String] = []

        // Add library header message
        let headerMessage = try await buildLibraryHeaderMessage(library)
        messages.append(MIMEEncoder.encode(headerMessage))

        // Export publications
        let publications = try await fetchPublications(for: library)
        logger.info("Exporting \(publications.count) publications")

        for publication in publications {
            let message = try await publicationToMessage(publication, library: library)
            messages.append(MIMEEncoder.encode(message))
        }

        // Write to file
        let mboxContent = messages.joined(separator: "\n\n")
        try mboxContent.write(to: url, atomically: true, encoding: .utf8)

        logger.info("Export complete: \(url.path)")
    }

    /// Export specific publications to mbox format.
    /// - Parameters:
    ///   - publications: Publications to export
    ///   - library: The owning library (for metadata)
    ///   - url: Destination file URL
    public func export(publications: [CDPublication], library: CDLibrary?, to url: URL) async throws {
        var messages: [String] = []

        // Add library header if provided
        if let library = library {
            let headerMessage = try await buildLibraryHeaderMessage(library)
            messages.append(MIMEEncoder.encode(headerMessage))
        }

        // Export publications
        for publication in publications {
            let message = try await publicationToMessage(publication, library: library)
            messages.append(MIMEEncoder.encode(message))
        }

        // Write to file
        let mboxContent = messages.joined(separator: "\n\n")
        try mboxContent.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Library Header

    /// Build the library metadata header message.
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
                maxResults: Int(search.maxResults)
            )
        }

        // Build metadata
        let metadata = LibraryMetadata(
            libraryID: library.id,
            name: library.displayName,
            bibtexPath: library.bibFilePath,
            exportVersion: "1.0",
            exportDate: Date(),
            collections: collections,
            smartSearches: smartSearches
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
        if let bibPath = library.bibFilePath {
            headers[MboxHeader.libraryBibtexPath] = bibPath
        }
        headers[MboxHeader.exportVersion] = "1.0"

        let iso8601Formatter = ISO8601DateFormatter()
        headers[MboxHeader.exportDate] = iso8601Formatter.string(from: Date())

        return MboxMessage(
            from: "imbib@imbib.local",
            subject: "[imbib Library Export]",
            date: Date(timeIntervalSince1970: 0), // Unix epoch
            messageID: library.id.uuidString,
            headers: headers,
            body: jsonString,
            attachments: []
        )
    }

    // MARK: - Publication to Message

    /// Convert a publication to an mbox message.
    private func publicationToMessage(_ publication: CDPublication, library: CDLibrary?) async throws -> MboxMessage {
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
        let collectionIDs = (publication.collections ?? []).map { $0.id.uuidString }
        if !collectionIDs.isEmpty {
            headers[MboxHeader.imbibCollections] = collectionIDs.joined(separator: ",")
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
            let fileAttachments = try await buildFileAttachments(for: publication, library: library)
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

    /// Build file attachments for a publication.
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

    /// Build BibTeX attachment for a publication.
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

    // MARK: - Helpers

    /// Fetch all publications for a library.
    private func fetchPublications(for library: CDLibrary) async throws -> [CDPublication] {
        let request = NSFetchRequest<CDPublication>(entityName: "CDPublication")
        request.predicate = NSPredicate(format: "ANY libraries == %@", library)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPublication.citeKey, ascending: true)]

        return try context.performAndWait {
            try context.fetch(request)
        }
    }

    /// Get MIME type for file extension.
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

// MARK: - Export Errors

/// Errors that can occur during mbox export.
public enum MboxExportError: Error, LocalizedError {
    case writeError(String)
    case encodingError(String)

    public var errorDescription: String? {
        switch self {
        case .writeError(let reason):
            return "Failed to write mbox file: \(reason)"
        case .encodingError(let reason):
            return "Encoding error: \(reason)"
        }
    }
}
