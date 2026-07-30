#if os(iOS)
// Chassis file — iOS-only. The macOS twin is `ManuscriptDetailPane`, which is
// an EDITOR host and stays macOS-only.
//
//  IOSManuscriptReadOnlyPane.swift
//  PublicationManagerCore
//
//  THE read-only iOS manuscript pane, for hosts that present manuscripts
//  WITHOUT an editor.
//
//  ## Why this is new code and not the macOS pane un-gated (I2, 2026-07-30)
//
//  `ManuscriptDetailPane` composes six views, five of which are `#if os(macOS)`
//  — `ManuscriptDetailView`, `ManuscriptSourceTab` (which wraps the AppKit
//  editor), `MarkdownPreviewTab`'s session adapter, `ManuscriptPDFPreview` (an
//  `NSViewRepresentable`), `ManuscriptLaTeXImprintPrompt`. It is not one AppKit
//  call away from portable the way `FigureDetailPane` and
//  `AgentRecordDetailPane` were: it hosts the editor SESSION, and the session
//  is where the compile pipeline, the undo stack and the write-back live. That
//  is the ADR-0022 D9 finding, and it still holds — so this pane does not host
//  a session at all.
//
//  imprint-iOS is NOT migrated onto this. It keeps `IOSManuscriptEditorHost`,
//  which is a real editor. This is for the OTHER hosts.
//
//  ## The honest scope, tab by tab
//
//    * INFO — title, status (labelled from the DESCRIPTOR's `StatusSpec`, never
//      a literal), authors, format, journal target, tags, dates, revision
//      count, and the read-only operation timeline (`ManuscriptHistorySection`,
//      cross-platform since wave 2). `ManuscriptVersionsSection` is
//      deliberately ABSENT: it offers Save Version and restore, which are
//      writes.
//    * SOURCE — the manuscript's body, monospaced and selectable, read-only.
//      NOT `IOSSourceEditorView`: that view has no read-only mode (no
//      `isEditable`, and its representable hardcodes `isUserInteractionEnabled`
//      and installs a write-back delegate plus ⌘B/⌘I markup commands). Adding
//      one would have changed imprint's live editor to give this pane syntax
//      highlighting, which is not a trade a read-only viewer should ask for.
//      A body stored as a blob ref renders its "too large" state rather than
//      the literal `blob:sha256:…` string.
//    * PREVIEW — `MarkdownSourcePreview` for markdown, because markdown renders
//      from the buffer with no compile step. TYPST AND LATEX GET NO PREVIEW:
//      compiling them needs the session and the in-process renderer, which is
//      the thing this pane exists to not carry. Those formats get an "Open in
//      imprint" affordance instead (`ManuscriptImprintHandoff`, cross-platform
//      since I2) — a handoff, stated, rather than a blank pane.
//
//  Which tabs exist at all is `ManuscriptRecordKind.descriptor.availableTabs`,
//  the same declaration macOS reads: plain text has `previewKind == .none` and
//  so has no Preview tab here either, from the same line of code.
//

import ImpressFTUI
import SwiftUI

/// Read-only manuscript detail: info header, source, and a preview where one is
/// free.
public struct IOSManuscriptReadOnlyPane: View {

    private let manuscriptID: UUID
    @Binding private var selectedTab: DetailTab

    @State private var detail: ManuscriptDetail?
    @State private var loaded = false

    public init(manuscriptID: UUID, selectedTab: Binding<DetailTab>) {
        self.manuscriptID = manuscriptID
        self._selectedTab = selectedTab
    }

    // MARK: - Declarative tab set

    /// The format of the loaded manuscript, defaulting to typst while the read
    /// is in flight (the format with the MOST restrictive preview story, so the
    /// tab set never flickers a preview tab in and out).
    private var format: DocumentFormat {
        detail.flatMap { DocumentFormat(rawValue: $0.format) } ?? .typst
    }

    private var tabContext: RecordTabContext {
        RecordTabContext(previewKind: format.previewKind)
    }

    private var availableTabs: [DetailTab] {
        ManuscriptRecordKind.descriptor.availableTabs(for: tabContext)
    }

    /// The body source, or nil when it is stored out of line.
    private var source: String? {
        guard let detail, !detail.bodyIsBlobRef else { return nil }
        return detail.bodyContent
    }

