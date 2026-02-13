//
//  DetailView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PublicationManagerCore
import ImpressKeyboard
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

    /// The full publication model (fetched from Rust store by UUID).
    /// Returns nil for non-library papers (search results, etc.).
    private var publication: PublicationModel? {
        guard let id = publicationID else { return nil }
        return RustStoreAdapter.shared.getPublicationDetail(id: id)
    }

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
    }

    // MARK: - Body

    var body: some View {
        let bodyStart = CFAbsoluteTimeGetCurrent()
        let _ = logger.info("DetailView.body START")
        let _ = print("DetailView.body START for \(paper.title.prefix(30))")

        // OPTIMIZATION: Add id() modifiers for stable view identity per publication.
        // This prevents SwiftUI from doing expensive diffing when switching papers.
        let pubID = publication?.id

        // Inline toolbar + tab content in VStack.
        // Note: window .toolbar {} cannot be used here because DetailView lives inside
        // HSplitView with .id() modifiers — toolbar items duplicate on view recreation.
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(pubID)  // Stable identity per publication
        #if os(iOS)
        // iOS: Show paper title in navigation bar
        .navigationTitle(paper.title)
        #endif
        // macOS: No navigation title - clean Apple Mail/Notes style
        .task(id: publicationID) {
            // Auto-mark as read after brief delay (Apple Mail style)
            await autoMarkAsRead()
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
        // Vim-style h/l for global pane focus cycling
        .focusable()
        .keyboardGuarded { press in
            // h key: cycle pane focus left
            if press.characters == "h" {
                NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
                return .handled
            }
            // l key: cycle pane focus right
            if press.characters == "l" {
                NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
                return .handled
            }
            return .ignored
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

    /// Cycle through detail tabs (h/l vim keys)
    /// Order: info → pdf → notes → bibtex → info...
    private func cycleTab(direction: Int) {
        let tabs: [DetailTab] = [.info, .pdf, .notes, .bibtex]
        guard let currentIndex = tabs.firstIndex(of: selectedTab) else { return }

        var newIndex = currentIndex + direction
        if newIndex < 0 {
            newIndex = tabs.count - 1
        } else if newIndex >= tabs.count {
            newIndex = 0
        }

        // Skip notes tab if not editable (non-library papers)
        if tabs[newIndex] == .notes && !canEdit {
            newIndex = newIndex + direction
            if newIndex < 0 {
                newIndex = tabs.count - 1
            } else if newIndex >= tabs.count {
                newIndex = 0
            }
        }

        selectedTab = tabs[newIndex]
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
