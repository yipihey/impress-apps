//
//  IOSMessageListColumn.swift
//  impart-iOS
//
//  The mail list column (Stage 5c) — and, since C1 (2026-07-30), THE SHARED
//  HOST rather than impart's own `List`.
//
//  Stage 5c reported the gap this file used to be evidence of: "there is no
//  shared iOS list host", so imprint-iOS, imbib-iOS and impart each wrote their
//  own `List` + search field + reload triggers. That plumbing is now
//  `PublicationManagerCore.RecordListHost` (Chassis/RecordKind/
//  RecordListHostView.swift + its cross-platform model half), and this file is
//  what genuinely belongs to MAIL:
//
//    * WHICH ROWS a scope contains — `MailStoreReader.messages(in:)`, shared
//      with macOS since Stage 5c (thread-collapsed, same "(n)" badge rule).
//    * WHAT A QUERY MATCHES — the three fields macOS's filter bar matches on,
//      applied in memory to the loaded page. The host owns the search FIELD; it
//      has no opinion about the predicate, because imprint's is a store search.
//    * WHAT A ROW LOOKS LIKE — `ImpressMailStyle.MailStyleRow` over
//      `MessageRowData`, the same row chrome macOS renders.
//    * WHAT A ROW CAN DO — `MessageRecordKind.descriptor.triage`, so the absence
//      of dismiss/archive/delete is the DECLARATION speaking.
//    * The honest EMPTY STATE, as a `ChassisEmptyState` value.
//    * Keeping the selection valid, which is per-app policy: impart CLEARS a
//      selection whose row left the scope, imprint keeps the open manuscript.
//

import ImpressMailStyle
import PublicationManagerCore
import SwiftUI

struct IOSMessageListColumn: View {

    /// What the sidebar selected, already translated to PMC's mail vocabulary.
    let scope: MessageListScope

    /// The selected ROW's title. `MessageListScope.title` says "Folder" /
    /// "Account" for the two id-carrying cases — it cannot know the name, and the
    /// sidebar node does, so the host passes it down.
    let title: String

    /// The message the detail column shows. On iPhone the split view is a stack,
    /// so writing this PUSHES the detail; on iPad it fills the third column.
    @Binding var selectedID: UUID?

    let actions: RecordTriageActions

    /// Bumped by the host when the store changes, so the list reloads with the
    /// sidebar rather than on its own schedule.
    let dataVersion: Int

    @State private var rows: [MessageRowData] = []
    @State private var searchText = ""
    @State private var isLoading = false

    /// The same three fields macOS's filter bar matches on. Mail's query is a
    /// predicate over the loaded page; imprint's is a store search with a scope
    /// intersection. Two capabilities, one text field — which is why the shared
    /// host takes rows and a `Binding<String>` and never filters.
    private var visibleRows: [MessageRowData] {
        guard !searchText.isEmpty else { return rows }
        let query = searchText.lowercased()
        return rows.filter {
            $0.subject.lowercased().contains(query)
                || $0.from.lowercased().contains(query)
                || $0.preview.lowercased().contains(query)
        }
    }

    var body: some View {
        RecordListHost(
            rows: visibleRows,
            selection: $selectedID,
            searchText: $searchText,
            title: title,
            searchPrompt: "Search messages",
            emptyState: emptyState,
            rowIdentifierPrefix: "messageRow.",
            listIdentifier: "messageList",
            isLoading: isLoading,
            triage: MessageRecordKind.descriptor.triage,
            actions: actions,
            rowState: { row in
                TriageRowState(
                    isStarred: row.isStarredState,
                    // Mail has no dismissal or archive status (`dismissal:
                    // .none`, `archiveStatus: nil`), so neither state can be
                    // true and the grammar omits both verbs. Same values macOS's
                    // list passes.
                    isDismissed: false,
                    isArchived: false)
            },
            rowTagPaths: { Set($0.tagPaths) },
            // This column owns its own read, so it opts into all three reload
            // triggers: scope change, store version, pull-to-refresh.
            scopeToken: scope,
            dataVersion: dataVersion,
            onReload: { reload() },
            rowContent: { MailStyleRow(item: $0) })
    }

    // MARK: - Empty state

    /// No create affordance in either state: `MessageRecordKind.descriptor`
    /// declares one and the chassis would offer it, but only when a host
    /// registers `RecordHostVerbs.onCreate`. This target registers none (no SMTP
    /// path), so the button is absent rather than dead — which is why this host
    /// passes no `emptyActions` builder at all.
    private var emptyState: ChassisEmptyState {
        if searchText.isEmpty {
            return ChassisEmptyState(
                id: "mail-empty",
                title: "No Messages",
                systemImage: "envelope",
                // The honest empty state. impart-iOS reads mail the Mac mirrored
                // into the shared store; it runs no IMAP sync of its own (there
                // is none to run — `RustMailProvider` is a stub on both
                // platforms), so "empty" means "nothing has been mirrored into
                // this device's app group yet", not "you have no mail".
                message:
                    "Messages appear here once impart has mirrored mail into the shared store.")
        }
        return ChassisEmptyState(
            id: "mail-no-matches",
            title: "No Matches",
            systemImage: "envelope",
            message: "No message in this mailbox matches \u{201C}\(searchText)\u{201D}.")
    }

    // MARK: - Data

    private func reload() {
        isLoading = true
        defer { isLoading = false }
        // Scope → rows is PMC's, shared with macOS (Stage 5c).
        let fetched = MailStoreReader.shared.messages(in: scope)
        rows = fetched
        // Keep the selection valid. Unlike macOS this does NOT auto-select the
        // first row: on a phone the split view is a stack, so writing a
        // selection pushes the detail view over the list the user just landed
        // on. Selecting is the user's move here.
        if let current = selectedID, !fetched.contains(where: { $0.id == current }) {
            selectedID = nil
        }
    }
}
