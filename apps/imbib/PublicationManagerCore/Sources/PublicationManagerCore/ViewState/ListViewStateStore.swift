//
//  ListViewStateStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import Foundation
import OSLog

// MARK: - Performance Timing

private let timingLogger = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "timing")

/// Log timing message using OSLog (public for visibility in log stream)
private func logTiming(_ message: String) {
    timingLogger.info("\(message, privacy: .public)")
}

// MARK: - List View ID

/// Identifies a specific list view for state persistence
public enum ListViewID: Hashable, Sendable {
    case library(UUID)
    case collection(UUID)
    case smartSearch(UUID)
    case lastSearch(UUID)  // "Last Search" system collection
    case scixLibrary(UUID)  // SciX online library
    case flagged(UUID)      // Flagged publications virtual list

    /// Storage key for this list view
    var storageKey: String {
        switch self {
        case .library(let id):
            return "library_\(id.uuidString)"
        case .collection(let id):
            return "collection_\(id.uuidString)"
        case .smartSearch(let id):
            return "smartsearch_\(id.uuidString)"
        case .lastSearch(let id):
            return "lastsearch_\(id.uuidString)"
        case .scixLibrary(let id):
            return "scixlibrary_\(id.uuidString)"
        case .flagged(let id):
            return "flagged_\(id.uuidString)"
        }
    }
}

// MARK: - List View State

/// Stores the UI state for a publication list view
public struct ListViewState: Codable, Equatable, Sendable {
    /// The ID of the last selected publication (nil if none selected)
    public var selectedPublicationID: UUID?

    /// The current sort order
    public var sortOrder: String  // Stored as raw value of LibrarySortOrder

    /// Whether sort is ascending
    public var sortAscending: Bool

    /// Whether showing unread only
    public var showUnreadOnly: Bool

    /// When the state was last updated
    public var lastVisitedDate: Date

    public init(
        selectedPublicationID: UUID? = nil,
        sortOrder: String = "dateAdded",
        sortAscending: Bool = false,
        showUnreadOnly: Bool = false,
        lastVisitedDate: Date = Date()
    ) {
        self.selectedPublicationID = selectedPublicationID
        self.sortOrder = sortOrder
        self.sortAscending = sortAscending
        self.showUnreadOnly = showUnreadOnly
        self.lastVisitedDate = lastVisitedDate
    }
}

// MARK: - List View State Store

