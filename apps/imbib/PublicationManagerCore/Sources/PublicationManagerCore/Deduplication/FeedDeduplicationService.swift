//
//  FeedDeduplicationService.swift
//  PublicationManagerCore
//
//  Service to detect and remove duplicate feeds (SmartSearch) that may occur
//  due to sync issues.
//

import Foundation
import OSLog

/// Service to detect and remove duplicate feeds (SmartSearch) that may occur due to sync issues.
///
/// Duplicates are identified by having the same:
/// - name
/// - query
/// - library
///
/// When duplicates are found, the oldest one (by ID stability) is kept and others are deleted.
public final class FeedDeduplicationService {

    public static let shared = FeedDeduplicationService()

    private init() {}

    // MARK: - Public API

    /// Check for and remove duplicate feeds.
    ///
    /// - Returns: Number of duplicate feeds removed
    @MainActor
    public func deduplicateFeeds() -> Int {
        let startTime = CFAbsoluteTimeGetCurrent()
        let store = RustStoreAdapter.shared

        // Fetch all smart searches (feeds)
        let allFeeds = store.listSmartSearches()

        if allFeeds.isEmpty {
            return 0
        }

        // Group feeds by their identity key (name + query + library)
        var feedGroups: [String: [SmartSearch]] = [:]

        for feed in allFeeds {
            let key = identityKey(for: feed)
            feedGroups[key, default: []].append(feed)
        }

        // Find groups with duplicates
        var totalRemoved = 0

        for (_, feeds) in feedGroups {
            guard feeds.count > 1 else { continue }

            // Keep the first one, delete the rest
            let feedToKeep = feeds[0]
            let duplicates = Array(feeds.dropFirst())

            Logger.persistence.info(
                "FeedDeduplicationService: Found \(duplicates.count) duplicate(s) of feed '\(feedToKeep.name)'"
            )

            // Delete duplicates
            for duplicate in duplicates {
                store.deleteItem(id: duplicate.id)
                totalRemoved += 1
            }
        }

        if totalRemoved > 0 {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Logger.persistence.info(
                "FeedDeduplicationService: Removed \(totalRemoved) duplicate feed(s) in \(String(format: "%.0f", elapsed))ms"
            )
        }

        return totalRemoved
    }

    // MARK: - Private Helpers

    /// Generate a unique identity key for a feed based on name, query, and library.
    private func identityKey(for feed: SmartSearch) -> String {
        let libraryID = feed.libraryID?.uuidString ?? "nil"
        // Normalize: lowercase and trim whitespace
        let normalizedName = feed.name.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedQuery = feed.query.lowercased().trimmingCharacters(in: .whitespaces)
        return "\(libraryID):\(normalizedName):\(normalizedQuery)"
    }
}
