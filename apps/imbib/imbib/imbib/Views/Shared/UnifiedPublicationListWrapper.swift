//
//  UnifiedPublicationListWrapper.swift
//  imbib
//
//  Created by Claude on 2026-01-05.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog
import ImpressKeyboard
import ImpressFTUI

private let logger = Logger(subsystem: "com.imbib.app", category: "publicationlist")

// MARK: - Publication Source

/// The data source for publications in the unified list view.
enum PublicationSource: Hashable {
    case library(CDLibrary)
    case smartSearch(CDSmartSearch)
    case lastSearch(CDCollection)  // ADR-016: Ad-hoc search results from "Last Search" collection
    case collection(CDCollection)  // Regular or smart collection
    case flagged(String?)           // Flagged publications (nil = any flag, or specific color name)

    var id: UUID {
        switch self {
        case .library(let library): return library.id
        case .smartSearch(let smartSearch): return smartSearch.id
        case .lastSearch(let collection): return collection.id
        case .collection(let collection): return collection.id
        case .flagged(let color):
            // Use a fixed namespace UUID for flagged virtual sources
            switch color {
            case "red":   return UUID(uuidString: "F1A99ED0-0001-4000-8000-000000000000")!
            case "amber": return UUID(uuidString: "F1A99ED0-0002-4000-8000-000000000000")!
            case "blue":  return UUID(uuidString: "F1A99ED0-0003-4000-8000-000000000000")!
            case "gray":  return UUID(uuidString: "F1A99ED0-0004-4000-8000-000000000000")!
            default:      return UUID(uuidString: "F1A99ED0-0000-4000-8000-000000000000")!
            }
        }
    }

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }

    var isSmartSearch: Bool {
        if case .smartSearch = self { return true }
        return false
    }

    var isLastSearch: Bool {
        if case .lastSearch = self { return true }
        return false
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }

    var isFlagged: Bool {
        if case .flagged = self { return true }
        return false
    }

    /// Whether the current user can edit content in this source.
    /// Returns false for read-only shared libraries.
    var canEdit: Bool {
        switch self {
        case .library(let library):
            return library.canEditLibrary
        case .collection(let collection):
            return collection.library?.canEditLibrary ?? true
        case .smartSearch, .lastSearch, .flagged:
            return true
        }
    }
}

// MARK: - Filter Mode

/// Filter mode for the publication list.
enum LibraryFilterMode: String, CaseIterable {
    case all
    case unread
}

// Note: SmartSearchProviderCache is now in PublicationManagerCore

// MARK: - Unified Publication List Wrapper

/// A unified wrapper view that displays publications from either a library or a smart search.
///
/// This view uses the same @State + explicit refresh pattern for both sources,
/// ensuring consistent behavior and immediate UI updates after mutations.
///
/// Features (same for both sources):
/// - @State publications with explicit refresh
/// - All/Unread filter (via Cmd+\\ keyboard shortcut)
/// - Refresh button (library = future enrichment, smart search = re-search)
/// - Loading/error states
/// - OSLog logging
struct UnifiedPublicationListWrapper: View {

    // MARK: - Properties

    let source: PublicationSource
    @Binding var selectedPublication: CDPublication?
    /// Multi-selection IDs for bulk operations
    @Binding var selectedPublicationIDs: Set<UUID>

    /// Initial filter mode (for Unread sidebar item)
    var initialFilterMode: LibraryFilterMode = .all

    /// Called when "Download PDFs" is requested for selected publications
    var onDownloadPDFs: ((Set<UUID>) -> Void)?

    /// Focused pane for vim-style navigation (optional - for focus border display)
    var focusedPane: Binding<FocusedPane?>?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Unified State

    @State private var publications: [CDPublication] = []
    // selectedPublicationIDs is now a binding: selectedPublicationIDs
    @State private var isLoading = false
    @State private var error: Error?
    @State private var filterMode: LibraryFilterMode = .all
    @State private var filterScope: FilterScope = .current
    @State private var provider: SmartSearchProvider?
    @State private var dropHandler = FileDropHandler()

    // Drop preview sheet state (for list background drops)
    private let dragDropCoordinator = DragDropCoordinator.shared
    @State private var showingDropPreview = false
    @State private var dropPreviewTargetLibraryID: UUID?

    /// Whether a background refresh is in progress (for subtle UI indicator)
    @State private var isBackgroundRefreshing = false

    /// Mapping of publication ID to library name for grouped search display
    @State private var libraryNameMapping: [UUID: String] = [:]

    /// Triage flash state for keyboard shortcuts (K/D keys)
    @State private var keyboardTriageFlash: (id: UUID, color: Color)?

    /// Current sort order - owned by wrapper for synchronous visual order computation.
    @State private var currentSortOrder: LibrarySortOrder = .dateAdded
    @State private var currentSortAscending: Bool = false

    /// ADR-020: Recommendation scores for sorted display.
    /// Owned by wrapper to ensure synchronous access during triage.
    @State private var recommendationScores: [UUID: Double] = [:]
    @State private var serendipitySlotIDs: Set<UUID> = []
    @State private var isComputingRecommendations: Bool = false

    // State for duplicate file alert
    @State private var showDuplicateAlert = false
    @State private var duplicateFilename = ""

    /// Snapshot of publication IDs visible when unread filter was applied.
    /// Enables Apple Mail behavior: items stay visible after being marked as read
    /// until the user navigates away or explicitly refreshes.
    @State private var unreadFilterSnapshot: Set<UUID>?

    // Import toast state
    @State private var importToastMessage: String?
    @State private var importToastCount: Int = 0

    // Tag input state
    @State private var isTagInputActive = false
    @State private var isTagDeleteActive = false
    @State private var tagTargetIDs: Set<UUID> = []
    @State private var tagCompletions: [TagCompletion] = []
    @State private var tagAutocomplete: TagAutocompleteService?

    // Flag input state
    @State private var isFlagInputActive = false
    @State private var flagTargetIDs: Set<UUID> = []

    // Filter input state
    @State private var isFilterActive = false
    @State private var filterText = ""
    @State private var activeFilter: LocalFilter?

    /// Version counter bumped when publication data changes in-place (flag/tag mutations)
    /// Passed to PublicationListView to force row data cache rebuild.
    @State private var listDataVersion: Int = 0

    /// Focus state for keyboard navigation - list needs focus to receive key events
    @FocusState private var isListFocused: Bool

    // MARK: - Computed Properties

    /// Check if the source (library or smart search) is still valid (not deleted)
    private var isSourceValid: Bool {
        switch source {
        case .library(let library):
            return library.managedObjectContext != nil && !library.isDeleted
        case .smartSearch(let smartSearch):
            return smartSearch.managedObjectContext != nil && !smartSearch.isDeleted
        case .lastSearch(let collection):
            return collection.managedObjectContext != nil && !collection.isDeleted
        case .collection(let collection):
            return collection.managedObjectContext != nil && !collection.isDeleted
        case .flagged:
            return true  // Virtual source, always valid
        }
    }

    private var navigationTitle: String {
        switch source {
        case .library(let library):
            guard library.managedObjectContext != nil else { return "" }
            return filterMode == .unread ? "Unread" : library.displayName
        case .smartSearch(let smartSearch):
            guard smartSearch.managedObjectContext != nil else { return "" }
            return smartSearch.name
        case .lastSearch:
            return "Search Results"
        case .collection(let collection):
            guard collection.managedObjectContext != nil else { return "" }
            return collection.name
        case .flagged(let color):
            if let color { return "\(color.capitalized) Flagged" }
            return "Flagged"
        }
    }

    private var currentLibrary: CDLibrary? {
        guard isSourceValid else { return nil }
        switch source {
        case .library(let library):
            return library
        case .smartSearch(let smartSearch):
            return smartSearch.resultCollection?.library ?? smartSearch.library
        case .lastSearch(let collection):
            return collection.library ?? collection.owningLibrary
        case .collection(let collection):
            return collection.effectiveLibrary
        case .flagged:
            return libraryManager.activeLibrary
        }
    }

    private var listID: ListViewID {
        switch source {
        case .library(let library):
            return .library(library.id)
        case .smartSearch(let smartSearch):
            return .smartSearch(smartSearch.id)
        case .lastSearch(let collection):
            return .lastSearch(collection.id)
        case .collection(let collection):
            return .collection(collection.id)
        case .flagged:
            return .flagged(source.id)
        }
    }

