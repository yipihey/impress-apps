//
//  IOSMailHostView.swift
//  impart-iOS
//
//  impart's iOS shell: sidebar → message list → message detail (Stage 5c).
//
//  It replaces `IOSContentView.swift` — 380 lines of hand-written `TabView`
//  whose three tabs were, verbatim: a sidebar reading
//  `Text("No accounts configured")` under a `// TODO: Populate with accounts and
//  mailboxes`; a detail pane reading `Text("Message content will appear here")`
//  under a `// TODO: Fetch and display message content`, with four bottom-bar
//  buttons whose bodies were `// Archive`, `// Delete`, `// Reply`, `// Forward`;
//  and a settings list whose Accounts screen's `+` button body was
//  `// Add account`. Nothing in it read the shared store, because the target did
//  not link PublicationManagerCore.
//
//  Nothing here decides what the app SHOWS either. The sections come from
//  `AppShellConfiguration.impart`, the rows from `ImpartSidebarBindings`, the
//  sidebar rendering from PMC's `RecordSidebarView`, the detail pane from PMC's
//  `MessageDetailPane` (the SAME pane macOS renders — de-gated in Stage 5c), and
//  the row chrome and triage grammar from `MailStyleRow` /
//  `MessageRecordKind.descriptor`. What is left is this wiring harness.
//
//  ── WHAT ACTUALLY RUNS ON iOS ────────────────────────────────────────────────
//
//  impart-iOS is a READ-ONLY VIEWER over the shared store, and this is the
//  honest v1 rather than a shortcut. The reach was surveyed before any code was
//  written:
//
//    * READS work. `MailStoreReader` opens the app group's `impress.sqlite`
//      (`group.com.impress.suite`, already in this target's entitlements) and the
//      mail rows the Mac mirrored — `mail-account`, `mail-folder`,
//      `email-message` — are right there. Bodies are in the payload's `body`
//      field, plain text (impart's mirror writes `CDMessage.content.textBody`),
//      NOT CAS blobs, so the detail pane needs no blob fetch and no HTML
//      renderer. Remote content is blocked by construction: nothing in this
//      target renders HTML or loads a URL, and PMC is forbidden WebKit by
//      `scripts/check-chassis-deps.sh`.
//    * STAR / FLAG / TAG writes work, and are the same generic envelope ops
//      macOS's mail list performs (`RecordTriageActions.storeBacked`).
//    * READ STATE is NOT written. `SharedItemRow.isRead` is mirrored FROM
//      impart's Core Data, so the Mac is the authority; a store-only write here
//      would be reverted by the next mirror pass, which is the exact fight to
//      avoid. So no `RecordHostVerbs.onSelect` is registered and a message read
//      on the phone keeps its unread dot.
//    * COMPOSE / SEND does not exist. Not "not wired on iOS" — not anywhere:
//      `MessageManagerCore.RustMailProvider` is a stub whose `send(_:)` comment
//      is `// Pretend to send` and whose `fetchMessages` returns `[]`, and
//      `ImpartRustCore` is a placeholder package with no Rust in it. The deleted
//      shell's Compose tab had `// TODO: Send message` where the send belonged.
//      So no `onCreate` verb is registered either, which makes the chassis omit
//      the `n` key and the empty-state button rather than offer dead ones.
//    * IMAP SYNC does not exist on either platform, and nothing polls: there is
//      no timer, no `BGTaskScheduler`, no scheduler anywhere in
//      MessageManagerCore. So this target starts no sync loop — there is none to
//      start — and its refresh gesture re-reads the store rather than pretending
//      to fetch.
//
//  That is why there is no `ImpartMailHost` twin of the macOS file here: both
//  verbs macOS supplies through `RecordHostVerbs` are verbs iOS cannot perform.
//

import ImpressKit
import PublicationManagerCore
import SwiftUI

struct IOSMailHostView: View {

    // MARK: - Navigation state

    /// The sidebar's selection, in chassis vocabulary.
    @State private var scope: RecordSidebarScope?
    /// The message the detail column shows.
    @State private var selectedMessageID: UUID?
    /// Which detail tab. Seeded from the shell preset rather than a literal, so
    /// impart lands where its declaration says (Info).
    @State private var selectedTab: DetailTab = AppShellConfiguration.impart.defaultDetailTab
    /// `.all` so iPad opens on sidebar + list + detail; iPhone collapses it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - Data state

    @State private var snapshot = ImpartMailSidebarSnapshot()
    /// Bumped by anything that changes the rows without going through the imbib
    /// store facade — the pull-to-refresh gesture, and the launch read.
    @State private var revision = 0
    @State private var showSettings = false

    /// Compact width is a STACK, so writing a selection there pushes the list
    /// over the sidebar the user just launched into — the landing seed below is
    /// regular-width only, the same rule `RecordSidebarView` applies.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The generic store facade the shared triage ops write through. Read here in
    /// `body` (not inside a closure) so SwiftUI registers observation: a star or
    /// flag applied in the list has to reload the sidebar badges too.
    private var storeAdapter: RustStoreAdapter { RustStoreAdapter.shared }

    /// The rebuild trigger. The store version alone is not enough — a
    /// pull-to-refresh changes the rows (the Mac may have mirrored more mail into
    /// the app group while this app was backgrounded) without any in-process
    /// mutation.
    private var dataVersion: Int {
        storeAdapter.dataVersion &* 1_000 &+ revision
    }

