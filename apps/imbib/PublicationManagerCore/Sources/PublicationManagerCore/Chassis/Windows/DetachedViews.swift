#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  DetachedViews.swift
//  imbib
//
//  Created by Claude on 2026-01-19.
//

#if os(macOS)
import SwiftUI
import ImpressKeyboard
import OSLog

// MARK: - Detached PDF View

private let detachedPDFLogger = Logger(subsystem: "com.imbib.app", category: "detachedPDF")

/// A standalone PDF viewer window for a publication.
struct DetachedPDFView: View {
    let publication: PublicationModel
    let library: LibraryModel?

    @State private var linkedFile: LinkedFileModel?
    @State private var isCheckingPDF = true
    @State private var isDownloading = false
    @State private var downloadError: Error?
    @State private var browserFallbackURL: URL?
    @State private var hasPDFURL = false
    @State private var pdfDarkModeEnabled: Bool = PDFSettingsStore.loadSettingsSync().darkModeEnabled
    @FocusState private var isFocused: Bool

    var body: some View {
        // Content - no toolbar, maximizes screen real estate
        Group {
            if let linked = linkedFile {
                PDFViewerWithControls(
                    linkedFile: linked,
                    libraryID: library?.id,
                    publicationID: publication.id,
                    isDetachedWindow: true,
                    onCorruptPDF: { _ in }
                )
            } else if isCheckingPDF || isDownloading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(isDownloading ? "Downloading PDF..." : "Loading...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noPDFView
            }
        }
        .background(pdfDarkModeEnabled ? Color.black : Color.clear)
        .task {
            await checkForPDF()
        }
        // Keyboard navigation for PDF reading
        .focusable()
        .focused($isFocused)
        .keyboardGuarded { press in handleKeyPress(press) }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            pdfDarkModeEnabled = PDFSettingsStore.loadSettingsSync().darkModeEnabled
        }
        .onAppear {
            // Request focus after a brief delay to ensure the window is fully set up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .detachedWindowDidEnterFullScreen)) { _ in
            // Re-focus when entering fullscreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    // MARK: - Keyboard Navigation

    /// Handle keyboard input for PDF navigation.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Page Down keys: Space, PageDown, Right Arrow, Down Arrow, j
        let isPageDown = switch press.key {
        case .space where press.modifiers.isEmpty: true
        case .pageDown: true
        case .rightArrow: true
        case .downArrow: true
        case .init("j") where press.modifiers.isEmpty: true
        default: false
        }
        if isPageDown {
            NotificationCenter.default.post(name: .pdfPageDown, object: nil)
            return .handled
        }

        // Page Up keys: Shift+Space, PageUp, Left Arrow, Up Arrow, k
        let isPageUp = switch press.key {
        case .space where press.modifiers.contains(.shift): true
        case .pageUp: true
        case .leftArrow: true
        case .upArrow: true
        case .init("k") where press.modifiers.isEmpty: true
        default: false
        }
        if isPageUp {
            NotificationCenter.default.post(name: .pdfPageUp, object: nil)
            return .handled
        }

        return .ignored
    }

    private var noPDFView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No PDF Available")
                .font(.headline)

