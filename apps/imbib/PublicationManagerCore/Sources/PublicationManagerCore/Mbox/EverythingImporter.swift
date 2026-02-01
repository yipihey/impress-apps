//
//  EverythingImporter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData
import OSLog

// MARK: - Everything Importer

/// Imports Everything mbox exports with phased reconstruction.
public actor EverythingImporter {

    private let context: NSManagedObjectContext
    private let options: EverythingImportOptions
    private let parser: MboxParser
    private let repository: PublicationRepository
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "EverythingImporter")

    public init(context: NSManagedObjectContext, options: EverythingImportOptions = .default) {
        self.context = context
        self.options = options
        self.parser = MboxParser()
        self.repository = PublicationRepository()
    }

    // MARK: - Public API

    /// Prepare an import preview from an Everything mbox file.
    /// - Parameter url: URL of the mbox file
    /// - Returns: Preview data for user confirmation
    public func prepareImport(from url: URL) async throws -> EverythingImportPreview {
        logger.info("Preparing Everything import from: \(url.path)")

        let messages = try await parser.parse(url: url)

        // Detect export version
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

        // Parse manifest and library headers
        var libraryMetadataByID: [UUID: LibraryMetadata] = [:]

        for (index, message) in messages.enumerated() {
            // Parse manifest
            if message.subject == "[imbib Everything Export]" {
                manifest = parseManifest(from: message)
                continue
            }

            // Parse library headers
            if message.subject == "[imbib Library Export]" {
                if let metadata = parseLibraryMetadata(from: message) {
                    if let libraryID = metadata.libraryID {
                        libraryMetadataByID[libraryID] = metadata

                        // Check for conflicts
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

            // Parse publications
            do {
                let preview = try await parsePublicationPreview(from: message, index: index)

                // Check for duplicates
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
                        existingTitle: existing.title ?? "Untitled",
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
    /// - Parameter preview: The import preview
    /// - Returns: Import result
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

        // Phase 1: Create/resolve libraries
        var libraryMap: [UUID: CDLibrary] = [:]  // Import ID -> Core Data library
        var collectionMap: [UUID: CDCollection] = [:]  // Import ID -> Core Data collection
        var smartSearchMap: [UUID: CDSmartSearch] = [:]  // Import ID -> Core Data smart search

        for libraryPreview in preview.libraries {
            let metadata = libraryPreview.metadata
            let resolution = options.libraryConflictResolutions[libraryPreview.id] ?? .merge

            do {
                if let existing = await findExistingLibrary(id: libraryPreview.id, type: metadata.libraryType) {
                    switch resolution {
                    case .merge:
                        libraryMap[libraryPreview.id] = existing
                        librariesMerged += 1
                    case .replace:
                        // Delete existing and create new
                        context.performAndWait { context.delete(existing) }
                        let newLibrary = try await createLibrary(from: metadata)
                        libraryMap[libraryPreview.id] = newLibrary
                        librariesCreated += 1
                    case .rename:
                        let newLibrary = try await createLibrary(from: metadata, rename: true)
                        libraryMap[libraryPreview.id] = newLibrary
                        librariesCreated += 1
                    case .skip:
                        continue
                    }
                } else {
                    let library = try await createLibrary(from: metadata)
                    libraryMap[libraryPreview.id] = library
                    librariesCreated += 1
                }
            } catch {
                errors.append(MboxImportErrorInfo(
                    citeKey: nil,
                    description: "Failed to create library '\(metadata.name)': \(error.localizedDescription)"
                ))
            }
        }

        // Phase 2: Create collections (with parent-child hierarchy)
        for libraryPreview in preview.libraries {
            guard let library = libraryMap[libraryPreview.id] else { continue }
            let metadata = libraryPreview.metadata

            // First pass: create all collections
            for collectionInfo in metadata.collections {
                let collection = try await createCollection(from: collectionInfo, in: library)
                collectionMap[collectionInfo.id] = collection
                collectionsCreated += 1
            }

            // Second pass: set parent relationships
            for collectionInfo in metadata.collections {
                if let parentID = collectionInfo.parentID,
                   let child = collectionMap[collectionInfo.id],
                   let parent = collectionMap[parentID] {
                    context.performAndWait {
                        child.parentCollection = parent
                    }
                }
            }
        }

        // Phase 3: Create smart searches
        for libraryPreview in preview.libraries {
            guard let library = libraryMap[libraryPreview.id] else { continue }
            let metadata = libraryPreview.metadata

            for searchInfo in metadata.smartSearches {
                let search = try await createSmartSearch(from: searchInfo, in: library)
                smartSearchMap[searchInfo.id] = search

                // Link result collection if it exists
                if let resultCollectionID = searchInfo.resultCollectionID,
                   let resultCollection = collectionMap[resultCollectionID] {
                    context.performAndWait {
                        search.resultCollection = resultCollection
                        resultCollection.smartSearch = search
                    }
                }
                smartSearchesCreated += 1
            }
        }

        // Phase 4: Import publications
        for pubPreview in preview.publications {
            do {
                try await importPublication(
                    from: pubPreview,
                    libraryMap: libraryMap,
                    collectionMap: collectionMap,
                    smartSearchMap: smartSearchMap
                )
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
            case .skip:
                action = .skip
            case .replace:
                action = .replace
            case .merge:
                action = .merge
            case .askEach:
                action = .skip  // Default to skip if not specified
            }

            switch action {
            case .skip:
                publicationsSkipped += 1
            case .replace:
                do {
                    try await replacePublication(
                        duplicate,
                        libraryMap: libraryMap,
                        collectionMap: collectionMap
                    )
                    publicationsImported += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
                    ))
                }
            case .merge:
                do {
                    try await mergePublication(
                        duplicate,
                        libraryMap: libraryMap,
                        collectionMap: collectionMap
                    )
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
                do {
                    try await importMutedItem(mutedItem)
                    mutedItemsImported += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: nil,
                        description: "Failed to import muted item: \(error.localizedDescription)"
                    ))
                }
            }
        }

        // Phase 6: Import dismissed papers
        if options.importDismissedPapers {
            for dismissedPaper in preview.manifest.dismissedPapers {
                do {
                    try await importDismissedPaper(dismissedPaper)
                    dismissedPapersImported += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: nil,
                        description: "Failed to import dismissed paper: \(error.localizedDescription)"
                    ))
                }
            }
        }

        // Save context
        try context.performAndWait {
            if context.hasChanges {
                try context.save()
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

    /// Detect the export version from parsed messages.
    public func detectExportVersion(_ messages: [MboxMessage]) -> ExportVersion {
        // Check for Everything export manifest
        if messages.first(where: { $0.headers[MboxHeader.exportType] == "everything" }) != nil {
            return .everything
        }

        // Check for single library export
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
        // Parse JSON body
        guard let jsonData = message.body.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let metadata = try? decoder.decode(LibraryMetadata.self, from: jsonData) {
            return metadata
        }

        // Fallback: extract from headers
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

        // Parse year from date
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: message.date)

        // Count file attachments (exclude BibTeX)
        let fileCount = message.attachments.filter { $0.contentType != "text/x-bibtex" }.count

        // Parse collection IDs
        var collectionIDs: [UUID] = []
        if let collectionsHeader = headers[MboxHeader.imbibCollections] {
            collectionIDs = collectionsHeader.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }

        // Extract raw BibTeX from attachment
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

    // MARK: - Conflict Detection

    private func checkLibraryConflict(_ metadata: LibraryMetadata) async -> LibraryConflict? {
        guard let libraryID = metadata.libraryID else { return nil }

        if let existing = await findExistingLibrary(id: libraryID, type: metadata.libraryType) {
            return LibraryConflict(
                id: UUID(),
                importName: metadata.name,
                importType: metadata.libraryType ?? .user,
                existingID: existing.id,
                existingName: existing.displayName
            )
        }
        return nil
    }

    private func findExistingLibrary(id: UUID, type: LibraryType?) async -> CDLibrary? {
        // For system libraries, find by type
        if let type = type {
            switch type {
            case .inbox:
                return await findLibraryByPredicate(NSPredicate(format: "isInbox == YES"))
            case .save:
                return await findLibraryByPredicate(NSPredicate(format: "isSaveLibrary == YES"))
            case .dismissed:
                return await findLibraryByPredicate(NSPredicate(format: "isDismissedLibrary == YES"))
            case .exploration:
                return await findLibraryByPredicate(NSPredicate(format: "isSystemLibrary == YES AND isInbox == NO AND isSaveLibrary == NO AND isDismissedLibrary == NO"))
            case .user:
                break
            }
        }

        // For user libraries, find by ID
        return await findLibraryByPredicate(NSPredicate(format: "id == %@", id as CVarArg))
    }

    private func findLibraryByPredicate(_ predicate: NSPredicate) async -> CDLibrary? {
        context.performAndWait {
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            request.predicate = predicate
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }
    }

    private func findExistingPublication(uuid: UUID?, citeKey: String?, doi: String?, arxivID: String?) async -> CDPublication? {
        // Check by UUID first
        if let uuid = uuid {
            let existing = context.performAndWait {
                let request = NSFetchRequest<CDPublication>(entityName: "Publication")
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1
                return try? context.fetch(request).first
            }
            if let pub = existing {
                return pub
            }
        }

        // Use repository's indexed lookups
        if let doi = doi, !doi.isEmpty {
            if let pub = await repository.findByDOI(doi) {
                return pub
            }
        }

        if let arxivID = arxivID, !arxivID.isEmpty {
            if let pub = await repository.findByArXiv(arxivID) {
                return pub
            }
        }

        if let citeKey = citeKey, !citeKey.isEmpty {
            if let pub = await repository.findByCiteKey(citeKey) {
                return pub
            }
        }

        return nil
    }

    // MARK: - Creation

    private func createLibrary(from metadata: LibraryMetadata, rename: Bool = false) async throws -> CDLibrary {
        try context.performAndWait {
            let library = CDLibrary(context: context)
            if options.preserveUUIDs, let id = metadata.libraryID {
                library.id = id
            } else {
                library.id = UUID()
            }

            if rename {
                library.name = "\(metadata.name) (Imported)"
            } else {
                library.name = metadata.name
            }

            library.bibFilePath = metadata.bibtexPath
            library.dateCreated = Date()
            library.isDefault = metadata.isDefault ?? false
            library.sortOrder = Int16(metadata.sortOrder ?? 0)

            // Set library type flags
            if let type = metadata.libraryType {
                switch type {
                case .inbox:
                    library.isInbox = true
                case .save:
                    library.isSaveLibrary = true
                case .dismissed:
                    library.isDismissedLibrary = true
                case .exploration:
                    library.isSystemLibrary = true
                    library.isLocalOnly = true
                case .user:
                    break
                }
            }

            return library
        }
    }

    private func createCollection(from info: CollectionInfo, in library: CDLibrary) async throws -> CDCollection {
        try context.performAndWait {
            let collection = CDCollection(context: context)
            if options.preserveUUIDs {
                collection.id = info.id
            } else {
                collection.id = UUID()
            }
            collection.name = info.name
            collection.isSmartCollection = info.isSmartCollection
            collection.predicate = info.predicate
            collection.library = library
            return collection
        }
    }

    private func createSmartSearch(from info: SmartSearchInfo, in library: CDLibrary) async throws -> CDSmartSearch {
        try context.performAndWait {
            let search = CDSmartSearch(context: context)
            if options.preserveUUIDs {
                search.id = info.id
            } else {
                search.id = UUID()
            }
            search.name = info.name
            search.query = info.query
            search.sources = info.sourceIDs
            search.maxResults = Int16(info.maxResults)
            search.dateCreated = Date()
            search.library = library

            // Set feed configuration
            if let feedsToInbox = info.feedsToInbox {
                search.feedsToInbox = feedsToInbox
            }
            if let autoRefresh = info.autoRefreshEnabled {
                search.autoRefreshEnabled = autoRefresh
            }
            if let interval = info.refreshIntervalSeconds {
                search.refreshIntervalSeconds = Int32(interval)
            }

            return search
        }
    }

    // MARK: - Publication Import

    private func importPublication(
        from preview: PublicationPreview,
        libraryMap: [UUID: CDLibrary],
        collectionMap: [UUID: CDCollection],
        smartSearchMap: [UUID: CDSmartSearch]
    ) async throws {
        try context.performAndWait {
            let publication = CDPublication(context: context)

            // Set ID
            if options.preserveUUIDs {
                publication.id = preview.id
            } else {
                publication.id = UUID()
            }

            // Set core fields
            publication.citeKey = preview.citeKey
            publication.entryType = preview.entryType
            publication.title = preview.title
            publication.year = Int16(preview.year ?? 0)
            publication.abstract = preview.message.body.isEmpty ? nil : preview.message.body
            publication.dateAdded = Date()
            publication.dateModified = Date()
            publication.citationCount = -1
            publication.referenceCount = -1

            // Set identifiers
            if let doi = preview.doi {
                publication.doi = doi
            }
            if let arxivID = preview.arxivID {
                var fields = publication.fields
                fields["eprint"] = arxivID
                publication.fields = fields
            }

            // Set raw BibTeX
            publication.rawBibTeX = preview.rawBibTeX

            // Parse and set fields from BibTeX if available
            if let bibtex = preview.rawBibTeX {
                if let items = try? BibTeXParser().parse(bibtex),
                   let firstItem = items.first,
                   case .entry(let entry) = firstItem {
                    publication.update(from: entry, context: context)
                }
            }

            // Set triage state
            if options.importTriageState {
                let headers = preview.message.headers
                publication.isRead = headers[MboxHeader.isRead] == "true"
                publication.isStarred = headers[MboxHeader.isStarred] == "true"
            }

            // Add to libraries
            let headers = preview.message.headers
            if let sourceLibraryIDString = headers[MboxHeader.sourceLibraryID],
               let sourceLibraryID = UUID(uuidString: sourceLibraryIDString),
               let library = libraryMap[sourceLibraryID] {
                publication.addToLibrary(library)
            }

            // Add to additional libraries
            if let additionalIDsString = headers[MboxHeader.additionalLibraryIDs] {
                let additionalIDs = additionalIDsString.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                for libraryID in additionalIDs {
                    if let library = libraryMap[libraryID] {
                        publication.addToLibrary(library)
                    }
                }
            }

            // Add to collections
            for collectionID in preview.collectionIDs {
                if let collection = collectionMap[collectionID] {
                    publication.addToCollection(collection)
                }
            }

            // Import file attachments
            if options.importFiles {
                for attachment in preview.message.attachments {
                    // Skip BibTeX attachment
                    if attachment.contentType == "text/x-bibtex" {
                        continue
                    }

                    let linkedFile = CDLinkedFile(context: context)
                    linkedFile.id = UUID()
                    linkedFile.filename = attachment.filename
                    linkedFile.dateAdded = Date()
                    linkedFile.fileData = attachment.data
                    linkedFile.fileSize = Int64(attachment.data.count)
                    linkedFile.mimeType = attachment.contentType

                    if let path = attachment.customHeaders[MboxHeader.linkedFilePath] {
                        linkedFile.relativePath = path
                    } else {
                        linkedFile.relativePath = attachment.filename
                    }

                    linkedFile.publication = publication
                }
            }
        }
    }

    private func replacePublication(
        _ duplicate: DuplicateInfo,
        libraryMap: [UUID: CDLibrary],
        collectionMap: [UUID: CDCollection]
    ) async throws {
        try context.performAndWait {
            // Find and delete existing
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "citeKey == %@", duplicate.existingCiteKey)
            request.fetchLimit = 1

            if let existing = try context.fetch(request).first {
                // Delete linked files
                for linkedFile in existing.linkedFiles ?? [] {
                    context.delete(linkedFile)
                }
                context.delete(existing)
            }
        }

        // Import as new
        try await importPublication(
            from: duplicate.importPublication,
            libraryMap: libraryMap,
            collectionMap: collectionMap,
            smartSearchMap: [:]
        )
    }

    private func mergePublication(
        _ duplicate: DuplicateInfo,
        libraryMap: [UUID: CDLibrary],
        collectionMap: [UUID: CDCollection]
    ) async throws {
        let preview = duplicate.importPublication

        try context.performAndWait {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "citeKey == %@", duplicate.existingCiteKey)
            request.fetchLimit = 1

            guard let existing = try context.fetch(request).first else {
                return
            }

            // Merge fields - only update empty fields
            if existing.abstract == nil || existing.abstract?.isEmpty == true {
                existing.abstract = preview.message.body.isEmpty ? nil : preview.message.body
            }

            if existing.doi == nil, let doi = preview.doi {
                existing.doi = doi
            }

            // Add to libraries
            let headers = preview.message.headers
            if let sourceLibraryIDString = headers[MboxHeader.sourceLibraryID],
               let sourceLibraryID = UUID(uuidString: sourceLibraryIDString),
               let library = libraryMap[sourceLibraryID] {
                existing.addToLibrary(library)
            }

            // Add to collections
            for collectionID in preview.collectionIDs {
                if let collection = collectionMap[collectionID] {
                    existing.addToCollection(collection)
                }
            }

            existing.dateModified = Date()
        }
    }

    // MARK: - Muted Items and Dismissed Papers

    private func importMutedItem(_ info: MutedItemInfo) async throws {
        try context.performAndWait {
            // Check if already exists
            let request = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")
            request.predicate = NSPredicate(format: "type == %@ AND value == %@", info.type, info.value)
            request.fetchLimit = 1

            if try context.fetch(request).first != nil {
                return  // Already exists
            }

            let mutedItem = CDMutedItem(context: context)
            mutedItem.id = UUID()
            mutedItem.type = info.type
            mutedItem.value = info.value
            mutedItem.dateAdded = info.dateAdded ?? Date()
        }
    }

    private func importDismissedPaper(_ info: DismissedPaperInfo) async throws {
        guard info.hasIdentifier else { return }

        try context.performAndWait {
            // Check if already exists
            var predicates: [NSPredicate] = []
            if let doi = info.doi {
                predicates.append(NSPredicate(format: "doi == %@", doi))
            }
            if let arxivID = info.arxivID {
                predicates.append(NSPredicate(format: "arxivID == %@", arxivID))
            }
            if let bibcode = info.bibcode {
                predicates.append(NSPredicate(format: "bibcode == %@", bibcode))
            }

            let request = NSFetchRequest<CDDismissedPaper>(entityName: "DismissedPaper")
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
            request.fetchLimit = 1

            if try context.fetch(request).first != nil {
                return  // Already exists
            }

            let dismissed = CDDismissedPaper(context: context)
            dismissed.id = UUID()
            dismissed.doi = info.doi
            dismissed.arxivID = info.arxivID
            dismissed.bibcode = info.bibcode
            dismissed.dateDismissed = info.dateDismissed ?? Date()
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
