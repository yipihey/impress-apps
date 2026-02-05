//
//  AppStateStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog

// MARK: - Sidebar Selection State

/// Serializable representation of sidebar selection.
/// Stores UUIDs instead of Core Data objects for persistence.
public enum SidebarSelectionState: Codable, Equatable, Sendable {
    case inbox
    case inboxFeed(UUID)              // Smart search ID (feeds to inbox)
    case inboxCollection(UUID)        // Collection ID within Inbox
    case library(UUID)                // Library ID
    case search                       // Legacy search (kept for compatibility)
    case searchForm(SearchFormType)   // Specific search form
    case smartSearch(UUID)            // Smart search ID
    case collection(UUID)             // Collection ID
    case scixLibrary(UUID)            // SciX online library ID
    case flagged(String?)             // Flagged publications (nil = any flag, color name)
}

// MARK: - App State

/// Persistent app state that survives across launches.
public struct AppState: Codable, Equatable, Sendable {
    /// Currently selected sidebar section
    public var sidebarSelection: SidebarSelectionState?

    /// Currently selected publication UUID
    public var selectedPublicationID: UUID?

    /// Currently selected detail tab (info, bibtex, pdf, notes)
    public var selectedDetailTab: String

    /// Set of expanded library UUIDs in sidebar
    public var expandedLibraries: Set<UUID>

    /// Notes panel size in points
    public var notesPanelSize: Double

    /// Whether notes panel is collapsed
    public var notesPanelCollapsed: Bool

    public init(
        sidebarSelection: SidebarSelectionState? = nil,
        selectedPublicationID: UUID? = nil,
        selectedDetailTab: String = "info",
        expandedLibraries: Set<UUID> = [],
        notesPanelSize: Double = 400,
        notesPanelCollapsed: Bool = false
    ) {
        self.sidebarSelection = sidebarSelection
        self.selectedPublicationID = selectedPublicationID
        self.selectedDetailTab = selectedDetailTab
        self.expandedLibraries = expandedLibraries
        self.notesPanelSize = notesPanelSize
        self.notesPanelCollapsed = notesPanelCollapsed
    }

    /// Default state for first launch
    public static let `default` = AppState()
}

// MARK: - App State Store

/// Actor-based store for persisting app state across launches.
public actor AppStateStore {
    public static let shared = AppStateStore(userDefaults: .forCurrentEnvironment)

    private let userDefaults: UserDefaults
    private let stateKey = "appState"
    private var cachedState: AppState?
    private var saveTask: Task<Void, Never>?

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    /// Get current app state (cached or loaded from UserDefaults)
    public var state: AppState {
        if let cached = cachedState {
            return cached
        }
        let loaded = loadState()
        cachedState = loaded
        return loaded
    }

    /// Load state from UserDefaults
    private func loadState() -> AppState {
        guard let data = userDefaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            Logger.appState.info("No saved app state found, using defaults")
            return .default
        }
        Logger.appState.info("Loaded app state: sidebar=\(String(describing: state.sidebarSelection)), paper=\(state.selectedPublicationID?.uuidString ?? "none")")
        return state
    }

    /// Save state to UserDefaults (debounced)
    public func save(_ state: AppState) {
        cachedState = state

        // Cancel any pending save
        saveTask?.cancel()

        // Debounce: wait 500ms before actually saving
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            if let data = try? JSONEncoder().encode(state) {
                userDefaults.set(data, forKey: stateKey)
                Logger.appState.debug("Saved app state")
            }
        }
    }

    /// Update a single field and save
    public func updateSidebarSelection(_ selection: SidebarSelectionState?) {
        var current = state
        current.sidebarSelection = selection
        save(current)
    }

    public func updateSelectedPublication(_ id: UUID?) {
        var current = state
        current.selectedPublicationID = id
        save(current)
    }

    public func updateSelectedDetailTab(_ tab: String) {
        var current = state
        current.selectedDetailTab = tab
        save(current)
    }

    public func updateExpandedLibraries(_ libraries: Set<UUID>) {
        var current = state
        current.expandedLibraries = libraries
        save(current)
    }

    public func updateNotesPanelSize(_ size: Double) {
        var current = state
        current.notesPanelSize = size
        save(current)
    }

    public func updateNotesPanelCollapsed(_ collapsed: Bool) {
        var current = state
        current.notesPanelCollapsed = collapsed
        save(current)
    }

    /// Clear saved state (for testing)
    public func reset() {
        userDefaults.removeObject(forKey: stateKey)
        cachedState = nil
        Logger.appState.info("Reset app state")
    }
}

// MARK: - Logger Extension

extension Logger {
    static let appState = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "appState")
}
