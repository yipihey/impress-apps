//
//  SidebarView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import CoreData
#if canImport(CloudKit)
import CloudKit
#endif
import PublicationManagerCore
import UniformTypeIdentifiers
import OSLog
import ImpressKeyboard
import ImpressSidebar
import ImpressFTUI

// MARK: - Sidebar Drop Types

/// Typed drop destinations for the sidebar.
/// Using an enum ensures type-safe drop routing and consistent handling.
enum SidebarDropDestination: Equatable, Hashable {
    /// Drop on a library header (adds publications/files to library)
    case libraryHeader(libraryID: UUID)

    /// Drop on a collection (adds publications to collection)
    case collection(collectionID: UUID, libraryID: UUID)

    /// Drop on the "move to root" zone within a library
    case libraryRoot(libraryID: UUID)

    /// Drop on the sidebar background (for creating new library from BibTeX)
    case sidebarBackground
}

/// Protocol for the drop context that handles actual data operations.
/// This allows the coordinator to be decoupled from the view layer.
@MainActor
protocol SidebarDropContext {
    func addPublicationsToLibrary(uuids: [UUID], libraryID: UUID)
    func addPublicationsToCollection(uuids: [UUID], collectionID: UUID)
    func handleFileDrop(providers: [NSItemProvider], libraryID: UUID)
    func handleFileDropOnCollection(providers: [NSItemProvider], collectionID: UUID, libraryID: UUID)
    func handleBibTeXDrop(providers: [NSItemProvider], libraryID: UUID)
    func handleBibTeXDropForNewLibrary(providers: [NSItemProvider])
    func handleCrossLibraryCollectionMove(providers: [NSItemProvider], targetLibraryID: UUID)
    func handleCollectionDropToRoot(providers: [NSItemProvider], libraryID: UUID)
    func handleCollectionNesting(providers: [NSItemProvider], targetCollectionID: UUID)
}

/// Centralized coordinator for all sidebar drop operations.
///
/// Benefits:
/// - Single point to debug drop issues
/// - Type-safe drop targets
/// - Consistent validation and feedback
/// - Works identically on macOS and iOS
@MainActor @Observable
final class SidebarDropCoordinator {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.imbib.app", category: "sidebar-drop-coordinator")

    private func log(_ message: String) {
        logger.info("\(message)")
        Task { @MainActor in
            LogStore.shared.log(level: .info, category: "dragdrop", message: message)
        }
    }

    private func logError(_ message: String) {
        logger.error("\(message)")
        Task { @MainActor in
            LogStore.shared.log(level: .error, category: "dragdrop", message: message)
        }
    }

    // MARK: - State

    /// Currently hovered drop target (for visual feedback)
    var hoveredTarget: SidebarDropDestination?

    /// The shared DragDropCoordinator for file handling
    private let fileCoordinator = DragDropCoordinator.shared

    // MARK: - UTType Constants

    private static let bibtexUTI = "org.tug.tex.bibtex"
    private static let risUTI = "com.clarivate.ris"

    // MARK: - Drop Validation

    /// Check if providers contain publication IDs
    func hasPublicationDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) }
    }

    /// Check if providers contain collection IDs
    func hasCollectionDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) }
    }

    /// Check if providers contain file drops (PDF, .bib, .ris)
    func hasFileDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI)
        }
    }

    /// Check if providers contain BibTeX or RIS file drops
    func hasBibTeXOrRISDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI) ||
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier)
        }
    }

    // MARK: - Accepted Types

    /// All accepted drop types for library headers
    var libraryHeaderAcceptedTypes: [UTType] {
        DragDropCoordinator.acceptedTypes + [.publicationID, .collectionID]
    }

    /// All accepted drop types for collections
    var collectionAcceptedTypes: [UTType] {
        DragDropCoordinator.acceptedTypes + [.publicationID]
    }

    // MARK: - Main Drop Handler

    /// Handle a drop on a specific target.
    /// Returns true if the drop was accepted.
    func handleDrop(
        providers: [NSItemProvider],
        target: SidebarDropDestination,
        context: SidebarDropContext
    ) -> Bool {
        log("📦 DROP on \(targetDescription(target))")
        log("  - Provider count: \(providers.count)")
        logProviderTypes(providers)

        switch target {
        case .libraryHeader(let libraryID):
            return handleLibraryHeaderDrop(providers: providers, libraryID: libraryID, context: context)

        case .collection(let collectionID, let libraryID):
            return handleCollectionDrop(providers: providers, collectionID: collectionID, libraryID: libraryID, context: context)

        case .libraryRoot(let libraryID):
            return handleLibraryRootDrop(providers: providers, libraryID: libraryID, context: context)

        case .sidebarBackground:
            return handleSidebarBackgroundDrop(providers: providers, context: context)
        }
    }

    // MARK: - Target-Specific Handlers

    private func handleLibraryHeaderDrop(
        providers: [NSItemProvider],
        libraryID: UUID,
        context: SidebarDropContext
    ) -> Bool {
        // Check for collection drops first - cross-library collection move
        if hasCollectionDrops(providers) {
            log("  → Routing to cross-library collection move handler")
            context.handleCrossLibraryCollectionMove(providers: providers, targetLibraryID: libraryID)
            return true
        }

        // Check for BibTeX/RIS files - these open import preview
        if hasBibTeXOrRISDrops(providers) {
            log("  → Routing to BibTeX import handler")
            context.handleBibTeXDrop(providers: providers, libraryID: libraryID)
            return true
        }

        // Check for other file drops (PDFs)
        if hasFileDrops(providers) {
            log("  → Routing to file drop handler")
            context.handleFileDrop(providers: providers, libraryID: libraryID)
            return true
        }

        // Handle publication drops
        if hasPublicationDrops(providers) {
            log("  → Routing to publication drop handler")
            loadPublicationIDs(from: providers) { uuids in
                self.log("  → Loaded \(uuids.count) publication UUIDs")
                context.addPublicationsToLibrary(uuids: uuids, libraryID: libraryID)
            }
            return true
        }

        log("  ⚠️ No recognized drop type")
        return false
    }

    private func handleCollectionDrop(
        providers: [NSItemProvider],
        collectionID: UUID,
        libraryID: UUID,
        context: SidebarDropContext
    ) -> Bool {
        // Check for file drops
        if hasFileDrops(providers) {
            log("  → Routing to file drop on collection handler")
            context.handleFileDropOnCollection(providers: providers, collectionID: collectionID, libraryID: libraryID)
            return true
        }

        // Handle publication drops
        if hasPublicationDrops(providers) {
            log("  → Routing to publication drop handler")
            loadPublicationIDs(from: providers) { uuids in
                self.log("  → Loaded \(uuids.count) publication UUIDs")
                context.addPublicationsToCollection(uuids: uuids, collectionID: collectionID)
            }
            return true
        }

        // Handle collection drops (for nesting)
        if hasCollectionDrops(providers) {
            log("  → Routing to collection nesting handler")
            context.handleCollectionNesting(providers: providers, targetCollectionID: collectionID)
            return true
        }

        log("  ⚠️ No recognized drop type")
        return false
    }

    private func handleLibraryRootDrop(
        providers: [NSItemProvider],
        libraryID: UUID,
        context: SidebarDropContext
    ) -> Bool {
        // Only handle collection drops - move collection to root
        if hasCollectionDrops(providers) {
            log("  → Moving collection to library root")
            context.handleCollectionDropToRoot(providers: providers, libraryID: libraryID)
            return true
        }

        log("  ⚠️ Library root only accepts collection drops")
        return false
    }

    private func handleSidebarBackgroundDrop(
        providers: [NSItemProvider],
        context: SidebarDropContext
    ) -> Bool {
        // Only handle BibTeX/RIS files - creates new library
        if hasBibTeXOrRISDrops(providers) {
            log("  → Creating new library from BibTeX/RIS")
            context.handleBibTeXDropForNewLibrary(providers: providers)
            return true
        }

        log("  ⚠️ Sidebar background only accepts BibTeX/RIS files")
        return false
    }

    // MARK: - Publication ID Loading

    /// Load publication UUIDs from providers
    private func loadPublicationIDs(from providers: [NSItemProvider], completion: @escaping ([UUID]) -> Void) {
        var collectedUUIDs: [UUID] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, error in
                defer { group.leave() }
                guard let data = data else { return }

                // Try to decode as JSON array first (multi-selection format)
                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    for idString in uuidStrings {
                        if let uuid = UUID(uuidString: idString) {
                            collectedUUIDs.append(uuid)
                        }
                    }
                }
                // Fallback: UUID is encoded as JSON via CodableRepresentation
                else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    collectedUUIDs.append(uuid)
                }
            }
        }

        group.notify(queue: .main) {
            completion(collectedUUIDs)
        }
    }

    // MARK: - Helpers

    private func targetDescription(_ target: SidebarDropDestination) -> String {
        switch target {
        case .libraryHeader(let id):
            return "library header (\(id.uuidString.prefix(8))...)"
        case .collection(let colID, _):
            return "collection (\(colID.uuidString.prefix(8))...)"
        case .libraryRoot(let id):
            return "library root (\(id.uuidString.prefix(8))...)"
        case .sidebarBackground:
            return "sidebar background"
        }
    }

    private func logProviderTypes(_ providers: [NSItemProvider]) {
        for (i, provider) in providers.enumerated() {
            let types = provider.registeredTypeIdentifiers
            log("  - Provider[\(i)] types: \(types.joined(separator: ", "))")
        }
    }
}

// MARK: - Focus Border Extension (duplicated from ContentView for cross-file use)

extension View {
    /// Visual indicator for focused pane in vim-style navigation.
    /// Shows a subtle colored border around the focused pane.
    @ViewBuilder
    func focusBorder(isFocused: Bool) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
                .padding(1)  // Inset slightly so border doesn't clip
        )
    }
}

private let sidebarLogger = Logger(subsystem: "com.imbib.app", category: "sidebar-dragdrop")

/// Log drag-drop info to both system console AND app's Console window
private func dragDropLog(_ message: String) {
    sidebarLogger.info("\(message)")
    Task { @MainActor in
        LogStore.shared.log(level: .info, category: "dragdrop", message: message)
    }
}

/// Log drag-drop error to both system console AND app's Console window
private func dragDropError(_ message: String) {
    sidebarLogger.error("\(message)")
    Task { @MainActor in
        LogStore.shared.log(level: .error, category: "dragdrop", message: message)
    }
}

/// Log drag-drop warning to both system console AND app's Console window
private func dragDropWarning(_ message: String) {
    sidebarLogger.warning("\(message)")
    Task { @MainActor in
        LogStore.shared.log(level: .warning, category: "dragdrop", message: message)
    }
}

// MARK: - Library Drag Item

/// Transferable wrapper for dragging libraries (for reordering)
struct LibraryDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .libraryID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return LibraryDragItem(id: uuid)
        }
    }
}

// MARK: - Collection Drag Item

/// Transferable wrapper for dragging collections (for nesting and cross-library moves)
struct CollectionDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .collectionID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return CollectionDragItem(id: uuid)
        }
    }
}

// MARK: - Inbox Feed Drag Item

/// Transferable wrapper for dragging inbox feeds (for reordering)
struct InboxFeedDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .inboxFeedID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return InboxFeedDragItem(id: uuid)
        }
    }
}

// MARK: - Search Form Drag Item

/// Transferable wrapper for dragging search form types (for reordering)
struct SearchFormDragItem: Transferable {
    let type: SearchFormType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .searchFormID) { item in
            item.type.rawValue.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let type = SearchFormType(rawValue: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SearchFormDragItem(type: type)
        }
    }
}

// MARK: - SciX Library Drag Item

/// Transferable wrapper for dragging SciX libraries (for reordering)
struct SciXLibraryDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .scixLibraryID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SciXLibraryDragItem(id: uuid)
        }
    }
}

// MARK: - Section Drag Item

/// Transferable wrapper for dragging sidebar sections (for reordering)
struct SectionDragItem: Transferable {
    let type: SidebarSectionType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .sidebarSectionID) { item in
            SectionDragReorder.encode(item.type)
        } importing: { data in
            guard let type = SectionDragReorder.decode(data, as: SidebarSectionType.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SectionDragItem(type: type)
        }
    }
}

// MARK: - Flag Color Drag Item

/// Transferable wrapper for dragging flag colors (for reordering)
struct FlagColorDragItem: Transferable {
    let color: FlagColor

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .flagColorID) { item in
            item.color.rawValue.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let color = FlagColor(rawValue: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return FlagColorDragItem(color: color)
        }
    }
}

// MARK: - Exploration Search Drag Item

/// Transferable wrapper for dragging exploration searches (for reordering)
struct ExplorationSearchDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .explorationSearchID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ExplorationSearchDragItem(id: uuid)
        }
    }
}

struct SidebarView: View {

    // MARK: - Properties

    @Binding var selection: SidebarSection?
    @Binding var expandedLibraries: Set<UUID>
    @Binding var focusedPane: FocusedPane?

    // MARK: - Drag-Drop Coordinators

    /// Centralized sidebar drop coordinator for type-safe drop routing
    @State private var sidebarDropCoordinator = SidebarDropCoordinator()

    /// File-level drag-drop coordinator (for PDF imports, etc.)
    private let dragDropCoordinator = DragDropCoordinator.shared

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme
    @Environment(\.openSettings) private var openSettings

    // MARK: - Observed Objects

    /// Observe SmartSearchRepository to refresh when smart searches change
    private let smartSearchRepository = SmartSearchRepository.shared

    /// Observe SciXLibraryRepository for SciX libraries
    private let scixRepository = SciXLibraryRepository.shared

    // MARK: - State

    /// Consolidated sidebar state using @Observable pattern
    @State private var state = SidebarState()

    // Section ordering and collapsed state (persisted via stores, not @AppStorage)
    @State private var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    @State private var collapsedSections: Set<SidebarSectionType> = SidebarCollapsedStateStore.loadCollapsedSync()

    /// Section currently targeted by a section drag (for blue insertion line indicator)
    @State private var sectionDropTarget: SidebarSectionType?

    // Search form ordering and visibility (persisted)
    @State private var searchFormOrder: [SearchFormType] = SearchFormStore.loadOrderSync()
    @State private var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()

    // Flag color ordering (persisted)
    @State private var flagColorOrder: [FlagColor] = FlagColorOrderStore.loadOrderSync()

