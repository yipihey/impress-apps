//
//  RecentDocumentsSnapshotMaintainer.swift
//  ImprintCore
//
//  Background refresh loop for `RecentDocumentsSnapshot`. Subscribes to
//  `ImprintImpressStore.shared.events` and rebuilds the list of
//  documents on any structural event. Field-only mutations skip the
//  rebuild unless the affected section id doesn't match the current
//  snapshot (cheap set membership check).
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

private let recentLog = Logger(subsystem: "com.imprint.app", category: "recent-documents-snapshot")

/// Owns the refresh loop for `RecentDocumentsSnapshot`.
public actor RecentDocumentsSnapshotMaintainer {

    public static let shared = RecentDocumentsSnapshotMaintainer()

    private var isRunning = false
    private var isRefreshing = false
    private var pendingRefresh = false
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

    private func triggerRefresh() {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        defer { Task { [weak self] in await self?.finishRefresh() } }

        #if canImport(ImpressRustCore)
        // Pull every section once; bucket by document id. One pass is
        // cheaper than `listDocumentIDs()` + per-document calls because
        // the gateway computes the same underlying set either way.
        let all = ImprintImpressStore.shared.listAllSections(limit: 10_000, offset: 0)

        var byDocument: [UUID: [ManuscriptSection]] = [:]
        for section in all {
            guard let docID = section.documentID else { continue }
            byDocument[docID, default: []].append(section)
        }

        var entries: [RecentDocumentEntry] = []
        entries.reserveCapacity(byDocument.count)
        for (docID, sections) in byDocument {
            let sorted = sections.sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                return lhs.title < rhs.title
            }
            let firstTitle = sorted.first?.title ?? "Untitled"
            let lastModified = sections.map(\.createdAt).max() ?? Date.distantPast
            let totalWords = sections.reduce(0) { $0 + $1.wordCount }
            entries.append(RecentDocumentEntry(
                id: docID,
                title: firstTitle.isEmpty ? "Untitled" : firstTitle,
                sectionCount: sections.count,
                lastModified: lastModified,
                firstSectionTitle: firstTitle,
                totalWordCount: totalWords
            ))
        }
        entries.sort { $0.lastModified > $1.lastModified }

        let finalEntries = entries
        await MainActor.run {
            RecentDocumentsSnapshot.shared.apply(documents: finalEntries)
        }
        #else
        await MainActor.run {
            RecentDocumentsSnapshot.shared.apply(documents: [])
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
