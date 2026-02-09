//
//  EverythingImporter.swift
//  PublicationManagerCore
//
//  Imports Everything mbox exports with phased reconstruction via RustStoreAdapter.
//

import Foundation
import OSLog

// MARK: - Everything Importer

/// Imports Everything mbox exports with phased reconstruction.
public actor EverythingImporter {

    private let options: EverythingImportOptions
    private let parser: MboxParser
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "EverythingImporter")

    public init(options: EverythingImportOptions = .default) {
        self.options = options
        self.parser = MboxParser()
    }

    /// Helper to call @MainActor RustStoreAdapter from actor context.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Public API

    /// Prepare an import preview from an Everything mbox file.
    public func prepareImport(from url: URL) async throws -> EverythingImportPreview {
        logger.info("Preparing Everything import from: \(url.path)")

        let messages = try await parser.parse(url: url)

        let version = detectExportVersion(messages)
        guard version == .everything else {
            throw EverythingImportError.wrongExportVersion(version)
        }

        var manifest: EverythingManifest?
        var libraryPreviews: [LibraryImportPreview] = []
        var publications: [PublicationPreview] = []
        var duplicates: [DuplicateInfo] = []
        var parseErrors: [ParseError] = []
        var libraryConflicts: [LibraryConflict] = []

        var libraryMetadataByID: [UUID: LibraryMetadata] = [:]

        for (index, message) in messages.enumerated() {
            if message.subject == "[imbib Everything Export]" {
                manifest = parseManifest(from: message)
                continue
            }

            if message.subject == "[imbib Library Export]" {
                if let metadata = parseLibraryMetadata(from: message) {
                    if let libraryID = metadata.libraryID {
                        libraryMetadataByID[libraryID] = metadata

                        let conflict = await checkLibraryConflict(metadata)
                        if let conflict = conflict {
                            libraryConflicts.append(conflict)
                        }

                        libraryPreviews.append(LibraryImportPreview(
                            id: libraryID,
                            metadata: metadata,
                            publicationCount: 0,
                            isNew: conflict == nil
                        ))
                    }
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

        // Update library publication counts
        for i in 0..<libraryPreviews.count {
            let libraryID = libraryPreviews[i].id
            let count = publications.filter { pub in
                if let sourceID = UUID(uuidString: pub.message.headers[MboxHeader.sourceLibraryID] ?? "") {
                    return sourceID == libraryID
                }
                return false
            }.count
            libraryPreviews[i] = LibraryImportPreview(
                id: libraryPreviews[i].id,
                metadata: libraryPreviews[i].metadata,
                publicationCount: count,
                isNew: libraryPreviews[i].isNew
            )
        }

        logger.info("Preview prepared: \(publications.count) new, \(duplicates.count) duplicates, \(libraryPreviews.count) libraries")

        return EverythingImportPreview(
            manifest: manifest ?? EverythingManifest(),
            libraries: libraryPreviews,
            publications: publications,
            duplicates: duplicates,
            parseErrors: parseErrors,
            libraryConflicts: libraryConflicts
        )
    }

    /// Execute the Everything import after user confirmation.
    public func executeImport(_ preview: EverythingImportPreview) async throws -> EverythingImportResult {
        logger.info("Executing Everything import")

        var librariesCreated = 0
        var librariesMerged = 0
        var collectionsCreated = 0
        var smartSearchesCreated = 0
        var publicationsImported = 0
        var publicationsSkipped = 0
        var publicationsMerged = 0
        var mutedItemsImported = 0
        var dismissedPapersImported = 0
        var errors: [MboxImportErrorInfo] = []

        var libraryMap: [UUID: UUID] = [:]  // Import ID -> Rust library ID
        var collectionMap: [UUID: UUID] = [:]  // Import ID -> Rust collection ID

        // Phase 1: Create/resolve libraries
        for libraryPreview in preview.libraries {
            let metadata = libraryPreview.metadata
            let resolution = options.libraryConflictResolutions[libraryPreview.id] ?? .merge

            do {
                let existingLibrary = await findExistingLibrary(id: libraryPreview.id, type: metadata.libraryType)

                if let existing = existingLibrary {
                    switch resolution {
                    case .merge:
                        libraryMap[libraryPreview.id] = existing.id
                        librariesMerged += 1
                    case .replace:
                        await withStore { $0.deleteLibrary(id: existing.id) }
                        let newLib = await withStore { $0.createLibrary(name: metadata.name) }
                        if let lib = newLib {
                            libraryMap[libraryPreview.id] = lib.id
                        }
                        librariesCreated += 1
                    case .rename:
                        let newLib = await withStore { $0.createLibrary(name: "\(metadata.name) (Imported)") }
                        if let lib = newLib {
                            libraryMap[libraryPreview.id] = lib.id
                        }
                        librariesCreated += 1
                    case .skip:
                        continue
                    }
                } else {
                    let lib = await withStore { $0.createLibrary(name: metadata.name) }
                    if let lib = lib {
                        libraryMap[libraryPreview.id] = lib.id
                    }
                    librariesCreated += 1
                }
            } catch {
                errors.append(MboxImportErrorInfo(
                    citeKey: nil,
                    description: "Failed to create library '\(metadata.name)': \(error.localizedDescription)"
                ))
            }
        }

        // Phase 2: Create collections
        for libraryPreview in preview.libraries {
            guard let libraryId = libraryMap[libraryPreview.id] else { continue }
            let metadata = libraryPreview.metadata

            for collectionInfo in metadata.collections {
                let coll = await withStore { $0.createCollection(name: collectionInfo.name, libraryId: libraryId) }
                if let coll = coll {
                    collectionMap[collectionInfo.id] = coll.id
                    collectionsCreated += 1
                }
            }
        }

        // Phase 3: Create smart searches
        for libraryPreview in preview.libraries {
            guard let libraryId = libraryMap[libraryPreview.id] else { continue }
            let metadata = libraryPreview.metadata

            for searchInfo in metadata.smartSearches {
                let sourceIdsJson: String?
                if !searchInfo.sourceIDs.isEmpty {
                    sourceIdsJson = try? String(data: JSONEncoder().encode(searchInfo.sourceIDs), encoding: .utf8)
                } else {
                    sourceIdsJson = nil
                }

                _ = await withStore {
                    $0.createSmartSearch(
                        name: searchInfo.name,
                        query: searchInfo.query,
                        libraryId: libraryId,
                        sourceIdsJson: sourceIdsJson,
                        maxResults: Int64(searchInfo.maxResults),
                        feedsToInbox: searchInfo.feedsToInbox ?? false,
                        autoRefreshEnabled: searchInfo.autoRefreshEnabled ?? false,
                        refreshIntervalSeconds: Int64(searchInfo.refreshIntervalSeconds ?? 3600)
                    )
                }
                smartSearchesCreated += 1
            }
        }

        // Phase 4: Import publications
        for pubPreview in preview.publications {
            do {
                let headers = pubPreview.message.headers
                let sourceLibraryID = UUID(uuidString: headers[MboxHeader.sourceLibraryID] ?? "")
                let targetLibraryId = sourceLibraryID.flatMap { libraryMap[$0] }

                guard let libraryId = targetLibraryId else {
                    publicationsSkipped += 1
                    continue
                }

                try await importPublication(from: pubPreview, to: libraryId, collectionMap: collectionMap)
                publicationsImported += 1
            } catch {
                errors.append(MboxImportErrorInfo(
                    citeKey: pubPreview.citeKey,
                    description: error.localizedDescription
                ))
            }
        }

        // Handle duplicates
        for duplicate in preview.duplicates {
            let action: DuplicateAction
            switch options.duplicateHandling {
            case .skip: action = .skip
            case .replace: action = .replace
            case .merge: action = .merge
            case .askEach: action = .skip
            }

            switch action {
            case .skip:
                publicationsSkipped += 1
            case .replace:
                do {
                    let existing = await withStore { $0.findByCiteKey(citeKey: duplicate.existingCiteKey) }
                    if let pub = existing {
                        await withStore { $0.deletePublications(ids: [pub.id]) }
                    }
                    let headers = duplicate.importPublication.message.headers
                    let sourceLibraryID = UUID(uuidString: headers[MboxHeader.sourceLibraryID] ?? "")
                    let targetLibraryId = sourceLibraryID.flatMap { libraryMap[$0] } ?? libraryMap.values.first
                    if let libraryId = targetLibraryId {
                        try await importPublication(from: duplicate.importPublication, to: libraryId, collectionMap: collectionMap)
                    }
                    publicationsImported += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
                    ))
                }
            case .merge:
                do {
                    try await mergePublication(duplicate)
                    publicationsMerged += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
                    ))
                }
            }
        }

        // Phase 5: Import muted items
        if options.importMutedItems {
            for mutedItem in preview.manifest.mutedItems {
                _ = await withStore { $0.createMutedItem(muteType: mutedItem.type, value: mutedItem.value) }
                mutedItemsImported += 1
            }
        }

        // Phase 6: Import dismissed papers
        if options.importDismissedPapers {
            for dismissedPaper in preview.manifest.dismissedPapers {
                guard dismissedPaper.hasIdentifier else { continue }
                _ = await withStore {
                    $0.dismissPaper(doi: dismissedPaper.doi, arxivId: dismissedPaper.arxivID, bibcode: dismissedPaper.bibcode)
                }
                dismissedPapersImported += 1
            }
        }

        logger.info("Import complete: \(publicationsImported) imported, \(publicationsMerged) merged, \(publicationsSkipped) skipped")

        return EverythingImportResult(
            librariesCreated: librariesCreated,
            librariesMerged: librariesMerged,
            collectionsCreated: collectionsCreated,
            smartSearchesCreated: smartSearchesCreated,
            publicationsImported: publicationsImported,
            publicationsSkipped: publicationsSkipped,
            publicationsMerged: publicationsMerged,
            mutedItemsImported: mutedItemsImported,
            dismissedPapersImported: dismissedPapersImported,
            errors: errors
        )
    }

    // MARK: - Version Detection

    public func detectExportVersion(_ messages: [MboxMessage]) -> ExportVersion {
        if messages.first(where: { $0.headers[MboxHeader.exportType] == "everything" }) != nil {
            return .everything
        }
        if messages.first(where: { $0.subject == "[imbib Library Export]" }) != nil {
            return .singleLibrary
        }
        return .unknown
    }

    // MARK: - Parsing

    private func parseManifest(from message: MboxMessage) -> EverythingManifest? {
        guard let jsonData = message.body.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EverythingManifest.self, from: jsonData)
    }

    private func parseLibraryMetadata(from message: MboxMessage) -> LibraryMetadata? {
        guard let jsonData = message.body.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let metadata = try? decoder.decode(LibraryMetadata.self, from: jsonData) {
            return metadata
        }

        let typeString = message.headers[MboxHeader.libraryType]
        let libraryType = typeString.flatMap { LibraryType(rawValue: $0) }

        return LibraryMetadata(
            libraryID: UUID(uuidString: message.headers[MboxHeader.libraryID] ?? ""),
            name: message.headers[MboxHeader.libraryName] ?? "Imported Library",
            bibtexPath: message.headers[MboxHeader.libraryBibtexPath],
            exportVersion: message.headers[MboxHeader.exportVersion] ?? "2.0",
            exportDate: Date(),
            libraryType: libraryType
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
            id: id, citeKey: citeKey, title: title, authors: authors,
            year: year > 0 ? year : nil, entryType: entryType, doi: doi, arxivID: arxivID,
            hasAbstract: !message.body.isEmpty, fileCount: fileCount,
            collectionIDs: collectionIDs, rawBibTeX: rawBibTeX, message: message
        )
    }

    // MARK: - Conflict Detection

    private func checkLibraryConflict(_ metadata: LibraryMetadata) async -> LibraryConflict? {
        guard let libraryID = metadata.libraryID else { return nil }

        if let existing = await findExistingLibrary(id: libraryID, type: metadata.libraryType) {
            return LibraryConflict(
                id: UUID(),
                importName: metadata.name,
                importType: metadata.libraryType ?? .user,
                existingID: existing.id,
                existingName: existing.name
            )
        }
        return nil
    }

    private func findExistingLibrary(id: UUID, type: LibraryType?) async -> LibraryModel? {
        // For system libraries, find by type
        if let type = type {
            let libraries = await withStore { $0.listLibraries() }
            switch type {
            case .inbox:
                return await withStore { $0.getInboxLibrary() }
            case .save, .dismissed, .exploration:
                // These system libraries can be matched by name convention
                return libraries.first { $0.name.lowercased() == type.rawValue.lowercased() }
            case .user:
                break
            }
        }

        // For user libraries, find by ID
        return await withStore { $0.getLibrary(id: id) }
    }

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

    // MARK: - Publication Import

    private func importPublication(
        from preview: PublicationPreview,
        to libraryId: UUID,
        collectionMap: [UUID: UUID]
    ) async throws {
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

        let importedIds = await withStore { $0.importBibTeX(bibtex, libraryId: libraryId) }

        // Add to collections
        if let pubId = importedIds.first {
            for collectionID in preview.collectionIDs {
                if let rustCollId = collectionMap[collectionID] {
                    await withStore { $0.addToCollection(publicationIds: [pubId], collectionId: rustCollId) }
                }
            }
        }
    }

    private func mergePublication(_ duplicate: DuplicateInfo) async throws {
        let preview = duplicate.importPublication
        let existing = await withStore { $0.findByCiteKey(citeKey: duplicate.existingCiteKey) }

        guard let pub = existing else { return }

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
}

// MARK: - Import Errors

/// Errors that can occur during Everything import.
public enum EverythingImportError: Error, LocalizedError {
    case wrongExportVersion(ExportVersion)
    case parseError(String)
    case saveError(String)

    public var errorDescription: String? {
        switch self {
        case .wrongExportVersion(let version):
            return "This file is not an Everything export (detected: \(version.rawValue)). Use the standard importer for single-library exports."
        case .parseError(let reason):
            return "Parse error: \(reason)"
        case .saveError(let reason):
            return "Save error: \(reason)"
        }
    }
}
