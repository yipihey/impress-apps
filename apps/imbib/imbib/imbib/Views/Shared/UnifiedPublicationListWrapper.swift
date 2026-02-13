//
//  UnifiedPublicationListWrapper.swift
//  imbib
//
//  Created by Claude on 2026-01-05.
//

import SwiftUI
import PublicationManagerCore
import OSLog
import ImpressKeyboard
import ImpressFTUI

private let logger = Logger(subsystem: "com.imbib.app", category: "publicationlist")

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
    @Binding var selectedPublicationID: UUID?
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

    @State private var publications: [PublicationRowData] = []
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

    /// Cached library list — avoids recreating a non-Equatable tuple array
    /// on every body evaluation, which would force PublicationListView to re-evaluate.
    @State private var cachedAllLibraries: [(id: UUID, name: String)] = []

    /// Version-based deduplication: tracks the last store version we refreshed at.
    /// Prevents double refreshes when both an explicit call and `.onReceive(.storeDidMutate)`
    /// fire for the same mutation.
    @State private var lastRefreshedStoreVersion: Int = -1

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
    @State private var ftsFilterResults: Set<UUID>?  // nil = no FTS filter active

    /// Focus state for keyboard navigation - list needs focus to receive key events
    @FocusState private var isListFocused: Bool

    // MARK: - Computed Properties

    /// Check if the source (library or smart search) is still valid (not deleted)
    private var isSourceValid: Bool {
        // Domain sources use value-type UUIDs — always valid
        true
    }

    private var navigationTitle: String {
        let store = RustStoreAdapter.shared
        switch source {
        case .library(let id):
            return filterMode == .unread ? "Unread" : (store.getLibrary(id: id)?.name ?? "")
        case .smartSearch(let id):
            return store.getSmartSearch(id: id)?.name ?? ""
        case .collection(let id):
            // TODO: implement collection name lookup via Rust store
            // For now use listCollections and find matching
            return "Collection"
        case .flagged(let color):
            if let color { return "\(color.capitalized) Flagged" }
            return "Flagged"
        case .scixLibrary(let id):
            return store.getScixLibrary(id: id)?.name ?? "SciX Library"
        case .unread:
            return "Unread"
        case .starred:
            return "Starred"
        case .tag(let path):
            return path.components(separatedBy: "/").last ?? path
        case .inbox(let id):
            return store.getLibrary(id: id)?.name ?? "Inbox"
        case .dismissed:
            return "Dismissed"
        }
    }

    private var currentLibraryID: UUID? {
        switch source {
        case .library(let id): return id
        case .inbox(let id): return id
        case .scixLibrary(let id): return id
        case .smartSearch(let id):
            return RustStoreAdapter.shared.getSmartSearch(id: id)?.libraryID
                ?? RustStoreAdapter.shared.getDefaultLibrary()?.id
        case .collection, .flagged, .unread, .starred, .tag, .dismissed:
            return RustStoreAdapter.shared.getDefaultLibrary()?.id
        }
    }

    private var listID: ListViewID {
        switch source {
        case .library(let id):
            return .library(id)
        case .smartSearch(let id):
            return .smartSearch(id)
        case .collection(let id):
            return .collection(id)
        case .flagged:
            return .flagged(source.viewID)
        case .scixLibrary(let id):
            return .scixLibrary(id)
        case .unread:
            return .library(source.viewID)
        case .starred:
            return .library(source.viewID)
        case .tag:
            return .library(source.viewID)
        case .inbox(let id):
            return .library(id)
        case .dismissed:
            return .library(source.viewID)
        }
    }

    private var emptyMessage: String {
        switch source {
        case .library:
            return "No Publications"
        case .smartSearch(let id):
            let query = RustStoreAdapter.shared.getSmartSearch(id: id)?.query ?? ""
            return "No Results for \"\(query)\""
        case .collection:
            return "No Publications"
        case .flagged(let color):
            if let color { return "No \(color.capitalized) Flagged Papers" }
            return "No Flagged Papers"
        case .scixLibrary:
            return "No Papers"
        case .unread:
            return "No Unread Papers"
        case .starred:
            return "No Starred Papers"
        case .tag(let path):
            return "No Papers Tagged \"\(path)\""
        case .inbox:
            return "Inbox Empty"
        case .dismissed:
            return "No Dismissed Papers"
        }
    }

    private var emptyDescription: String {
        switch source {
        case .library:
            return "Add publications to your library or search online sources."
        case .smartSearch:
            return "Click refresh to search again."
        case .collection:
            return "Drag publications to this collection."
        case .flagged:
            return "Flag papers to see them here."
        case .scixLibrary:
            return "This SciX library is empty."
        case .unread:
            return "All papers have been read."
        case .starred:
            return "Star papers to see them here."
        case .tag:
            return "Tag papers to see them here."
        case .inbox:
            return "No new papers in your inbox."
        case .dismissed:
            return "No dismissed papers."
        }
    }

    // MARK: - Body

    /// Check if we're viewing the Inbox library or an Inbox feed
    private var isInboxView: Bool {
        switch source {
        case .inbox:
            return true
        case .smartSearch(let id):
            return RustStoreAdapter.shared.getSmartSearch(id: id)?.feedsToInbox ?? false
        case .library, .collection, .flagged, .scixLibrary, .unread, .starred, .tag, .dismissed:
            return false
        }
    }

    /// Check if we're viewing an exploration collection (in the system Exploration library).
    /// Exploration collections have special triage behavior:
    /// - S key: Save to Save library AND remove from exploration collection
    /// - D key: Remove from collection only (NOT move to Dismissed library)
    private var isExplorationCollection: Bool {
        if case .collection = source { return false } // TODO: check system library via Rust store
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
            #if os(iOS)
            .navigationTitle(navigationTitle)
            #endif
            .toolbar { toolbarContent }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress { press in handleVimNavigation(press) }
            .onKeyPress(.init("d")) { handleDismissKey() }
            .task(id: source.viewID) {
                filterMode = initialFilterMode
                filterScope = .current  // Reset scope on navigation
                unreadFilterSnapshot = nil  // Reset snapshot on navigation

                // If starting with unread filter, capture snapshot after loading data
                if initialFilterMode == .unread {
                    refreshPublicationsList(force: true)
                    unreadFilterSnapshot = captureUnreadSnapshot()
                } else {
                    refreshPublicationsList(force: true)
                }

                if case .smartSearch(let ssID) = source {
                    await queueBackgroundRefreshIfNeeded(ssID)
                }

                // Auto-refresh SciX libraries that haven't been synced yet
                if case .scixLibrary(let id) = source {
                    let store = RustStoreAdapter.shared
                    if let scix = store.getScixLibrary(id: id) {
                        let needsRefresh = scix.syncState == "pending" || scix.lastSyncDate == nil
                        if needsRefresh, let remoteID = Optional(scix.remoteID), !remoteID.isEmpty {
                            logger.info("Auto-refreshing SciX library '\(scix.name)' (syncState=\(scix.syncState))")
                            isBackgroundRefreshing = true
                            do {
                                try await SciXSyncManager.shared.pullLibraryPapers(libraryID: remoteID)
                                await MainActor.run {
                                    isBackgroundRefreshing = false
                                    refreshPublicationsList(force: true)
                                }
                            } catch {
                                logger.error("SciX auto-refresh failed: \(error.localizedDescription)")
                                isBackgroundRefreshing = false
                            }
                        }
                    }
                }
            }
            // Belt-and-suspenders: .task(id:) can miss re-fires inside
            // AppKit-bridged containers (HSplitView/ZStack). Explicit
            // .onChange guarantees a refresh when the source changes.
            .onChange(of: source) { oldSource, newSource in
                filterMode = initialFilterMode
                filterScope = .current
                unreadFilterSnapshot = nil
                refreshPublicationsList(force: true)

                // Queue unenriched papers for background enrichment (one-shot per source switch)
                if let libraryID = currentLibraryID {
                    Task {
                        await EnrichmentCoordinator.shared.queueUnenrichedPublications(inLibrary: libraryID)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storeDidMutate)) { notification in
                // Only do a full list refresh for structural mutations (add/remove/move).
                // In-place mutations (read/star/flag/tag) are handled by row-level
                // notifications in PublicationListView via O(1) updateSingleRowData().
                let structural = notification.userInfo?["structural"] as? Bool ?? true
                if structural {
                    refreshPublicationsList()
                }
            }
            .onAppear {
                // Give the list focus so keyboard shortcuts work immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isListFocused = true
                }
            }
            .onChange(of: selectedPublicationIDs) { _, _ in
                // Re-request focus after selection changes. Clicking a row in the
                // List gives AppKit's NSTableView first responder, which steals
                // focus from our .focusable() wrapper and breaks .onKeyPress.
                // Toggle false→true to force SwiftUI to re-request focus.
                isListFocused = false
                DispatchQueue.main.async {
                    isListFocused = true
                }
            }
            .modifier(InputOverlayFocusModifier(
                isFlagInputActive: isFlagInputActive,
                isTagInputActive: isTagInputActive,
                isTagDeleteActive: isTagDeleteActive,
                isFilterActive: isFilterActive,
                onActivate: { isListFocused = false },
                onDeactivate: { restoreListFocus() }
            ))
            .onChange(of: filterMode) { _, newMode in
                // Capture snapshot when switching TO unread filter (Apple Mail behavior)
                if newMode == .unread {
                    unreadFilterSnapshot = captureUnreadSnapshot()
                } else {
                    unreadFilterSnapshot = nil
                }
                refreshPublicationsList(force: true)
            }
            .onChange(of: filterScope) { _, _ in
                refreshPublicationsList(force: true)
            }
            .modifier(NotificationModifiers(
                onToggleReadStatus: toggleReadStatusForSelected,
                onCopyPublications: { Task { await copySelectedPublications() } },
                onCutPublications: { Task { await cutSelectedPublications() } },
                onPastePublications: {
                    Task {
                        try? await libraryViewModel.pasteFromClipboard()
                    }
                },
                onSelectAll: selectAllPublications
            ))
            .modifier(SmartSearchRefreshModifier(
                source: source,
                onRefreshComplete: { smartSearchName in
                    logger.info("Background refresh completed for '\(smartSearchName)', refreshing UI")
                    isBackgroundRefreshing = false
                    refreshPublicationsList(force: true)
                }
            ))
            .onReceive(NotificationCenter.default.publisher(for: .lastSearchUpdated)) { _ in
                // Refresh list when Last Search collection is updated
                // TODO: implement with Rust store — lastSearch is no longer a separate case
                logger.info("Last search updated notification received, refreshing list")
                refreshPublicationsList(force: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .activateFilter)) { _ in
                _ = handleFilterKey()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfImportCompleted)) { notification in
                // Handle PDF import completion: select imported publications, scroll to them, and show PDF viewer
                guard let importedIDs = notification.object as? [UUID], !importedIDs.isEmpty else { return }

                logger.info("PDF import completed with \(importedIDs.count) publications")

                // Refresh list first to ensure imported publications are visible
                refreshPublicationsList(force: true)

                // Select the imported publications
                selectedPublicationIDs = Set(importedIDs)

                // Set the first imported publication as the selected publication for detail view
                if let firstID = importedIDs.first {
                    selectedPublicationID = firstID
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
                isInputOverlayActive: isFlagInputActive || isTagInputActive || isTagDeleteActive || isFilterActive,
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
                if newValue == nil && showingDropPreview {
                    // Dismiss the sheet when pendingPreview becomes nil (import completed or cancelled)
                    showingDropPreview = false
                } else if newValue != nil && !showingDropPreview {
                    // Show the sheet when pendingPreview is set externally (e.g. sidebar PDF drop)
                    if dropPreviewTargetLibraryID == nil {
                        dropPreviewTargetLibraryID = currentLibraryID
                    }
                    showingDropPreview = true
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
                refreshPublicationsList(force: true)
            }
        } else if let libraryID = currentLibraryID {
            // Fallback: use current library
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: libraryID,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                refreshPublicationsList(force: true)
            }
        } else {
            let libraries = RustStoreAdapter.shared.listLibraries()
            if let firstLibrary = libraries.first(where: { !$0.isInbox }) {
                // Fallback: use first user library
                DropPreviewSheet(
                    preview: $coordinator.pendingPreview,
                    libraryID: firstLibrary.id,
                    coordinator: dragDropCoordinator
                )
                .onDisappear {
                    refreshPublicationsList(force: true)
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
                    TagDeleteMode(
                        isPresented: $isTagDeleteActive,
                        tags: pub.tagDisplays,
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
        // TODO: implement canEdit check via Rust store (check library permissions)
        true
    }

    private var listView: some View {
        PublicationListView(
            publications: publications,
            selection: $selectedPublicationIDs,
            selectedPublicationID: $selectedPublicationID,
            libraryID: currentLibraryID,
            allLibraries: cachedAllLibraries,
            showImportButton: false,
            showSortMenu: true,
            emptyStateMessage: emptyMessage,
            emptyStateDescription: emptyDescription,
            listID: listID,
            disableUnreadFilter: isInboxView,
            isInInbox: isInboxView,
            saveLibraryID: isInboxView ? libraryManager.getOrCreateSaveLibrary().id : nil,
            filterScope: $filterScope,
            libraryNameMapping: libraryNameMapping,
            sortOrder: $currentSortOrder,
            sortAscending: $currentSortAscending,
            recommendationScores: $recommendationScores,
            onDelete: !sourceCanEdit ? nil : { ids in
                // Track dismissal for inbox papers before deleting
                if isInboxView {
                    for id in ids {
                        InboxManager.shared.trackDismissal(id)
                    }
                }
                // Remove from local state FIRST to prevent rendering deleted objects
                publications.removeAll { pub in
                    ids.contains(pub.id)
                }
                // Clear selection for deleted items
                selectedPublicationIDs.subtract(ids)
                // Then delete from Rust store
                RustStoreAdapter.shared.deletePublications(ids: Array(ids))
            },
            onToggleRead: { id in
                let store = RustStoreAdapter.shared
                let pub = store.getPublication(id: id)
                store.setRead(ids: [id], read: !(pub?.isRead ?? false))
            },
            onCopy: { ids in
                await libraryViewModel.copyToClipboard(ids)
            },
            onCut: !sourceCanEdit ? nil : { ids in
                await libraryViewModel.cutToClipboard(ids)
            },
            onPaste: !sourceCanEdit ? nil : {
                try? await libraryViewModel.pasteFromClipboard()
            },
            onAddToLibrary: { ids, targetLibraryID in
                _ = RustStoreAdapter.shared.duplicatePublications(ids: Array(ids), toLibraryId: targetLibraryID)
            },
            onAddToCollection: { ids, collectionID in
                RustStoreAdapter.shared.addToCollection(publicationIds: Array(ids), collectionId: collectionID)
            },
            onRemoveFromAllCollections: !sourceCanEdit ? nil : { ids in
                // TODO: implement removeFromAllCollections with Rust store
            },
            onImport: nil,
            onOpenPDF: { id in
                openPDF(for: id)
            },
            onFileDrop: !sourceCanEdit ? nil : { id, providers in
                // TODO: implement file drop with Rust store (FileDropHandler needs UUID-based API)
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
                                logger.info("Fallback - currentLibraryID: \(String(describing: currentLibraryID))")
                                // Use current library as fallback
                                dropPreviewTargetLibraryID = currentLibraryID
                            }
                            logger.info("Setting showingDropPreview = true")
                            showingDropPreview = true
                        }
                    }
                }
            },
            onDownloadPDFs: onDownloadPDFs,
            // Keep callback - only available in Inbox (implied once in library)
            onSaveToLibrary: isInboxView ? { ids, targetLibraryID in
                await saveToLibrary(ids: ids, targetLibraryID: targetLibraryID)
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
            onMutePaper: isInboxView ? { id in
                mutePaper(id)
            } : nil,
            onGlobalSearch: {
                NotificationCenter.default.post(name: .showGlobalSearch, object: nil)
            },
            // Refresh callback (shown as small button in list header)
            onRefresh: {
                await refreshFromNetwork()
            },
            isRefreshing: isLoading || isBackgroundRefreshing,
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

    /// Refresh publications from data source (synchronous read).
    ///
    /// - Parameter force: When `true`, always refreshes regardless of store version.
    ///   Use `force: true` for non-mutation refreshes (navigation, filter changes).
    ///   Default (`false`) deduplicates: if the store version hasn't changed since the
    ///   last refresh, the call is a no-op. This prevents double refreshes when both
    ///   an explicit call and `.onReceive(.storeDidMutate)` fire for the same mutation.
    private func refreshPublicationsList(force: Bool = false) {
        guard isSourceValid else { return }

        let store = RustStoreAdapter.shared
        let currentVersion = store.dataVersion
        if !force && currentVersion == lastRefreshedStoreVersion { return }
        lastRefreshedStoreVersion = currentVersion

        publications = store.queryPublications(for: source)

        // Refresh cached library list (cheap — typically < 10 libraries)
        let freshLibraries = store.listLibraries().map { ($0.id, $0.name) }
        if freshLibraries.count != cachedAllLibraries.count ||
           !zip(freshLibraries, cachedAllLibraries).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) {
            cachedAllLibraries = freshLibraries
        }

        // Apply unread filter with Apple Mail behavior
        if filterMode == .unread {
            if let snapshot = unreadFilterSnapshot {
                publications = publications.filter { !$0.isRead || snapshot.contains($0.id) }
            } else {
                publications = publications.filter { !$0.isRead }
            }
        }

        // Apply local filter syntax if active (flags, tags, read state)
        if let filter = activeFilter, !filter.isEmpty {
            // Apply non-text filters locally (text terms handled by FTS)
            let nonTextFilter = LocalFilter(
                textTerms: [],
                flagQuery: filter.flagQuery,
                tagQueries: filter.tagQueries,
                readState: filter.readState
            )
            if !nonTextFilter.isEmpty {
                publications = LocalFilterService.shared.apply(nonTextFilter, to: publications)
            }
            // Apply FTS text filter if active
            if let ftsIDs = ftsFilterResults {
                publications = publications.filter { ftsIDs.contains($0.id) }
            }
        }

        logger.info("Refreshed: \(self.publications.count) items")
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
        case .library(let id):
            // TODO: Future enrichment protocol
            // For now, just refresh the list
            let name = RustStoreAdapter.shared.getLibrary(id: id)?.name ?? "unknown"
            logger.info("Library refresh requested for: \(name)")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList(force: true)
            }

        case .smartSearch(let id):
            let ss = RustStoreAdapter.shared.getSmartSearch(id: id)
            let name = ss?.name ?? "unknown"
            logger.info("Smart search refresh requested for: \(name)")

            // TODO: implement smart search refresh with Rust store
            // Route group feeds to GroupFeedRefreshService for staggered per-author searches
            // Regular smart search - use provider
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList(force: true)
            }

        case .collection(let id):
            // For collections, refresh just re-reads
            logger.info("Collection refresh requested for: \(id)")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList(force: true)
            }

        case .scixLibrary(let id):
            // Pull latest papers from SciX server, then refresh the list
            let scix = RustStoreAdapter.shared.getScixLibrary(id: id)
            let name = scix?.name ?? "unknown"
            logger.info("SciX library refresh requested for: \(name)")
            if let remoteID = scix?.remoteID {
                do {
                    try await SciXSyncManager.shared.pullLibraryPapers(libraryID: remoteID)
                    await MainActor.run {
                        refreshPublicationsList(force: true)
                    }
                } catch {
                    logger.error("SciX library refresh failed: \(error.localizedDescription)")
                    self.error = error
                }
            }

        case .flagged:
            // For flagged, refresh just re-reads from store
            logger.info("Flagged refresh requested")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList(force: true)
            }

        case .unread, .starred, .tag, .inbox, .dismissed:
            logger.info("Virtual source refresh requested")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList(force: true)
            }
        }

        isLoading = false
    }

    /// Queue a background refresh for the smart search if needed (stale or empty).
    ///
    /// This does NOT block the UI - cached results are shown immediately while
    /// the refresh happens in the background via SmartSearchRefreshService.
    private func queueBackgroundRefreshIfNeeded(_ smartSearchID: UUID) async {
        let store = RustStoreAdapter.shared
        guard let ss = store.getSmartSearch(id: smartSearchID) else { return }

        // TODO: implement full smart search background refresh with Rust store
        // For now, check if results are empty and log
        let isEmpty = publications.isEmpty

        if isEmpty {
            logger.info("Smart search '\(ss.name)' needs refresh (empty: \(isEmpty))")

            // Check if already being refreshed
            let alreadyRefreshing = await SmartSearchRefreshService.shared.isRefreshing(smartSearchID)
            let alreadyQueued = await SmartSearchRefreshService.shared.isQueued(smartSearchID)

            if alreadyRefreshing || alreadyQueued {
                logger.debug("Smart search '\(ss.name)' already refreshing/queued")
                isBackgroundRefreshing = alreadyRefreshing
            } else {
                // TODO: queue refresh via Rust store smart search service
                // Don't set isBackgroundRefreshing — no actual refresh mechanism yet
                logger.info("Would queue high-priority background refresh for '\(ss.name)'")
            }
        } else {
            logger.debug("Smart search '\(ss.name)' has results, no refresh needed")
        }
    }

    // MARK: - Notification Handlers

    private func selectAllPublications() {
        selectedPublicationIDs = Set(publications.map { $0.id })
    }

    private func toggleReadStatusForSelected() {
        guard !selectedPublicationIDs.isEmpty else { return }

        let store = RustStoreAdapter.shared
        // Apple Mail behavior: if ANY are unread, mark ALL as read
        // If ALL are read, mark ALL as unread
        let ids = Array(selectedPublicationIDs)
        let anyUnread = publications.filter { selectedPublicationIDs.contains($0.id) }.contains { !$0.isRead }
        store.setRead(ids: ids, read: anyUnread)
    }

    private func copySelectedPublications() async {
        guard !selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.copyToClipboard(selectedPublicationIDs)
    }

    private func cutSelectedPublications() async {
        guard !selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.cutToClipboard(selectedPublicationIDs)
    }

    // MARK: - Inbox Triage Handlers

    /// Handle 'S' key - save selected to default library
    private func handleSaveKey() -> KeyPress.Result {
        guard !TextFieldFocusDetection.isTextFieldFocused(), !isFlagInputActive, !isTagInputActive, !isTagDeleteActive, !isFilterActive, isInboxView, !selectedPublicationIDs.isEmpty else { return .ignored }
        saveSelectedToDefaultLibrary()
        return .handled
    }

    /// Handle 'D' key - dismiss selected publications
    /// For exploration collections: removes from collection only (doesn't dismiss to Dismissed library)
    /// For inbox/other views: moves to Dismissed library
    private func handleDismissKey() -> KeyPress.Result {
        guard !TextFieldFocusDetection.isTextFieldFocused(), !isFlagInputActive, !isTagInputActive, !isTagDeleteActive, !isFilterActive, !selectedPublicationIDs.isEmpty else { return .ignored }

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
        guard !TextFieldFocusDetection.isTextFieldFocused(), !isFlagInputActive, !isTagInputActive, !isTagDeleteActive, !isFilterActive else { return .ignored }

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

        // Toggle star (*): toggles star attribute only (does NOT save to library)
        let starMatched = store.matches(press, action: "inboxToggleStar")
        if starMatched {
            if !selectedPublicationIDs.isEmpty {
                toggleStarForSelected()
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
            await saveToLibrary(ids: ids, targetLibraryID: saveLibrary.id)
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
                RustStoreAdapter.shared.setStarred(ids: Array(ids), starred: true)
            }
            await saveToLibrary(ids: ids, targetLibraryID: saveLibrary.id)
        }
    }

    /// Toggle star for selected publications
    private func toggleStarForSelected() {
        let ids = selectedPublicationIDs
        guard !ids.isEmpty else { return }

        // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
        let anyUnstarred = publications.filter { ids.contains($0.id) }.contains { !$0.isStarred }
        RustStoreAdapter.shared.setStarred(ids: Array(ids), starred: anyUnstarred)
    }

    /// Toggle star for publications by IDs (used by PublicationListView callback)
    private func toggleStarForIDs(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
        let anyUnstarred = publications.filter { ids.contains($0.id) }.contains { !$0.isStarred }
        RustStoreAdapter.shared.setStarred(ids: Array(ids), starred: anyUnstarred)
    }

    /// Set flag for publications by IDs
    private func setFlagForIDs(_ ids: Set<UUID>, color: FlagColor) async {
        guard !ids.isEmpty else { return }

        RustStoreAdapter.shared.setFlag(ids: Array(ids), color: color.rawValue)
    }

    /// Clear flag for publications by IDs
    private func clearFlagForIDs(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        RustStoreAdapter.shared.setFlag(ids: Array(ids), color: nil)
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
        // TODO: implement tag removal by tagID with Rust store
        // The Rust store uses tag paths, not tag UUIDs. Need to look up the tag path from tagID.
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
            ftsFilterResults = nil
        } else {
            activeFilter = LocalFilterService.shared.parse(trimmed)
            // If there are text terms, do async FTS search
            if let filter = activeFilter, !filter.textTerms.isEmpty {
                let query = filter.textTerms.joined(separator: " ")
                let libraryID = currentLibraryID
                Task {
                    if let results = await FullTextSearchService.shared.search(
                        query: query, limit: 500, libraryId: libraryID
                    ) {
                        ftsFilterResults = Set(results.map(\.publicationId))
                    } else {
                        // FTS unavailable — fall back to simple text matching
                        ftsFilterResults = nil
                    }
                    refreshPublicationsList(force: true)
                }
            } else {
                ftsFilterResults = nil
            }
        }
        refreshPublicationsList(force: true)
    }

    /// Clear the active filter and reset filter text
    private func clearFilter() {
        filterText = ""
        activeFilter = nil
        ftsFilterResults = nil
        refreshPublicationsList(force: true)
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

                RustStoreAdapter.shared.setFlag(
                    ids: Array(ids),
                    color: flag.color.rawValue,
                    style: flag.style.rawValue,
                    length: flag.length.rawValue
                )
                flagTargetIDs = []
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
            tagAutocomplete = TagAutocompleteService()
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

        logInfo("commitTag: captured \(targetIDs.count) targets, resolving '\(path)'", category: "tags")

        Task {
            let resolvedPath = TagAliasStore.shared.resolve(path) ?? path

            logInfo("commitTag: applying tag '\(resolvedPath)' to \(targetIDs.count) pubs", category: "tags")

            RustStoreAdapter.shared.addTag(ids: Array(targetIDs), tagPath: resolvedPath)

            logInfo("commitTag: done", category: "tags")

            tagAutocomplete?.invalidate()
            tagTargetIDs = []
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
    private func computeVisualOrder() -> [PublicationRowData] {
        // Apply current sort order with stable tie-breaker (UUID) on ALL sort criteria.
        // This MUST match PublicationListView.filteredRowData sorting exactly.
        let sorted = publications.sorted { lhs, rhs in
            let primaryResult = primarySortComparison(lhs, rhs)
            if primaryResult != .orderedSame { return primaryResult == .orderedAscending }
            // Stable tie-breaker: UUID string comparison ensures identical order regardless of input order
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return sorted
    }

    /// Primary sort comparison — returns .orderedSame when items are equal on the sort key.
    /// Used by computeVisualOrder for stable tie-breaking.
    private func primarySortComparison(_ lhs: PublicationRowData, _ rhs: PublicationRowData) -> ComparisonResult {
        let ascending = currentSortAscending == currentSortOrder.defaultAscending

        switch currentSortOrder {
        case .recommended:
            let lhsScore = recommendationScores[lhs.id] ?? 0
            let rhsScore = recommendationScores[rhs.id] ?? 0
            if lhsScore != rhsScore {
                let result: ComparisonResult = lhsScore > rhsScore ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded != rhs.dateAdded {
                let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            return .orderedSame
        case .dateAdded:
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .dateModified:
            if lhs.dateModified == rhs.dateModified { return .orderedSame }
            let result: ComparisonResult = lhs.dateModified > rhs.dateModified ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .title:
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if cmp == .orderedSame { return .orderedSame }
            let result: ComparisonResult = cmp == .orderedAscending ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .year:
            let ly = lhs.year ?? 0, ry = rhs.year ?? 0
            if ly == ry { return .orderedSame }
            let result: ComparisonResult = ly > ry ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .citeKey:
            let cmp = lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey)
            if cmp == .orderedSame { return .orderedSame }
            let result: ComparisonResult = cmp == .orderedAscending ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .citationCount:
            if lhs.citationCount == rhs.citationCount { return .orderedSame }
            let result: ComparisonResult = lhs.citationCount > rhs.citationCount ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .starred:
            if lhs.isStarred != rhs.isStarred {
                let result: ComparisonResult = lhs.isStarred ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        }
    }

    /// Dismiss selected publications from inbox (moves to Dismissed library, not delete)
    /// Advances selection to next paper for rapid triage.
    private func dismissSelectedFromInbox() {
        guard let firstID = selectedPublicationIDs.first else { return }

        // Show orange flash for dismiss action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .orange)
        }

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()
        let currentIDs = selectedPublicationIDs

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Compute next selection before removing
                let nextID = computeNextSelection(removing: currentIDs, from: visualOrder)

                // Track dismissal to prevent reappearance in feeds
                for id in currentIDs {
                    InboxManager.shared.trackDismissal(id)
                }

                // Advance to next selection BEFORE mutation (so .storeDidMutate refresh sees correct selection)
                if let nextID {
                    selectedPublicationIDs = [nextID]
                    selectedPublicationID = nextID
                } else {
                    selectedPublicationIDs.removeAll()
                    selectedPublicationID = nil
                }

                // Move publications to dismissed library (triggers .storeDidMutate → refresh)
                let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()
                RustStoreAdapter.shared.movePublications(ids: Array(currentIDs), toLibraryId: dismissedLibrary.id)
            }
        }
    }

    // MARK: - Exploration Collection Triage

    /// Save selected publications to Save library AND remove from exploration collection.
    /// Used for exploration collections where S key should both save and remove.
    private func saveSelectedAndRemoveFromExploration() {
        guard case .collection(let collectionID) = source else { return }
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

                // Advance selection BEFORE mutation
                let nextID = computeNextSelection(removing: ids, from: visualOrder)
                if let nextID {
                    selectedPublicationIDs = [nextID]
                    selectedPublicationID = nextID
                } else {
                    selectedPublicationIDs.removeAll()
                    selectedPublicationID = nil
                }

                // Add to Save library and remove from exploration collection (triggers .storeDidMutate → refresh)
                let store = RustStoreAdapter.shared
                _ = store.duplicatePublications(ids: Array(ids), toLibraryId: saveLibrary.id)
                store.removeFromCollection(publicationIds: Array(ids), collectionId: collectionID)
            }
        }
    }

    /// Remove selected publications from exploration collection (without dismissing to Dismissed library).
    /// Used for D key in exploration collections.
    private func removeSelectedFromExploration() {
        guard case .collection(let collectionID) = source else { return }
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

                // Advance selection BEFORE mutation
                let nextID = computeNextSelection(removing: ids, from: visualOrder)
                if let nextID {
                    selectedPublicationIDs = [nextID]
                    selectedPublicationID = nextID
                } else {
                    selectedPublicationIDs.removeAll()
                    selectedPublicationID = nil
                }

                // Remove from exploration collection (triggers .storeDidMutate → refresh)
                RustStoreAdapter.shared.removeFromCollection(publicationIds: Array(ids), collectionId: collectionID)
            }
        }
    }

    /// Compute the next selection ID after removing the given IDs from the visual order.
    private func computeNextSelection(removing ids: Set<UUID>, from visualOrder: [PublicationRowData]) -> UUID? {
        // Find the last selected item in visual order (bottom of the selection block).
        // This ensures we advance "downward" from where the user's selection ends.
        guard let lastSelectedIndex = visualOrder.lastIndex(where: { ids.contains($0.id) }) else {
            return nil
        }

        // Try the item immediately after the last selected item
        for i in (lastSelectedIndex + 1)..<visualOrder.count {
            if !ids.contains(visualOrder[i].id) {
                return visualOrder[i].id
            }
        }

        // If no next item, try before the first selected item
        if let firstSelectedIndex = visualOrder.firstIndex(where: { ids.contains($0.id) }) {
            for i in (0..<firstSelectedIndex).reversed() {
                if !ids.contains(visualOrder[i].id) {
                    return visualOrder[i].id
                }
            }
        }

        return nil
    }

    // MARK: - Save Implementation

    /// Save publications to a target library (adds to target AND removes from current).
    /// Advances selection to next paper for rapid triage.
    private func saveToLibrary(ids: Set<UUID>, targetLibraryID: UUID) async {
        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        // Track dismissal for inbox papers to prevent reappearance in feeds
        if isInboxView {
            for id in ids {
                InboxManager.shared.trackDismissal(id)
            }
        }

        // Compute and advance selection BEFORE mutation
        let nextID = computeNextSelection(removing: ids, from: visualOrder)
        if let nextID {
            selectedPublicationIDs = [nextID]
            selectedPublicationID = nextID
        } else {
            selectedPublicationIDs.removeAll()
            selectedPublicationID = nil
        }

        // Move publications to the target library (triggers .storeDidMutate → refresh)
        let store = RustStoreAdapter.shared
        store.movePublications(ids: Array(ids), toLibraryId: targetLibraryID)
    }

    // MARK: - Inbox Triage Callback Implementations

    /// Dismiss publications from inbox (for context menu) - moves to Dismissed library, not delete
    private func dismissFromInbox(ids: Set<UUID>) async {
        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        // Track dismissal to prevent reappearance in feeds
        for id in ids {
            InboxManager.shared.trackDismissal(id)
        }

        // Compute and advance selection BEFORE mutation
        let nextID = computeNextSelection(removing: ids, from: visualOrder)
        if let nextID {
            selectedPublicationIDs = [nextID]
            selectedPublicationID = nextID
        } else {
            selectedPublicationIDs.removeAll()
            selectedPublicationID = nil
        }

        // Move to dismissed library (triggers .storeDidMutate → refresh)
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()
        RustStoreAdapter.shared.movePublications(ids: Array(ids), toLibraryId: dismissedLibrary.id)
    }

    /// Mute an author
    private func muteAuthor(_ authorName: String) {
        _ = RustStoreAdapter.shared.createMutedItem(muteType: "author", value: authorName)
        logger.info("Muted author: \(authorName)")
    }

    /// Mute a paper (by DOI or bibcode)
    private func mutePaper(_ publicationID: UUID) {
        let store = RustStoreAdapter.shared
        guard let pub = store.getPublication(id: publicationID) else { return }

        // Prefer DOI, then bibcode
        if let doi = pub.doi, !doi.isEmpty {
            _ = store.dismissPaper(doi: doi)
            logger.info("Muted paper by DOI: \(doi)")
        } else if let bibcode = pub.bibcode, !bibcode.isEmpty {
            _ = store.dismissPaper(bibcode: bibcode)
            logger.info("Muted paper by bibcode: \(bibcode)")
        } else {
            logger.warning("Cannot mute paper - no DOI or bibcode available")
        }
    }

    // MARK: - Helpers

    private func openPDF(for publicationID: UUID) {
        // Check user preference for opening PDFs
        let openExternally = UserDefaults.standard.bool(forKey: "openPDFInExternalViewer")
        let store = RustStoreAdapter.shared

        if openExternally {
            // Open in external viewer (Preview, Adobe, etc.)
            let linkedFiles = store.listLinkedFiles(publicationId: publicationID)
            if let pdfFile = linkedFiles.first(where: { $0.isPDF }),
               let libraryID = currentLibraryID,
               let library = store.getLibrary(id: libraryID) {
                // TODO: implement library folder URL lookup for PDF opening
                // For now, just show in built-in tab
                libraryViewModel.selectedPublications = [publicationID]
                NotificationCenter.default.post(name: .showPDFTab, object: nil)
            }
        } else {
            // Show in built-in PDF tab
            // First ensure the publication is selected, then switch to PDF tab
            libraryViewModel.selectedPublications = [publicationID]
            NotificationCenter.default.post(name: .showPDFTab, object: nil)
        }
    }

    /// Capture current unread publication IDs for Apple Mail-style snapshot.
    /// Items in the snapshot stay visible even after being marked as read.
    private func captureUnreadSnapshot() -> Set<UUID> {
        return Set(publications.filter { !$0.isRead }.map { $0.id })
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
                if case .smartSearch(let ssID) = source,
                   let completedID = notification.object as? UUID,
                   completedID == ssID {
                    let name = RustStoreAdapter.shared.getSmartSearch(id: ssID)?.name ?? "unknown"
                    onRefreshComplete(name)
                }
            }
    }
}

