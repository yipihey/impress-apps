//
//  IOSMessageListColumn.swift
//  impart-iOS
//
//  The mail list column (Stage 5c) — and a REPORTED SHARED-SURFACE GAP.
//
//  There is no shared iOS list host in the chassis. macOS has one per kind
//  (`MessageListWrapper`, `ManuscriptListWrapper`, `FigureListWrapper`,
//  `AgentRecordListWrapper`, `UnifiedPublicationListWrapper`) and every one of
//  them is `#if os(macOS)`; on iOS each app writes its own list:
//  imprint-iOS's is a `List` inside `IOSManuscriptLibraryView`, imbib-iOS's is
//  `IOSUnifiedPublicationListWrapper`, and this is impart's. Three app-side
//  lists is the point at which "each app writes its own" stops being a
//  coincidence, so it is flagged in the Stage 5c report as the next shared
//  surface to build rather than built unilaterally here.
//
//  What that gap does NOT cost, because Stage 5c closed the parts that mattered:
//
//    * WHICH ROWS a scope contains — `MailStoreReader.messages(in:)`, lifted out
//      of `MessageListWrapper.reload()` so All Inboxes / an account / a folder /
//      a flag colour fan out identically on both platforms, thread-collapsed with
//      the same "(n)" badge rule.
//    * WHAT A ROW LOOKS LIKE — `ImpressMailStyle.MailStyleRow` over
//      `MessageRowData`, the same row chrome and the same value snapshot macOS
//      renders. Unread dot, star, flag stripe, relative date, thread badge: all
//      of it is shared, none of it is re-authored here.
//    * WHAT A ROW CAN DO — `.recordTriageRow(...)` builds the swipe actions and
//      the long-press menu from `MessageRecordKind.descriptor.triage`, so the
//      absence of dismiss/archive/delete is the DECLARATION speaking, not this
//      file forgetting.
//
//  So what is genuinely local is the SwiftUI plumbing: a `List`, a search field,
//  and the reload triggers. That is the honest size of the gap.
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
    @State private var searchPresented = false
    @State private var isLoading = false

    private var visibleRows: [MessageRowData] {
        guard !searchText.isEmpty else { return rows }
        let query = searchText.lowercased()
        // The same three fields macOS's filter bar matches on.
        return rows.filter {
            $0.subject.lowercased().contains(query)
                || $0.from.lowercased().contains(query)
                || $0.preview.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if isLoading && rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRows.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            isPresented: $searchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search messages")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                // ⌘F for hardware keyboards — the iOS half of the chassis's
                // Find in List command.
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityIdentifier("toolbar.find")
            }
        }
        .task(id: scope) { reload() }
        .onChange(of: dataVersion) { _, _ in reload() }
        .refreshable { reload() }
    }

    // MARK: - List

    private var messageList: some View {
        List(selection: $selectedID) {
            ForEach(visibleRows) { row in
                MailStyleRow(item: row)
                    .tag(row.id)
                    .recordTriageRow(
                        triage: MessageRecordKind.descriptor.triage,
                        row: TriageRowState(
                            isStarred: row.isStarredState,
                            // Mail has no dismissal or archive status
                            // (`dismissal: .none`, `archiveStatus: nil`), so
                            // neither state can be true and the grammar omits
                            // both verbs. Same values macOS's list passes.
                            isDismissed: false,
                            isArchived: false),
                        targets: [row.id],
                        actions: actions,
                        rowTagPaths: Set(row.tagPaths))
                    .accessibilityIdentifier("messageRow.\(row.id.uuidString)")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("messageList")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            searchText.isEmpty ? "No Messages" : "No Matches",
            systemImage: "envelope",
            description: Text(
                searchText.isEmpty
                    // The honest empty state. impart-iOS reads mail the Mac
                    // mirrored into the shared store; it runs no IMAP sync of
                    // its own (there is none to run — `RustMailProvider` is a
                    // stub on both platforms), so "empty" means "nothing has
                    // been mirrored into this device's app group yet", not
                    // "you have no mail".
                    ? "Messages appear here once impart has mirrored mail into the shared store."
                    : "No message in this mailbox matches “\(searchText)”.")
        )
        // No create affordance: `MessageRecordKind.descriptor` declares one, and
        // the chassis would offer it, but only when a host registers
        // `RecordHostVerbs.onCreate`. This target registers none (no SMTP path),
        // so the button is absent rather than dead — the same rule the chassis's
        // own empty state applies.
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
