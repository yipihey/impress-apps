//
//  ImpartSidebarBindings.swift
//  impart-iOS
//
//  The ENTIRE app-specific surface of impart's iOS sidebar (Stage 5c).
//
//  It is the third of these files — after `IOSManuscriptSidebarBindings`
//  (imprint) and `ImbibSidebarBindings` (imbib) — and by far the smallest,
//  because everything it would otherwise have had to say is already declared
//  somewhere:
//
//    * WHICH SECTIONS exist: `AppShellConfiguration.impart` (`[.mail]`).
//    * WHAT MAIL CAN DO: `MessageRecordKind.descriptor` — star/flag/tag yes,
//      dismissal `.none`, deletion `.none`, no status lifecycle. So there is no
//      Dismissed section and no Flagged section to build here; the preset does
//      not permit them and the descriptor would emit no rows for them anyway.
//      (Flagged mail on iOS therefore needs a preset change — `.flagged` plus a
//      `.flagged: .message` binding — exactly as macOS does. Not invented here.)
//    * WHICH ROWS the Mail section has: `MailSidebarSnapshot` (PMC,
//      cross-platform since Stage 5c) — All Inboxes, one row per `mail-account`,
//      each account's `mail-folder` children in role order with the role's glyph
//      and a message count. macOS's sidebar maps the same snapshot.
//    * WHAT A ROW SELECTS: `MessageListScope(routeScope:)` (PMC) already
//      translates `RecordSidebarScope` → the mail list scope, including the
//      account escape hatch (`MessageListScope.accountRouteScope`). There is no
//      route enum in this file because impart does not need one: unlike imbib,
//      every mail row IS expressible in the chassis vocabulary.
//
//  What is left is a data source over `MailStoreReader` — which is why this file
//  is ~120 lines against the 380-line hand-written TabView it replaces, and why
//  the replaced shell's sidebar showed the literal string "No accounts
//  configured" with a `// TODO: Populate with accounts and mailboxes` above it.
//
//  READ-ONLY, deliberately. `RecordHostVerbs` is NOT injected on iOS, and that
//  is a decision rather than an omission — see `IOSMailHostView`'s header for
//  the two verbs macOS registers (compose, mark-read-on-select) and why neither
//  can be honoured from this target.
//

import Foundation
import PublicationManagerCore

// MARK: - Store snapshot

/// One store read pass per version, shared by every row.
///
/// `RecordSidebarBuilder` asks for the section's rows, then a count per row, on
/// every rebuild. Answering each from its own query would be a fan of FFI
/// round-trips per rebuild; this is imprint's `ManuscriptSidebarCounts` and
/// imbib's `ImbibSidebarSnapshot` with impart's one read
/// (`MailSidebarSnapshot.load()`), invalidated by the version the host observes.
@MainActor
final class ImpartMailSidebarSnapshot {

    private var version: Int = .min
    private(set) var tree: MailSidebarSnapshot = .empty

    /// Counts keyed by folder store id, flattened out of the tree so a badge
    /// lookup is not a nested search.
    private(set) var folderCounts: [UUID: Int] = [:]

    /// No-op once `version` matches, so a whole sidebar rebuild costs one read
    /// however many times the builder asks. (The alternative is ordering the
    /// host's refresh against `RecordSidebarView`'s own `.task { rebuild() }`,
    /// which SwiftUI does not promise — the same trap imbib documented.)
    func refresh(version newVersion: Int, force: Bool = false) {
        guard force || version != newVersion else { return }
        version = newVersion
        tree = MailSidebarSnapshot.load()
        folderCounts = Dictionary(
            uniqueKeysWithValues: tree.accounts
                .flatMap(\.folders)
                .map { ($0.id, $0.messageCount) })
    }
}

// MARK: - Bindings

@MainActor
enum ImpartSidebarBindings {

    /// impart's declarative identity on iOS.
    ///
    /// `.presenting([.message])` is this HOST's capability statement. The
    /// `.impart` preset registers four kinds (publication, manuscript, artifact,
    /// message) because the shell CONFIG is shared with macOS, where the same
    /// chassis can in principle render them; impart-iOS has exactly one record
    /// surface, the mail list, so naming the kind drops any section bound to
    /// another one without a section-name literal here.
    ///
    /// Note what is deliberately NOT added: `withCustomSurfaces(_:)`. macOS
    /// registers Chat / Category / Research / Development as app-owned surfaces
    /// over view models that read `InboxViewModel`, and `InboxViewModel.accounts`
    /// is assigned nowhere in MessageManagerCore — those surfaces are empty on
    /// macOS too. Registering four empty panes on a phone would be four dead
    /// rows in the sidebar.
    static var configuration: AppShellConfiguration {
        .impart.presenting([.message])
    }

    static var descriptor: RecordKindDescriptor { MessageRecordKind.descriptor }

    /// The list scope a sidebar selection means, in PMC's own vocabulary. nil =
    /// a row this shell has no list for (it emits none, so this is defensive).
    static func listScope(for scope: RecordSidebarScope?) -> MessageListScope? {
        scope.flatMap(MessageListScope.init(routeScope:))
    }

    /// Where the shell lands with no selection: the first row of the preset's
    /// `defaultSection`, which for `.mail` is All Inboxes.
    ///
    /// `RecordSidebarView` seeds this itself — but only from its own `body`, and
    /// on iPad in PORTRAIT the sidebar column is presented as an overlay that
    /// SwiftUI does not evaluate until the user reveals it. The app then launched
    /// showing "No Mailbox Selected" beside "No Message Selected" with a full
    /// mailbox behind the toggle. macOS has always seeded its side explicitly
    /// (`ImbibSidebarViewModel` sets `.mailAllInboxes` when the shell's
    /// `defaultSection` is `.mail`); the host doing the same is what makes the
    /// landing route independent of whether a column has been laid out yet.
    static let landingScope: RecordSidebarScope = .all(.message)

