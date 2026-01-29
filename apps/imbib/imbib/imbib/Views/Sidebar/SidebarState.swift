//
//  SidebarState.swift
//  imbib
//
//  Created by Claude on 2026-01-28.
//

import SwiftUI
import PublicationManagerCore

// MARK: - Sidebar Sheet Enum

/// Enum for mutually exclusive sheet presentations in the sidebar.
/// Using an enum with associated values ensures only one sheet can be presented at a time,
/// eliminating bugs from conflicting boolean flags.
public enum SidebarSheet: Identifiable {
    case newLibrary
    case newSmartCollection(CDLibrary)
    case editCollection(CDCollection)
    case dropPreview(libraryID: UUID)
    case mboxImport(preview: MboxImportPreview, library: CDLibrary)

    public var id: String {
        switch self {
        case .newLibrary:
            return "newLibrary"
        case .newSmartCollection(let library):
            return "newSmartCollection-\(library.id)"
        case .editCollection(let collection):
            return "editCollection-\(collection.id)"
        case .dropPreview(let libraryID):
            return "dropPreview-\(libraryID)"
        case .mboxImport(_, let library):
            return "mboxImport-\(library.id)"
        }
    }
}

// MARK: - Sidebar State

/// Consolidated state for SidebarView.
/// Using @Observable with a single state object simplifies state management
/// and makes it easier to reason about the view's behavior.
@MainActor @Observable
public final class SidebarState {

    // MARK: - Active Sheet (enum-based, mutually exclusive)

    /// The currently presented sheet, or nil if no sheet is shown.
    /// Using an optional enum ensures only one sheet can be presented at a time.
    var activeSheet: SidebarSheet?

    // MARK: - Drop State

    /// The library currently being targeted by a drag operation (for "All Publications" row)
    var dropTargetedLibrary: UUID?

    /// The library header currently being targeted by a drag operation
    var dropTargetedLibraryHeader: UUID?

    /// The collection currently being targeted by a drag operation
    var dropTargetedCollection: UUID?

    /// The library ID for the drop preview sheet
    var dropPreviewTargetLibraryID: UUID?

    // MARK: - Multi-selection State

    /// Multi-selection for exploration collections (Option+click to toggle, Shift+click for range)
    var explorationMultiSelection: Set<UUID> = []

    /// Last selected exploration collection ID for Shift+click range selection
    var lastSelectedExplorationID: UUID?

    /// Expanded state for exploration collection tree disclosure groups
    var expandedExplorationCollections: Set<UUID> = []

    /// Expanded state for library collection tree, keyed by library ID
    var expandedLibraryCollections: [UUID: Set<UUID>] = [:]

    /// Multi-selection for smart searches in exploration section
    var searchMultiSelection: Set<UUID> = []

    /// Last selected smart search ID for Shift+click range selection
    var lastSelectedSearchID: UUID?

    // MARK: - Editing State

    /// Collection currently being renamed inline
    var renamingCollection: CDCollection?

    // MARK: - Confirmation Dialogs

    /// Library pending deletion (shows confirmation dialog)
    var libraryToDelete: CDLibrary?

    /// Whether to show the delete library confirmation dialog
    var showDeleteConfirmation = false

    /// Whether to show the empty dismissed confirmation dialog
    var showEmptyDismissedConfirmation = false

    // MARK: - Mbox Import/Export State

    /// The target library for mbox import
    var mboxImportTargetLibrary: CDLibrary?

    /// Whether to show the mbox import file picker
    var showMboxImportPicker = false

    /// Error message from mbox export/import operation
    var mboxExportError: String?

    /// Whether to show the mbox export error alert
    var showMboxExportError = false

    /// Mbox import preview data (used with activeSheet.mboxImport)
    var mboxImportPreview: MboxImportPreview?

    // MARK: - UI Refresh Triggers

    /// Triggers re-render when read status changes
    var refreshTrigger = UUID()

    /// Triggers refresh of the exploration section
    var explorationRefreshTrigger = UUID()

    // MARK: - API Key State

    /// Whether SciX/ADS API key is configured
    var hasSciXAPIKey = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Helper Methods

    /// Dismiss the currently active sheet
    func dismissSheet() {
        activeSheet = nil
    }

    /// Present the new library sheet
    func showNewLibrary() {
        activeSheet = .newLibrary
    }

    /// Present the smart collection editor for a library
    func showNewSmartCollection(for library: CDLibrary) {
        activeSheet = .newSmartCollection(library)
    }

    /// Present the collection editor for editing an existing collection
    func showEditCollection(_ collection: CDCollection) {
        activeSheet = .editCollection(collection)
    }

    /// Present the drop preview sheet for a library
    func showDropPreview(for libraryID: UUID) {
        dropPreviewTargetLibraryID = libraryID
        activeSheet = .dropPreview(libraryID: libraryID)
    }

    /// Present the mbox import preview sheet
    func showMboxImportPreview(preview: MboxImportPreview, library: CDLibrary) {
        mboxImportPreview = preview
        activeSheet = .mboxImport(preview: preview, library: library)
    }

    /// Trigger a sidebar refresh
    func triggerRefresh() {
        refreshTrigger = UUID()
    }

    /// Trigger an exploration section refresh
    func triggerExplorationRefresh() {
        explorationRefreshTrigger = UUID()
    }

    /// Clear exploration multi-selection
    func clearExplorationSelection() {
        explorationMultiSelection.removeAll()
        lastSelectedExplorationID = nil
    }

    /// Clear search multi-selection
    func clearSearchSelection() {
        searchMultiSelection.removeAll()
        lastSelectedSearchID = nil
    }
}
