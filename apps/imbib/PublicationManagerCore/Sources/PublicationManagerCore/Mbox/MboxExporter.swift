//
//  MboxExporter.swift
//  PublicationManagerCore
//
//  Exports libraries and publications to mbox format via RustStoreAdapter.
//

import Foundation
import OSLog

// MARK: - Mbox Exporter

/// Exports libraries and publications to mbox format.
public actor MboxExporter {

    private let options: MboxExportOptions
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "MboxExporter")

    public init(options: MboxExportOptions = .default) {
        self.options = options
    }

    /// Helper to call @MainActor RustStoreAdapter from actor context.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Public API

    /// Export a library to mbox format.
    public func export(libraryId: UUID, to url: URL) async throws {
        let library = await withStore { $0.getLibrary(id: libraryId) }
        guard let library else {
            throw MboxExportError.writeError("Library not found")
        }

        logger.info("Exporting library '\(library.name)' to mbox")

        var messages: [String] = []

        // Add library header message
        let headerMessage = try await buildLibraryHeaderMessage(library)
        messages.append(MIMEEncoder.encode(headerMessage))

        // Export publications
        let publications = await withStore { $0.queryPublications(parentId: libraryId, sort: "cite_key", ascending: true) }
        logger.info("Exporting \(publications.count) publications")

        for pub in publications {
            guard let detail = await withStore({ $0.getPublicationDetail(id: pub.id) }) else { continue }
            let message = try await publicationToMessage(detail, libraryId: libraryId)
            messages.append(MIMEEncoder.encode(message))
        }

        // Write to file
        let mboxContent = messages.joined(separator: "\n\n")
        try mboxContent.write(to: url, atomically: true, encoding: .utf8)

        logger.info("Export complete: \(url.path)")
    }

    /// Export specific publications to mbox format.
    public func export(publicationIds: [UUID], libraryId: UUID?, to url: URL) async throws {
        var messages: [String] = []

        // Add library header if provided
        if let libraryId = libraryId {
            let library = await withStore { $0.getLibrary(id: libraryId) }
            if let library = library {
                let headerMessage = try await buildLibraryHeaderMessage(library)
                messages.append(MIMEEncoder.encode(headerMessage))
            }
        }

        // Export publications
        for pubId in publicationIds {
            guard let detail = await withStore({ $0.getPublicationDetail(id: pubId) }) else { continue }
            let message = try await publicationToMessage(detail, libraryId: libraryId)
            messages.append(MIMEEncoder.encode(message))
        }

        // Write to file
        let mboxContent = messages.joined(separator: "\n\n")
        try mboxContent.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Library Header

    private func buildLibraryHeaderMessage(_ library: LibraryModel) async throws -> MboxMessage {
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

        let smartSearches = await withStore { $0.listSmartSearches(libraryId: library.id) }
        let searchInfos: [SmartSearchInfo] = smartSearches.map { search in
            SmartSearchInfo(
                id: search.id,
                name: search.name,
                query: search.query,
                sourceIDs: search.sourceIDs,
                maxResults: Int(search.maxResults)
            )
        }

        let metadata = LibraryMetadata(
            libraryID: library.id,
            name: library.name,
            bibtexPath: nil,
            exportVersion: "1.0",
            exportDate: Date(),
            collections: collectionInfos,
            smartSearches: searchInfos
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(metadata)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var headers: [String: String] = [:]
        headers[MboxHeader.libraryID] = library.id.uuidString
        headers[MboxHeader.libraryName] = library.name
        headers[MboxHeader.exportVersion] = "1.0"

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

    // MARK: - Publication to Message

    private func publicationToMessage(_ publication: PublicationModel, libraryId: UUID?) async throws -> MboxMessage {
        let authorString = publication.authorString.isEmpty ? "Unknown Author" : publication.authorString

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

        if options.includeFiles, let libraryId = libraryId {
            let fileAttachments = try await buildFileAttachments(for: publication, libraryId: libraryId)
            attachments.append(contentsOf: fileAttachments)
        }

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

            let contentType = linkedFile.isPDF ? "application/pdf" : mimeTypeForExtension(fileURL.pathExtension)

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

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bib": return "text/x-bibtex"
        case "ris": return "application/x-research-info-systems"
        default: return "application/octet-stream"
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
