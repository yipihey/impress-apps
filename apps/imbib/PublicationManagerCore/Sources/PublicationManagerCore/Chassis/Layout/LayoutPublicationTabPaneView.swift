#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W4 (ADR-0031 L8 leaf 5).
//
//  LayoutPublicationTabPaneView.swift
//  PublicationManagerCore
//
//  The `pdf`, `notes` and `bibtex` view kinds: imbib's own detail TABS, one
//  per pane.
//
//  Map, not rewrite (ADR-0031 D11). `PDFTab`, `NotesTab` and `BibTeXTab` are
//  the views `DetailView` switches between; this file feeds each the inputs
//  `DetailView` feeds it — the paper, its id, the loaded `PublicationModel` —
//  from the pane's `single_item` / `$item`, the same resolution the `info`
//  pane uses. What `DetailView` did AROUND the tabs is the one thing a pane
//  has to supply itself, and it does it with the same shared modifier:
//  `publicationDetailLifecycle` (the read dwell, the Recent dwell, the live
//  store-event reload). A pane that showed a PDF without it would never mark
//  the paper read and would go stale when enrichment rewrote the record.
//
//  What is deliberately NOT here: `DetailView`'s tab switching (a pane has
//  exactly one tab — its view kind is the tab), its ⌘4/5/6 notification
//  handlers (they switch the `info` pane's tab, which is still a
//  `DetailView`), its `.focusable()` (the tree's outermost container owns
//  focus; a `.focusable()` here would sit around `NotesTab`'s text editor,
//  which CLAUDE.md forbids), and its file-drop target (private to
//  `DetailView`; dropping a PDF on the `info` pane still attaches it).
//

import ImpressLogging
import SwiftUI

@MainActor
struct LayoutPublicationTabPaneView: View {

    let context: PaneContext
    /// Which of the publication's tabs this pane IS.
    let tab: DetailTab

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(\.layoutToolbarBand) private var toolbarBand

    /// The loaded record. Re-read when the id changes and when the store
    /// says this paper changed — exactly `DetailView.cachedPublication`.
    @State private var publication: PublicationModel?
    @State private var loadedID: UUID?

    private var rawItem: String? {
        context.singleItem ?? context.bindings["item"]
    }

    private var itemID: UUID? {
        rawItem.flatMap(UUID.init(uuidString:))
    }

    /// These three are PUBLICATION tabs. A pane of another kind that names
    /// one of them (imprint's Writing puts a `pdf` pane over manuscripts)
    /// is answered honestly rather than handed a paper it is not.
    private var isPublicationPane: Bool {
        (context.primaryKind ?? RecordKindID.publication.rawValue)
            == RecordKindID.publication.rawValue
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { load(itemID) }
            .onChange(of: itemID) { _, id in load(id) }
            .publicationDetailLifecycle(
                publicationID: isPublicationPane ? loadedID : nil,
                // Read FRESH from the store, not from `publication`: a
                // reading arrangement puts up to four detail panes on one
                // paper, and every one of them runs this dwell. Against the
                // cached model each would see "unread" and write (four
                // undoable `setRead`s for one selection); against the store
                // the first write is seen by the rest, which then skip. The
                // Recent write needs no such care — Rust throttles
                // `recordRecentView` per paper and reports `wrote: false`.
                isRead: { [loadedID] in
                    loadedID.flatMap { RustStoreAdapter.shared.getPublication(id: $0)?.isRead }
                },
                markAsRead: { id in await viewModel.markAsRead(id: id) },
                reload: { reload() })
    }

    @ViewBuilder
    private var content: some View {
        if !isPublicationPane {
            ChassisEmptyState(
                id: "detail-unavailable",
                title: "Detail Unavailable",
                systemImage: RecordKindDescriptor.unknownSymbolName,
                message: "The \u{201C}\(tab.rawValue)\u{201D} view shows publications; this "
                    + "pane lists \u{201C}\(context.primaryKind ?? "item")\u{201D}."
            )
            .view
        } else if let publication, let id = loadedID {
            tabView(publication, id: id)
                // The tree reclaims the toolbar band for every horizontal
                // child but the first; the tabs were written for a detail
                // column under the window toolbar, so they get the same
                // clearance the `info` pane's picker gets.
                .padding(.top, toolbarBand)
        } else if let raw = rawItem, itemID == nil || loadedID == nil {
            ChassisEmptyState(
                id: "detail-unavailable",
                title: "Detail Unavailable",
                systemImage: RecordKindDescriptor.unknownSymbolName,
                message: "No publication \u{201C}\(raw)\u{201D}."
            )
            .view
        } else {
            ChassisEmptyState.noRowSelection(kind: .publication).view
        }
    }

    /// A plain switch over a plain `some View` (impress-swiftui-pitfalls
    /// rule 3). Each arm is the call `DetailView.body` makes for that tab.
    @ViewBuilder
    private func tabView(_ publication: PublicationModel, id: UUID) -> some View {
        let paper = LocalPaper(from: publication)
        switch tab {
        case .pdf:
            PDFTab(paper: paper, publicationID: id, selectedTab: .constant(.pdf))
        case .notes:
            NotesTab(publication: publication)
        case .bibtex:
            BibTeXTab(paper: paper, publicationID: id, publicationIDs: [id])
        case .info, .source:
            // Not publication-tab view kinds; the registry never routes them
            // here. Named rather than `default:` so a new tab is a compile
            // error at this switch.
            ChassisEmptyState(
                id: "detail-unavailable",
                title: "Detail Unavailable",
                systemImage: RecordKindDescriptor.unknownSymbolName,
                message: "\u{201C}\(tab.rawValue)\u{201D} is not a publication tab."
            )
            .view
        }
    }

    private func load(_ id: UUID?) {
        guard isPublicationPane, let id else {
            publication = nil
            loadedID = nil
            return
        }
        publication = RustStoreAdapter.shared.getPublicationDetail(id: id)
        loadedID = publication == nil ? nil : id
        // The proof line, beside the `info` pane's own: which kind, which
        // tab, which paper. A PDF viewer and "no PDF" look alike in a log.
        logInfo(
            "pane \(context.tile) \(tab.rawValue): publication \(id.uuidString)"
                + (publication == nil ? " — not in the store" : ""),
            category: "layout")
    }

    private func reload() {
        guard let id = loadedID else { return }
        publication = RustStoreAdapter.shared.getPublicationDetail(id: id)
        if publication == nil {
            // The paper went away while shown (PH-L6). Clearing `loadedID`
            // is what makes the pane say "No publication …" instead of
            // falling through to "select a publication" under a row that is
            // still selected.
            loadedID = nil
            logInfo(
                "pane \(context.tile) \(tab.rawValue): publication \(id.uuidString) — no longer in the store",
                category: "layout")
        }
    }
}
#endif
