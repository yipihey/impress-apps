// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the mail sidebar's
// ACCOUNT/FOLDER TREE as value types. No view, no AppKit.
//
//  MailSidebarSnapshot.swift
//  PublicationManagerCore
//
//  ADDITIVE (Stage 5c, flagged). "What does the Mail section contain" —
//  All Inboxes, one node per `mail-account`, each account's `mail-folder`
//  children in ROLE order with the role's glyph and a message count — lived
//  inside `ImbibSidebarViewModel.mailChildren()`, which is macOS-gated. It also
//  needed `MailStoreReader.accountPayload(from:)` / `.folderPayload(from:)`,
//  which are internal to this module, so an app-target iOS sidebar could not
//  reach them at all.
//
//  impart-iOS needs the same tree. Re-encoding the role order, the six folder
//  glyphs and the "All Inboxes" fan-out in app code is precisely the second
//  truth table ADR-0021 exists to prevent (imbib-iOS's deleted sidebar was the
//  cautionary tale), so the tree became data instead: this file answers the
//  question once, and each platform maps the answer onto its own node type —
//  macOS onto `ImbibSidebarNode`, iOS onto `RecordSidebarNode`.
//
//  READ-ONLY, like `MailStoreReader`: IMAP owns account and folder lifecycle,
//  so there is nothing to write here and no organise verbs to declare.
//

import Foundation
import ImpressRustCore

/// One `mail-folder` row, display-resolved.
public struct MailFolderNode: Identifiable, Hashable, Sendable {
    /// Store item id (a deterministic UUIDv5 — see `DeterministicID`).
    public let id: UUID
    public let name: String
    /// `inbox | sent | drafts | trash | archive | spam`; nil for custom folders.
    public let role: String?
    /// Messages parented to this folder.
    public let messageCount: Int

    /// The role's glyph, from the ONE mapping (see `MailSidebarSnapshot`).
    public var systemImage: String { MailSidebarSnapshot.folderIcon(role: role) }

    /// The lowercase store-id spelling the reader and macOS node ids use.
    public var storeID: String { id.uuidString.lowercased() }

    public init(id: UUID, name: String, role: String?, messageCount: Int) {
        self.id = id
        self.name = name
        self.role = role
        self.messageCount = messageCount
    }
}

/// One `mail-account` row with its folders, in role order.
public struct MailAccountNode: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Payload `name`, falling back to `address`, falling back to "Account" —
    /// the same fallback chain `mailChildren()` has always applied.
    public let name: String
    public let address: String?
    public let folders: [MailFolderNode]

    public var storeID: String { id.uuidString.lowercased() }

    public init(id: UUID, name: String, address: String?, folders: [MailFolderNode]) {
        self.id = id
        self.name = name
        self.address = address
        self.folders = folders
    }
}

/// The Mail section's tree, read once from the shared store.
public struct MailSidebarSnapshot: Hashable, Sendable {

    public let accounts: [MailAccountNode]
    /// Total messages across every inbox-role folder — the "All Inboxes" badge.
    public let allInboxesCount: Int

    public init(accounts: [MailAccountNode], allInboxesCount: Int) {
        self.accounts = accounts
        self.allInboxesCount = allInboxesCount
    }

    public static let empty = MailSidebarSnapshot(accounts: [], allInboxesCount: 0)

    /// The row every mail shell shows first. Spelled here so the two sidebars
    /// cannot disagree about its title or glyph (the `.mail` section's own
    /// `displayName` is "Mail", which names the SECTION, not this destination —
    /// `MessageListScope.allInboxes.title` is the same string as this).
    public static let allInboxesTitle = "All Inboxes"
    public static let allInboxesSystemImage = "tray.2"

    /// One store read pass: accounts, each account's folders, and a count per
    /// folder. Cheap at Stage-2 scale (every query is an indexed
    /// `schemaRef`+`parentId` lookup); hosts memoise it against their store
    /// version rather than calling it per row.
    @MainActor
    public static func load(reader: MailStoreReader = .shared) -> MailSidebarSnapshot {
        let inboxes = reader.fetchInboxFolders()
        let allInboxesCount = inboxes.reduce(0) { $0 + reader.messageCount(inFolder: $1.id) }

        var accounts: [MailAccountNode] = []
        for row in reader.fetchAccounts() {
            // A store item id is a UUID string by construction; a row that is
            // not one is unreadable rather than renderable, exactly as
            // `MessageRowData.init?` treats it.
            guard let id = UUID(uuidString: row.id) else { continue }
            let payload = MailStoreReader.accountPayload(from: row)
            let folders = roleSorted(reader.fetchFolders(accountID: row.id))
                .compactMap { folderRow -> MailFolderNode? in
                    guard let folderID = UUID(uuidString: folderRow.id) else { return nil }
                    let folderPayload = MailStoreReader.folderPayload(from: folderRow)
                    return MailFolderNode(
                        id: folderID,
                        name: folderPayload?.name ?? "Folder",
                        role: folderPayload?.role,
                        messageCount: reader.messageCount(inFolder: folderRow.id))
                }
            accounts.append(
                MailAccountNode(
                    id: id,
                    name: payload?.name ?? payload?.address ?? "Account",
                    address: payload?.address,
                    folders: folders))
        }
        return MailSidebarSnapshot(accounts: accounts, allInboxesCount: allInboxesCount)
    }

    // MARK: - Ordering + glyphs (moved verbatim from ImbibSidebarViewModel)

    /// Role-ordered folder sort: inbox/drafts/sent/archive/trash/spam first,
    /// then custom folders by payload sort_order, then name.
    static func roleSorted(_ folders: [SharedItemRow]) -> [SharedItemRow] {
        let roleOrder: [String: Int] = [
            "inbox": 0, "drafts": 1, "sent": 2, "archive": 3, "trash": 4, "spam": 5,
        ]
        struct Sortable {
            let row: SharedItemRow
            let roleRank: Int
            let sortOrder: Int
            let name: String
        }
        return folders.map { row -> Sortable in
            let payload = MailStoreReader.folderPayload(from: row)
            return Sortable(
                row: row,
                roleRank: payload?.role.flatMap { roleOrder[$0] } ?? 100,
                sortOrder: payload?.sortOrder ?? 0,
                name: payload?.name ?? "")
        }
        .sorted { ($0.roleRank, $0.sortOrder, $0.name) < ($1.roleRank, $1.sortOrder, $1.name) }
        .map(\.row)
    }

    /// The glyph for a folder role. The ONE mapping: macOS's sidebar and
    /// impart-iOS's both resolve through it, so Sent cannot be a paperplane in
    /// one shell and a folder in the other.
    public static func folderIcon(role: String?) -> String {
        switch role {
        case "inbox": return "tray"
        case "sent": return "paperplane"
        case "drafts": return "doc"
        case "trash": return "trash"
        case "archive": return "archivebox"
        case "spam": return "xmark.bin"
        default: return "folder"
        }
    }
}
