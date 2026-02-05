//
//  LibraryDeduplicationService.swift
//  PublicationManagerCore
//
//  Merges duplicate libraries that can occur when multiple devices
//  create the same library before CloudKit sync completes.
//

import Foundation
import CoreData
import OSLog

// MARK: - Library Merge Result

/// Result of a library deduplication operation.
public struct LibraryMergeResult: Sendable {
    /// The library that was kept (oldest/canonical)
    public let keptLibraryID: UUID

    /// The library that was kept's name
    public let keptLibraryName: String

    /// IDs of libraries that were merged and deleted
    public let mergedLibraryIDs: [UUID]

    /// Number of publications moved to the kept library
    public let publicationsMoved: Int

    /// Number of collections moved to the kept library
    public let collectionsMoved: Int

    /// Number of smart searches moved to the kept library
    public let smartSearchesMoved: Int

    /// Human-readable summary
    public var summary: String {
        let merged = mergedLibraryIDs.count
        return "Merged \(merged) duplicate(s) into '\(keptLibraryName)': " +
               "\(publicationsMoved) papers, \(collectionsMoved) collections, \(smartSearchesMoved) smart searches"
    }
}

// MARK: - Library Deduplication Service

/// Service for detecting and merging duplicate libraries.
///
/// Duplicate libraries can occur when:
/// 1. User creates a library on Device A
/// 2. User creates a library with the same name on Device B before sync completes
/// 3. CloudKit syncs both libraries - now user has two "My Library" entries
///
/// This service detects these duplicates and merges them:
/// - Keeps the oldest library (most likely to have the original data)
/// - Moves all publications, collections, and smart searches to the kept library
/// - Deletes the duplicate libraries
///
/// ## Usage
///
/// ```swift
/// let service = LibraryDeduplicationService(context: viewContext)
/// let results = await service.deduplicateLibraries()
/// for result in results {
///     print(result.summary)
/// }
/// ```
public actor LibraryDeduplicationService {

    // MARK: - Properties

    /// Persistence controller for database access
    private let persistenceController: PersistenceController

    /// Time window for considering libraries as duplicates (24 hours)
    private let duplicateTimeWindow: TimeInterval = 24 * 60 * 60

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Deduplication

    /// Detect and merge duplicate libraries.
    ///
    /// This method:
    /// 1. Finds libraries that share the canonical default ID
    /// 2. Finds libraries with the same name created within 24 hours of each other
    /// 3. Merges duplicates into the oldest library
    ///
    /// - Returns: Array of merge results describing what was merged
    @MainActor
    public func deduplicateLibraries() async -> [LibraryMergeResult] {
        Logger.dedup.info("Starting library deduplication")

        var results: [LibraryMergeResult] = []

        let context = persistenceController.viewContext

        // Step 1: Handle canonical default library duplicates
        let canonicalResult = await mergeCanonicalDefaultLibraries(context: context)
        if let result = canonicalResult {
            results.append(result)
        }

        // Step 2: Handle inbox library duplicates (all isInbox == true libraries)
        let inboxResult = await mergeInboxLibraries(context: context)
        if let result = inboxResult {
            results.append(result)
        }

        // Step 3: Handle exploration library duplicates (all system libraries named "Exploration")
        let explorationResult = await mergeExplorationLibraries(context: context)
        if let result = explorationResult {
            results.append(result)
        }

        // Step 4: Handle name-based duplicates (same name, created within time window)
        let nameResults = await mergeNameBasedDuplicates(context: context)
        results.append(contentsOf: nameResults)

        if !results.isEmpty {
            persistenceController.save()
            Logger.dedup.info("Library deduplication complete: \(results.count) merge(s)")
        } else {
            Logger.dedup.debug("Library deduplication: no duplicates found")
        }

        return results
    }

    // MARK: - Canonical Default Library Merging

    /// Merge libraries that have the canonical default library ID.
    @MainActor
    private func mergeCanonicalDefaultLibraries(context: NSManagedObjectContext) async -> LibraryMergeResult? {
        // Fetch all non-system libraries and filter by canonical ID in Swift
        // (Core Data can't query computed properties directly)
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSystemLibrary == NO")

        guard let allLibraries = try? context.fetch(request) else {
            return nil
        }

        // Filter to only libraries with the canonical default ID
        let libraries = allLibraries.filter { $0.id == CDLibrary.canonicalDefaultLibraryID }

        guard libraries.count > 1 else {
            return nil
        }

        Logger.dedup.info("Found \(libraries.count) libraries with canonical default ID")
        return mergeLibraries(libraries, context: context)
    }

    // MARK: - Inbox Library Merging

    /// Merge all inbox libraries into one.
    ///
    /// Unlike other libraries, all inbox libraries should be merged regardless of creation time
    /// since there should only ever be one inbox per user account.
    @MainActor
    private func mergeInboxLibraries(context: NSManagedObjectContext) async -> LibraryMergeResult? {
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isInbox == YES")

        guard let inboxLibraries = try? context.fetch(request),
              inboxLibraries.count > 1 else {
            return nil
        }

        Logger.dedup.info("Found \(inboxLibraries.count) inbox libraries - merging")

        // Sort by: canonical ID first, then oldest
        let sorted = inboxLibraries.sorted { lib1, lib2 in
            if lib1.id == CDLibrary.canonicalInboxLibraryID { return true }
            if lib2.id == CDLibrary.canonicalInboxLibraryID { return false }
            return lib1.dateCreated < lib2.dateCreated
        }

        return mergeLibraries(sorted, context: context)
    }

    // MARK: - Exploration Library Merging

    /// Merge all exploration libraries into one.
    ///
    /// All exploration libraries should be merged regardless of creation time or device
    /// since there should only ever be one exploration library per user account.
    @MainActor
    private func mergeExplorationLibraries(context: NSManagedObjectContext) async -> LibraryMergeResult? {
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSystemLibrary == YES AND name == %@", "Exploration")

        guard let explorationLibraries = try? context.fetch(request),
              explorationLibraries.count > 1 else {
            return nil
        }

        Logger.dedup.info("Found \(explorationLibraries.count) exploration libraries - merging")

        // Sort by: canonical ID first, then oldest
        let sorted = explorationLibraries.sorted { lib1, lib2 in
            if lib1.id == CDLibrary.canonicalExplorationLibraryID { return true }
            if lib2.id == CDLibrary.canonicalExplorationLibraryID { return false }
            return lib1.dateCreated < lib2.dateCreated
        }

        return mergeLibraries(sorted, context: context)
    }

    // MARK: - Name-Based Duplicate Merging

    /// Merge libraries with the same name created within a time window.
    @MainActor
    private func mergeNameBasedDuplicates(context: NSManagedObjectContext) async -> [LibraryMergeResult] {
        var results: [LibraryMergeResult] = []

        // Fetch all non-system libraries
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSystemLibrary == NO AND isLocalOnly == NO")

        guard let allLibraries = try? context.fetch(request) else {
            return results
        }

        // Group libraries by normalized name
        var libraryGroups: [String: [CDLibrary]] = [:]
        for library in allLibraries {
            let normalizedName = library.name.lowercased().trimmingCharacters(in: .whitespaces)
            libraryGroups[normalizedName, default: []].append(library)
        }

        // Find groups with potential duplicates
        for (name, libraries) in libraryGroups where libraries.count > 1 {
            // Sort by creation date (oldest first)
            let sorted = libraries.sorted { $0.dateCreated < $1.dateCreated }

            // Find libraries created within the time window of the oldest
            let oldest = sorted[0]
            let duplicates = sorted.dropFirst().filter { library in
                let timeDiff = library.dateCreated.timeIntervalSince(oldest.dateCreated)
                return timeDiff < duplicateTimeWindow
            }

            if !duplicates.isEmpty {
                let toMerge = [oldest] + Array(duplicates)
                Logger.dedup.info("Found \(toMerge.count) libraries named '\(name)' created within 24h")
                if let result = mergeLibraries(toMerge, context: context) {
                    results.append(result)
                }
            }
        }

        return results
    }

    // MARK: - Library Merging

    /// Merge a group of libraries into the oldest one.
    @MainActor
    private func mergeLibraries(_ libraries: [CDLibrary], context: NSManagedObjectContext) -> LibraryMergeResult? {
        guard libraries.count > 1 else { return nil }

        // Sort by creation date and use canonical ID as tiebreaker
        let sorted = libraries.sorted { lib1, lib2 in
            if lib1.id == CDLibrary.canonicalDefaultLibraryID { return true }
            if lib2.id == CDLibrary.canonicalDefaultLibraryID { return false }
            return lib1.dateCreated < lib2.dateCreated
        }

        let keeper = sorted[0]
        let duplicates = Array(sorted.dropFirst())

        Logger.dedup.info("Merging \(duplicates.count) libraries into '\(keeper.displayName)' (ID: \(keeper.id))")

        var publicationsMoved = 0
        var collectionsMoved = 0
        var smartSearchesMoved = 0

        for duplicate in duplicates {
            // Move publications
            if let publications = duplicate.publications {
                for pub in publications {
                    pub.addToLibrary(keeper)
                    pub.removeFromLibrary(duplicate)
                    publicationsMoved += 1
                }
            }

            // Move collections
            if let collections = duplicate.collections {
                for collection in collections {
                    collection.library = keeper
                    collectionsMoved += 1
                }
            }

            // Move smart searches
            if let smartSearches = duplicate.smartSearches {
                for search in smartSearches {
                    search.library = keeper
                    smartSearchesMoved += 1
                }
            }

            // Delete the duplicate library
            Logger.dedup.debug("Deleting duplicate library '\(duplicate.displayName)' (ID: \(duplicate.id))")
            context.delete(duplicate)
        }

        return LibraryMergeResult(
            keptLibraryID: keeper.id,
            keptLibraryName: keeper.displayName,
            mergedLibraryIDs: duplicates.map { $0.id },
            publicationsMoved: publicationsMoved,
            collectionsMoved: collectionsMoved,
            smartSearchesMoved: smartSearchesMoved
        )
    }

    // MARK: - Integration Hook

    /// Call this after CloudKit remote change notifications to handle potential duplicates.
    ///
    /// Debouncing is recommended to avoid running deduplication on every notification.
    @MainActor
    public func handleRemoteChangeNotification() async {
        let results = await deduplicateLibraries()
        for result in results {
            Logger.dedup.info("Library deduplication: \(result.summary)")
        }
    }
}

// MARK: - Logger Extension

private extension Logger {
    static let dedup = Logger(subsystem: "com.imbib.app", category: "deduplication")
}