    // Focus state for inline collection rename
    @FocusState private var isRenamingCollectionFocused: Bool
    @FocusState private var isRenamingInboxCollectionFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Main list with optional theme tint
            List(selection: $selection) {
                // All sections in user-defined order, collapsible and reorderable
                // Cache order to avoid re-fetch race conditions during drag
                let orderSnapshot = sectionOrder

                ForEach(orderSnapshot) { sectionType in
                    sectionView(for: sectionType)
                        .id(sectionType == .exploration ? state.explorationRefreshTrigger : nil)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(theme.detailBackground != nil || theme.sidebarTint != nil ? .hidden : .automatic)
            .background {
                if let tint = theme.sidebarTint {
                    tint.opacity(theme.sidebarTintOpacity)
                }
            }
            // Vim-style keyboard navigation (h/l for focus cycling, j/k for item selection)
            .focusable()
            .onKeyPress { press in
                // Don't intercept keys when typing in a text field (e.g., renaming collections)
                guard !TextFieldFocusDetection.isTextFieldFocused() else {
                    return .ignored
                }

                let store = KeyboardShortcutsStore.shared
                // Cycle focus left (default: h)
                if store.matches(press, action: "cycleFocusLeft") {
                    NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
                    return .handled
                }
                // Cycle focus right (default: l)
                if store.matches(press, action: "cycleFocusRight") {
                    NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
                    return .handled
                }
                // j/k for sidebar item navigation is handled by the List's built-in keyboard support
                return .ignored
            }
            // Visual focus indicator
            .focusBorder(isFocused: focusedPane == .sidebar)
            // Set focus when sidebar is clicked
            .onTapGesture {
                focusedPane = .sidebar
            }
            // Sidebar-wide drop target for BibTeX/RIS files (not dropped on a specific library)
            // Opens import preview with "Create new library" pre-selected
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Only handle BibTeX/RIS files - other drops (publications, PDFs) should go to specific targets
                if hasBibTeXOrRISDrops(providers) {
                    handleBibTeXDropForNewLibrary(providers)
                    return true
                }
                return false
            }

            // Bottom toolbar
            Divider()
            bottomToolbar
        }
        #if os(iOS)
        .navigationTitle("imbib")  // Keep for iOS navigation bar
        #endif
        #if os(macOS)
        // No .navigationTitle on macOS - prevents inline header from appearing in content pane
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        #endif
        // Unified sheet presentation using SidebarSheet enum
        .sheet(item: $state.activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .onChange(of: dragDropCoordinator.pendingPreview) { _, newValue in
            // Dismiss the sheet when pendingPreview becomes nil (import completed or cancelled)
            if newValue == nil, case .dropPreview = state.activeSheet {
                state.dismissSheet()
            }
        }
        .alert("Delete Library?", isPresented: $state.showDeleteConfirmation, presenting: state.libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                deleteLibrary(library)
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.displayName)\"? This will remove all publications and cannot be undone.")
        }
        .alert("Empty Dismissed?", isPresented: $state.showEmptyDismissedConfirmation) {
            Button("Empty", role: .destructive) {
                libraryManager.emptyDismissedLibrary()
                state.triggerRefresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = libraryManager.dismissedLibrary?.publications?.count ?? 0
            Text("Are you sure you want to permanently delete \(count) dismissed paper\(count == 1 ? "" : "s")? This cannot be undone.")
        }
        // Mbox import file picker
        .fileImporter(
            isPresented: $state.showMboxImportPicker,
            allowedContentTypes: [UTType(filenameExtension: "mbox") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        await prepareMboxImport(from: url)
                    }
                }
            case .failure(let error):
                state.mboxExportError = error.localizedDescription
                state.showMboxExportError = true
            }
        }
        // Mbox export error alert
        .alert("Export Error", isPresented: $state.showMboxExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.mboxExportError ?? "Unknown error")
        }
        // CloudKit sharing sheet
        .sheet(item: $state.itemToShareViaICloud) { item in
            #if os(macOS)
            ShareConfigurationSheet(item: item)
            #else
            Text("iCloud sharing is not available on this platform.")
            #endif
        }
        // Activity feed sheet
        .sheet(item: $state.activityFeedLibrary) { library in
            ActivityFeedView(library: library)
        }
        // Assignment list sheet
        .sheet(item: $state.assignmentLibrary) { library in
            AssignmentListView(library: library)
        }
        // Citation graph sheet
        .sheet(item: $state.citationGraphLibrary) { library in
            CitationGraphView(library: library)
        }
        // Participant management sheet
        .sheet(item: $state.sharedLibraryToManage) { library in
            ParticipantManagementView(library: library)
        }
        .task {
            // Auto-expand the first library if none expanded
            if expandedLibraries.isEmpty, let firstLibrary = libraryManager.libraries.first {
                expandedLibraries.insert(firstLibrary.id)
            }
            // Load all smart searches (not filtered by library) for sidebar display
            smartSearchRepository.loadSmartSearches(for: nil)

            // Compute initial flag counts and register for updates
            state.refreshFlagCounts(libraries: libraryManager.libraries)
            state.observeFlagChanges { [libraryManager] in libraryManager.libraries }

            // Check for ADS API key (SciX uses ADS API) and load libraries if available
            if let _ = await CredentialManager.shared.apiKey(for: "ads") {
                state.hasSciXAPIKey = true
                // Load cached libraries from Core Data
                scixRepository.loadLibraries()
                // Optionally trigger a background refresh from server
                Task.detached {
                    try? await SciXSyncManager.shared.pullLibraries()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readStatusDidChange)) { _ in
            // Force re-render to update unread counts
            state.triggerRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryContentDidChange)) { _ in
            // Force re-render to update publication counts after add/move operations
            state.triggerRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            // Refresh exploration section
            state.triggerExplorationRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
            // Navigate to a smart search in the sidebar (from share extension or other source)
            if let searchID = notification.object as? UUID,
               let smartSearch = explorationSmartSearches.first(where: { $0.id == searchID }) {
                selection = .smartSearch(smartSearch)
            }
            // Refresh exploration to show the new/updated search
            state.triggerExplorationRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
            // Navigate to the collection in the sidebar
            if let collection = notification.userInfo?["collection"] as? CDCollection {
                // Expand all ancestors so the collection is visible in the tree
                expandAncestors(of: collection)
                selection = .collection(collection)
                state.triggerExplorationRefresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            // Refresh retention labels when settings change
            Task {
                await state.loadInboxSettings()
            }
            state.triggerRefresh()
        }
        // Auto-expand ancestors, set exploration context, and clear multi-selection when selection changes
        .onChange(of: selection) { _, newSelection in
            // Check if new selection is in the exploration section
            let isExplorationSelection: Bool
            switch newSelection {
            case .collection(let collection):
                // Check if this collection belongs to the exploration library
                isExplorationSelection = collection.library?.id == libraryManager.explorationLibrary?.id
                expandAncestors(of: collection)
                if isExplorationSelection {
                    ExplorationService.shared.currentExplorationContext = collection
                } else {
                    ExplorationService.shared.currentExplorationContext = nil
                }
            case .smartSearch(let smartSearch):
                // Check if this smart search belongs to the exploration library
                isExplorationSelection = smartSearch.library?.id == libraryManager.explorationLibrary?.id
                ExplorationService.shared.currentExplorationContext = nil
            default:
                isExplorationSelection = false
                ExplorationService.shared.currentExplorationContext = nil
            }

            // Clear exploration multi-selection when navigating outside exploration section
            // This ensures only one item appears selected at a time
            if !isExplorationSelection {
                state.clearExplorationSelection()
                state.clearSearchSelection()
            }
        }
        .id(state.refreshTrigger)  // Re-render when refreshTrigger changes
    }

    // MARK: - Sheet Content

    /// Unified sheet content based on SidebarSheet enum
    @ViewBuilder
    private func sheetContent(for sheet: SidebarSheet) -> some View {
        switch sheet {
        case .newLibrary:
            NewLibrarySheet()

        case .newSmartCollection(let library):
            SmartCollectionEditor(isPresented: .constant(true)) { name, predicate in
                Task {
                    await createSmartCollection(name: name, predicate: predicate, in: library)
                }
                state.dismissSheet()
            }

        case .editCollection(let collection):
            SmartCollectionEditor(isPresented: .constant(true), collection: collection) { name, predicate in
                Task {
                    await updateCollection(collection, name: name, predicate: predicate)
                }
                state.dismissSheet()
            }

        case .dropPreview(let libraryID):
            dropPreviewSheetContent(for: libraryID)

        case .mboxImport(let preview, _):
            MboxImportPreviewView(
                preview: preview,
                onImport: { selectedIDs, duplicateDecisions in
                    Task {
                        await executeMboxImport(
                            preview: preview,
                            selectedIDs: selectedIDs,
                            duplicateDecisions: duplicateDecisions
                        )
                    }
                    state.dismissSheet()
                },
                onCancel: {
                    state.mboxImportPreview = nil
                    state.dismissSheet()
                }
            )
            .frame(minWidth: 600, minHeight: 500)
        }
    }

    /// Drop preview sheet content for a specific library
    @ViewBuilder
    private func dropPreviewSheetContent(for libraryID: UUID) -> some View {
        @Bindable var coordinator = dragDropCoordinator
        DropPreviewSheet(
            preview: $coordinator.pendingPreview,
            libraryID: libraryID,
            coordinator: dragDropCoordinator
        )
        .onDisappear {
            state.dropPreviewTargetLibraryID = nil
            state.triggerRefresh()
        }
    }

    // MARK: - Section Views

    /// Returns the appropriate section view for a given section type
    @ViewBuilder
    private func sectionView(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            // Inbox uses selectable header - clicking "Inbox" shows all papers
            selectableCollapsibleSection(for: .inbox, tag: .inbox) {
                inboxSectionContent
            }
        case .libraries:
            collapsibleSection(for: .libraries) {
                librariesSectionContent
            }
        case .sharedWithMe:
            if !libraryManager.sharedWithMeLibraries.isEmpty {
                collapsibleSection(for: .sharedWithMe) {
                    sharedWithMeSectionContent
                }
            }
        case .scixLibraries:
            if state.hasSciXAPIKey && !scixRepository.libraries.isEmpty {
                collapsibleSection(for: .scixLibraries) {
                    scixLibrariesSectionContent
                }
            }
        case .search:
            collapsibleSection(for: .search) {
                searchSectionContent
            }
        case .exploration:
            // Show exploration section if there are smart searches OR collections
            let hasExplorationSearches = !explorationSmartSearches.isEmpty
            let hasExplorationCollections = libraryManager.explorationLibrary?.collections?.isEmpty == false
            if hasExplorationSearches || hasExplorationCollections {
                collapsibleSection(for: .exploration) {
                    explorationSectionContent
                }
            }
        case .flagged:
            collapsibleSection(for: .flagged) {
                flaggedSectionContent
            }
        case .dismissed:
            if let dismissedLibrary = libraryManager.dismissedLibrary,
               let publications = dismissedLibrary.publications,
               !publications.isEmpty {
                collapsibleSection(for: .dismissed) {
                    dismissedSectionContent
                }
            }
        }
    }

    /// Wraps section content in a collapsible Section with standard header
    @ViewBuilder
    private func collapsibleSection<Content: View>(
        for sectionType: SidebarSectionType,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(sectionType)

        Section {
            if !isCollapsed {
                content()
            }
        } header: {
            HStack(spacing: 4) {
                // Collapse/expand button
                Button {
                    toggleSectionCollapsed(sectionType)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                // Section title
                Text(sectionType.displayName)

                Spacer()

                // Additional header content based on section type
                sectionHeaderExtras(for: sectionType)
            }
            .contentShape(Rectangle())
            .draggable(SectionDragItem(type: sectionType)) {
                HStack {
                    Image(systemName: sectionType.icon)
                    Text(sectionType.displayName)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .onDrop(of: [.sidebarSectionID], isTargeted: sectionDropTargetBinding(for: sectionType)) { providers in
                handleSectionHeaderDrop(providers: providers, targetSection: sectionType)
            }
            .overlay(alignment: .top) {
                if sectionDropTarget == sectionType {
                    SectionDropIndicatorLine()
                }
            }
        }
    }

    /// Wraps section content in a collapsible Section with a SELECTABLE header.
    /// Used for Inbox where clicking the header text selects the section (shows all papers).
    /// The disclosure triangle still handles expand/collapse.
    @ViewBuilder
    private func selectableCollapsibleSection<Content: View>(
        for sectionType: SidebarSectionType,
        tag: SidebarSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(sectionType)

        Section {
            if !isCollapsed {
                content()
            }
        } header: {
            HStack(spacing: 4) {
                // Collapse/expand button (only affects expand state, not selection)
                Button {
                    toggleSectionCollapsed(sectionType)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                // Selectable header title with unread badge
                HStack(spacing: 4) {
                    Text(sectionType.displayName)

                    // Show unread badge for Inbox
                    if sectionType == .inbox && inboxUnreadCount > 0 {
                        Text("\(inboxUnreadCount)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Select the section when clicking the title
                    selection = tag
                }

                Spacer()

                // Additional header content based on section type
                sectionHeaderExtras(for: sectionType)
            }
            .contentShape(Rectangle())
            .draggable(SectionDragItem(type: sectionType)) {
                HStack {
                    Image(systemName: sectionType.icon)
                    Text(sectionType.displayName)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            // Allow dropping sections (reorder), feeds, and exploration searches on header
            .onDrop(of: [.sidebarSectionID, .inboxFeedID, .explorationSearchID], isTargeted: sectionDropTargetBinding(for: sectionType)) { providers in
                // Handle section reorder drops
                if providers.first?.hasItemConformingToTypeIdentifier(UTType.sidebarSectionID.identifier) == true {
                    return handleSectionHeaderDrop(providers: providers, targetSection: sectionType)
                }

                // Handle inbox feed/search drops (only on Inbox section)
                guard sectionType == .inbox else { return false }
                var handled = false

                for provider in providers {
                    // Handle inbox feed drops (move to top level)
                    if provider.hasItemConformingToTypeIdentifier(UTType.inboxFeedID.identifier) {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.inboxFeedID.identifier) { data, _ in
                            guard let data = data,
                                  let uuidString = String(data: data, encoding: .utf8),
                                  let feedID = UUID(uuidString: uuidString) else { return }
                            Task { @MainActor in
                                if let feed = inboxFeeds.first(where: { $0.id == feedID }) {
                                    moveFeedToCollection(feed, collection: nil)
                                }
                            }
                        }
                        handled = true
                    }
                    // Handle exploration search drops (convert to feed)
                    else if provider.hasItemConformingToTypeIdentifier(UTType.explorationSearchID.identifier) {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.explorationSearchID.identifier) { data, _ in
                            guard let data = data,
                                  let uuidString = String(data: data, encoding: .utf8),
                                  let searchID = UUID(uuidString: uuidString) else { return }
                            Task { @MainActor in
                                convertExplorationSearchToInboxFeed(searchID, inCollection: nil)
                            }
                        }
                        handled = true
                    }
                }
                return handled
            }
            .overlay(alignment: .top) {
                if sectionDropTarget == sectionType {
                    SectionDropIndicatorLine()
                }
            }
        }
    }

    /// Toggle collapsed state for a section
    private func toggleSectionCollapsed(_ sectionType: SidebarSectionType) {
        if collapsedSections.contains(sectionType) {
            collapsedSections.remove(sectionType)
        } else {
            collapsedSections.insert(sectionType)
        }
        // Persist
        Task {
            await SidebarCollapsedStateStore.shared.save(collapsedSections)
        }
    }

    /// Additional header content for specific section types
    @ViewBuilder
    private func sectionHeaderExtras(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            HStack(spacing: 6) {
                // Retention dropdown menu
                Menu {
                    ForEach(AgeLimitPreset.allCases, id: \.self) { preset in
                        Button {
                            Task {
                                await InboxSettingsStore.shared.updateAgeLimit(preset)
                                await state.loadInboxSettings()
                            }
                        } label: {
                            if preset == state.inboxAgeLimit {
                                Label(preset.displayName, systemImage: "checkmark")
                            } else {
                                Text(preset.displayName)
                            }
                        }
                    }
                } label: {
                    Text(inboxRetentionLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change how long papers stay in Inbox")

                // Add feed/collection menu - creates feeds or collections for organizing
                Menu {
                    // New Collection option
                    Button {
                        createInboxRootCollection()
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }

                    Divider()

                    Button {
                        // Navigate to arXiv Feed form in Search section
                        selection = .searchForm(.arxivFeed)
                    } label: {
                        Label("arXiv Category Feed", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    Button {
                        // Navigate to Group Feed form in Search section
                        selection = .searchForm(.arxivGroupFeed)
                    } label: {
                        Label("arXiv Group Feed", systemImage: "person.3.fill")
                    }

                    Divider()

                    Button {
                        // Navigate to SciX Search form in Search section
                        selection = .searchForm(.adsModern)
                    } label: {
                        Label("SciX Search", systemImage: "magnifyingglass")
                    }

                    Button {
                        // Navigate to ADS Classic form in Search section
                        selection = .searchForm(.adsClassic)
                    } label: {
                        Label("ADS Classic Search", systemImage: "list.bullet.rectangle")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .help("Add collection or feed to Inbox")
            }
        case .libraries:
            // Add library button
            Button {
                state.showNewLibrary()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Add Library")
        case .exploration:
            // Retention label + navigation buttons + selection count
            HStack(spacing: 4) {
                // Retention dropdown menu
                Menu {
                    ForEach(ExplorationRetention.allCases, id: \.self) { retention in
                        Button {
                            SyncedSettingsStore.shared.explorationRetention = retention
                            state.triggerRefresh()
                        } label: {
                            if retention == SyncedSettingsStore.shared.explorationRetention {
                                Label(retention.displayName, systemImage: "checkmark")
                            } else {
                                Text(retention.displayName)
                            }
                        }
                    }
                } label: {
                    Text(explorationRetentionLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change how long exploration results are kept")

                // Back/forward navigation buttons
                NavigationButtonBar(
                    navigationHistory: NavigationHistoryStore.shared,
                    onBack: { NotificationCenter.default.post(name: .navigateBack, object: nil) },
                    onForward: { NotificationCenter.default.post(name: .navigateForward, object: nil) }
                )

                // Show selection count when multi-selected
                if state.explorationSelection.selectedIDs.count > 1 {
                    Text("\(state.explorationSelection.selectedIDs.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .dismissed:
            // Empty dismissed button
            Button {
                emptyDismissed()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Empty Dismissed")
        default:
            EmptyView()
        }
    }

    /// Libraries section content (without Section wrapper)
    @ViewBuilder
    private var librariesSectionContent: some View {
        // Cache libraries to avoid re-fetch race conditions during drag
        let librariesSnapshot = libraryManager.libraries.filter { !$0.isInbox && !$0.isDismissedLibrary }

        ForEach(librariesSnapshot, id: \.id) { library in
            // Library header row
            libraryHeaderRow(for: library)

            // Children (when expanded) - rendered inside iteration, doesn't affect ForEach indices
            if expandedLibraries.contains(library.id) {
                libraryChildrenContent(for: library)
            }
        }
        .onInsert(of: [.libraryID]) { index, providers in
            handleLibraryInsert(at: index, providers: providers, libraries: librariesSnapshot)
        }
    }

    /// Convert a visual index (accounting for expanded children) to a library index
    private func libraryIndexFromVisualIndex(_ visualIndex: Int, libraries: [CDLibrary]) -> Int {
        var currentVisualIndex = 0

        for (libraryIndex, library) in libraries.enumerated() {
            // Check if this is the target position (before this library)
            if currentVisualIndex >= visualIndex {
                return libraryIndex
            }

            // Count the library header
            currentVisualIndex += 1

            // Count children if expanded
            if expandedLibraries.contains(library.id) {
                currentVisualIndex += countLibraryChildren(library)
            }
        }

        // Insert at end
        return libraries.count
    }

    /// Count the number of child views for an expanded library
    private func countLibraryChildren(_ library: CDLibrary) -> Int {
        var count = 0

        // Smart searches
        let smartSearches = smartSearchRepository.smartSearches.filter { $0.library?.id == library.id }
        count += smartSearches.count

        // Collections (visible ones based on expansion state)
        if let collections = library.collections as? Set<CDCollection>, !collections.isEmpty {
            let flatCollections = flattenedLibraryCollections(from: collections, libraryID: library.id)
            let visibleCollections = filterVisibleLibraryCollections(flatCollections, libraryID: library.id)
            count += visibleCollections.count

            // "Drop here to move to root" text if any collection has a parent
            if flatCollections.contains(where: { $0.parentCollection != nil }) {
                count += 1
            }
        }

        return count
    }

    /// Handle library reordering via drag-and-drop (.onInsert)
    private func handleLibraryInsert(at targetIndex: Int, providers: [NSItemProvider], libraries: [CDLibrary]) {
        DragReorderHandler.handleInsert(
            at: targetIndex,
            providers: providers,
            typeIdentifier: UTType.libraryID.identifier,
            items: libraries,
            extractID: { data in
                String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
            },
            completion: { reordered in
                for (index, lib) in reordered.enumerated() {
                    lib.sortOrder = Int16(index)
                }
                try? PersistenceController.shared.viewContext.save()
                state.triggerRefresh()
            }
        )
    }

    /// Handle library dropped on another library (reorder by inserting before target)
    private func handleLibraryDropOnLibrary(providers: [NSItemProvider], targetLibrary: CDLibrary) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.libraryID.identifier) { data, _ in
            guard let data = data,
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString) else { return }

            Task { @MainActor in
                // Don't reorder if dropping on self
                guard draggedID != targetLibrary.id else { return }

                var libraries = libraryManager.libraries.filter { !$0.isInbox && !$0.isDismissedLibrary }
                guard let sourceIndex = libraries.firstIndex(where: { $0.id == draggedID }),
                      let targetIndex = libraries.firstIndex(where: { $0.id == targetLibrary.id }) else { return }

                // Remove from source
                let library = libraries.remove(at: sourceIndex)

                // Insert before target (adjust index if source was before target)
                let insertIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                libraries.insert(library, at: insertIndex)

                // Update sort order
                for (index, lib) in libraries.enumerated() {
                    lib.sortOrder = Int16(index)
                }
                try? PersistenceController.shared.viewContext.save()
                state.triggerRefresh()
            }
        }
    }

    /// SciX Libraries section content (without Section wrapper)
    @ViewBuilder
    private var scixLibrariesSectionContent: some View {
        // Cache the libraries to avoid re-fetch race conditions during drag
        let librariesSnapshot = scixRepository.libraries

        ForEach(librariesSnapshot, id: \.id) { library in
            scixLibraryRow(for: library)
                .draggable(SciXLibraryDragItem(id: library.id)) {
                    HStack {
                        Image(systemName: "cloud")
                            .foregroundStyle(.blue)
                        Text(library.displayName)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
        }
        .onInsert(of: [.scixLibraryID]) { index, providers in
            handleSciXLibraryReorder(at: index, providers: providers, libraries: librariesSnapshot)
        }
    }

    /// Handle SciX library reordering via drag-and-drop
    private func handleSciXLibraryReorder(at targetIndex: Int, providers: [NSItemProvider], libraries: [CDSciXLibrary]) {
        DragReorderHandler.handleInsert(
            at: targetIndex,
            providers: providers,
            typeIdentifier: UTType.scixLibraryID.identifier,
            items: libraries,
            extractID: { data in
                String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
            },
            completion: { reordered in
                scixRepository.updateSortOrder(reordered)
            }
        )
    }

    /// Search section content (without Section wrapper)
    @ViewBuilder
    private var searchSectionContent: some View {
        // Cache visible forms to avoid re-fetch race conditions during drag
        let formsSnapshot = visibleSearchForms

        // Visible search forms in user-defined order
        ForEach(formsSnapshot) { formType in
            Label(formType.displayName, systemImage: formType.icon)
                .tag(SidebarSection.searchForm(formType))
                .draggable(SearchFormDragItem(type: formType)) {
                    Label(formType.displayName, systemImage: formType.icon)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    Button("Hide") {
                        hideSearchForm(formType)
                    }
                }
        }
        .onInsert(of: [.searchFormID]) { index, providers in
            handleSearchFormInsert(at: index, providers: providers, forms: formsSnapshot)
        }

        // Show hidden forms menu if any are hidden
        if !hiddenSearchForms.isEmpty {
            Menu {
                ForEach(Array(hiddenSearchForms).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { formType in
                    Button("Show \(formType.displayName)") {
                        showSearchForm(formType)
                    }
                }

                Divider()

                Button("Show All") {
                    showAllSearchForms()
                }
            } label: {
                Label("Show Hidden Forms...", systemImage: "eye")
            }
        }
    }

    /// Get visible search forms in order
    private var visibleSearchForms: [SearchFormType] {
        searchFormOrder.filter { formType in
            // Skip if form is hidden by user
            if hiddenSearchForms.contains(formType) { return false }
            // Skip forms that require ADS credentials when not available
            if formType.requiresADSCredentials && !state.hasSciXAPIKey { return false }
            return true
        }
    }

    // MARK: - Retention Labels

    /// Label showing the current Inbox retention setting
    private var inboxRetentionLabel: String {
        let ageLimit = state.inboxAgeLimit
        return ageLimit == .unlimited ? "∞" : ageLimit.displayName
    }

    /// Label showing the current Exploration retention setting
    private var explorationRetentionLabel: String {
        let retention = SyncedSettingsStore.shared.explorationRetention
        return retention.displayName.lowercased()
    }

    /// Handle search form reordering via drag-and-drop (.onInsert)
    private func handleSearchFormInsert(at targetIndex: Int, providers: [NSItemProvider], forms: [SearchFormType]) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.searchFormID.identifier) { data, _ in
            guard let data = data,
                  let rawValue = String(data: data, encoding: .utf8),
                  let draggedType = SearchFormType(rawValue: rawValue) else { return }

            Task { @MainActor in
                var reordered = forms
                guard let sourceIndex = reordered.firstIndex(of: draggedType) else { return }

                // Calculate destination accounting for removal
                let destinationIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                let clampedDestination = max(0, min(destinationIndex, reordered.count - 1))

                // Perform the move
                let form = reordered.remove(at: sourceIndex)
                reordered.insert(form, at: clampedDestination)

                // Rebuild the full order preserving hidden forms in their relative positions
                var newOrder: [SearchFormType] = []
                var visibleIndex = 0

                for formType in searchFormOrder {
                    if hiddenSearchForms.contains(formType) {
                        // Keep hidden forms in their current relative position
                        newOrder.append(formType)
                    } else {
                        // Insert visible forms in their new order
                        if visibleIndex < reordered.count {
                            newOrder.append(reordered[visibleIndex])
                            visibleIndex += 1
                        }
                    }
                }

                // Add any remaining visible forms
                while visibleIndex < reordered.count {
                    newOrder.append(reordered[visibleIndex])
                    visibleIndex += 1
                }

                withAnimation {
                    searchFormOrder = newOrder
                }

                Task {
                    await SearchFormStore.shared.save(newOrder)
                }
            }
        }
    }

    /// Hide a search form
    private func hideSearchForm(_ formType: SearchFormType) {
        withAnimation {
            hiddenSearchForms.insert(formType)
        }
        Task {
            await SearchFormStore.shared.hide(formType)
        }
    }

    /// Show a hidden search form
    private func showSearchForm(_ formType: SearchFormType) {
        withAnimation {
            hiddenSearchForms.remove(formType)
        }
        Task {
            await SearchFormStore.shared.show(formType)
        }
    }

    /// Show all hidden search forms
    private func showAllSearchForms() {
        withAnimation {
            hiddenSearchForms.removeAll()
        }
        Task {
            await SearchFormStore.shared.setHidden([])
        }
    }

    /// Smart searches in the exploration library (searches executed from Search section)
    private var explorationSmartSearches: [CDSmartSearch] {
        guard let library = libraryManager.explorationLibrary,
              let searches = library.smartSearches else { return [] }
        // Sort by user-defined order, falling back to dateCreated for new searches
        return Array(searches).sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.dateCreated > $1.dateCreated
        }
    }

    /// Exploration section content (without Section wrapper)
    @ViewBuilder
    private var explorationSectionContent: some View {
        // Cache searches to avoid re-fetch race conditions during drag
        let searchesSnapshot = explorationSmartSearches

        // Search results from Search section (smart searches in exploration library)
        ForEach(searchesSnapshot) { smartSearch in
            explorationSearchRow(smartSearch)
        }
        .onInsert(of: [.explorationSearchID]) { index, providers in
            handleExplorationSearchInsert(at: index, providers: providers, searches: searchesSnapshot)
        }

        // Exploration collections (Refs, Cites, Similar, Co-Reads) - hierarchical tree display
        if let library = libraryManager.explorationLibrary,
           let collections = library.collections,
           !collections.isEmpty {
            // Add separator if both searches and collections exist
            if !explorationSmartSearches.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }

            // Get flattened list for multi-selection range calculations
            let allCollections = flattenedExplorationCollections(from: collections)

            // Create root adapters (TreeFlattener will recurse into children)
            let rootAdapters = explorationRootCollections(from: collections)
                .map { ExplorationCollectionAdapter(collection: $0, allCollections: allCollections) }

            // Flatten tree using TreeFlattener (handles visibility and sibling info)
            let flattenedNodes = rootAdapters.flattened(
                children: { adapter in
                    adapter.collection.sortedChildren
                        .filter { !$0.isSmartSearchResults }
                        .map { ExplorationCollectionAdapter(collection: $0, allCollections: allCollections) }
                },
                isExpanded: { state.expandedExplorationCollections.contains($0.id) }
            )

            ForEach(flattenedNodes) { flattenedNode in
                let collection = flattenedNode.node.collection
                let isMultiSelected = state.explorationSelection.selectedIDs.contains(collection.id)

                GenericTreeRow(
                    flattenedNode: flattenedNode,
                    capabilities: .explorationCollection,
                    isExpanded: Binding(
                        get: { state.expandedExplorationCollections.contains(collection.id) },
                        set: { isExpanded in
                            if isExpanded {
                                state.expandedExplorationCollections.insert(collection.id)
                            } else {
                                state.expandedExplorationCollections.remove(collection.id)
                            }
                        }
                    ),
                    isMultiSelected: isMultiSelected
                )
                .tag(SidebarSection.collection(collection))
                .onTapGesture {
                    handleExplorationCollectionClick(collection, allCollections: allCollections)
                }
                .contextMenu {
                    if state.explorationSelection.selectedIDs.count > 1 && state.explorationSelection.selectedIDs.contains(collection.id) {
                        Button("Delete \(state.explorationSelection.selectedIDs.count) Items", role: .destructive) {
                            deleteSelectedExplorationCollections()
                        }
                    } else {
                        Button("Delete", role: .destructive) {
                            deleteExplorationCollection(collection)
                        }
                    }
                }
            }
        }
    }

    /// Get root collections for exploration (excluding smart search results)
    private func explorationRootCollections(from collections: Set<CDCollection>) -> [CDCollection] {
        Array(collections)
            .filter { $0.parentCollection == nil && !$0.isSmartSearchResults }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }
    }

    /// Handle click on exploration collection with modifier detection for multi-selection
    private func handleExplorationCollectionClick(_ collection: CDCollection, allCollections: [CDCollection]) {
        let orderedIDs = allCollections.map(\.id)
        let action = state.explorationSelection.handleClick(collection.id, orderedIDs: orderedIDs)
        if case .single = action {
            selection = .collection(collection)
        }
    }

    /// Shared With Me section content
    @ViewBuilder
    private var sharedWithMeSectionContent: some View {
        ForEach(libraryManager.sharedWithMeLibraries, id: \.id) { library in
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                Text(library.displayName)
                    .lineLimit(1)
                Spacer()
                #if canImport(CloudKit)
                if !library.canEdit {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Read Only")
                }
                #endif
                ActivityBadge(library: library)
                let count = library.publications?.count ?? 0
                if count > 0 {
                    CountBadge(count: count)
                }
            }
            .tag(SidebarSection.library(library))
            .contextMenu {
                Button {
                    state.activityFeedLibrary = library
                } label: {
                    Label("View Activity", systemImage: "clock")
                }

                Button {
                    state.assignmentLibrary = library
                } label: {
                    Label("Reading Suggestions", systemImage: "bookmark")
                }

                Button {
                    state.citationGraphLibrary = library
                } label: {
                    Label("Citation Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }

                #if canImport(CloudKit)
                Button {
                    state.sharedLibraryToManage = library
                } label: {
                    Label("Manage Participants...", systemImage: "person.2")
                }
                #endif

                Divider()

                #if canImport(CloudKit)
                Button {
                    Task {
                        try? await CloudKitSharingService.shared.leaveShare(library, keepCopy: true)
                    }
                } label: {
                    Label("Leave and Keep Copy", systemImage: "rectangle.portrait.and.arrow.right")
                }

                Button(role: .destructive) {
                    Task {
                        try? await CloudKitSharingService.shared.leaveShare(library, keepCopy: false)
                    }
                } label: {
                    Label("Remove Shared Library", systemImage: "trash")
                }
                #endif
            }
        }
    }

    // MARK: - Flagged Section

    @ViewBuilder
    private var flaggedSectionContent: some View {
        // "Any Flag" item (always first, not draggable)
        HStack {
            Label("Any Flag", systemImage: "flag.fill")
            Spacer()
            if state.flagCounts.total > 0 {
                CountBadge(count: state.flagCounts.total)
            }
        }
        .tag(SidebarSection.flagged(nil))

        // Individual flag colors (reorderable)
        ForEach(flagColorOrder) { color in
            HStack {
                Label(color.displayName, systemImage: "flag.fill")
                    .foregroundStyle(flagDisplayColor(color.rawValue))
                Spacer()
                let count = state.flagCounts.byColor[color.rawValue] ?? 0
                if count > 0 {
                    CountBadge(count: count)
                }
            }
            .tag(SidebarSection.flagged(color.rawValue))
            .draggable(FlagColorDragItem(color: color)) {
                Label(color.displayName, systemImage: "flag.fill")
                    .foregroundStyle(flagDisplayColor(color.rawValue))
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onInsert(of: [.flagColorID]) { index, providers in
            handleFlagColorInsert(at: index, providers: providers)
        }
    }

    /// Map flag color name to SwiftUI Color for sidebar display
    private func flagDisplayColor(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "amber": return .orange
        case "blue": return .blue
        case "gray": return .gray
        default: return .primary
        }
    }


    @ViewBuilder
    private var dismissedSectionContent: some View {
        if let dismissedLibrary = libraryManager.dismissedLibrary {
            let count = dismissedLibrary.publications?.count ?? 0

            HStack {
                Label("All Dismissed", systemImage: "trash")
                Spacer()
                if count > 0 {
                    CountBadge(count: count)
                }
            }
            .tag(SidebarSection.library(dismissedLibrary))
            .contextMenu {
                Button("Empty Dismissed", role: .destructive) {
                    state.showEmptyDismissedConfirmation = true
                }
            }
        }
    }

    /// Empty dismissed library
    private func emptyDismissed() {
        state.showEmptyDismissedConfirmation = true
    }

    /// Row for a search smart search in the exploration section
    @ViewBuilder
    private func explorationSearchRow(_ smartSearch: CDSmartSearch) -> some View {
        // Guard against deleted Core Data objects
        if smartSearch.managedObjectContext == nil {
            EmptyView()
        } else {
            explorationSearchRowContent(smartSearch)
        }
    }

    @ViewBuilder
    private func explorationSearchRowContent(_ smartSearch: CDSmartSearch) -> some View {
        let isSelected = selection == .smartSearch(smartSearch)
        let isMultiSelected = state.searchSelection.selectedIDs.contains(smartSearch.id)
        let count = smartSearch.resultCollection?.publications?.count ?? 0
        // Strip "Search: " prefix if present (legacy naming)
        let displayName = smartSearch.name.hasPrefix("Search: ")
            ? String(smartSearch.name.dropFirst(8))
            : smartSearch.name

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.purple)
                .frame(width: 16)

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .tag(SidebarSection.smartSearch(smartSearch))
        .draggable(ExplorationSearchDragItem(id: smartSearch.id)) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.purple)
                Text(displayName)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .listRowBackground(
            isMultiSelected || isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
        .contextMenu {
            // Show batch delete if multiple searches selected
            if state.searchSelection.selectedIDs.count > 1 {
                Button("Delete \(state.searchSelection.selectedIDs.count) Searches", role: .destructive) {
                    deleteSelectedSmartSearches()
                }
            } else {
                if let (url, label) = webURL(for: smartSearch) {
                    Button(label) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Edit Search...") {
                    // Navigate to Search section with this smart search's query
                    NotificationCenter.default.post(name: .editSmartSearch, object: smartSearch.id)
                }

                Divider()

                Button("Delete", role: .destructive) {
                    SmartSearchRepository.shared.delete(smartSearch)
                    if selection == .smartSearch(smartSearch) {
                        selection = nil
                    }
                    state.searchSelection.selectedIDs.remove(smartSearch.id)
                    state.triggerExplorationRefresh()
                }
            }
        }
    }

    /// Handle click on smart search row with modifier detection
    private func handleSearchRowClick(smartSearch: CDSmartSearch) {
        let orderedIDs = explorationSmartSearches.map(\.id)
        let action = state.searchSelection.handleClick(smartSearch.id, orderedIDs: orderedIDs)
        if case .single = action {
            selection = .smartSearch(smartSearch)
        }
    }

    /// Delete all selected smart searches
    private func deleteSelectedSmartSearches() {
        // Collect items to delete BEFORE clearing selection (avoid mutating during iteration)
        let searchesToDelete = explorationSmartSearches.filter { state.searchSelection.selectedIDs.contains($0.id) }

        // Clear main selection if any selected search is being deleted
        if case .smartSearch(let selected) = selection,
           state.searchSelection.selectedIDs.contains(selected.id) {
            selection = nil
        }

        // Clear multi-selection BEFORE deleting to prevent view crashes
        state.clearSearchSelection()

        // Now delete the collected items
        for smartSearch in searchesToDelete {
            SmartSearchRepository.shared.delete(smartSearch)
        }

        state.triggerExplorationRefresh()
    }

    /// Handle exploration search reordering via drag-and-drop (.onInsert)
    private func handleExplorationSearchInsert(at targetIndex: Int, providers: [NSItemProvider], searches: [CDSmartSearch]) {
        DragReorderHandler.handleInsert(
            at: targetIndex,
            providers: providers,
            typeIdentifier: UTType.explorationSearchID.identifier,
            items: searches,
            extractID: { data in
                String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
            },
            completion: { reordered in
                for (index, s) in reordered.enumerated() {
                    s.order = Int16(index)
                }
                try? PersistenceController.shared.viewContext.save()
                state.triggerExplorationRefresh()
            }
        )
    }

    /// Delete all selected exploration collections
    private func deleteSelectedExplorationCollections() {
        // Collect items to delete BEFORE clearing selection (avoid mutating during iteration)
        var collectionsToDelete: [CDCollection] = []
        if let library = libraryManager.explorationLibrary,
           let collections = library.collections {
            collectionsToDelete = collections.filter { state.explorationSelection.selectedIDs.contains($0.id) }
        }

        // Clear main selection if any selected collection is being deleted
        if case .collection(let selected) = selection,
           state.explorationSelection.selectedIDs.contains(selected.id) {
            selection = nil
        }

        // Clear multi-selection BEFORE deleting to prevent view crashes
        state.clearExplorationSelection()

        // Now delete the collected items
        for collection in collectionsToDelete {
            libraryManager.deleteExplorationCollection(collection)
        }

        state.triggerExplorationRefresh()
    }

    /// Determine the SF Symbol icon for an exploration collection based on its name prefix.
    ///
    /// - "Refs:" → arrow.down.doc (papers this paper cites)
    /// - "Cites:" → arrow.up.doc (papers citing this paper)
    /// - "Similar:" → doc.on.doc (related papers by content)
    /// - "Co-Reads:" → person.2.fill (papers frequently read together)
    private func explorationIcon(for collection: CDCollection) -> String {
        if collection.name.hasPrefix("Refs:") { return "arrow.down.doc" }
        if collection.name.hasPrefix("Cites:") { return "arrow.up.doc" }
        if collection.name.hasPrefix("Similar:") { return "doc.on.doc" }
        if collection.name.hasPrefix("Co-Reads:") { return "person.2.fill" }
        return "doc.text.magnifyingglass"
    }

    /// Check if this collection is the last child of its parent.
    private func isLastChild(_ collection: CDCollection, in allCollections: [CDCollection]) -> Bool {
        guard let parentID = collection.parentCollection?.id else {
            // Root level - check if it's the last root
            let rootCollections = allCollections.filter { $0.parentCollection == nil }
            return rootCollections.last?.id == collection.id
        }

        // Find siblings (children of the same parent)
        let siblings = allCollections.filter { $0.parentCollection?.id == parentID }
        return siblings.last?.id == collection.id
    }

    /// Check if an ancestor at the given depth level has siblings after it.
    /// Used to determine whether to draw a vertical tree line at that level.
    private func hasAncestorSiblingBelow(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> Bool {
        // Walk up the tree to the ancestor at the specified level
        var current: CDCollection? = collection
        var currentLevel = Int(collection.depth)

        while currentLevel > level, let c = current {
            current = c.parentCollection
            currentLevel -= 1
        }

        // Check if this ancestor has siblings below it
        guard let ancestor = current else { return false }
        return !isLastChild(ancestor, in: allCollections)
    }

    /// Flatten collection hierarchy into a list with proper ordering
    /// Excludes smart search result collections (they're shown as smart search rows instead)
    private func flattenedExplorationCollections(from collections: Set<CDCollection>) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            // Skip smart search result collections - they're displayed as smart search rows
            guard !collection.isSmartSearchResults else { return }

            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        // Start with root collections (excluding smart search results), sorted by sortOrder then name
        let rootCollections = Array(collections)
            .filter { $0.parentCollection == nil && !$0.isSmartSearchResults }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }

        for collection in rootCollections {
            addWithChildren(collection)
        }

        return result
    }

    /// Filter flattened collections to show only visible ones based on expanded state.
    /// A collection is visible if all its ancestors are expanded.
    private func filterVisibleCollections(_ collections: [CDCollection]) -> [CDCollection] {
        collections.filter { collection in
            // Root collections are always visible
            guard collection.parentCollection != nil else { return true }

            // Check if all ancestors are expanded
            for ancestor in collection.ancestors {
                if !state.expandedExplorationCollections.contains(ancestor.id) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Library Collection Helpers

    /// Flatten library collections into ordered list respecting hierarchy
    private func flattenedLibraryCollections(from collections: Set<CDCollection>, libraryID: UUID) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        // Start with root collections (no parent), sorted by sortOrder then name
        let rootCollections = Array(collections)
            .filter { $0.parentCollection == nil }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }

        for collection in rootCollections {
            addWithChildren(collection)
        }

        return result
    }

    /// Filter to only visible collections (ancestors expanded)
    private func filterVisibleLibraryCollections(_ collections: [CDCollection], libraryID: UUID) -> [CDCollection] {
        let expandedSet = state.expandedLibraryCollections[libraryID] ?? []
        return collections.filter { collection in
            // Root collections are always visible
            guard collection.parentCollection != nil else { return true }

            // Check if all ancestors are expanded
            for ancestor in collection.ancestors {
                if !expandedSet.contains(ancestor.id) {
                    return false
                }
            }
            return true
        }
    }

    /// Create a binding for library collection expansion state
    private func expandedLibraryCollectionsBinding(for libraryID: UUID) -> Binding<Set<UUID>> {
        Binding(
            get: { state.expandedLibraryCollections[libraryID] ?? [] },
            set: { state.expandedLibraryCollections[libraryID] = $0 }
        )
    }

    // NOTE: The old explorationCollectionRow and ExplorationTreeRow have been replaced
    // by GenericTreeRow with ExplorationCollectionAdapter for unified tree rendering.

    /// Delete an exploration collection
    private func deleteExplorationCollection(_ collection: CDCollection) {
        // Clear selection if this collection is selected
        if case .collection(let selected) = selection, selected.id == collection.id {
            selection = nil
        }

        libraryManager.deleteExplorationCollection(collection)
        state.triggerExplorationRefresh()
    }

    /// Expand all ancestors of a collection to make it visible in the tree
    private func expandAncestors(of collection: CDCollection) {
        for ancestor in collection.ancestors {
            state.expandedExplorationCollections.insert(ancestor.id)
        }
    }

    // MARK: - Section Reordering

    /// Handle section reordering when a section is dropped on another section's header.
    /// Returns true if the drop was handled.
    @discardableResult
    private func handleSectionHeaderDrop(providers: [NSItemProvider], targetSection: SidebarSectionType) -> Bool {
        let result = SectionDragReorder.handleDrop(
            providers: providers,
            typeIdentifier: UTType.sidebarSectionID.identifier,
            targetSection: targetSection,
            currentOrder: sectionOrder
        ) { [self] newOrder in
            withAnimation {
                sectionOrder = newOrder
            }
            Task { await SidebarSectionOrderStore.shared.save(newOrder) }
        }
        sectionDropTarget = nil
        return result
    }

    /// Binding that tracks whether a specific section header is the current drop target.
    private func sectionDropTargetBinding(for sectionType: SidebarSectionType) -> Binding<Bool> {
        .optionalEquality(source: $sectionDropTarget, equals: sectionType)
    }

    // MARK: - Library Expandable Row

    /// Check if library has any visible children (smart searches or collections).
    private func libraryHasChildren(_ library: CDLibrary) -> Bool {
        let hasSmartSearches = smartSearchRepository.smartSearches.contains { $0.library?.id == library.id }
        let hasCollections = (library.collections as? Set<CDCollection>)?.isEmpty == false
        return hasSmartSearches || hasCollections
    }

    /// Library header row (without children).
    /// Uses flat structure similar to collection rows so List selection works properly.
    @ViewBuilder
    private func libraryHeaderRow(for library: CDLibrary) -> some View {
        let isExpanded = expandedLibraries.contains(library.id)
        let hasChildren = libraryHasChildren(library)

        HStack(spacing: 4) {
            // Disclosure triangle
            if hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedLibraries.remove(library.id)
                        } else {
                            expandedLibraries.insert(library.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            } else {
                // Spacer to align with items that have disclosure triangles
                Color.clear.frame(width: 16, height: 16)
            }

            // Library icon and name
            libraryHeaderDropTarget(for: library)

            Spacer()

            // + menu for adding collections
            Menu {
                Button {
                    state.showNewSmartCollection(for: library)
                } label: {
                    Label("New Smart Collection", systemImage: "folder.badge.gearshape")
                }
                Button {
                    createStaticCollection(in: library)
                } label: {
                    Label("New Collection", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
        .contentShape(Rectangle())
        .tag(SidebarSection.library(library))
        .contextMenu {
            #if os(macOS)
            // CloudKit sharing
            Button {
                state.itemToShareViaICloud = .library(library)
            } label: {
                Label("Share via iCloud...", systemImage: "person.badge.plus")
            }

            Divider()

            // Native sharing via AirDrop, Messages, etc.
            ShareLink(
                item: ShareablePublications(
                    publications: (library.publications ?? [])
                        .filter { !$0.isDeleted }
                        .map { ShareablePublication(from: $0) },
                    libraryName: library.displayName
                ),
                preview: SharePreview(
                    library.displayName,
                    image: Image(systemName: "books.vertical")
                )
            ) {
                Label("Share Library...", systemImage: "square.and.arrow.up")
            }

            Button {
                NotificationCenter.default.post(
                    name: .showUnifiedExport,
                    object: nil,
                    userInfo: ["library": library]
                )
            } label: {
                Label("Export...", systemImage: "square.and.arrow.up.on.square")
            }

            Button {
                NotificationCenter.default.post(
                    name: .showUnifiedImport,
                    object: nil,
                    userInfo: ["library": library]
                )
            } label: {
                Label("Import...", systemImage: "square.and.arrow.down")
            }

            Divider()
            #endif
            Button("Delete Library", role: .destructive) {
                state.libraryToDelete = library
                state.showDeleteConfirmation = true
            }
        }
        .draggable(LibraryDragItem(id: library.id)) {
            Label(library.displayName, systemImage: "building.columns")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Library children content (smart searches and collections).
    /// Separated to keep expandableLibraryRow clean.
    @ViewBuilder
    private func libraryChildrenContent(for library: CDLibrary) -> some View {
        // Smart Searches for this library (use repository for change observation)
        let librarySmartSearches = smartSearchRepository.smartSearches.filter { $0.library?.id == library.id }
        if !librarySmartSearches.isEmpty {
            ForEach(librarySmartSearches.sorted(by: { $0.name < $1.name }), id: \.id) { smartSearch in
                SmartSearchRow(smartSearch: smartSearch, count: resultCount(for: smartSearch))
                    .padding(.leading, 16)  // Indent children
                    .tag(SidebarSection.smartSearch(smartSearch))
                    .contextMenu {
                        Button("Edit") {
                            // Navigate to Search section with this smart search's query
                            NotificationCenter.default.post(name: .editSmartSearch, object: smartSearch.id)
                        }
                        Button("Delete", role: .destructive) {
                            deleteSmartSearch(smartSearch)
                        }
                    }
            }
        }

        // Collections for this library (hierarchical)
        // NOTE: Using filterVisibleLibraryCollections instead of TreeFlattener
        // because FlattenedTreeNode wrappers cause identity issues with List/OutlineView
        // during drag operations (crashes in performDropInsertion).
        if let collections = library.collections as? Set<CDCollection>, !collections.isEmpty {
            let flatCollections = flattenedLibraryCollections(from: collections, libraryID: library.id)
            let visibleCollections = filterVisibleLibraryCollections(flatCollections, libraryID: library.id)

            ForEach(visibleCollections, id: \.id) { collection in
                libraryCollectionRow(
                    collection: collection,
                    allCollections: flatCollections,
                    library: library
                )
            }
            .onInsert(of: [.collectionID]) { index, providers in
                handleCollectionInsert(at: index, providers: providers, visibleCollections: visibleCollections, library: library)
            }

            // Drop zone at library level to move collections back to root
            if flatCollections.contains(where: { $0.parentCollection != nil }) {
                Text("Drop here to move to root")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onDrop(of: [.collectionID], isTargeted: nil) { providers in
                        handleCollectionDropToRoot(providers: providers, library: library)
                    }
            }
        }
    }

    /// Renders a single library collection row.
    /// Uses a simple inline approach rather than GenericTreeRow to avoid
    /// FlattenedTreeNode identity issues during drag operations.
    @ViewBuilder
    private func libraryCollectionRow(
        collection: CDCollection,
        allCollections: [CDCollection],
        library: CDLibrary
    ) -> some View {
        let isEditing = state.renamingCollection?.id == collection.id
        let expandedSet = state.expandedLibraryCollections[library.id] ?? []
        let isExpanded = expandedSet.contains(collection.id)

        HStack(spacing: 0) {
            // Tree indentation with lines
            ForEach(0..<collection.depth, id: \.self) { level in
                treeLineForCollection(collection, at: level, in: allCollections)
            }

            // Disclosure triangle
            if collection.hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            state.expandedLibraryCollections[library.id, default: []].remove(collection.id)
                        } else {
                            state.expandedLibraryCollections[library.id, default: []].insert(collection.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            // Icon
            Image(systemName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.leading, 2)

            // Name
            if isEditing {
                TextField("Name", text: $state.renamingCollectionName)
                    .textFieldStyle(.plain)
                    .padding(.leading, 4)
                    .focused($isRenamingCollectionFocused)
                    .onSubmit {
                        renameCollection(collection, to: state.renamingCollectionName)
                    }
                    .onExitCommand {
                        // Cancel on Escape
                        state.renamingCollection = nil
                        isRenamingCollectionFocused = false
                    }
            } else {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }

            Spacer()

            // Count badge
            let count = collection.matchingPublicationCount
            if count > 0 {
                CountBadge(count: count)
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarSection.collection(collection))
        .padding(.leading, 16)
        .contextMenu {
            collectionContextMenu(collection: collection, library: library)
        }
        .onDrop(of: collection.isSmartCollection ? [] : [.publicationID, .collectionID], isTargeted: nil) { providers in
            handleCollectionDrop(providers: providers, collection: collection, allCollections: allCollections, library: library)
        }
        .draggable(CollectionDragItem(id: collection.id)) {
            Label(collection.name, systemImage: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Renders tree line for a collection at a specific indentation level.
    @ViewBuilder
    private func treeLineForCollection(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> some View {
        let ancestors = collection.ancestors
        if level == collection.depth - 1 {
            // Final level - check if this collection is last among siblings
            let isLastChild = isLastChildAtLevel(collection, in: allCollections)
            TreeLineView(
                level: level,
                depth: collection.depth,
                isLastChild: isLastChild,
                hasAncestorSiblingBelow: false
            )
        } else if level < ancestors.count {
            // Parent levels - check if ancestor at this level has siblings below
            let ancestor = ancestors[level]
            let hasSiblingsBelow = !isLastChildAtLevel(ancestor, in: allCollections)
            TreeLineView(
                level: level,
                depth: collection.depth,
                isLastChild: false,
                hasAncestorSiblingBelow: hasSiblingsBelow
            )
        } else {
            Spacer().frame(width: 16)
        }
    }

    /// Checks if a collection is the last child among its siblings.
    private func isLastChildAtLevel(_ collection: CDCollection, in allCollections: [CDCollection]) -> Bool {
        if let parent = collection.parentCollection {
            let siblings = parent.sortedChildren
            return siblings.last?.id == collection.id
        } else {
            // Root level - check among root collections
            let roots = allCollections.filter { $0.parentCollection == nil }
            return roots.last?.id == collection.id
        }
    }

    /// Context menu for a collection row.
    @ViewBuilder
    private func collectionContextMenu(collection: CDCollection, library: CDLibrary) -> some View {
        Group {
            Button("Rename") {
                // Clear any previous focus first
                isRenamingCollectionFocused = false
                // Set up rename state
                state.renamingCollectionName = collection.name
                state.renamingCollection = collection
                // Focus after TextField appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isRenamingCollectionFocused = true
                }
            }

            if collection.isSmartCollection {
                Button("Edit") {
                    state.showEditCollection(collection)
                }
            }

            // CloudKit sharing for collections
            if !collection.isSmartCollection {
                Divider()

                Button {
                    state.itemToShareViaICloud = .collection(collection)
                } label: {
                    Label("Share via iCloud...", systemImage: "person.badge.plus")
                }
            }

            Divider()

            if !collection.isSmartCollection {
                Button {
                    createStaticCollection(in: library, parent: collection)
                } label: {
                    Label("New Subcollection", systemImage: "folder.badge.plus")
                }

                Divider()
            }

            Button("Delete", role: .destructive) {
                deleteCollection(collection)
            }
        }
    }

    // MARK: - Export BibTeX

    /// Export a library to BibTeX format using a save panel.
    private func exportLibraryToBibTeX(_ library: CDLibrary) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(library.displayName).bib"
        panel.allowedContentTypes = [.init(filenameExtension: "bib")!]
        panel.canCreateDirectories = true
        panel.title = "Export Library"
        panel.message = "Choose a location to save the BibTeX file"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try libraryManager.exportToBibTeX(library, to: url)
            } catch {
                // Could show an error alert here
                print("Export failed: \(error)")
            }
        }
        #endif
    }

    // MARK: - Export/Import Mbox

    /// Export a library to mbox format using a save panel.
    private func exportLibraryToMbox(_ library: CDLibrary) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(library.displayName).mbox"
        panel.allowedContentTypes = [UTType(filenameExtension: "mbox") ?? .data]
        panel.canCreateDirectories = true
        panel.title = "Export Library as mbox"
        panel.message = "Export library with all publications, PDFs, and metadata to mbox format"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let exporter = MboxExporter(
                        context: PersistenceController.shared.viewContext,
                        options: .default
                    )
                    try await exporter.export(library: library, to: url)
                } catch {
                    await MainActor.run {
                        state.mboxExportError = error.localizedDescription
                        state.showMboxExportError = true
                    }
                }
            }
        }
        #endif
    }

    /// Prepare mbox import by parsing the file and showing preview.
    private func prepareMboxImport(from url: URL) async {
        do {
            // Start accessing security-scoped resource if needed
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let importer = MboxImporter(
                context: PersistenceController.shared.viewContext,
                options: .default
            )
            let preview = try await importer.prepareImport(from: url)

            await MainActor.run {
                // Show mbox import preview sheet
                if let targetLibrary = state.mboxImportTargetLibrary {
                    state.showMboxImportPreview(preview: preview, library: targetLibrary)
                } else {
                    // Fallback: store preview for later use
                    state.mboxImportPreview = preview
                }
            }
        } catch {
            await MainActor.run {
                state.mboxExportError = "Failed to parse mbox: \(error.localizedDescription)"
                state.showMboxExportError = true
            }
        }
    }

    /// Execute the mbox import after user confirmation.
    private func executeMboxImport(
        preview: MboxImportPreview,
        selectedIDs: Set<UUID>,
        duplicateDecisions: [UUID: DuplicateAction]
    ) async {
        do {
            let importer = MboxImporter(
                context: PersistenceController.shared.viewContext,
                options: .default
            )
            let result = try await importer.executeImport(
                preview,
                to: state.mboxImportTargetLibrary,
                selectedPublications: selectedIDs,
                duplicateDecisions: duplicateDecisions
            )

            await MainActor.run {
                state.mboxImportPreview = nil
                state.mboxImportTargetLibrary = nil

                // Log result
                print("Mbox import: \(result.importedCount) imported, \(result.mergedCount) merged, \(result.skippedCount) skipped")

                if !result.errors.isEmpty {
                    state.mboxExportError = "Import completed with \(result.errors.count) error(s)"
                    state.showMboxExportError = true
                }
            }
        } catch {
            await MainActor.run {
                state.mboxExportError = "Import failed: \(error.localizedDescription)"
                state.showMboxExportError = true
            }
        }
    }

    // MARK: - SciX Libraries Section Header

    /// Section header for SciX Libraries with help tooltip
    private var scixLibrariesSectionHeader: some View {
        HStack {
            Text("SciX Libraries")

            Spacer()

            // Help button that opens SciX libraries documentation
            Button {
                if let url = URL(string: "https://ui.adsabs.harvard.edu/help/libraries/") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                }
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Learn about SciX Libraries - click to open help page")
        }
        .help("""
            SciX Libraries are cloud-based collections synced with NASA ADS/SciX.

            • Access your libraries from any device
            • Share and collaborate with other researchers
            • Set operations: union, intersection, difference
            • Citation helper finds related papers

            Click the ? to learn more.
            """)
    }

    // MARK: - SciX Library Row

    @ViewBuilder
    private func scixLibraryRow(for library: CDSciXLibrary) -> some View {
        HStack {
            // Cloud icon (different from local libraries)
            Image(systemName: "cloud")
                .foregroundStyle(.blue)
                .help("Cloud-synced library from NASA ADS/SciX")

            Text(library.displayName)

            Spacer()

            // Permission level indicator
            Image(systemName: library.permissionLevelEnum.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(permissionTooltip(library.permissionLevelEnum))

            // Pending changes indicator
            if library.hasPendingChanges {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Changes pending sync to SciX")
            }

            // Paper count
            if library.documentCount > 0 {
                CountBadge(count: Int(library.documentCount))
            }
        }
        .tag(SidebarSection.scixLibrary(library))
        .contextMenu {
            Button {
                // Open library on SciX/ADS web interface
                if let url = URL(string: "https://ui.adsabs.harvard.edu/user/libraries/\(library.remoteID)") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                }
            } label: {
                Label("Open on SciX", systemImage: "safari")
            }

            Button {
                Task {
                    try? await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            // SciX permission sharing - requires SciX API integration (not yet implemented)
            // if library.canManagePermissions {
            //     Button { } label: { Label("Share...", systemImage: "person.2") }
            // }

            // SciX library deletion - requires SciX API integration (not yet implemented)
            // if library.permissionLevelEnum == .owner {
            //     Divider()
            //     Button(role: .destructive) { } label: { Label("Delete Library", systemImage: "trash") }
            // }
        }
    }

    // MARK: - Library Header Drop Target

    @ViewBuilder
    private func libraryHeaderDropTarget(for library: CDLibrary) -> some View {
        let count = publicationCount(for: library)
        let starredCount = library.isSaveLibrary ? starredPublicationCount(for: library) : 0
        SidebarDropTarget(
            isTargeted: state.dropTargetedLibraryHeader == library.id,
            showPlusBadge: true
        ) {
            HStack {
                Label(library.displayName, systemImage: "building.columns")
                Spacer()
                // Show starred count badge for Save library
                if starredCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("\(starredCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if count > 0 {
                    CountBadge(count: count)
                }
            }
        }
        .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID, .collectionID, .libraryID], isTargeted: makeLibraryHeaderTargetBinding(library.id)) { providers in
            dragDropLog("📦 DROP on library HEADER '\(library.displayName)' (id: \(library.id.uuidString))")
            dragDropLog("  - Provider count: \(providers.count)")
            for (i, provider) in providers.enumerated() {
                let types = provider.registeredTypeIdentifiers
                dragDropLog("  - Provider[\(i)] types: \(types.joined(separator: ", "))")
            }

            // Check for library drops first - reorder libraries
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.libraryID.identifier) }) {
                dragDropLog("  → Routing to library reorder handler")
                handleLibraryDropOnLibrary(providers: providers, targetLibrary: library)
                return true
            }

            // Auto-expand collapsed library when dropping on header
            if !expandedLibraries.contains(library.id) {
                dragDropLog("  - Auto-expanding library")
                expandedLibraries.insert(library.id)
            }

            // Check for collection drops - cross-library collection move
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) }) {
                dragDropLog("  → Routing to cross-library collection move handler")
                return handleCrossLibraryCollectionMove(providers: providers, targetLibrary: library)
            }

            // Check for BibTeX/RIS files first - these open import preview
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.bibtexUTI) }) ||
               providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.risUTI) }) {
                handleBibTeXDrop(providers, library: library)
            } else if hasFileDrops(providers) {
                dragDropLog("  → Routing to file drop handler")
                handleFileDrop(providers, libraryID: library.id)
            } else if hasURLDrops(providers) {
                dragDropLog("  → Routing to URL import handler")
                handleFileDrop(providers, libraryID: library.id)
            } else {
                dragDropLog("  → Routing to publication drop handler")
                handleDrop(providers: providers) { uuids in
                    dragDropLog("  → handleDrop completed with \(uuids.count) UUIDs")
                    Task { await addPublicationsToLibrary(uuids, library: library) }
                }
            }
            return true
        }
    }

    // MARK: - Collection Drop Target

    @ViewBuilder
    private func collectionDropTarget(for collection: CDCollection) -> some View {
        let count = publicationCount(for: collection)
        let isEditing = state.renamingCollection?.id == collection.id
        if collection.isSmartCollection {
            // Smart collections don't accept drops
            CollectionRow(
                collection: collection,
                count: count,
                isEditing: isEditing,
                onRename: { newName in renameCollection(collection, to: newName) }
            )
        } else {
            // Static collections accept drops (publications and files)
            SidebarDropTarget(
                isTargeted: state.dropTargetedCollection == collection.id,
                showPlusBadge: true
            ) {
                CollectionRow(
                    collection: collection,
                    count: count,
                    isEditing: isEditing,
                    onRename: { newName in renameCollection(collection, to: newName) }
                )
            }
            .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID], isTargeted: makeCollectionTargetBinding(collection.id)) { providers in
                dragDropLog("📦 DROP on collection '\(collection.name)' (id: \(collection.id.uuidString))")
                dragDropLog("  - Provider count: \(providers.count)")
                for (i, provider) in providers.enumerated() {
                    let types = provider.registeredTypeIdentifiers
                    dragDropLog("  - Provider[\(i)] types: \(types.joined(separator: ", "))")
                }

                let libraryID = collection.effectiveLibrary?.id ?? collection.library?.id ?? UUID()
                dragDropLog("  - Effective library ID: \(libraryID.uuidString)")

                if hasFileDrops(providers) {
                    dragDropLog("  → Routing to file drop handler")
                    handleFileDropOnCollection(providers, collectionID: collection.id, libraryID: libraryID)
                } else if hasURLDrops(providers) {
                    dragDropLog("  → Routing to URL import handler (collection)")
                    handleFileDropOnCollection(providers, collectionID: collection.id, libraryID: libraryID)
                } else {
                    dragDropLog("  → Routing to publication drop handler")
                    handleDrop(providers: providers) { uuids in
                        dragDropLog("  → handleDrop completed with \(uuids.count) UUIDs")
                        Task { await addPublications(uuids, to: collection) }
                    }
                }
                return true
            }
        }
    }

    // MARK: - Drop Target Bindings

    private func makeLibraryHeaderTargetBinding(_ libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { state.dropTargetedLibraryHeader == libraryID },
            set: { isTargeted in
                state.dropTargetedLibraryHeader = isTargeted ? libraryID : nil
                // Auto-expand after hovering for a moment
                if isTargeted && !expandedLibraries.contains(libraryID) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if state.dropTargetedLibraryHeader == libraryID {
                            expandedLibraries.insert(libraryID)
                        }
                    }
                }
            }
        )
    }

    private func makeCollectionTargetBinding(_ collectionID: UUID) -> Binding<Bool> {
        .optionalEquality(source: $state.dropTargetedCollection, equals: collectionID)
    }

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider], action: @escaping ([UUID]) -> Void) {
        dragDropLog("🔄 handleDrop started with \(providers.count) providers")
        var collectedUUIDs: [UUID] = []
        let group = DispatchGroup()
        var loadAttempts = 0

        for (index, provider) in providers.enumerated() {
            // Try to load as our custom publication ID type
            let hasPublicationID = provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier)
            dragDropLog("  Provider[\(index)] hasPublicationID: \(hasPublicationID)")

            if hasPublicationID {
                loadAttempts += 1
                group.enter()
                dragDropLog("  Provider[\(index)] loading data representation...")
                provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, error in
                    defer { group.leave() }
                    if let error = error {
                        dragDropError("  ❌ Provider[\(index)] load error: \(error.localizedDescription)")
                        return
                    }
                    if let data = data {
                        dragDropLog("  Provider[\(index)] received \(data.count) bytes")
                        // Log raw data for debugging
                        if let dataString = String(data: data, encoding: .utf8) {
                            dragDropLog("  Provider[\(index)] raw data: \(dataString)")
                        }
                        // Try to decode as JSON array first (old multi-selection format)
                        if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                            for idString in uuidStrings {
                                if let uuid = UUID(uuidString: idString) {
                                    dragDropLog("  ✅ Provider[\(index)] decoded UUID from array: \(uuid.uuidString)")
                                    collectedUUIDs.append(uuid)
                                }
                            }
                        }
                        // Fallback: UUID is encoded as JSON via CodableRepresentation
                        else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                            dragDropLog("  ✅ Provider[\(index)] decoded UUID: \(uuid.uuidString)")
                            collectedUUIDs.append(uuid)
                        } else {
                            dragDropError("  ❌ Provider[\(index)] failed to decode UUID from data")
                        }
                    } else {
                        dragDropError("  ❌ Provider[\(index)] received nil data")
                    }
                }
            }
        }

        dragDropLog("  Initiated \(loadAttempts) load attempts, waiting for completion...")

        group.notify(queue: .main) {
            dragDropLog("  DispatchGroup completed - collected \(collectedUUIDs.count) UUIDs")
            if !collectedUUIDs.isEmpty {
                dragDropLog("  Calling action with UUIDs: \(collectedUUIDs.map { $0.uuidString })")
                action(collectedUUIDs)
            } else {
                dragDropWarning("  ⚠️ No UUIDs collected, action will NOT be called")
            }
        }
    }

    /// BibTeX UTType identifier
    private static let bibtexUTI = "org.tug.tex.bibtex"
    /// RIS UTType identifier
    private static let risUTI = "com.clarivate.ris"

    /// Check if providers contain file drops (PDF, .bib, .ris)
    private func hasFileDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI)
        }
    }

    /// Check if providers contain web URL drops (from browser address bar)
    private func hasURLDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
            !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }

    /// Check if providers contain BibTeX or RIS file drops
    private func hasBibTeXOrRISDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI) ||
            // Also check for generic file URLs with .bib or .ris extension
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier)
        }
    }

    /// Handle BibTeX/RIS file drops - opens import preview with target library pre-selected
    private func handleBibTeXDrop(_ providers: [NSItemProvider], library: CDLibrary) {
        dragDropLog("  → Routing to BibTeX import handler")

        // Try to load the file URL from the provider
        for provider in providers {
            // First try BibTeX type
            if provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) {
                provider.loadItem(forTypeIdentifier: Self.bibtexUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    }
                }
                return
            }

            // Try RIS type
            if provider.hasItemConformingToTypeIdentifier(Self.risUTI) {
                provider.loadItem(forTypeIdentifier: Self.risUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    }
                }
                return
            }

            // Try generic file URL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    let ext = url.pathExtension.lowercased()
                    if ext == "bib" || ext == "bibtex" || ext == "ris" {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    }
                }
                return
            }
        }
    }

    /// Handle BibTeX/RIS file drops on sidebar background (not on a specific library)
    /// Opens import preview with "Create new library" pre-selected and filename as suggestion
    private func handleBibTeXDropForNewLibrary(_ providers: [NSItemProvider]) {
        dragDropLog("  → Routing to BibTeX import handler (new library)")

        for provider in providers {
            // Try BibTeX type
            if provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) {
                provider.loadItem(forTypeIdentifier: Self.bibtexUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            // Post with no library - ContentView will default to "create new library"
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                return
            }

            // Try RIS type
            if provider.hasItemConformingToTypeIdentifier(Self.risUTI) {
                provider.loadItem(forTypeIdentifier: Self.risUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                return
            }

            // Try generic file URL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    let ext = url.pathExtension.lowercased()
                    if ext == "bib" || ext == "bibtex" || ext == "ris" {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                return
            }
        }
    }

    /// Handle file drops on a library target
    private func handleFileDrop(_ providers: [NSItemProvider], libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.library(libraryID: libraryID)
        Task {
            let result = await dragDropCoordinator.performDrop(info, target: target)
            if case .needsConfirmation = result {
                await MainActor.run {
                    state.showDropPreview(for: libraryID)
                }
            }
        }
    }

    /// Handle file drops on a collection target
    private func handleFileDropOnCollection(_ providers: [NSItemProvider], collectionID: UUID, libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.collection(collectionID: collectionID, libraryID: libraryID)
        Task {
            let result = await dragDropCoordinator.performDrop(info, target: target)
            if case .needsConfirmation = result {
                await MainActor.run {
                    state.showDropPreview(for: libraryID)
                }
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 16) {
            Button {
                state.showNewLibrary()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Library")
            .accessibilityIdentifier(AccessibilityID.Sidebar.newLibraryButton)

            Button {
                if let library = selectedLibrary {
                    state.libraryToDelete = library
                    state.showDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selectedLibrary == nil)
            .help("Remove Library")
            .accessibilityIdentifier(AccessibilityID.Toolbar.removeButton)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.borderless)
    }

    // MARK: - Inbox Section

    /// Inbox section content (without Section wrapper)
    /// Now clicking the "Inbox" header shows all papers, so we don't need an "All Publications" row.
    /// Content includes: top-level feeds, collections (with their nested feeds)
    @ViewBuilder
    private var inboxSectionContent: some View {
        // Top-level feeds (no parent collection)
        let topLevelFeeds = inboxFeeds.filter { $0.inboxParentCollection == nil }

        ForEach(topLevelFeeds, id: \.id) { feed in
            inboxFeedRow(for: feed)
        }
        .onInsert(of: [.inboxFeedID]) { index, providers in
            handleInboxFeedReorder(at: index, providers: providers, feeds: topLevelFeeds)
        }

        // Inbox collections (hierarchical) with their nested feeds
        if let inboxLibrary = InboxManager.shared.inboxLibrary,
           let collections = inboxLibrary.collections,
           !collections.isEmpty {
            let flatCollections = flattenedInboxCollections(from: collections, inboxLibraryID: inboxLibrary.id)
            let visibleCollections = filterVisibleInboxCollections(flatCollections, inboxLibraryID: inboxLibrary.id)

            ForEach(visibleCollections, id: \.id) { collection in
                inboxCollectionRow(collection: collection, allCollections: flatCollections, inboxLibrary: inboxLibrary)
            }
            .onInsert(of: [.collectionID]) { index, providers in
                handleCollectionInsert(at: index, providers: providers, visibleCollections: visibleCollections, library: inboxLibrary)
            }

            // Drop zone at inbox level to move collections back to root
            if flatCollections.contains(where: { $0.parentCollection != nil }) {
                Text("Drop here to move to root")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onDrop(of: [.collectionID], isTargeted: nil) { providers in
                        handleCollectionDropToRoot(providers: providers, library: inboxLibrary)
                    }
            }
        }
    }

    /// Row for an inbox feed (smart search with feedsToInbox)
    @ViewBuilder
    private func inboxFeedRow(for feed: CDSmartSearch) -> some View {
        HStack {
            Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                .help(tooltipForFeed(feed))
            Spacer()
            // Show unread count for this feed
            let unreadCount = unreadCountForFeed(feed)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .tag(SidebarSection.inboxFeed(feed))
        .draggable(InboxFeedDragItem(id: feed.id)) {
            Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            inboxFeedContextMenu(for: feed)
        }
    }

    /// Context menu for inbox feed
    @ViewBuilder
    private func inboxFeedContextMenu(for feed: CDSmartSearch) -> some View {
        Button("Refresh Now") {
            Task {
                await refreshInboxFeed(feed)
            }
        }
        if let (url, label) = webURL(for: feed) {
            Button(label) {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
            }
        }
        Button("Edit") {
            // Check feed type and route to appropriate editor
            if feed.isGroupFeed {
                // Navigate to Group arXiv Feed form
                selection = .searchForm(.arxivGroupFeed)
                // Delay notification to ensure view is mounted
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: .editGroupArXivFeed, object: feed)
                }
            } else if isArXivCategoryFeed(feed) {
                // Navigate to arXiv Feed form
                selection = .searchForm(.arxivFeed)
                // Delay notification to ensure view is mounted
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: .editArXivFeed, object: feed)
                }
            } else {
                // Navigate to Search section with this feed's query
                NotificationCenter.default.post(name: .editSmartSearch, object: feed.id)
            }
        }

        // Move to collection submenu (if there are collections)
        if let inboxLibrary = InboxManager.shared.inboxLibrary,
           let collections = inboxLibrary.collections,
           !collections.isEmpty {
            Divider()
            Menu("Move to Collection") {
                // Option to move to top level (no collection)
                if feed.inboxParentCollection != nil {
                    Button("(No Collection)") {
                        moveFeedToCollection(feed, collection: nil)
                    }
                    Divider()
                }
                // List available collections
                ForEach(Array(collections).sorted(by: { $0.name < $1.name }), id: \.id) { collection in
                    Button(collection.name) {
                        moveFeedToCollection(feed, collection: collection)
                    }
                }
            }
        }

        Divider()
        Button("Remove from Inbox", role: .destructive) {
            removeFromInbox(feed)
        }
    }

    /// Row for an inbox collection (with expand/collapse and nested feeds)
    @ViewBuilder
    private func inboxCollectionRow(
        collection: CDCollection,
        allCollections: [CDCollection],
        inboxLibrary: CDLibrary
    ) -> some View {
        let isExpanded = state.expandedInboxCollections.contains(collection.id)
        let hasChildren = collection.hasChildren
        let nestedFeeds = inboxFeeds.filter { $0.inboxParentCollection?.id == collection.id }
        let hasContent = hasChildren || !nestedFeeds.isEmpty
        let depth = collection.depth

        let isEditing = state.renamingInboxCollection?.id == collection.id

        HStack(spacing: 4) {
            // Indentation based on depth
            if depth > 0 {
                ForEach(0..<depth, id: \.self) { _ in
                    Color.clear.frame(width: 16)
                }
            }

            // Expand/collapse triangle (only if has children or feeds)
            if hasContent {
                Button {
                    toggleInboxCollectionExpanded(collection)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12)
            }

            // Collection icon
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            // Collection name (editable when renaming)
            if isEditing {
                TextField("Name", text: $state.renamingInboxCollectionName)
                    .textFieldStyle(.plain)
                    .focused($isRenamingInboxCollectionFocused)
                    .onSubmit {
                        finishRenamingInboxCollection(collection)
                    }
                    .onExitCommand {
                        // Cancel on Escape
                        state.renamingInboxCollection = nil
                        isRenamingInboxCollectionFocused = false
                    }
            } else {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Publication count
            let pubCount = collection.publications?.count ?? 0
            if pubCount > 0 {
                Text("\(pubCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(SidebarSection.inboxCollection(collection))
        .contextMenu {
            inboxCollectionContextMenu(for: collection, inboxLibrary: inboxLibrary)
        }
        // Allow dropping feeds and exploration searches on collection
        .onDrop(of: [.inboxFeedID, .explorationSearchID], isTargeted: nil) { providers in
            var handled = false

            for provider in providers {
                // Handle inbox feed drops (move to this collection)
                if provider.hasItemConformingToTypeIdentifier(UTType.inboxFeedID.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.inboxFeedID.identifier) { data, _ in
                        guard let data = data,
                              let uuidString = String(data: data, encoding: .utf8),
                              let feedID = UUID(uuidString: uuidString) else { return }
                        Task { @MainActor in
                            if let feed = inboxFeeds.first(where: { $0.id == feedID }) {
                                moveFeedToCollection(feed, collection: collection)
                            }
                        }
                    }
                    handled = true
                }
                // Handle exploration search drops (convert to feed in this collection)
                else if provider.hasItemConformingToTypeIdentifier(UTType.explorationSearchID.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.explorationSearchID.identifier) { data, _ in
                        guard let data = data,
                              let uuidString = String(data: data, encoding: .utf8),
                              let searchID = UUID(uuidString: uuidString) else { return }
                        Task { @MainActor in
                            convertExplorationSearchToInboxFeed(searchID, inCollection: collection)
                        }
                    }
                    handled = true
                }
            }
            return handled
        }
        .draggable(CollectionDragItem(id: collection.id)) {
            Label(collection.name, systemImage: "folder")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }

        // Show nested feeds when expanded
        if isExpanded {
            ForEach(nestedFeeds, id: \.id) { feed in
                HStack(spacing: 4) {
                    // Indentation (depth + 1 for being inside collection)
                    ForEach(0..<(depth + 1), id: \.self) { _ in
                        Color.clear.frame(width: 16)
                    }
                    Color.clear.frame(width: 12) // Space where triangle would be

                    Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                        .help(tooltipForFeed(feed))

                    Spacer()

                    let unreadCount = unreadCountForFeed(feed)
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .tag(SidebarSection.inboxFeed(feed))
                .draggable(InboxFeedDragItem(id: feed.id)) {
                    Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    inboxFeedContextMenu(for: feed)
                }
            }
        }
    }

    /// Context menu for inbox collection
    @ViewBuilder
    private func inboxCollectionContextMenu(for collection: CDCollection, inboxLibrary: CDLibrary) -> some View {
        Button("New Subcollection") {
            createInboxSubcollection(under: collection, in: inboxLibrary)
        }

        Button("Rename") {
            startRenamingInboxCollection(collection)
        }

        Divider()

        Button("Delete", role: .destructive) {
            deleteInboxCollection(collection)
        }
    }

    /// Toggle expanded state for an inbox collection
    private func toggleInboxCollectionExpanded(_ collection: CDCollection) {
        if state.expandedInboxCollections.contains(collection.id) {
            state.expandedInboxCollections.remove(collection.id)
        } else {
            state.expandedInboxCollections.insert(collection.id)
        }
    }

    /// Move a feed to a collection (or to top level if collection is nil)
    private func moveFeedToCollection(_ feed: CDSmartSearch, collection: CDCollection?) {
        feed.inboxParentCollection = collection
        try? PersistenceController.shared.viewContext.save()
        state.triggerRefresh()
    }

    /// Convert an exploration search to an inbox feed
    private func convertExplorationSearchToInboxFeed(_ searchID: UUID, inCollection: CDCollection?) {
        guard let inboxLibrary = InboxManager.shared.inboxLibrary else { return }

        // Find the exploration search
        guard let explorationLibrary = libraryManager.explorationLibrary,
              let searches = explorationLibrary.smartSearches,
              let search = searches.first(where: { $0.id == searchID }) else {
            return
        }

        // Move the search to the inbox library and set feedsToInbox
        search.library = inboxLibrary
        search.feedsToInbox = true
        search.inboxParentCollection = inCollection

        try? PersistenceController.shared.viewContext.save()
        state.triggerRefresh()
        state.triggerExplorationRefresh()
    }

    /// Create a new root-level collection in the Inbox
    private func createInboxRootCollection() {
        guard let inboxLibrary = InboxManager.shared.inboxLibrary else { return }

        let context = PersistenceController.shared.viewContext
        let newCollection = CDCollection(context: context)
        newCollection.id = UUID()
        newCollection.name = "New Collection"
        newCollection.library = inboxLibrary
        newCollection.dateCreated = Date()
        newCollection.sortOrder = Int16((inboxLibrary.collections?.count ?? 0))

        try? context.save()
        state.triggerRefresh()

        // Start editing the new collection's name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            startRenamingInboxCollection(newCollection)
        }
    }

    /// Create a new subcollection under an inbox collection
    private func createInboxSubcollection(under parent: CDCollection, in library: CDLibrary) {
        let context = PersistenceController.shared.viewContext
        let newCollection = CDCollection(context: context)
        newCollection.id = UUID()
        newCollection.name = "New Folder"
        newCollection.parentCollection = parent
        newCollection.library = library
        newCollection.dateCreated = Date()
        newCollection.sortOrder = Int16((parent.childCollections?.count ?? 0))

        try? context.save()
        state.expandedInboxCollections.insert(parent.id)
        state.triggerRefresh()

        // Start editing the new collection's name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            startRenamingInboxCollection(newCollection)
        }
    }

    /// Delete an inbox collection
    private func deleteInboxCollection(_ collection: CDCollection) {
        let context = PersistenceController.shared.viewContext

        // Move any feeds in this collection to top level
        if let feeds = collection.inboxFeeds {
            for feed in feeds {
                feed.inboxParentCollection = nil
            }
        }

        context.delete(collection)
        try? context.save()
        state.triggerRefresh()
    }

    /// Start renaming an inbox collection
    private func startRenamingInboxCollection(_ collection: CDCollection) {
        // Clear any previous focus first
        isRenamingInboxCollectionFocused = false
        // Set up rename state
        state.renamingInboxCollectionName = collection.name
        state.renamingInboxCollection = collection
        // Focus after TextField appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isRenamingInboxCollectionFocused = true
        }
    }

    /// Finish renaming an inbox collection
    private func finishRenamingInboxCollection(_ collection: CDCollection) {
        let newName = state.renamingInboxCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && newName != collection.name {
            collection.name = newName
            try? PersistenceController.shared.viewContext.save()
        }
        state.renamingInboxCollection = nil
        isRenamingInboxCollectionFocused = false
        state.triggerRefresh()
    }

    /// Flatten inbox collections for display (respecting hierarchy)
    private func flattenedInboxCollections(from collections: Set<CDCollection>, inboxLibraryID: UUID) -> [CDCollection] {
        Array(collections)
            .filter { $0.library?.id == inboxLibraryID && !$0.isSystemCollection && !$0.isSmartSearchResults }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }
    }

    /// Filter to only show visible collections based on parent expansion state
    private func filterVisibleInboxCollections(_ collections: [CDCollection], inboxLibraryID: UUID) -> [CDCollection] {
        collections.filter { collection in
            // Root collections are always visible
            guard let parent = collection.parentCollection else { return true }
            // Children are visible only if parent is expanded
            return state.expandedInboxCollections.contains(parent.id)
        }
    }

    /// Handle inbox feed reordering via drag-and-drop
    private func handleInboxFeedReorder(at targetIndex: Int, providers: [NSItemProvider], feeds: [CDSmartSearch]) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.inboxFeedID.identifier) { data, _ in
            guard let data = data,
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString) else { return }

            Task { @MainActor in
                var reordered = feeds
                guard let sourceIndex = reordered.firstIndex(where: { $0.id == draggedID }) else { return }

                // Calculate destination accounting for removal
                let destinationIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                let clampedDestination = max(0, min(destinationIndex, reordered.count - 1))

                // Perform the move
                let feed = reordered.remove(at: sourceIndex)
                reordered.insert(feed, at: clampedDestination)

                // Update order for all feeds
                for (index, f) in reordered.enumerated() {
                    f.order = Int16(index)
                }

                try? PersistenceController.shared.viewContext.save()
                state.triggerRefresh()
            }
        }
    }

    /// Get all smart searches that feed to the Inbox
    private var inboxFeeds: [CDSmartSearch] {
        // Fetch all smart searches with feedsToInbox enabled
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")
        request.sortDescriptors = [
            NSSortDescriptor(key: "order", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)  // Secondary sort for ties
        ]

        do {
            return try PersistenceController.shared.viewContext.fetch(request)
        } catch {
            return []
        }
    }

    /// Get unread count for the Inbox
    private var inboxUnreadCount: Int {
        InboxManager.shared.unreadCount
    }

    /// Get unread count for a specific inbox feed
    private func unreadCountForFeed(_ feed: CDSmartSearch) -> Int {
        guard let collection = feed.resultCollection,
              let publications = collection.publications else {
            return 0
        }
        return publications.filter { !$0.isRead && !$0.isDeleted }.count
    }

    /// Generate tooltip text for a feed
    private func tooltipForFeed(_ feed: CDSmartSearch) -> String {
        if feed.isGroupFeed {
            // Group feed: show authors and categories
            let authors = feed.groupFeedAuthors()
            let categories = feed.groupFeedCategories()

            var lines: [String] = []

            if !authors.isEmpty {
                lines.append("Authors:")
                for author in authors {
                    lines.append("  • \(author)")
                }
            }

            if !categories.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Categories:")
                for category in categories.sorted() {
                    lines.append("  • \(category)")
                }
            }

            return lines.isEmpty ? "Group feed" : lines.joined(separator: "\n")
        } else if isArXivCategoryFeed(feed) {
            // arXiv category feed: show categories from query
            let categories = parseArXivCategories(from: feed.query)
            if categories.isEmpty {
                return "arXiv category feed"
            }
            var lines = ["Categories:"]
            for category in categories.sorted() {
                lines.append("  • \(category)")
            }
            return lines.joined(separator: "\n")
        } else {
            // Regular smart search: show query
            return "Query: \(feed.query)"
        }
    }

    /// Parse arXiv categories from a category feed query
    private func parseArXivCategories(from query: String) -> [String] {
        // Category feeds typically have queries like: cat:astro-ph.GA OR cat:astro-ph.CO
        var categories: [String] = []
        let pattern = #"cat:([a-zA-Z\-]+\.[A-Z]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(query.startIndex..., in: query)
            let matches = regex.matches(in: query, options: [], range: range)
            for match in matches {
                if let catRange = Range(match.range(at: 1), in: query) {
                    categories.append(String(query[catRange]))
                }
            }
        }
        return categories
    }

    /// Refresh a specific inbox feed
    private func refreshInboxFeed(_ feed: CDSmartSearch) async {
        guard let scheduler = await InboxCoordinator.shared.scheduler else { return }
        do {
            _ = try await scheduler.refreshFeed(feed)
            await MainActor.run {
                state.triggerRefresh()
            }
        } catch {
            // Handle error silently for now
        }
    }

    /// Remove a feed from Inbox (disable feedsToInbox)
    private func removeFromInbox(_ feed: CDSmartSearch) {
        feed.feedsToInbox = false
        feed.autoRefreshEnabled = false
        try? feed.managedObjectContext?.save()
        state.triggerRefresh()
    }

    /// Check if a feed is an arXiv category feed (query contains only cat: patterns)
    private func isArXivCategoryFeed(_ feed: CDSmartSearch) -> Bool {
        let query = feed.query
        // arXiv feeds use only "arxiv" source and have cat: patterns in their query
        guard feed.sources == ["arxiv"] else { return false }
        guard query.contains("cat:") else { return false }

        // Check that the query is primarily category-based (no search terms like ti:, au:, abs:)
        let hasSearchTerms = query.contains("ti:") || query.contains("au:") ||
                             query.contains("abs:") || query.contains("co:") ||
                             query.contains("jr:") || query.contains("rn:") ||
                             query.contains("id:") || query.contains("doi:")
        return !hasSearchTerms
    }

    /// Construct an arXiv web URL for a feed.
    ///
    /// For category feeds (e.g., "cat:astro-ph.GA"), opens the category listing page.
    /// For other arXiv searches, opens the search results page.
    private func arXivWebURL(for feed: CDSmartSearch) -> URL? {
        guard feed.sources == ["arxiv"] else { return nil }

        let query = feed.query

        // Extract category from "cat:xxx" pattern for category feeds
        if isArXivCategoryFeed(feed) {
            // Extract first category from query like "(cat:astro-ph.GA OR cat:astro-ph.CO)"
            let pattern = #"cat:([^\s()]+)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let category = String(query[range])
                return URL(string: "https://arxiv.org/list/\(category)/recent")
            }
        }

        // For general arXiv searches, use the search page
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://arxiv.org/search/?query=\(encodedQuery)&searchtype=all")
        }

        return nil
    }

    /// Construct an ADS web URL for a feed or search.
    ///
    /// Opens the search results page on the ADS web interface.
    private func adsWebURL(for feed: CDSmartSearch) -> URL? {
        guard feed.sources == ["ads"] else { return nil }

        let query = feed.query
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://ui.adsabs.harvard.edu/search/q=\(encodedQuery)")
        }

        return nil
    }

    /// Construct a SciX web URL for a feed or search.
    ///
    /// Opens the search results page on the SciX web interface.
    private func sciXWebURL(for feed: CDSmartSearch) -> URL? {
        guard feed.sources == ["scix"] else { return nil }

        let query = feed.query
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://www.scixplorer.org/search/q=\(encodedQuery)")
        }

        return nil
    }

    /// Get the appropriate web URL for any supported feed.
    ///
    /// Returns the web URL for arXiv, ADS, or SciX feeds based on their source.
    private func webURL(for feed: CDSmartSearch) -> (url: URL, label: String)? {
        if let url = arXivWebURL(for: feed) {
            return (url, "Open on arXiv")
        }
        if let url = adsWebURL(for: feed) {
            return (url, "Open on ADS")
        }
        if let url = sciXWebURL(for: feed) {
            return (url, "Open on SciX")
        }
        return nil
    }

    // MARK: - Helpers

    /// Convert permission level to tooltip string
    private func permissionTooltip(_ level: CDSciXLibrary.PermissionLevel) -> String {
        switch level {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .write: return "Can edit"
        case .read: return "Read only"
        }
    }

    private func expansionBinding(for libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedLibraries.contains(libraryID) },
            set: { isExpanded in
                if isExpanded {
                    expandedLibraries.insert(libraryID)
                } else {
                    expandedLibraries.remove(libraryID)
                }
            }
        )
    }

    /// Get the currently selected library from the selection
    private var selectedLibrary: CDLibrary? {
        switch selection {
        case .inbox:
            return InboxManager.shared.inboxLibrary
        case .inboxFeed(let feed):
            return feed.library ?? InboxManager.shared.inboxLibrary
        case .library(let library):
            return library
        case .smartSearch(let smartSearch):
            return smartSearch.library
        case .collection(let collection):
            return collection.library
        default:
            return nil
        }
    }

    private func publicationCount(for library: CDLibrary) -> Int {
        allPublications(for: library).count
    }

    /// Get count of starred publications in a library.
    private func starredPublicationCount(for library: CDLibrary) -> Int {
        allPublications(for: library).filter { $0.isStarred }.count
    }

    /// Get all publications for a library.
    ///
    /// Simplified: All papers are in `library.publications` (smart search results included).
    private func allPublications(for library: CDLibrary) -> Set<CDPublication> {
        (library.publications ?? []).filter { !$0.isDeleted }
    }

    private func publicationCount(for collection: CDCollection) -> Int {
        // Use matchingPublicationCount which handles both static and smart collections
        collection.matchingPublicationCount
    }

    private func resultCount(for smartSearch: CDSmartSearch) -> Int {
        smartSearch.resultCollection?.publications?.count ?? 0
    }

    // MARK: - Smart Search Management

    private func deleteSmartSearch(_ smartSearch: CDSmartSearch) {
        // Clear selection BEFORE deletion to prevent accessing deleted object
        if case .smartSearch(let selected) = selection, selected.id == smartSearch.id {
            selection = nil
        }

        let searchID = smartSearch.id
        SmartSearchRepository.shared.delete(smartSearch)
        Task {
            await SmartSearchProviderCache.shared.invalidate(searchID)
        }
    }

    // MARK: - Collection Management

    private func createSmartCollection(name: String, predicate: String, in library: CDLibrary) async {
        // Create collection directly in Core Data
        let context = library.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.isSmartCollection = true
        collection.predicate = predicate
        collection.library = library
        try? context.save()

        // Trigger sidebar refresh to show the new collection
        await MainActor.run {
            state.triggerRefresh()
        }
    }

    private func createStaticCollection(in library: CDLibrary, parent: CDCollection? = nil) {
        let context = library.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = parent != nil ? "New Subcollection" : "New Collection"
        collection.isSmartCollection = false
        collection.library = library
        collection.parentCollection = parent
        try? context.save()

        // Expand parent when creating subcollection
        if let parent = parent {
            var expanded = state.expandedLibraryCollections[library.id] ?? []
            expanded.insert(parent.id)
            state.expandedLibraryCollections[library.id] = expanded
        }

        // Clear any previous focus and rename state first
        isRenamingCollectionFocused = false
        state.renamingCollection = nil

        // Trigger refresh so the new collection appears in the list
        state.triggerRefresh()

        // Enter rename mode after a brief delay to ensure collection is in view hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            state.renamingCollectionName = collection.name
            state.renamingCollection = collection
        }

        // Focus the TextField after it appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isRenamingCollectionFocused = true
        }
    }

    private func renameCollection(_ collection: CDCollection, to newName: String) {
        isRenamingCollectionFocused = false
        guard !newName.isEmpty else {
            state.renamingCollection = nil
            return
        }
        collection.name = newName
        try? collection.managedObjectContext?.save()
        state.renamingCollection = nil
        state.triggerRefresh()
    }

    private func updateCollection(_ collection: CDCollection, name: String, predicate: String) async {
        collection.name = name
        collection.predicate = predicate
        try? collection.managedObjectContext?.save()
    }

    private func deleteCollection(_ collection: CDCollection) {
        // Clear selection BEFORE deletion to prevent accessing deleted object
        if case .collection(let selected) = selection, selected.id == collection.id {
            selection = nil
        }

        guard let context = collection.managedObjectContext else { return }
        context.delete(collection)
        try? context.save()
    }

    /// Move a collection to a new parent (or to root if newParent is nil)
    private func moveCollection(_ collection: CDCollection, to newParent: CDCollection?, in library: CDLibrary) {
        // Don't allow moving to itself
        guard collection.id != newParent?.id else { return }

        // Don't allow moving a parent into its descendant (would create cycle)
        if let newParent = newParent {
            if newParent.ancestors.contains(where: { $0.id == collection.id }) {
                return
            }
        }

        collection.parentCollection = newParent
        try? collection.managedObjectContext?.save()

        // Expand the new parent to show the moved collection
        if let newParent = newParent {
            var expanded = state.expandedLibraryCollections[library.id] ?? []
            expanded.insert(newParent.id)
            state.expandedLibraryCollections[library.id] = expanded
        }

        state.triggerRefresh()
    }

    /// Handle drop onto a collection (publications or nested collections)
    /// Used by GenericTreeRow's onDrop modifier
    private func handleCollectionDrop(
        providers: [NSItemProvider],
        collection: CDCollection,
        allCollections: [CDCollection],
        library: CDLibrary
    ) -> Bool {
        // Handle collection drops (for nesting)
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.collectionID.identifier) { data, _ in
                    guard let data = data,
                          let idString = String(data: data, encoding: .utf8),
                          let draggedID = UUID(uuidString: idString) else { return }

                    // Don't allow dropping a collection onto itself or its descendants
                    if draggedID == collection.id { return }
                    if collection.ancestors.contains(where: { $0.id == draggedID }) { return }

                    // Find the dragged collection and move it
                    if let draggedCollection = allCollections.first(where: { $0.id == draggedID }) {
                        Task { @MainActor in
                            moveCollection(draggedCollection, to: collection, in: library)
                        }
                    }
                }
                return true
            }
        }

        // Handle publication drops
        var publicationIDs: [UUID] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, error in
                defer { group.leave() }
                guard let data = data else { return }

                // Try to decode as JSON array of UUIDs first (multi-selection drag)
                if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                    for idString in uuidStrings {
                        if let uuid = UUID(uuidString: idString) {
                            publicationIDs.append(uuid)
                        }
                    }
                }
                // Fallback: try single UUID via JSONDecoder (CodableRepresentation format)
                else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                    publicationIDs.append(uuid)
                }
                // Final fallback: try plain UUID string (legacy string format)
                else if let idString = String(data: data, encoding: .utf8),
                        let uuid = UUID(uuidString: idString) {
                    publicationIDs.append(uuid)
                }
            }
        }

        group.notify(queue: .main) {
            if !publicationIDs.isEmpty {
                Task {
                    await self.addPublications(publicationIDs, to: collection)
                }
            }
        }

        return !providers.isEmpty
    }

    /// Handle collection reordering via drag-and-drop (.onInsert)
    private func handleCollectionInsert(at targetIndex: Int, providers: [NSItemProvider], visibleCollections: [CDCollection], library: CDLibrary) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.collectionID.identifier) { data, _ in
            guard let data = data,
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString) else { return }

            Task { @MainActor in
                // Find the dragged collection
                guard let sourceIndex = visibleCollections.firstIndex(where: { $0.id == draggedID }) else { return }
                let sourceCollection = visibleCollections[sourceIndex]

                // Use the existing moveCollections logic via IndexSet
                let source = IndexSet(integer: sourceIndex)
                moveCollections(from: source, to: targetIndex, in: visibleCollections, library: library)
            }
        }
    }

    /// Reorder collections within their sibling group
    private func moveCollections(from source: IndexSet, to destination: Int, in visibleCollections: [CDCollection], library: CDLibrary) {
        // Get the source collection
        guard let sourceIndex = source.first,
              sourceIndex < visibleCollections.count else { return }

        let sourceCollection = visibleCollections[sourceIndex]

        // Determine valid destination - only allow reordering among siblings with same parent
        let sourceParentID = sourceCollection.parentCollection?.id

        // Find all siblings (collections with same parent at same depth)
        let siblings = visibleCollections.filter { $0.parentCollection?.id == sourceParentID }
        guard siblings.count > 1 else { return }

        // Calculate the position within siblings
        let sourceIndexInSiblings = siblings.firstIndex(where: { $0.id == sourceCollection.id }) ?? 0

        // Find destination index in siblings
        // We need to map the flattened list destination to sibling-relative destination
        var destinationInSiblings = destination

        // Calculate where in siblings this destination maps to
        if destination < visibleCollections.count {
            let destCollection = visibleCollections[min(destination, visibleCollections.count - 1)]
            if destCollection.parentCollection?.id == sourceParentID {
                destinationInSiblings = siblings.firstIndex(where: { $0.id == destCollection.id }) ?? siblings.count
            } else {
                // Destination is not a sibling, don't allow move
                return
            }
        } else {
            // Destination is past end, check if last sibling
            if let lastSibling = siblings.last,
               let lastIndex = visibleCollections.firstIndex(where: { $0.id == lastSibling.id }),
               destination > lastIndex {
                destinationInSiblings = siblings.count
            } else {
                return
            }
        }

        // Don't move to same position
        if sourceIndexInSiblings == destinationInSiblings || sourceIndexInSiblings + 1 == destinationInSiblings {
            return
        }

        // Reorder siblings
        var reorderedSiblings = siblings
        reorderedSiblings.remove(at: sourceIndexInSiblings)
        let insertIndex = destinationInSiblings > sourceIndexInSiblings ? destinationInSiblings - 1 : destinationInSiblings
        reorderedSiblings.insert(sourceCollection, at: insertIndex)

        // Update sortOrder for all siblings
        for (index, collection) in reorderedSiblings.enumerated() {
            collection.sortOrder = Int16(index)
        }

        try? library.managedObjectContext?.save()
        state.triggerRefresh()
    }

    /// Handle dropping a collection to the root level (remove parent)
    private func handleCollectionDropToRoot(providers: [NSItemProvider], library: CDLibrary) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.collectionID.identifier) { data, _ in
                    guard let data = data,
                          let idString = String(data: data, encoding: .utf8),
                          let draggedID = UUID(uuidString: idString) else { return }

                    // Find the dragged collection
                    guard let collections = library.collections as? Set<CDCollection>,
                          let draggedCollection = collections.first(where: { $0.id == draggedID }) else { return }

                    Task { @MainActor in
                        moveCollection(draggedCollection, to: nil, in: library)
                    }
                }
                return true
            }
        }
        return false
    }

    /// Handle flag color reordering via drag-and-drop (.onInsert)
    private func handleFlagColorInsert(at targetIndex: Int, providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.flagColorID.identifier) { data, _ in
            guard let data = data,
                  let rawValue = String(data: data, encoding: .utf8),
                  let draggedColor = FlagColor(rawValue: rawValue) else { return }

            Task { @MainActor in
                var reordered = flagColorOrder
                guard let sourceIndex = reordered.firstIndex(of: draggedColor) else { return }
                let destinationIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                let clamped = max(0, min(destinationIndex, reordered.count - 1))
                let color = reordered.remove(at: sourceIndex)
                reordered.insert(color, at: clamped)
                flagColorOrder = reordered
                Task { await FlagColorOrderStore.shared.save(reordered) }
            }
        }
    }

    /// Handle dropping a collection onto a different library header (cross-library move)
    private func handleCrossLibraryCollectionMove(providers: [NSItemProvider], targetLibrary: CDLibrary) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.collectionID.identifier) { data, _ in
                    guard let data = data,
                          let idString = String(data: data, encoding: .utf8),
                          let draggedID = UUID(uuidString: idString) else { return }

                    // Find the dragged collection from any library
                    guard let context = targetLibrary.managedObjectContext else { return }

                    let request = NSFetchRequest<CDCollection>(entityName: "Collection")
                    request.predicate = NSPredicate(format: "id == %@", draggedID as CVarArg)
                    request.fetchLimit = 1

                    guard let draggedCollection = try? context.fetch(request).first else { return }

                    // Don't move to same library
                    guard draggedCollection.library?.id != targetLibrary.id else { return }

                    Task { @MainActor in
                        moveCollectionToLibrary(draggedCollection, targetLibrary: targetLibrary)
                    }
                }
                return true
            }
        }
        return false
    }

    /// Move a collection (and all its children) to a different library
    private func moveCollectionToLibrary(_ collection: CDCollection, targetLibrary: CDLibrary) {
        // Move the collection tree
        moveCollectionTree(collection, to: targetLibrary)

        // Clear parent (becomes root collection in target)
        collection.parentCollection = nil

        try? collection.managedObjectContext?.save()

        // Expand target library to show moved collection
        if !expandedLibraries.contains(targetLibrary.id) {
            expandedLibraries.insert(targetLibrary.id)
        }

        state.triggerRefresh()
    }

    /// Recursively move a collection and all descendants to a target library
    private func moveCollectionTree(_ collection: CDCollection, to targetLibrary: CDLibrary) {
        // Change library
        collection.library = targetLibrary

        // Move publications to target library
        if let publications = collection.publications {
            for publication in publications {
                // Add to target library (publication may exist in multiple libraries)
                publication.addToLibrary(targetLibrary)
            }
        }

        // Recursively move all children
        if let children = collection.childCollections {
            for child in children {
                moveCollectionTree(child, to: targetLibrary)
            }
        }
    }

    // MARK: - Library Management

    private func deleteLibrary(_ library: CDLibrary) {
        // Clear selection BEFORE deletion if ANY item from this library is selected
        if let currentSelection = selection {
            switch currentSelection {
            case .inbox, .inboxFeed, .inboxCollection:
                break  // Inbox is not affected by library deletion
            case .library(let lib):
                if lib.id == library.id { selection = nil }
            case .smartSearch(let ss):
                if ss.library?.id == library.id { selection = nil }
            case .collection(let col):
                if col.library?.id == library.id { selection = nil }
            case .search, .searchForm, .scixLibrary, .flagged:
                break  // Not affected by library deletion
            }
        }

        try? libraryManager.deleteLibrary(library, deleteFiles: false)
    }

    // MARK: - Drop Handlers

    /// Add publications to a static collection (also adds to the collection's owning library)
    private func addPublications(_ uuids: [UUID], to collection: CDCollection) async {
        guard !collection.isSmartCollection else { return }
        let context = PersistenceController.shared.viewContext

        await context.perform {
            // Batch fetch all publications at once (much faster than individual fetches)
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", uuids)

            guard let publications = try? context.fetch(request) else { return }

            // Build the new set of publications for the collection
            var current = collection.publications ?? []
            let collectionLibrary = collection.effectiveLibrary

            for publication in publications {
                current.insert(publication)
                // Also add to the collection's library
                if let library = collectionLibrary {
                    publication.addToLibrary(library)
                }
            }
            collection.publications = current

            try? context.save()
        }

        // Trigger sidebar refresh to update counts
        await MainActor.run {
            state.triggerRefresh()
        }
    }

    /// Add publications to a library (publications can belong to multiple libraries)
    private func addPublicationsToLibrary(_ uuids: [UUID], library: CDLibrary) async {
        dragDropLog("📚 addPublicationsToLibrary called")
        dragDropLog("  - Target library: '\(library.displayName)' (id: \(library.id.uuidString))")
        dragDropLog("  - UUIDs to add: \(uuids.count)")

        let context = PersistenceController.shared.viewContext

        await context.perform {
            // Batch fetch all publications at once (much faster than individual fetches)
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", uuids)

            guard let publications = try? context.fetch(request) else {
                dragDropError("  ❌ Failed to fetch publications")
                return
            }

            dragDropLog("  Found \(publications.count) publications for \(uuids.count) UUIDs")

            // Add all publications to the library
            for publication in publications {
                publication.addToLibrary(library)
            }

            do {
                try context.save()
                dragDropLog("  ✅ Context saved successfully - added \(publications.count) publications")
            } catch {
                dragDropError("  ❌ Context save failed: \(error.localizedDescription)")
            }
        }

        dragDropLog("  ✅ addPublicationsToLibrary complete")

        // Trigger sidebar refresh to update counts
        await MainActor.run {
            dragDropLog("  🔄 Triggering sidebar refresh")
            state.triggerRefresh()
        }
    }
}

