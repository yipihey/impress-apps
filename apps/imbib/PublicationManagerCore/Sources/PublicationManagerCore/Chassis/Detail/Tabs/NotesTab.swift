#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  NotesTab.swift
//  imbib
//
//  Extracted from DetailView.swift
//

import SwiftUI
import OSLog
#if os(macOS)
import AppKit
import ImpressHelixCore
#endif

// MARK: - Notes Position

/// Position of the notes panel relative to the PDF viewer.
public enum NotesPosition: String, CaseIterable {
    case top = "top"
    case below = "below"    // Keep existing value for backward compat
    case right = "right"
    case left = "left"

    /// Next position in cycle (clockwise: top → right → below → left)
    var next: NotesPosition {
        switch self {
        case .top: return .right
        case .right: return .below
        case .below: return .left
        case .left: return .top
        }
    }

    /// Icon pointing to next position
    var nextIcon: String {
        switch self {
        case .top: return "arrow.right"
        case .right: return "arrow.down"
        case .below: return "arrow.left"
        case .left: return "arrow.up"
        }
    }

    /// Whether this position uses vertical layout (notes beside PDF)
    var isVertical: Bool {
        self == .left || self == .right
    }

    public var label: String {
        switch self {
        case .top: return "Above PDF"
        case .below: return "Below PDF"
        case .right: return "Right of PDF"
        case .left: return "Left of PDF"
        }
    }
}

// MARK: - Notes Panel Orientation

enum NotesPanelOrientation {
    case horizontal      // Panel below PDF (resize vertically)
    case verticalLeft    // Panel on left of PDF (header on right edge)
    case verticalRight   // Panel on right of PDF (header on left edge)
}

// MARK: - Notes Tab

struct NotesTab: View {
    let publication: PublicationModel

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme
    @AppStorage("notesPosition") private var notesPositionRaw: String = "below"
    @AppStorage("notesPanelSize") private var savedPanelSize: Double = 400  // ~60 chars at 13pt monospace
    @AppStorage("notesPanelCollapsed") private var isNotesPanelCollapsed = false
    @State private var panelSize: CGFloat = 400

    // PDF auto-load state
    @State private var linkedFile: LinkedFileModel?
    @State private var isCheckingPDF = true
    @State private var isDownloading = false
    @State private var checkPDFTask: Task<Void, Never>?

    private var notesPosition: NotesPosition {
        NotesPosition(rawValue: notesPositionRaw) ?? .below
    }