    // MARK: Data source

    static func dataSource(
        snapshot: ImpartMailSidebarSnapshot,
        version: Int
    ) -> RecordSidebarDataSource {
        let sync = { snapshot.refresh(version: version) }
        return RecordSidebarDataSource(
            // The message descriptor declares NO `CollectionCapability`, and
            // that is correct: a mail folder is a server mailbox, not a user
            // folder, so it must not acquire the organise grammar (rename /
            // new subfolder / reparent / delete). Mail's folders arrive as
            // host-resolved rows below instead.
            folders: { _ in [] },
            folderCounts: { _, ids in ids.map { _ in 0 } },
            count: { scope in
                sync()
                switch scope {
                case .all(.message):
                    return snapshot.tree.allInboxesCount
                case .folder(.message, let id):
                    return snapshot.folderCounts[id]
                default:
                    // No `.tag` badge: a count per tag row is one scan per row
                    // over the message table.
                    return nil
                }
            },
            tags: { kind in
                // The kind's OWN rows, memoised on this host's version by the
                // chassis (`RecordTagVocabulary`) — impart has no tag-definition
                // table to read, so the vocabulary is what its messages carry.
                guard kind == descriptor.id else { return [] }
                return RecordTagVocabulary.inUse(kind, version: version)
            },
            sectionIsAvailable: { section in
                // The CONTENT gate. Mail is available unconditionally: it is the
                // shell's `defaultSection` and its only one, so hiding it while
                // the store is empty would leave `RecordSidebarView` with no
                // landing route and the app with no navigable surface at all.
                // The empty case is handled where it belongs — the list's empty
                // state, which says the mirror has not run yet.
                //
                // Tags is the second section this shell shows, and it IS gated
                // on content: unlike Mail it is not a landing route, and a Tags
                // section with nothing under it promises browsing it cannot do.
                if section == .tags {
                    return !RecordTagVocabulary.inUse(descriptor.id, version: version).isEmpty
                }
                return section == .mail
            },
            sectionContent: { section, _ in
                sync()
                guard section == .mail else { return nil }
                return RecordSidebarSectionContent(
                    nodes: nodes(snapshot.tree),
                    // No selectable header: "Mail" names the section, and the
                    // destination the header would mean (All Inboxes) is already
                    // the first row. macOS's sidebar makes the same call.
                    headerScope: nil,
                    canOrganizeFolders: false,
                    offersRootFolderCreation: false)
            })
    }

    // MARK: Section rows

    /// The Mail section, from the shared snapshot. Every title, glyph, order and
    /// count in here comes from `MailSidebarSnapshot`; this only chooses the
    /// chassis SCOPE each row selects.
    private static func nodes(_ tree: MailSidebarSnapshot) -> [RecordSidebarNode] {
        var nodes: [RecordSidebarNode] = [
            RecordSidebarNode(
                scope: .all(.message),
                title: MailSidebarSnapshot.allInboxesTitle,
                systemImage: MailSidebarSnapshot.allInboxesSystemImage,
                count: tree.allInboxesCount > 0 ? tree.allInboxesCount : nil)
        ]
        for account in tree.accounts {
            nodes.append(
                RecordSidebarNode(
                    // Accounts own folders rather than records, so `.folder`
                    // would be the wrong word — this is the declared host escape
                    // hatch, with the key single-sourced in PMC and read back by
                    // `MessageListScope(routeScope:)`.
                    scope: MessageListScope.accountRouteScope(account.id),
                    title: account.name,
                    systemImage: "person.crop.circle",
                    children: account.folders.map { folder in
                        RecordSidebarNode(
                            scope: .folder(.message, folder.id),
                            title: folder.name,
                            systemImage: folder.systemImage,
                            count: folder.messageCount > 0 ? folder.messageCount : nil,
                            // NOT a user folder: `isFolder: false` is what keeps
                            // the shared organise verbs off a server mailbox.
                            isFolder: false)
                    },
                    isFolder: false))
        }
        return nodes
    }

    // MARK: Triage actions

    /// The store-backed triage defaults — the WHOLE action surface for mail,
    /// exactly as macOS's `MessageSectionView.makeActions()` has it.
    ///
    /// Star / flag / tag are generic envelope ops on the shared store row, so
    /// they work identically from either platform. Everything else the grammar
    /// could offer is absent BY DECLARATION rather than by omission here:
    /// `dismissal: .none` and `deletion: .none` mean `TriageSwipe` / `TriageMenu`
    /// emit no dismiss, archive or delete item, and `d` is ignored — because
    /// moving or deleting mail is an IMAP operation, not a store write.
    ///
    /// One iOS-specific honesty note, which is the same one macOS's mark-read
    /// handling turns on: `isRead` is MIRRORED from impart's Core Data, so the
    /// store is a replica for that field and iOS has no authority over it. There
    /// is no `onSelect` verb registered in this target (see `IOSMailHostView`),
    /// so a message read on the phone keeps its unread dot rather than writing a
    /// flag the Mac's next mirror pass would revert.
    static func triageActions() -> RecordTriageActions {
        RecordTriageActions.storeBacked(descriptor: descriptor)
    }
}
