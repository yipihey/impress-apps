#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W4.
//
//  LayoutListRowMenus.swift
//  PublicationManagerCore
//
//  The context menu a `list` pane's row shows — the legacy list's own menu,
//  not a second one. A publication row shows `PublicationRowContextMenu`
//  over `PublicationListActions.chassis`, the builder the legacy
//  `UnifiedPublicationListWrapper` uses; what the wrapper did to its OWN
//  state (drop rows, advance its selection, open its tag input) is done here
//  to the TREE's: the selection is the channel's, and the rows re-read
//  themselves when the invalidation feed says the pane is stale.
//

import ImpressLayout
import ImpressLogging
import SwiftUI

// MARK: - The pane's scope, as the legacy list names it

/// The `PublicationSource` a publication list pane's query is — so the
/// delete / dismiss / save sequences (`PublicationListMutations`) take the
/// same scope-specific steps the legacy list takes for that scope (a delete
/// in a collection removes its `Contains` edge; a delete in Dismissed is
/// permanent; Save and Mute exist only in the Inbox).
///
/// A MAPPING from one representation of the scope to another, not a
/// decision: the query is Rust's (`impress_pane_query::PaneQuery`), and every
/// branch below reads one of its fields. A query with no single container
/// (every publication, or a filter over all of them) maps to `.combined([])`
/// — no scope-specific steps, the default library for anything that needs
/// one — rather than to a container it is not.
enum LayoutPaneScope {

    static func source(
        query: LayoutJSONValue?,
        bindings: [String: String],
        isInboxLibrary: (UUID) -> Bool,
        dismissedLibraryID: UUID?
    ) -> PublicationSource {
        guard let query else { return .combined([]) }
        let scope = query["scope"]
        if let kind = scope?["scope"]?.stringValue,
           let id = resolve(scope?["id"], bindings: bindings)
        {
            switch kind {
            case "collection", "collection-subtree":
                return .collection(id)
            case "parent":
                if id == dismissedLibraryID { return .dismissed }
                if isInboxLibrary(id) { return .inbox(id) }
                return .library(id)
            default:
                break
            }
        }
        for filter in query["filters"]?.arrayValue ?? [] {
            switch filter["filter"]?.stringValue {
            case "flag":
                return .flagged(filter["color"]?.stringValue)
            case "starred" where filter["starred"]?.boolValue == true:
                return .starred
            case "tag":
                if let path = filter["path"]?.stringValue { return .tag(path) }
            default:
                continue
            }
        }
        return .combined([])
    }

    /// The envelope parent a pane's query is scoped to, if it is one
    /// parent's — a figure folder files its members by parent
    /// (`outline::folder_scope`).
    static func parentID(query: LayoutJSONValue?, bindings: [String: String]) -> UUID? {
        guard query?["scope"]?["scope"]?.stringValue == "parent" else { return nil }
        return resolve(query?["scope"]?["id"], bindings: bindings)
    }

    /// The collection a pane's query is scoped to, if it is one collection's
    /// — a manuscript folder is a collection.
    static func collectionID(query: LayoutJSONValue?, bindings: [String: String]) -> UUID? {
        guard let kind = query?["scope"]?["scope"]?.stringValue,
              kind == "collection" || kind == "collection-subtree"
        else { return nil }
        return resolve(query?["scope"]?["id"], bindings: bindings)
    }

    /// An `ItemRef`: `{"ref": "id", "id": …}` or `{"ref": "param", "name": …}`.
    private static func resolve(_ ref: LayoutJSONValue?, bindings: [String: String]) -> UUID? {
        switch ref?["ref"]?.stringValue {
        case "id":
            return ref?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        case "param":
            return ref?["name"]?.stringValue
                .flatMap { bindings[$0] }
                .flatMap(UUID.init(uuidString:))
        default:
            return nil
        }
    }
}

// MARK: - Publication rows

/// A publication row's menu in a `list` pane.
@MainActor
struct LayoutPublicationRowMenu: View {

    let context: PaneContext
    /// What the menu acts on: the selection when the clicked row is in it,
    /// else the clicked row (Mail semantics, as the legacy list).
    let targets: Set<UUID>
    /// The pane's rows in the order it shows them, for "select the next row"
    /// after a dismiss or save.
    let order: [UUID]
    /// The pane's row revision — an input only, so the menu is rebuilt (and
    /// re-reads its row) whenever the pane re-reads its rows.
    let revision: Int

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager

    var body: some View {
        let source = LayoutPaneScope.source(
            query: context.spec?.query,
            bindings: context.bindings,
            isInboxLibrary: { id in
                RustStoreAdapter.shared.getLibrary(id: id)?.isInbox ?? false
            },
            dismissedLibraryID: libraryManager.dismissedLibrary?.id)
        PublicationRowContextMenu(
            ids: targets,
            actions: .chassis(host(source)),
            row: { RustStoreAdapter.shared.getPublication(id: $0) },
            libraryID: source.libraryIDOrDefaultLibrary,
            allLibraries: RustStoreAdapter.shared.listLibraries().map { ($0.id, $0.name) },
            allScixLibraries: SciXLibraryRepository.shared.libraries
                .filter { ["owner", "admin", "write"].contains($0.permissionLevel) }
                .map { ($0.id, $0.name) },
            willDelete: {})
    }

    private func host(_ source: PublicationSource) -> PublicationListActionsHost {
        let context = context
        let order = order
        let targets = targets
        return PublicationListActionsHost(
            source: source,
            canEdit: true,
            libraryViewModel: libraryViewModel,
            libraryManager: libraryManager,
            // The rules that read rows (star, e-ink) read only the targets.
            rows: { targets.compactMap { RustStoreAdapter.shared.getPublication(id: $0) } },
            willDelete: { ids in
                // The rows go when the pane re-reads; the selection is the
                // channel's, so the deleted ids leave it now.
                let kept = context.currentSelection.filter {
                    UUID(uuidString: $0).map { !ids.contains($0) } ?? true
                }
                context.select(Array(kept), kind: RecordKindID.publication.rawValue)
            },
            nextSelection: { ids in
                PublicationListOrder.nextSelection(removing: ids, inOrder: order)
            },
            select: { id in
                context.select(
                    id.map { [$0.uuidString.lowercased()] } ?? [],
                    kind: RecordKindID.publication.rawValue)
            },
            // The legacy list opens its inline tag field; a pane has none,
            // so it asks with the triage menu's own "New Tag…" prompt.
            beginTagInput: { ids in
                guard let path = RecordTriageNewTagPrompt.run() else { return }
                RustStoreAdapter.shared.addTag(ids: Array(ids), tagPath: path)
            },
            // Through the TREE, not the global `.showPDFTab` (review PH-M10):
            // that switched every `info` pane in every window — including one
            // beside a `pdf` pane, which then showed the PDF twice — and no
            // agent could see or replay it.
            // Selecting the row and showing its PDF are ONE gesture (one ⌘Z).
            openPDF: { id in
                LayoutOpenPDF.open(
                    from: context.tile,
                    selecting: LayoutOpenPDF.Selection(
                        kind: RecordKindID.publication.rawValue, ids: [id.uuidString.lowercased()]),
                    controller: context.controller)
            },
            // No list-background drop and no batch-download sheet in a pane:
            // both are presented by the legacy content view, which a tree
            // does not mount. The menu hides what these leave nil.
            onListDrop: nil,
            onDownloadPDFs: nil,
            onRefresh: nil)
    }
}
// MARK: - Open PDF

/// "Open PDF" from a list pane's row, as ordinary verbs applied as ONE
/// gesture (`LayoutController.applyAll`, review PH-M2): selecting the row,
/// switching the `info` pane's tab and focusing the pane that shows the PDF
/// are one click, so they are one undo entry, and a refusal of any of them
/// applies none. They used to be separate verbs, and the selection and the
/// tab landed on two different panes' undo rings — two ⌘Zs in two panes to
/// take back one click.
@MainActor
enum LayoutOpenPDF {

    /// What happened, for the log and the tests.
    enum Outcome: Equatable {
        /// A `pdf` pane follows this list's channel: it was focused.
        case focusedPDFPane(UInt64)
        /// No `pdf` pane, but an `info` pane does: its tab was set to PDF.
        case infoPaneTab(UInt64)
        /// Neither follows this list: nothing on screen can show the PDF.
        case nowhere
        /// Rust refused the gesture: none of it was applied.
        case refused
    }

    /// The row being opened, published on the list's channel in the same
    /// step (what `PaneContext.select` publishes for a click).
    struct Selection: Equatable {
        let kind: String
        let ids: [String]
    }