/// Actor-based store for persisting list view state per library/collection/smart search.
///
/// Follows the same pattern as ReadingPositionStore - uses UserDefaults with
/// in-memory caching for performance.
public actor ListViewStateStore {

    // MARK: - Singleton

    public static let shared = ListViewStateStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private var cache: [String: ListViewState] = [:]
    private let keyPrefix = "list_view_state_"

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
        logTiming("⏱ ListViewStateStore initialized")
    }

    // MARK: - Public Interface

    /// Get the saved state for a list view
    public func get(for listID: ListViewID) -> ListViewState? {
        let cacheKey = listID.storageKey

        // Check cache first
        if let cached = cache[cacheKey] {
            return cached
        }

        // Load from UserDefaults
        let key = keyPrefix + cacheKey
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }

        do {
            let state = try JSONDecoder().decode(ListViewState.self, from: data)
            cache[cacheKey] = state
            return state
        } catch {
            Logger.viewModels.warningCapture("Failed to decode list view state: \(error.localizedDescription)", category: "viewstate")
            return nil
        }
    }

    /// Save state for a list view
    public func save(_ state: ListViewState, for listID: ListViewID) {
        logTiming("⏱ ListViewStateStore.save() CALLED for \(listID.storageKey)")
        let cacheKey = listID.storageKey
        let cacheStart = CFAbsoluteTimeGetCurrent()

        // Update cache immediately (synchronous, fast)
        cache[cacheKey] = state

        let cacheTime = (CFAbsoluteTimeGetCurrent() - cacheStart) * 1000

        // Persist to UserDefaults on background queue (async, slower disk I/O)
        let key = keyPrefix + cacheKey
        let defaults = userDefaults
        Task.detached(priority: .background) {
            let diskStart = CFAbsoluteTimeGetCurrent()
            do {
                let data = try JSONEncoder().encode(state)
                defaults.set(data, forKey: key)
                let diskTime = (CFAbsoluteTimeGetCurrent() - diskStart) * 1000
                // Log to imbib Console window with timing
                await Logger.viewModels.debugCapture(
                    "⏱ ListViewStateStore.save: cache=\(String(format: "%.2f", cacheTime))ms, disk=\(String(format: "%.2f", diskTime))ms for \(cacheKey): sort=\(state.sortOrder), selected=\(state.selectedPublicationID?.uuidString ?? "none")",
                    category: "viewstate"
                )
            } catch {
                await Logger.viewModels.warningCapture("Failed to encode list view state: \(error.localizedDescription)", category: "viewstate")
            }
        }
    }

    // MARK: - Convenience Methods

    /// Update just the selection
    public func updateSelection(_ publicationID: UUID?, for listID: ListViewID) {
        let start = CFAbsoluteTimeGetCurrent()
        var state = get(for: listID) ?? ListViewState()
        state.selectedPublicationID = publicationID
        state.lastVisitedDate = Date()
        let getTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
        save(state, for: listID)
        let totalTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
        logTiming("⏱ ListViewStateStore.updateSelection: get=\(String(format: "%.2f", getTime))ms, total=\(String(format: "%.2f", totalTime))ms")
    }


    /// Update just the sort order
    public func updateSortOrder(_ sortOrder: String, ascending: Bool, for listID: ListViewID) {
        var state = get(for: listID) ?? ListViewState()
        state.sortOrder = sortOrder
        state.sortAscending = ascending
        state.lastVisitedDate = Date()
        save(state, for: listID)
    }

    /// Update just the unread filter
    public func updateUnreadFilter(_ showUnreadOnly: Bool, for listID: ListViewID) {
        var state = get(for: listID) ?? ListViewState()
        state.showUnreadOnly = showUnreadOnly
        state.lastVisitedDate = Date()
        save(state, for: listID)
    }

    /// Clear the state for a list view (when deleted)
    public func clear(for listID: ListViewID) {
        let cacheKey = listID.storageKey
        cache.removeValue(forKey: cacheKey)
        let key = keyPrefix + cacheKey
        userDefaults.removeObject(forKey: key)
        Logger.viewModels.debugCapture("Cleared list view state for \(cacheKey)", category: "viewstate")
    }

    /// Clear only the selection (preserving sort order and filters)
    /// Used when navigating back from detail view to prevent re-selection
    public func clearSelection(for listID: ListViewID) {
        var state = get(for: listID) ?? ListViewState()
        state.selectedPublicationID = nil
        state.lastVisitedDate = Date()
        save(state, for: listID)
        Logger.viewModels.debugCapture("Cleared selection for \(listID.storageKey)", category: "viewstate")
    }

    /// Clear all list view states (for testing)
    public func clearAll() {
        cache.removeAll()

        // Remove all list view state keys from UserDefaults
        let allKeys = userDefaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(keyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
        Logger.viewModels.infoCapture("Cleared all list view states", category: "viewstate")
    }

    // MARK: - Recently Visited

    /// Get list views sorted by last visited date (most recent first)
    public func recentlyVisited(limit: Int = 10) -> [(ListViewID, ListViewState)] {
        // Load all states from UserDefaults
        let allKeys = userDefaults.dictionaryRepresentation().keys
        var states: [(ListViewID, ListViewState)] = []

        for key in allKeys where key.hasPrefix(keyPrefix) {
            let storageKey = String(key.dropFirst(keyPrefix.count))
            guard let listID = parseStorageKey(storageKey),
                  let data = userDefaults.data(forKey: key),
                  let state = try? JSONDecoder().decode(ListViewState.self, from: data) else {
                continue
            }
            states.append((listID, state))
        }

        // Sort by last visited date (most recent first) and limit
        return states
            .sorted { $0.1.lastVisitedDate > $1.1.lastVisitedDate }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Private Helpers

    private func parseStorageKey(_ key: String) -> ListViewID? {
        let parts = key.split(separator: "_", maxSplits: 1)
        guard parts.count == 2,
              let uuid = UUID(uuidString: String(parts[1])) else {
            return nil
        }

        switch String(parts[0]) {
        case "library":
            return .library(uuid)
        case "collection":
            return .collection(uuid)
        case "smartsearch":
            return .smartSearch(uuid)
        case "lastsearch":
            return .lastSearch(uuid)
        case "scixlibrary":
            return .scixLibrary(uuid)
        case "flagged":
            return .flagged(uuid)
        default:
            return nil
        }
    }
}