// MARK: - SidebarDropContext Conformance

extension SidebarView: SidebarDropContext {

    func addPublicationsToLibrary(uuids: [UUID], libraryID: UUID) {
        guard let library = libraryManager.libraries.first(where: { $0.id == libraryID }) else { return }
        Task {
            await addPublicationsToLibrary(uuids, library: library)
        }
    }

    func addPublicationsToCollection(uuids: [UUID], collectionID: UUID) {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDCollection>(entityName: "Collection")
        request.predicate = NSPredicate(format: "id == %@", collectionID as CVarArg)
        request.fetchLimit = 1

        guard let collection = try? context.fetch(request).first else { return }
        Task {
            await addPublications(uuids, to: collection)
        }
    }

    func handleFileDrop(providers: [NSItemProvider], libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.library(libraryID: libraryID)
        Task {
            let result = await dragDropCoordinator.performDrop(info, target: target)
            if case .needsConfirmation = result {
                await MainActor.run {
                    state.showDropPreview(for: libraryID)
                }
            }
        }
    }

    func handleFileDropOnCollection(providers: [NSItemProvider], collectionID: UUID, libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.collection(collectionID: collectionID, libraryID: libraryID)
        Task {
            let result = await dragDropCoordinator.performDrop(info, target: target)
            if case .needsConfirmation = result {
                await MainActor.run {
                    state.showDropPreview(for: libraryID)
                }
            }
        }
    }

