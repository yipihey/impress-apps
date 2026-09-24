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
            openPDF: { id in
                context.select([id.uuidString.lowercased()], kind: RecordKindID.publication.rawValue)
                NotificationCenter.default.post(name: .showPDFTab, object: nil)
            },
            // No list-background drop and no batch-download sheet in a pane:
            // both are presented by the legacy content view, which a tree
            // does not mount. The menu hides what these leave nil.
            onListDrop: nil,
            onDownloadPDFs: nil,
            onRefresh: nil)
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
