//
//  NotesTab.swift
//  imbib
//
//  Extracted from DetailView.swift
//

import SwiftUI
import PublicationManagerCore
import OSLog
#if os(macOS)
import AppKit
import ImpressHelixCore
#endif

// MARK: - Notes Position

/// Position of the notes panel relative to the PDF viewer.
public enum NotesPosition: String, CaseIterable {
    case below = "below"
    case right = "right"
    case left = "left"

    public var label: String {
        switch self {
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
                .clipShape(.rect(cornerRadius: 3))
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
                            .frame(minHeight: 80)
                            .helixModeIndicator(
                                state: helixState,
                                position: .bottomRight,
                                isVisible: helixShowModeIndicator,
                                padding: 8
                            )
                        } else {
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
                        #else
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
