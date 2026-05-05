//
//  PaperDetailPanel.swift
//  ImpressPublicationUI
//
//  In-imprint paper detail view: shows metadata, PDF, editable notes, and
//  BibTeX for a publication read from imbib's shared Rust store.
//
//  Minimal-dependency package (only ImbibRustCore + SwiftUI + PDFKit) so
//  imprint can embed it without pulling in PublicationManagerCore's heavy
//  transitive deps.
//

import AppKit
import ImbibRustCore
import PDFKit
import SwiftUI

// MARK: - Data source contract

/// Abstract contract for the shared publication store, implemented by the host
/// app (imprint uses `ImprintPublicationService` — not directly visible from this
/// package, so we inject it via a protocol).
public protocol PublicationDataSource: AnyObject {
    func detail(id: String) -> PublicationDetail?
    func updateNote(publicationID: String, note: String) throws
}

// MARK: - PublicationDetail helpers

extension PublicationDetail {
    /// Title from the fields dictionary.
    var title: String { fields["title"] ?? citeKey }
    /// Year from the fields dictionary (parsed).
    var year: String? { fields["year"] }
    /// Journal or booktitle.
    var venue: String? { fields["journal"] ?? fields["booktitle"] ?? fields["publisher"] }
    /// Abstract text.
    var abstractText: String? { fields["abstract"] }
    /// Note text (free-form notes).
    var note: String? { fields["note"] }
    /// DOI.
    var doi: String? { fields["doi"] }
    /// arXiv ID.
    var arxivId: String? { fields["arxiv_id"] ?? fields["eprint"] }
    /// Volume.
    var volume: String? { fields["volume"] }
    /// Number (issue).
    var number: String? { fields["number"] }
    /// Pages.
    var pages: String? { fields["pages"] }
    /// Comma-separated author display string.
    var authorDisplay: String {
        authors.map { author in
            var parts: [String] = []
            if let g = author.givenName { parts.append(g) }
            parts.append(author.familyName)
            return parts.joined(separator: " ")
        }.joined(separator: ", ")
    }
}

// MARK: - Top-level panel

/// Tabbed paper detail panel — Info, PDF, Notes, BibTeX.
public struct PaperDetailPanel: View {
    public enum Tab: String, CaseIterable {
        case info = "Info"
        case pdf = "PDF"
        case notes = "Notes"
        case bibtex = "BibTeX"

        var icon: String {
            switch self {
            case .info: return "info.circle"
            case .pdf: return "doc.richtext"
            case .notes: return "note.text"
            case .bibtex: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    public let publicationID: String
    public let dataSource: PublicationDataSource
    public var onClose: (() -> Void)?

    @State private var detail: PublicationDetail?
    @State private var currentTab: Tab = .info

    public init(
        publicationID: String,
        dataSource: PublicationDataSource,
        onClose: (() -> Void)? = nil
    ) {
        self.publicationID = publicationID
        self.dataSource = dataSource
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content
        }
        .task(id: publicationID) {
            detail = dataSource.detail(id: publicationID)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let d = detail {
                    Text(d.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(d.citeKey)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let y = d.year {
                            Text("· \(y)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Loading…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close paper panel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    currentTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                        Text(tab.rawValue)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(currentTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                    .foregroundStyle(currentTab == tab ? Color.accentColor : Color.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let d = detail {
            switch currentTab {
            case .info: PaperInfoView(detail: d)
            case .pdf: PaperPDFView(detail: d)
            case .notes: PaperNotesEditor(detail: d, dataSource: dataSource)
            case .bibtex: PaperBibTeXView(detail: d)
            }
        } else {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Info tab

struct PaperInfoView: View {
    let detail: PublicationDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !detail.authors.isEmpty {
                    section(title: "Authors") {
                        Text(detail.authorDisplay)
                            .font(.system(size: 12))
                    }
                }
                if let venue = detail.venue {
                    section(title: "Venue") {
                        Text(venue).font(.system(size: 12))
                    }
                }
                if let vol = detail.volume {
                    section(title: "Volume") {
                        Text(vol + (detail.number.map { ", \($0)" } ?? ""))
                            .font(.system(size: 12))
                    }
                }
                if let pages = detail.pages {
                    section(title: "Pages") {
                        Text(pages).font(.system(size: 12))
                    }
                }
                if let doi = detail.doi {
                    section(title: "DOI") {
                        Text(doi)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let arxiv = detail.arxivId {
                    section(title: "arXiv") {
                        Text(arxiv)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let abs = detail.abstractText, !abs.isEmpty {
                    section(title: "Abstract") {
                        Text(abs)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !detail.tags.isEmpty {
                    section(title: "Tags") {
                        HStack {
                            ForEach(detail.tags.map(\.path), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

// MARK: - PDF tab

struct PaperPDFView: View {
    let detail: PublicationDetail

    var body: some View {
        if let url = pdfURL() {
            PDFKitView(url: url)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No PDF linked")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if !detail.linkedFiles.isEmpty {
                    Text("\(detail.linkedFiles.count) linked file(s) — PDF resolution requires AttachmentManager")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func pdfURL() -> URL? {
        // Look for a linked PDF file. `relativePath` is relative to the attachments root.
        // Resolution depends on imbib's AttachmentManager paths — for Phase 1, we try
        // the common default: ~/Documents/imbib-attachments/{relativePath}
        guard let first = detail.linkedFiles.first(where: { $0.isPdf }),
              let rel = first.relativePath else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser
        // Try a few common locations where imbib might store attachments
        let candidates: [URL] = [
            home.appendingPathComponent("Documents/imbib-attachments").appendingPathComponent(rel),
            home.appendingPathComponent("Library/Containers/com.impress.imbib/Data/Library/Application Support/imbib/attachments").appendingPathComponent(rel),
            URL(fileURLWithPath: rel),
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Minimal PDFKit wrapper — scroll, zoom, find work via PDFView defaults.
struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Notes tab

struct PaperNotesEditor: View {
    let detail: PublicationDetail
    let dataSource: PublicationDataSource

    @State private var noteText: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSavedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $noteText)
                .font(.system(size: 13))
                .padding(8)
                .onChange(of: noteText) { _, newValue in
                    scheduleSave(newValue)
                }
            Divider()
            HStack {
                if let saved = lastSavedAt {
                    Text("Saved \(saved, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(noteText.count) chars")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .onAppear {
            noteText = detail.note ?? ""
        }
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        let id = detail.id
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            do {
                try dataSource.updateNote(publicationID: id, note: value)
                lastSavedAt = Date()
            } catch {
                // Silent failure — the host app logs
            }
        }
    }
}

// MARK: - BibTeX tab

struct PaperBibTeXView: View {
    let detail: PublicationDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.rawBibtex ?? "(no BibTeX available)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