    /// Show the selected paper's PDF in the pane that follows `listTile`'s
    /// channel: focus a `pdf` pane if there is one, else set the `info`
    /// pane's tab to PDF through its `view_state` (a `set-pane`, attributed
    /// and undoable) and focus it. `selection`, when given, is published on
    /// the list's channel in the same step.
    ///
    /// The tab write goes first, so the step is recorded on the `info` pane's
    /// exploration ring (`UndoStacks::apply_all` records a gesture on its
    /// first recorded verb's ring) — the pane focus ends on, so the next ⌘Z
    /// takes the whole click back.
    @discardableResult
    static func open(
        from listTile: UInt64, selecting selection: Selection? = nil, controller: LayoutController
    ) -> Outcome {
        guard let tree = controller.tree else { return .nowhere }
        var select: [LayoutJSONValue] = []
        if let selection {
            select.append(.object([
                "verb": .string("select"),
                "target": LayoutPaneRef.id(listTile).json,
                "kind": .string(selection.kind),
                "ids": .array(selection.ids.map { .string($0) }),
            ]))
        }
        func focus(_ tile: UInt64) -> [LayoutJSONValue] {
            controller.focused == tile ? [] : [LayoutVerb.focus(target: .id(tile)).verbJSON!]
        }

        if let pdf = LayoutPaneViewState.pane(showing: .pdf, onChannelOf: listTile, in: tree) {
            logInfo("Open PDF from pane \(listTile): focus pdf pane \(pdf)", category: "layout")
            let applied = apply(select + focus(pdf), label: "open PDF in pane \(pdf)", controller: controller)
            return applied ? .focusedPDFPane(pdf) : .refused
        }
        if let info = LayoutPaneViewState.pane(showing: .info, onChannelOf: listTile, in: tree) {
            logInfo("Open PDF from pane \(listTile): info pane \(info) → PDF tab", category: "layout")
            let tab: [LayoutJSONValue]
            switch LayoutPaneViewState.write(
                [LayoutViewStateKey.tab: .string(DetailTab.pdf.rawValue)], into: info,
                controller: controller, why: "Open PDF from pane \(listTile)")
            {
            case .verb(let verb): tab = [verb]
            case .unchanged: tab = []
            case nil: return .refused
            }
            let applied = apply(
                tab + select + focus(info), label: "open PDF in info pane \(info)", controller: controller)
            return applied ? .infoPaneTab(info) : .refused
        }
        logInfo(
            "Open PDF from pane \(listTile): no pdf or info pane follows its channel — nothing to show it in",
            category: "layout")
        // The row was still picked: publish it where it is.
        _ = apply(select + focus(listTile), label: "select for open PDF", controller: controller)
        return .nowhere
    }

    /// One gesture: all of it or none. An empty one is nothing to do.
    private static func apply(
        _ verbs: [LayoutJSONValue], label: String, controller: LayoutController
    ) -> Bool {
        guard !verbs.isEmpty else { return true }
        do {
            let json = try LayoutJSONValue.array(verbs).jsonString()
            // 2. SAVE — what Rust did with the click.
            let applied = try controller.applyAll(json, label: label)
            logInfo(
                "Open PDF: \(verbs.count) verb(s) as one step → version \(applied.version)",
                category: "layout")
            return true
        } catch {
            logWarning(
                "Open PDF: \(label) refused, none of its \(verbs.count) verb(s) applied — \(error)",
                category: "layout")
            return false
        }
    }
}

// MARK: - Manuscript rows

/// A manuscript row's menu in a `list` pane: `ManuscriptRowMenu`, over the
/// row as the store has it now (star, status, tags — what the triage segment
/// phrases itself from).
@MainActor
struct LayoutManuscriptRowMenu: View {
    let rowID: UUID
    /// See `LayoutPublicationRowMenu.revision`.
    let revision: Int
    let targets: Set<UUID>
    let isFolderScoped: Bool
    let actions: RecordTriageActions
    let onRename: (ManuscriptRenameRequest) -> Void

    var body: some View {
        if let row = RustStoreAdapter.shared.getManuscriptRow(id: rowID)
            .flatMap(ManuscriptRowData.init(from:))
        {
            ManuscriptRowMenu(
                rowID: row.id,
                triage: row.triageRowState,
                rowTagPaths: Set(row.tagDisplays.map(\.path)),
                targets: targets,
                isFolderScoped: isFolderScoped,
                actions: actions,
                onRename: { onRename(ManuscriptRenameRequest(id: row.id, title: row.title)) })
        }
    }
}
#endif
