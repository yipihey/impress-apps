//
//  IOSInfoTab.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import ImpressFTUI
import QuickLook

/// iOS Info tab showing publication details, abstract, identifiers, and attachments.
struct IOSInfoTab: View {
    let publication: CDPublication
    let libraryID: UUID

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme
    @Environment(\.fontScale) private var fontScale
    @State private var showPDFBrowser = false
    @State private var showFilePicker = false
    @State private var showShareSheet = false
    @State private var fileToShare: URL?
    @State private var isDownloadingPDF = false
    @State private var fileToPreview: URL?
    @State private var fileError: String?

    // State for exploration (references/citations/similar/co-reads/wos-related)
    @State private var isExploringReferences = false
    @State private var isExploringCitations = false
    @State private var isExploringSimilar = false
    @State private var isExploringCoReads = false
    @State private var isExploringWoSRelated = false
    @State private var explorationError: String?

    // Refresh trigger for when enrichment completes
    @State private var enrichmentRefreshID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Email-style Header (From, Year, Subject, Venue)
                headerSection

                Divider()

                // Explore (References, Citations, Similar, Co-Reads)
                if canExploreReferences {
                    exploreSection
                        .id(enrichmentRefreshID)  // Refresh when enrichment data arrives
                    Divider()
                }

                // Flag & Tags
                flagAndTagsSection
                Divider()

                // Abstract
                if let abstract = publication.abstract, !abstract.isEmpty {
                    abstractSection(abstract)
                    Divider()
                }

                // PDF Sources
                if hasPDFSources {
                    pdfSourcesSection
                    Divider()
                }

                // Attachments
                attachmentsSection
                Divider()

                // Comments (shared libraries)
                if publication.libraries?.contains(where: { $0.isSharedLibrary }) == true {
                    CommentSectionView(publication: publication)
                    Divider()
                }

                // Identifiers (DOI, arXiv, ADS, PubMed)
                if hasIdentifiers {
                    identifiersSection
                    Divider()
                }