    func handleBibTeXDrop(providers: [NSItemProvider], libraryID: UUID) {
        guard let library = libraryManager.libraries.first(where: { $0.id == libraryID }) else { return }
        handleBibTeXDrop(providers, library: library)
    }

    func handleBibTeXDropForNewLibrary(providers: [NSItemProvider]) {
        handleBibTeXDropForNewLibrary(providers)
    }

    func handleCrossLibraryCollectionMove(providers: [NSItemProvider], targetLibraryID: UUID) {
        guard let library = libraryManager.libraries.first(where: { $0.id == targetLibraryID }) else { return }
        _ = handleCrossLibraryCollectionMove(providers: providers, targetLibrary: library)
    }

    func handleCollectionDropToRoot(providers: [NSItemProvider], libraryID: UUID) {
        guard let library = libraryManager.libraries.first(where: { $0.id == libraryID }) else { return }
        _ = handleCollectionDropToRoot(providers: providers, library: library)
    }

    func handleCollectionNesting(providers: [NSItemProvider], targetCollectionID: UUID) {
        // Collection nesting is handled directly by GenericTreeRow's onDrop modifier
        // via handleCollectionDrop(). This stub exists for SidebarDropContext conformance.
    }
}

// CountBadge is now imported from ImpressSidebar package

