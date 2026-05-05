//
//  OutlineSnapshotMaintainer.swift
//  ImprintCore
//
//  Background refresh loop for `OutlineSnapshot`. Mirrors imbib's
//  `SidebarSnapshotMaintainer` pattern: one actor, debounced refresh,
//  nonisolated gateway reads, main-actor publish.
//
//  The currently-focused document id is pushed in by the UI layer
//  (typically `ContentView` on document open). When it changes, or
//  when a `.structural` / relevant `.itemsMutated` event arrives from
//  the gateway, the maintainer recomputes the outline for the focused
//  document and publishes it.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

private let outlineLog = Logger(subsystem: "com.imprint.app", category: "outline-snapshot")

/// Owns the refresh loop for `OutlineSnapshot`.
public actor OutlineSnapshotMaintainer {

    public static let shared = OutlineSnapshotMaintainer()

    private var isRunning = false
    private var isRefreshing = false
    private var pendingRefresh = false
    private var focusedDocumentID: UUID?
    private var eventTask: Task<Void, Never>?

    public init() {}

    /// Start the event subscription. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let stream = ImprintImpressStore.shared.events.subscribe()
        eventTask = Task.detached(priority: .utility) { [weak self] in
            for await event in stream {
                guard let self else { return }
                // Skip events that obviously don't affect this document's
                // outline. `.collectionMembershipChanged` is irrelevant.
                switch event {
                case .collectionMembershipChanged:
                    continue
                case .structural, .itemsMutated:
                    await self.triggerRefresh()
                }
            }
        }
        triggerRefresh()
    }

    /// Tell the maintainer which document's outline to track. Passing
    /// `nil` clears the snapshot. Safe to call on every document
    /// switch; refreshes are coalesced.
    public func setFocusedDocument(_ id: UUID?) {
        if focusedDocumentID == id { return }
        focusedDocumentID = id
        triggerRefresh()
    }

    private func triggerRefresh() {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        let docID = focusedDocumentID
        Task.detached(priority: .utility) { [weak self] in
            await self?.performRefresh(documentID: docID)
        }
    }

    private func performRefresh(documentID: UUID?) async {
        defer { Task { [weak self] in await self?.finishRefresh() } }

        guard let documentID else {
            await MainActor.run {
                OutlineSnapshot.shared.apply(focusedDocumentID: nil, entries: [])
            }
            return
        }

        #if canImport(ImpressRustCore)
        let sections = ImprintImpressStore.shared.listSectionsForDocument(documentID: documentID)

        // Only expose a snapshot when the document has true multi-section
        // structure. Single-section docs fall back to the regex outline
        // parser in the view layer.
        let entries: [OutlineSnapshotEntry]
        if sections.count >= 2 {
            entries = sections.map { section in
                OutlineSnapshotEntry(
                    id: section.id,
                    title: section.title.isEmpty ? "Untitled section" : section.title,
                    orderIndex: section.orderIndex,
                    wordCount: section.wordCount,
                    sectionType: section.sectionType
                )
            }
        } else {
            entries = []
        }

        await MainActor.run {
            OutlineSnapshot.shared.apply(focusedDocumentID: documentID, entries: entries)
        }
        #else
        await MainActor.run {
            OutlineSnapshot.shared.apply(focusedDocumentID: documentID, entries: [])
        }
        #endif
    }

    private func finishRefresh() async {
        isRefreshing = false
        if pendingRefresh {
            pendingRefresh = false
            triggerRefresh()
        }
    }
}
