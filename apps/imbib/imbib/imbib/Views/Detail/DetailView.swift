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

    @StateObject private var dropHandler = FileDropHandler()
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
        logger.info("⏱ DetailView.init: \(elapsed, format: .fixed(precision: 1))ms")
    }

    // MARK: - Body

    var body: some View {
        let bodyStart = CFAbsoluteTimeGetCurrent()
        let _ = logger.info("⏱ DetailView.body START")
        let _ = print("⏱ DetailView.body START for \(paper.title.prefix(30))")

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
                        logger.info("⏱ DetailView.body → InfoTab.onAppear: \(elapsed, format: .fixed(precision: 1))ms")
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
            subtitle += " — \(selectedPublicationIDs.count) papers selected"
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
            tabButton(tab: .bibtex, label: "BibTeX", icon: "chevron.left.forwardslash.chevron.right")
            tabButton(tab: .pdf, label: "PDF", icon: "doc.richtext")
            if canEdit {
                tabButton(tab: .notes, label: "Notes", icon: "note.text")
            }
        }

        Spacer()

        // Action buttons (compact, smaller icons)
        HStack(spacing: 6) {
            // Copy BibTeX
            Button {
                copyBibTeX()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy BibTeX to clipboard")

            // Open in Browser
            if let webURL = publication?.webURLObject {
                Link(destination: webURL) {
                    Image(systemName: "link")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open paper's web page")
            }

            // Share menu
            if let pub = publication {
                Menu {
                    ShareLink(
                        item: shareText(for: pub),
                        subject: Text(pub.title ?? "Paper"),
                        message: Text(shareText(for: pub))
                    ) {
                        Label("Share Text...", systemImage: "text.bubble")
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
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
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
                        .font(.caption)
                }
                .buttonStyle(.borderless)
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
                tabButton(tab: .bibtex, label: "BibTeX", icon: "chevron.left.forwardslash.chevron.right")
                tabButton(tab: .pdf, label: "PDF", icon: "doc.richtext")
                if canEdit {
                    tabButton(tab: .notes, label: "Notes", icon: "note.text")
                }
            }

            Spacer()

            // Action buttons (compact, smaller icons)
            HStack(spacing: 6) {
                // Copy BibTeX
                Button {
                    copyBibTeX()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy BibTeX to clipboard")

                // Open in Browser
                if let webURL = publication?.webURLObject {
                    Link(destination: webURL) {
                        Image(systemName: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open paper's web page")
                }

                // Share menu
                if let pub = publication {
                    Menu {
                        ShareLink(
                            item: shareText(for: pub),
                            subject: Text(pub.title ?? "Paper"),
                            message: Text(shareText(for: pub))
                        ) {
                            Label("Share Text...", systemImage: "text.bubble")
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
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
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
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
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
                if let url = PDFManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) {
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

// MARK: - Unified Detail Tab

enum DetailTab: String, CaseIterable {
    case info
    case bibtex
    case pdf
    case notes
}

// MARK: - Notes Position

/// Position of the notes panel relative to the PDF viewer.
enum NotesPosition: String, CaseIterable {
    case below = "below"
    case right = "right"
    case left = "left"

    var label: String {
        switch self {
        case .below: return "Below PDF"
        case .right: return "Right of PDF"
        case .left: return "Left of PDF"
        }
    }
}

// MARK: - Info Tab

private let infoTabLogger = Logger(subsystem: "com.imbib.app", category: "infotab")

struct InfoTab: View {
    let paper: any PaperRepresentable
    let publication: CDPublication?

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme
    @Environment(\.fontScale) private var fontScale

    // State for attachment deletion
    @State private var fileToDelete: CDLinkedFile?
    @State private var showDeleteConfirmation = false

    // State for file drop
    @StateObject private var dropHandler = FileDropHandler()
    @State private var isDropTargeted = false
    @State private var showFileImporter = false

    // State for duplicate file alert (drop handler)
    @State private var showDuplicateAlert = false
    @State private var duplicateFilename = ""

    // State for duplicate PDF from browser
    @State private var showBrowserDuplicateAlert = false
    @State private var browserDuplicateFilename = ""
    @State private var browserDuplicateData: Data?
    @State private var browserDuplicatePublication: CDPublication?

    // Refresh trigger for attachments section
    @State private var attachmentsRefreshID = UUID()

    // Timing for body evaluation
    @State private var bodyStartTime: CFAbsoluteTime = 0

    // State for exploration (references/citations)
    @State private var isExploringReferences = false
    @State private var isExploringCitations = false
    @State private var isExploringSimilar = false
    @State private var isExploringCoReads = false
    @State private var explorationError: String?

    // Refresh trigger for when enrichment completes
    @State private var enrichmentRefreshID = UUID()

    var body: some View {
        let bodyStart = CFAbsoluteTimeGetCurrent()

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // MARK: - Email-Style Header
                    headerSection
                        .id("top")

                    Divider()

                    // MARK: - Explore (References & Citations)
                    if canExploreReferences {
                        exploreSection
                            .id(enrichmentRefreshID)  // Refresh when enrichment data arrives
                        Divider()
                    }

                    // MARK: - Abstract (Body)
                    if let abstract = paper.abstract, !abstract.isEmpty {
                        infoSection("Abstract") {
                            // Base font size is 21 (1.5x larger than body text), scaled by user preference
                            MathJaxAbstractView(text: abstract, fontSize: 21 * fontScale)
                        }
                        Divider()
                    }

                    // MARK: - PDF Sources
                    if let pub = publication {
                        let sourcesStart = CFAbsoluteTimeGetCurrent()
                        let sources = collectPDFSources(for: pub)
                        let sourcesElapsed = (CFAbsoluteTimeGetCurrent() - sourcesStart) * 1000
                        let _ = infoTabLogger.info("⏱ collectPDFSources: \(sourcesElapsed, format: .fixed(precision: 1))ms (\(sources.count) sources)")

                        if !sources.isEmpty {
                            pdfSourcesSection(sources, publication: pub)
                            Divider()
                        }
                    }

                    // MARK: - Attachments Section with Drop Target
                    if let pub = publication {
                        let attachStart = CFAbsoluteTimeGetCurrent()
                        let attachView = attachmentsSectionWithDrop(pub)
                        let attachElapsed = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
                        let _ = infoTabLogger.info("⏱ attachmentsSectionWithDrop: \(attachElapsed, format: .fixed(precision: 1))ms")

                        attachView
                            .id(attachmentsRefreshID)
                        Divider()
                    }

                    // MARK: - Identifiers (compact row)
                    if hasIdentifiers {
                        identifiersSection
                        Divider()
                    }

                    // MARK: - Record Info
                    if let pub = publication {
                        recordInfoSection(pub)
                            .id(enrichmentRefreshID)  // Refresh when enrichment data arrives
                    }

                    Spacer()
                }
                .padding()
            }
            .onChange(of: paper.id, initial: true) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
            .scrollContentBackground(theme.detailBackground != nil ? .hidden : .automatic)
        }
        .onAppear {
            let elapsed = (CFAbsoluteTimeGetCurrent() - bodyStart) * 1000
            infoTabLogger.info("⏱ InfoTab.body onAppear: \(elapsed, format: .fixed(precision: 1))ms total")
        }
        .confirmationDialog(
            "Delete Attachment?",
            isPresented: $showDeleteConfirmation,
            presenting: fileToDelete
        ) { file in
            Button("Delete", role: .destructive) {
                deleteFile(file)
            }
        } message: { file in
            Text("Delete \"\(file.filename)\"? This cannot be undone.")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],  // Accept any file type
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
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
        .alert("Duplicate PDF", isPresented: $showBrowserDuplicateAlert) {
            Button("Skip") {
                browserDuplicateData = nil
                browserDuplicatePublication = nil
            }
            Button("Import Anyway") {
                importBrowserPDF()
            }
        } message: {
            Text("This PDF is identical to '\(browserDuplicateFilename)' which is already attached. Do you want to import it anyway?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfImportedFromBrowser)) { notification in
            // Refresh attachments section when a PDF is imported from browser
            if let objectID = notification.object as? NSManagedObjectID,
               objectID == publication?.objectID {
                attachmentsRefreshID = UUID()
                Logger.files.infoCapture("[InfoTab] Refreshing attachments after PDF import", category: "pdf")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .publicationEnrichmentDidComplete)) { notification in
            // Refresh view when enrichment data becomes available for this publication
            if let enrichedID = notification.userInfo?["publicationID"] as? UUID,
               enrichedID == publication?.id {
                enrichmentRefreshID = UUID()
                infoTabLogger.info("Refreshing InfoTab after enrichment completed for \(publication?.citeKey ?? "unknown")")
            }
        }
        .alert("Exploration Error", isPresented: .constant(explorationError != nil)) {
            Button("OK") {
                explorationError = nil
            }
        } message: {
            if let error = explorationError {
                Text(error)
            }
        }
    }

    // MARK: - Header Section (Email-Style)

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // From: Authors (expandable if more than 10)
            infoRow("From") {
                ExpandableAuthorList(authors: paper.authors)
                    .font(.system(size: 21 * fontScale))
            }

            // Year
            if let year = paper.year {
                infoRow("Year") {
                    Text(String(year))
                }
            }

            // Subject: Title
            infoRow("Subject") {
                Text(paper.title)
                    .font(.system(size: 21 * fontScale))
                    .textSelection(.enabled)
            }

            // Venue
            if let venue = paper.venue {
                infoRow("Venue") {
                    Text(JournalMacros.expand(venue))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Identifiers Section

    private var hasIdentifiers: Bool {
        paper.doi != nil || paper.arxivID != nil || paper.bibcode != nil || paper.pmid != nil
    }

    @ViewBuilder
    private var identifiersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            FlowLayout(spacing: 12) {
                if let doi = paper.doi {
                    identifierLink("DOI", value: doi, url: "https://doi.org/\(doi)")
                        .help("Open DOI resolver")
                }
                if let arxivID = paper.arxivID {
                    identifierLink("arXiv", value: arxivID, url: "https://arxiv.org/abs/\(arxivID)")
                        .help("Open on arXiv")
                }
                if let bibcode = paper.bibcode {
                    identifierLink("ADS", value: bibcode, url: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
                        .help("Open on NASA ADS")
                }
                if let pmid = paper.pmid {
                    identifierLink("PubMed", value: pmid, url: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)")
                        .help("Open on PubMed")
                }
            }
        }
    }

    @ViewBuilder
    private func identifierLink(_ label: String, value: String, url: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let linkURL = URL(string: url) {
                Link(value, destination: linkURL)
                    .font(.caption)
            } else {
                Text(value)
                    .font(.caption)
            }
        }
    }

    // MARK: - Explore Section (References & Citations)

    /// Whether this paper can be explored via ADS (has bibcode, DOI, or arXiv ID)
    private var canExploreReferences: Bool {
        paper.bibcode != nil || paper.doi != nil || paper.arxivID != nil
    }

    @ViewBuilder
    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Explore")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // All buttons in a single row
            HStack(spacing: 8) {
                let refAvail = publication?.referencesAvailability() ?? .notEnriched
                Button {
                    showReferences()
                } label: {
                    if isExploringReferences {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(referencesButtonLabel, systemImage: "doc.text")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(refAvail == .noResults || isExploring)
                .help(referencesHelpText(for: refAvail))

                let citeAvail = publication?.citationsAvailability() ?? .notEnriched
                Button {
                    showCitations()
                } label: {
                    if isExploringCitations {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(citationsButtonLabel, systemImage: "quote.bubble")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(citeAvail == .noResults || isExploring)
                .help(citationsHelpText(for: citeAvail))

                Button {
                    showSimilar()
                } label: {
                    if isExploringSimilar {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Similar", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isExploring)
                .help("Show papers with similar content")

                Button {
                    showCoReads()
                } label: {
                    if isExploringCoReads {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Co-Reads", systemImage: "books.vertical")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isExploring)
                .help("Show papers frequently read together")
            }
        }
    }

    /// Whether any exploration is in progress
    private var isExploring: Bool {
        isExploringReferences || isExploringCitations || isExploringSimilar || isExploringCoReads
    }

    /// Label for the references button, including count if available
    private var referencesButtonLabel: String {
        guard let pub = publication else { return "References" }
        switch pub.referencesAvailability() {
        case .hasResults(let count): return "References (\(count))"
        case .noResults: return "References (0)"
        default: return "References"
        }
    }

    /// Label for the citations button, including count if available
    private var citationsButtonLabel: String {
        guard let pub = publication else { return "Citations" }
        switch pub.citationsAvailability() {
        case .hasResults(let count): return "Citations (\(count))"
        case .noResults: return "Citations (0)"
        default: return "Citations"
        }
    }

    /// Help text for references button based on availability
    private func referencesHelpText(for availability: CDPublication.ExplorationAvailability) -> String {
        switch availability {
        case .notEnriched: return "Click to find papers this paper cites (⌘R)"
        case .hasResults(let count): return "Show \(count) referenced papers (⌘R)"
        case .noResults: return "No references available for this paper"
        case .unavailable: return "No identifiers available for lookup"
        }
    }

    /// Help text for citations button based on availability
    private func citationsHelpText(for availability: CDPublication.ExplorationAvailability) -> String {
        switch availability {
        case .notEnriched: return "Click to find papers that cite this paper (⇧⌘R)"
        case .hasResults(let count): return "Show \(count) citing papers (⇧⌘R)"
        case .noResults: return "No citations available for this paper"
        case .unavailable: return "No identifiers available for lookup"
        }
    }

    /// Show references using ExplorationService
    private func showReferences() {
        guard let pub = publication else { return }

        isExploringReferences = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore references - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreReferences(of: pub)

                await MainActor.run {
                    isExploringReferences = false
                }
            } catch {
                await MainActor.run {
                    isExploringReferences = false
                    explorationError = error.localizedDescription
                }
            }
        }
    }

    /// Show citations using ExplorationService
    private func showCitations() {
        guard let pub = publication else { return }

        isExploringCitations = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore citations - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreCitations(of: pub)

                await MainActor.run {
                    isExploringCitations = false
                }
            } catch {
                await MainActor.run {
                    isExploringCitations = false
                    explorationError = error.localizedDescription
                }
            }
        }
    }

    /// Show similar papers using ExplorationService
    private func showSimilar() {
        guard let pub = publication else { return }

        isExploringSimilar = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore similar - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreSimilar(of: pub)

                await MainActor.run {
                    isExploringSimilar = false
                }
            } catch {
                await MainActor.run {
                    isExploringSimilar = false
                    explorationError = error.localizedDescription
                }
            }
        }
    }

    /// Show co-read papers using ExplorationService
    private func showCoReads() {
        guard let pub = publication else { return }

        isExploringCoReads = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore co-reads - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreCoReads(of: pub)

                await MainActor.run {
                    isExploringCoReads = false
                }
            } catch {
                await MainActor.run {
                    isExploringCoReads = false
                    explorationError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Attachments Section with Drop Target

    @ViewBuilder
    private func attachmentsSectionWithDrop(_ pub: CDPublication) -> some View {
        let linkedFiles = Array(pub.linkedFiles ?? []).sorted { $0.dateAdded < $1.dateAdded }

        VStack(alignment: .leading, spacing: 8) {
            // Header with count and Add button
            HStack {
                Text("Attachments (\(linkedFiles.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    showFileImporter = true
                } label: {
                    Label("Add Files...", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Attach files to this paper")
            }

            // Drop zone / file list
            VStack(spacing: 4) {
                if linkedFiles.isEmpty {
                    // Empty state with drop hint
                    dropZoneEmptyState
                } else {
                    // File list
                    ForEach(linkedFiles, id: \.id) { file in
                        enhancedAttachmentRow(file)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.clear,
                        style: StrokeStyle(lineWidth: 2, dash: isDropTargeted ? [] : [5])
                    )
            )
            .fileDropTarget(
                for: pub,
                in: libraryManager.activeLibrary,
                handler: dropHandler,
                isTargeted: $isDropTargeted
            )

            // Import progress indicator
            if dropHandler.isImporting, let progress = dropHandler.importProgress {
                HStack {
                    ProgressView(value: Double(progress.current), total: Double(progress.total))
                    Text("Importing \(progress.current)/\(progress.total)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var dropZoneEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Drop files here or click Add Files...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func enhancedAttachmentRow(_ file: CDLinkedFile) -> some View {
        HStack(spacing: 8) {
            // File type icon
            FileTypeIcon(linkedFile: file, size: 20)

            // Display name with edit support (future: inline rename)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.effectiveDisplayName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Show actual filename if display name differs
                if file.displayName != nil && file.displayName != file.filename {
                    Text(file.filename)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Date added
            Text(file.dateAdded, style: .date)
                .font(.caption)
                .foregroundStyle(.tertiary)

            // File size (use cached or compute)
            Text(file.fileSize > 0 ? file.formattedFileSize : getFileSizeString(for: file))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Action buttons
            Button("Open") {
                openFile(file)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            #if os(macOS)
            Button {
                showInFinder(file)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
            #endif

            // Delete button
            Button {
                fileToDelete = file
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Delete attachment")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
        .contextMenu {
            Button("Open") { openFile(file) }
            #if os(macOS)
            Button("Show in Finder") { showInFinder(file) }
            #endif
            Divider()
            Button("Delete", role: .destructive) {
                fileToDelete = file
                showDeleteConfirmation = true
            }
        }
    }

    // MARK: - Legacy Attachments Section (for backward compatibility)

    @ViewBuilder
    private func attachmentsSection(_ linkedFiles: [CDLinkedFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments (\(linkedFiles.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(linkedFiles, id: \.id) { file in
                attachmentRow(file)
            }
        }
    }

    @ViewBuilder
    private func attachmentRow(_ file: CDLinkedFile) -> some View {
        HStack {
            FileTypeIcon(linkedFile: file, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.effectiveDisplayName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Added \(file.dateAdded.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(file.fileSize > 0 ? file.formattedFileSize : getFileSizeString(for: file))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open") {
                openFile(file)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            #if os(macOS)
            Button {
                showInFinder(file)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
            #endif

            // Delete button
            Button {
                fileToDelete = file
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Delete attachment")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Record Info Section

    @ViewBuilder
    private func recordInfoSection(_ pub: CDPublication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Record Info")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Cite Key")
                        .foregroundStyle(.secondary)
                    Text(pub.citeKey)
                        .textSelection(.enabled)
                }

                GridRow {
                    Text("Entry Type")
                        .foregroundStyle(.secondary)
                    Text(pub.entryType.capitalized)
                }

                GridRow {
                    Text("Added")
                        .foregroundStyle(.secondary)
                    Text(pub.dateAdded.formatted(date: .abbreviated, time: .omitted))
                }

                GridRow {
                    Text("Modified")
                        .foregroundStyle(.secondary)
                    Text(pub.dateModified.formatted(date: .abbreviated, time: .omitted))
                }

                GridRow {
                    Text("Read Status")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(pub.isRead ? "Read" : "Unread")
                        if pub.isRead {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                // Libraries this paper belongs to
                if let libraries = pub.libraries, !libraries.isEmpty {
                    GridRow {
                        Text(libraries.count == 1 ? "Library" : "Libraries")
                            .foregroundStyle(.secondary)
                        Text(libraries.map { $0.displayName }.sorted().joined(separator: ", "))
                            .textSelection(.enabled)
                    }
                }

                if pub.citationCount > 0 {
                    GridRow {
                        Text("Citations")
                            .foregroundStyle(.secondary)
                        Text(pub.citationCount.formatted())
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func infoRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder
    private func infoSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func getFileSize(for file: CDLinkedFile) -> Int64? {
        guard let url = PDFManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) else {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }

    private func getFileSizeString(for file: CDLinkedFile) -> String {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            infoTabLogger.info("⏱ getFileSizeString (disk I/O): \(elapsed, format: .fixed(precision: 1))ms for \(file.filename)")
        }
        if let size = getFileSize(for: file) {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return ""
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let pub = publication else { return }

        switch result {
        case .success(let urls):
            Task {
                do {
                    let _ = try AttachmentManager.shared.importAttachments(
                        from: urls,
                        for: pub,
                        in: libraryManager.activeLibrary
                    )
                    Logger.files.infoCapture("Imported \(urls.count) files via file picker", category: "files")
                } catch {
                    Logger.files.errorCapture("File import failed: \(error.localizedDescription)", category: "files")
                }
            }

        case .failure(let error):
            Logger.files.errorCapture("File picker failed: \(error.localizedDescription)", category: "files")
        }
    }

    private func openFile(_ file: CDLinkedFile) {
        guard let url = PDFManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) else {
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
    private func showInFinder(_ file: CDLinkedFile) {
        guard let url = PDFManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private func deleteFile(_ file: CDLinkedFile) {
        do {
            try PDFManager.shared.delete(file, in: libraryManager.activeLibrary)
            Logger.files.infoCapture("Deleted attachment: \(file.filename)", category: "pdf")
        } catch {
            Logger.files.errorCapture("Failed to delete attachment: \(error)", category: "pdf")
        }
    }

    // MARK: - PDF Sources Section

    /// A PDF source with URL, type and optional source ID
    private struct PDFSource: Hashable {
        let url: URL
        let type: PDFLinkType
        let sourceID: String?

        var label: String {
            let typeName = type.displayName
            if let source = sourceID, !source.isEmpty {
                return "\(typeName) (\(source.capitalized))"
            }
            return typeName
        }
    }

    /// Collect all available PDF sources for a publication
    private func collectPDFSources(for pub: CDPublication) -> [PDFSource] {
        var sources: [PDFSource] = []
        var seenURLs: Set<URL> = []

        // Add from pdfLinks array (but filter out ADS link_gateway URLs which often 404)
        for link in pub.pdfLinks {
            // Skip unreliable ADS link_gateway URLs
            if link.url.absoluteString.contains("link_gateway") {
                continue
            }
            if !seenURLs.contains(link.url) {
                sources.append(PDFSource(url: link.url, type: link.type, sourceID: link.sourceID))
                seenURLs.insert(link.url)
            }
        }

        // Add arXiv PDF URL if not already present
        if let arxivURL = pub.arxivPDFURL, !seenURLs.contains(arxivURL) {
            sources.append(PDFSource(url: arxivURL, type: .preprint, sourceID: "arXiv"))
            seenURLs.insert(arxivURL)
        }

        // Add DOI resolver for publisher access (much more reliable than ADS link_gateway)
        if let doi = pub.doi, !doi.isEmpty,
           let doiURL = URL(string: "https://doi.org/\(doi)") {
            // Only add if we don't already have a publisher link
            let hasPublisherLink = sources.contains { $0.type == .publisher }
            if !hasPublisherLink {
                sources.append(PDFSource(url: doiURL, type: .publisher, sourceID: "DOI"))
                seenURLs.insert(doiURL)
            }
        }

        // Fallback: ADS abstract page (shows all full text sources, always works)
        if let bibcode = pub.bibcode,
           let adsURL = URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/abstract") {
            // Only add if we have no other sources
            if sources.isEmpty {
                sources.append(PDFSource(url: adsURL, type: .publisher, sourceID: "ADS"))
                seenURLs.insert(adsURL)
            }
        }

        return sources
    }

    @ViewBuilder
    private func pdfSourcesSection(_ sources: [PDFSource], publication: CDPublication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PDF Sources")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(sources, id: \.self) { source in
                pdfSourceRow(source, publication: publication)
            }
        }
    }

    @ViewBuilder
    private func pdfSourceRow(_ source: PDFSource, publication: CDPublication) -> some View {
        HStack {
            // Clickable label - opens in imBib browser on macOS, system browser on iOS
            #if os(macOS)
            Button {
                Task {
                    await openInImBibBrowser(source.url, publication: publication)
                }
            } label: {
                Text(source.label)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("Open in imBib browser")
            #else
            Button {
                openInSystemBrowser(source.url)
            } label: {
                Text(source.label)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            #endif

            Spacer()

            // System browser button (Safari)
            Button {
                openInSystemBrowser(source.url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("Open in Safari")

            // imBib browser button
            #if os(macOS)
            Button {
                Task {
                    await openInImBibBrowser(source.url, publication: publication)
                }
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            .help("Open in imBib browser")
            #endif
        }
    }

    private func openInSystemBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    #if os(macOS)
    private func openInImBibBrowser(_ url: URL, publication: CDPublication) async {
        guard let library = libraryManager.activeLibrary else { return }

        await PDFBrowserWindowController.shared.openBrowser(
            for: publication,
            startURL: url,
            libraryID: library.id
        ) { [self] data in
            // Check for duplicates first
            let result = PDFManager.shared.checkForDuplicate(data: data, in: publication)

            switch result {
            case .duplicate(let existingFile, _):
                // Show duplicate alert
                await MainActor.run {
                    browserDuplicateFilename = existingFile.filename
                    browserDuplicateData = data
                    browserDuplicatePublication = publication
                    showBrowserDuplicateAlert = true
                }
                Logger.files.infoCapture("[InfoTab] Duplicate PDF detected: matches \(existingFile.filename)", category: "pdf")

            case .noDuplicate:
                // Import directly
                do {
                    try PDFManager.shared.importPDF(data: data, for: publication, in: library)
                    Logger.files.infoCapture("[InfoTab] PDF imported from browser successfully", category: "pdf")

                    await MainActor.run {
                        NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: publication.objectID)
                    }
                } catch {
                    Logger.files.errorCapture("[InfoTab] Failed to import PDF from browser: \(error)", category: "pdf")
                }
            }
        }
    }

    /// Import the pending browser PDF after user chooses "Import Anyway" for duplicate
    private func importBrowserPDF() {
        guard let data = browserDuplicateData,
              let publication = browserDuplicatePublication,
              let library = libraryManager.activeLibrary else {
            return
        }

        do {
            try PDFManager.shared.importPDF(data: data, for: publication, in: library)
            Logger.files.infoCapture("[InfoTab] Duplicate PDF imported after user confirmation", category: "pdf")

            NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: publication.objectID)
        } catch {
            Logger.files.errorCapture("[InfoTab] Failed to import duplicate PDF: \(error)", category: "pdf")
        }

        // Clear pending state
        browserDuplicateData = nil
        browserDuplicatePublication = nil
    }
    #endif
}

// MARK: - BibTeX Tab

struct BibTeXTab: View {
    let paper: any PaperRepresentable
    let publication: CDPublication?
    let publications: [CDPublication]  // For multi-selection support

    @Environment(LibraryViewModel.self) private var viewModel
    @State private var bibtexContent: String = ""
    @State private var isEditing = false
    @State private var hasChanges = false
    @State private var isLoading = false

    /// Whether editing is enabled (only for single library paper)
    private var canEdit: Bool {
        publication != nil && publications.count <= 1
    }

    /// Whether multiple papers are selected
    private var isMultiSelection: Bool {
        publications.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar (only show edit controls for library papers)
            if canEdit {
                editableToolbar
            }

            // Editor / Display
            if isLoading {
                ProgressView("Loading BibTeX...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bibtexContent.isEmpty {
                ContentUnavailableView(
                    "No BibTeX",
                    systemImage: "doc.text",
                    description: Text("BibTeX is not available for this paper")
                )
            } else {
                BibTeXEditor(
                    text: $bibtexContent,
                    isEditable: isEditing,
                    showLineNumbers: true
                ) { _ in
                    saveBibTeX()
                }
                .onChange(of: bibtexContent) { _, _ in
                    if isEditing {
                        hasChanges = true
                    }
                }
            }
        }
        .onChange(of: paper.id, initial: true) { _, _ in
            // Reset state and reload when paper changes
            bibtexContent = ""
            isEditing = false
            hasChanges = false
            loadBibTeX()
        }
    }

    @ViewBuilder
    private var editableToolbar: some View {
        HStack {
            if isEditing {
                Button("Cancel") {
                    bibtexContent = generateBibTeX()
                    isEditing = false
                    hasChanges = false
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Save") {
                    saveBibTeX()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
            } else {
                // Multi-selection indicator
                if isMultiSelection {
                    Text("\(publications.count) papers selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Copy button (always visible)
                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy BibTeX to clipboard")

                // Edit button (only for single selection)
                if !isMultiSelection {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bibtexContent, forType: .string)
        #else
        UIPasteboard.general.string = bibtexContent
        #endif
    }

    private func loadBibTeX() {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("⏱ loadBibTeX: \(elapsed, format: .fixed(precision: 1))ms")
        }

        isLoading = true
        bibtexContent = generateBibTeX()
        isLoading = false
    }

    private func generateBibTeX() -> String {
        // Multi-selection: export all selected publications
        if isMultiSelection {
            let entries = publications.map { $0.toBibTeXEntry() }
            return BibTeXExporter().export(entries)
        }
        // Single paper: ADR-016: All papers are now CDPublication
        if let pub = publication {
            let entry = pub.toBibTeXEntry()
            return BibTeXExporter().export([entry])
        }
        // Fallback for any edge cases (should not happen)
        let entry = BibTeXExporter.generateEntry(from: paper)
        return BibTeXExporter().export([entry])
    }

    private func saveBibTeX() {
        guard let pub = publication else { return }

        Task {
            do {
                let items = try BibTeXParserFactory.createParser().parse(bibtexContent)
                guard let entry = items.compactMap({ item -> BibTeXEntry? in
                    if case .entry(let entry) = item { return entry }
                    return nil
                }).first else {
                    return
                }

                await viewModel.updateFromBibTeX(pub, entry: entry)

                await MainActor.run {
                    isEditing = false
                    hasChanges = false
                }
            } catch {
                logger.error("Failed to parse BibTeX: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Multi-Selection BibTeX View

/// A simplified view shown when multiple papers are selected.
/// Only displays combined BibTeX with a Copy button.
struct MultiSelectionBibTeXView: View {
    let publications: [CDPublication]
    var onDownloadPDFs: (() -> Void)?

    /// Combined BibTeX content - computed directly from publications
    private var bibtexContent: String {
        guard !publications.isEmpty else { return "" }
        let entries = publications.compactMap { pub -> BibTeXEntry? in
            guard !pub.isDeleted, pub.managedObjectContext != nil else { return nil }
            return pub.toBibTeXEntry()
        }
        guard !entries.isEmpty else { return "" }
        return BibTeXExporter().export(entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with count and action buttons
            HStack {
                Text("\(publications.count) papers selected")
                    .font(.headline)

                Spacer()

                if let onDownloadPDFs = onDownloadPDFs {
                    Button {
                        onDownloadPDFs()
                    } label: {
                        Label("Download PDFs", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy All BibTeX", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(bibtexContent.isEmpty)
            }
            .padding()
            .background(.bar)

            Divider()

            // BibTeX content
            if bibtexContent.isEmpty {
                ContentUnavailableView(
                    "No BibTeX",
                    systemImage: "doc.text",
                    description: Text("Could not generate BibTeX for selected papers")
                )
            } else {
                ScrollView {
                    Text(bibtexContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bibtexContent, forType: .string)
        #else
        UIPasteboard.general.string = bibtexContent
        #endif
    }
}

// MARK: - PDF Tab

struct PDFTab: View {
    let paper: any PaperRepresentable
    let publication: CDPublication?
    @Binding var selectedTab: DetailTab
    var isMultiSelection: Bool = false  // Disable auto-download when multiple papers selected

    @Environment(LibraryManager.self) private var libraryManager
    @State private var linkedFile: CDLinkedFile?
    @State private var isDownloading = false
    @State private var downloadError: Error?
    @State private var hasRemotePDF = false
    @State private var checkPDFTask: Task<Void, Never>?
    @State private var showFileImporter = false
    @State private var isCheckingPDF = true  // Start in loading state
    @State private var browserFallbackURL: URL?  // URL to open in browser when publisher PDF fails

    var body: some View {
        Group {
            // ADR-016: All papers are now CDPublication
            if let linked = linkedFile, let pub = publication {
                // Has linked PDF file → show viewer only (no notes panel)
                pdfViewerOnly(linked: linked, pub: pub)
                    .id(pub.id)  // Force view recreation when paper changes to reset @State
            } else if isCheckingPDF {
                // Loading state while checking for PDFs
                ProgressView("Checking for PDF...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isDownloading {
                downloadingView
            } else if let error = downloadError {
                errorView(error)
            } else if hasRemotePDF {
                // No local PDF but remote available → show download prompt
                noPDFLibraryView
            } else {
                // No PDF available anywhere
                noPDFView
            }
        }
        .onAppear {
            // Trigger initial PDF check on first appearance
            resetAndCheckPDF()
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            // Only check PDF when switching TO the PDF tab
            if newTab == .pdf {
                resetAndCheckPDF()
            }
        }
        .onChange(of: paper.id) { _, _ in
            // Only check PDF if the PDF tab is currently visible
            if selectedTab == .pdf {
                resetAndCheckPDF()
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfImportedFromBrowser)) { notification in
            // Refresh when PDF is imported from browser for this publication
            if let objectID = notification.object as? NSManagedObjectID,
               objectID == publication?.objectID {
                resetAndCheckPDF()
            }
        }
    }

    // MARK: - PDF Viewer Only (no notes panel)

    @ViewBuilder
    private func pdfViewerOnly(linked: CDLinkedFile, pub: CDPublication) -> some View {
        PDFViewerWithControls(
            linkedFile: linked,
            library: libraryManager.activeLibrary,
            publicationID: pub.id,
            onCorruptPDF: { corruptFile in
                Task {
                    await handleCorruptPDF(corruptFile)
                }
            }
        )
    }

    // MARK: - Subviews

    private var downloadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Downloading PDF...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView {
            Label("Download Failed", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(error.localizedDescription)

                // Show the attempted URL for browser fallback (clickable to open in system browser)
                if let fallbackURL = browserFallbackURL {
                    Text("Publisher URL:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.open(fallbackURL)
                    } label: {
                        Text(fallbackURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .underline()
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                    .help("Click to open in Safari")
                    #else
                    Link(destination: fallbackURL) {
                        Text(fallbackURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .underline()
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    #endif
                }
            }
        } actions: {
            // Show "Open in Browser" as primary action when we have a fallback URL
            if let fallbackURL = browserFallbackURL {
                #if os(macOS)
                Button("Open in Browser") {
                    Task { await openPDFBrowserWithURL(fallbackURL) }
                }
                .buttonStyle(.borderedProminent)
                .help("Open publisher page in built-in browser to download PDF")
                #endif

                Button("Retry") {
                    Task { await downloadPDF() }
                }
                .buttonStyle(.bordered)
                .help("Retry PDF download")
            } else {
                Button("Retry") {
                    Task { await downloadPDF() }
                }
                .buttonStyle(.borderedProminent)
                .help("Retry PDF download")

                #if os(macOS)
                Button("Open in Browser") {
                    Task { await openPDFBrowser() }
                }
                .buttonStyle(.bordered)
                .help("Open publisher page to download PDF interactively")
                #endif
            }

            Button("Add PDF...") {
                showFileImporter = true
            }
            .buttonStyle(.bordered)
            .help("Attach a local PDF file")
        }
    }

    private var noPDFLibraryView: some View {
        ContentUnavailableView {
            Label("PDF Available", systemImage: "doc.richtext")
        } description: {
            Text("Download from online source or add a local file.")
        } actions: {
            Button("Download PDF") {
                Task { await downloadPDF() }
            }
            .buttonStyle(.borderedProminent)
            .help("Download PDF from online source")

            #if os(macOS)
            Button("Open in Browser") {
                Task { await openPDFBrowser() }
            }
            .buttonStyle(.bordered)
            .help("Open publisher page to download PDF interactively")
            #endif

            Button("Add PDF...") {
                showFileImporter = true
            }
            .buttonStyle(.bordered)
            .help("Attach a local PDF file")
        }
    }

    private var noPDFView: some View {
        ContentUnavailableView(
            "No PDF",
            systemImage: "doc.richtext",
            description: Text("No PDF is available for this paper.")
        )
    }

    // MARK: - Actions

    private func resetAndCheckPDF() {
        let start = CFAbsoluteTimeGetCurrent()
        Logger.files.infoCapture("[PDFTab] resetAndCheckPDF started", category: "pdf")

        checkPDFTask?.cancel()

        linkedFile = nil
        downloadError = nil
        browserFallbackURL = nil
        isDownloading = false
        hasRemotePDF = false
        isCheckingPDF = true  // Show loading state

        checkPDFTask = Task {
            Logger.files.infoCapture("[PDFTab] checking publication...", category: "pdf")

            // ADR-016: All papers are now CDPublication
            guard let pub = publication else {
                Logger.files.warningCapture("[PDFTab] publication is NIL!", category: "pdf")
                await MainActor.run { isCheckingPDF = false }
                return
            }

            Logger.files.infoCapture("[PDFTab] pub='\(pub.citeKey)', checking linkedFiles...", category: "pdf")

            // Check for linked PDF files
            let linkedFiles = pub.linkedFiles ?? []
            Logger.files.infoCapture("[PDFTab] linkedFiles count = \(linkedFiles.count)", category: "pdf")
            for (i, file) in linkedFiles.enumerated() {
                Logger.files.infoCapture("[PDFTab] linkedFile[\(i)]: \(file.filename), isPDF=\(file.isPDF), path=\(file.relativePath)", category: "pdf")
            }

            if let firstPDF = linkedFiles.first(where: { $0.isPDF }) ?? linkedFiles.first {
                Logger.files.infoCapture("[PDFTab] Found local PDF: \(firstPDF.filename)", category: "pdf")
                await MainActor.run {
                    linkedFile = firstPDF
                    isCheckingPDF = false
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    Logger.files.infoCapture("[PDFTab] \(String(format: "%.1f", elapsed))ms (found local PDF)", category: "pdf")
                }
                return
            }

            Logger.files.infoCapture("[PDFTab] No local PDF found, checking remote...", category: "pdf")

            // No local PDF - check if remote PDF is available
            // Check multiple sources: PDFURLResolver, pdfLinks, arxivID from fields
            let resolverHasPDF = PDFURLResolver.hasPDF(publication: pub)
            let hasPdfLinks = !pub.pdfLinks.isEmpty
            let hasArxivID = pub.arxivID != nil
            let hasEprint = pub.fields["eprint"] != nil
            let hasRemote = resolverHasPDF || hasPdfLinks || hasArxivID || hasEprint

            // Debug logging for PDF availability
            let arxivVal = pub.arxivID ?? "nil"
            let eprintVal = pub.fields["eprint"] ?? "nil"
            Logger.files.infoCapture("[PDFTab] PDF check: resolver=\(resolverHasPDF), pdfLinks=\(hasPdfLinks) (\(pub.pdfLinks.count)), arxivID=\(hasArxivID) (\(arxivVal)), eprint=\(hasEprint) (\(eprintVal)), result=\(hasRemote)", category: "pdf")

            // Log pdfLinks details if present
            for (i, link) in pub.pdfLinks.enumerated() {
                let sourceID = link.sourceID ?? "nil"
                Logger.files.infoCapture("[PDFTab] pdfLink[\(i)]: \(link.url.absoluteString) type=\(String(describing: link.type)) source=\(sourceID)", category: "pdf")
            }

            // Log fields if no PDF found
            if !hasRemote {
                let fieldKeys = pub.fields.keys.sorted().joined(separator: ", ")
                Logger.files.warningCapture("[PDFTab] No PDF available. Fields: [\(fieldKeys)]", category: "pdf")
            }

            await MainActor.run {
                hasRemotePDF = hasRemote
                isCheckingPDF = false  // Done checking
            }

            // Auto-download if setting enabled AND remote PDF available AND not multi-selection
            // When multiple papers are selected, don't auto-download - user can use "Download PDFs" menu
            let settings = await PDFSettingsStore.shared.settings
            if settings.autoDownloadEnabled && hasRemote && !isMultiSelection {
                Logger.files.infoCapture("[PDFTab] auto-downloading PDF...", category: "pdf")
                await downloadPDF()
            } else if isMultiSelection && hasRemote {
                Logger.files.infoCapture("[PDFTab] Skipping auto-download (multi-selection mode)", category: "pdf")
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.files.infoCapture("[PDFTab] \(String(format: "%.1f", elapsed))ms (autoDownload=\(settings.autoDownloadEnabled))", category: "pdf")
        }
    }

    private func downloadPDF() async {
        logger.info("[PDFTab] downloadPDF() called - starting download attempt")

        guard let pub = publication else {
            logger.warning("[PDFTab] downloadPDF() FAILED: publication is nil")
            return
        }
        logger.info("[PDFTab] downloadPDF() - publication: \(pub.citeKey)")

        // Use resolveWithDetails to get full resolution info (including browser fallback)
        let settings = await PDFSettingsStore.shared.settings
        let resolution = PDFURLResolver.resolveWithDetails(for: pub, settings: settings)

        // Store browser fallback URL if resolution failed but we have an attempted URL
        await MainActor.run {
            browserFallbackURL = resolution.attemptedURL
        }

        guard let resolvedURL = resolution.url else {
            // Log detailed info about what identifiers were available
            logger.warning("[PDFTab] downloadPDF() FAILED: No URL resolved")
            logger.info("[PDFTab]   pdfLinks: \(pub.pdfLinks.map { $0.url.absoluteString })")
            logger.info("[PDFTab]   arxivID: \(pub.arxivID ?? "nil")")
            logger.info("[PDFTab]   eprint: \(pub.fields["eprint"] ?? "nil")")
            logger.info("[PDFTab]   bibcode: \(pub.bibcodeNormalized ?? "nil")")
            logger.info("[PDFTab]   doi: \(pub.doi ?? "nil")")

            // Always show an error when resolution fails
            await MainActor.run {
                if let attemptedURL = resolution.attemptedURL {
                    logger.info("[PDFTab]   Browser fallback URL available: \(attemptedURL.absoluteString)")
                    downloadError = PDFDownloadError.publisherNotAvailable

                    // Auto-open the built-in browser when resolution fails but we have a fallback URL
                    #if os(macOS)
                    Task {
                        await openPDFBrowserWithURL(attemptedURL)
                    }
                    #endif
                } else {
                    logger.info("[PDFTab]   No browser fallback URL available")
                    downloadError = PDFDownloadError.noPDFAvailable
                }
            }
            return
        }

        // Log if this is a fallback resolution
        if resolution.isFallback {
            logger.info("[PDFTab] Using fallback source: \(resolution.sourceType?.rawValue ?? "unknown") (preferred: \(resolution.preferredSourceType.rawValue))")
        }

        logger.info("[PDFTab] Downloading PDF from: \(resolvedURL.absoluteString)")

        isDownloading = true
        downloadError = nil
        browserFallbackURL = nil  // Clear since we found a URL to try

        do {
            // Download to temp location
            logger.info("[PDFTab] Starting URLSession download...")
            let (tempURL, response) = try await URLSession.shared.download(from: resolvedURL)

            // Log HTTP response details
            if let httpResponse = response as? HTTPURLResponse {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
                logger.info("[PDFTab] Download response: HTTP \(httpResponse.statusCode), Content-Type: \(contentType), Content-Length: \(contentLength)")
                if httpResponse.statusCode != 200 {
                    logger.warning("[PDFTab] Non-200 HTTP status! Headers: \(httpResponse.allHeaderFields)")
                }
            } else {
                logger.info("[PDFTab] Download complete (non-HTTP response)")
            }

            // Validate it's actually a PDF (check for %PDF header)
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            let header = fileHandle.readData(ofLength: 100) // Read more for debugging
            try fileHandle.close()

            // Log header bytes for debugging
            let headerHex = header.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.info("[PDFTab] PDF validation - first 16 bytes: \(headerHex)")

            guard header.count >= 4,
                  header[0] == 0x25, // %
                  header[1] == 0x50, // P
                  header[2] == 0x44, // D
                  header[3] == 0x46  // F
            else {
                // Not a valid PDF - likely HTML error page
                logger.warning("[PDFTab] Downloaded file is NOT a valid PDF (expected %PDF header)")

                // Log what we actually received (helpful for diagnosing HTML error pages)
                if let headerString = String(data: header, encoding: .utf8) {
                    logger.warning("[PDFTab] Received content preview: \(headerString)")
                }

                try? FileManager.default.removeItem(at: tempURL)
                throw PDFDownloadError.downloadFailed("Downloaded file is not a valid PDF")
            }

            logger.info("[PDFTab] PDF header validation PASSED")

            // Import into library using PDFManager
            guard let library = libraryManager.activeLibrary else {
                logger.error("[PDFTab] No active library for PDF import")
                throw PDFDownloadError.noActiveLibrary
            }

            logger.info("[PDFTab] Importing PDF via PDFManager...")
            try PDFManager.shared.importPDF(from: tempURL, for: pub, in: library)
            logger.info("[PDFTab] PDF import SUCCESS")

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            await MainActor.run {
                logger.info("[PDFTab] PDF downloaded and imported successfully - refreshing view")
                resetAndCheckPDF()
            }
        } catch {
            logger.error("[PDFTab] Download/import FAILED: \(error.localizedDescription)")
            logger.error("[PDFTab]   Error type: \(type(of: error))")
            if let urlError = error as? URLError {
                logger.error("[PDFTab]   URLError code: \(urlError.code.rawValue)")
            }
            await MainActor.run {
                downloadError = error
                // Store the failed URL as browser fallback so user can try in browser
                browserFallbackURL = resolvedURL

                // Auto-open the built-in browser when download fails
                #if os(macOS)
                Task {
                    await openPDFBrowserWithURL(resolvedURL)
                }
                #endif
            }
        }

        await MainActor.run {
            isDownloading = false
            logger.info("[PDFTab] downloadPDF() complete - isDownloading=false, error=\(downloadError?.localizedDescription ?? "nil")")
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let pub = publication else { return }

            Task {
                do {
                    // Import PDF using PDFManager
                    guard let library = libraryManager.activeLibrary else {
                        logger.error("[PDFTab] No active library for PDF import")
                        return
                    }

                    // Import the PDF - PDFManager takes CDPublication directly
                    try PDFManager.shared.importPDF(from: url, for: pub, in: library)

                    // Refresh to show the new PDF
                    await MainActor.run {
                        resetAndCheckPDF()
                    }

                    logger.info("[PDFTab] PDF imported successfully")
                } catch {
                    logger.error("[PDFTab] PDF import failed: \(error.localizedDescription)")
                    await MainActor.run {
                        downloadError = error
                    }
                }
            }

        case .failure(let error):
            logger.error("[PDFTab] File import failed: \(error.localizedDescription)")
            downloadError = error
        }
    }

    #if os(macOS)
    private func openPDFBrowser() async {
        guard let pub = publication else { return }
        guard let library = libraryManager.activeLibrary else { return }

        await PDFBrowserWindowController.shared.openBrowser(
            for: pub,
            libraryID: library.id
        ) { [weak libraryManager] data in
            // This is called when user saves the detected PDF
            guard let library = libraryManager?.activeLibrary else { return }
            do {
                try PDFManager.shared.importPDF(data: data, for: pub, in: library)
                logger.info("[PDFTab] PDF imported from browser successfully")

                // Post notification to refresh PDF view
                await MainActor.run {
                    NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: pub.objectID)
                }
            } catch {
                logger.error("[PDFTab] Failed to import PDF from browser: \(error)")
            }
        }
    }

    /// Open the built-in PDF browser with a specific URL (used for fallback URLs)
    private func openPDFBrowserWithURL(_ url: URL) async {
        guard let pub = publication else { return }
        guard let library = libraryManager.activeLibrary else { return }

        logger.info("[PDFTab] Opening built-in browser with fallback URL: \(url.absoluteString)")

        await PDFBrowserWindowController.shared.openBrowser(
            for: pub,
            startURL: url,
            libraryID: library.id
        ) { [weak libraryManager] data in
            // This is called when user saves the detected PDF
            guard let library = libraryManager?.activeLibrary else { return }
            do {
                try PDFManager.shared.importPDF(data: data, for: pub, in: library)
                logger.info("[PDFTab] PDF imported from browser successfully")

                // Post notification to refresh PDF view
                await MainActor.run {
                    NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: pub.objectID)
                }
            } catch {
                logger.error("[PDFTab] Failed to import PDF from browser: \(error)")
            }
        }
    }
    #endif

    private func handleCorruptPDF(_ corruptFile: CDLinkedFile) async {
        logger.warning("[PDFTab] Corrupt PDF detected, attempting recovery: \(corruptFile.filename)")

        do {
            // 1. Delete corrupt file from disk and Core Data
            try PDFManager.shared.delete(corruptFile, in: libraryManager.activeLibrary)

            // 2. Reset state and trigger re-download
            await MainActor.run {
                linkedFile = nil
                resetAndCheckPDF()  // Will see no local PDF and try to download
            }

            logger.info("[PDFTab] Corrupt PDF cleanup complete, re-downloading...")
        } catch {
            logger.error("[PDFTab] Failed to clean up corrupt PDF: \(error)")
            await MainActor.run {
                downloadError = error
            }
        }
    }
}

// MARK: - Notes Tab

struct NotesTab: View {
    let publication: CDPublication

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme
    @AppStorage("notesPosition") private var notesPositionRaw: String = "below"
    @AppStorage("notesPanelSize") private var notesPanelSize: Double = 400  // ~60 chars at 13pt monospace
    @AppStorage("notesPanelCollapsed") private var isNotesPanelCollapsed = false

    // PDF auto-load state
    @State private var linkedFile: CDLinkedFile?
    @State private var isCheckingPDF = true
    @State private var isDownloading = false
    @State private var checkPDFTask: Task<Void, Never>?

    private var notesPosition: NotesPosition {
        NotesPosition(rawValue: notesPositionRaw) ?? .below
    }

    var body: some View {
        let sizeBinding = Binding<CGFloat>(
            get: { CGFloat(notesPanelSize) },
            set: { notesPanelSize = Double($0) }
        )

        Group {
            switch notesPosition {
            case .below:
                VStack(spacing: 0) {
                    pdfViewerContent
                    NotesPanel(
                        publication: publication,
                        size: sizeBinding,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .horizontal
                    )
                }
            case .right:
                HStack(spacing: 0) {
                    pdfViewerContent
                    NotesPanel(
                        publication: publication,
                        size: sizeBinding,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .verticalRight
                    )
                }
            case .left:
                HStack(spacing: 0) {
                    NotesPanel(
                        publication: publication,
                        size: sizeBinding,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .verticalLeft
                    )
                    pdfViewerContent
                }
            }
        }
        .onAppear {
            checkAndLoadPDF()
        }
        .onChange(of: publication.id) { _, _ in
            checkAndLoadPDF()
        }
    }

    @ViewBuilder
    private var pdfViewerContent: some View {
        if let linked = linkedFile {
            PDFViewerWithControls(
                linkedFile: linked,
                library: libraryManager.activeLibrary,
                publicationID: publication.id,
                onCorruptPDF: { _ in }
            )
        } else if isCheckingPDF {
            ProgressView("Checking for PDF...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isDownloading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Downloading PDF...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No PDF",
                systemImage: "doc.richtext",
                description: Text("Add a PDF to view it here while taking notes.")
            )
        }
    }

    // MARK: - PDF Auto-Load

    private func checkAndLoadPDF() {
        Logger.files.infoCapture("[NotesTab] checkAndLoadPDF() started for: \(publication.citeKey)", category: "pdf")

        checkPDFTask?.cancel()

        linkedFile = nil
        isCheckingPDF = true
        isDownloading = false

        checkPDFTask = Task {
            // Check for linked PDF files
            let linkedFiles = publication.linkedFiles ?? []
            Logger.files.infoCapture("[NotesTab] linkedFiles count = \(linkedFiles.count)", category: "pdf")

            if let firstPDF = linkedFiles.first(where: { $0.isPDF }) ?? linkedFiles.first {
                Logger.files.infoCapture("[NotesTab] Found local PDF: \(firstPDF.filename)", category: "pdf")
                await MainActor.run {
                    linkedFile = firstPDF
                    isCheckingPDF = false
                }
                return
            }

            Logger.files.infoCapture("[NotesTab] No local PDF found, checking remote...", category: "pdf")

            // No local PDF - check if remote PDF is available
            let resolverHasPDF = PDFURLResolver.hasPDF(publication: publication)
            let hasPdfLinks = !publication.pdfLinks.isEmpty
            let hasArxivID = publication.arxivID != nil
            let hasEprint = publication.fields["eprint"] != nil
            let hasRemote = resolverHasPDF || hasPdfLinks || hasArxivID || hasEprint

            Logger.files.infoCapture("[NotesTab] PDF check: resolver=\(resolverHasPDF), pdfLinks=\(hasPdfLinks) (\(publication.pdfLinks.count)), arxivID=\(hasArxivID), eprint=\(hasEprint), result=\(hasRemote)", category: "pdf")

            await MainActor.run { isCheckingPDF = false }

            // Auto-download if setting enabled AND remote PDF available
            let settings = await PDFSettingsStore.shared.settings
            if settings.autoDownloadEnabled && hasRemote {
                Logger.files.infoCapture("[NotesTab] auto-downloading PDF...", category: "pdf")
                await downloadPDF()
            } else {
                Logger.files.infoCapture("[NotesTab] autoDownload=\(settings.autoDownloadEnabled), hasRemote=\(hasRemote) - not downloading", category: "pdf")
            }
        }
    }

    private func downloadPDF() async {
        Logger.files.infoCapture("[NotesTab] downloadPDF() called - starting download attempt", category: "pdf")

        await MainActor.run { isDownloading = true }

        let settings = await PDFSettingsStore.shared.settings
        guard let resolvedURL = PDFURLResolver.resolveForAutoDownload(for: publication, settings: settings) else {
            Logger.files.warningCapture("[NotesTab] downloadPDF() FAILED: No URL resolved", category: "pdf")
            Logger.files.infoCapture("[NotesTab]   pdfLinks: \(publication.pdfLinks.map { $0.url.absoluteString })", category: "pdf")
            Logger.files.infoCapture("[NotesTab]   arxivID: \(publication.arxivID ?? "nil")", category: "pdf")
            Logger.files.infoCapture("[NotesTab]   eprint: \(publication.fields["eprint"] ?? "nil")", category: "pdf")
            Logger.files.infoCapture("[NotesTab]   bibcode: \(publication.bibcodeNormalized ?? "nil")", category: "pdf")
            Logger.files.infoCapture("[NotesTab]   doi: \(publication.doi ?? "nil")", category: "pdf")
            await MainActor.run { isDownloading = false }
            return
        }

        Logger.files.infoCapture("[NotesTab] Downloading PDF from: \(resolvedURL.absoluteString)", category: "pdf")

        do {
            // Download to temp location
            Logger.files.infoCapture("[NotesTab] Starting URLSession download...", category: "pdf")
            let (tempURL, response) = try await URLSession.shared.download(from: resolvedURL)

            // Log HTTP response details
            if let httpResponse = response as? HTTPURLResponse {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                Logger.files.infoCapture("[NotesTab] Download response: HTTP \(httpResponse.statusCode), Content-Type: \(contentType)", category: "pdf")
                if httpResponse.statusCode != 200 {
                    Logger.files.warningCapture("[NotesTab] Non-200 HTTP status!", category: "pdf")
                }
            }

            // Validate it's actually a PDF (check for %PDF header)
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            let header = fileHandle.readData(ofLength: 100)
            try fileHandle.close()

            // Log header bytes for debugging
            let headerHex = header.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            Logger.files.infoCapture("[NotesTab] PDF validation - first 16 bytes: \(headerHex)", category: "pdf")

            guard header.count >= 4,
                  header[0] == 0x25, // %
                  header[1] == 0x50, // P
                  header[2] == 0x44, // D
                  header[3] == 0x46  // F
            else {
                Logger.files.warningCapture("[NotesTab] Downloaded file is NOT a valid PDF", category: "pdf")
                if let headerString = String(data: header, encoding: .utf8) {
                    Logger.files.warningCapture("[NotesTab] Received content preview: \(headerString)", category: "pdf")
                }
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run { isDownloading = false }
                return
            }

            Logger.files.infoCapture("[NotesTab] PDF header validation PASSED", category: "pdf")

            // Import into library using PDFManager
            guard let library = libraryManager.activeLibrary else {
                Logger.files.errorCapture("[NotesTab] No active library for PDF import", category: "pdf")
                await MainActor.run { isDownloading = false }
                return
            }

            Logger.files.infoCapture("[NotesTab] Importing PDF via PDFManager...", category: "pdf")
            try PDFManager.shared.importPDF(from: tempURL, for: publication, in: library)
            Logger.files.infoCapture("[NotesTab] PDF import SUCCESS", category: "pdf")

            // Refresh linkedFile
            await MainActor.run {
                isDownloading = false
                linkedFile = publication.linkedFiles?.first(where: { $0.isPDF }) ?? publication.linkedFiles?.first
                Logger.files.infoCapture("[NotesTab] downloadPDF() complete - PDF loaded", category: "pdf")
            }
        } catch {
            Logger.files.errorCapture("[NotesTab] Download/import FAILED: \(error.localizedDescription)", category: "pdf")
            if let urlError = error as? URLError {
                Logger.files.errorCapture("[NotesTab]   URLError code: \(urlError.code.rawValue)", category: "pdf")
            }
            await MainActor.run { isDownloading = false }
        }
    }
}

// MARK: - Notes Panel Orientation

enum NotesPanelOrientation {
    case horizontal      // Panel below PDF (resize vertically)
    case verticalLeft    // Panel on left of PDF (header on right edge)
    case verticalRight   // Panel on right of PDF (header on left edge)
}

// MARK: - Notes Panel

/// A collapsible notes panel that can be positioned below or beside the PDF viewer.
/// Provides structured fields for annotations and a free-form notes area.
struct NotesPanel: View {
    let publication: CDPublication

    @Binding var size: CGFloat
    @Binding var isCollapsed: Bool
    let orientation: NotesPanelOrientation

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(\.themeColors) private var theme
    @State private var isResizing = false
    @State private var isEditingFreeformNotes = false  // Controls edit vs preview mode
    @FocusState private var isFreeformNotesFocused: Bool  // Controls TextEditor focus

    // Quick annotation settings
    @State private var annotationSettings: QuickAnnotationSettings = .defaults

    // Parsed notes (annotations + freeform)
    @State private var annotations: [String: String] = [:]
    @State private var freeformNotes: String = ""
    @State private var saveTask: Task<Void, Never>?

    private let minSize: CGFloat = 80
    private let maxSize: CGFloat = 2000  // Allow up to 100% of view (effectively unlimited)
    private let headerSize: CGFloat = 28

    var body: some View {
        Group {
            switch orientation {
            case .horizontal:
                // Horizontal: header on top, content below
                VStack(spacing: 0) {
                    headerBar
                    if !isCollapsed {
                        notesContent
                            .frame(height: size - headerSize)
                    }
                }
                .frame(height: isCollapsed ? headerSize : size)

            case .verticalRight:
                // Panel on RIGHT of PDF: header bar on LEFT edge (between PDF and notes)
                HStack(spacing: 0) {
                    verticalHeaderBar(chevronExpand: "chevron.left", chevronCollapse: "chevron.right")
                    if !isCollapsed {
                        notesContent
                            .frame(width: size - headerSize)
                    }
                }
                .frame(width: isCollapsed ? headerSize : size)

            case .verticalLeft:
                // Panel on LEFT of PDF: header bar on RIGHT edge (between notes and PDF)
                HStack(spacing: 0) {
                    if !isCollapsed {
                        notesContent
                            .frame(width: size - headerSize)
                    }
                    verticalHeaderBar(chevronExpand: "chevron.right", chevronCollapse: "chevron.left")
                }
                .frame(width: isCollapsed ? headerSize : size)
            }
        }
        .background(theme.contentBackground)
        .task {
            // Load annotation field settings
            annotationSettings = await QuickAnnotationSettingsStore.shared.settings
        }
        .onChange(of: publication.id, initial: true) { _, _ in
            loadNotes()
        }
    }

    // MARK: - Notes Content

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact quick annotations at top (doesn't scroll)
            structuredFieldsSection

            // Freeform notes fills remaining space
            freeformNotesSection
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            enterEditMode()
        }
    }

    // MARK: - Horizontal Header Bar (for below position)

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand notes" : "Collapse notes")

            Text("Notes")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            if !isCollapsed {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(90))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: headerSize)
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isCollapsed {
                        let newSize = size - value.translation.height
                        size = min(max(newSize, minSize), maxSize)
                    }
                }
        )
        .onHover { hovering in
            if !isCollapsed {
                #if os(macOS)
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
                #endif
            }
        }
    }

    // MARK: - Vertical Header Bar (for left/right position)

    private func verticalHeaderBar(chevronExpand: String, chevronCollapse: String) -> some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? chevronExpand : chevronCollapse)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand notes" : "Collapse notes")

            Text("Notes")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90))
                .fixedSize()

            Spacer()

            if !isCollapsed {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .frame(width: headerSize)
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isCollapsed {
                        // For left panel, dragging right increases size; for right panel, dragging left increases size
                        let delta = orientation == .verticalLeft ? value.translation.width : -value.translation.width
                        let newSize = size + delta
                        size = min(max(newSize, minSize), maxSize)
                    }
                }
        )
        .onHover { hovering in
            if !isCollapsed {
                #if os(macOS)
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
                #endif
            }
        }
    }

    // MARK: - Structured Fields

    @ViewBuilder
    private var structuredFieldsSection: some View {
        let enabledFields = annotationSettings.enabledFields

        if !enabledFields.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick Annotations")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                // Compact inline layout
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(enabledFields) { field in
                        noteField(field)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func noteField(_ field: QuickAnnotationField) -> some View {
        HStack(spacing: 4) {
            Text(field.label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            TextField(field.placeholder, text: annotationBinding(for: field.id))
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(theme.contentBackground)
                .cornerRadius(3)
        }
    }

    /// Create a binding for an annotation field
    private func annotationBinding(for fieldID: String) -> Binding<String> {
        Binding(
            get: { annotations[fieldID] ?? "" },
            set: { newValue in
                annotations[fieldID] = newValue
                scheduleSave()
            }
        )
    }

    // MARK: - Free-form Notes (Hybrid WYSIWYG)

    @ViewBuilder
    private var freeformNotesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reading Notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Spacer()

                // Markdown hint
                if isEditingFreeformNotes {
                    Text("Markdown + LaTeX supported")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Hybrid editor: show raw markdown when editing, rendered when not
            // Use Group with explicit id to prevent view identity issues during transitions
            Group {
                if isEditingFreeformNotes || freeformNotes.isEmpty {
                    // Edit mode: raw markdown input with formatting toolbar
                    VStack(spacing: 0) {
                        // Formatting toolbar
                        CompactFormattingBar(text: $freeformNotes)
                            .cornerRadius(4)

                        // Text editor with theme background
                        TextEditor(text: $freeformNotes)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(theme.contentBackground)
                            .focused($isFreeformNotesFocused)
                            .onChange(of: freeformNotes) { _, _ in
                                scheduleSave()
                            }
                    }
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                } else {
                // Preview mode: rendered markdown + LaTeX
                VStack(alignment: .leading, spacing: 0) {
                    // Edit button overlay
                    HStack {
                        Spacer()
                        Button {
                            enterEditMode()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .background(
                                    Circle()
                                        .fill(Color.primary.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Edit notes")
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 4)

                    RichTextView(content: freeformNotes, mode: .markdown, fontSize: 13)
                        .frame(minHeight: 60, maxHeight: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
                .background(theme.contentBackground)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .contentShape(Rectangle())  // Make entire area tappable
                .onTapGesture {
                    // Single click to edit
                    enterEditMode()
                }
                }
            }
            .animation(nil, value: isEditingFreeformNotes)  // Prevent animation glitches

            // Help text
            if !isEditingFreeformNotes && freeformNotes.isEmpty {
                Text("Click to add notes. Supports **bold**, _italic_, `code`, and $math$.")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .onChange(of: isFreeformNotesFocused) { _, focused in
            // Exit edit mode when focus is lost (clicked elsewhere)
            // Use a delay to ensure the state transition is smooth and content renders properly
            if !focused && !freeformNotes.isEmpty {
                // Delay the mode switch to allow SwiftUI to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    // Only exit if still unfocused (user didn't click back)
                    if !isFreeformNotesFocused {
                        isEditingFreeformNotes = false
                    }
                }
            }
        }
    }

    /// Enter edit mode and focus the TextEditor
    private func enterEditMode() {
        isEditingFreeformNotes = true
        // Delay focus slightly to allow view to render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFreeformNotesFocused = true
        }
    }

    // MARK: - Persistence

    private func loadNotes() {
        saveTask?.cancel()

        // Get raw note content
        let rawNote = publication.fields["note"] ?? ""

        // Check if this is legacy format (has separate notes_structured)
        if let jsonString = publication.fields["notes_structured"],
           let data = jsonString.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data),
           !dict.isEmpty {
            // Legacy format: migrate to unified format
            let migrated = NotesParser.migrateFromLegacy(structuredJSON: jsonString, freeformNote: rawNote)
            let parsed = NotesParser.parse(migrated)
            annotations = parsed.annotations
            freeformNotes = parsed.freeform
        } else {
            // New unified format: parse YAML front matter
            let parsed = NotesParser.parse(rawNote)
            // Convert label-keyed annotations to ID-keyed
            annotations = annotationSettings.labelToIDAnnotations(parsed.annotations)
            freeformNotes = parsed.freeform
        }
    }

    private func scheduleSave() {
        let targetPublication = publication
        let currentAnnotations = annotations
        let currentFreeform = freeformNotes
        let settings = annotationSettings

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard targetPublication.id == self.publication.id else { return }

            // Serialize to unified format with YAML front matter
            let notes = ParsedNotes(annotations: currentAnnotations, freeform: currentFreeform)
            let serialized = NotesParser.serialize(notes, fields: settings.fields)

            // Save to single "note" field
            await viewModel.updateField(targetPublication, field: "note", value: serialized)

            // Clear legacy field if it exists (migration cleanup)
            if targetPublication.fields["notes_structured"] != nil {
                await viewModel.updateField(targetPublication, field: "notes_structured", value: "")
            }
        }
    }
}

// MARK: - PDF Download Error

enum PDFDownloadError: LocalizedError {
    case noActiveLibrary
    case downloadFailed(String)
    case publisherNotAvailable
    case noPDFAvailable

    var errorDescription: String? {
        switch self {
        case .noActiveLibrary:
            return "No active library for PDF import"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .publisherNotAvailable:
            return "Publisher PDF not available for direct download. Use the browser to access the publisher page."
        case .noPDFAvailable:
            return "No PDF source available for this paper."
        }
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
    @ObservedObject var handler: FileDropHandler
    @Binding var isTargeted: Bool
    var onPDFImported: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay(dropOverlay)
            .modifier(FileDropTargetModifier(
                publication: publication,
                library: library,
                handler: handler,
                isTargeted: $isTargeted
            ))
            .alert(item: $handler.pendingDuplicate) { pending in
                Alert(
                    title: Text("Duplicate File"),
                    message: Text("'\(pending.sourceURL.lastPathComponent)' appears to be identical to '\(pending.existingFilename)'. Import anyway?"),
                    primaryButton: .default(Text("Import")) {
                        handler.resolveDuplicate(proceed: true)
                    },
                    secondaryButton: .cancel(Text("Skip")) {
                        handler.resolveDuplicate(proceed: false)
                    }
                )
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
    @ObservedObject var handler: FileDropHandler
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