    private var emptyMessage: String {
        switch source {
        case .library:
            return "No Publications"
        case .smartSearch(let smartSearch):
            return "No Results for \"\(smartSearch.query)\""
        case .lastSearch:
            return "No Results"
        case .collection:
            return "No Publications"
        case .flagged(let color):
            if let color { return "No \(color.capitalized) Flagged Papers" }
            return "No Flagged Papers"
        }
    }

    private var emptyDescription: String {
        switch source {
        case .library:
            return "Add publications to your library or search online sources."
        case .smartSearch:
            return "Click refresh to search again."
        case .lastSearch:
            return "Enter a query to search across multiple sources."
        case .collection:
            return "Drag publications to this collection."
        case .flagged:
            return "Flag papers to see them here."
        }
    }

    // MARK: - Body

    /// Check if we're viewing the Inbox library or an Inbox feed
    private var isInboxView: Bool {
        guard isSourceValid else { return false }
        switch source {
        case .library(let library):
            return library.isInbox
        case .smartSearch(let smartSearch):
            // Inbox feeds also support triage shortcuts
            return smartSearch.feedsToInbox
        case .lastSearch:
            // Search results are not inbox - but triage shortcuts (S/T) work everywhere
            return false
        case .collection:
            // Collections are not inbox views
            return false
        case .flagged:
            return false
        }
    }

    /// Check if we're viewing an exploration collection (in the system Exploration library).
    /// Exploration collections have special triage behavior:
    /// - S key: Save to Save library AND remove from exploration collection
    /// - D key: Remove from collection only (NOT move to Dismissed library)
    private var isExplorationCollection: Bool {
        guard isSourceValid else { return false }
        if case .collection(let collection) = source {
            return collection.library?.isSystemLibrary == true
        }
        return false
    }

    var body: some View {
        // Guard against deleted source - return empty view to prevent crash
        if !isSourceValid {
            Color.clear
        } else {
            bodyContent
                .overlay(alignment: .bottom) {
                    importToast
                }
        }
    }

    // MARK: - Import Toast

    @ViewBuilder
    private var importToast: some View {
        if let message = importToastMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: importToastCount)
                Text(message)
                    .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Main body content separated to help compiler type-checking
    @ViewBuilder
    private var bodyContent: some View {
        contentView
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress { press in handleVimNavigation(press) }
            .onKeyPress(.init("d")) { handleDismissKey() }
            .task(id: source.id) {
                filterMode = initialFilterMode
                filterScope = .current  // Reset scope on navigation
                unreadFilterSnapshot = nil  // Reset snapshot on navigation

                // If starting with unread filter, capture snapshot after loading data
                if initialFilterMode == .unread {
                    refreshPublicationsList()
                    unreadFilterSnapshot = captureUnreadSnapshot()
                } else {
                    refreshPublicationsList()
                }

                if case .smartSearch(let smartSearch) = source {
                    await queueBackgroundRefreshIfNeeded(smartSearch)
                }
            }
            .onAppear {
                // Give the list focus so keyboard shortcuts work immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isListFocused = true
                }
            }
            // Restore list focus when any input overlay dismisses
            .onChange(of: isFlagInputActive) { _, active in
                if !active { restoreListFocus() }
            }
            .onChange(of: isTagInputActive) { _, active in
                if !active { restoreListFocus() }
            }
            .onChange(of: isTagDeleteActive) { _, active in
                if !active { restoreListFocus() }
            }
            .onChange(of: isFilterActive) { _, active in
                if !active { restoreListFocus() }
            }
            .onChange(of: filterMode) { _, newMode in
                // Capture snapshot when switching TO unread filter (Apple Mail behavior)
                if newMode == .unread {
                    unreadFilterSnapshot = captureUnreadSnapshot()
                } else {
                    unreadFilterSnapshot = nil
                }
                refreshPublicationsList()
            }
            .onChange(of: filterScope) { _, _ in
                refreshPublicationsList()
            }
            .modifier(NotificationModifiers(
                onToggleReadStatus: toggleReadStatusForSelected,
                onCopyPublications: { Task { await copySelectedPublications() } },
                onCutPublications: { Task { await cutSelectedPublications() } },
                onPastePublications: {
                    Task {
                        try? await libraryViewModel.pasteFromClipboard()
                        refreshPublicationsList()
                    }
                },
                onSelectAll: selectAllPublications
            ))
            .modifier(SmartSearchRefreshModifier(
                source: source,
                onRefreshComplete: { smartSearchName in
                    logger.info("Background refresh completed for '\(smartSearchName)', refreshing UI")
                    isBackgroundRefreshing = false
                    refreshPublicationsList()
                }
            ))
            .onReceive(NotificationCenter.default.publisher(for: .lastSearchUpdated)) { _ in
                // Refresh list when Last Search collection is updated
                if case .lastSearch = source {
                    logger.info("Last search updated notification received, refreshing list")
                    refreshPublicationsList()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfImportCompleted)) { notification in
                // Handle PDF import completion: select imported publications, scroll to them, and show PDF viewer
                guard let importedIDs = notification.object as? [UUID], !importedIDs.isEmpty else { return }

                logger.info("PDF import completed with \(importedIDs.count) publications")

                // Refresh list first to ensure imported publications are visible
                refreshPublicationsList()

                // Select the imported publications
                selectedPublicationIDs = Set(importedIDs)

                // Set the first imported publication as the selected publication for detail view
                if let firstID = importedIDs.first,
                   let firstPub = publications.first(where: { $0.id == firstID }) {
                    selectedPublication = firstPub
                }

                // Show import success toast
                let count = importedIDs.count
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    importToastMessage = count == 1 ? "1 paper imported" : "\(count) papers imported"
                    importToastCount += 1
                }

