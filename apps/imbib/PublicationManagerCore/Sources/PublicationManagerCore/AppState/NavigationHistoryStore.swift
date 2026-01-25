//
//  NavigationHistoryStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import Foundation
import OSLog

// MARK: - Navigation History Store

/// Tracks navigation history for browser-style back/forward navigation.
///
/// Uses `SidebarSelectionState` (serializable UUIDs) instead of Core Data objects
/// to avoid lifecycle issues when collections are deleted while in history.
///
/// ## Usage
///
/// ```swift
/// // Push new navigation
/// NavigationHistoryStore.shared.push(.collection(collectionID))
///
/// // Navigate back
/// if let state = NavigationHistoryStore.shared.goBack() {
///     selectedSection = sidebarSectionFrom(state)
/// }
/// ```
@Observable
public final class NavigationHistoryStore: @unchecked Sendable {

    // MARK: - Shared Instance

    public static let shared = NavigationHistoryStore()

    // MARK: - Properties

    /// Navigation history (oldest first, newest last)
    private var history: [SidebarSelectionState] = []

    /// Current position in history (0 = oldest, history.count-1 = newest)
    private var currentIndex: Int = -1

    /// Maximum history size to prevent unbounded growth
    private let maxHistorySize = 50

    // MARK: - Computed Properties

    /// Whether there are entries to go back to
    public var canGoBack: Bool {
        currentIndex > 0
    }

    /// Whether there are entries to go forward to
    public var canGoForward: Bool {
        currentIndex < history.count - 1
    }

    /// Current history position (for debugging)
    public var currentPosition: Int {
        currentIndex
    }

    /// Total history count (for debugging)
    public var historyCount: Int {
        history.count
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Navigation

    /// Push a new navigation state.
    ///
    /// - When pushing from end of history: appends new state
    /// - When pushing from middle of history: truncates forward entries
    /// - Deduplicates consecutive identical states
    /// - Trims oldest entries when exceeding max size
    ///
    /// - Parameter state: The navigation state to push
    public func push(_ state: SidebarSelectionState) {
        // Skip duplicate consecutive states
        if currentIndex >= 0 && currentIndex < history.count {
            if history[currentIndex] == state {
                Logger.navigation.debug("Skipping duplicate navigation state")
                return
            }
        }

        // If we're not at the end, truncate forward history
        if currentIndex < history.count - 1 {
            history.removeLast(history.count - 1 - currentIndex)
            Logger.navigation.debug("Truncated forward history")
        }

        // Append new state
        history.append(state)
        currentIndex = history.count - 1

        // Trim oldest entries if exceeding max size
        if history.count > maxHistorySize {
            let trimCount = history.count - maxHistorySize
            history.removeFirst(trimCount)
            currentIndex -= trimCount
            Logger.navigation.debug("Trimmed \(trimCount) oldest history entries")
        }

        Logger.navigation.info("Pushed navigation: \(String(describing: state)), index=\(self.currentIndex)/\(self.history.count)")
    }

    /// Go back in history.
    ///
    /// - Returns: The previous navigation state, or nil if at beginning
    public func goBack() -> SidebarSelectionState? {
        guard canGoBack else {
            Logger.navigation.debug("Cannot go back - at beginning of history")
            return nil
        }

        currentIndex -= 1
        let state = history[currentIndex]
        Logger.navigation.info("Going back to: \(String(describing: state)), index=\(self.currentIndex)/\(self.history.count)")
        return state
    }

    /// Go forward in history.
    ///
    /// - Returns: The next navigation state, or nil if at end
    public func goForward() -> SidebarSelectionState? {
        guard canGoForward else {
            Logger.navigation.debug("Cannot go forward - at end of history")
            return nil
        }

        currentIndex += 1
        let state = history[currentIndex]
        Logger.navigation.info("Going forward to: \(String(describing: state)), index=\(self.currentIndex)/\(self.history.count)")
        return state
    }

    /// Clear all history (for testing or reset)
    public func clear() {
        history.removeAll()
        currentIndex = -1
        Logger.navigation.info("Cleared navigation history")
    }

    /// Remove invalid entries (e.g., deleted collections) from history.
    ///
    /// Call this when you know certain UUIDs are no longer valid.
    ///
    /// - Parameter invalidIDs: Set of UUIDs that are no longer valid
    public func removeInvalidEntries(_ invalidIDs: Set<UUID>) {
        guard !invalidIDs.isEmpty else { return }

        let originalCount = history.count
        let originalIndex = currentIndex

        // Filter out invalid entries
        history = history.filter { state in
            switch state {
            case .inbox, .search:
                return true
            case .inboxFeed(let id), .library(let id), .smartSearch(let id), .collection(let id), .scixLibrary(let id):
                return !invalidIDs.contains(id)
            case .searchForm:
                return true
            }
        }

        // Adjust current index if entries before it were removed
        if history.isEmpty {
            currentIndex = -1
        } else {
            // Clamp to valid range
            currentIndex = min(currentIndex, history.count - 1)
        }

        let removedCount = originalCount - history.count
        if removedCount > 0 {
            Logger.navigation.info("Removed \(removedCount) invalid history entries, index \(originalIndex) -> \(self.currentIndex)")
        }
    }
}

// Note: Logger.navigation is defined in Logger+Extensions.swift
