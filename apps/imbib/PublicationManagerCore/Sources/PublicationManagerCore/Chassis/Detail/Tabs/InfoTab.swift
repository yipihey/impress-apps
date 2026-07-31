#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  InfoTab.swift
//  imbib
//
//  Extracted from DetailView.swift
//

import SwiftUI
import ImpressFTUI
import ImpressStoreKit
import OSLog
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let infoTabLogger = Logger(subsystem: "com.imbib.app", category: "infotab")

struct InfoTab: View {
    let paper: any PaperRepresentable
    let publicationID: UUID?

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme
    @Environment(\.fontScale) private var fontScale

    // State for attachment deletion
    @State private var fileToDelete: LinkedFileModel?
    @State private var showDeleteConfirmation = false

    // State for file drop
    @State private var dropHandler = FileDropHandler()
    @State private var isDropTargeted = false
    @State private var showFileImporter = false

    // State for duplicate file alert (drop handler)
    @State private var showDuplicateAlert = false
    @State private var duplicateFilename = ""

    // State for duplicate PDF from browser
    @State private var showBrowserDuplicateAlert = false
    @State private var browserDuplicateFilename = ""
    @State private var browserDuplicateData: Data?

    // Refresh trigger for attachments section
    @State private var attachmentsRefreshID = UUID()

    // Timing for body evaluation
    @State private var bodyStartTime: CFAbsoluteTime = 0

    // Exploration (references/citations/similar/co-reads) — one runner, whose
    // `running` value replaced four parallel `isExploringX` booleans.
    @State private var explorationRunner = PublicationExplorationRunner()

    // Refresh trigger for when enrichment completes
    @State private var enrichmentRefreshID = UUID()

    // Author annotation state
    @State private var annotationSettings: QuickAnnotationSettings = .defaults
    @State private var annotations: [String: String] = [:]

    /// Cached publication model — loaded once per paper switch, refreshed on mutations.
    /// Replaces the computed property that was calling FFI ~15 times per body evaluation.
    @State private var cachedPublication: PublicationModel?

    /// Alias for backward compatibility with body code that binds `let pub = publication`.
    private var publication: PublicationModel? { cachedPublication }

    /// Fetch the publication from the Rust store and cache it.
    private func loadPublication() {
        guard let id = publicationID else {
            cachedPublication = nil
            return
        }
        cachedPublication = RustStoreAdapter.shared.getPublicationDetail(id: id)
    }