                // Auto-dismiss toast after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        importToastMessage = nil
                    }
                }

                // Scroll to selection and show PDF tab after a brief delay to allow UI to update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    // Scroll to make the imported publication visible
                    NotificationCenter.default.post(name: .scrollToSelection, object: nil)

                    // Show PDF tab
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: .showPDFTab, object: nil)
                    }
                }
            }
            .modifier(InboxTriageModifier(
                isInboxView: isInboxView,
                hasSelection: !selectedPublicationIDs.isEmpty,
                onSave: saveSelectedToDefaultLibrary,
                onSaveAndStar: saveAndStarSelected,
                onToggleStar: toggleStarForSelected,
                onDismiss: dismissSelectedFromInbox
            ))
            .alert("Duplicate File", isPresented: $showDuplicateAlert) {
                Button("Skip") {
                    dropHandler.resolveDuplicate(proceed: false)
                }
                Button("Attach Anyway") {
                    dropHandler.resolveDuplicate(proceed: true)
                }
            } message: {
                Text("This file is identical to '\(duplicateFilename)' which is already attached. Do you want to attach it anyway?")
            }
            .onChange(of: dropHandler.pendingDuplicate) { _, newValue in
                if let pending = newValue {
                    duplicateFilename = pending.existingFilename
                    showDuplicateAlert = true
                }
            }
            .onChange(of: dragDropCoordinator.pendingPreview) { _, newValue in
                // Dismiss the sheet when pendingPreview becomes nil (import completed or cancelled)
                if newValue == nil && showingDropPreview {
                    showingDropPreview = false
                }
            }
            .sheet(isPresented: $showingDropPreview) {
                dropPreviewSheetContent
                    .frame(minWidth: 500, minHeight: 400)
            }
    }

    // MARK: - Drop Preview Sheet

    /// Drop preview sheet content for list background drops
    @ViewBuilder
    private var dropPreviewSheetContent: some View {
        @Bindable var coordinator = dragDropCoordinator
        if let libraryID = dropPreviewTargetLibraryID {
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: libraryID,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                dropPreviewTargetLibraryID = nil
                refreshPublicationsList()
            }
        } else if let library = currentLibrary {
            // Fallback: use current library
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: library.id,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                refreshPublicationsList()
            }
        } else if let firstLibrary = libraryManager.libraries.first(where: { !$0.isInbox && !$0.isSystemLibrary }) {
            // Fallback: use first user library
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: firstLibrary.id,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                refreshPublicationsList()
            }
        } else {
            // No libraries available
            VStack {
                Text("No Library Available")
                    .font(.headline)
                Text("Create a library first to import PDFs.")
                    .foregroundStyle(.secondary)
                Button("Close") {
                    showingDropPreview = false
                    dragDropCoordinator.pendingPreview = nil
                }
                .padding(.top)
            }
            .padding()
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        if isLoading && publications.isEmpty {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            errorView(error)
        } else {
            VStack(spacing: 0) {
                // Read-only banner for shared libraries
                if !sourceCanEdit {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                        Text("Read Only")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .foregroundStyle(.secondary)
                }

                listView

                // Flag input mode overlay
                if isFlagInputActive {
                    FlagInput(
                        isPresented: $isFlagInputActive,
                        onCommit: { flag in
                            commitFlag(flag)
                        },
                        onCancel: {
                            flagTargetIDs = []
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Tag input mode overlay (at bottom, like flag input)
                if isTagInputActive {
                    TagInput(
                        isPresented: $isTagInputActive,
                        completions: tagCompletions,
                        onCommit: { path in
                            commitTag(path: path)
                        },
                        onCancel: {
                            tagTargetIDs = []
                        },
                        onTextChanged: { text in
                            updateTagCompletions(text)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Tag delete mode overlay
                if isTagDeleteActive, let pubID = selectedPublicationIDs.first,
                   let pub = publications.first(where: { $0.id == pubID }) {
                    let rowData = PublicationRowData(publication: pub)
                    TagDeleteMode(
                        isPresented: $isTagDeleteActive,
                        tags: rowData?.tagDisplays ?? [],
                        onRemoveTag: { tagID in
                            handleRemoveTag(pubID: pubID, tagID: tagID)
                        },
                        onCancel: {}
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Filter input mode overlay
                if isFilterActive {
                    FilterInput(
                        isPresented: $isFilterActive,
                        currentText: filterText,
                        onTextChanged: { text in
                            filterText = text
                            applyFilterText(text)
                        },
                        onCancel: {
                            clearFilter()
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Active filter indicator (shown when filter input is dismissed but filter is active)
                if !isFilterActive, let filter = activeFilter, !filter.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.purple)
                        Text(filterText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            clearFilter()
                        } label: {
                            Text("Clear")
                                .font(.caption)
                                .foregroundStyle(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isFilterActive = true
                        }
                    }
                }
            }
        }
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Retry") {
                Task { await refreshFromNetwork() }
            }
        }
    }

    /// Whether the current source is editable (false for read-only shared libraries)
    private var sourceCanEdit: Bool {
        source.canEdit
    }

    private var listView: some View {
        PublicationListView(
            publications: publications,
            selection: $selectedPublicationIDs,
            selectedPublication: $selectedPublication,
            library: currentLibrary,
            allLibraries: libraryManager.libraries,
            showImportButton: false,
            showSortMenu: true,
            emptyStateMessage: emptyMessage,
            emptyStateDescription: emptyDescription,
            listID: listID,
            disableUnreadFilter: isInboxView,
            isInInbox: isInboxView,
            saveLibrary: isInboxView ? libraryManager.getOrCreateSaveLibrary() : nil,
            filterScope: $filterScope,
            libraryNameMapping: libraryNameMapping,
            sortOrder: $currentSortOrder,
            sortAscending: $currentSortAscending,
            recommendationScores: $recommendationScores,
            onDelete: !sourceCanEdit ? nil : { ids in
                // Remove from local state FIRST to prevent SwiftUI from rendering deleted objects
                // Use isDeleted/isFault check to avoid crash when accessing id on invalid objects
                publications.removeAll { pub in
                    guard !pub.isDeleted, !pub.isFault else { return true }
                    return ids.contains(pub.id)
                }
                // Clear selection for deleted items
                selectedPublicationIDs.subtract(ids)
                // Then delete from Core Data
                await libraryViewModel.delete(ids: ids)
                refreshPublicationsList()
            },
            onToggleRead: { publication in
                await libraryViewModel.toggleReadStatus(publication)
                refreshPublicationsList()
            },
            onCopy: { ids in
                await libraryViewModel.copyToClipboard(ids)
            },
            onCut: !sourceCanEdit ? nil : { ids in
                await libraryViewModel.cutToClipboard(ids)
                refreshPublicationsList()
            },
            onPaste: !sourceCanEdit ? nil : {
                try? await libraryViewModel.pasteFromClipboard()
                refreshPublicationsList()
            },
            onAddToLibrary: { ids, targetLibrary in
                await libraryViewModel.addToLibrary(ids, library: targetLibrary)
                refreshPublicationsList()
            },
            onAddToCollection: { ids, collection in
                await libraryViewModel.addToCollection(ids, collection: collection)
            },
            onRemoveFromAllCollections: !sourceCanEdit ? nil : { ids in
                await libraryViewModel.removeFromAllCollections(ids)
            },
            onImport: nil,
            onOpenPDF: { publication in
                openPDF(for: publication)
            },
            onFileDrop: !sourceCanEdit ? nil : { publication, providers in
                Task {
                    await dropHandler.handleDrop(
                        providers: providers,
                        for: publication,
                        in: currentLibrary
                    )
                    // Refresh to show new attachments (paperclip indicator)
                    refreshPublicationsList()
                }
            },
            onListDrop: { providers, target in
                // Handle PDF drop on list background for import
                logger.info("onListDrop triggered with target: \(String(describing: target))")
                Task {
                    let result = await DragDropCoordinator.shared.performDrop(
                        DragDropInfo(providers: providers),
                        target: target
                    )
                    logger.info("performDrop returned: \(String(describing: result))")
                    if case .needsConfirmation = result {
                        await MainActor.run {
                            // Extract library ID from target for the preview sheet
                            switch target {
                            case .library(let libraryID):
                                logger.info("Setting dropPreviewTargetLibraryID from .library: \(libraryID)")
                                dropPreviewTargetLibraryID = libraryID
                            case .collection(_, let libraryID):
                                logger.info("Setting dropPreviewTargetLibraryID from .collection: \(libraryID)")
                                dropPreviewTargetLibraryID = libraryID
                            case .inbox, .publication, .newLibraryZone:
                                logger.info("Fallback - currentLibrary?.id: \(String(describing: currentLibrary?.id))")
                                // Use current library as fallback
                                dropPreviewTargetLibraryID = currentLibrary?.id
                            }
                            logger.info("Setting showingDropPreview = true")
                            showingDropPreview = true
                        }
                    }
                    refreshPublicationsList()
                }
            },
            onDownloadPDFs: onDownloadPDFs,
            // Keep callback - only available in Inbox (implied once in library)
            onSaveToLibrary: isInboxView ? { ids, targetLibrary in
                await saveToLibrary(ids: ids, targetLibrary: targetLibrary)
            } : nil,
            // Dismiss callback - available for all views (moves papers to dismissed library)
            onDismiss: { ids in
                await dismissFromInbox(ids: ids)
            },
            onToggleStar: { ids in
                await toggleStarForIDs(ids)
            },
            onSetFlag: { ids, color in
                await setFlagForIDs(ids, color: color)
            },
            onClearFlag: { ids in
                await clearFlagForIDs(ids)
            },
            onAddTag: { ids in
                handleAddTag(ids)
            },
            onRemoveTag: { pubID, tagID in
                handleRemoveTag(pubID: pubID, tagID: tagID)
            },
            onMuteAuthor: isInboxView ? { authorName in
                muteAuthor(authorName)
            } : nil,
            onMutePaper: isInboxView ? { publication in
                mutePaper(publication)
            } : nil,
            // Refresh callback (shown as small button in list header)
            onRefresh: {
                await refreshFromNetwork()
            },
            isRefreshing: isLoading || isBackgroundRefreshing,
            dataVersion: listDataVersion,
            // External flash trigger for keyboard shortcuts
            externalTriageFlash: $keyboardTriageFlash
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Toolbar is now mostly empty - refresh moved to inline toolbar in list view
        // EmptyView is needed for the ToolbarContentBuilder
        ToolbarItem(placement: .automatic) {
            EmptyView()
        }
    }

    // MARK: - Data Refresh

    /// Refresh publications from data source (synchronous read)
    private func refreshPublicationsList() {
        // Handle cross-scope fetching
        switch filterScope {
        case .current:
            refreshCurrentScopePublications()
        case .allLibraries, .inbox, .everything:
            publications = fetchPublications(for: filterScope)
            logger.info("Refreshed \(filterScope.rawValue): \(self.publications.count) items")
        }

        // Apply local filter syntax if active
        if let filter = activeFilter, !filter.isEmpty {
            publications = LocalFilterService.shared.apply(filter, to: publications)
        }
    }

    /// Refresh publications for the current source (library or smart search)
    ///
    /// Simplified: All papers in a library are in `library.publications`.
    /// No merge logic needed - smart search results are added to the library relationship.
    private func refreshCurrentScopePublications() {
        // Clear library name mapping for current scope (no grouped display)
        libraryNameMapping = [:]

        guard isSourceValid else {
            publications = []
            return
        }
        switch source {
        case .library(let library):
            // Simple: just use the library's publications relationship
            // Note: Only filter by isDeleted, not managedObjectContext - during Core Data
            // background merges, managedObjectContext can temporarily be nil even for valid
            // objects, which causes list churn and selection loss
            var result = (library.publications ?? [])
                .filter { !$0.isDeleted }

            // Apply filter mode with Apple Mail behavior:
            // Items stay visible after being read if they were visible when filter was applied.
            // Skip for Inbox - papers should stay visible after being read regardless.
            if filterMode == .unread && !library.isInbox {
                if let snapshot = unreadFilterSnapshot {
                    // Keep items in snapshot visible (Apple Mail behavior)
                    result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                } else {
                    // No snapshot - strict filter (fresh application)
                    result = result.filter { !$0.isRead }
                }
            }

            publications = result.sorted { $0.dateAdded > $1.dateAdded }
            logger.info("Refreshed library: \(self.publications.count) items")

        case .smartSearch(let smartSearch):
            // Show result collection (organizational view within the library)
            guard let collection = smartSearch.resultCollection else {
                publications = []
                return
            }
            var result = (collection.publications ?? [])
                .filter { !$0.isDeleted }

            // Apply filter mode with Apple Mail behavior.
            // Skip for Inbox feeds - papers should stay visible after being read regardless.
            if filterMode == .unread && !smartSearch.feedsToInbox {
                if let snapshot = unreadFilterSnapshot {
                    // Keep items in snapshot visible (Apple Mail behavior)
                    result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                } else {
                    // No snapshot - strict filter (fresh application)
                    result = result.filter { !$0.isRead }
                }
            }

            publications = result.sorted { $0.dateAdded > $1.dateAdded }
            logger.info("Refreshed smart search: \(self.publications.count) items")

        case .lastSearch(let collection):
            // ADR-016: Show ad-hoc search results from the "Last Search" collection
            var result = (collection.publications ?? [])
                .filter { !$0.isDeleted }

            // Apply filter mode if needed
            if filterMode == .unread {
                if let snapshot = unreadFilterSnapshot {
                    result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                } else {
                    result = result.filter { !$0.isRead }
                }
            }

            publications = result.sorted { $0.dateAdded > $1.dateAdded }
            logger.info("Refreshed last search: \(self.publications.count) items")

        case .collection(let collection):
            // Handle both smart collections and static collections
            // Use a Task for async smart collection execution
            Task {
                var result: [CDPublication]
                if collection.isSmartCollection {
                    // Execute predicate for smart collections
                    result = await libraryViewModel.executeSmartCollection(collection)
                } else {
                    // For static collections, include publications from this collection
                    // AND all descendant subcollections
                    result = Array(collection.allPublicationsIncludingDescendants)
                        .filter { !$0.isDeleted }
                }

                // Apply filter mode with Apple Mail behavior
                if filterMode == .unread {
                    if let snapshot = unreadFilterSnapshot {
                        result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                    } else {
                        result = result.filter { !$0.isRead }
                    }
                }

                await MainActor.run {
                    var sorted = result.sorted { $0.dateAdded > $1.dateAdded }
                    if let filter = activeFilter, !filter.isEmpty {
                        sorted = LocalFilterService.shared.apply(filter, to: sorted)
                    }
                    publications = sorted
                    logger.info("Refreshed collection: \(self.publications.count) items")
                }
            }

        case .flagged(let colorName):
            // Fetch flagged publications across all libraries
            let context = PersistenceController.shared.viewContext
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            if let colorName {
                request.predicate = NSPredicate(format: "flagColor == %@", colorName)
            } else {
                request.predicate = NSPredicate(format: "flagColor != nil")
            }
            request.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: false)]
            var result = (try? context.fetch(request))?.filter { !$0.isDeleted } ?? []

            // Apply filter mode
            if filterMode == .unread {
                if let snapshot = unreadFilterSnapshot {
                    result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                } else {
                    result = result.filter { !$0.isRead }
                }
            }

            publications = result
            logger.info("Refreshed flagged(\(colorName ?? "any")): \(self.publications.count) items")
        }
    }

    /// Fetch publications for a given scope and build library name mapping.
    ///
    /// Unified method replaces fetchAllLibrariesPublications, fetchInboxPublications, fetchEverythingPublications.
    /// - Parameter scope: Which libraries to include
    /// - Returns: Array of publications sorted by dateAdded (newest first)
    private func fetchPublications(for scope: FilterScope) -> [CDPublication] {
        // Determine which libraries to include based on scope
        let libraries: [CDLibrary] = switch scope {
        case .current:
            // For current scope, get from source (handled separately in refreshCurrentScopePublications)
            if case .library(let lib) = source { [lib] } else { [] }
        case .allLibraries:
            libraryManager.libraries.filter { !$0.isInbox }
        case .inbox:
            libraryManager.libraries.filter { $0.isInbox }
        case .everything:
            libraryManager.libraries
        }

        // Collect all publications from the selected libraries with library name tracking
        var allPublications = Set<CDPublication>()
        var newMapping: [UUID: String] = [:]

        for library in libraries {
            let pubs = (library.publications ?? [])
                .filter { !$0.isDeleted }
            allPublications.formUnion(pubs)

            // Track which library each publication came from (first library wins for duplicates)
            for pub in pubs {
                if newMapping[pub.id] == nil {
                    newMapping[pub.id] = library.displayName
                }
            }
        }

        // For "All Libraries" and "Everything", also include SciX library publications
        if scope == .allLibraries || scope == .everything {
            let (scixPublications, scixMapping) = fetchSciXLibraryPublicationsWithMapping()
            allPublications.formUnion(scixPublications)
            // Merge SciX mapping (don't overwrite existing entries)
            for (id, name) in scixMapping where newMapping[id] == nil {
                newMapping[id] = name
            }
        }

        // Update the library name mapping state
        libraryNameMapping = newMapping

        return Array(allPublications).sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Fetch all publications from SciX (NASA ADS) online libraries with name mapping.
    private func fetchSciXLibraryPublicationsWithMapping() -> ([CDPublication], [UUID: String]) {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDSciXLibrary>(entityName: "SciXLibrary")

        do {
            let scixLibraries = try context.fetch(request)
            var publications = Set<CDPublication>()
            var mapping: [UUID: String] = [:]

            for library in scixLibraries {
                let pubs = (library.publications ?? [])
                    .filter { !$0.isDeleted }
                publications.formUnion(pubs)

                // Track which SciX library each publication came from
                let libraryName = "SciX: \(library.name)"
                for pub in pubs {
                    if mapping[pub.id] == nil {
                        mapping[pub.id] = libraryName
                    }
                }
            }

            return (Array(publications), mapping)
        } catch {
            logger.error("Failed to fetch SciX libraries: \(error.localizedDescription)")
            return ([], [:])
        }
    }

    /// Fetch all publications from SciX (NASA ADS) online libraries (legacy, without mapping).
    private func fetchSciXLibraryPublications() -> [CDPublication] {
        let (publications, _) = fetchSciXLibraryPublicationsWithMapping()
        return publications
    }

    /// Refresh from network (async operation with loading state)
    private func refreshFromNetwork() async {
        guard isSourceValid else {
            isLoading = false
            return
        }

        // Reset snapshot on explicit refresh (Apple Mail behavior)
        unreadFilterSnapshot = nil

        isLoading = true
        error = nil

        switch source {
        case .library(let library):
            // TODO: Future enrichment protocol
            // For now, just refresh the list
            logger.info("Library refresh requested for: \(library.displayName)")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList()
            }

        case .smartSearch(let smartSearch):
            logger.info("Smart search refresh requested for: \(smartSearch.name)")

            // Route group feeds to GroupFeedRefreshService for staggered per-author searches
            if smartSearch.isGroupFeed {
                logger.info("Routing group feed '\(smartSearch.name)' to GroupFeedRefreshService")
                do {
                    _ = try await GroupFeedRefreshService.shared.refreshGroupFeed(smartSearch)
                    await MainActor.run {
                        refreshPublicationsList()
                    }
                    logger.info("Group feed refresh completed for '\(smartSearch.name)'")
                } catch {
                    logger.error("Group feed refresh failed: \(error.localizedDescription)")
                    self.error = error
                }
            } else {
                // Regular smart search - use provider
                let cachedProvider = await SmartSearchProviderCache.shared.getOrCreate(
                    for: smartSearch,
                    sourceManager: searchViewModel.sourceManager,
                    repository: libraryViewModel.repository
                )
                provider = cachedProvider

                do {
                    try await cachedProvider.refresh()
                    await MainActor.run {
                        SmartSearchRepository.shared.markExecuted(smartSearch)
                        refreshPublicationsList()
                    }
                    logger.info("Smart search refresh completed")
                } catch {
                    logger.error("Smart search refresh failed: \(error.localizedDescription)")
                    self.error = error
                }
            }

        case .lastSearch:
            // For last search, refresh just re-reads the collection
            // The actual search is triggered from the search form
            logger.info("Last search refresh requested")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList()
            }

        case .collection(let collection):
            // For collections, refresh just re-reads the collection
            logger.info("Collection refresh requested for: \(collection.name)")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList()
            }

        case .flagged:
            // For flagged, refresh just re-reads from Core Data
            logger.info("Flagged refresh requested")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList()
            }
        }

        isLoading = false
    }

    /// Queue a background refresh for the smart search if needed (stale or empty).
    ///
    /// This does NOT block the UI - cached results are shown immediately while
    /// the refresh happens in the background via SmartSearchRefreshService.
    private func queueBackgroundRefreshIfNeeded(_ smartSearch: CDSmartSearch) async {
        // Guard against deleted smart search
        guard smartSearch.managedObjectContext != nil, !smartSearch.isDeleted else { return }

        // Get provider to check staleness
        let cachedProvider = await SmartSearchProviderCache.shared.getOrCreate(
            for: smartSearch,
            sourceManager: searchViewModel.sourceManager,
            repository: libraryViewModel.repository
        )
        provider = cachedProvider

        // Check if refresh is needed (stale or empty)
        let isStale = await cachedProvider.isStale
        let isEmpty = publications.isEmpty

        if isStale || isEmpty {
            logger.info("Smart search '\(smartSearch.name)' needs refresh (stale: \(isStale), empty: \(isEmpty))")

            // Check if already being refreshed
            let alreadyRefreshing = await SmartSearchRefreshService.shared.isRefreshing(smartSearch.id)
            let alreadyQueued = await SmartSearchRefreshService.shared.isQueued(smartSearch.id)

            if alreadyRefreshing || alreadyQueued {
                logger.debug("Smart search '\(smartSearch.name)' already refreshing/queued")
                isBackgroundRefreshing = alreadyRefreshing
            } else {
                // Queue with high priority since it's the currently visible smart search
                isBackgroundRefreshing = true
                await SmartSearchRefreshService.shared.queueRefresh(smartSearch, priority: .high)
                logger.info("Queued high-priority background refresh for '\(smartSearch.name)'")
            }
        } else {
            logger.debug("Smart search '\(smartSearch.name)' is fresh, no refresh needed")
        }
    }

    // MARK: - Notification Handlers

    private func selectAllPublications() {
        selectedPublicationIDs = Set(publications.map { $0.id })
    }

    private func toggleReadStatusForSelected() {
        guard !selectedPublicationIDs.isEmpty else { return }

        Task {
            // Apple Mail behavior: if ANY are unread, mark ALL as read
            // If ALL are read, mark ALL as unread
            await libraryViewModel.smartToggleReadStatus(selectedPublicationIDs)
            refreshPublicationsList()
        }
    }

    private func copySelectedPublications() async {
        guard !selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.copyToClipboard(selectedPublicationIDs)
    }

    private func cutSelectedPublications() async {
        guard !selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.cutToClipboard(selectedPublicationIDs)
        refreshPublicationsList()
    }

    // MARK: - Inbox Triage Handlers

    /// Handle 'S' key - save selected to default library
    private func handleSaveKey() -> KeyPress.Result {
        guard !TextFieldFocusDetection.isTextFieldFocused(), isInboxView, !selectedPublicationIDs.isEmpty else { return .ignored }
        saveSelectedToDefaultLibrary()
        return .handled
    }

    /// Handle 'D' key - dismiss selected publications
    /// For exploration collections: removes from collection only (doesn't dismiss to Dismissed library)
    /// For inbox/other views: moves to Dismissed library
    private func handleDismissKey() -> KeyPress.Result {
        guard !TextFieldFocusDetection.isTextFieldFocused(), !selectedPublicationIDs.isEmpty else { return .ignored }

        if isExplorationCollection {
            // Exploration collection: just remove from collection, don't move to Dismissed
            removeSelectedFromExploration()
        } else {
            // Regular behavior: move to Dismissed library
            dismissSelectedFromInbox()
        }
        return .handled
    }

    /// Handle vim-style navigation keys (j/k for paper nav, h/l for pane cycling, i/p/n/b for tabs) and inbox triage keys (s/S/t)
    private func handleVimNavigation(_ press: KeyPress) -> KeyPress.Result {
        guard !TextFieldFocusDetection.isTextFieldFocused() else { return .ignored }

        // ESC: clear active filter if present
        if press.key == .escape, activeFilter != nil, !isFilterActive {
            clearFilter()
            return .handled
        }

        let store = KeyboardShortcutsStore.shared

        // j/k for paper navigation in list
        if store.matches(press, action: "navigateDown") {
            NotificationCenter.default.post(name: .navigateNextPaper, object: nil)
            return .handled
        }

        if store.matches(press, action: "navigateUp") {
            NotificationCenter.default.post(name: .navigatePreviousPaper, object: nil)
            return .handled
        }

        // h/l pane cycling (post notification for ContentView to handle)
        if store.matches(press, action: "cycleFocusLeft") {
            NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
            return .handled
        }

        if store.matches(press, action: "cycleFocusRight") {
            NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
            return .handled
        }

        // Single-key tab shortcuts (i/p/n/b)
        if store.matches(press, action: "showInfoTabVim") {
            NotificationCenter.default.post(name: .showInfoTab, object: nil)
            return .handled
        }

        if store.matches(press, action: "showPDFTabVim") {
            NotificationCenter.default.post(name: .showPDFTab, object: nil)
            return .handled
        }

        if store.matches(press, action: "showNotesTabVim") {
            NotificationCenter.default.post(name: .showNotesTab, object: nil)
            return .handled
        }

        if store.matches(press, action: "showBibTeXTabVim") {
            NotificationCenter.default.post(name: .showBibTeXTab, object: nil)
            return .handled
        }

        // Option+J: Next unread (Vim)
        if store.matches(press, action: "navigateNextUnreadVim") {
            NotificationCenter.default.post(name: .navigateNextUnread, object: nil)
            return .handled
        }

        // Option+K: Previous unread (Vim)
        if store.matches(press, action: "navigatePreviousUnreadVim") {
            NotificationCenter.default.post(name: .navigatePreviousUnread, object: nil)
            return .handled
        }

        // S key: Save to Save library (works anywhere for paper discovery)
        // For exploration collections: also removes from collection after saving
        if store.matches(press, action: "inboxSave") {
            if !selectedPublicationIDs.isEmpty {
                if isExplorationCollection {
                    saveSelectedAndRemoveFromExploration()
                } else {
                    saveSelectedToDefaultLibrary()
                }
                return .handled
            }
        }

        // Shift+S: Save and Star (works anywhere for paper discovery)
        if store.matches(press, action: "inboxSaveAndStar") {
            if !selectedPublicationIDs.isEmpty {
                saveAndStarSelected()
                return .handled
            }
        }

        // Flag mode (f): enter flag input for selected publications
        if store.matches(press, action: "flagMode") {
            let result = handleFlagKey()
            if result == .handled { return .handled }
        }

        // Tag mode (t): enter tag input for selected publications
        if store.matches(press, action: "tagMode") {
            let result = handleTagKey()
            if result == .handled { return .handled }
        }

        // Tag delete mode (T): enter tag removal for selected publications
        if store.matches(press, action: "tagDeleteMode") {
            let result = handleTagDeleteKey()
            if result == .handled { return .handled }
        }

        // Filter mode (/): enter local filter syntax
        if store.matches(press, action: "filterMode") {
            let result = handleFilterKey()
            if result == .handled { return .handled }
        }

        // Toggle star (*): works anywhere; in inbox also saves to library
        if store.matches(press, action: "inboxToggleStar") {
            if !selectedPublicationIDs.isEmpty {
                if isInboxView {
                    saveAndStarSelected()
                } else {
                    toggleStarForSelected()
                }
                return .handled
            }
        }

        // Shift+letter: Open tab in fullscreen/separate window
        // Check for shift modifier with uppercase letters
        if press.modifiers.contains(.shift) {
            switch press.characters.uppercased() {
            case "P":
                NotificationCenter.default.post(name: .detachPDFTab, object: nil)
                return .handled
            case "I":
                NotificationCenter.default.post(name: .detachInfoTab, object: nil)
                return .handled
            case "N":
                NotificationCenter.default.post(name: .detachNotesTab, object: nil)
                return .handled
            case "B":
                NotificationCenter.default.post(name: .detachBibTeXTab, object: nil)
                return .handled
            case "F":
                NotificationCenter.default.post(name: .flipWindowPositions, object: nil)
                return .handled
            default:
                break
            }
        }

        return .ignored
    }

    /// Save selected publications to the Save library (created on first use if needed)
    private func saveSelectedToDefaultLibrary() {
        // Use the Save library (created automatically on first use)
        let saveLibrary = libraryManager.getOrCreateSaveLibrary()

        let ids = selectedPublicationIDs
        guard let firstID = ids.first else { return }

        // Show green flash for save action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .green)
        }

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }
            }
            await saveToLibrary(ids: ids, targetLibrary: saveLibrary)
        }
    }

    /// Save and star selected publications to the Save library
    private func saveAndStarSelected() {
        // Use the Save library (created automatically on first use)
        let saveLibrary = libraryManager.getOrCreateSaveLibrary()

        let ids = selectedPublicationIDs
        guard let firstID = ids.first else { return }

        // Show gold flash for save+star action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .yellow)
        }

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Star the selected publications
                for id in ids {
                    if let pub = publications.first(where: { $0.id == id }) {
                        pub.isStarred = true
                    }
                }
                PersistenceController.shared.save()
            }
            await saveToLibrary(ids: ids, targetLibrary: saveLibrary)
        }
    }

    /// Toggle star for selected publications
    private func toggleStarForSelected() {
        let ids = selectedPublicationIDs
        guard !ids.isEmpty else { return }

        // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
        let anyUnstarred = publications.filter { ids.contains($0.id) }.contains { !$0.isStarred }
        let newStarred = anyUnstarred

        for id in ids {
            if let pub = publications.first(where: { $0.id == id }) {
                pub.isStarred = newStarred
            }
        }
        PersistenceController.shared.save()
        refreshPublicationsList()
    }

    /// Toggle star for a single publication
    private func toggleStar(for publication: CDPublication) async {
        publication.isStarred = !publication.isStarred
        PersistenceController.shared.save()
        refreshPublicationsList()
    }

    /// Toggle star for publications by IDs (used by PublicationListView callback)
    private func toggleStarForIDs(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
        let anyUnstarred = publications.filter { ids.contains($0.id) }.contains { !$0.isStarred }
        let newStarred = anyUnstarred

        for id in ids {
            if let pub = publications.first(where: { $0.id == id }) {
                pub.isStarred = newStarred
            }
        }
        PersistenceController.shared.save()
        refreshPublicationsList()
    }

    /// Set flag for publications by IDs
    private func setFlagForIDs(_ ids: Set<UUID>, color: FlagColor) async {
        guard !ids.isEmpty else { return }

        for id in ids {
            if let pub = publications.first(where: { $0.id == id }) {
                pub.flag = .simple(color)
            }
        }
        PersistenceController.shared.save()
        listDataVersion += 1
        NotificationCenter.default.post(name: .flagDidChange, object: nil)
        refreshPublicationsList()
    }

    /// Clear flag for publications by IDs
    private func clearFlagForIDs(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        for id in ids {
            if let pub = publications.first(where: { $0.id == id }) {
                pub.flag = nil
            }
        }
        PersistenceController.shared.save()
        listDataVersion += 1
        NotificationCenter.default.post(name: .flagDidChange, object: nil)
        refreshPublicationsList()
    }

    /// Handle adding a tag (triggers tag input mode for the given publication IDs)
    private func handleAddTag(_ ids: Set<UUID>) {
        // Tag input is handled via keyboard mode (t key) in the wrapper;
        // context menu "Add Tag..." opens it for the specified publications.
        tagTargetIDs = ids
        isTagInputActive = true
    }

    /// Handle removing a tag from a publication
    private func handleRemoveTag(pubID: UUID, tagID: UUID) {
        guard let pub = publications.first(where: { $0.id == pubID }) else { return }
        Task {
            await libraryViewModel.repository.removeTag(tagID, from: pub)
            listDataVersion += 1
            refreshPublicationsList()
        }
    }

    // MARK: - Focus Restoration

    /// Restore focus to the publication list after an input overlay dismisses.
    /// Uses a short delay to allow SwiftUI to finish removing the overlay's focused TextField.
    private func restoreListFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isListFocused = true
        }
    }

    // MARK: - Filter Keyboard Handlers

    /// Handle `/` key: enter filter mode
    private func handleFilterKey() -> KeyPress.Result {
        guard !isFlagInputActive && !isTagInputActive && !isTagDeleteActive && !isFilterActive else {
            return .ignored
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            isFilterActive = true
        }
        return .handled
    }

    /// Apply filter text to the publication list (called live as user types)
    private func applyFilterText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            activeFilter = nil
        } else {
            activeFilter = LocalFilterService.shared.parse(trimmed)
        }
        refreshPublicationsList()
    }

    /// Clear the active filter and reset filter text
    private func clearFilter() {
        filterText = ""
        activeFilter = nil
        refreshPublicationsList()
    }

    // MARK: - Flag Keyboard Handlers

    /// Handle `f` key: enter flag input mode for selected publications
    private func handleFlagKey() -> KeyPress.Result {
        guard !selectedPublicationIDs.isEmpty else { return .ignored }
        guard !isFlagInputActive && !isTagInputActive && !isTagDeleteActive && !isFilterActive else { return .ignored }

        flagTargetIDs = selectedPublicationIDs

        withAnimation(.easeInOut(duration: 0.15)) {
            isFlagInputActive = true
        }
        return .handled
    }

    /// Commit a flag to the target publications
    private func commitFlag(_ flag: PublicationFlag) {
        let ids = flagTargetIDs
        guard let firstID = ids.first else { return }

        // Show triage flash with the flag's color
        let flashColor: Color = switch flag.color {
        case .red: .red
        case .amber: .orange
        case .blue: .blue
        case .gray: .gray
        }

        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, flashColor)
        }

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                for id in ids {
                    if let pub = publications.first(where: { $0.id == id }) {
                        pub.flag = flag
                    }
                }
                PersistenceController.shared.save()
                listDataVersion += 1
                NotificationCenter.default.post(name: .flagDidChange, object: nil)
                flagTargetIDs = []
                refreshPublicationsList()
            }
        }
    }

    // MARK: - Tag Keyboard Handlers

    /// Handle `t` key: enter tag input mode for selected publications
    private func handleTagKey() -> KeyPress.Result {
        guard !selectedPublicationIDs.isEmpty else { return .ignored }
        guard !isFlagInputActive && !isTagInputActive && !isTagDeleteActive && !isFilterActive else { return .ignored }

        tagTargetIDs = selectedPublicationIDs
        tagCompletions = []

        // Lazily initialize autocomplete service
        if tagAutocomplete == nil {
            tagAutocomplete = TagAutocompleteService(persistenceController: PersistenceController.shared)
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            isTagInputActive = true
        }
        return .handled
    }

    /// Handle `T` key: enter tag delete mode for selected publication
    private func handleTagDeleteKey() -> KeyPress.Result {
        guard !selectedPublicationIDs.isEmpty else { return .ignored }
        guard !isFlagInputActive && !isTagInputActive && !isTagDeleteActive && !isFilterActive else { return .ignored }

        withAnimation(.easeInOut(duration: 0.15)) {
            isTagDeleteActive = true
        }
        return .handled
    }

    /// Commit a tag path to the target publications
    private func commitTag(path: String) {
        // Capture @State values BEFORE entering the async Task.
        // TagInput dismisses (clearing tagTargetIDs) before the Task body starts,
        // so reading @State inside the Task would see empty IDs.
        let targetIDs = tagTargetIDs
        let pubs = publications

        logInfo("commitTag: captured \(targetIDs.count) targets, resolving '\(path)'", category: "tags")

        Task {
            let resolvedPath = TagAliasStore.shared.resolve(path) ?? path
            let repo = libraryViewModel.repository

            let tag = await repo.findOrCreateTagByPath(resolvedPath)

            logInfo("commitTag: tag '\(tag.canonicalPath ?? tag.name)' id=\(tag.id), applying to \(targetIDs.count) pubs", category: "tags")

            var applied = 0
            var missed = 0
            for id in targetIDs {
                if let pub = pubs.first(where: { $0.id == id }) {
                    await repo.addTag(tag, to: pub)
                    applied += 1

                    let tagCount = pub.tags?.count ?? 0
                    logInfo("commitTag: after addTag, '\(pub.citeKey)' has \(tagCount) tags", category: "tags")
                } else {
                    logWarning("commitTag: publication \(id) not found in publications array", category: "tags")
                    missed += 1
                }
            }

            logInfo("commitTag: done — applied=\(applied), missed=\(missed)", category: "tags")

            tagAutocomplete?.invalidate()
            tagTargetIDs = []
            listDataVersion += 1
            refreshPublicationsList()
        }
    }

    /// Update tag completions as the user types
    private func updateTagCompletions(_ text: String) {
        guard let autocomplete = tagAutocomplete else { return }
        tagCompletions = autocomplete.complete(text)
    }

    /// Compute the visual order of publications synchronously.
    ///
    /// This is the single source of truth for list order during triage operations.
    /// Called synchronously before triage to ensure selection advancement uses the correct order.
    ///
    /// - Returns: Publications sorted according to current sort order and filters
    private func computeVisualOrder() -> [CDPublication] {
        // Filter valid publications
        var result = publications.filter { pub in
            !pub.isDeleted
        }

        // Apply current sort order with stable tie-breaker (dateAdded then id)
        let sorted = result.sorted { lhs, rhs in
            // For recommendation sort, handle tie-breaking specially
            if currentSortOrder == .recommended {
                let lhsScore = recommendationScores[lhs.id] ?? 0
                let rhsScore = recommendationScores[rhs.id] ?? 0
                if lhsScore != rhsScore {
                    let result = lhsScore > rhsScore
                    return currentSortAscending == currentSortOrder.defaultAscending ? result : !result
                }
                // Tie-breaker: dateAdded descending (newest first)
                if lhs.dateAdded != rhs.dateAdded {
                    let result = lhs.dateAdded > rhs.dateAdded
                    return currentSortAscending == currentSortOrder.defaultAscending ? result : !result
                }
                // Final tie-breaker: id for absolute stability
                return lhs.id.uuidString < rhs.id.uuidString
            }

            let defaultComparison: Bool = switch currentSortOrder {
            case .dateAdded:
                lhs.dateAdded > rhs.dateAdded  // Default descending (newest first)
            case .dateModified:
                lhs.dateModified > rhs.dateModified  // Default descending (newest first)
            case .title:
                (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending  // Default ascending (A-Z)
            case .year:
                (lhs.year ?? 0) > (rhs.year ?? 0)  // Default descending (newest first)
            case .citeKey:
                lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey) == .orderedAscending  // Default ascending (A-Z)
            case .citationCount:
                (lhs.citationCount ?? 0) > (rhs.citationCount ?? 0)  // Default descending (highest first)
            case .starred:
                // Starred first, then by dateAdded as tie-breaker
                if lhs.isStarred != rhs.isStarred {
                    lhs.isStarred  // Starred papers first (true > false)
                } else {
                    lhs.dateAdded > rhs.dateAdded  // Tie-breaker: newest first
                }
            case .recommended:
                true  // Handled above, this won't be reached
            }
            // Flip result if sortAscending differs from the field's default direction
            return currentSortAscending == currentSortOrder.defaultAscending ? defaultComparison : !defaultComparison
        }

        return sorted
    }

    /// Dismiss selected publications from inbox (moves to Dismissed library, not delete)
    /// Advances selection to next paper for rapid triage.
    private func dismissSelectedFromInbox() {
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()
        guard let firstID = selectedPublicationIDs.first else { return }

        // Show orange flash for dismiss action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .orange)
        }

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()
        let currentIDs = selectedPublicationIDs
        let currentSelection = selectedPublication

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Use computed visual order for proper selection advancement
                let result = InboxTriageService.shared.dismissFromInbox(
                    ids: currentIDs,
                    from: visualOrder,
                    currentSelection: currentSelection,
                    dismissedLibrary: dismissedLibrary,
                    source: triageSource
                )

                // Advance to next selection for rapid triage
                if let nextID = result.nextSelectionID {
                    selectedPublicationIDs = [nextID]
                    selectedPublication = result.nextPublication
                } else {
                    // No more papers - clear selection
                    selectedPublicationIDs.removeAll()
                    selectedPublication = nil
                }

                refreshPublicationsList()
            }
        }
    }

    // MARK: - Exploration Collection Triage

    /// Save selected publications to Save library AND remove from exploration collection.
    /// Used for exploration collections where S key should both save and remove.
    private func saveSelectedAndRemoveFromExploration() {
        guard case .collection(let collection) = source else { return }
        let saveLibrary = libraryManager.getOrCreateSaveLibrary()
        let ids = selectedPublicationIDs
        guard let firstID = ids.first else { return }

        // Show green flash for save action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .green)
        }

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Add to Save library and remove from exploration collection
                let pubs = publications.filter { ids.contains($0.id) }
                for pub in pubs {
                    pub.addToLibrary(saveLibrary)
                    pub.removeFromCollection(collection)
                }
                PersistenceController.shared.save()

                // Compute next selection
                let nextID = computeNextSelection(removing: ids, from: visualOrder)
                if let nextID {
                    selectedPublicationIDs = [nextID]
                    selectedPublication = publications.first { $0.id == nextID }
                } else {
                    selectedPublicationIDs.removeAll()
                    selectedPublication = nil
                }

                refreshPublicationsList()
            }
        }
    }

    /// Remove selected publications from exploration collection (without dismissing to Dismissed library).
    /// Used for D key in exploration collections.
    private func removeSelectedFromExploration() {
        guard case .collection(let collection) = source else { return }
        let ids = selectedPublicationIDs
        guard let firstID = ids.first else { return }

        // Show orange flash for dismiss action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .orange)
        }

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Remove from exploration collection (don't move to Dismissed library)
                let pubs = publications.filter { ids.contains($0.id) }
                for pub in pubs {
                    pub.removeFromCollection(collection)
                }
                PersistenceController.shared.save()

                // Compute next selection
                let nextID = computeNextSelection(removing: ids, from: visualOrder)
                if let nextID {
                    selectedPublicationIDs = [nextID]
                    selectedPublication = publications.first { $0.id == nextID }
                } else {
                    selectedPublicationIDs.removeAll()
                    selectedPublication = nil
                }

                refreshPublicationsList()
            }
        }
    }

    /// Compute the next selection ID after removing the given IDs from the visual order.
    private func computeNextSelection(removing ids: Set<UUID>, from visualOrder: [CDPublication]) -> UUID? {
        // Find the current position of the first selected item
        guard let firstSelectedID = ids.first,
              let currentIndex = visualOrder.firstIndex(where: { $0.id == firstSelectedID }) else {
            return nil
        }

        // Find the next item that isn't being removed
        for i in (currentIndex + 1)..<visualOrder.count {
            if !ids.contains(visualOrder[i].id) {
                return visualOrder[i].id
            }
        }

        // If no next item, try previous
        for i in (0..<currentIndex).reversed() {
            if !ids.contains(visualOrder[i].id) {
                return visualOrder[i].id
            }
        }

        return nil
    }

    // MARK: - Save Implementation

    /// Save publications to a target library (adds to target AND removes from current).
    /// Advances selection to next paper for rapid triage.
    private func saveToLibrary(ids: Set<UUID>, targetLibrary: CDLibrary) async {
        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        // Use computed visual order for proper selection advancement
        let result = InboxTriageService.shared.saveToLibrary(
            ids: ids,
            from: visualOrder,
            currentSelection: selectedPublication,
            targetLibrary: targetLibrary,
            source: triageSource
        )

        // Advance to next selection for rapid triage
        if let nextID = result.nextSelectionID {
            selectedPublicationIDs = [nextID]
            selectedPublication = result.nextPublication
        } else {
            // No more papers - clear selection
            selectedPublicationIDs.removeAll()
            selectedPublication = nil
        }

        refreshPublicationsList()
    }

    /// Convert current source to TriageSource for InboxTriageService.
    private var triageSource: TriageSource {
        switch source {
        case .library(let lib):
            return lib.isInbox ? .inboxLibrary : .regularLibrary(lib)
        case .smartSearch(let ss) where ss.feedsToInbox:
            return .inboxFeed(ss)
        case .smartSearch(let ss):
            if let lib = ss.library {
                return .regularLibrary(lib)
            }
            return .inboxLibrary
        case .lastSearch(let collection):
            // Last search results belong to a regular library
            if let lib = collection.library ?? collection.owningLibrary {
                return .regularLibrary(lib)
            }
            return .inboxLibrary
        case .collection(let collection):
            // Collections belong to a regular library
            if let lib = collection.effectiveLibrary {
                return .regularLibrary(lib)
            }
            return .inboxLibrary
        case .flagged:
            // Flagged is a cross-library virtual source; use active library for triage
            if let lib = libraryManager.activeLibrary {
                return .regularLibrary(lib)
            }
            return .inboxLibrary
        }
    }

    // MARK: - Inbox Triage Callback Implementations

    /// Dismiss publications from inbox (for context menu) - moves to Dismissed library, not delete
    private func dismissFromInbox(ids: Set<UUID>) async {
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        let result = InboxTriageService.shared.dismissFromInbox(
            ids: ids,
            from: visualOrder,
            currentSelection: selectedPublication,
            dismissedLibrary: dismissedLibrary,
            source: triageSource
        )

        // Advance to next selection for rapid triage
        if let nextID = result.nextSelectionID {
            selectedPublicationIDs = [nextID]
            selectedPublication = result.nextPublication
        } else {
            selectedPublicationIDs.removeAll()
            selectedPublication = nil
        }

        refreshPublicationsList()
    }

    /// Mute an author
    private func muteAuthor(_ authorName: String) {
        let inboxManager = InboxManager.shared
        inboxManager.mute(type: .author, value: authorName)
        logger.info("Muted author: \(authorName)")
    }

    /// Mute a paper (by DOI or bibcode)
    private func mutePaper(_ publication: CDPublication) {
        let inboxManager = InboxManager.shared

        // Prefer DOI, then bibcode (from original source ID for ADS papers)
        if let doi = publication.doi, !doi.isEmpty {
            inboxManager.mute(type: .doi, value: doi)
            logger.info("Muted paper by DOI: \(doi)")
        } else if let bibcode = publication.originalSourceID {
            // For ADS papers, originalSourceID contains the bibcode
            inboxManager.mute(type: .bibcode, value: bibcode)
            logger.info("Muted paper by bibcode: \(bibcode)")
        } else {
            logger.warning("Cannot mute paper - no DOI or bibcode available")
        }
    }

    // MARK: - Helpers

    private func openPDF(for publication: CDPublication) {
        // Check user preference for opening PDFs
        let openExternally = UserDefaults.standard.bool(forKey: "openPDFInExternalViewer")

        if openExternally {
            // Open in external viewer (Preview, Adobe, etc.)
            if let linkedFiles = publication.linkedFiles,
               let pdfFile = linkedFiles.first(where: { $0.isPDF }),
               let libraryURL = currentLibrary?.folderURL {
                let pdfURL = libraryURL.appendingPathComponent(pdfFile.relativePath)
                #if os(macOS)
                NSWorkspace.shared.open(pdfURL)
                #endif
            }
        } else {
            // Show in built-in PDF tab
            // First ensure the publication is selected, then switch to PDF tab
            libraryViewModel.selectedPublications = [publication.id]
            NotificationCenter.default.post(name: .showPDFTab, object: nil)
        }
    }

    /// Capture current unread publication IDs for Apple Mail-style snapshot.
    /// Items in the snapshot stay visible even after being marked as read.
    private func captureUnreadSnapshot() -> Set<UUID> {
        guard isSourceValid else { return [] }
        switch source {
        case .library(let library):
            let unread = (library.publications ?? [])
                .filter { !$0.isDeleted && !$0.isRead }
            return Set(unread.map { $0.id })
        case .smartSearch(let smartSearch):
            guard let collection = smartSearch.resultCollection else { return [] }
            let unread = (collection.publications ?? [])
                .filter { !$0.isDeleted && !$0.isRead }
            return Set(unread.map { $0.id })
        case .lastSearch(let collection):
            let unread = (collection.publications ?? [])
                .filter { !$0.isDeleted && !$0.isRead }
            return Set(unread.map { $0.id })
        case .collection(let collection):
            let unread = (collection.publications ?? [])
                .filter { !$0.isDeleted && !$0.isRead }
            return Set(unread.map { $0.id })
        case .flagged:
            // For flagged view, use current publications list for snapshot
            return Set(publications.filter { !$0.isRead }.map { $0.id })
        }
    }
}

