//
//  MboxImporter.swift
//  PublicationManagerCore
//
//  Imports mbox files into imbib libraries via RustStoreAdapter.
//

import Foundation
import OSLog

// MARK: - Mbox Importer

/// Imports mbox files into imbib libraries.
public actor MboxImporter {

    private let options: MboxImportOptions
    private let parser: MboxParser
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "MboxImporter")

    public init(options: MboxImportOptions = .default) {
        self.options = options
        self.parser = MboxParser()
    }

    /// Helper to call @MainActor RustStoreAdapter from actor context.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Public API

    /// Detect the export version from an mbox file.
    public func detectExportVersion(from url: URL) async throws -> ExportVersion {
        let messages = try await parser.parse(url: url)
        return detectExportVersion(messages)
    }

    /// Detect the export version from parsed messages.
    public func detectExportVersion(_ messages: [MboxMessage]) -> ExportVersion {
        if messages.first(where: { $0.headers[MboxHeader.exportType] == "everything" }) != nil {
            return .everything
        }
        if messages.first(where: { $0.subject == "[imbib Library Export]" }) != nil {
            return .singleLibrary
        }
        return .unknown
    }

    /// Prepare an import preview from an mbox file.
    public func prepareImport(from url: URL) async throws -> MboxImportPreview {
        logger.info("Preparing import preview from: \(url.path)")

        let messages = try await parser.parse(url: url)

        let version = detectExportVersion(messages)
        if version == .everything {
            logger.info("Detected Everything export - falling back to first library")
        }

        var libraryMetadata: LibraryMetadata?
        var publications: [PublicationPreview] = []
        var duplicates: [DuplicateInfo] = []
        var parseErrors: [ParseError] = []

        for (index, message) in messages.enumerated() {
            if message.subject == "[imbib Everything Export]" {
                continue
            }

            if message.subject == "[imbib Library Export]" {
                if libraryMetadata == nil {
                    libraryMetadata = parseLibraryMetadata(from: message)
                }
                continue
            }

            do {
                let preview = try await parsePublicationPreview(from: message, index: index)

                if let existing = await findExistingPublication(
                    uuid: UUID(uuidString: message.headers[MboxHeader.imbibID] ?? ""),
                    citeKey: message.headers[MboxHeader.imbibCiteKey],
                    doi: message.headers[MboxHeader.imbibDOI],
                    arxivID: message.headers[MboxHeader.imbibArXiv]
                ) {
                    let matchType: DuplicateInfo.MatchType
                    if existing.id.uuidString == message.headers[MboxHeader.imbibID] {
                        matchType = .uuid
                    } else if existing.citeKey == message.headers[MboxHeader.imbibCiteKey] {
                        matchType = .citeKey
                    } else {
                        matchType = .doi
                    }

                    duplicates.append(DuplicateInfo(
                        importPublication: preview,
                        existingCiteKey: existing.citeKey,
                        existingTitle: existing.title,
                        matchType: matchType
                    ))
                } else {
                    publications.append(preview)
                }
            } catch {
                parseErrors.append(ParseError(
                    messageIndex: index,
                    description: error.localizedDescription
                ))
            }
        }

        logger.info("Preview prepared: \(publications.count) new, \(duplicates.count) duplicates, \(parseErrors.count) errors")

        return MboxImportPreview(
            libraryMetadata: libraryMetadata,
            publications: publications,
            duplicates: duplicates,
            parseErrors: parseErrors
        )
    }

    /// Execute the import after user confirmation.
    public func executeImport(
        _ preview: MboxImportPreview,
        to libraryId: UUID?,
        selectedPublications: Set<UUID>? = nil,
        duplicateDecisions: [UUID: DuplicateAction] = [:]
    ) async throws -> MboxImportResult {
        logger.info("Executing import")

        var importedCount = 0
        var skippedCount = 0
        var mergedCount = 0
        var errors: [MboxImportErrorInfo] = []

        // Determine target library
        let targetLibraryId: UUID
        if let existingId = libraryId {
            targetLibraryId = existingId
        } else if let metadata = preview.libraryMetadata {
            let lib = await withStore { $0.createLibrary(name: metadata.name) }
            targetLibraryId = lib?.id ?? UUID()
        } else {
            let lib = await withStore { $0.createLibrary(name: "Imported Library") }
            targetLibraryId = lib?.id ?? UUID()
        }

        // Import new publications
        for pubPreview in preview.publications {
            if let selected = selectedPublications, !selected.contains(pubPreview.id) {
                skippedCount += 1
                continue
            }

            do {
                try await importPublication(from: pubPreview, to: targetLibraryId)
                importedCount += 1
            } catch {
                errors.append(MboxImportErrorInfo(
                    citeKey: pubPreview.citeKey,
                    description: error.localizedDescription
                ))
            }
        }

        // Handle duplicates
        for duplicate in preview.duplicates {
            let action = duplicateDecisions[duplicate.id] ?? (options.duplicateHandling == .askEach ? .skip : duplicateActionFromOption())

            switch action {
            case .skip:
                skippedCount += 1
            case .replace:
                do {
                    try await replacePublication(duplicate, in: targetLibraryId)
                    importedCount += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
                    ))
                }
            case .merge:
                do {
                    try await mergePublication(duplicate, in: targetLibraryId)
                    mergedCount += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
                    ))
                }
            }
        }

        logger.info("Import complete: \(importedCount) imported, \(mergedCount) merged, \(skippedCount) skipped, \(errors.count) errors")

        return MboxImportResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            mergedCount: mergedCount,
            errors: errors
        )
    }

    // MARK: - Preview Parsing

    private func parseLibraryMetadata(from message: MboxMessage) -> LibraryMetadata? {
        guard let jsonData = message.body.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let metadata = try? decoder.decode(LibraryMetadata.self, from: jsonData) {
            return metadata
        }

        return LibraryMetadata(
            libraryID: UUID(uuidString: message.headers[MboxHeader.libraryID] ?? ""),
            name: message.headers[MboxHeader.libraryName] ?? "Imported Library",
            bibtexPath: message.headers[MboxHeader.libraryBibtexPath],
            exportVersion: message.headers[MboxHeader.exportVersion] ?? "1.0",
            exportDate: Date()
        )
    }

    private func parsePublicationPreview(from message: MboxMessage, index: Int) async throws -> PublicationPreview {
        let headers = message.headers

        let id = UUID(uuidString: headers[MboxHeader.imbibID] ?? "") ?? UUID()
        let citeKey = headers[MboxHeader.imbibCiteKey] ?? "imported\(index)"
        let title = message.subject
        let authors = message.from
        let entryType = headers[MboxHeader.imbibEntryType] ?? "article"
        let doi = headers[MboxHeader.imbibDOI]
        let arxivID = headers[MboxHeader.imbibArXiv]

        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: message.date)

        let fileCount = message.attachments.filter { $0.contentType != "text/x-bibtex" }.count

        var collectionIDs: [UUID] = []
        if let collectionsHeader = headers[MboxHeader.imbibCollections] {
            collectionIDs = collectionsHeader.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }

        var rawBibTeX: String?
        for attachment in message.attachments {
            if attachment.contentType == "text/x-bibtex" || attachment.filename.hasSuffix(".bib") {
                rawBibTeX = String(data: attachment.data, encoding: .utf8)
                break
            }
        }

        return PublicationPreview(
            id: id,
            citeKey: citeKey,
            title: title,
            authors: authors,
            year: year > 0 ? year : nil,
            entryType: entryType,
            doi: doi,
            arxivID: arxivID,
            hasAbstract: !message.body.isEmpty,
            fileCount: fileCount,
            collectionIDs: collectionIDs,
            rawBibTeX: rawBibTeX,
            message: message
        )
    }

    // MARK: - Duplicate Detection

    private func findExistingPublication(uuid: UUID?, citeKey: String?, doi: String?, arxivID: String?) async -> PublicationRowData? {
        if let uuid = uuid {
            let existing = await withStore { $0.getPublication(id: uuid) }
            if let pub = existing { return pub }
        }

        if let doi = doi, !doi.isEmpty {
            let results = await withStore { $0.findByDoi(doi: doi) }
            if let pub = results.first { return pub }
        }

        if let arxivID = arxivID, !arxivID.isEmpty {
            let results = await withStore { $0.findByArxiv(arxivId: arxivID) }
            if let pub = results.first { return pub }
        }

        if let citeKey = citeKey, !citeKey.isEmpty {
            let existing = await withStore { $0.findByCiteKey(citeKey: citeKey) }
            if let pub = existing { return pub }
        }

        return nil
    }

    // MARK: - Import Execution

    private func importPublication(
        from preview: PublicationPreview,
        to libraryId: UUID
    ) async throws {
        // Build BibTeX from preview data or use raw
        let bibtex: String
        if let raw = preview.rawBibTeX, !raw.isEmpty {
            bibtex = raw
        } else {
            var fields: [String: String] = [:]
            fields["title"] = preview.title
            fields["author"] = preview.authors
            if let year = preview.year { fields["year"] = String(year) }
            if let doi = preview.doi { fields["doi"] = doi }
            if let arxivID = preview.arxivID {
                fields["eprint"] = arxivID
                fields["archiveprefix"] = "arXiv"
            }
            if !preview.message.body.isEmpty {
                fields["abstract"] = preview.message.body
            }

            let entry = BibTeXEntry(citeKey: preview.citeKey, entryType: preview.entryType, fields: fields)
            bibtex = BibTeXExporter().export(entry)
        }

        _ = await withStore { $0.importBibTeX(bibtex, libraryId: libraryId) }
    }

    private func replacePublication(
        _ duplicate: DuplicateInfo,
        in libraryId: UUID
    ) async throws {
        // Find and delete existing by cite key
        let existing = await withStore { $0.findByCiteKey(citeKey: duplicate.existingCiteKey) }
        if let pub = existing {
            await withStore { $0.deletePublications(ids: [pub.id]) }
        }

        try await importPublication(from: duplicate.importPublication, to: libraryId)
    }

    private func mergePublication(
        _ duplicate: DuplicateInfo,
        in libraryId: UUID
    ) async throws {
        let preview = duplicate.importPublication
        let existing = await withStore { $0.findByCiteKey(citeKey: duplicate.existingCiteKey) }

        guard let pub = existing else { return }

        // Merge fields - only update empty fields
        let detail = await withStore { $0.getPublicationDetail(id: pub.id) }
        if let detail = detail {
            if detail.abstract == nil || detail.abstract?.isEmpty == true {
                let abstract = preview.message.body.isEmpty ? nil : preview.message.body
                if let abstract = abstract {
                    await withStore { $0.updateField(id: pub.id, field: "abstract_text", value: abstract) }
                }
            }

            if detail.doi == nil, let doi = preview.doi {
                await withStore { $0.updateField(id: pub.id, field: "doi", value: doi) }
            }
        }
    }

    // MARK: - Helpers

    private func duplicateActionFromOption() -> DuplicateAction {
        switch options.duplicateHandling {
        case .skip:
            return .skip
        case .replace:
            return .replace
        case .merge:
            return .merge
        case .askEach:
            return .skip
        }
    }
}

// MARK: - Duplicate Action

/// Action to take for a duplicate publication.
public enum DuplicateAction: String, Sendable, CaseIterable {
    case skip = "Skip"
    case replace = "Replace"
    case merge = "Merge"
}

// MARK: - Import Errors

/// Errors that can occur during mbox import.
public enum MboxMboxImportErrorInfo: Error, LocalizedError {
    case parseError(String)
    case duplicateConflict(String)
    case saveError(String)

    public var errorDescription: String? {
        switch self {
        case .parseError(let reason):
            return "Parse error: \(reason)"
        case .duplicateConflict(let citeKey):
            return "Duplicate conflict for: \(citeKey)"
        case .saveError(let reason):
            return "Save error: \(reason)"
        }
    }
}
