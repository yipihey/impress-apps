#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  DetailView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import ImpressKeyboard
import ImpressStoreKit
import OSLog
#if os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "unifieddetail")

// MARK: - Notifications

extension Notification.Name {
    static let pdfImportedFromBrowser = Notification.Name("pdfImportedFromBrowser")
}

// MARK: - Unified Detail View

/// A unified detail view that works with any PaperRepresentable.
///
/// This view provides a consistent experience for viewing both online search results
/// and local library papers, with editing capabilities enabled for persistent papers.
struct DetailView: View {

    // MARK: - Properties

    /// The paper to display (any PaperRepresentable)
    let paper: any PaperRepresentable

    /// The publication ID for editing (enables editing for library papers)
    let publicationID: UUID?

    /// External binding for tab selection (persists across paper changes)
    @Binding var selectedTab: DetailTab

    /// Whether multiple papers are selected (disables auto-download)
    var isMultiSelection: Bool = false

    /// Selected publication IDs when in multi-selection mode (for context info)
    var selectedPublicationIDs: Set<UUID> = []

    /// Callback to trigger batch PDF download (multi-selection mode)
    var onDownloadPDFs: (() -> Void)?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme

    // MARK: - File Drop State

    @State private var dropHandler = FileDropHandler()
    @State private var isDropTargeted = false
    @State private var dropRefreshID = UUID()

    // PDF dark mode state (for styling when PDF tab is selected)
    @State private var pdfDarkModeEnabled: Bool = PDFSettingsStore.loadSettingsSync().darkModeEnabled

    // MARK: - Computed Properties

    /// Whether this paper supports editing (local library papers only)
    private var canEdit: Bool {
        publicationID != nil
    }

    /// Whether this is a persistent (library) paper
    private var isPersistent: Bool {
        paper.sourceType.isPersistent
    }

    /// The owning library ID for this publication (for file drop imports)
    private var owningLibraryID: UUID? {
        libraryManager.activeLibrary?.id
    }

    /// Cached publication model — loaded on paper switch via `.onChange(of: publicationID)`,
    /// refreshed on flag/tag mutations via notification handlers.
    @State private var cachedPublication: PublicationModel?

    /// Alias for backward compatibility.
    private var publication: PublicationModel? { cachedPublication }

    // MARK: - Initialization

    init(paper: any PaperRepresentable, publicationID: UUID? = nil, selectedTab: Binding<DetailTab>, isMultiSelection: Bool = false, selectedPublicationIDs: Set<UUID> = [], onDownloadPDFs: (() -> Void)? = nil) {
        self.paper = paper
        self.publicationID = publicationID
        self._selectedTab = selectedTab
        self.isMultiSelection = isMultiSelection
        self.selectedPublicationIDs = selectedPublicationIDs
        self.onDownloadPDFs = onDownloadPDFs
    }

    /// Initializer from Rust store — loads PublicationModel by UUID.
    /// Returns nil if the publication is not found.
    init?(publicationID: UUID, selectedTab: Binding<DetailTab>, isMultiSelection: Bool = false, selectedPublicationIDs: Set<UUID> = [], onDownloadPDFs: (() -> Void)? = nil) {
        guard let model = RustStoreAdapter.shared.getPublicationDetail(id: publicationID) else {
            return nil
        }
        let localPaper = LocalPaper(from: model)
        self.paper = localPaper
        self.publicationID = publicationID
        self._selectedTab = selectedTab
        self.isMultiSelection = isMultiSelection
        self.selectedPublicationIDs = selectedPublicationIDs
        self.onDownloadPDFs = onDownloadPDFs
        self._cachedPublication = State(initialValue: model)
    }

    // MARK: - Body