    var body: some View {
        let bodyStart = CFAbsoluteTimeGetCurrent()

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // MARK: - Email-Style Header
                    headerSection
                        .id("top")
                        .padding(.top, 40)

                    Divider()

                    // MARK: - Explore (References & Citations)
                    if canExploreReferences {
                        exploreSection
                            .id(enrichmentRefreshID)  // Refresh when enrichment data arrives
                        Divider()
                    }

                    // MARK: - Flag & Tags
                    if let pub = publication {
                        flagAndTagsSection(pub)
                        Divider()
                    }

                    // MARK: - Cited in Manuscripts
                    // Shown when this publication appears in at least one
                    // citation-usage record written by imprint's tracker.
                    // The section lists every manuscript section that
                    // cites this paper, with cite key and timestamp.
                    if let pubID = publicationID {
                        CitedInManuscriptsSection(publicationID: pubID)
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
                        let _ = infoTabLogger.info("collectPDFSources: \(sourcesElapsed, format: .fixed(precision: 1))ms (\(sources.count) sources)")

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
                        let _ = infoTabLogger.info("attachmentsSectionWithDrop: \(attachElapsed, format: .fixed(precision: 1))ms")

                        attachView
                            .id(attachmentsRefreshID)
                        Divider()
                    }

                    // MARK: - Comments Section
                    if let pub = publication {
                        CommentSectionView(itemID: pub.id, itemTitle: pub.title)
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
        .task {
            // Load annotation field settings
            annotationSettings = await QuickAnnotationSettingsStore.shared.settings
        }
        .onChange(of: publicationID, initial: true) { _, _ in
            loadPublication()
            loadAnnotations()
            // Reset ephemeral state that should not carry over between papers
            explorationRunner.reset()
            enrichmentRefreshID = UUID()
        }
        .task {
            // One subscription replaces the three legacy
            // flag/tag/field observers. Reload the publication only
            // when the current pub id is among the affected ids.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard case .itemsMutated(_, let ids) = event,
                      let pubID = publicationID,
                      ids.contains(pubID)
                else { continue }
                loadPublication()
            }
        }
        .onAppear {
            let elapsed = (CFAbsoluteTimeGetCurrent() - bodyStart) * 1000
            infoTabLogger.info("InfoTab.body onAppear: \(elapsed, format: .fixed(precision: 1))ms total")
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
            }
            Button("Import Anyway") {
                importBrowserPDF()
            }
        } message: {
            Text("This PDF is identical to '\(browserDuplicateFilename)' which is already attached. Do you want to import it anyway?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfImportedFromBrowser)) { notification in
            // Refresh attachments section when a PDF is imported from browser
            if let pubID = notification.object as? UUID,
               pubID == publicationID {
                attachmentsRefreshID = UUID()
                Logger.files.infoCapture("[InfoTab] Refreshing attachments after PDF import", category: "pdf")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .publicationEnrichmentDidComplete)) { notification in
            // Refresh view when enrichment data becomes available for this publication
            if let enrichedID = notification.userInfo?["publicationID"] as? UUID,
               enrichedID == publicationID {
                enrichmentRefreshID = UUID()
                infoTabLogger.info("Refreshing InfoTab after enrichment completed for \(publication?.citeKey ?? "unknown")")
            }
        }
        .alert("Exploration Error", isPresented: .constant(explorationRunner.errorMessage != nil)) {
            Button("OK") {
                explorationRunner.errorMessage = nil
            }
        } message: {
            if let error = explorationRunner.errorMessage {
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
                VStack(alignment: .leading, spacing: 4) {
                    ExpandableAuthorList(authors: paper.authors)
                        .font(.system(size: 21 * fontScale))

                    // Author annotation chips (if any populated)
                    authorAnnotationChips
                }
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

    /// DOI / arXiv / ADS / PubMed, from the ONE declaration
    /// (`PublicationIdentifierLink`) both platforms and the iOS More menu read.
    private var identifierLinks: [PublicationIdentifierLink] {
        PublicationIdentifierLink.all(for: paper)
    }

    private var hasIdentifiers: Bool {
        !identifierLinks.isEmpty
    }

    @ViewBuilder
    private var identifiersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            FlowLayout(spacing: 12) {
                ForEach(identifierLinks) { link in
                    identifierLink(link)
                        .help(link.openHelpText)
                }
            }
        }
    }

    @ViewBuilder
    private func identifierLink(_ link: PublicationIdentifierLink) -> some View {
        HStack(spacing: 4) {
            Text("\(link.label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let linkURL = link.url {
                Link(link.value, destination: linkURL)
                    .font(.caption)
            } else {
                Text(link.value)
                    .font(.caption)
            }
        }
        .contextMenu {
            Button("Copy \(link.label)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.value, forType: .string)
            }
        }
    }

    // MARK: - Flag & Tags Section

    /// Flag stripe + tags, rendered by the shared
    /// `PublicationFlagAndTagsSection` (Stage 5b) — the same view iOS's Info
    /// tab now uses, so the two cannot drift about tag ORDER or path style
    /// again. Tapping a chip activates the filter bar with `tags:{path}`; that
    /// gesture belongs to the host, which is why it arrives as a closure.
    @ViewBuilder
    private func flagAndTagsSection(_ pub: PublicationModel) -> some View {
        PublicationFlagAndTagsSection(publication: pub, tagPathStyle: .full) { tagPath in
            NotificationCenter.default.post(
                name: .activateFilterWithTag,
                object: nil,
                userInfo: ["tagPath": tagPath]
            )
        }
    }

    // MARK: - Explore Section (References & Citations)

    /// Whether this paper can be explored via ADS (has bibcode, DOI, or arXiv ID).
    ///
    /// Paper-level on purpose: an online search result has identifiers before
    /// it has a store row.
    private var canExploreReferences: Bool {
        PublicationExplorationModel.canExplore(paper: paper)
    }

    /// Labels, counts, help text and enablement, from the shared declaration.
    private var explorationModel: PublicationExplorationModel {
        PublicationExplorationModel(publication: publication)
    }

    /// The four buttons macOS ships, listed explicitly.
    ///
    /// NOT `explorationModel.offeredKinds` — that set includes `.wosRelated`,
    /// which only iOS surfaces. Adding a fifth button here would be a product
    /// change to the frozen pane, so the shared model informs each button and
    /// the ROW stays macOS's.
    private static let macExplorationKinds: [PublicationExplorationKind] = [
        .references, .citations, .similar, .coReads,
    ]

    @ViewBuilder
    private var exploreSection: some View {
        let model = explorationModel
        VStack(alignment: .leading, spacing: 8) {
            Text("Explore")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // All buttons in a single row
            HStack(spacing: 8) {
                ForEach(Self.macExplorationKinds) { kind in
                    Button {
                        explore(kind)
                    } label: {
                        if explorationRunner.isRunning(kind) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(model.label(for: kind), systemImage: kind.systemImage)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isEnabled(kind) || explorationRunner.isExploring)
                    .help(model.helpText(for: kind))
                }
            }
        }
    }

    /// Run one exploration. The four ~20-line copies of this block (one per
    /// button, differing only in which `explore*` they awaited) are now
    /// `PublicationExplorationRunner`.
    private func explore(_ kind: PublicationExplorationKind) {
        guard let pubID = publicationID else { return }
        Task {
            await explorationRunner.run(kind, for: pubID, libraryManager: libraryManager)
        }
    }

    // MARK: - Attachments Section with Drop Target

    @ViewBuilder
    private func attachmentsSectionWithDrop(_ pub: PublicationModel) -> some View {
        let linkedFiles = pub.linkedFiles.sorted { $0.dateAdded < $1.dateAdded }

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
            .onDrop(of: FileDropHandler.acceptedTypes, isTargeted: $isDropTargeted) { providers in
                Task {
                    await dropHandler.handleDrop(
                        providers: providers,
                        for: pub.id,
                        in: libraryManager.activeLibrary?.id
                    )
                }
                return true
            }

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
    private func enhancedAttachmentRow(_ file: LinkedFileModel) -> some View {
        HStack(spacing: 8) {
            // File type icon
            FileTypeIcon(linkedFile: file, size: 20)

            // Display name
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Date added
            Text(file.dateAdded, style: .date)
                .font(.caption)
                .foregroundStyle(.tertiary)

            // File size
            Text(file.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file) : getFileSizeString(for: file))
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
        .clipShape(.rect(cornerRadius: 6))
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
    private func attachmentsSection(_ linkedFiles: [LinkedFileModel]) -> some View {
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
    private func attachmentRow(_ file: LinkedFileModel) -> some View {
        HStack {
            FileTypeIcon(linkedFile: file, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Added \(file.dateAdded.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(file.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file) : getFileSizeString(for: file))
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
        .clipShape(.rect(cornerRadius: 6))
    }

    // MARK: - Record Info Section

    @ViewBuilder
    private func recordInfoSection(_ pub: PublicationModel) -> some View {
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
                        .textSelection(.enabled)
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

                // Flag info (shown in detail; primary display is in flagAndTagsSection above)
                GridRow {
                    Text("Flag")
                        .foregroundStyle(.secondary)
                    if let flag = pub.flag {
                        HStack(spacing: 6) {
                            FlagStripe(flag: flag, rowHeight: 16)
                            Text("\(flag.color.displayName) · \(flag.style.displayName) · \(flag.length.displayName)")
                        }
                    } else {
                        Text("None")
                            .foregroundStyle(.tertiary)
                    }
                }

                // Libraries this paper belongs to
                if !pub.libraryIDs.isEmpty {
                    let libraryNames = pub.libraryIDs.compactMap { libID in
                        RustStoreAdapter.shared.getLibrary(id: libID)?.name
                    }
                    let uniqueNames = Set(libraryNames).sorted()
                    GridRow {
                        Text(uniqueNames.count == 1 ? "Library" : "Libraries")
                            .foregroundStyle(.secondary)
                        Text(uniqueNames.joined(separator: ", "))
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

                // ADR-0023 W2 — "where did this paper come from?". Renders only
                // for papers a watched folder imported; a user who watches no
                // folder never sees the row and pays nothing for it (the index
                // short-circuits on an empty folder list).
                if let provenance = WatchedFolderProvenanceIndex.shared.provenance(
                    of: pub.id, dataVersion: RustStoreAdapter.shared.dataVersion) {
                    GridRow {
                        Text("Source File")
                            .foregroundStyle(.secondary)
                        Text(provenance.summary)
                            .textSelection(.enabled)
                            .foregroundStyle(
                                provenance.isMissing ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(.primary))
                            .help("Imported from \(provenance.path) — "
                                + "watched folder \u{201C}\(provenance.folderName)\u{201D}.")
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: - Author Annotations

    /// Load annotations from the publication's note field.
    ///
    /// The `note` field's format (YAML front matter + freeform) is parsed by
    /// `PublicationNotesDocument` — the same type the Notes editors on both
    /// platforms use, so three readers of one field cannot disagree about what
    /// it contains.
    private func loadAnnotations() {
        annotations = PublicationNotesDocument(
            publication: publication, settings: annotationSettings
        ).annotations
    }

    /// Author annotation chips displayed below the author list
    @ViewBuilder
    private var authorAnnotationChips: some View {
        let authorFields = annotationSettings.enabledAuthorFields
        let populated = authorFields.filter { annotations[$0.id]?.isEmpty == false }

        if !populated.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(populated) { field in
                    AuthorAnnotationChip(label: field.label, value: annotations[field.id] ?? "")
                }
            }
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

    /// Library UUID that owns the current publication. Falls back to the
    /// active library only if the paper isn't attached to any. Always use
    /// this (not `libraryManager.activeLibrary`) when resolving linked-file
    /// URLs — the active library is a UI concept and may differ from the
    /// one the paper's files actually live under.
    private var fileOwnerLibraryID: UUID? {
        publication?.libraryIDs.first ?? libraryManager.activeLibrary?.id
    }

    private func getFileSize(for file: LinkedFileModel) -> Int64? {
        guard let url = AttachmentManager.shared.resolveURL(for: file, in: fileOwnerLibraryID) else {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }

    private func getFileSizeString(for file: LinkedFileModel) -> String {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            infoTabLogger.info("getFileSizeString (disk I/O): \(elapsed, format: .fixed(precision: 1))ms for \(file.filename)")
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
                        for: pub.id,
                        in: fileOwnerLibraryID
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

    private func openFile(_ file: LinkedFileModel) {
        let libID = fileOwnerLibraryID
        guard let url = AttachmentManager.shared.resolveURL(for: file, in: libID) else {
            Logger.files.warningCapture(
                "openFile: resolveURL returned nil for \(file.filename) in library \(libID?.uuidString ?? "nil")",
                category: "files"
            )
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.files.warningCapture(
                "openFile: resolved path does not exist on disk: \(url.path)",
                category: "files"
            )
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
    private func showInFinder(_ file: LinkedFileModel) {
        let libID = fileOwnerLibraryID
        guard let url = AttachmentManager.shared.resolveURL(for: file, in: libID) else {
            Logger.files.warningCapture(
                "showInFinder: resolveURL returned nil for \(file.filename) in library \(libID?.uuidString ?? "nil")",
                category: "files"
            )
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // File missing at computed path — reveal its expected directory
            // instead of silently no-oping. Better than nothing.
            Logger.files.warningCapture(
                "showInFinder: resolved path missing (\(url.path)); revealing parent dir",
                category: "files"
            )
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private func deleteFile(_ file: LinkedFileModel) {
        do {
            try AttachmentManager.shared.delete(file, in: fileOwnerLibraryID)
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

    /// Collect all available PDF sources for a publication.
    /// Shows both arXiv preprint and publisher links when available (they're often different).
    private func collectPDFSources(for pub: PublicationModel) -> [PDFSource] {
        var sources: [PDFSource] = []
        var seenURLs: Set<URL> = []

        // 1. Add arXiv link first if available (most reliable for preprints)
        if let arxivID = pub.arxivID,
           let arxivURL = URL(string: "https://arxiv.org/pdf/\(arxivID)") {
            sources.append(PDFSource(url: arxivURL, type: .preprint, sourceID: "arXiv"))
            seenURLs.insert(arxivURL)
        }

        // 2. Add publisher/DOI link if available and different from arXiv
        // Skip arXiv DOIs (10.48550/arXiv.*) since they just resolve to arXiv
        if let doi = pub.doi, !doi.isEmpty {
            let isArxivDOI = doi.lowercased().contains("arxiv") || doi.lowercased().contains("10.48550")
            if !isArxivDOI, let doiURL = URL(string: "https://doi.org/\(doi)") {
                sources.append(PDFSource(url: doiURL, type: .publisher, sourceID: "Publisher"))
                seenURLs.insert(doiURL)
            }
        }

        // 3. Fallback: ADS abstract page if we have no sources but have a bibcode
        if sources.isEmpty, let bibcode = pub.bibcode,
           let adsURL = URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/abstract") {
            sources.append(PDFSource(url: adsURL, type: .publisher, sourceID: "ADS"))
        }

        return sources
    }

    @ViewBuilder
    private func pdfSourcesSection(_ sources: [PDFSource], publication pub: PublicationModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PDF Sources")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(sources, id: \.self) { source in
                pdfSourceRow(source, publication: pub)
            }
        }
    }

    @ViewBuilder
    private func pdfSourceRow(_ source: PDFSource, publication pub: PublicationModel) -> some View {
        HStack {
            // Clickable label - opens in imBib browser on macOS, system browser on iOS
            #if os(macOS)
            Button {
                Task {
                    await openInImBibBrowser(source.url, publication: pub)
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
                    await openInImBibBrowser(source.url, publication: pub)
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
    private func openInImBibBrowser(_ url: URL, publication pub: PublicationModel) async {
        guard let library = libraryManager.activeLibrary else { return }

        let capturedPubID = pub.id

        await PDFBrowserWindowController.shared.openBrowser(
            for: pub,
            startURL: url,
            libraryID: library.id
        ) { [self] data in
            // Check for duplicates first
            let result = AttachmentManager.shared.checkForDuplicate(data: data, in: capturedPubID)

            switch result {
            case .duplicate(let existingFile, _):
                // Show duplicate alert
                await MainActor.run {
                    browserDuplicateFilename = existingFile.filename
                    browserDuplicateData = data
                    showBrowserDuplicateAlert = true
                }
                Logger.files.infoCapture("[InfoTab] Duplicate PDF detected: matches \(existingFile.filename)", category: "pdf")

            case .noDuplicate:
                // Import directly
                do {
                    try AttachmentManager.shared.importPDF(data: data, for: capturedPubID, in: library.id)
                    Logger.files.infoCapture("[InfoTab] PDF imported from browser successfully", category: "pdf")

                    await MainActor.run {
                        NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: capturedPubID)
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
              let pubID = publicationID,
              let library = libraryManager.activeLibrary else {
            return
        }

        do {
            try AttachmentManager.shared.importPDF(data: data, for: pubID, in: library.id)
            Logger.files.infoCapture("[InfoTab] Duplicate PDF imported after user confirmation", category: "pdf")

            NotificationCenter.default.post(name: .pdfImportedFromBrowser, object: pubID)
        } catch {
            Logger.files.errorCapture("[InfoTab] Failed to import duplicate PDF: \(error)", category: "pdf")
        }

        // Clear pending state
        browserDuplicateData = nil
    }
    #endif
}

// MARK: - Author Annotation Chip

/// A read-only chip for displaying author annotations in InfoTab.
struct AuthorAnnotationChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 2) {
            Text(label + ":")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }
}
#endif
