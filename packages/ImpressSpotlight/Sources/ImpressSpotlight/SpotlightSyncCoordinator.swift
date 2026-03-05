import CoreSpotlight
import Foundation
import OSLog

/// Coordinates incremental Spotlight index updates for a single app domain.
///
/// Each app creates one coordinator with its `SpotlightItemProvider`.
/// The coordinator handles:
/// - Initial full rebuild on first launch or schema version bump
/// - Incremental add/remove by diffing current vs. last-known item IDs
/// - Debounced field-change re-indexing for metadata updates
///
/// Usage:
/// ```swift
/// let coordinator = SpotlightSyncCoordinator(provider: MyAppProvider())
/// await coordinator.initialRebuildIfNeeded()
/// await coordinator.startObserving(...)
/// await SpotlightBridge.shared.setCoordinator(coordinator) // keep alive!
/// ```
public actor SpotlightSyncCoordinator {

    // MARK: - Version Tracking

    /// Bump this when the indexing schema changes to force a rebuild.
    /// Changed to 2 to force rebuild with new compound identifier format.
    private static let currentSchemaVersion = 2

    private var indexVersionKey: String {
        "SpotlightIndexVersion_\(provider.domain)"
    }

    // MARK: - State

    private let provider: any SpotlightItemProvider
    private var lastKnownIDs: Set<UUID> = []
    private var debounceTask: Task<Void, Never>?
    private var pendingMutationIDs: Set<UUID> = []
    private var observationTokens: [Any] = []

    // MARK: - Initialization

    public init(provider: any SpotlightItemProvider) {
        self.provider = provider
    }

    // MARK: - Initial Rebuild

    /// Checks whether a full rebuild is needed (first launch or schema version bump)
    /// and performs it if so. Otherwise, snapshots the current item IDs for incremental diffs.
    public func initialRebuildIfNeeded() async {
        let storedVersion = UserDefaults.standard.integer(forKey: indexVersionKey)

        if storedVersion < Self.currentSchemaVersion {
            Logger.spotlight.info("Spotlight schema version \(storedVersion) < \(Self.currentSchemaVersion), rebuilding '\(self.provider.domain)'")
            let allIDs = await provider.allItemIDs()
            let items = await provider.spotlightItems(for: Array(allIDs))
            await SpotlightIndexer.shared.rebuild(items: items, domain: provider.domain)
            lastKnownIDs = allIDs
            UserDefaults.standard.set(Self.currentSchemaVersion, forKey: indexVersionKey)
        } else {
            // Just snapshot current IDs for future diffs
            lastKnownIDs = await provider.allItemIDs()
            Logger.spotlight.info("Spotlight index up-to-date for '\(self.provider.domain)' (\(self.lastKnownIDs.count) items)")
        }
    }

    // MARK: - Incremental Mutation Handling

    /// Called when the data store mutates. Diffs current IDs against last-known
    /// to find additions and deletions, then updates the Spotlight index.
    public func handleMutation() async {
        let currentIDs = await provider.allItemIDs()
        let added = currentIDs.subtracting(lastKnownIDs)
        let removed = lastKnownIDs.subtracting(currentIDs)

        if !added.isEmpty {
            let items = await provider.spotlightItems(for: Array(added))
            await SpotlightIndexer.shared.index(items)
        }

        if !removed.isEmpty {
            await SpotlightIndexer.shared.remove(ids: Array(removed), domain: provider.domain)
        }

        if !added.isEmpty || !removed.isEmpty {
            Logger.spotlight.info("Spotlight incremental: +\(added.count) -\(removed.count) for '\(self.provider.domain)'")
        }

        lastKnownIDs = currentIDs
    }

    /// Called when specific items have field changes. Re-indexes only those items.
    /// Debounces within a 2-second window to coalesce rapid edits.
    public func handleFieldChange(ids: [UUID]) async {
        pendingMutationIDs.formUnion(ids)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return // Properly cancelled
            }
            await self?.flushPendingFieldChanges()
        }
    }

    private func flushPendingFieldChanges() async {
        let ids = Array(pendingMutationIDs)
        pendingMutationIDs.removeAll()

        guard !ids.isEmpty else { return }

        let items = await provider.spotlightItems(for: ids)
        await SpotlightIndexer.shared.index(items)
        Logger.spotlight.info("Spotlight re-indexed \(items.count) changed items for '\(self.provider.domain)'")
    }

    // MARK: - Notification Observation

    /// Starts observing the given notification names and routes them to the
    /// appropriate handler. Call this after `initialRebuildIfNeeded()`.
    ///
    /// - Parameters:
    ///   - mutationName: Notification posted when items are added/removed (structural change)
    ///   - fieldChangeName: Notification posted when item fields change (metadata update).
    ///                      Must include `userInfo["publicationIDs"]` or similar UUID array.
    ///   - extractIDs: Closure to extract changed UUIDs from the notification's userInfo.
    public func startObserving(
        mutationName: Notification.Name,
        fieldChangeName: Notification.Name? = nil,
        extractIDs: (@Sendable (Notification) -> [UUID])? = nil
    ) {
        let mutationToken = NotificationCenter.default.addObserver(
            forName: mutationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleMutation() }
        }
        observationTokens.append(mutationToken)

        if let fieldChangeName, let extractIDs {
            let fieldToken = NotificationCenter.default.addObserver(
                forName: fieldChangeName,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let ids = extractIDs(notification)
                if !ids.isEmpty {
                    Task { await self?.handleFieldChange(ids: ids) }
                }
            }
            observationTokens.append(fieldToken)
        }

        Logger.spotlight.info("SpotlightSyncCoordinator observing for '\(self.provider.domain)'")
    }

    // MARK: - Manual Rebuild

    /// Forces a full rebuild. Used by Settings UI recovery button.
    public func forceRebuild() async {
        let allIDs = await provider.allItemIDs()
        let items = await provider.spotlightItems(for: Array(allIDs))
        await SpotlightIndexer.shared.rebuild(items: items, domain: provider.domain)
        lastKnownIDs = allIDs
        Logger.spotlight.info("Forced Spotlight rebuild for '\(self.provider.domain)': \(allIDs.count) items")
    }
}
