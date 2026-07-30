#if os(iOS)
// Chassis view — iOS. Its DATA half (`RecordListHostModel.swift`) is
// cross-platform and ungated; only this renderer is platform-shaped, exactly
// like the `RecordSidebarModel` / `RecordSidebarView` pair.
//
//  RecordListHostView.swift
//  PublicationManagerCore
//
//  C1 (2026-07-30) — THE shared iOS list host, and the honest size of it.
//
//  ## What was written twice
//
//  Stage 5c reported the gap ("there is no shared iOS LIST host") and Stage 5d
//  narrowed it: imbib-iOS does NOT hand-write a list — its host is
//  `SharedViews/PublicationListView`, 2,021 cross-platform lines — so a host
//  generalized from imbib would be generalized from a file imbib would not use.
//  The two hosts that DO hand-write one are the two that asked:
//  `IOSMessageListColumn` (impart) and the `listColumn` middle of
//  `IOSManuscriptLibraryView` (imprint). Set side by side, what is IDENTICAL is:
//
//    * `List(selection:) { ForEach(rows) { row.tag(id).recordTriageRow(…) } }`
//      with `.listStyle(.plain)`;
//    * the search FIELD — `.searchable(text:isPresented:placement:prompt:)` in a
//      `.navigationBarDrawer`, plus the ⌘F toolbar button (same glyph, same
//      `toolbar.find` identifier, same `keyboardShortcut`) that exists because a
//      hardware keyboard on iPad has no other way to reach the field;
//    * the three-state branch (spinner / empty state / rows) and the
//      `.navigationTitle` + `.navigationBarTitleDisplayMode(.inline)` pair;
//    * the reload triggers: `.task(id: scope)`, `.onChange(of: dataVersion)`,
//      `.refreshable`;
//    * the row accessibility-identifier convention both UI suites match by
//      prefix.
//
//  ## What each app parameterizes, and why it is not shared
//
//  * **The ROW.** imprint draws a flag dot + title + status badge + authors +
//    format; impart draws `ImpressMailStyle.MailStyleRow` over `MessageRowData`.
//    A row is the kind's own chrome (and impart's is already shared with macOS);
//    collapsing them would mean one of the two changing pixels, which is a
//    product decision, not a duplication. `rowContent` is a builder.
//  * **WHICH ROWS a query matches.** See `RecordListHostModel`'s header: one is
//    a store search with a scope intersection, the other an in-memory filter
//    over three fields. The host owns the FIELD, not the predicate — it takes a
//    `Binding<String>` and never reads it except to hand it to `.searchable`.
//  * **The empty-state COPY**, as a `ChassisEmptyState` value built by the app
//    (imprint: "No Manuscripts" / "No Results"; impart: "No Messages" / "No
//    Matches" with its honest "nothing has been mirrored yet" sentence). Which
//    of the two an app shows depends on whether its query is empty, so the app
//    passes the resolved state and the host renders it. The `emptyActions`
//    builder is how imprint keeps its "New Manuscript" button and impart keeps
//    NO button — it registers no create verb, so offering one would be a dead
//    control (the `RecordTriageNewTagPrompt` rule).
//  * **Triage.** `triage:` is the kind's declared `TriageCapabilities` and
//    `actions:` the host's bag, so left-swipe/long-press grammar stays the
//    descriptor's answer rather than this file's.
//
//  ## Why `.searchable` and not `ImpressFTUI.FilterInput`
//
//  `FilterInput` is the macOS list's inline filter BAR: a 12 pt monospaced
//  field with a `FILTER` mode indicator, `?` syntax help and ESC-to-clear,
//  designed to be overlaid on a pointer-driven list. The iOS idiom is the
//  navigation-bar search field, which is what both adopters ship, what
//  `app.searchFields` in both UI suites drives, and what gives the keyboard
//  dismissal and Cancel affordance for free. Adopting `FilterInput` here would
//  replace a native control with a desktop one on both apps at once.
//
//  ## What this host deliberately does NOT do
//
//  * **It writes no selection of its own.** No landing selection, no
//    auto-advance after triage: in compact width a `NavigationSplitView` is a
//    stack, so writing a selection PUSHES the detail pane over the list the user
//    is working in (matrix ~line 271, the rule that has now bitten three times).
//    Selection is the user's move; keeping it VALID when rows leave is the app's
//    reload, because whether a vanished selection should pop the pushed editor
//    is per-app policy (impart clears, imprint keeps the open manuscript).
//  * **It is not `AnyRecordListWrapper`.** That is the MIXED-kind list — rows
//    are `KindTaggedRow`s rendered through `RecordViewerRegistry` factories,
//    with per-kind sections, double-click and Return-to-open — and the registry
//    is empty on iOS by construction, so every row would fall back to
//    `MailStyleRow`. Sharing this host's chrome with it is a follow-up; making
//    imprint's manuscript row a `MailStyleRow` is a product change.
//

