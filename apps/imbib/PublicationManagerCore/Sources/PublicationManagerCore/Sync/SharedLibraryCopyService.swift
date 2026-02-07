//
//  SharedLibraryCopyService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
import OSLog

/// Options controlling what content is included when sharing a library or collection.
public struct ShareOptions: Equatable, Sendable, Codable {
    public var includeNotes: Bool
    public var includePDFs: Bool
    public var includeFlags: Bool
    public var includeTags: Bool

    public init(
        includeNotes: Bool = true,
        includePDFs: Bool = false,
        includeFlags: Bool = true,
        includeTags: Bool = true
    ) {
        self.includeNotes = includeNotes
        self.includePDFs = includePDFs
        self.includeFlags = includeFlags
        self.includeTags = includeTags
    }

    public static let `default` = ShareOptions()
    public static let all = ShareOptions(includeNotes: true, includePDFs: true, includeFlags: true, includeTags: true)
    public static let minimal = ShareOptions(includeNotes: false, includePDFs: false, includeFlags: false, includeTags: false)
}

/// Deep-copies library or collection content into a new CDLibrary in the shared store.
///
/// CloudKit's `NSPersistentCloudKitContainer.share(_:to:)` moves objects to the shared zone,
/// which would sever many-to-many relationships with other private-store libraries.
/// This service creates safe copies instead, leaving private data untouched.
///
/// Both library sharing and collection sharing produce a CDLibrary in the shared store.
/// The only difference is the source of content being copied.
public actor SharedLibraryCopyService {

    public static let shared = SharedLibraryCopyService()

    private init() {}

    // MARK: - Public API

    /// Copy an entire library's content to the shared store.
    ///
    /// Creates a new CDLibrary in the shared store with deep-copied collections and publications.
    /// - Parameters:
    ///   - library: The source library to copy
    ///   - context: The managed object context to use
    /// - Returns: The new CDLibrary in the shared store
    public func copyLibraryToSharedStore(
        _ library: CDLibrary,
        context: NSManagedObjectContext,
        options: ShareOptions = .default
    ) throws -> CDLibrary {
        guard let sharedStore = PersistenceController.shared.sharedStore else {
            throw SharedLibraryCopyError.sharedStoreUnavailable
        }

        return try context.performAndWait {
            let targetLibrary = CDLibrary(context: context)
            context.assign(targetLibrary, to: sharedStore)

            targetLibrary.id = UUID()
            targetLibrary.name = library.name
            targetLibrary.dateCreated = Date()
            targetLibrary.isDefault = false
            targetLibrary.isInbox = false
            targetLibrary.isSystemLibrary = false
            targetLibrary.isSaveLibrary = false
            targetLibrary.isDismissedLibrary = false
            targetLibrary.isLocalOnly = false

            // Track publications we've already copied to avoid duplicates across collections
            var publicationMap: [UUID: CDPublication] = [:]

            // Copy all root collections and their subtrees
            for collection in library.sortedRootCollections {
                deepCopyCollection(
                    collection,
                    into: targetLibrary,
                    parent: nil,
                    context: context,
                    sharedStore: sharedStore,
                    publicationMap: &publicationMap,
                    options: options
                )
            }

            // Copy publications not in any collection (library-level publications)
            let collectionPubIDs = Set(publicationMap.keys)
            for publication in library.publications ?? [] {
                if !collectionPubIDs.contains(publication.id) {
                    let copied = copyPublication(publication, context: context, sharedStore: sharedStore, options: options)
                    copied.addToLibrary(targetLibrary)
                    publicationMap[publication.id] = copied
                }
            }

            try context.save()
            Logger.sync.info("Copied library '\(library.name)' to shared store: \(publicationMap.count) publications")
            return targetLibrary
        }
    }

    /// Copy a collection (with its subtree and publications) to the shared store.
    ///
    /// Creates a new CDLibrary in the shared store containing the collection and its contents.
    /// - Parameters:
    ///   - collection: The source collection to copy
    ///   - context: The managed object context to use
    ///   - options: What content to include in the shared copy
    /// - Returns: The new CDLibrary wrapper in the shared store
    public func copyCollectionToSharedStore(
        _ collection: CDCollection,
        context: NSManagedObjectContext,
        options: ShareOptions = .default
    ) throws -> CDLibrary {
        guard let sharedStore = PersistenceController.shared.sharedStore else {
            throw SharedLibraryCopyError.sharedStoreUnavailable
        }

        return try context.performAndWait {
            let targetLibrary = CDLibrary(context: context)
            context.assign(targetLibrary, to: sharedStore)

            targetLibrary.id = UUID()
            targetLibrary.name = collection.name
            targetLibrary.dateCreated = Date()
            targetLibrary.isDefault = false
            targetLibrary.isInbox = false
            targetLibrary.isSystemLibrary = false
            targetLibrary.isSaveLibrary = false
            targetLibrary.isDismissedLibrary = false
            targetLibrary.isLocalOnly = false

            var publicationMap: [UUID: CDPublication] = [:]

            deepCopyCollection(
                collection,
                into: targetLibrary,
                parent: nil,
                context: context,
                sharedStore: sharedStore,
                publicationMap: &publicationMap,
                options: options
            )

            try context.save()
            Logger.sync.info("Copied collection '\(collection.name)' to shared store: \(publicationMap.count) publications")
            return targetLibrary
        }
    }

    /// Copy a shared library back to the private store (for unsharing or leaving).
    ///
    /// Creates a private CDLibrary with deep-copied content from a shared library.
    /// - Parameters:
    ///   - sharedLibrary: The shared library to privatize
    ///   - context: The managed object context to use
    ///   - options: What content to include (defaults to all for privatization)
    /// - Returns: The new CDLibrary in the private store
    public func copyToPrivateStore(
        _ sharedLibrary: CDLibrary,
        context: NSManagedObjectContext,
        options: ShareOptions = .all
    ) throws -> CDLibrary {
        guard let privateStore = PersistenceController.shared.privateStore else {
            throw SharedLibraryCopyError.privateStoreUnavailable
        }

        return try context.performAndWait {
            let targetLibrary = CDLibrary(context: context)
            context.assign(targetLibrary, to: privateStore)

            targetLibrary.id = UUID()
            targetLibrary.name = sharedLibrary.name
            targetLibrary.dateCreated = Date()
            targetLibrary.isDefault = false
            targetLibrary.isInbox = false
            targetLibrary.isSystemLibrary = false
            targetLibrary.isSaveLibrary = false
            targetLibrary.isDismissedLibrary = false
            targetLibrary.isLocalOnly = false

            var publicationMap: [UUID: CDPublication] = [:]

            for collection in sharedLibrary.sortedRootCollections {
                deepCopyCollection(
                    collection,
                    into: targetLibrary,
                    parent: nil,
                    context: context,
                    sharedStore: privateStore,
                    publicationMap: &publicationMap,
                    options: options
                )
            }

            let collectionPubIDs = Set(publicationMap.keys)
            for publication in sharedLibrary.publications ?? [] {
                if !collectionPubIDs.contains(publication.id) {
                    let copied = copyPublication(publication, context: context, sharedStore: privateStore, options: options)
                    copied.addToLibrary(targetLibrary)
                    publicationMap[publication.id] = copied
                }
            }

            try context.save()
            Logger.sync.info("Copied shared library '\(sharedLibrary.name)' to private store: \(publicationMap.count) publications")
            return targetLibrary
        }
    }

    // MARK: - Internal Helpers

    private func deepCopyCollection(
        _ source: CDCollection,
        into targetLibrary: CDLibrary,
        parent: CDCollection?,
        context: NSManagedObjectContext,
        sharedStore: NSPersistentStore,
        publicationMap: inout [UUID: CDPublication],
        options: ShareOptions
    ) {
        let newCollection = CDCollection(context: context)
        context.assign(newCollection, to: sharedStore)

        newCollection.id = UUID()
        newCollection.name = source.name
        newCollection.isSmartCollection = false // Don't copy smart predicates to shared
        newCollection.isSmartSearchResults = false
        newCollection.isSystemCollection = false
        newCollection.sortOrder = source.sortOrder
        newCollection.dateCreated = Date()
        newCollection.library = targetLibrary
        newCollection.parentCollection = parent

        // Copy publications in this collection
        for publication in source.publications ?? [] {
            let copied: CDPublication
            if let existing = publicationMap[publication.id] {
                // Already copied this publication (shared across collections)
                copied = existing
            } else {
                copied = copyPublication(publication, context: context, sharedStore: sharedStore, options: options)
                copied.addToLibrary(targetLibrary)
                publicationMap[publication.id] = copied
            }
            copied.addToCollection(newCollection)
        }

        // Recursively copy child collections
        let sortedChildren = (source.childCollections ?? [])
            .filter { !$0.isSystemCollection && !$0.isSmartSearchResults }
            .sorted { $0.sortOrder < $1.sortOrder }

        for child in sortedChildren {
            deepCopyCollection(
                child,
                into: targetLibrary,
                parent: newCollection,
                context: context,
                sharedStore: sharedStore,
                publicationMap: &publicationMap,
                options: options
            )
        }
    }

    private func copyPublication(
        _ source: CDPublication,
        context: NSManagedObjectContext,
        sharedStore: NSPersistentStore,
        options: ShareOptions
    ) -> CDPublication {
        let pub = CDPublication(context: context)
        context.assign(pub, to: sharedStore)

        // Copy scalar fields
        pub.id = UUID()
        pub.citeKey = source.citeKey
        pub.entryType = source.entryType
        pub.title = source.title
        pub.year = source.year
        pub.abstract = source.abstract
        pub.doi = source.doi
        pub.url = source.url
        pub.dateAdded = source.dateAdded
        pub.dateModified = source.dateModified

        // Copy rawBibTeX and rawFields, stripping notes if needed
        if options.includeNotes {
            pub.rawBibTeX = source.rawBibTeX
            pub.rawFields = source.rawFields
        } else {
            pub.rawBibTeX = stripNotesFromBibTeX(source.rawBibTeX)
            pub.rawFields = stripNotesFromRawFields(source.rawFields)
        }

        pub.fieldTimestamps = source.fieldTimestamps

        // Enrichment
        pub.citationCount = source.citationCount
        pub.referenceCount = source.referenceCount
        pub.enrichmentSource = source.enrichmentSource
        pub.enrichmentDate = source.enrichmentDate

        // Online source metadata
        pub.originalSourceID = source.originalSourceID
        pub.pdfLinksJSON = source.pdfLinksJSON
        pub.webURL = source.webURL

        // PDF state (metadata only, not binary data)
        pub.hasPDFDownloaded = false // Recipients resolve PDFs independently
        pub.pdfDownloadDate = nil

        // Extended identifiers
        pub.semanticScholarID = source.semanticScholarID
        pub.openAlexID = source.openAlexID
        pub.arxivIDNormalized = source.arxivIDNormalized
        pub.bibcodeNormalized = source.bibcodeNormalized

        // Read status (fresh for recipient)
        pub.isRead = false

        // Flags
        if options.includeFlags {
            pub.isStarred = source.isStarred
            pub.flagColor = source.flagColor
            pub.flagStyle = source.flagStyle
            pub.flagLength = source.flagLength
        } else {
            pub.isStarred = false
        }

        // Copy authors
        for pubAuthor in source.sortedAuthors {
            let newAuthor = CDAuthor(context: context)
            context.assign(newAuthor, to: sharedStore)
            newAuthor.id = UUID()
            newAuthor.familyName = pubAuthor.familyName
            newAuthor.givenName = pubAuthor.givenName
            newAuthor.nameSuffix = pubAuthor.nameSuffix

            let join = CDPublicationAuthor(context: context)
            context.assign(join, to: sharedStore)
            if let originalJoin = (source.publicationAuthors ?? []).first(where: { $0.author?.id == pubAuthor.id }) {
                join.order = originalJoin.order
            }
            join.publication = pub
            join.author = newAuthor
        }

        // Copy tags
        if options.includeTags {
            for tag in source.tags ?? [] {
                let newTag = CDTag(context: context)
                context.assign(newTag, to: sharedStore)
                newTag.id = UUID()
                newTag.name = tag.name
                newTag.color = tag.color

                let tagSet = pub.mutableSetValue(forKey: "tags")
                tagSet.add(newTag)
            }
        }

        // Copy linked file metadata
        for file in source.linkedFiles ?? [] {
            let newFile = CDLinkedFile(context: context)
            context.assign(newFile, to: sharedStore)
            newFile.id = UUID()
            newFile.relativePath = file.relativePath
            newFile.filename = file.filename
            newFile.fileType = file.fileType
            newFile.sha256 = file.sha256
            newFile.dateAdded = file.dateAdded
            newFile.displayName = file.displayName
            newFile.fileSize = file.fileSize
            newFile.mimeType = file.mimeType

            // Copy binary PDF data only if requested
            if options.includePDFs {
                newFile.fileData = file.fileData
                newFile.pdfCloudAvailable = file.pdfCloudAvailable
                newFile.isLocallyMaterialized = file.isLocallyMaterialized
            } else {
                newFile.pdfCloudAvailable = false
                newFile.isLocallyMaterialized = false
            }

            newFile.publication = pub

            // Copy annotations to shared store
            for annotation in file.annotations ?? [] {
                let newAnnotation = CDAnnotation(context: context)
                context.assign(newAnnotation, to: sharedStore)
                newAnnotation.id = UUID()
                newAnnotation.annotationType = annotation.annotationType
                newAnnotation.pageNumber = annotation.pageNumber
                newAnnotation.boundsJSON = annotation.boundsJSON
                newAnnotation.color = annotation.color
                newAnnotation.contents = annotation.contents
                newAnnotation.selectedText = annotation.selectedText
                newAnnotation.author = annotation.author
                newAnnotation.dateCreated = annotation.dateCreated
                newAnnotation.dateModified = annotation.dateModified
                newAnnotation.syncState = "pending"
                newAnnotation.linkedFile = newFile
            }
        }

        return pub
    }

    // MARK: - Notes Stripping

    /// Remove `note` and `annote` fields from a rawFields JSON string.
    private func stripNotesFromRawFields(_ rawFields: String?) -> String? {
        guard let rawFields, !rawFields.isEmpty,
              let data = rawFields.data(using: .utf8),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return rawFields
        }
        dict.removeValue(forKey: "note")
        dict.removeValue(forKey: "annote")
        guard let result = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: result, encoding: .utf8) else {
            return rawFields
        }
        return str
    }

    /// Remove `note` and `annote` fields from raw BibTeX using line-based brace-depth stripping.
    private func stripNotesFromBibTeX(_ rawBibTeX: String?) -> String? {
        guard let rawBibTeX, !rawBibTeX.isEmpty else { return rawBibTeX }

        let noteFields: Set<String> = ["note", "annote"]
        var result: [String] = []
        var skipping = false
        var braceDepth = 0

        for line in rawBibTeX.components(separatedBy: .newlines) {
            if skipping {
                // Count braces to find where the field value ends
                for char in line {
                    if char == "{" { braceDepth += 1 }
                    if char == "}" { braceDepth -= 1 }
                }
                if braceDepth <= 0 {
                    skipping = false
                    braceDepth = 0
                }
                continue
            }

            // Check if this line starts a note/annote field
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isNoteField = noteFields.contains(where: { field in
                trimmed.lowercased().hasPrefix("\(field)")
                    && trimmed.dropFirst(field.count).first.map({ $0 == " " || $0 == "=" }) == true
            })

            if isNoteField {
                // Start skipping; count braces on this line
                skipping = true
                braceDepth = 0
                for char in line {
                    if char == "{" { braceDepth += 1 }
                    if char == "}" { braceDepth -= 1 }
                }
                if braceDepth <= 0 {
                    skipping = false
                    braceDepth = 0
                }
                continue
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Errors

public enum SharedLibraryCopyError: LocalizedError {
    case sharedStoreUnavailable
    case privateStoreUnavailable
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sharedStoreUnavailable:
            return "CloudKit shared store is not available. Enable iCloud sync to share libraries."
        case .privateStoreUnavailable:
            return "Private store is not available."
        case .copyFailed(let reason):
            return "Failed to copy library: \(reason)"
        }
    }
}
