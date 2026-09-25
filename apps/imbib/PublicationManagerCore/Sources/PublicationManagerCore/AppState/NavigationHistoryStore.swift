//
//  NavigationHistoryStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import Foundation
import OSLog
import SwiftUI

// MARK: - Navigation History

/// Browser-style back/forward over a sequence of navigation states.
///
/// Holds values, never store objects, so an entry outlives the thing it
/// names; whoever navigates decides whether an entry still leads anywhere
/// (the macOS sidebar skips an entry whose node is gone).
///
/// Go ▸ Back / Forward (⌘[ / ⌘]) is `NavigationHistory<ImbibTab>`, one per
/// sidebar (`ImbibSidebarViewModel.navigationHistory`): the Core Data sidebar
/// pushed `SidebarSelectionState`s into a process-wide `shared` instance until
/// b748151d deleted it, and nothing pushed or navigated after that, so both
/// menu items did nothing. The sidebar's own tab is the state now — it names
/// every place the sidebar can select, which `SidebarSelectionState` (nine
/// cases) never did — and each window keeps its own history.
///
/// ## Usage
///
/// ```swift
/// history.push(.collection(collectionID))
/// if let tab = history.goBack() { navigate(to: tab) }
/// ```
@Observable
public final class NavigationHistory<State: Equatable>: @unchecked Sendable {

    // MARK: - Properties

    /// Navigation history (oldest first, newest last)
    private var history: [State] = []

    /// Current position in history (0 = oldest, history.count-1 = newest)
    private var currentIndex: Int = -1

    /// Maximum history size to prevent unbounded growth
    private let maxHistorySize: Int

    // MARK: - Computed Properties

    /// Whether there are entries to go back to
    public var canGoBack: Bool {
        currentIndex > 0
    }

    /// Whether there are entries to go forward to
    public var canGoForward: Bool {
        currentIndex < history.count - 1
    }

    /// Whether nothing has been recorded yet.
    public var isEmpty: Bool {
        history.isEmpty
    }

    /// The state at the current position, if any.
    public var current: State? {
        history.indices.contains(currentIndex) ? history[currentIndex] : nil
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

    public init(maxHistorySize: Int = 50) {
        self.maxHistorySize = max(1, maxHistorySize)
    }

    // MARK: - Navigation

    /// Push a new navigation state.
    ///
    /// - When pushing from end of history: appends new state
    /// - When pushing from middle of history: truncates forward entries
    /// - Deduplicates consecutive identical states
    /// - Trims oldest entries when exceeding max size
    ///
    /// - Parameter state: The navigation state to push
    public func push(_ state: State) {
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
    public func goBack() -> State? {
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
    public func goForward() -> State? {
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

    /// Remove entries that no longer lead anywhere, keeping the current
    /// position on the same entry when it survives.
    public func removeAll(where isInvalid: (State) -> Bool) {
        let originalCount = history.count
        let originalIndex = currentIndex
        var kept: [State] = []
        var newIndex = -1
        for (index, state) in history.enumerated() where !isInvalid(state) {
            kept.append(state)
            if index <= currentIndex { newIndex = kept.count - 1 }
        }
        history = kept
        currentIndex = kept.isEmpty ? -1 : max(0, newIndex)

        let removedCount = originalCount - history.count
        if removedCount > 0 {
            Logger.navigation.info("Removed \(removedCount) invalid history entries, index \(originalIndex) -> \(self.currentIndex)")
        }
    }
}

/// The Core Data–era history's state type, kept for its callers' spelling.
public typealias NavigationHistoryStore = NavigationHistory<SidebarSelectionState>

extension NavigationHistory where State == SidebarSelectionState {
    /// Remove invalid entries (e.g., deleted collections) from history.
    ///
    /// - Parameter invalidIDs: Set of UUIDs that are no longer valid
    public func removeInvalidEntries(_ invalidIDs: Set<UUID>) {
        guard !invalidIDs.isEmpty else { return }
        removeAll { state in
            switch state {
            case .inbox, .search, .flagged, .searchForm:
                return false
            case .inboxCollection(let id), .library(let id), .smartSearch(let id), .collection(let id), .scixLibrary(let id):
                return invalidIDs.contains(id)
            }
        }
    }
}

// MARK: - The key window's sidebar history (Go ▸ Back / Forward)

public struct ImbibNavigationHistoryKey: FocusedValueKey {
    public typealias Value = NavigationHistory<ImbibTab>
}

public extension FocusedValues {
    /// The sidebar history of the window the Go menu acts on — the menu reads
    /// `canGoBack` / `canGoForward` from it for its disabled state and names
    /// it as the post's object, so only that window's sidebar navigates.
    var imbibNavigationHistory: NavigationHistory<ImbibTab>? {
        get { self[ImbibNavigationHistoryKey.self] }
        set { self[ImbibNavigationHistoryKey.self] = newValue }
    }
}

// Note: Logger.navigation is defined in Logger+Extensions.swift
