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
import OSLog

/// iOS Info tab showing publication details, abstract, identifiers, and attachments.
/// Uses RustStoreAdapter for all data access (no Core Data).
struct IOSInfoTab: View {
    let publicationID: UUID
    let libraryID: UUID

    @Environment(\.themeColors) private var theme
    @Environment(\.fontScale) private var fontScale
    @Environment(LibraryManager.self) private var libraryManager
    @State private var showPDFBrowser = false
    @State private var showFilePicker = false
    @State private var showShareSheet = false
    @State private var fileToShare: URL?
    @State private var isDownloadingPDF = false
    @State private var fileToPreview: URL?
    @State private var fileError: String?

    // Publication data loaded from store
    @State private var publication: PublicationModel?

    // Exploration (references/citations/similar/co-reads/wos-related) — one
    // shared runner in place of five parallel booleans + an error string.
    @State private var explorationRunner = PublicationExplorationRunner()

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
        .alert("Exploration Error", isPresented: .constant(explorationRunner.errorMessage != nil)) {
            Button("OK") {
                explorationRunner.errorMessage = nil
            }
        } message: {
            if let error = explorationRunner.errorMessage {
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
        !PublicationIdentifierLink.all(for: pub).isEmpty
    }

    /// The identifier row. The four URL templates live once, in
    /// `PublicationIdentifierLink` (Stage 5b); the horizontal scroll and the
    /// tinted-button look stay iOS's, because a `FlowLayout` of `Link`s with
    /// hover help is the pointer surface's answer, not a phone's.
    private func identifiersSection(_ pub: PublicationModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(PublicationIdentifierLink.all(for: pub)) { link in
                        identifierLink(link)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func identifierLink(_ link: PublicationIdentifierLink) -> some View {
        Button {
            if let linkURL = link.url {
                _ = FileManager_Opener.shared.openURL(linkURL)
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(link.label):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(link.value)
                    .font(.caption)
                    .foregroundStyle(theme.linkColor)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Explore Section

    private func canExploreReferences(_ pub: PublicationModel) -> Bool {
        PublicationExplorationModel(publication: pub).canExplore
    }

    /// Flag stripe + tags: the SHARED `PublicationFlagAndTagsSection`
    /// (Stage 5b). iOS gains what its copy lacked — tags sorted by path (they
    /// used to appear in a different order than on macOS for the same paper)
    /// and the full path on each chip. Chips stay inert here: activating a
    /// filter is a capability of the LIST pane, and iOS's list has no filter
    /// bar to activate.
    @ViewBuilder
    private func flagAndTagsSection(_ pub: PublicationModel) -> some View {
        PublicationFlagAndTagsSection(publication: pub, tagPathStyle: .full)
    }

    /// The Explore row. Which explorations exist, their labels, counts and
    /// enablement come from `PublicationExplorationModel`; running one is
    /// `PublicationExplorationRunner` (Stage 5b), which replaced the five
    /// `isExploringX` booleans and the local `explore(_:_:)` helper. The
    /// horizontal scroll is iOS chrome and stays.
    ///
    /// Unlike macOS this row iterates `offeredKinds`, so iOS keeps its fifth
    /// button (WoS Related, DOI-gated) — the difference is now declared rather
    /// than written out.
    private func exploreSection(_ pub: PublicationModel) -> some View {
        let model = PublicationExplorationModel(publication: pub)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Explore")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.offeredKinds) { kind in
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
        guard let url = resolveFileURL(file) else {
            fileError = "The file \"\(file.filename)\" is no longer available."
            return
        }
        fileToPreview = url
    }

    private func shareFile(_ file: LinkedFileModel) {
        guard let url = resolveFileURL(file) else {
            fileError = "The file \"\(file.filename)\" is no longer available."
            return
        }
        fileToShare = url
        showShareSheet = true
    }

    /// Resolve a linked file to an on-disk URL.
    ///
    /// Stage 5b: this was twelve hand-rolled lines checking TWO candidate
    /// paths, duplicated verbatim in `IOSPDFTab.pdfFileExists`, while
    /// `AttachmentManager.resolveURL(for:in:)` — cross-platform all along, and
    /// what macOS calls — knows FOUR. The one thing it does not do is answer
    /// "does it exist", because macOS callers want a path to reveal in Finder
    /// even on a miss; that step is `existingURL`, in PMC now.
    private func resolveFileURL(_ file: LinkedFileModel) -> URL? {
        AttachmentManager.shared.existingURL(for: file, in: libraryID)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        // publicationID / libraryID are immutable `let` properties — safe to read directly.
        let pubID = publicationID
        let libID = libraryID
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                do {
                    let data = try Data(contentsOf: url)
                    let fileExtension = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
                    Logger.files.infoCapture(
                        "iOS InfoTab: importing attachment '\(url.lastPathComponent)' (\(data.count) bytes) for \(pubID)",
                        category: "files"
                    )
                    // Value-type store: import keyed by publication + library UUIDs.
                    let linked = try AttachmentManager.shared.importAttachment(
                        data: data,
                        for: pubID,
                        in: libID,
                        fileExtension: fileExtension,
                        displayName: url.lastPathComponent
                    )
                    Logger.files.infoCapture(
                        "iOS InfoTab: imported linked file \(linked.id) (\(linked.filename))",
                        category: "files"
                    )
                } catch {
                    Logger.files.errorCapture(
                        "iOS InfoTab: failed to import file '\(url.lastPathComponent)': \(error.localizedDescription)",
                        category: "files"
                    )
                }
            }
            loadPublication()
        case .failure(let error):
            Logger.files.errorCapture("iOS InfoTab: file picker error: \(error.localizedDescription)", category: "files")
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Exploration

    // These once posted `.explore*` notifications that NOTHING observed — taps
    // fired into a void and no ADS/SciX search ran. They then called
    // `ExplorationService` directly, in a local copy of macOS's plumbing;
    // Stage 5b made that plumbing shared (`PublicationExplorationRunner`), so
    // the service setup, the in-flight flag and the error surfacing exist once.
    private func explore(_ kind: PublicationExplorationKind) {
        let pubID = publicationID
        Task {
            await explorationRunner.run(kind, for: pubID, libraryManager: libraryManager)
        }
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
