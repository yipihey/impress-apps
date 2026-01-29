//
//  DetailView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog
#if os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "unifieddetail")

// MARK: - Notifications

extension Notification.Name {
    static let pdfImportedFromBrowser = Notification.Name("pdfImportedFromBrowser")
}

// MARK: - Unified Detail Tab

enum DetailTab: String, CaseIterable {
    case info
    case pdf
    case notes
    case bibtex
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

    /// The underlying Core Data publication (enables editing for library papers)
    let publication: CDPublication?

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

    // MARK: - Computed Properties

    /// Whether this paper supports editing (local library papers only)
    private var canEdit: Bool {
        publication != nil
    }

    /// Whether this is a persistent (library) paper
    private var isPersistent: Bool {
        paper.sourceType.isPersistent
    }

    /// The owning library for this publication (for file drop imports)
    private var owningLibrary: CDLibrary? {
        publication?.libraries?.first
    }

    // MARK: - Initialization

    init(paper: any PaperRepresentable, publication: CDPublication? = nil, selectedTab: Binding<DetailTab>, isMultiSelection: Bool = false, selectedPublicationIDs: Set<UUID> = [], onDownloadPDFs: (() -> Void)? = nil) {
        self.paper = paper
        self.publication = publication
        self._selectedTab = selectedTab
        self.isMultiSelection = isMultiSelection
        self.selectedPublicationIDs = selectedPublicationIDs
        self.onDownloadPDFs = onDownloadPDFs
    }

    /// Primary initializer for CDPublication (ADR-016: all papers are CDPublication)
    /// Returns nil if the publication has been deleted
    init?(publication: CDPublication, libraryID: UUID, selectedTab: Binding<DetailTab>, isMultiSelection: Bool = false, selectedPublicationIDs: Set<UUID> = [], onDownloadPDFs: (() -> Void)? = nil) {
        let start = CFAbsoluteTimeGetCurrent()
        // Guard against deleted Core Data objects
        guard let localPaper = LocalPaper(publication: publication, libraryID: libraryID) else {
            return nil
        }
        self.paper = localPaper
        self.publication = publication
        self._selectedTab = selectedTab
        self.isMultiSelection = isMultiSelection
        self.selectedPublicationIDs = selectedPublicationIDs
        self.onDownloadPDFs = onDownloadPDFs
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        logger.info("DetailView.init: \(elapsed, format: .fixed(precision: 1))ms")
    }

    // MARK: - Body

