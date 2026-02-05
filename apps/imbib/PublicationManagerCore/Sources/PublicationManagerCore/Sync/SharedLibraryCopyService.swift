//
//  SharedLibraryCopyService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
import OSLog

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
        context: NSManagedObjectContext
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
                    publicationMap: &publicationMap
                )
            }

            // Copy publications not in any collection (library-level publications)
            let collectionPubIDs = Set(publicationMap.keys)
            for publication in library.publications ?? [] {
                if !collectionPubIDs.contains(publication.id) {
                    let copied = copyPublication(publication, context: context, sharedStore: sharedStore)
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
    /// - Returns: The new CDLibrary wrapper in the shared store
    public func copyCollectionToSharedStore(
        _ collection: CDCollection,
        context: NSManagedObjectContext
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
                publicationMap: &publicationMap
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
    /// - Returns: The new CDLibrary in the private store
    public func copyToPrivateStore(
        _ sharedLibrary: CDLibrary,
        context: NSManagedObjectContext
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
                    publicationMap: &publicationMap
                )
            }

            let collectionPubIDs = Set(publicationMap.keys)
            for publication in sharedLibrary.publications ?? [] {
                if !collectionPubIDs.contains(publication.id) {
                    let copied = copyPublication(publication, context: context, sharedStore: privateStore)
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
        publicationMap: inout [UUID: CDPublication]
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
                copied = copyPublication(publication, context: context, sharedStore: sharedStore)
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
                publicationMap: &publicationMap
            )
        }
    }

    private func copyPublication(
        _ source: CDPublication,
        context: NSManagedObjectContext,
        sharedStore: NSPersistentStore
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
        pub.rawBibTeX = source.rawBibTeX
        pub.rawFields = source.rawFields
        pub.fieldTimestamps = source.fieldTimestamps
        pub.dateAdded = source.dateAdded
        pub.dateModified = source.dateModified

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

        // Read/star status (fresh for recipient)
        pub.isRead = false
        pub.isStarred = false

        // Copy authors
        for pubAuthor in source.sortedAuthors {
            // Create new CDAuthor in shared store
            let newAuthor = CDAuthor(context: context)
            context.assign(newAuthor, to: sharedStore)
            newAuthor.id = UUID()
            newAuthor.familyName = pubAuthor.familyName
            newAuthor.givenName = pubAuthor.givenName
            newAuthor.nameSuffix = pubAuthor.nameSuffix

            // Create join record
            let join = CDPublicationAuthor(context: context)
            context.assign(join, to: sharedStore)
            if let originalJoin = (source.publicationAuthors ?? []).first(where: { $0.author?.id == pubAuthor.id }) {
                join.order = originalJoin.order
            }
            join.publication = pub
            join.author = newAuthor
        }

        // Copy tags
        for tag in source.tags ?? [] {
            let newTag = CDTag(context: context)
            context.assign(newTag, to: sharedStore)
            newTag.id = UUID()
            newTag.name = tag.name
            newTag.color = tag.color

            var pubTags = pub.tags ?? []
            pubTags.insert(newTag)
            pub.tags = pubTags
        }

        // Copy linked file metadata (NOT binary data)
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
            // Intentionally NOT copying fileData (binary PDF data)
            newFile.pdfCloudAvailable = false
            newFile.isLocallyMaterialized = false
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
