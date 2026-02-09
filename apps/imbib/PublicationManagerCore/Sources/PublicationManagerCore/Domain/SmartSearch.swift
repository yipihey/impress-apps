//
//  SmartSearch.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDSmartSearch.
//

import Foundation
import ImbibRustCore

/// A saved search query that can auto-refresh and feed the inbox.
public struct SmartSearch: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let query: String
    public let sourceIDs: [String]
    public let maxResults: Int
    public let feedsToInbox: Bool
    public let autoRefreshEnabled: Bool
    public let refreshIntervalSeconds: Int
    public let lastFetchCount: Int
    public let lastExecuted: Date?
    public let libraryID: UUID?
    public let sortOrder: Int

    public init(from row: SmartSearchRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.name = row.name
        self.query = row.query
        self.sourceIDs = row.sourceIds
        self.maxResults = Int(row.maxResults)
        self.feedsToInbox = row.feedsToInbox
        self.autoRefreshEnabled = row.autoRefreshEnabled
        self.refreshIntervalSeconds = Int(row.refreshIntervalSeconds)
        self.lastFetchCount = Int(row.lastFetchCount)
        self.lastExecuted = row.lastExecuted.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        self.libraryID = row.libraryId.flatMap { UUID(uuidString: $0) }
        self.sortOrder = Int(row.sortOrder)
    }

    // MARK: - Group Feed Helpers

    /// Whether this smart search is a group feed (encoded in the query prefix).
    public var isGroupFeed: Bool {
        query.hasPrefix("GROUP_FEED|")
    }

    /// Parse authors from a GROUP_FEED query.
    public func groupFeedAuthors() -> [String] {
        guard isGroupFeed else { return [] }
        let parts = query.dropFirst("GROUP_FEED|".count).components(separatedBy: "|")
        for part in parts {
            if part.hasPrefix("authors:") {
                return part.dropFirst("authors:".count)
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        return []
    }

    /// Parse categories from a GROUP_FEED query.
    public func groupFeedCategories() -> Set<String> {
        guard isGroupFeed else { return [] }
        let parts = query.dropFirst("GROUP_FEED|".count).components(separatedBy: "|")
        for part in parts {
            if part.hasPrefix("categories:") {
                let cats = part.dropFirst("categories:".count)
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return Set(cats)
            }
        }
        return []
    }

    /// Parse cross-listed flag from a GROUP_FEED query.
    public func groupFeedIncludesCrossListed() -> Bool {
        guard isGroupFeed else { return false }
        let parts = query.dropFirst("GROUP_FEED|".count).components(separatedBy: "|")
        for part in parts {
            if part.hasPrefix("crosslist:") {
                return part.dropFirst("crosslist:".count) == "true"
            }
        }
        return false
    }
}
