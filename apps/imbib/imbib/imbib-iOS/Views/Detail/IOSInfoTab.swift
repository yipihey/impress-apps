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
/// Uses RustStoreAdapter for all data access (no Core Data).
struct IOSInfoTab: View {
    let publicationID: UUID
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

    // Publication data loaded from store
    @State private var publication: PublicationModel?

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
            if let pub = publication {
                VStack(alignment: .leading, spacing: 20) {
                    // Email-style Header (From, Year, Subject, Venue)
                    headerSection(pub)

                    Divider()

                    // Explore (References, Citations, Similar, Co-Reads)
                    if canExploreReferences(pub) {
                        exploreSection(pub)
                            .id(enrichmentRefreshID)
                        Divider()
                    }

                    // Flag & Tags
                    flagAndTagsSection(pub)
                    Divider()

                    // Abstract
                    if let abstract = pub.abstract, !abstract.isEmpty {
                        abstractSection(abstract)
                        Divider()
                    }

                    // Attachments
                    attachmentsSection(pub)
                    Divider()

                    // Identifiers (DOI, arXiv, ADS, PubMed)
                    if hasIdentifiers(pub) {
                        identifiersSection(pub)
                        Divider()
                    }

                    // Record Info
                    recordInfoSection(pub)
                        .id(enrichmentRefreshID)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "Loading...",
                    systemImage: "doc.text"
                )
            }
        }
        .sheet(isPresented: $showPDFBrowser) {
            IOSPDFBrowserView(
                publicationID: publicationID,
                libraryID: libraryID,
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
        .task(id: publicationID) {
            loadPublication()
        }
        .onReceive(NotificationCenter.default.publisher(for: .publicationEnrichmentDidComplete)) { notification in
            if let enrichedID = notification.userInfo?["publicationID"] as? UUID,
               enrichedID == publicationID {
                loadPublication()
                enrichmentRefreshID = UUID()
            }
        }
    }

    // MARK: - Data Loading

    private func loadPublication() {
        publication = RustStoreAdapter.shared.getPublicationDetail(id: publicationID)
    }

    // MARK: - Sections

    /// Email-style header matching macOS InfoTab
    private func headerSection(_ pub: PublicationModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // From: Authors
            infoRow("From") {
                ExpandableAuthorList(authorString: pub.authorString)
                    .font(.system(size: 22 * fontScale))
            }

            // Year
            if let year = pub.year, year > 0 {
                infoRow("Year") {
                    Text(String(year))
                }
            }

            // Subject: Title
            infoRow("Subject") {
                Text(pub.title)
                    .font(.system(size: 22 * fontScale))
                    .textSelection(.enabled)
            }

            // Venue
            if let venue = venueString(pub), !venue.isEmpty {
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

            MathJaxAbstractView(text: abstract, fontSize: 21 * fontScale, textColor: .secondary)
        }
    }

    /// Whether this paper has any identifiers to display
    private func hasIdentifiers(_ pub: PublicationModel) -> Bool {
        pub.doi != nil || pub.arxivID != nil || pub.bibcode != nil || pub.pmid != nil
    }

    private func identifiersSection(_ pub: PublicationModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    if let doi = pub.doi {
                        identifierLink("DOI", value: doi, url: "https://doi.org/\(doi)")
                    }
                    if let arxivID = pub.arxivID {
                        identifierLink("arXiv", value: arxivID, url: "https://arxiv.org/abs/\(arxivID)")
                    }
                    if let bibcode = pub.bibcode {
                        identifierLink("ADS", value: bibcode, url: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
                    }
                    if let pmid = pub.pmid {
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

    private func canExploreReferences(_ pub: PublicationModel) -> Bool {
        pub.bibcode != nil || pub.doi != nil || pub.arxivID != nil
    }

    private var isExploring: Bool {
        isExploringReferences || isExploringCitations || isExploringSimilar || isExploringCoReads || isExploringWoSRelated
    }

    @ViewBuilder
    private func flagAndTagsSection(_ pub: PublicationModel) -> some View {
        let hasFlag = pub.flag != nil
        let hasTags = !pub.tags.isEmpty

        if hasFlag || hasTags {
            VStack(alignment: .leading, spacing: 8) {
                if let flag = pub.flag {
                    HStack(spacing: 6) {
                        FlagStripe(flag: flag, rowHeight: 16)
                        Text("\(flag.color.displayName) · \(flag.style.displayName) · \(flag.length.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasTags {
                    FlowLayout(spacing: 4) {
                        ForEach(pub.tags, id: \.id) { tag in
                            TagChip(tag: tag)
                        }
                    }
                }
            }
        }
    }

    private func exploreSection(_ pub: PublicationModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Explore")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Button {
                        showReferences()
                    } label: {
                        if isExploringReferences {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            let refCount = pub.referenceCount
                            Label(refCount > 0 ? "References (\(refCount))" : "References", systemImage: "doc.text")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExploring)

                    Button {
                        showCitations()
                    } label: {
                        if isExploringCitations {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            let citeCount = pub.citationCount
                            Label(citeCount > 0 ? "Citations (\(citeCount))" : "Citations", systemImage: "quote.bubble")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExploring)

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
                    if pub.doi != nil {
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

    // MARK: - Attachments Section

    private func attachmentsSection(_ pub: PublicationModel) -> some View {
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

            if !pub.linkedFiles.isEmpty {
                ForEach(pub.linkedFiles, id: \.id) { file in
                    attachmentRow(file)
                }
            } else {
                Text("No attachments")
                    .foregroundStyle(.secondary)

                if pub.doi != nil || pub.bibcode != nil || pub.arxivID != nil {
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

    private func attachmentRow(_ file: LinkedFileModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: file.isPDF ? "doc.fill" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                ScrollView(.horizontal) {
                    Text(file.filename)
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
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Record Info Section

    private func recordInfoSection(_ pub: PublicationModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record Info")
                .font(.headline)

            recordInfoRow("Cite Key") {
                Text(pub.citeKey)
                    .textSelection(.enabled)
            }

            recordInfoRow("Entry Type") {
                Text(pub.entryType.capitalized)
            }

            recordInfoRow("Date Added") {
                Text(pub.dateAdded.formatted(date: .abbreviated, time: .shortened))
            }

            if pub.dateModified != pub.dateAdded {
                recordInfoRow("Date Modified") {
                    Text(pub.dateModified.formatted(date: .abbreviated, time: .shortened))
                }
            }

            recordInfoRow("Read Status") {
                HStack {
                    Image(systemName: pub.isRead ? "checkmark.circle" : "circle")
                    Text(pub.isRead ? "Read" : "Unread")
                }
            }

            recordInfoRow("Flag") {
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

            if pub.citationCount > 0 {
                recordInfoRow("Citations") {
                    Text("\(pub.citationCount)")
                }
            }

            if pub.referenceCount > 0 {
                recordInfoRow("References") {
                    Text("\(pub.referenceCount)")
                }
            }

            // Libraries this paper belongs to
            if !pub.libraryIDs.isEmpty {
                let store = RustStoreAdapter.shared
                let names = pub.libraryIDs.compactMap { store.getLibrary(id: $0)?.name }
                let uniqueNames = Set(names).sorted()
                recordInfoRow(uniqueNames.count == 1 ? "Library" : "Libraries") {
                    Text(uniqueNames.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }
        }
    }

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

    private func venueString(_ pub: PublicationModel) -> String? {
        pub.journal ?? pub.booktitle ?? pub.publisher
    }

    // MARK: - Actions

    private func openFile(_ file: LinkedFileModel) {
        guard let library = libraryManager.find(id: libraryID),
              let path = file.relativePath else {
            fileError = "Library not found."
            return
        }

        let normalizedPath = path.precomposedStringWithCanonicalMapping
        let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
        if FileManager.default.fileExists(atPath: containerURL.path) {
            fileToPreview = containerURL
        } else {
            fileError = "The file \"\(file.filename)\" is no longer available."
        }
    }

    private func shareFile(_ file: LinkedFileModel) {
        guard let library = libraryManager.find(id: libraryID),
              let path = file.relativePath else {
            fileError = "Library not found."
            return
        }

        let normalizedPath = path.precomposedStringWithCanonicalMapping
        let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
        if FileManager.default.fileExists(atPath: containerURL.path) {
            fileToShare = containerURL
            showShareSheet = true
        } else {
            fileError = "The file \"\(file.filename)\" is no longer available."
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
                    // Use Rust store to import attachment
                    // For now, we need to go through library manager for file system operations
                    if let library = libraryManager.find(id: libraryID) {
                        try AttachmentManager.shared.importAttachment(
                            data: data,
                            publicationID: publicationID,
                            in: library,
                            fileExtension: fileExtension,
                            displayName: url.lastPathComponent
                        )
                    }
                } catch {
                    print("Failed to import file: \(error)")
                }
            }
            loadPublication()
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

    private func showReferences() {
        NotificationCenter.default.post(name: .exploreReferences, object: publicationID)
    }

    private func showCitations() {
        NotificationCenter.default.post(name: .exploreCitations, object: publicationID)
    }

    private func showSimilar() {
        NotificationCenter.default.post(name: .exploreSimilar, object: publicationID)
    }

    private func showCoReads() {
        NotificationCenter.default.post(name: .exploreCoReads, object: publicationID)
    }

    private func showWoSRelated() {
        NotificationCenter.default.post(name: .exploreWoSRelated, object: publicationID)
    }
}

// MARK: - Share Sheet

private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
