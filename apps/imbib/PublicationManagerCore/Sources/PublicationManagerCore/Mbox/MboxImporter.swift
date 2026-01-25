//
//  MboxImporter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation
import CoreData
import OSLog

// MARK: - Mbox Importer

/// Imports mbox files into imbib libraries.
public actor MboxImporter {

    private let context: NSManagedObjectContext
    private let options: MboxImportOptions
    private let parser: MboxParser
    private let repository: PublicationRepository
    private let logger = Logger(subsystem: "PublicationManagerCore", category: "MboxImporter")

    public init(context: NSManagedObjectContext, options: MboxImportOptions = .default) {
        self.context = context
        self.options = options
        self.parser = MboxParser()
        self.repository = PublicationRepository()
    }

    // MARK: - Public API

    /// Prepare an import preview from an mbox file.
    /// - Parameter url: URL of the mbox file
    /// - Returns: Preview data for user confirmation
    public func prepareImport(from url: URL) async throws -> MboxImportPreview {
        logger.info("Preparing import preview from: \(url.path)")

        let messages = try await parser.parse(url: url)

        var libraryMetadata: LibraryMetadata?
        var publications: [PublicationPreview] = []
        var duplicates: [DuplicateInfo] = []
        var parseErrors: [ParseError] = []

        for (index, message) in messages.enumerated() {
            // Check if this is the library header
            if message.subject == "[imbib Library Export]" {
                libraryMetadata = parseLibraryMetadata(from: message)
                continue
            }

            // Parse as publication
            do {
                let preview = try await parsePublicationPreview(from: message, index: index)

                // Check for duplicates using repository's indexed lookups
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

        logger.info("Preview prepared: \(publications.count) new, \(duplicates.count) duplicates, \(parseErrors.count) errors")

        return MboxImportPreview(
            libraryMetadata: libraryMetadata,
            publications: publications,
            duplicates: duplicates,
            parseErrors: parseErrors
        )
    }

    /// Execute the import after user confirmation.
    /// - Parameters:
    ///   - preview: The import preview
    ///   - library: Target library (or nil to create new)
    ///   - selectedPublications: UUIDs of publications to import (nil = all)
    ///   - duplicateDecisions: How to handle each duplicate (UUID -> action)
    /// - Returns: Import result
    public func executeImport(
        _ preview: MboxImportPreview,
        to library: CDLibrary?,
        selectedPublications: Set<UUID>? = nil,
        duplicateDecisions: [UUID: DuplicateAction] = [:]
    ) async throws -> MboxImportResult {
        logger.info("Executing import")

        var importedCount = 0
        var skippedCount = 0
        var mergedCount = 0
        var errors: [MboxImportErrorInfo] = []

        // Create or use library
        let targetLibrary: CDLibrary
        if let existingLibrary = library {
            targetLibrary = existingLibrary
        } else if let metadata = preview.libraryMetadata {
            targetLibrary = try await createLibrary(from: metadata)
        } else {
            targetLibrary = try await createDefaultLibrary()
        }

        // Create collections map for assignment
        let collectionsMap = try await createCollections(
            from: preview.libraryMetadata?.collections ?? [],
            in: targetLibrary
        )

        // Import new publications
        for pubPreview in preview.publications {
            // Check if selected
            if let selected = selectedPublications, !selected.contains(pubPreview.id) {
                skippedCount += 1
                continue
            }

            do {
                try await importPublication(
                    from: pubPreview,
                    to: targetLibrary,
                    collectionsMap: collectionsMap
                )
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
                    try await replacePublication(duplicate, in: targetLibrary, collectionsMap: collectionsMap)
                    importedCount += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
                    ))
                }
            case .merge:
                do {
                    try await mergePublication(duplicate, in: targetLibrary, collectionsMap: collectionsMap)
                    mergedCount += 1
                } catch {
                    errors.append(MboxImportErrorInfo(
                        citeKey: duplicate.importPublication.citeKey,
                        description: error.localizedDescription
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

        logger.info("Import complete: \(importedCount) imported, \(mergedCount) merged, \(skippedCount) skipped, \(errors.count) errors")

        return MboxImportResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            mergedCount: mergedCount,
            errors: errors
        )
    }

    // MARK: - Preview Parsing

    /// Parse library metadata from header message.
    private func parseLibraryMetadata(from message: MboxMessage) -> LibraryMetadata? {
        // Parse JSON body
        guard let jsonData = message.body.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let metadata = try? decoder.decode(LibraryMetadata.self, from: jsonData) {
            return metadata
        }

        // Fallback: extract from headers
        return LibraryMetadata(
            libraryID: UUID(uuidString: message.headers[MboxHeader.libraryID] ?? ""),
            name: message.headers[MboxHeader.libraryName] ?? "Imported Library",
            bibtexPath: message.headers[MboxHeader.libraryBibtexPath],
            exportVersion: message.headers[MboxHeader.exportVersion] ?? "1.0",
            exportDate: Date()
        )
    }

    /// Parse publication preview from message.
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

    // MARK: - Duplicate Detection

    /// Find existing publication by UUID, cite key, DOI, or arXiv ID.
    /// Reuses PublicationRepository's indexed lookup methods for efficiency.
    private func findExistingPublication(uuid: UUID?, citeKey: String?, doi: String?, arxivID: String?) async -> CDPublication? {
        // Check by UUID first (mbox round-trip preservation)
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

        // Use repository's indexed lookups for standard identifiers
        // DOI - most reliable identifier
        if let doi = doi, !doi.isEmpty {
            if let pub = await repository.findByDOI(doi) {
                return pub
            }
        }

        // arXiv ID - common in physics/CS
        if let arxivID = arxivID, !arxivID.isEmpty {
            if let pub = await repository.findByArXiv(arxivID) {
                return pub
            }
        }

        // Cite key - fallback for BibTeX-sourced publications
        if let citeKey = citeKey, !citeKey.isEmpty {
            if let pub = await repository.findByCiteKey(citeKey) {
                return pub
            }
        }

        return nil
    }

    // MARK: - Import Execution

    /// Import a single publication from preview.
    private func importPublication(
        from preview: PublicationPreview,
        to library: CDLibrary,
        collectionsMap: [UUID: CDCollection]
    ) async throws {
        try context.performAndWait {
            let publication = CDPublication(context: context)

            // Set ID (preserve if requested)
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

            // Add to library
            publication.addToLibrary(library)

            // Add to collections
            for collectionID in preview.collectionIDs {
                if let collection = collectionsMap[collectionID] {
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

                    // Get relative path from custom header or generate
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

    /// Replace an existing publication with imported data.
    private func replacePublication(
        _ duplicate: DuplicateInfo,
        in library: CDLibrary,
        collectionsMap: [UUID: CDCollection]
    ) async throws {
        try context.performAndWait {
            // Find and delete existing
            let request = NSFetchRequest<CDPublication>(entityName: "CDPublication")
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
            to: library,
            collectionsMap: collectionsMap
        )
    }

    /// Merge imported data into existing publication.
    private func mergePublication(
        _ duplicate: DuplicateInfo,
        in library: CDLibrary,
        collectionsMap: [UUID: CDCollection]
    ) async throws {
        let preview = duplicate.importPublication

        try context.performAndWait {
            let request = NSFetchRequest<CDPublication>(entityName: "CDPublication")
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

            // Add to collections
            for collectionID in preview.collectionIDs {
                if let collection = collectionsMap[collectionID] {
                    existing.addToCollection(collection)
                }
            }

            // Add to library
            existing.addToLibrary(library)

            existing.dateModified = Date()
        }
    }

    // MARK: - Library and Collection Creation

    /// Create a new library from metadata.
    private func createLibrary(from metadata: LibraryMetadata) async throws -> CDLibrary {
        try context.performAndWait {
            let library = CDLibrary(context: context)
            if options.preserveUUIDs, let id = metadata.libraryID {
                library.id = id
            } else {
                library.id = UUID()
            }
            library.name = metadata.name
            library.bibFilePath = metadata.bibtexPath
            library.dateCreated = Date()
            return library
        }
    }

    /// Create a default library for import.
    private func createDefaultLibrary() async throws -> CDLibrary {
        try context.performAndWait {
            let library = CDLibrary(context: context)
            library.id = UUID()
            library.name = "Imported Library"
            library.dateCreated = Date()
            return library
        }
    }

    /// Create collections from metadata.
    private func createCollections(
        from collectionInfos: [CollectionInfo],
        in library: CDLibrary
    ) async throws -> [UUID: CDCollection] {
        var collectionsMap: [UUID: CDCollection] = [:]

        try context.performAndWait {
            // First pass: create all collections
            for info in collectionInfos {
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

                collectionsMap[info.id] = collection
            }

            // Second pass: set parent relationships
            for info in collectionInfos {
                if let parentID = info.parentID,
                   let child = collectionsMap[info.id],
                   let parent = collectionsMap[parentID] {
                    child.parentCollection = parent
                }
            }
        }

        return collectionsMap
    }

    // MARK: - Helpers

    /// Convert import option to duplicate action.
    private func duplicateActionFromOption() -> DuplicateAction {
        switch options.duplicateHandling {
        case .skip:
            return .skip
        case .replace:
            return .replace
        case .merge:
            return .merge
        case .askEach:
            return .skip // Default to skip if askEach but no decision provided
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