    private var listScope: MessageListScope? {
        ImpartSidebarBindings.listScope(for: scope)
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } content: {
            listColumn
        } detail: {
            detailColumn
        }
        .task { refresh() }
        // Settings is presented at the navigation ROOT, not inside a column: a
        // sheet raised from a column is dismissed by that column's own
        // navigation when the split view collapses on iPhone (the lesson
        // imprint-iOS's citation sheet paid for).
        .sheet(isPresented: $showSettings) {
            IOSSettingsScreen(configuration: .impart) {
                showSettings = false
            }
            .environment(\.settingsSectionRegistry, ImpartIOSSettingsSections.registry)
        }
        .onOpenURL { url in handle(url) }
    }

    // MARK: - Sidebar column

    private var sidebarColumn: some View {
        RecordSidebarView(
            configuration: ImpartSidebarBindings.configuration,
            dataSource: ImpartSidebarBindings.dataSource(
                snapshot: snapshot, version: dataVersion),
            // No `RecordCollectionActions`: mail folders are server mailboxes,
            // IMAP owns their lifecycle, and the message descriptor declares no
            // collection binding. The default bag has `canOrganize: false`, so
            // the shared organise grammar is off by declaration.
            dataVersion: dataVersion,
            selection: $scope,
            title: "impart")
        .refreshable { refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("toolbar.settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Re-READ, not re-fetch. There is no IMAP client to ask (see the
                // file header), so this refreshes what the shared store holds —
                // which is exactly what changes when the Mac mirrors new mail.
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload from shared store")
                .accessibilityIdentifier("toolbar.reload")
            }
        }
    }

    // MARK: - List column

    @ViewBuilder
    private var listColumn: some View {
        if let listScope {
            IOSMessageListColumn(
                scope: listScope,
                title: scopeTitle,
                selectedID: $selectedMessageID,
                actions: ImpartSidebarBindings.triageActions(),
                dataVersion: dataVersion)
            // The `.id(scope)` rule (imbib CLAUDE.md "Sidebar Selection
            // Patterns"): a view that takes a route as a `let` inside a
            // NavigationSplitView column must be recreated when the route
            // changes, or the closure caching leaves the old scope's rows on
            // screen. `.task(id: scope)` inside the column covers the reload;
            // this covers the identity.
            .id(listScope)
        } else {
            ContentUnavailableView(
                "No Mailbox Selected",
                systemImage: "tray.2",
                description: Text("Choose a mailbox in the sidebar."))
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let selectedMessageID {
            // THE chassis pane, not an iOS copy of it: Info (headers, thread
            // membership, related items, flag and tags), Source (raw body,
            // monospaced) and View (the body typeset at a reading measure), all
            // from `MessageRecordKind.descriptor.detailTabs`.
            //
            // `topInset: 0` — the macOS section host passes 40 to clear the
            // toolbar band it reclaims with `.ignoresSafeArea(.top)`; iOS has a
            // navigation bar instead and needs no clearance.
            MessageDetailPane(
                messageID: selectedMessageID,
                selectedTab: $selectedTab,
                topInset: 0)
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("messageDetail")
        } else {
            ContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope",
                description: Text("Choose a message to read it."))
        }
    }

    // MARK: - Titles

    /// The selected row's own name. The sidebar knows it; `MessageListScope`
    /// cannot (its `.folder`/`.account` cases carry only an id).
    private var scopeTitle: String {
        switch listScope {
        case .allInboxes:
            return MailSidebarSnapshot.allInboxesTitle
        case .account(let id):
            return snapshot.tree.accounts.first { $0.id == id }?.name ?? "Account"
        case .folder(let id):
            return snapshot.tree.accounts
                .flatMap(\.folders)
                .first { $0.id == id }?.name ?? "Mailbox"
        case .flagged(let color):
            return color.map { "\($0.displayName) Flag" } ?? "Flagged"
        // The LEAF, matching the sidebar row the user came from: the full path
        // is that row's identity, and its ancestors are the rows above it.
        case .tag(let path):
            return path.split(separator: "/").last.map(String.init) ?? path
        case nil:
            return "Mail"
        }
    }

    // MARK: - Refresh

    private func refresh() {
        // Force past the version memo: the store may have changed out of process
        // (the Mac's mirror writes the same SQLite file) with no in-process
        // mutation to bump `RustStoreAdapter.dataVersion`.
        snapshot.refresh(version: dataVersion, force: true)
        revision += 1
        if scope == nil, horizontalSizeClass != .compact {
            scope = ImpartSidebarBindings.landingScope
        }
    }

    // MARK: - URL scheme

    /// `impart://message?id=<store item id>` selects a message.
    ///
    /// `impart://compose` is deliberately unhandled here: the deleted shell
    /// answered it with a form whose Send button body was `// TODO: Send
    /// message`, and there is no SMTP path in this target (or any other — see the
    /// file header). Logging the refusal beats presenting a composer that cannot
    /// send.
    private func handle(_ url: URL) {
        guard let parsed = ImpressURL.parse(url), parsed.app == .impart else { return }
        switch parsed.action {
        case "message":
            guard let raw = parsed.parameters["id"], let id = UUID(uuidString: raw) else { return }
            // Only select a message this device can actually read, so a stale
            // deep link leaves the pane where it is instead of blanking it.
            guard MailStoreReader.shared.fetchMessage(id: raw) != nil else { return }
            selectedMessageID = id
        default:
            break
        }
    }
}