// MARK: - Inbox Triage Modifier

/// Keyboard shortcuts for inbox triage workflow (save/star/dismiss).
/// Only active when viewing the inbox.
private struct InboxTriageModifier: ViewModifier {
    let isInboxView: Bool
    let hasSelection: Bool
    let isInputOverlayActive: Bool
    let onSave: () -> Void
    let onSaveAndStar: () -> Void
    let onToggleStar: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.return) {
                guard isInboxView && hasSelection && !isInputOverlayActive else { return .ignored }
                onSave()
                return .handled
            }
            .onKeyPress(.init("s")) {
                guard isInboxView && hasSelection && !isInputOverlayActive else { return .ignored }
                onSaveAndStar()
                return .handled
            }
            .onKeyPress(.init("*")) {
                guard hasSelection && !isInputOverlayActive else { return .ignored }
                onToggleStar()
                return .handled
            }
            .onKeyPress(.delete) {
                guard isInboxView && hasSelection && !isInputOverlayActive else { return .ignored }
                onDismiss()
                return .handled
            }
    }
}

/// Manages focus transitions when input overlays (flag, tag, filter) activate/deactivate.
/// Extracted as a ViewModifier to reduce type-checking complexity in the main body.
private struct InputOverlayFocusModifier: ViewModifier {
    let isFlagInputActive: Bool
    let isTagInputActive: Bool
    let isTagDeleteActive: Bool
    let isFilterActive: Bool
    let onActivate: () -> Void
    let onDeactivate: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isFlagInputActive) { _, active in
                if active { onActivate() } else { onDeactivate() }
            }
            .onChange(of: isTagInputActive) { _, active in
                if active { onActivate() } else { onDeactivate() }
            }
            .onChange(of: isTagDeleteActive) { _, active in
                if active { onActivate() } else { onDeactivate() }
            }
            .onChange(of: isFilterActive) { _, active in
                if active { onActivate() } else { onDeactivate() }
            }
    }
}

