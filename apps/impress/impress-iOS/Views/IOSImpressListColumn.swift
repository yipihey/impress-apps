//
//  IOSImpressListColumn.swift
//  impress-iOS
//
//  ONE list column for five kinds.
//
//  `RecordListHost` (the shared iOS list host: search field, ⌘F, pull to
//  refresh, empty/loading phases, triage row grammar) is generic over any
//  `Identifiable` row, and four of the chassis's row-data types conform to
//  `MailStyleItem` — so the row VIEW is `MailStyleRow` for those kinds, exactly
//  as it is on macOS. What is left per kind is the honest minimum: which rows a
//  scope contains, and what a text query matches.
//
//  PUBLICATIONS are the exception, and deliberately so: their rows go through
//  the chassis's `IOSPublicationListPane` (I2) rather than being assembled
//  here. That pane is `RecordListHost` too — over `PublicationRowData` rendered
//  by `MailStylePublicationRow`, the row view macOS draws — but the scope→rows
//  half is `PublicationListCore`, which owns the paging and the sort and is
//  shared with both of imbib's hosts. Re-deriving a publication query in a
//  shell would be the one place this file could invent a second truth.
//
//  The triage capabilities and the row's verbs come from the KIND'S DESCRIPTOR,
//  never from a switch here: mail declares no dismiss/archive/delete, figures
//  declare no create, tasks declare `.none` for everything the kernel owns,
//  manuscripts declare a full status lifecycle, publications declare a
//  library-move dismissal that needs a `LibraryManager` this shell does not
//  have. A verb this shell cannot offer is a verb the descriptor did not
//  declare — or, for publications, one `RecordTriageActions.storeBacked`
//  deliberately leaves unset for `.libraryMove`.
//

import ImpressMailStyle
import PublicationManagerCore
import SwiftUI

struct IOSImpressListColumn: View {

    let route: ImpressRoute
    @Binding var selectedID: UUID?
    let dataVersion: Int

    @State private var messages: [MessageRowData] = []
    @State private var figures: [FigureRowData] = []
    @State private var tasks: [TaskRowData] = []
    @State private var manuscripts: [ManuscriptRowData] = []
    @State private var searchText = ""

    var body: some View {
        switch route {
        case .messages(let scope):
            list(rows: filtered(messages) { [$0.subject, $0.from, $0.preview] },
                 descriptor: MessageRecordKind.descriptor,
                 prefix: "messageRow.",
                 listID: "messageList",
                 prompt: "Search messages",
                 emptyTitle: "No Messages",
                 emptySymbol: "envelope",
                 rowState: { TriageRowState(isStarred: $0.isStarredState, isDismissed: false) },
                 tagPaths: { Set($0.tagPaths) },
                 reload: { messages = MailStoreReader.shared.messages(in: scope) })
        case .figures(let scope):
            list(rows: filtered(figures) { [$0.title, $0.caption ?? "", $0.format] },
                 descriptor: FigureRecordKind.descriptor,
                 prefix: "figureRow.",
                 listID: "figureList",
                 prompt: "Search figures",
                 emptyTitle: "No Figures",
                 emptySymbol: "photo",
                 rowState: { TriageRowState(isStarred: $0.isStarredState, isDismissed: false) },
                 tagPaths: { Set($0.tagPaths) },
                 reload: { figures = Self.loadFigures(scope) })
        case .tasks(let scope):
            list(rows: filtered(tasks) { [$0.title, $0.taskDescription, $0.state] },
                 descriptor: TaskRecordKind.descriptor,
                 prefix: "taskRow.",
                 listID: "taskList",
                 prompt: "Search tasks",
                 emptyTitle: "No Tasks",
                 emptySymbol: "checklist",
                 rowState: { TriageRowState(isStarred: $0.isStarredState, isDismissed: false) },
                 tagPaths: { Set($0.tagPaths) },
                 reload: { tasks = Self.loadTasks(scope) })
        case .manuscripts(let scope, _):
            list(rows: filtered(manuscripts) { [$0.title, $0.authorString, $0.statusRaw] },
                 descriptor: ManuscriptRecordKind.descriptor,
                 prefix: "manuscriptRow.",
                 listID: "manuscriptList",
                 prompt: "Search manuscripts",
                 emptyTitle: "No Manuscripts",
                 emptySymbol: "doc.richtext",
                 rowState: {
                     TriageRowState(
                         isStarred: $0.isStarredState,
                         // The descriptor's declared dismissal status, read off
                         // the kind rather than spelled here.
                         isDismissed: $0.statusRaw
                             == ManuscriptRecordKind.descriptor.triage.dismissedStatus)
                 },
                 tagPaths: { Set($0.tagDisplays.map(\.path)) },
                 reload: { manuscripts = Self.loadManuscripts(scope) })
        case .publications(let source, let title):
            IOSPublicationListPane(
                source: source,
                title: title,
                selectedID: $selectedID,
                listIdentifier: "publicationList",
                dataVersion: dataVersion)
        }
    }

    // MARK: - One host, parameterised

