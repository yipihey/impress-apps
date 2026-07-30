#if os(iOS)
// Chassis file — iOS-only. The macOS twin is `UnifiedPublicationListWrapper`.
//
//  IOSPublicationListPane.swift
//  PublicationManagerCore
//
//  THE read-only iOS publication list, for hosts that are not imbib.
//
//  ## Why this is a new view rather than a lift (I2, 2026-07-30)
//
//  The obvious move was to lift `IOSUnifiedPublicationListWrapper` out of the
//  imbib target the way `IOSPublicationDetailPane` was lifted. It was surveyed
//  and rejected, and the reason is worth writing down because "reuse the
//  existing one" is the right default:
//
//  The wrapper is 791 lines and only about a fifth of them are "show these
//  papers". The rest are imbib's LIBRARY-MANAGEMENT verbs — the inbox/feed
//  triage flow (save-to-library, destructive dismissal that must not come
//  back), the BibTeX editor sheet, the sort/unread/recommendation controls,
//  multi-select, the per-source `Source` enum carrying display names, the
//  attachment drop path and the smart-search pull. Every one of those needs a
//  library to put something in, a `LibraryManager`, or a sidebar listening for
//  imbib's navigation notifications. A shell that reads the shared store and
//  writes nothing to a bibliography would have inherited all of it as dead or,
//  worse, half-live code.
//
//  What the other hosts need is what `RecordListHost` already is for mail,
//  figures, tasks and manuscripts. So the honest shape is the same one those
//  four use: `RecordListHost` + the kind's DESCRIPTOR for the triage grammar,
//  over `PublicationRowData` rows rendered by `MailStylePublicationRow` — the
//  same row view macOS draws. The one thing this does NOT re-implement is
//  scope→rows: that is `PublicationListCore` (cross-platform since Stage 5d,
//  and what imbib's wrapper itself uses), so the query, the paging and the sort
//  are shared with both of imbib's hosts and cannot drift.
//
//  ## What this pane can and cannot do
//
//  CAN: show any `PublicationSource` (a library, a collection, flagged, cited
//  in manuscripts, dismissed, …), search it, pull to refresh, and offer the
//  triage verbs the publication descriptor DECLARES — star, flag, tag. Those
//  route through `RecordTriageActions.storeBacked`, the generic path, so they
//  work in any host with no app-side verb table.
//
//  CANNOT: dismiss. Not an omission — `PublicationRecordKind.descriptor`
//  declares `dismissal: .libraryMove`, and `storeBacked` deliberately leaves
//  `onDismiss` unset for that case because moving a paper to the Dismissed
//  LIBRARY needs a `LibraryManager`. The swipe grammar reads the capability and
//  omits the verb by itself; nothing here says the word "dismiss".
//

import ImpressFTUI
import ImpressMailStyle
import SwiftUI

/// A read-only publication list over one `PublicationSource`.
public struct IOSPublicationListPane: View {

    private let source: PublicationSource
    private let title: String
    private let listIdentifier: String
    @Binding private var selectedID: UUID?
    private let dataVersion: Int?

    /// The scope's rows, paging and sort. Rebuilt when the source changes,
    /// which is why hosts must `.id(...)` this view on the source — the same
    /// rule imbib's wrappers carry (`PublicationListCore.source` is a `let`).
    @State private var core: PublicationListCore
    @State private var searchText = ""

    public init(
        source: PublicationSource,
        title: String,
        selectedID: Binding<UUID?>,
        listIdentifier: String = "publicationList",
        dataVersion: Int? = nil
    ) {
        self.source = source
        self.title = title
        self._selectedID = selectedID
        self.listIdentifier = listIdentifier
        self.dataVersion = dataVersion
        self._core = State(initialValue: PublicationListCore(source: source))
    }

    // MARK: - Query

    /// The in-memory predicate over the loaded page.
    ///
    /// Deliberately NOT a store search: `PublicationListCore` pages a scope,
    /// and a full-text search across the workspace is a different surface
    /// (imbib's, and `StoreSearchSurface`'s on macOS). Matching what is on
    /// screen is the honest promise a filter field can keep here.
    private var rows: [PublicationRowData] {
        guard !searchText.isEmpty else { return core.rows }
        let query = searchText.lowercased()
        return core.rows.filter { row in
            [row.title, row.authorString, row.citeKey, row.venue ?? ""]
                .contains { $0.lowercased().contains(query) }
        }
    }

    public var body: some View {
        RecordListHost(
            rows: rows,
            selection: $selectedID,
            searchText: $searchText,
            title: title,
            searchPrompt: "Search papers",
            emptyState: ChassisEmptyState(
                id: "publication-empty",
                title: searchText.isEmpty ? "No Papers" : "No Matches",
                systemImage: "doc.text",
                message: searchText.isEmpty
                    ? "Papers appear here once the suite has written them to the shared store."
                    : "Nothing in this scope matches \u{201C}\(searchText)\u{201D}."),
            rowIdentifierPrefix: "publicationRow.",
            listIdentifier: listIdentifier,
            triage: PublicationRecordKind.descriptor.triage,
            actions: RecordTriageActions.storeBacked(
                descriptor: PublicationRecordKind.descriptor),
            rowState: { TriageRowState(isStarred: $0.isStarred, isDismissed: false) },
            rowTagPaths: { Set($0.tagDisplays.map(\.path)) },
            scopeToken: source,
            dataVersion: dataVersion,
            onReload: { reload() },
            rowContent: { MailStylePublicationRow(data: $0) })
    }

    @MainActor
    private func reload() {
        core.reload()
        if let current = selectedID, !core.rows.contains(where: { $0.id == current }) {
            selectedID = nil
        }
    }
}
#endif  // os(iOS)