            if let error = downloadError {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if hasPDFURL {
                Button {
                    Task { await downloadPDF() }
                } label: {
                    Label("Download PDF", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No PDF URL available for this paper.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let fallbackURL = browserFallbackURL {
                Button("Open in Browser") {
                    NSWorkspace.shared.open(fallbackURL)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkForPDF() async {
        isCheckingPDF = true

        // Check for existing linked PDF
        if let linked = publication.linkedFiles.first(where: { $0.isPDF }) {
            linkedFile = linked
            isCheckingPDF = false
            return
        }

        // Check if we can resolve a PDF URL using the paper's identifiers
        let settings = await PDFSettingsStore.shared.settings
        let status = await PDFURLResolverV2.shared.resolve(for: publication, settings: settings)
        hasPDFURL = status.pdfURL != nil
        browserFallbackURL = status.browserURL ?? status.pdfURL

        // Auto-download if URL available and auto-download enabled
        if status.pdfURL != nil && settings.autoDownloadEnabled {
            isCheckingPDF = false
            await downloadPDF()
        } else {
            isCheckingPDF = false
        }
    }

    /// Fetch the paper's PDF through `PDFAcquisitionService` (ADR-025 P7)
    /// and re-read the linked file from the store.
    private func downloadPDF() async {
        detachedPDFLogger.info("[DetachedPDF] downloadPDF() called for: \(publication.citeKey)")
        let pubID = publication.id

        isDownloading = true
        downloadError = nil

        do {
            let local = try await PDFAcquisitionService.shared.acquire(publicationID: pubID, policy: .interactive)
            await MainActor.run {
                if local != nil {
                    let files = RustStoreAdapter.shared.listLinkedFiles(publicationId: pubID)
                    if let linked = files.first(where: { $0.isPDF }) {
                        linkedFile = linked
                    }
                    detachedPDFLogger.info("[DetachedPDF] PDF imported successfully")
                } else {
                    detachedPDFLogger.warning("[DetachedPDF] No URL resolved")
                    downloadError = PDFDownloadError.noPDFAvailable
                }
            }
        } catch let error as PDFAcquisitionError {
            detachedPDFLogger.error("[DetachedPDF] Download failed: \(error.localizedDescription)")
            await MainActor.run {
                if case .requiresUserAction(let browserURL, _) = error {
                    downloadError = PDFDownloadError.publisherNotAvailable
                    browserFallbackURL = browserURL
                } else if case .cancelled = error {
                    // Nothing to show.
                } else {
                    downloadError = error
                    browserFallbackURL = error.sourceURL ?? browserFallbackURL
                }
            }
        } catch {
            detachedPDFLogger.error("[DetachedPDF] Download failed: \(error.localizedDescription)")
            await MainActor.run {
                downloadError = error
            }
        }

        await MainActor.run {
            isDownloading = false
        }
    }
}

// MARK: - Detached Notes View

/// A standalone notes editor window for a publication.
struct DetachedNotesView: View {
    let publication: PublicationModel

    @State private var notes: String = ""
    @State private var hasUnsavedChanges = false
    @State private var originalNote: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            detachedToolbar

            Divider()

            // Notes editor
            TextEditor(text: $notes)
                .font(.body)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .padding()
                .onChange(of: notes) { _, newValue in
                    hasUnsavedChanges = newValue != originalNote
                }
        }
        .onAppear {
            let noteValue = publication.fields["note"] ?? ""
            notes = noteValue
            originalNote = noteValue
        }
        .onDisappear {
            saveNotes()
        }
    }

    private var detachedToolbar: some View {
        HStack {
            // Publication info
            VStack(alignment: .leading, spacing: 2) {
                Text(publication.title)
                    .font(.headline)
                    .lineLimit(1)

                if hasUnsavedChanges {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button("Save") {
                saveNotes()
            }
            .disabled(!hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func saveNotes() {
        guard hasUnsavedChanges else { return }

        let value = notes.isEmpty ? nil : notes
        RustStoreAdapter.shared.updateField(id: publication.id, field: "note", value: value)
        originalNote = notes
        hasUnsavedChanges = false
    }
}

// MARK: - Detached BibTeX View

/// A standalone BibTeX editor window for a publication.
struct DetachedBibTeXView: View {
    let publication: PublicationModel

    @State private var bibtex: String = ""
    @State private var isEditing = false
    @State private var hasUnsavedChanges = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            detachedToolbar

            Divider()

            // BibTeX content
            if isEditing {
                TextEditor(text: $bibtex)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding()
                    .onChange(of: bibtex) { _, _ in
                        hasUnsavedChanges = true
                    }
            } else {
                ScrollView {
                    Text(bibtex)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .onAppear {
            loadBibTeX()
        }
    }

    private var detachedToolbar: some View {
        HStack {
            // Publication info
            VStack(alignment: .leading, spacing: 2) {
                Text(publication.citeKey)
                    .font(.headline.monospaced())
                Text(publication.entryType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bibtex, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy BibTeX")

            // Edit toggle
            Toggle(isOn: $isEditing) {
                Image(systemName: "pencil")
            }
            .toggleStyle(.button)
            .help(isEditing ? "View mode" : "Edit mode")

            if isEditing && hasUnsavedChanges {
                Button("Save") {
                    saveBibTeX()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func loadBibTeX() {
        // Use raw BibTeX if available, otherwise generate from fields
        if let raw = publication.rawBibTeX, !raw.isEmpty {
            bibtex = raw
        } else {
            // Generate basic BibTeX from fields
            var lines: [String] = []
            lines.append("@\(publication.entryType){\(publication.citeKey),")
            for (key, value) in publication.fields.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(key) = {\(value)},")
            }
            lines.append("}")
            bibtex = lines.joined(separator: "\n")
        }
    }

    private func saveBibTeX() {
        // Parse and save via RustStoreAdapter
        do {
            let parser = BibTeXParserFactory.createParser()
            let items = try parser.parse(bibtex)
            if let item = items.first, case .entry(let entry) = item {
                // Update fields via RustStoreAdapter
                RustStoreAdapter.shared.updateField(id: publication.id, field: "cite_key", value: entry.citeKey)
                RustStoreAdapter.shared.updateField(id: publication.id, field: "entry_type", value: entry.entryType)
                RustStoreAdapter.shared.updateField(id: publication.id, field: "raw_bibtex", value: bibtex)
                for (key, value) in entry.fields {
                    RustStoreAdapter.shared.updateField(id: publication.id, field: key, value: value)
                }
                hasUnsavedChanges = false
            }
        } catch {
            // Show error (could add alert state)
            print("BibTeX parse error: \(error)")
        }
    }
}

// MARK: - Detached Info View

/// A standalone info panel window for a publication.
struct DetachedInfoView: View {
    let publication: PublicationModel

    @State private var isRead: Bool

    init(publication: PublicationModel) {
        self.publication = publication
        self._isRead = State(initialValue: publication.isRead)
    }

    private var authors: [String] {
        guard let author = publication.fields["author"] else { return [] }
        return author.components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            detachedToolbar

            Divider()

            // Info content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    infoSection("Title") {
                        Text(publication.title)
                            .textSelection(.enabled)
                    }

                    // Authors
                    if !authors.isEmpty {
                        infoSection("Authors") {
                            Text(authors.joined(separator: ", "))
                                .textSelection(.enabled)
                        }
                    }

                    // Year & Venue
                    HStack(alignment: .top, spacing: 32) {
                        if let year = publication.year, year > 0 {
                            infoSection("Year") {
                                Text(String(year))
                            }
                        }
                        if let venue = publication.fields["journal"] ?? publication.fields["booktitle"] {
                            infoSection("Venue") {
                                Text(venue)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    // Identifiers
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Identifiers")
                            .font(.headline)

                        if let doi = publication.fields["doi"] {
                            identifierRow("DOI", value: doi)
                        }
                        if let arxiv = publication.fields["eprint"] {
                            identifierRow("arXiv", value: arxiv)
                        }
                        if let bibcode = publication.fields["bibcode"] ?? publication.fields["adsurl"]?.components(separatedBy: "/").last {
                            identifierRow("Bibcode", value: bibcode)
                        }
                    }

                    // Abstract
                    if let abstract = publication.fields["abstract"], !abstract.isEmpty {
                        infoSection("Abstract") {
                            Text(abstract)
                                .textSelection(.enabled)
                        }
                    }

                    // Record info
                    infoSection("Record") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cite key: \(publication.citeKey)")
                            Text("Type: \(publication.entryType)")
                            Text("Added: \(publication.dateAdded.formatted(date: .abbreviated, time: .shortened))")
                            Text("Read: \(isRead ? "Yes" : "No")")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
    }

    private var detachedToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(publication.title)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer()

            // Toggle read status
            Button {
                isRead.toggle()
                RustStoreAdapter.shared.setRead(ids: [publication.id], read: isRead)
            } label: {
                Image(systemName: isRead ? "circle.fill" : "circle")
            }
            .help(isRead ? "Mark as unread" : "Mark as read")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func infoSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func identifierRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }
}

#endif // os(macOS)
#endif