    var body: some View {
        let bodyStart = CFAbsoluteTimeGetCurrent()
        let _ = logger.info("DetailView.body START")
        let _ = print("DetailView.body START for \(paper.title.prefix(30))")

        // Inline toolbar + tab content in VStack.
        // Note: window .toolbar {} cannot be used here because DetailView lives inside
        // HSplitView — toolbar items duplicate on view recreation.
        //
        // NO .id(pubID) here — that would destroy and recreate the entire view tree on
        // every paper switch, killing the WKWebView inside MathJaxAbstractView and spawning
        // a new WebContent process each time. Instead, paper-specific state is reset via
        // .onChange(of: publicationID) and child views update via their own update mechanisms.
        return VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .info:
                    InfoTab(paper: paper, publicationID: publicationID)
                        .onAppear {
                            let elapsed = (CFAbsoluteTimeGetCurrent() - bodyStart) * 1000
                            logger.info("DetailView.body -> InfoTab.onAppear: \(elapsed, format: .fixed(precision: 1))ms")
                        }
                case .bibtex:
                    BibTeXTab(paper: paper, publicationID: publicationID, publicationIDs: publicationID.map { [$0] } ?? [])
                case .pdf:
                    PDFTab(paper: paper, publicationID: publicationID, selectedTab: $selectedTab, isMultiSelection: isMultiSelection)
                case .notes:
                    if let pub = publication {
                        NotesTab(publication: pub)
                    } else {
                        Color.clear
                    }
                case .source:
                    // Manuscript-only tab; publications never select it.
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // macOS: No navigation title - clean Apple Mail/Notes style.
        // (A dead `#if os(iOS)` .navigationTitle branch lived here — unreachable
        // since the whole file is `#if os(macOS)`. Removed Stage 2a.)
        .task(id: publicationID) {
            // Auto-mark as read after brief delay (Apple Mail style)
            await autoMarkAsRead()
        }
        .task(id: publicationID) {
            // Opening a paper is a user-initiated view — it belongs in Recent.
            // (Automated ingest paths must never record activity.) The
            // one-second dwell keeps arrow-key scrubbing through a list from
            // filling Recent with papers the user merely passed over; the task
            // is cancelled as soon as the selection changes.
            guard let id = publicationID else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            RustStoreAdapter.shared.recordRecentView(id: id)
        }
        .onChange(of: publicationID, initial: true) { _, newID in
            guard let id = newID else { cachedPublication = nil; return }
            cachedPublication = RustStoreAdapter.shared.getPublicationDetail(id: id)
        }
        .task {
            // One subscription replaces the legacy flag/tag observers.
            // Refresh cachedPublication only when the focused pub id
            // is among the affected set.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard case .itemsMutated(_, let ids) = event,
                      let pubID = publicationID,
                      ids.contains(pubID)
                else { continue }
                cachedPublication = RustStoreAdapter.shared.getPublicationDetail(id: pubID)
            }
        }
        // Keyboard shortcuts for tab switching (Cmd+4/5/6, Cmd+R for Notes)
        .onReceive(NotificationCenter.default.publisher(for: .showPDFTab)) { _ in
            selectedTab = .pdf
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBibTeXTab)) { _ in
            selectedTab = .bibtex
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNotesTab)) { _ in
            if canEdit {
                selectedTab = .notes
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showInfoTab)) { _ in
            selectedTab = .info
        }
        // Vim-style pane focus cycling (h/l keys) - handled by ContentView
        // These notifications are kept for backward compatibility with direct tab switching
        .onReceive(NotificationCenter.default.publisher(for: .showPreviousDetailTab)) { _ in
            cycleTab(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNextDetailTab)) { _ in
            cycleTab(direction: 1)
        }
        // Vim-style h/l for global pane focus cycling — routed through the one
        // shared single-key catalog (TriageKeyGrammar) rather than hardcoded here.
        .focusable()
        .keyboardGuarded { press in
            switch TriageKeyGrammar.command(forCharacters: press.characters) {
            case .focusPaneLeft:
                NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
                return .handled
            case .focusPaneRight:
                NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
                return .handled
            default:
                // Every other catalog command is row-scoped and belongs to the
                // list pane, not the detail pane: let it bubble.
                return .ignored
            }
        }
        // File drop support - allows dropping files to attach them to the publication
        .modifier(FileDropModifier(
            publicationID: publicationID,
            libraryID: owningLibraryID,
            handler: dropHandler,
            isTargeted: $isDropTargeted,
            onPDFImported: {
                // Switch to PDF tab when a PDF is imported
                selectedTab = .pdf
                // Trigger refresh
                dropRefreshID = UUID()
            }
        ))
    }

    // MARK: - Auto-Mark as Read

    private func autoMarkAsRead() async {
        guard let pub = publication, !pub.isRead else { return }

        // Wait 2 seconds before marking as read
        do {
            try await Task.sleep(for: .seconds(1))
            // Re-check after sleep in case publication was deleted while waiting
            guard publication != nil else { return }
            await viewModel.markAsRead(id: pub.id)
            logger.debug("Auto-marked as read: \(pub.citeKey)")
        } catch {
            // Task was cancelled (user navigated away quickly)
        }
    }

    // MARK: - Tab Cycling

    /// The publication kind's tabs, for THIS paper.
    ///
    /// `PublicationRecordKind.descriptor` declares the order
    /// (info → pdf → notes → bibtex) and the availability rule for Notes
    /// (`isEditable`), which is the same pair of facts this file used to state
    /// as a literal array plus a hand-written skip. The descriptor's
    /// `DetailTabSpec`/`coercedTab` machinery had view-side consumers for
    /// manuscripts, messages, figures and agent runs — publications, the kind
    /// it was modelled on, were the ones still hardcoding it.
    private var availableTabs: [DetailTab] {
        PublicationRecordKind.descriptor.availableTabs(for: tabContext)
    }

    private var tabContext: RecordTabContext {
        RecordTabContext(isEditable: canEdit)
    }

    /// Cycle through detail tabs (h/l vim keys).
    ///
    /// Order and membership come from the descriptor, so a tab that is not
    /// available for this paper is simply not in the ring — the old code
    /// carried Notes in the array and then stepped over it with a second copy
    /// of the wrap-around arithmetic, which is where an "unreachable" tab or a
    /// double-skip hides.
    private func cycleTab(direction: Int) {
        let tabs = availableTabs
        guard !tabs.isEmpty else { return }
        guard let currentIndex = tabs.firstIndex(of: selectedTab) else {
            // The selected tab is not valid for this paper (a persisted tab, a
            // paper that just lost editability): land on the descriptor's
            // coercion instead of doing nothing.
            selectedTab = PublicationRecordKind.descriptor.coercedTab(
                selectedTab, for: tabContext)
            return
        }
        let count = tabs.count
        selectedTab = tabs[((currentIndex + direction) % count + count) % count]
    }

    // MARK: - Navigation Subtitle

    private var navigationSubtitle: String {
        var subtitle: String
        if let pub = publication {
            subtitle = pub.citeKey
        } else {
            subtitle = paper.authorDisplayString
        }

        // Add multi-selection indicator
        if isMultiSelection {
            subtitle += " - \(selectedPublicationIDs.count) papers selected"
        }

        return subtitle
    }

    // MARK: - Actions

    private func openPDF() {
        Task {
            if let url = await paper.pdfURL() {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
            }
        }
    }

}