    public var body: some View {
        Group {
            if detail != nil {
                TabView(selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        // The manuscript "PDF" tab is a PREVIEW surface — the
                        // same relabel macOS's picker makes.
                        Tab(tab == .pdf ? "Preview" : tab.label,
                            systemImage: tab.icon, value: tab) {
                            tabContent(tab)
                        }
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .onChange(of: availableTabs, initial: true) { _, tabs in
                    guard !tabs.contains(selectedTab) else { return }
                    selectedTab = ManuscriptRecordKind.descriptor.coercedTab(
                        selectedTab, for: tabContext)
                }
            } else if loaded {
                ContentUnavailableView(
                    "Manuscript Not Found",
                    systemImage: "doc.richtext",
                    description: Text("This manuscript is no longer in the store."))
            } else {
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(detail?.title ?? "Manuscript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if ManuscriptImprintHandoff.isAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        ManuscriptImprintHandoff.open(manuscriptID: manuscriptID)
                    } label: {
                        Label("Open in imprint", systemImage: "arrow.up.forward.app")
                    }
                    .accessibilityIdentifier("manuscript.openInImprint")
                }
            }
        }
        .task(id: manuscriptID) { load() }
    }

    @ViewBuilder
    private func tabContent(_ tab: DetailTab) -> some View {
        switch tab {
        case .info:
            infoTab
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.info)
        case .source:
            sourceTab
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.source)
        case .pdf:
            previewTab
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.pdf)
        case .notes, .bibtex:
            // Not in the manuscript tab set; coerced away on entry.
            EmptyView()
        }
    }

    // MARK: - Info

    @ViewBuilder
    private var infoTab: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Title") {
                            Text(detail.title.isEmpty ? "Untitled" : detail.title)
                                .font(.title3)
                                .textSelection(.enabled)
                        }
                        infoRow("Status") { Text(statusLabel(detail.status)) }
                        if !detail.authors.isEmpty {
                            infoRow("Authors") {
                                Text(detail.authors.joined(separator: ", "))
                                    .textSelection(.enabled)
                            }
                        }
                        infoRow("Format") {
                            Text(DocumentFormat(rawValue: detail.format)?.displayName
                                ?? detail.format.capitalized)
                        }
                        if let target = detail.journalTarget, !target.isEmpty {
                            infoRow("Target") { Text(target).textSelection(.enabled) }
                        }
                    }

                    if !detail.tags.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tags")
                                .font(.caption).foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            FlowLayout(spacing: 8) {
                                ForEach(detail.tags, id: \.path) { tag in
                                    Text(tag.path)
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.15),
                                                    in: Capsule())
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Record Info").font(.headline)
                        recordRow("Added", Self.date(detail.dateAdded))
                        recordRow("Modified", Self.date(detail.dateModified))
                        if let modified = detail.bodyModifiedAt, !modified.isEmpty {
                            recordRow("Body Modified", modified)
                        }
                        if let hash = detail.bodyContentHash, !hash.isEmpty {
                            recordRow("Body Hash", String(hash.prefix(12)))
                        }
                    }

                    Divider()

                    // Cross-platform since wave 2, and purely a READ.
                    ManuscriptHistorySection(manuscriptID: manuscriptID)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func infoRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
            content()
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recordRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    /// The status's DECLARED label. A status the descriptor does not know still
    /// renders — capitalised raw — rather than vanishing.
    private func statusLabel(_ raw: String) -> String {
        ManuscriptRecordKind.descriptor.triage.statuses
            .first { $0.rawValue == raw }?.label
            ?? (raw.isEmpty ? "Unknown" : raw.capitalized)
    }

    private static func date(_ epochMillis: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000.0)
            .formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Source

    @ViewBuilder
    private var sourceTab: some View {
        if let source, !source.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                Text(source)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.platformTextBackground)
        } else if detail?.bodyIsBlobRef == true {
            ContentUnavailableView(
                "Body Stored Out of Line",
                systemImage: "externaldrive",
                description: Text(
                    "This manuscript's body is large enough to live in the blob "
                        + "store. Open it in imprint to read or edit it."))
        } else {
            ContentUnavailableView(
                "No Source",
                systemImage: "doc.plaintext",
                description: Text("This manuscript has no body yet."))
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewTab: some View {
        switch format.previewKind {
        case .renderedMarkdown:
            MarkdownSourcePreview(source: source ?? "")
        case .compiledPDF, .none:
            // The honest handoff. A compiled preview needs the editor session
            // and the in-process renderer; this pane carries neither, and a
            // spinner that never resolves would be worse than saying so.
            ContentUnavailableView {
                Label("Preview Needs imprint", systemImage: "doc.richtext")
            } description: {
                Text("\(format.displayName) is compiled, and this viewer has no "
                     + "compiler. imprint renders it.")
            } actions: {
                if ManuscriptImprintHandoff.isAvailable {
                    Button("Open in imprint") {
                        ManuscriptImprintHandoff.open(manuscriptID: manuscriptID)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Data

    /// PMC's OWN FFI read — `RustStoreAdapter`, not `ImprintCore`. The pane has
    /// no dependency on imprint's core, which is what lets a host that never
    /// links the Typst renderer still show a manuscript.
    private func load() {
        detail = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)
        loaded = true
    }
}
#endif  // os(iOS)