                // Record Info
                recordInfoSection
                    .id(enrichmentRefreshID)  // Refresh when enrichment data arrives
            }
            .padding()
        }
        .sheet(isPresented: $showPDFBrowser) {
            IOSPDFBrowserView(
                publication: publication,
                library: libraryManager.find(id: libraryID),
                onPDFSaved: nil
            )
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = fileToShare {
                IOSShareSheet(items: [url])
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],  // Accept any file type
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .quickLookPreview($fileToPreview)
        .alert("Exploration Error", isPresented: .constant(explorationError != nil)) {
            Button("OK") {
                explorationError = nil
            }
        } message: {
            if let error = explorationError {
                Text(error)
            }
        }
        .alert("File Not Found", isPresented: .constant(fileError != nil)) {
            Button("OK") {
                fileError = nil
            }
        } message: {
            if let error = fileError {
                Text(error)
            }
        }
        .task(id: publication.id) {
            // Auto-enrich on view if needed (for ref/cite counts)
            if publication.needsEnrichment {
                await EnrichmentCoordinator.shared.queueForEnrichment(publication, priority: .recentlyViewed)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .publicationEnrichmentDidComplete)) { notification in
            // Refresh view when enrichment data becomes available for this publication
            if let enrichedID = notification.userInfo?["publicationID"] as? UUID,
               enrichedID == publication.id {
                enrichmentRefreshID = UUID()
            }
        }
    }

    // MARK: - Sections

    /// Email-style header matching macOS InfoTab
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // From: Authors (expandable if more than 10) - larger font, scales with user preference
            infoRow("From") {
                ExpandableAuthorList(authorString: publication.authorString)
                    .font(.system(size: 22 * fontScale))
            }

            // Year
            if publication.year > 0 {
                infoRow("Year") {
                    Text(String(publication.year))
                }
            }

            // Subject: Title - larger font, scales with user preference
            infoRow("Subject") {
                Text(publication.title ?? "Untitled")
                    .font(.system(size: 22 * fontScale))
                    .textSelection(.enabled)
            }

            // Venue
            if let venue = venueString, !venue.isEmpty {
                infoRow("Venue") {
                    Text(JournalMacros.expand(venue))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Email-style info row with label and content
    @ViewBuilder
    private func infoRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)

            content()
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func abstractSection(_ abstract: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Abstract")
                .font(.headline)

            // Base font size is 21 (1.5x larger than body text), scaled by user preference
            MathJaxAbstractView(text: abstract, fontSize: 21 * fontScale, textColor: .secondary)
        }
    }

    /// Whether this paper has any identifiers to display
    private var hasIdentifiers: Bool {
        publication.doi != nil || publication.arxivID != nil || publication.bibcode != nil || publication.pmid != nil
    }

    private var identifiersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Compact horizontal scroll for identifier links
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    if let doi = publication.doi {
                        identifierLink("DOI", value: doi, url: "https://doi.org/\(doi)")
                    }
                    if let arxivID = publication.arxivID {
                        identifierLink("arXiv", value: arxivID, url: "https://arxiv.org/abs/\(arxivID)")
                    }
                    if let bibcode = publication.bibcode {
                        identifierLink("ADS", value: bibcode, url: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
                    }
                    if let pmid = publication.pmid {
                        identifierLink("PubMed", value: pmid, url: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func identifierLink(_ label: String, value: String, url: String) -> some View {
        Button {
            if let linkURL = URL(string: url) {
                _ = FileManager_Opener.shared.openURL(linkURL)
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(label):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(theme.linkColor)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Explore Section

    /// Whether this paper can be explored via ADS (has bibcode, DOI, or arXiv ID)
    private var canExploreReferences: Bool {
        publication.bibcode != nil || publication.doi != nil || publication.arxivID != nil
    }

    /// Whether any exploration is in progress
    private var isExploring: Bool {
        isExploringReferences || isExploringCitations || isExploringSimilar || isExploringCoReads || isExploringWoSRelated
    }

    @ViewBuilder
    private var flagAndTagsSection: some View {
        let tags = publication.tags ?? []
        let sortedTags = tags.sorted { ($0.canonicalPath ?? $0.name) < ($1.canonicalPath ?? $1.name) }
        let hasFlag = publication.flag != nil
        let hasTags = !sortedTags.isEmpty

        if hasFlag || hasTags {
            VStack(alignment: .leading, spacing: 8) {
                if let flag = publication.flag {
                    HStack(spacing: 6) {
                        FlagStripe(flag: flag, rowHeight: 16)
                        Text("\(flag.color.displayName) · \(flag.style.displayName) · \(flag.length.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasTags {
                    FlowLayout(spacing: 4) {
                        ForEach(sortedTags, id: \.id) { tag in
                            TagChip(tag: TagDisplayData(
                                id: tag.id,
                                path: tag.canonicalPath ?? tag.name,
                                leaf: tag.leaf,
                                colorLight: tag.colorLight ?? tag.effectiveLightColor(),
                                colorDark: tag.colorDark ?? tag.effectiveDarkColor()
                            ))
                        }
                    }
                }
            }
        }
    }

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Explore")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Single row of buttons using ScrollView for horizontal overflow on smaller screens
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    let refAvail = publication.referencesAvailability()
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
                    .accessibilityHint(referencesHelpText(for: refAvail))

                    let citeAvail = publication.citationsAvailability()
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
                    .accessibilityHint(citationsHelpText(for: citeAvail))

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

                    // WoS Related (requires DOI)
                    if publication.doi != nil {
                        Button {
                            showWoSRelated()
                        } label: {
                            if isExploringWoSRelated {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("WoS Related", systemImage: "globe.americas")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExploring)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Label for the references button, including count if available
    private var referencesButtonLabel: String {
        switch publication.referencesAvailability() {
        case .hasResults(let count): return "References (\(count))"
        case .noResults: return "References (0)"
        default: return "References"
        }
    }

    /// Label for the citations button, including count if available
    private var citationsButtonLabel: String {
        switch publication.citationsAvailability() {
        case .hasResults(let count): return "Citations (\(count))"
        case .noResults: return "Citations (0)"
        default: return "Citations"
        }
    }

    /// Help text for references button based on availability
    private func referencesHelpText(for availability: CDPublication.ExplorationAvailability) -> String {
        switch availability {
        case .notEnriched: return "Find papers this paper cites"
        case .hasResults(let count): return "Show \(count) referenced papers"
        case .noResults: return "No references available for this paper"
        case .unavailable: return "No identifiers available for lookup"
        }
    }

    /// Help text for citations button based on availability
    private func citationsHelpText(for availability: CDPublication.ExplorationAvailability) -> String {
        switch availability {
        case .notEnriched: return "Find papers that cite this paper"
        case .hasResults(let count): return "Show \(count) citing papers"
        case .noResults: return "No citations available for this paper"
        case .unavailable: return "No identifiers available for lookup"
        }
    }

    // MARK: - PDF Sources Section

    private var hasPDFSources: Bool {
        publication.arxivID != nil || !publication.pdfLinks.isEmpty || publication.doi != nil
    }

    private var pdfSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PDF Sources")
                .font(.headline)

            VStack(spacing: 8) {
                // arXiv direct PDF
                if let arxivID = publication.arxivID {
                    pdfSourceRow(
                        label: "arXiv",
                        url: URL(string: "https://arxiv.org/pdf/\(arxivID).pdf"),
                        icon: "doc.text"
                    )
                }

                // PDF links from publication metadata
                ForEach(Array(publication.pdfLinks.enumerated()), id: \.offset) { index, link in
                    let sourceName = link.sourceID ?? pdfSourceName(for: link.url)
                    pdfSourceRow(
                        label: sourceName,
                        url: link.url,
                        icon: "link"
                    )
                }

                // DOI resolver fallback (skip if arXiv-only paper or arXiv DOI)
                if let doi = publication.doi,
                   publication.arxivID == nil,
                   !doi.lowercased().contains("arxiv") {
                    pdfSourceRow(
                        label: "Publisher (via DOI)",
                        url: URL(string: "https://doi.org/\(doi)"),
                        icon: "globe"
                    )
                }
            }
        }
    }

    private func pdfSourceRow(label: String, url: URL?, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(label)

            Spacer()

            if let url = url {
                Button {
                    downloadPDF(from: url)
                } label: {
                    if isDownloadingPDF {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(isDownloadingPDF)
            }
        }
        .padding(.vertical, 4)
    }

    private func pdfSourceName(for url: URL) -> String {
        let host = url.host ?? ""
        if host.contains("arxiv.org") { return "arXiv" }
        if host.contains("adsabs") { return "ADS" }
        if host.contains("openalex") { return "OpenAlex" }
        if host.contains("semanticscholar") { return "Semantic Scholar" }
        if host.contains("doi.org") { return "DOI Resolver" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: - Attachments Section

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attachments")
                    .font(.headline)

                Spacer()

                Button {
                    showFilePicker = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let linkedFiles = publication.linkedFiles, !linkedFiles.isEmpty {
                ForEach(Array(linkedFiles), id: \.id) { file in
                    attachmentRow(file)
                }
            } else {
                Text("No attachments")
                    .foregroundStyle(.secondary)

                if publication.doi != nil || publication.bibcode != nil || publication.arxivID != nil {
                    Button {
                        showPDFBrowser = true
                    } label: {
                        Label("Download PDF", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func attachmentRow(_ file: CDLinkedFile) -> some View {
        HStack(spacing: 8) {
            FileTypeIcon(linkedFile: file)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                // Allow file name to scroll horizontally if too long
                ScrollView(.horizontal) {
                    Text(file.displayName ?? file.relativePath)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)

                if file.fileSize > 0 {
                    Text(formatFileSize(file.fileSize))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    openFile(file)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }

                Button {
                    shareFile(file)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive) {
                    deleteFile(file)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Record Info Section

    private var recordInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record Info")
                .font(.headline)

            recordInfoRow("Cite Key") {
                Text(publication.citeKey)
                    .textSelection(.enabled)
            }

            recordInfoRow("Entry Type") {
                Text(publication.entryType.capitalized)
            }

            recordInfoRow("Date Added") {
                Text(publication.dateAdded.formatted(date: .abbreviated, time: .shortened))
            }

            if publication.dateModified != publication.dateAdded {
                recordInfoRow("Date Modified") {
                    Text(publication.dateModified.formatted(date: .abbreviated, time: .shortened))
                }
            }

            recordInfoRow("Read Status") {
                HStack {
                    Image(systemName: publication.isRead ? "checkmark.circle" : "circle")
                    Text(publication.isRead ? "Read" : "Unread")
                }
            }

            recordInfoRow("Flag") {
                if let flag = publication.flag {
                    HStack(spacing: 6) {
                        FlagStripe(flag: flag, rowHeight: 16)
                        Text("\(flag.color.displayName) · \(flag.style.displayName) · \(flag.length.displayName)")
                    }
                } else {
                    Text("None")
                        .foregroundStyle(.tertiary)
                }
            }


            if publication.citationCount > 0 {
                recordInfoRow("Citations") {
                    Text("\(publication.citationCount)")
                }
            }

            if publication.referenceCount > 0 {
                recordInfoRow("References") {
                    Text("\(publication.referenceCount)")
                }
            }

            // Libraries this paper belongs to
            if let libraries = publication.libraries, !libraries.isEmpty {
                // Use Set to deduplicate display names (handles duplicate inbox libraries)
                let uniqueNames = Set(libraries.map { $0.displayName }).sorted()
                recordInfoRow(uniqueNames.count == 1 ? "Library" : "Libraries") {
                    Text(uniqueNames.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Record info row that wraps long content
    @ViewBuilder
    private func recordInfoRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    // MARK: - Computed Properties

    private var venueString: String? {
        let fields = publication.fields
        return fields["journal"] ?? fields["booktitle"] ?? fields["publisher"]
    }

    // MARK: - Actions

    private func openFile(_ file: CDLinkedFile) {
        guard let library = libraryManager.find(id: libraryID) else {
            fileError = "Library not found."
            return
        }

        let normalizedPath = file.relativePath.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default

        // Check container path (iCloud-only storage)
        let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
        if fileManager.fileExists(atPath: containerURL.path) {
            fileToPreview = containerURL
        } else {
            fileError = "The file \"\(file.displayName ?? file.relativePath)\" is no longer available. It may have been moved or deleted, or iCloud may have freed up storage space."
        }
    }

    private func shareFile(_ file: CDLinkedFile) {
        guard let library = libraryManager.find(id: libraryID) else {
            fileError = "Library not found."
            return
        }

        let normalizedPath = file.relativePath.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default

        // Check container path (iCloud-only storage)
        let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
        if fileManager.fileExists(atPath: containerURL.path) {
            fileToShare = containerURL
            showShareSheet = true
        } else {
            fileError = "The file \"\(file.displayName ?? file.relativePath)\" is no longer available. It may have been moved or deleted, or iCloud may have freed up storage space."
        }
    }

    private func deleteFile(_ file: CDLinkedFile) {
        do {
            try AttachmentManager.shared.delete(file, in: libraryManager.find(id: libraryID))
        } catch {
            print("Failed to delete file: \(error)")
        }
    }

    private func downloadPDF(from url: URL) {
        isDownloadingPDF = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                // Verify it's a PDF
                guard data.count >= 4,
                      data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46]) else {
                    // Not a PDF - open browser instead
                    await MainActor.run {
                        isDownloadingPDF = false
                        showPDFBrowser = true
                    }
                    return
                }

                try AttachmentManager.shared.importPDF(
                    data: data,
                    for: publication,
                    in: libraryManager.find(id: libraryID)
                )

                await MainActor.run {
                    isDownloadingPDF = false
                }
            } catch {
                await MainActor.run {
                    isDownloadingPDF = false
                    showPDFBrowser = true
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                do {
                    let data = try Data(contentsOf: url)
                    let fileExtension = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
                    try AttachmentManager.shared.importAttachment(
                        data: data,
                        for: publication,
                        in: libraryManager.find(id: libraryID),
                        fileExtension: fileExtension,
                        displayName: url.lastPathComponent
                    )
                } catch {
                    print("Failed to import file: \(error)")
                }
            }
        case .failure(let error):
            print("File picker error: \(error)")
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Exploration

    /// Show references using ExplorationService
    private func showReferences() {
        isExploringReferences = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore references - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreReferences(of: publication)

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
        isExploringCitations = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore citations - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreCitations(of: publication)

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
        isExploringSimilar = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore similar - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreSimilar(of: publication)

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
        isExploringCoReads = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore co-reads - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreCoReads(of: publication)

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

    /// Show WoS related papers using ExplorationService
    private func showWoSRelated() {
        isExploringWoSRelated = true
        explorationError = nil

        Task {
            do {
                // Set up ExplorationService with enrichment service and library manager
                let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
                ExplorationService.shared.setEnrichmentService(enrichmentService)
                ExplorationService.shared.setLibraryManager(libraryManager)

                // Explore WoS related - creates collection and navigates via notification
                _ = try await ExplorationService.shared.exploreWoSRelated(of: publication)

                await MainActor.run {
                    isExploringWoSRelated = false
                }
            } catch {
                await MainActor.run {
                    isExploringWoSRelated = false
                    explorationError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Share Sheet

/// UIActivityViewController wrapper for sharing files.
private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
