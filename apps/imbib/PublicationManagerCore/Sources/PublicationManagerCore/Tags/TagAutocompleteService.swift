//
//  TagAutocompleteService.swift
//  PublicationManagerCore
//
//  In-memory tag autocomplete service for fast prefix matching.
//

import Foundation
import ImpressFTUI
import ImpressStoreKit

/// In-memory tag autocomplete service for fast prefix matching.
///
/// Shared singleton that pre-warms its cache at app launch and refreshes
/// asynchronously after mutations. Completion queries always hit the
/// in-memory cache — they never block on store I/O.
///
/// Ranking: recency > shallow depth > frequency > alphabetical.
@MainActor
@Observable
public final class TagAutocompleteService {

    // MARK: - Singleton

    public static let shared = TagAutocompleteService()

    // MARK: - Properties

    private var cachedTags: [CachedTag] = []
    private var hasLoaded = false
    private var eventTask: Task<Void, Never>?

    // MARK: - Initialization

    public init() {}

    // No explicit deinit — the service is a singleton that lives for the
    // app lifetime, and `Task.cancel()` from a nonisolated deinit would
    // require unsafely reaching into `@MainActor` state. The subscription
    // is torn down at process exit.

    // MARK: - Cache Management

    /// Pre-warm the cache. Call this at app launch.
    ///
    /// Also starts a long-lived `Task` that subscribes to
    /// `ImbibImpressStore.shared.events` and refreshes the cache on
    /// every `.itemsMutated(kind: .tag, ...)` event. This replaces the
    /// legacy `.tagDidChange` observer. We deliberately ignore other
    /// mutation kinds for the same reason as before: tag refreshes
    /// touch SQLite and would starve the main thread if kicked off on
    /// every read/star/flag mutation.
    public func warmCache() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refreshInBackground()

        eventTask = Task { [weak self] in
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard case .itemsMutated(.tag, _) = event else { continue }
                await MainActor.run { self?.refreshInBackground() }
            }
        }
    }

    /// Refresh the cache by submitting a refresh operation to the shared
    /// `BackgroundOperationQueue`.
    ///
    /// The queue's dedupe-by-key mechanism ensures only one tag refresh
    /// is ever in flight at a time (shared across the whole app, not
    /// just this service). A burst of `.tagDidChange` notifications from
    /// a batch of tagging operations collapses into a single refresh by
    /// construction.
    ///
    /// The operation runs at `.userInitiated` priority so it bypasses
    /// the startup grace period — the user-visible tag input needs
    /// fresh completions even during the first 90 seconds.
    public func refreshInBackground() {
        let op = BackgroundOperation(
            kind: .read,
            priority: .userInitiated,
            dedupeKey: "tag-cache-refresh",
            label: "Tag autocomplete cache refresh"
        ) { _ in
            let tags = RustStoreAdapter.shared.listTagsWithCountsBackground()
            let mapped: [CachedTag] = tags.map { tag in
                let depth = tag.path.components(separatedBy: "/").count - 1
                return CachedTag(
                    path: tag.path,
                    leaf: tag.leafName,
                    depth: depth,
                    useCount: tag.publicationCount,
                    lastUsedAt: nil,
                    colorLight: tag.colorLight,
                    colorDark: tag.colorDark
                )
            }
            await MainActor.run {
                TagAutocompleteService.shared.applyRefreshed(cachedTags: mapped)
            }
        }
        Task {
            _ = await BackgroundOperationQueue.shared.submit(op)
        }
    }

    /// Internal apply method called from the operation queue worker
    /// after a refresh completes.
    fileprivate func applyRefreshed(cachedTags: [CachedTag]) {
        self.cachedTags = cachedTags
    }

    /// Legacy invalidate hook — now triggers a background refresh instead
    /// of clearing the cache, so the next keystroke remains instant.
    public func invalidate() {
        refreshInBackground()
    }

    // MARK: - Completion

    /// Find completions matching a prefix string.
    ///
    /// Ranked by: recency > shallow depth > frequency > alphabetical.
    public func complete(_ input: String, limit: Int = 8) -> [TagCompletion] {
        // If the cache is cold (first call ever), kick off a refresh and
        // return empty — completion will populate once the refresh lands.
        if !hasLoaded {
            warmCache()
        }

        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let now = Date()

        var seenPaths = Set<String>()
        return cachedTags
            .filter { $0.path.lowercased().hasPrefix(trimmed) || $0.leaf.lowercased().hasPrefix(trimmed) }
            .sorted { a, b in
                // 1. Recency (used in last 7 days gets priority)
                let aRecent = a.isRecent(relativeTo: now)
                let bRecent = b.isRecent(relativeTo: now)
                if aRecent != bRecent { return aRecent }

                // 2. Shallower depth preferred
                if a.depth != b.depth { return a.depth < b.depth }

                // 3. Higher use count preferred
                if a.useCount != b.useCount { return a.useCount > b.useCount }

                // 4. Alphabetical
                return a.path < b.path
            }
            .filter { seenPaths.insert($0.path.lowercased()).inserted }
            .prefix(limit)
            .map { cached in
                TagCompletion(
                    id: UUID(),
                    path: cached.path,
                    leaf: cached.leaf,
                    depth: cached.depth,
                    useCount: cached.useCount,
                    lastUsedAt: cached.lastUsedAt,
                    colorLight: cached.colorLight,
                    colorDark: cached.colorDark
                )
            }
    }
}

// MARK: - Cached Tag

private struct CachedTag: Sendable {
    let path: String
    let leaf: String
    let depth: Int
    let useCount: Int
    let lastUsedAt: Date?
    let colorLight: String?
    let colorDark: String?

    func isRecent(relativeTo now: Date) -> Bool {
        guard let lastUsed = lastUsedAt else { return false }
        return now.timeIntervalSince(lastUsed) < 7 * 24 * 3600
    }
}