    var body: some View {
        let bodyStart = CFAbsoluteTimeGetCurrent()
        let _ = logger.info("DetailView.body START")
        let _ = print("DetailView.body START for \(paper.title.prefix(30))")

        // OPTIMIZATION: Add id() modifiers for stable view identity per publication.
        // This prevents SwiftUI from doing expensive diffing when switching papers.
        let pubID = publication?.id

        // Tab content with toolbar in proper position
        return Group {
            switch selectedTab {
            case .info:
                InfoTab(paper: paper, publication: publication)
                    .onAppear {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - bodyStart) * 1000
                        logger.info("DetailView.body -> InfoTab.onAppear: \(elapsed, format: .fixed(precision: 1))ms")
                    }
            case .bibtex:
                BibTeXTab(paper: paper, publication: publication, publications: publication.map { [$0] } ?? [])
            case .pdf:
                PDFTab(paper: paper, publication: publication, selectedTab: $selectedTab, isMultiSelection: isMultiSelection)
            case .notes:
                if let pub = publication {
                    NotesTab(publication: pub)
                } else {
                    Color.clear
                }
            }
        }
        .id(pubID)  // Stable identity per publication
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        // macOS: Use window toolbar for proper positioning at top
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                tabPickerToolbarContent
            }
        }
        #else
        // iOS: Use inline toolbar
        .safeAreaInset(edge: .top, spacing: 0) {
            detailToolbar
        }
        #endif
        // Match the paper title to the navigation bar
        .navigationTitle(paper.title)
        .task(id: publication?.id) {
            // Auto-mark as read after brief delay (Apple Mail style)
            await autoMarkAsRead()

            // Auto-enrich on view if needed (for ref/cite counts and other metadata)
            if let pub = publication, pub.needsEnrichment {
                await EnrichmentCoordinator.shared.queueForEnrichment(pub, priority: .recentlyViewed)
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
        // Vim-style tab cycling (h/l keys)
        .onReceive(NotificationCenter.default.publisher(for: .showPreviousDetailTab)) { _ in
            cycleTab(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNextDetailTab)) { _ in
            cycleTab(direction: 1)
        }
        // File drop support - allows dropping files to attach them to the publication
        .modifier(FileDropModifier(
            publication: publication,
            library: owningLibrary,
            handler: dropHandler,
            isTargeted: $isDropTargeted,
            onPDFImported: {
                // Switch to PDF tab when a PDF is imported
                selectedTab = .pdf
                // Trigger refresh
                dropRefreshID = UUID()
            }
        ))
        // Update PDF tab when files are dropped
        .id(dropRefreshID)
    }

    // MARK: - Auto-Mark as Read

    private func autoMarkAsRead() async {
        guard let pub = publication, !pub.isRead else { return }

        // Wait 1 second before marking as read (like Mail)
        do {
            try await Task.sleep(for: .seconds(1))
            await viewModel.markAsRead(pub)
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

    // MARK: - macOS Toolbar Content

    #if os(macOS)
    /// Tab picker and action buttons for the macOS window toolbar
    @ViewBuilder
    private var tabPickerToolbarContent: some View {
        // Tab Picker (no background - buttons appear directly on toolbar)
        HStack(spacing: 2) {
            tabButton(tab: .info, label: "Info", icon: "info.circle")
            tabButton(tab: .pdf, label: "PDF", icon: "doc.richtext")
            if canEdit {
                tabButton(tab: .notes, label: "Notes", icon: "note.text")
            }
            tabButton(tab: .bibtex, label: "BibTeX", icon: "chevron.left.forwardslash.chevron.right")
        }

        Spacer()

        // Action buttons (compact, smaller icons)
        HStack(spacing: 6) {
            // Copy BibTeX
            Button {
                copyBibTeX()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy BibTeX to clipboard")

            // Open in Browser
            if let webURL = publication?.webURLObject {
                Link(destination: webURL) {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open paper's web page")
            }

            // Share menu
            if let pub = publication {
                Menu {
                    // Native ShareLink for AirDrop, Messages, etc.
                    ShareLink(
                        item: ShareablePublication(from: pub),
                        preview: SharePreview(
                            pub.title ?? "Paper",
                            image: Image(systemName: "doc.text")
                        )
                    ) {
                        Label("Share Paper...", systemImage: "square.and.arrow.up")
                    }

                    ShareLink(
                        item: shareText(for: pub),
                        subject: Text(pub.title ?? "Paper"),
                        message: Text(shareText(for: pub))
                    ) {
                        Label("Share Citation...", systemImage: "text.bubble")
                    }

                    Divider()

                    Button {
                        copyBibTeX()
                    } label: {
                        Label("Copy BibTeX", systemImage: "doc.on.doc")
                    }

                    Button {
                        copyLink(for: pub)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }

                    Divider()

                    Button {
                        shareViaEmail(pub)
                    } label: {
                        Label("Email with PDF & BibTeX...", systemImage: "envelope.badge.fill")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .help("Share options")
            }

            // Pop-out button - opens current tab in separate window
            if let pub = publication {
                Divider()
                    .frame(height: 16)

                Button {
                    openInSeparateWindow(pub)
                } label: {
                    Image(systemName: ScreenConfigurationObserver.shared.hasSecondaryScreen
                          ? "rectangle.portrait.on.rectangle.portrait.angled"
                          : "uiwindow.split.2x1")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(ScreenConfigurationObserver.shared.hasSecondaryScreen
                      ? "Open \(selectedTab.rawValue) on secondary display"
                      : "Open \(selectedTab.rawValue) in new window")
            }
        }
    }

    /// Open the current tab in a separate window
    private func openInSeparateWindow(_ publication: CDPublication) {
        let detachedTab: DetachedTab
        switch selectedTab {
        case .info: detachedTab = .info
        case .bibtex: detachedTab = .bibtex
        case .pdf: detachedTab = .pdf
        case .notes: detachedTab = .notes
        }

        DetailWindowController.shared.openTab(detachedTab, for: publication, library: libraryManager.activeLibrary)
    }
    #endif

    // MARK: - Inline Toolbar

    /// Compact toolbar at the top of the detail view (both platforms)
    private var detailToolbar: some View {
        HStack(spacing: 8) {
            // Tab Picker (no background - buttons appear directly)
            HStack(spacing: 2) {
                tabButton(tab: .info, label: "Info", icon: "info.circle")
                tabButton(tab: .pdf, label: "PDF", icon: "doc.richtext")
                if canEdit {
                    tabButton(tab: .notes, label: "Notes", icon: "note.text")
                }
                tabButton(tab: .bibtex, label: "BibTeX", icon: "chevron.left.forwardslash.chevron.right")
            }

            Spacer()

            // Action buttons (compact, smaller icons)
            HStack(spacing: 6) {
                // Copy BibTeX
                Button {
                    copyBibTeX()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy BibTeX to clipboard")

                // Open in Browser
                if let webURL = publication?.webURLObject {
                    Link(destination: webURL) {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Open paper's web page")
                }

                // Share menu
                if let pub = publication {
                    Menu {
                        // Native ShareLink for AirDrop, Messages, etc.
                        ShareLink(
                            item: ShareablePublication(from: pub),
                            preview: SharePreview(
                                pub.title ?? "Paper",
                                image: Image(systemName: "doc.text")
                            )
                        ) {
                            Label("Share Paper...", systemImage: "square.and.arrow.up")
                        }

                        ShareLink(
                            item: shareText(for: pub),
                            subject: Text(pub.title ?? "Paper"),
                            message: Text(shareText(for: pub))
                        ) {
                            Label("Share Citation...", systemImage: "text.bubble")
                        }

                        Divider()

                        Button {
                            copyBibTeX()
                        } label: {
                            Label("Copy BibTeX", systemImage: "doc.on.doc")
                        }

                        Button {
                            copyLink(for: pub)
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }

                        #if os(macOS)
                        Divider()

                        Button {
                            shareViaEmail(pub)
                        } label: {
                            Label("Email with PDF & BibTeX...", systemImage: "envelope.badge.fill")
                        }
                        #endif
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .help("Share options")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            // Match list header background using theme colors
            if let tint = theme.listBackgroundTint {
                tint.opacity(theme.listBackgroundTintOpacity)
            } else {
                Color.clear
            }
        }
    }

    /// Individual tab button for the compact tab picker
    private func tabButton(tab: DetailTab, label: String, icon: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(label, systemImage: icon)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
    }

    // MARK: - Window Toolbar (for multi-selection mode only)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Only show window toolbar items in multi-selection mode
        if isMultiSelection, let onDownloadPDFs = onDownloadPDFs {
            ToolbarItemGroup {
                Button {
                    onDownloadPDFs()
                } label: {
                    Label("Download PDFs (\(selectedPublicationIDs.count))", systemImage: "arrow.down.doc")
                }
                .help("Download PDFs for all selected papers")
            }
        }
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

    private func copyBibTeX() {
        Task {
            let bibtex: String
            if let pub = publication {
                // For library papers, use stored BibTeX
                let entry = pub.toBibTeXEntry()
                bibtex = BibTeXExporter().export([entry])
            } else {
                // For online papers, generate from metadata
                let entry = BibTeXExporter.generateEntry(from: paper)
                bibtex = BibTeXExporter().export([entry])
            }

            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bibtex, forType: .string)
            #endif
        }
    }

    private func copyLink(for pub: CDPublication) {
        var link: String?

        // Prefer DOI
        if let doi = pub.doi, !doi.isEmpty {
            link = "https://doi.org/\(doi)"
        }
        // Then arXiv
        else if let arxivID = pub.arxivID, !arxivID.isEmpty {
            link = "https://arxiv.org/abs/\(arxivID)"
        }
        // Then ADS bibcode
        else if let bibcode = pub.originalSourceID, bibcode.count == 19 {
            link = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
        }
        // Then any explicit URL field
        else if let urlString = pub.fields["url"], !urlString.isEmpty {
            link = urlString
        }

        if let link {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            #endif
        }
    }

    #if os(macOS)
    private func shareViaEmail(_ pub: CDPublication) {
        // Build email body with abstract
        var body: [String] = []

        // Title
        body.append(pub.title ?? "Untitled")
        body.append("")

        // Authors
        let authors = pub.sortedAuthors.map { $0.displayName }
        if !authors.isEmpty {
            body.append("Authors: \(authors.joined(separator: ", "))")
        }

        // Year and venue
        if pub.year > 0 {
            let venue = pub.fields["journal"] ?? pub.fields["booktitle"] ?? ""
            if !venue.isEmpty {
                body.append("Published: \(venue), \(pub.year)")
            } else {
                body.append("Year: \(pub.year)")
            }
        }

        // URL
        if let doi = pub.doi, !doi.isEmpty {
            body.append("Link: https://doi.org/\(doi)")
        } else if let arxivID = pub.arxivID, !arxivID.isEmpty {
            body.append("Link: https://arxiv.org/abs/\(arxivID)")
        } else if let bibcode = pub.originalSourceID, bibcode.count == 19 {
            body.append("Link: https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }

        // Abstract
        if let abstract = pub.abstract, !abstract.isEmpty {
            body.append("")
            body.append("Abstract:")
            body.append(abstract)
        }

        // Citation key
        body.append("")
        body.append("---")
        body.append("Citation key: \(pub.citeKey)")

        let emailBody = body.joined(separator: "\n")

        // Build items to share
        var items: [Any] = [emailBody]

        // Add PDF attachments
        if let linkedFiles = pub.linkedFiles {
            for file in linkedFiles where file.isPDF {
                if let url = AttachmentManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) {
                    items.append(url)
                }
            }
        }

        // Create temporary BibTeX file
        let bibtex = BibTeXExporter().export([pub.toBibTeXEntry()])
        let tempBibURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(pub.citeKey).bib")
        if let _ = try? bibtex.write(to: tempBibURL, atomically: true, encoding: .utf8) {
            items.append(tempBibURL)
        }

        // Show sharing service picker
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
    #endif

    /// Generate share text for a publication (used by ShareLink)
    private func shareText(for pub: CDPublication) -> String {
        var lines: [String] = []

        // Title
        lines.append(pub.title ?? "Untitled")

        // Authors
        let authors = pub.sortedAuthors.map { $0.displayName }
        if !authors.isEmpty {
            lines.append(authors.joined(separator: ", "))
        }

        // Year and venue (journal or booktitle)
        var yearVenue: [String] = []
        if pub.year > 0 {
            yearVenue.append("(\(pub.year))")
        }
        let venue = pub.fields["journal"] ?? pub.fields["booktitle"]
        if let venue, !venue.isEmpty {
            yearVenue.append(venue)
        }
        if !yearVenue.isEmpty {
            lines.append(yearVenue.joined(separator: " "))
        }

        // URL (prefer DOI, then arXiv, then ADS)
        if let doi = pub.doi, !doi.isEmpty {
            lines.append("")
            lines.append("https://doi.org/\(doi)")
        } else if let arxivID = pub.arxivID, !arxivID.isEmpty {
            lines.append("")
            lines.append("https://arxiv.org/abs/\(arxivID)")
        } else if let bibcode = pub.originalSourceID, bibcode.count == 19 {
            // ADS bibcode format
            lines.append("")
            lines.append("https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }

        // Citation key for reference
        lines.append("")
        lines.append("Citation key: \(pub.citeKey)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Flow Layout

/// A layout that arranges views horizontally and wraps to new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return layout(sizes: sizes, containerWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = layout(sizes: sizes, containerWidth: bounds.width).offsets

        for (subview, offset) in zip(subviews, offsets) {
            subview.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(sizes: [CGSize], containerWidth: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for size in sizes {
            if currentX + size.width > containerWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return (offsets, CGSize(width: maxWidth, height: currentY + lineHeight))
    }
}

// MARK: - File Drop Modifier

/// View modifier that enables file drop support on the detail view.
/// Dropped files become attachments; PDFs become the preferred PDF.
private struct FileDropModifier: ViewModifier {
    let publication: CDPublication?
    let library: CDLibrary?
    var handler: FileDropHandler
    @Binding var isTargeted: Bool
    var onPDFImported: (() -> Void)?

    @State private var showDuplicateAlert = false

    func body(content: Content) -> some View {
        @Bindable var dropHandler = handler
        return content
            .overlay(dropOverlay)
            .modifier(FileDropTargetModifier(
                publication: publication,
                library: library,
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
    let publication: CDPublication?
    let library: CDLibrary?
    var handler: FileDropHandler
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let pub = publication {
            content
                .fileDropTarget(
                    for: pub,
                    in: library,
                    handler: handler,
                    isTargeted: $isTargeted
                )
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview {
    // Create a sample CDPublication for preview
    let publication = PersistenceController.preview.viewContext.performAndWait {
        let pub = CDPublication(context: PersistenceController.preview.viewContext)
        pub.id = UUID()
        pub.citeKey = "Smith2024Deep"
        pub.entryType = "inproceedings"
        pub.title = "Deep Learning for Natural Language Processing"
        pub.year = 2024
        pub.dateAdded = Date()
        pub.dateModified = Date()
        pub.abstract = "This paper presents a novel approach to natural language processing using deep learning techniques..."

        var fields: [String: String] = [:]
        fields["author"] = "Smith, John and Doe, Jane and Wilson, Bob"
        fields["booktitle"] = "Conference on Machine Learning"
        fields["doi"] = "10.1234/example.2024.001"
        pub.fields = fields

        return pub
    }

    let libraryID = UUID()

    NavigationStack {
        DetailView(publication: publication, libraryID: libraryID, selectedTab: .constant(.info))
    }
    .environment(LibraryViewModel())
    .environment(LibraryManager(persistenceController: .preview))
}
