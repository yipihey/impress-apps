//
//  IOSImpressListColumn.swift
//  impress-iOS
//
//  ONE list column for three kinds.
//
//  `RecordListHost` (the shared iOS list host: search field, ⌘F, pull to
//  refresh, empty/loading phases, triage row grammar) is generic over any
//  `Identifiable` row, and all three of the chassis's row-data types conform to
//  `MailStyleItem` — so the row VIEW is `MailStyleRow` for every kind, exactly
//  as it is on macOS. What is left per kind is the honest minimum: which rows a
//  scope contains, and what a text query matches.
//
//  The triage capabilities and the row's verbs come from the KIND'S DESCRIPTOR,
//  never from a switch here: mail declares no dismiss/archive/delete, figures
//  declare no create, tasks declare `.none` for everything the kernel owns. A
//  verb this shell cannot offer is a verb the descriptor did not declare. None
//  of the three declares a dismissal or an archive status — mail's lifecycle is
//  IMAP-owned, figures have no status field, task state moves only through the
//  kernel — so `TriageRowState` passes false for both and the swipe grammar
//  omits those verbs by itself.
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
        case .runs:
            // Unreachable: `.agentRun` is not in `presentableKinds`, so no
            // sidebar node routes here. See ImpressSidebarBindings' header.
            return []
        }
    }
}
