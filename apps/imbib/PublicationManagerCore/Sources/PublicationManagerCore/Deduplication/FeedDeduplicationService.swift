//
//  FeedDeduplicationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-20.
//

import CoreData
import OSLog

/// Service to detect and remove duplicate feeds (CDSmartSearch) that may occur due to CloudKit sync issues.
///
/// Duplicates are identified by having the same:
/// - name
/// - query
/// - library
///
/// When duplicates are found, the oldest one (by dateCreated) is kept and others are deleted.
/// Publications from duplicate result collections are merged into the kept feed's collection.
public final class FeedDeduplicationService {

    public static let shared = FeedDeduplicationService()

    private init() {}

    // MARK: - Public API

    /// Check for and remove duplicate feeds.
    ///
    /// - Parameter context: The managed object context to use
    /// - Returns: Number of duplicate feeds removed
    @MainActor
    public func deduplicateFeeds(in context: NSManagedObjectContext) -> Int {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Fetch all smart searches (feeds)
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDSmartSearch.dateCreated, ascending: true)]

        let allFeeds: [CDSmartSearch]
        do {
            allFeeds = try context.fetch(request)
        } catch {
            Logger.persistence.warning("FeedDeduplicationService: Failed to fetch feeds: \(error.localizedDescription)")
            return 0
        }

        if allFeeds.isEmpty {
            return 0
        }

        // Group feeds by their identity key (name + query + library)
        var feedGroups: [String: [CDSmartSearch]] = [:]

        for feed in allFeeds {
            let key = identityKey(for: feed)
            feedGroups[key, default: []].append(feed)
        }

        // Find groups with duplicates
        var totalRemoved = 0

        for (key, feeds) in feedGroups {
            guard feeds.count > 1 else { continue }

            // Feeds are already sorted by dateCreated (oldest first)
            let feedToKeep = feeds[0]
            let duplicates = Array(feeds.dropFirst())

            Logger.persistence.info(
                "FeedDeduplicationService: Found \(duplicates.count) duplicate(s) of feed '\(feedToKeep.name)'"
            )

            // Merge and delete duplicates
            for duplicate in duplicates {
                mergeFeed(duplicate, into: feedToKeep, context: context)
                context.delete(duplicate)
                totalRemoved += 1
            }
        }

        // Save if we made changes
        if totalRemoved > 0 {
            do {
                try context.save()
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                Logger.persistence.info(
                    "FeedDeduplicationService: Removed \(totalRemoved) duplicate feed(s) in \(String(format: "%.0f", elapsed))ms"
                )
            } catch {
                Logger.persistence.error(
                    "FeedDeduplicationService: Failed to save after deduplication: \(error.localizedDescription)"
                )
                context.rollback()
                return 0
            }
        }

        return totalRemoved
    }

    // MARK: - Private Helpers

    /// Generate a unique identity key for a feed based on name, query, and library.
    private func identityKey(for feed: CDSmartSearch) -> String {
        let libraryID = feed.library?.id.uuidString ?? "nil"
        // Normalize: lowercase and trim whitespace
        let normalizedName = feed.name.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedQuery = feed.query.lowercased().trimmingCharacters(in: .whitespaces)
        return "\(libraryID):\(normalizedName):\(normalizedQuery)"
    }

    /// Merge publications from duplicate feed's result collection into the kept feed's collection.
    private func mergeFeed(_ duplicate: CDSmartSearch, into target: CDSmartSearch, context: NSManagedObjectContext) {
        // If duplicate has a result collection with publications, move them to target's collection
        guard let duplicateCollection = duplicate.resultCollection,
              let duplicatePubs = duplicateCollection.publications, !duplicatePubs.isEmpty else {
            // Nothing to merge - just delete the duplicate's collection if it exists
            if let emptyCollection = duplicate.resultCollection {
                context.delete(emptyCollection)
            }
            return
        }

        // Ensure target has a result collection
        let targetCollection: CDCollection
        if let existing = target.resultCollection {
            targetCollection = existing
        } else {
            // Create a new result collection for target
            targetCollection = CDCollection(context: context)
            targetCollection.name = "\(target.name) Results"
            targetCollection.isSmartSearchResults = true
            targetCollection.library = target.library
            target.resultCollection = targetCollection
        }

        // Get existing publication IDs in target collection to avoid duplicates
        let existingIDs = Set((targetCollection.publications ?? []).map { $0.id })

        // Move unique publications to target collection
        var movedCount = 0
        for pub in duplicatePubs {
            if !existingIDs.contains(pub.id) {
                targetCollection.publications?.insert(pub)
                movedCount += 1
            }
        }

        if movedCount > 0 {
            Logger.persistence.debug(
                "FeedDeduplicationService: Moved \(movedCount) publication(s) from duplicate to '\(target.name)'"
            )
        }

        // Delete the duplicate's now-empty collection
        context.delete(duplicateCollection)
    }
}
