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

    // MARK: - Manuscript export (Phase 5.3 — journal pipeline)

    /// Export one or more journal manuscripts to an mbox file. Each
    /// manuscript becomes one mbox message; reviews + revision-notes appear
    /// in the body; each manuscript-revision is a MIME attachment carrying
    /// the source archive reference (real bytes are written when BlobStore
    /// resolution lands per Phase 5.5+).
    ///
    /// Per ADR-0011 D10 / plan §3.5: this is the journal's "cold tier" —
    /// the file is portable, opens in Apple Mail, and preserves the full
    /// revision timeline plus reviewer commentary.
    public func exportManuscripts(
        manuscriptIDs: [String],
        bridge: ManuscriptBridge = ManuscriptBridge.shared,
        to url: URL
    ) async throws {
        var messages: [String] = []
        for manuscriptID in manuscriptIDs {
            guard let manuscript = await bridge.getManuscript(id: manuscriptID) else {
                logger.warning("exportManuscripts: manuscript \(manuscriptID) not found; skipping")
                continue
            }
            let revisions = await bridge.listRevisions(manuscriptID: manuscriptID)
            let reviews   = await bridge.listReviews(manuscriptID: manuscriptID)
            let notes     = await bridge.listRevisionNotes(manuscriptID: manuscriptID)
            let message = await buildManuscriptMessage(
                manuscript: manuscript,
                revisions: revisions,
                reviews: reviews,
                notes: notes,
                bridge: bridge
            )
            messages.append(MIMEEncoder.encode(message))
        }

        let mboxContent = messages.joined(separator: "\n\n")
        try mboxContent.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Exported \(manuscriptIDs.count) manuscript(s) to \(url.path)")
    }

    /// Build a single MboxMessage from a manuscript and its provenance.
    /// Subject = manuscript title. Body = markdown-formatted revision
    /// timeline plus inlined review summaries. Each revision becomes one
    /// MIME attachment carrying the real PDF (Phase 6, when imprint compile
    /// has run) or a small text pointer (placeholder for deferred compile).
    private func buildManuscriptMessage(
        manuscript: JournalManuscript,
        revisions: [JournalRevision],
        reviews: [JournalReview],
        notes: [JournalRevisionNote],
        bridge: ManuscriptBridge
    ) async -> MboxMessage {
        // Body — markdown-style for human readability when opened in Mail.
        var body = """
        # \(manuscript.title)

        Status: \(manuscript.status.displayName)
        \(manuscript.authors.isEmpty ? "" : "Authors: " + manuscript.authors.joined(separator: ", "))
        \(manuscript.journalTarget.map { "Target journal: \($0)" } ?? "")

        ## Revision Timeline (\(revisions.count))

        """
        for rev in revisions {
            body += "- **\(rev.revisionTag)** — content_hash=\(rev.contentHash.prefix(12))…"
            if let reason = rev.snapshotReason { body += " (\(reason))" }
            body += "\n"
        }

        body += "\n## Reviews (\(reviews.count))\n\n"
        for r in reviews {
            body += "### \(r.verdict.displayName) — \(r.agentID ?? "human")\n\n"
            if let summary = r.summary { body += "**Summary:** \(summary)\n\n" }
            body += r.body + "\n\n"
        }

        body += "## Revision Notes (\(notes.count))\n\n"
        for n in notes {
            body += "### \(n.verdict.displayName)"
            if let target = n.targetSection { body += " — §\(target)" }
            body += " — \(n.agentID ?? "human")\n\n"
            body += n.body + "\n\n"
            if let diff = n.diff, !diff.isEmpty {
                body += "```diff\n\(diff)\n```\n\n"
            }
        }

        // Attachments — one per revision. Phase 8: bundle revisions get
        // their `.tar.zst` archive bytes attached directly (faithful copy
        // for re-import). Inline-text revisions still get a pointer
        // placeholder until inline-blob resolution lands.
        var attachments: [MboxAttachment] = []
        for rev in revisions {
            if rev.isBundle, let archiveURL = await bridge.getRevisionBundleArchiveURL(revisionID: rev.id) {
                let archiveData: Data
                do {
                    archiveData = try Data(contentsOf: archiveURL)
                } catch {
                    archiveData = Data()
                }
                var customHeaders: [String: String] = [
                    "X-Imbib-Journal-Revision-ID": rev.id,
                    "X-Imbib-Journal-Revision-Tag": rev.revisionTag,
                    "X-Imbib-Journal-Content-Hash": rev.contentHash,
                    "X-Imbib-Journal-Bundle": "true",
                ]
                if let format = rev.bundleSourceFormat {
                    customHeaders["X-Imbib-Journal-Source-Format"] = format
                }
                if let main = rev.bundleMainSource {
                    customHeaders["X-Imbib-Journal-Bundle-Main"] = main
                }
                if let entries = rev.bundleEntries() {
                    customHeaders["X-Imbib-Journal-Bundle-Entries"] = "\(entries.count)"
                }
                let attachment = MboxAttachment(
                    filename: "\(rev.revisionTag)-source.tar.zst",
                    contentType: "application/zstd",
                    data: archiveData,
                    customHeaders: customHeaders
                )
                attachments.append(attachment)
            } else {
                let placeholder = """
                Manuscript-Revision \(rev.revisionTag)
                content_hash:        \(rev.contentHash)
                source_archive_ref:  \(rev.sourceArchiveRef)
                pdf_artifact_ref:    \(rev.pdfArtifactRef)
                snapshot_reason:     \(rev.snapshotReason ?? "n/a")
                word_count:          \(rev.wordCount.map(String.init) ?? "n/a")

                (This revision pre-dates Phase 8 bundles; bundle revisions
                attach the real `.tar.zst` archive in place of this pointer.)
                """
                let data = placeholder.data(using: .utf8) ?? Data()
                let attachment = MboxAttachment(
                    filename: "\(rev.revisionTag).txt",
                    contentType: "text/plain; charset=utf-8",
                    data: data,
                    customHeaders: [
                        "X-Imbib-Journal-Revision-ID": rev.id,
                        "X-Imbib-Journal-Revision-Tag": rev.revisionTag,
                        "X-Imbib-Journal-Content-Hash": rev.contentHash,
                    ]
                )
                attachments.append(attachment)
            }
        }

        var headers: [String: String] = [
            "X-Imbib-Journal-Manuscript-ID": manuscript.id,
            "X-Imbib-Journal-Manuscript-Status": manuscript.status.rawValue,
            "X-Imbib-Journal-Revision-Count": "\(revisions.count)",
            "X-Imbib-Journal-Review-Count": "\(reviews.count)",
        ]
        if !manuscript.topicTags.isEmpty {
            headers["X-Imbib-Journal-Topics"] = manuscript.topicTags.joined(separator: ", ")
        }

        return MboxMessage(
            from: "imbib-journal@local",
            subject: manuscript.title,
            date: Date(),
            messageID: "<journal-manuscript-\(manuscript.id)@imbib.local>",
            headers: headers,
            body: body,
            attachments: attachments
        )
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
