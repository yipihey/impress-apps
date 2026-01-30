//
//  InfoTab.swift
//  imbib
//
//  Extracted from DetailView.swift
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

    // Author annotation state
    @State private var annotationSettings: QuickAnnotationSettings = .defaults
    @State private var annotations: [String: String] = [:]

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
            #if os(macOS)
            .contentMargins(.top, 8, for: .scrollContent)  // Align top edge with other detail tabs
            #endif
        }
        .task {
            // Load annotation field settings
            annotationSettings = await QuickAnnotationSettingsStore.shared.settings
        }
        .onChange(of: publication?.id, initial: true) { _, _ in
            loadAnnotations()
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
        // Keyboard navigation: h/l for pane cycling
        .focusable()
        .onKeyPress { press in
            let store = KeyboardShortcutsStore.shared
            // Cycle pane focus left (default: h)
            if store.matches(press, action: "cycleFocusLeft") {
                NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
                return .handled
            }
            // Cycle pane focus right (default: l)
            if store.matches(press, action: "cycleFocusRight") {
                NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
                return .handled
            }
            return .ignored
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
        case .notEnriched: return "Click to find papers this paper cites"
        case .hasResults(let count): return "Show \(count) referenced papers"
        case .noResults: return "No references available for this paper"
        case .unavailable: return "No identifiers available for lookup"
        }
    }

    /// Help text for citations button based on availability
    private func citationsHelpText(for availability: CDPublication.ExplorationAvailability) -> String {
        switch availability {
        case .notEnriched: return "Click to find papers that cite this paper"
        case .hasResults(let count): return "Show \(count) citing papers"
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
        .clipShape(.rect(cornerRadius: 6))
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

    // MARK: - Author Annotations

    /// Load annotations from the publication's note field
    private func loadAnnotations() {
        guard let pub = publication else {
            annotations = [:]
            return
        }

        // Get raw note content
        let rawNote = pub.fields["note"] ?? ""

        // Parse YAML front matter
        let parsed = NotesParser.parse(rawNote)
        // Convert label-keyed annotations to ID-keyed
        annotations = annotationSettings.labelToIDAnnotations(parsed.annotations)
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

    private func getFileSize(for file: CDLinkedFile) -> Int64? {
        guard let url = AttachmentManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) else {
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
        guard let url = AttachmentManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) else {
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
    private func showInFinder(_ file: CDLinkedFile) {
        guard let url = AttachmentManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private func deleteFile(_ file: CDLinkedFile) {
        do {
            try AttachmentManager.shared.delete(file, in: libraryManager.activeLibrary)
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
    private func collectPDFSources(for pub: CDPublication) -> [PDFSource] {
        var sources: [PDFSource] = []
        var seenURLs: Set<URL> = []
        var hasArxivSource = false

        // Helper to check if a URL is an arXiv link (any subdomain)
        func isArxivURL(_ url: URL) -> Bool {
            let urlString = url.absoluteString.lowercased()
            return urlString.contains("arxiv.org") || urlString.contains("export.arxiv")
        }

        // 1. Always add arXiv link first if available (most reliable for preprints)
        if let arxivURL = pub.arxivPDFURL {
            sources.append(PDFSource(url: arxivURL, type: .preprint, sourceID: "arXiv"))
            seenURLs.insert(arxivURL)
            hasArxivSource = true
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

        // 3. Add other PDF links from enrichment
        for link in pub.pdfLinks {
            // Skip if we already have this URL
            if seenURLs.contains(link.url) {
                continue
            }
            // Skip if it's any arXiv link and we already have an arXiv source
            if hasArxivSource && isArxivURL(link.url) {
                continue
            }
            sources.append(PDFSource(url: link.url, type: link.type, sourceID: link.sourceID))
            seenURLs.insert(link.url)
            if isArxivURL(link.url) {
                hasArxivSource = true
            }
        }

        // 4. Fallback: ADS abstract page if we have no sources but have a bibcode
        if sources.isEmpty, let bibcode = pub.bibcode,
           let adsURL = URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/abstract") {
            sources.append(PDFSource(url: adsURL, type: .publisher, sourceID: "ADS"))
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
            let result = AttachmentManager.shared.checkForDuplicate(data: data, in: publication)

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
                    try AttachmentManager.shared.importPDF(data: data, for: publication, in: library)
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
            try AttachmentManager.shared.importPDF(data: data, for: publication, in: library)
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