// MARK: - File Drop Modifier

/// View modifier that enables file drop support on the detail view.
/// Dropped files become attachments; PDFs become the preferred PDF.
private struct FileDropModifier: ViewModifier {
    let publicationID: UUID?
    let libraryID: UUID?
    var handler: FileDropHandler
    @Binding var isTargeted: Bool
    var onPDFImported: (() -> Void)?

    @State private var showDuplicateAlert = false

    func body(content: Content) -> some View {
        @Bindable var dropHandler = handler
        return content
            .overlay(dropOverlay)
            .modifier(FileDropTargetModifier(
                publicationID: publicationID,
                libraryID: libraryID,
                handler: handler,
                isTargeted: $isTargeted
            ))
            .alert("Duplicate File", isPresented: $showDuplicateAlert, presenting: dropHandler.pendingDuplicate) { pending in
                Button("Import") {
                    handler.resolveDuplicate(proceed: true)
                }
                Button("Skip", role: .cancel) {
                    handler.resolveDuplicate(proceed: false)
                }
            } message: { pending in
                Text("'\(pending.sourceURL.lastPathComponent)' appears to be identical to '\(pending.existingFilename)'. Import anyway?")
            }
            .onChange(of: dropHandler.pendingDuplicate) { _, newValue in
                showDuplicateAlert = newValue != nil
            }
            .onChange(of: handler.isImporting) { wasImporting, isImporting in
                // When import finishes, check if a PDF was added
                if wasImporting && !isImporting {
                    onPDFImported?()
                }
            }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isTargeted {
            ZStack {
                Color.accentColor.opacity(0.1)

                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)

                    Text("Drop files to attach")
                        .font(.headline)

                    Text("PDFs will become the preferred PDF")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .allowsHitTesting(false)
        }
    }
}

/// Helper modifier for applying the file drop target
private struct FileDropTargetModifier: ViewModifier {
    let publicationID: UUID?
    let libraryID: UUID?
    var handler: FileDropHandler
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let pubID = publicationID {
            content
                .onDrop(of: FileDropHandler.acceptedTypes, isTargeted: $isTargeted) { providers in
                    Task { @MainActor in
                        await handler.handleDrop(
                            providers: providers,
                            for: pubID,
                            in: libraryID
                        )
                    }
                    return true
                }
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        // Preview requires a real publication ID from the store; use a placeholder
        Text("DetailView preview requires RustStoreAdapter data")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environment(LibraryViewModel())
    .environment(LibraryManager())
}
#endif