    @ViewBuilder
    private func list<Row: MailStyleItem>(
        rows: [Row],
        descriptor: RecordKindDescriptor,
        prefix: String,
        listID: String,
        prompt: String,
        emptyTitle: String,
        emptySymbol: String,
        rowState: @escaping (Row) -> TriageRowState,
        tagPaths: @escaping (Row) -> Set<String>,
        reload: @escaping () -> Void
    ) -> some View {
        RecordListHost(
            rows: rows,
            selection: $selectedID,
            searchText: $searchText,
            title: route.title,
            searchPrompt: prompt,
            emptyState: ChassisEmptyState(
                id: "\(route.kind.rawValue)-empty",
                title: searchText.isEmpty ? emptyTitle : "No Matches",
                systemImage: emptySymbol,
                message: searchText.isEmpty
                    // The honest empty state: impress reads what the suite
                    // wrote into the shared store; it syncs nothing itself.
                    ? "Records appear here once the suite has written them to the shared store."
                    : "Nothing in this scope matches \u{201C}\(searchText)\u{201D}."),
            rowIdentifierPrefix: prefix,
            listIdentifier: listID,
            triage: descriptor.triage,
            actions: ImpressSidebarBindings.triageActions(for: route.kind),
            rowState: rowState,
            rowTagPaths: tagPaths,
            scopeToken: route,
            dataVersion: dataVersion,
            onReload: {
                reload()
                if let current = selectedID, !rows.contains(where: { $0.id == current }) {
                    selectedID = nil
                }
            },
            rowContent: { MailStyleRow(item: $0) })
    }

    /// The query predicate, over the loaded page. The host owns the FIELD; it
    /// has no opinion about the predicate, because imprint's is a store search
    /// and mail's is three in-memory fields.
    private func filtered<Row>(_ rows: [Row], fields: (Row) -> [String]) -> [Row] {
        guard !searchText.isEmpty else { return rows }
        let query = searchText.lowercased()
        return rows.filter { row in
            fields(row).contains { $0.lowercased().contains(query) }
        }
    }

    // MARK: - Scope → rows

    private static func loadFigures(_ scope: FigureListScope) -> [FigureRowData] {
        let rows: [FigureRowData]
        switch scope {
        case .all:
            rows = FigureStoreReader.shared.fetchFigures().compactMap(FigureRowData.init(from:))
        case .folder(let id):
            rows = FigureStoreReader.shared
                .fetchFigures(inFolder: id.uuidString.lowercased())
                .compactMap(FigureRowData.init(from:))
        case .unfiled:
            rows = FigureStoreReader.shared.fetchFigures()
                .compactMap(FigureRowData.init(from:))
                .filter { $0.parentIDString == nil }
        case .flagged(let color):
            rows = FigureStoreReader.shared.fetchFigures()
                .compactMap(FigureRowData.init(from:))
                .filter { row in
                    guard let flag = row.flag else { return false }
                    guard let color else { return true }
                    return flag.color == color
                }
        case .tag(let path):
            // Envelope post-filter through the one matching authority, exactly
            // as PMC's `FigureListWrapper` does it — never a query argument,
            // because tags are not in the payload.
            rows = FigureStoreReader.shared.fetchFigures()
                .filter { TagPathMatch.anyMatches($0.tags, scopePath: path) }
                .compactMap(FigureRowData.init(from:))
        }
        return rows
    }

    private static func loadTasks(_ scope: AgentListScope) -> [TaskRowData] {
        switch scope {
        case .tasks:
            return AgentStoreReader.shared.fetchTasks().compactMap(TaskRowData.init(from:))
        case .tasksByState(let state):
            return AgentStoreReader.shared.fetchTasks(state: state)
                .compactMap(TaskRowData.init(from:))
        case .flagged(let color):
            // The envelope's `flag_color` is the researcher's mark, not the
            // kernel's state — a different axis, so this crosses every
            // lifecycle state on purpose.
            return AgentStoreReader.shared.fetchTasks()
                .filter { row in
                    guard let flagColor = row.flagColor else { return false }
                    if let color { return flagColor == color.rawValue }
                    return true
                }
                .compactMap(TaskRowData.init(from:))
        case .tag(let path):
            // TASKS only, and that is the chassis's decision rather than this
            // host's: an `agent-run` is immutable provenance with no user mark
            // to browse back, so the Agents section's tag rows bind `.task`.
            return AgentStoreReader.shared.fetchTasks()
                .filter { TagPathMatch.anyMatches($0.tags, scopePath: path) }
                .compactMap(TaskRowData.init(from:))
        case .runs:
            // Unreachable: `.agentRun` is not in `presentableKinds`, so no
            // sidebar node routes here. See ImpressSidebarBindings' header.
            return []
        }
    }

    /// PMC's OWN manuscript reads (`RustStoreAdapter`), not ImprintCore's
    /// adapter — impress links no imprint core. The five cases are the five
    /// `ManuscriptListScope` cases, one query each.
    @MainActor
    private static func loadManuscripts(_ scope: ManuscriptListScope) -> [ManuscriptRowData] {
        let store = RustStoreAdapter.shared
        switch scope {
        case .all:
            return store.queryManuscripts().compactMap(ManuscriptRowData.init(from:))
        case .status(let status):
            return store.queryManuscripts(status: status.rawValue)
                .compactMap(ManuscriptRowData.init(from:))
        case .folder(let id):
            return store.queryManuscripts(collectionID: id)
                .compactMap(ManuscriptRowData.init(from:))
        case .flagged(let color):
            return store.getFlaggedManuscripts(color: color)
                .compactMap(ManuscriptRowData.init(from:))
        case .tag(let path):
            // ADR-0023 W3 — a watched folder's rows. Tags live on the item
            // ENVELOPE, not the payload, so this is a post-filter rather than
            // a query parameter: the same shape the flagged path above takes,
            // and the reason `listManuscripts` needs no new argument (nor a
            // new FFI verb whose only caller would be this one row kind).
            // Mirrors `ManuscriptListWrapper.reload()`.
            return store.queryManuscripts()
                .compactMap(ManuscriptRowData.init(from:))
                .filter { $0.tagDisplays.contains { $0.path == path } }
        }
    }
}