// MARK: - Smart Search Row

struct SmartSearchRow: View {
    let smartSearch: CDSmartSearch
    var count: Int = 0

    var body: some View {
        HStack {
            Label(smartSearch.name, systemImage: "magnifyingglass.circle.fill")
                .help(smartSearch.query)  // Show query on hover
            Spacer()
            if count > 0 {
                CountBadge(count: count)
            }
        }
    }
}

// MARK: - Collection Row

struct CollectionRow: View {
    @ObservedObject var collection: CDCollection
    var count: Int = 0
    var isEditing: Bool = false
    var onRename: ((String) -> Void)?

    @State private var editedName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Label {
                if isEditing {
                    TextField("Collection Name", text: $editedName)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit {
                            onRename?(editedName)
                        }
                        .onExitCommand {
                            // Cancel on Escape
                            onRename?(collection.name)
                        }
                        .task {
                            // Initialize name and focus immediately
                            editedName = collection.name
                            // Small delay to ensure TextField is in view hierarchy
                            try? await Task.sleep(for: .milliseconds(50))
                            isFocused = true
                            // Select all text for easy replacement (macOS)
                            #if os(macOS)
                            DispatchQueue.main.async {
                                if let window = NSApp.keyWindow,
                                   let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextView {
                                    fieldEditor.selectAll(nil)
                                }
                            }
                            #endif
                        }
                } else {
                    Text(collection.name)
                }
            } icon: {
                Image(systemName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                    .help(collection.isSmartCollection ? "Smart collection - auto-populated by filter rules" : "Collection")
            }
            Spacer()
            if count > 0 {
                CountBadge(count: count)
            }
        }
    }
}

// SidebarDropTarget is now provided by ImpressSidebar package

// MARK: - New Library Sheet

struct NewLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryManager.self) private var libraryManager

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Library Name") {
                    TextField("Name", text: $name, prompt: Text("My Library"))
                }

                Section {
                    Text("Your library will sync across all your devices via iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Library")
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 160)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createLibrary()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func createLibrary() {
        let libraryName = name.isEmpty ? "New Library" : name
        _ = libraryManager.createLibrary(name: libraryName)
        dismiss()
    }
}

#Preview {
    SidebarView(selection: .constant(nil), expandedLibraries: .constant([]), focusedPane: .constant(nil))
        .environment(LibraryManager(persistenceController: .preview))
}
