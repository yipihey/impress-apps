//
//  RecentDocumentsSnapshot.swift
//  ImprintCore
//
//  Observable snapshot of every manuscript document imprint knows about,
//  derived from the `manuscript-section@1.0.0` items in the shared store.
//
//  Replaces the `NSDocumentController.shared.recentDocumentURLs` list in
//  the project sidebar. That list was a filesystem history that missed
//  documents edited by agents and didn't reflect actual content. This
//  snapshot is the true "documents in my workspace" — agents, HTTP
//  automation, and the user all see the same data.
//
//  Entries are derived in `RecentDocumentsSnapshotMaintainer`:
//  - One entry per distinct `document_id` in the store
//  - `title` = first section's title (sorted by `order_index`)
//  - `sectionCount` = number of sections for that document
//  - `lastModified` = max `created_at` across the document's sections
//

import Foundation

/// One row in the recent-documents snapshot.
public struct RecentDocumentEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let sectionCount: Int
    public let lastModified: Date
    public let firstSectionTitle: String
    public let totalWordCount: Int

    public init(
        id: UUID,
        title: String,
        sectionCount: Int,
        lastModified: Date,
        firstSectionTitle: String,
        totalWordCount: Int
    ) {
        self.id = id
        self.title = title
        self.sectionCount = sectionCount
        self.lastModified = lastModified
        self.firstSectionTitle = firstSectionTitle
        self.totalWordCount = totalWordCount
    }
}

/// Observable snapshot of recent manuscript documents. Shared singleton.
@MainActor
@Observable
public final class RecentDocumentsSnapshot {

    public static let shared = RecentDocumentsSnapshot()

    /// Documents sorted by `lastModified` descending.
    public private(set) var documents: [RecentDocumentEntry] = []

    /// Bumped on every successful refresh.
    public private(set) var revision: Int = 0

    /// Wall-clock time of the last successful refresh, for debug overlays.
    public private(set) var lastRefreshedAt: Date?

    public init() {}

    public func apply(documents: [RecentDocumentEntry]) {
        self.documents = documents
        self.revision &+= 1
        self.lastRefreshedAt = Date()
    }
}