import SwiftUI

/// The iOS list column for ONE record kind: list, search field, pull-to-refresh,
/// triage grammar, empty state.
///
/// Generic over the app's row VALUE (`Row`) rather than over a chassis row type,
/// because both adopters already have a display-ready snapshot of their own
/// (`ManuscriptModel`, `MessageRowData`) and a conversion layer would buy
/// nothing.
public struct RecordListHost<
    Row: Identifiable, RowContent: View, RowMenu: View, EmptyActions: View
>: View where Row.ID == UUID {

    // MARK: Rows

    /// The rows to show, already reflecting the app's own query policy.
    private let rows: [Row]
    /// True while a FIRST read is in flight; only consulted when `rows` is empty
    /// (see `RecordListPhase.resolve`).
    private let isLoading: Bool

    /// The selected row. On iPhone writing this PUSHES the detail column, which
    /// is why the host never writes it.
    @Binding private var selection: UUID?

    /// The search field's text. The host renders the field; the app decides what
    /// a query MEANS (store search vs in-memory filter).
    @Binding private var searchText: String

    // MARK: Chrome

    private let title: String
    private let searchPrompt: String
    /// Already resolved for the current query by the app — it owns the copy.
    private let emptyState: ChassisEmptyState
    /// `manuscriptRow.` / `messageRow.` — see `RecordListRowIdentity`.
    private let rowIdentifierPrefix: String
    /// The list container's own identifier, when a suite anchors on it.
    private let listIdentifier: String?

    // MARK: Triage

    private let triage: TriageCapabilities
    private let actions: RecordTriageActions
    private let rowState: (Row) -> TriageRowState
    private let rowTagPaths: (Row) -> Set<String>

    // MARK: Reload triggers
    //
    // All optional, because an adopter whose sidebar shares the same reload
    // keeps it at the split-view root: imprint's `.onChange(of:
    // adapter.dataVersion)` refreshes the sidebar counts too, so it passes only
    // `onReload` and gets pull-to-refresh. impart's list owns its own read, so
    // it passes the scope token and the version as well.

    private let scopeToken: AnyHashable?
    private let dataVersion: Int?
    private let onReload: (@MainActor () async -> Void)?

    // MARK: Builders

    private let rowContent: (Row) -> RowContent
    private let rowMenu: (Row) -> RowMenu
    private let emptyActions: () -> EmptyActions

    /// Owned by the host: the ⌘F button and the field are one affordance.
    @State private var searchPresented = false

    // MARK: - Init

    public init(
        rows: [Row],
        selection: Binding<UUID?>,
        searchText: Binding<String>,
        title: String,
        searchPrompt: String,
        emptyState: ChassisEmptyState,
        rowIdentifierPrefix: String,
        listIdentifier: String? = nil,
        isLoading: Bool = false,
        triage: TriageCapabilities,
        actions: RecordTriageActions,
        rowState: @escaping (Row) -> TriageRowState,
        rowTagPaths: @escaping (Row) -> Set<String> = { _ in [] },
        scopeToken: AnyHashable? = nil,
        dataVersion: Int? = nil,
        onReload: (@MainActor () async -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (Row) -> RowContent,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu,
        @ViewBuilder emptyActions: @escaping () -> EmptyActions
    ) {
        self.rows = rows
        self._selection = selection
        self._searchText = searchText
        self.title = title
        self.searchPrompt = searchPrompt
        self.emptyState = emptyState
        self.rowIdentifierPrefix = rowIdentifierPrefix
        self.listIdentifier = listIdentifier
        self.isLoading = isLoading
        self.triage = triage
        self.actions = actions
        self.rowState = rowState
        self.rowTagPaths = rowTagPaths
        self.scopeToken = scopeToken
        self.dataVersion = dataVersion
        self.onReload = onReload
        self.rowContent = rowContent
        self.rowMenu = rowMenu
        self.emptyActions = emptyActions
    }

    // MARK: - Body

    public var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                isPresented: $searchPresented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: searchPrompt)
            .toolbar {
                // The iOS half of the chassis's Find in List command
                // (`FindCoordinator`'s ⌘F on macOS). A touch user taps the
                // glyph; a hardware keyboard sends ⌘F. Same identifier in both
                // adopters, so one suite helper addresses both.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        searchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityIdentifier("toolbar.find")
                }
            }
            // Pull-to-refresh means whatever the app's reload means — a store
            // re-read for impart (there is no IMAP client to ask), a re-query
            // for imprint.
            .refreshable { await onReload?() }
            // A scope change is a new read. Opt-in: nil token = the app drives
            // its own (imprint's sidebar and list share one refresh).
            .task(id: scopeToken) {
                guard scopeToken != nil else { return }
                await onReload?()
            }
            .onChange(of: dataVersion) { _, newValue in
                guard newValue != nil else { return }
                Task { await onReload?() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch RecordListPhase.resolve(rowCount: rows.count, isLoading: isLoading) {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            emptyState.view(actions: emptyActions)
        case .rows:
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        let rendered = List(selection: $selection) {
            ForEach(rows) { row in
                rowContent(row)
                    .accessibilityIdentifier(
                        RecordListRowIdentity.identifier(
                            prefix: rowIdentifierPrefix, id: row.id))
                    .tag(row.id)
                    .recordTriageRow(
                        triage: triage,
                        row: rowState(row),
                        targets: [row.id],
                        actions: actions,
                        rowTagPaths: rowTagPaths(row),
                        extraMenuItems: { rowMenu(row) })
            }
        }
        .listStyle(.plain)

        if let listIdentifier {
            rendered.accessibilityIdentifier(listIdentifier)
        } else {
            rendered
        }
    }
}

// MARK: - Convenience inits

public extension RecordListHost where RowMenu == EmptyView, EmptyActions == EmptyView {
    /// No row menu beyond the shared triage grammar, and no empty-state button.
    ///
    /// The ONE convenience init, for the shape a kind with no extra verbs
    /// actually has (impart's mail column: the descriptor's triage is the whole
    /// grammar, and a create button would be dead). Anything in between passes
    /// the builders explicitly — two more overloads of a seventeen-parameter
    /// init would be more lines than they save.
    init(
        rows: [Row],
        selection: Binding<UUID?>,
        searchText: Binding<String>,
        title: String,
        searchPrompt: String,
        emptyState: ChassisEmptyState,
        rowIdentifierPrefix: String,
        listIdentifier: String? = nil,
        isLoading: Bool = false,
        triage: TriageCapabilities,
        actions: RecordTriageActions,
        rowState: @escaping (Row) -> TriageRowState,
        rowTagPaths: @escaping (Row) -> Set<String> = { _ in [] },
        scopeToken: AnyHashable? = nil,
        dataVersion: Int? = nil,
        onReload: (@MainActor () async -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (Row) -> RowContent
    ) {
        self.init(
            rows: rows,
            selection: selection,
            searchText: searchText,
            title: title,
            searchPrompt: searchPrompt,
            emptyState: emptyState,
            rowIdentifierPrefix: rowIdentifierPrefix,
            listIdentifier: listIdentifier,
            isLoading: isLoading,
            triage: triage,
            actions: actions,
            rowState: rowState,
            rowTagPaths: rowTagPaths,
            scopeToken: scopeToken,
            dataVersion: dataVersion,
            onReload: onReload,
            rowContent: rowContent,
            rowMenu: { _ in EmptyView() },
            emptyActions: { EmptyView() })
    }
}
#endif
