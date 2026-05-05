//
//  OutlineSnapshot.swift
//  ImprintCore
//
//  Observable snapshot of the manuscript outline for a single document,
//  derived from `manuscript-section@1.0.0` items in the shared store.
//
//  Views read this snapshot synchronously during body evaluation.
//  `OutlineSnapshotMaintainer` keeps it up to date by subscribing to
//  `ImprintImpressStore.shared.events` on a background actor.
//
//  When a document has only one section (the current single-blob
//  storage model used by `ImprintStoreAdapter.storeSection`), the
//  snapshot is intentionally empty so the consumer can fall back to
//  its regex-based outline parser. Multi-section documents produce
//  real entries that views can render.
//

import Foundation

/// A single entry in the outline — one stored section.
public struct OutlineSnapshotEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let orderIndex: Int
    public let wordCount: Int
    public let sectionType: String?

    public init(
        id: UUID,
        title: String,
        orderIndex: Int,
        wordCount: Int,
        sectionType: String?
    ) {
        self.id = id
        self.title = title
        self.orderIndex = orderIndex
        self.wordCount = wordCount
        self.sectionType = sectionType
    }
}

/// Observable snapshot of a document's outline. Shared singleton; the
/// focused document id can change at runtime via `setFocusedDocument`.
@MainActor
@Observable
public final class OutlineSnapshot {

    public static let shared = OutlineSnapshot()

    /// The document whose outline this snapshot currently reflects.
    /// `nil` means no document is focused and `entries` is empty.
    public private(set) var focusedDocumentID: UUID?

    /// Ordered outline entries for the focused document. Empty when
    /// the document has fewer than 2 sections — callers should fall
    /// back to their own parser in that case.
    public private(set) var entries: [OutlineSnapshotEntry] = []

    /// Bumped on every successful refresh so consumers can trigger
    /// work in `.onChange(of:)`.
    public private(set) var revision: Int = 0

    public init() {}

    /// Replace the snapshot atomically.
    public func apply(
        focusedDocumentID: UUID?,
        entries: [OutlineSnapshotEntry]
    ) {
        self.focusedDocumentID = focusedDocumentID
        self.entries = entries
        self.revision &+= 1
    }
}
