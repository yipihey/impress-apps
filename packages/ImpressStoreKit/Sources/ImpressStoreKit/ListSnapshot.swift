//
//  ListSnapshot.swift
//  ImpressStoreKit
//
//  A generic row-cache pattern for list surfaces. Establishes the shape
//  for list views across the impress suite: the view reads rows from
//  the snapshot synchronously (cheap dictionary lookup + array access),
//  and a background maintainer keeps the snapshot up to date by
//  subscribing to `StoreEvent`s.
//
//  The existing `PublicationRowData` cache in imbib's `PublicationListView`
//  is the prototype of this pattern. That cache will be retrofitted onto
//  `ListSnapshot` in a follow-up session. For now, this type lives in
//  ImpressStoreKit so new list surfaces (imprint's manuscript sections,
//  impart's message list, implore's figure thumbnails) can adopt the
//  pattern immediately.
//
//  ## Design
//
//  - `ListSnapshot<Row: Identifiable>` owns an ordered `[Row]` plus an
//    index `[Row.ID: Int]` for O(1) lookup.
//  - `apply(rows:)` replaces the entire snapshot atomically. Used for
//    full refreshes.
//  - `patch(updated:removed:)` applies an incremental update. Used when
//    `StoreEvent.itemsMutated(...)` arrives and only a few rows changed.
//  - `version` bumps on every apply/patch so views observe changes via
//    `@Observable`.
//

import Foundation

/// Generic ordered row cache.
///
/// Parameterized over the row type so each surface (publications,
/// messages, sections, figures) can use its own value type without
/// casting. The type is `@MainActor` so views can read it directly
/// during body evaluation without hopping.
@MainActor
@Observable
public final class ListSnapshot<Row: Identifiable & Sendable> where Row.ID: Hashable {

    // MARK: - Stored state

    public private(set) var rows: [Row] = []
    private var indexByID: [Row.ID: Int] = [:]

    /// Monotonically bumped on every apply/patch.
    public private(set) var version: Int = 0

    /// When was the snapshot last updated (for debug / console overlay).
    public private(set) var lastUpdated: Date = .distantPast

    // MARK: - Init

    public init() {}

    // MARK: - Read

    public var count: Int { rows.count }

    public var isEmpty: Bool { rows.isEmpty }

    public func row(withID id: Row.ID) -> Row? {
        guard let idx = indexByID[id] else { return nil }
        return rows[idx]
    }

    public func contains(id: Row.ID) -> Bool {
        indexByID[id] != nil
    }

    // MARK: - Mutation

    /// Replace the entire row set. Used for full refreshes after a
    /// `StoreEvent.structural` event or on first load.
    public func apply(rows: [Row]) {
        self.rows = rows
        var idx: [Row.ID: Int] = [:]
        idx.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            idx[row.id] = i
        }
        self.indexByID = idx
        self.version &+= 1
        self.lastUpdated = Date()
    }

    /// Incrementally apply a patch. Rows in `updated` replace existing
    /// rows with the same id (or are appended if new). Rows with ids in
    /// `removed` are dropped. Used when a narrow `StoreEvent.itemsMutated`
    /// or `.collectionMembershipChanged` event arrives.
    public func patch(updated: [Row] = [], removed: Set<Row.ID> = []) {
        guard !updated.isEmpty || !removed.isEmpty else { return }

        // Build a new row vector in-place so we preserve order.
        var newRows: [Row] = []
        newRows.reserveCapacity(rows.count + updated.count)
        var touchedIDs = Set<Row.ID>()
        touchedIDs.reserveCapacity(updated.count + removed.count)

        let updatedByID: [Row.ID: Row] = Dictionary(
            uniqueKeysWithValues: updated.map { ($0.id, $0) }
        )

        for row in rows {
            if removed.contains(row.id) {
                continue
            }
            if let replacement = updatedByID[row.id] {
                newRows.append(replacement)
                touchedIDs.insert(row.id)
            } else {
                newRows.append(row)
            }
        }

        // Append any updated rows that weren't already present.
        for row in updated where !touchedIDs.contains(row.id) {
            newRows.append(row)
        }

        self.rows = newRows
        var idx: [Row.ID: Int] = [:]
        idx.reserveCapacity(newRows.count)
        for (i, row) in newRows.enumerated() {
            idx[row.id] = i
        }
        self.indexByID = idx
        self.version &+= 1
        self.lastUpdated = Date()
    }
}