    var body: some View {
        Group {
            switch notesPosition {
            case .top:
                VStack(spacing: 0) {
                    NotesPanel(
                        publication: publication,
                        size: $panelSize,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .horizontal
                    )
                    .clipped()
                    if !isNotesPanelCollapsed {
                        ResizeDivider(size: $panelSize, isVertical: false, minSize: 80, maxSize: 2000, invertDrag: false, onDragEnd: persistPanelSize)
                    }
                    pdfViewerContent
                        .clipped()
                        .contentShape(Rectangle())
                }
            case .below:
                VStack(spacing: 0) {
                    pdfViewerContent
                        .clipped()
                        .contentShape(Rectangle())
                    if !isNotesPanelCollapsed {
                        ResizeDivider(size: $panelSize, isVertical: false, minSize: 80, maxSize: 2000, invertDrag: true, onDragEnd: persistPanelSize)
                    }
                    NotesPanel(
                        publication: publication,
                        size: $panelSize,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .horizontal
                    )
                    .clipped()
                }
            case .right:
                HStack(spacing: 0) {
                    pdfViewerContent
                        .clipped()
                        .contentShape(Rectangle())
                    if !isNotesPanelCollapsed {
                        ResizeDivider(size: $panelSize, isVertical: true, minSize: 80, maxSize: 2000, invertDrag: true, onDragEnd: persistPanelSize)
                    }
                    NotesPanel(
                        publication: publication,
                        size: $panelSize,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .verticalRight
                    )
                    .clipped()
                }
            case .left:
                HStack(spacing: 0) {
                    NotesPanel(
                        publication: publication,
                        size: $panelSize,
                        isCollapsed: $isNotesPanelCollapsed,
                        orientation: .verticalLeft
                    )
                    .clipped()
                    if !isNotesPanelCollapsed {
                        ResizeDivider(size: $panelSize, isVertical: true, minSize: 80, maxSize: 2000, invertDrag: false, onDragEnd: persistPanelSize)
                    }
                    pdfViewerContent
                        .clipped()
                        .contentShape(Rectangle())
                }
            }
        }
        .background(theme.detailBackground)
        .scrollContentBackground(theme.detailBackground != nil ? .hidden : .automatic)
        .onAppear {
            panelSize = CGFloat(savedPanelSize)
            checkAndLoadPDF()
        }
        .onChange(of: publication.id) { _, _ in
            checkAndLoadPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .attachmentDidChange)) { notification in
            if let pubID = notification.object as? UUID, pubID == publication.id {
                checkAndLoadPDF()
            }
        }
        // Half-page scrolling support (macOS) - scrolls the notes panel
        .halfPageScrollable()
    }

    private func persistPanelSize() {
        savedPanelSize = Double(panelSize)
    }

    @ViewBuilder
    private var pdfViewerContent: some View {
        if let linked = linkedFile {
            PDFViewerWithControls(
                linkedFile: linked,
                libraryID: publication.libraryIDs.first ?? libraryManager.activeLibrary?.id,
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
            let linkedFiles = publication.linkedFiles
            Logger.files.infoCapture("[NotesTab] linkedFiles count = \(linkedFiles.count)", category: "pdf")

            if let firstPDF = linkedFiles.preferredPDF {
                Logger.files.infoCapture("[NotesTab] Found local PDF: \(firstPDF.filename)", category: "pdf")
                await MainActor.run {
                    linkedFile = firstPDF
                    isCheckingPDF = false
                }
                return
            }

            Logger.files.infoCapture("[NotesTab] No local PDF found, checking remote...", category: "pdf")

            // No local PDF - check if remote PDF is available
            let hasArxivID = publication.arxivID != nil
            let hasDOI = publication.doi != nil
            let hasBibcode = publication.bibcode != nil
            let hasEprint = publication.fields["eprint"] != nil
            let hasRemote = hasArxivID || hasDOI || hasBibcode || hasEprint

            Logger.files.infoCapture("[NotesTab] PDF check: arxivID=\(hasArxivID), doi=\(hasDOI), bibcode=\(hasBibcode), eprint=\(hasEprint), result=\(hasRemote)", category: "pdf")

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

    /// Fetch the paper's PDF through `PDFAcquisitionService` (ADR-025 P7),
    /// then re-read the linked files from the store — the `publication`
    /// value this view holds is a snapshot and does not grow a file.
    private func downloadPDF() async {
        Logger.files.infoCapture("[NotesTab] downloadPDF() called - starting download attempt", category: "pdf")
        let pubID = publication.id

        await MainActor.run { isDownloading = true }
        do {
            let local = try await PDFAcquisitionService.shared.acquire(publicationID: pubID, policy: .interactive)
            await MainActor.run {
                isDownloading = false
                guard local != nil else {
                    Logger.files.infoCapture("[NotesTab] downloadPDF(): no PDF source available", category: "pdf")
                    return
                }
                let files = RustStoreAdapter.shared.listLinkedFiles(publicationId: pubID)
                linkedFile = files.preferredPDF
                Logger.files.infoCapture("[NotesTab] downloadPDF() complete - PDF loaded", category: "pdf")
            }
        } catch {
            Logger.files.errorCapture("[NotesTab] Download/import FAILED: \(error.localizedDescription)", category: "pdf")
            await MainActor.run { isDownloading = false }
        }
    }
}

// MARK: - Notes Panel

/// A collapsible notes panel that can be positioned below or beside the PDF viewer.
/// Provides structured fields for annotations and a free-form notes area.
struct NotesPanel: View {
    let publication: PublicationModel

    @Binding var size: CGFloat
    @Binding var isCollapsed: Bool
    let orientation: NotesPanelOrientation

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(\.themeColors) private var theme
    @AppStorage("notesPosition") private var notesPositionRaw: String = "below"
    @State private var isEditingFreeformNotes = false  // Controls edit vs preview mode
    @FocusState private var isFreeformNotesFocused: Bool  // Controls TextEditor focus

    private var notesPosition: NotesPosition {
        NotesPosition(rawValue: notesPositionRaw) ?? .below
    }

    // Quick annotation settings
    @State private var annotationSettings: QuickAnnotationSettings = .defaults

    // Parsed notes (annotations + freeform)
    @State private var annotations: [String: String] = [:]
    @State private var freeformNotes: String = ""
    /// Debounced `note`-field writer, shared with the iOS editor (Stage 5b).
    @State private var notesWriter = PublicationNotesWriter()

    /// Which annotation fields are currently active/visible (by field ID)
    @State private var activeAnnotations: Set<String> = []

    // Helix mode settings
    @AppStorage("helixModeEnabled") private var helixModeEnabled = false
    @AppStorage("helixShowModeIndicator") private var helixShowModeIndicator = true
    #if os(macOS)
    @State private var helixState = HelixState()
    #endif

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
                    }
                }
                .frame(height: isCollapsed ? headerSize : size)

            case .verticalRight:
                // Panel on RIGHT of PDF: header bar on LEFT edge (between PDF and notes)
                HStack(spacing: 0) {
                    verticalHeaderBar(chevronExpand: "chevron.left", chevronCollapse: "chevron.right")
                    if !isCollapsed {
                        notesContent
                    }
                }
                .frame(width: isCollapsed ? headerSize : size)

            case .verticalLeft:
                // Panel on LEFT of PDF: header bar on RIGHT edge (between notes and PDF)
                HStack(spacing: 0) {
                    if !isCollapsed {
                        notesContent
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
            // Inline annotation fields at top
            annotationFieldsSection

            // What the reMarkable sent back (ADR-025): highlights, typed
            // text, read handwriting; nothing until a device is configured.
            EInkNotesSection(publication: currentPublication, onNotesAppended: reloadFromStore)

            // Freeform notes fills remaining space
            freeformNotesSection
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: publication.id) {
            // The `publication` this panel holds is a snapshot. When the note
            // field changes underneath it — "Append reMarkable notes" here,
            // or an agent through the store — re-read it, but never while
            // the user is typing (the debounced writer owns the buffer then).
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard case .itemsMutated(_, let ids) = event, ids.contains(publication.id) else { continue }
                guard !isEditingFreeformNotes, !isFreeformNotesFocused else { continue }
                reloadFromStore()
            }
        }
    }

    /// The publication as last re-read from the store, else the snapshot.
    @State private var refreshedPublication: PublicationModel?

    private var currentPublication: PublicationModel {
        refreshedPublication.flatMap { $0.id == publication.id ? $0 : nil } ?? publication
    }

    /// Re-read the paper and rebuild the notes document from its `note` field.
    private func reloadFromStore() {
        guard let fresh = RustStoreAdapter.shared.getPublicationDetail(id: publication.id) else { return }
        refreshedPublication = fresh
        notesWriter.cancelPending()
        let document = PublicationNotesDocument(publication: fresh, settings: annotationSettings)
        annotations = document.annotations
        freeformNotes = document.freeform
        activeAnnotations = document.populatedAnnotationIDs
        Logger.library.infoCapture(
            "eink.notes display: re-read note field for \(publication.id) (\(freeformNotes.count) chars freeform)",
            category: "eink")
    }

    // MARK: - Horizontal Header Bar (for below/top position)

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "Expand notes" : "Collapse notes")

            Text("Notes")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            // Position button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    notesPositionRaw = notesPosition.next.rawValue
                }
            } label: {
                Image(systemName: notesPosition.nextIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Move notes panel to \(notesPosition.next.label)")

        }
        .padding(.horizontal, 12)
        .frame(height: headerSize)
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "Expand notes" : "Collapse notes")

            // Position button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    notesPositionRaw = notesPosition.next.rawValue
                }
            } label: {
                Image(systemName: notesPosition.nextIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Move notes panel to \(notesPosition.next.label)")

            Text("Notes")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90))
                .fixedSize()

            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: headerSize)
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
    }

    // MARK: - Annotation Fields (Inline Toggleable)

    private var isHorizontalLayout: Bool {
        orientation == .horizontal
    }

    @ViewBuilder
    private var annotationFieldsSection: some View {
        let allFields = annotationSettings.enabledFields  // ALL enabled fields, including author fields

        if !allFields.isEmpty {
            if isHorizontalLayout {
                // Horizontal: fields flow side by side in a row
                HStack(alignment: .top, spacing: 12) {
                    ForEach(allFields) { field in
                        annotationField(field)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 4)
            } else {
                // Vertical: fields stack top to bottom
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(allFields) { field in
                        annotationField(field)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func annotationField(_ field: QuickAnnotationField) -> some View {
        let isActive = activeAnnotations.contains(field.id)

        VStack(alignment: .leading, spacing: 2) {
            // Header row: toggle + label
            HStack(spacing: 6) {
                Toggle(isOn: annotationToggleBinding(for: field.id)) {
                    Text(field.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(isActive ? .secondary : .tertiary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()
            }

            // Text field (only when active)
            if isActive {
                TextField(field.placeholder, text: annotationBinding(for: field.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(6)
                    .background(theme.contentBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
        }
    }

    /// Binding for toggling an annotation field on/off per-publication
    private func annotationToggleBinding(for fieldID: String) -> Binding<Bool> {
        Binding(
            get: { activeAnnotations.contains(fieldID) },
            set: { isOn in
                if isOn {
                    activeAnnotations.insert(fieldID)
                    // Initialize empty if no content
                    if annotations[fieldID] == nil {
                        annotations[fieldID] = ""
                    }
                } else {
                    activeAnnotations.remove(fieldID)
                    // Clear the value when toggled off
                    annotations[fieldID] = ""
                    scheduleSave()
                }
            }
        )
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
                            .clipShape(.rect(cornerRadius: 4))

                        // Text editor with theme background
                        #if os(macOS)
                        if helixModeEnabled {
                            HelixNotesTextEditor(
                                text: $freeformNotes,
                                helixState: helixState,
                                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                onChange: { scheduleSave() }
                            )
                            .frame(minHeight: 80, maxHeight: .infinity)
                            .helixModeIndicator(
                                state: helixState,
                                position: .bottomRight,
                                isVisible: helixShowModeIndicator,
                                padding: 8
                            )
                        } else {
                            TextEditor(text: $freeformNotes)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(minHeight: 80, maxHeight: .infinity)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(theme.contentBackground)
                                .focused($isFreeformNotesFocused)
                                .onChange(of: freeformNotes) { _, _ in
                                    scheduleSave()
                                }
                        }
                        #else
                        TextEditor(text: $freeformNotes)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: .infinity)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(theme.contentBackground)
                            .focused($isFreeformNotesFocused)
                            .onChange(of: freeformNotes) { _, _ in
                                scheduleSave()
                            }
                        #endif
                    }
                    .clipShape(.rect(cornerRadius: 4))
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
                .clipShape(.rect(cornerRadius: 4))
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
            if focused {
                // Enter edit mode when TextEditor gains focus
                // This handles the case where user clicks directly on an empty TextEditor
                // (which is shown due to freeformNotes.isEmpty) without going through enterEditMode()
                if !isEditingFreeformNotes {
                    isEditingFreeformNotes = true
                }
            } else if !freeformNotes.isEmpty {
                // Exit edit mode when focus is lost (clicked elsewhere)
                // Use a delay to ensure the state transition is smooth and content renders properly
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

    /// The `note` field's two halves, parsed by the shared
    /// `PublicationNotesDocument` (Stage 5b). iOS's notes editor reads the same
    /// type; before this it read the field RAW and showed the user their own
    /// YAML front matter as prose.
    private func loadNotes() {
        notesWriter.cancelPending()

        let document = PublicationNotesDocument(
            publication: publication, settings: annotationSettings)
        annotations = document.annotations
        freeformNotes = document.freeform

        // Populate active set from fields that have content
        activeAnnotations = document.populatedAnnotationIDs
    }

    /// Debounced save through the shared writer, which owns the 500 ms interval
    /// and the "did the selection move on" guard both editors had their own
    /// copy of.
    private func scheduleSave() {
        notesWriter.schedule(
            PublicationNotesDocument(annotations: annotations, freeform: freeformNotes),
            for: publication.id,
            settings: annotationSettings)
    }
}

// MARK: - Helix Notes Text Editor (macOS)

#if os(macOS)
/// NSViewRepresentable wrapper for HelixTextView for use in the notes panel.
struct HelixNotesTextEditor: NSViewRepresentable {
    @Binding var text: String
    let helixState: HelixState
    let font: NSFont
    let onChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = HelixTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = font
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor

        // Configure for code editing
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        // Set up text container
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        // Set up Helix adaptor
        let adaptor = NSTextViewHelixAdaptor(textView: textView, helixState: helixState)
        textView.helixAdaptor = adaptor
        context.coordinator.helixAdaptor = adaptor

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text
        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HelixTextView else { return }

        // Update text if changed externally
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text

            // Restore selection
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HelixNotesTextEditor
        weak var textView: NSTextView?
        var helixAdaptor: NSTextViewHelixAdaptor?

        init(_ parent: HelixNotesTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onChange()
        }
    }
}
#endif

// MARK: - Resize Divider

/// A thin draggable divider between two panes for resizing.
struct ResizeDivider: View {
    @Binding var size: CGFloat
    let isVertical: Bool    // true = left/right (drag horizontal), false = top/below (drag vertical)
    let minSize: CGFloat
    let maxSize: CGFloat
    let invertDrag: Bool    // true when drag direction is inverted relative to size increase
    var onDragEnd: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartSize: CGFloat = 0

    private let hitAreaThickness: CGFloat = 12
    private let lineWidth: CGFloat = 1

    var body: some View {
        Color.clear
            .frame(width: isVertical ? hitAreaThickness : nil,
                   height: isVertical ? nil : hitAreaThickness)
            .overlay {
                Rectangle()
                    .fill(isDragging ? Color.accentColor : (isHovering ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3)))
                    .frame(width: isVertical ? (isDragging || isHovering ? 3 : lineWidth) : nil,
                           height: isVertical ? nil : (isDragging || isHovering ? 3 : lineWidth))
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isHovering {
                        isHovering = true
                        (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                    }
                case .ended:
                    if isHovering {
                        isHovering = false
                        NSCursor.pop()
                    }
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            dragStartSize = size
                            isDragging = true
                        }
                        let delta = isVertical ? value.translation.width : value.translation.height
                        let adjusted = invertDrag ? -delta : delta
                        let newSize = dragStartSize + adjusted
                        size = min(max(newSize, minSize), maxSize)
                    }
                    .onEnded { _ in
                        dragStartSize = 0
                        isDragging = false
                        onDragEnd?()
                    }
            )
    }
}

#endif