// MARK: - View Modifiers (extracted to help compiler type-checking)

/// Handles notification subscriptions for clipboard and selection operations
private struct NotificationModifiers: ViewModifier {
    let onToggleReadStatus: () -> Void
    let onCopyPublications: () -> Void
    let onCutPublications: () -> Void
    let onPastePublications: () -> Void
    let onSelectAll: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadStatus)) { _ in
                onToggleReadStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyPublications)) { _ in
                onCopyPublications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cutPublications)) { _ in
                onCutPublications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pastePublications)) { _ in
                onPastePublications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllPublications)) { _ in
                onSelectAll()
            }
    }
}

/// Handles smart search refresh completion notifications
private struct SmartSearchRefreshModifier: ViewModifier {
    let source: PublicationSource
    let onRefreshComplete: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .smartSearchRefreshCompleted)) { notification in
                if case .smartSearch(let smartSearch) = source,
                   let completedID = notification.object as? UUID,
                   completedID == smartSearch.id {
                    onRefreshComplete(smartSearch.name)
                }
            }
    }
}

/// Handles inbox triage notification subscriptions
private struct InboxTriageModifier: ViewModifier {
    let isInboxView: Bool
    let hasSelection: Bool
    let onSave: () -> Void
    let onSaveAndStar: () -> Void
    let onToggleStar: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .inboxSave)) { _ in
                // Save works anywhere (paper discovery in search results, smart searches, etc.)
                if hasSelection {
                    onSave()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxSaveAndStar)) { _ in
                // Save and star works anywhere
                if hasSelection {
                    onSaveAndStar()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxToggleStar)) { _ in
                if hasSelection {
                    onToggleStar()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxDismiss)) { _ in
                // Dismiss only works in inbox view (moves to dismissed library)
                if isInboxView && hasSelection {
                    onDismiss()
                }
            }
    }
}

// MARK: - Preview

#Preview {
    let libraryManager = LibraryManager(persistenceController: .preview)
    if let library = libraryManager.libraries.first {
        NavigationStack {
            UnifiedPublicationListWrapper(
                source: .library(library),
                selectedPublication: .constant(nil),
                selectedPublicationIDs: .constant([])
            )
        }
        .environment(LibraryViewModel())
        .environment(SearchViewModel(
            sourceManager: SourceManager(),
            deduplicationService: DeduplicationService(),
            repository: PublicationRepository()
        ))
        .environment(libraryManager)
    } else {
        Text("No library available in preview")
    }
}
