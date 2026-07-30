//
//  ImpartIOSUITestSeed.swift
//  impart-iOS
//
//  A fixture mailbox for a fresh simulator (Stage 5c).
//
//  impart-iOS reads mail the MAC mirrored into the shared impress workspace, and
//  a fresh simulator's app group has no such file — so there is nothing to look
//  at, in a UI test or in a screenshot, until something writes mail rows. Every
//  sibling app solved this the same way (imbib's `seedUITestDataIfNeeded`,
//  imprint's twin of it) and this is impart's, with one structural difference
//  worth writing down.
//
//  The siblings seed through their own store facade, which redirects to an
//  IN-MEMORY database under `--ui-testing`. impart cannot: `MailStoreReader`
//  (the reader the whole mail surface goes through) opens
//  `SharedWorkspace.databasePath` unconditionally, with no UI-testing redirect,
//  so an in-memory seed would be invisible to it. The seed therefore writes the
//  REAL app-group store — correct on a simulator, which is a scratch device, and
//  gated so it can never run on a build the user launched.
//
//  It is gated on `shouldSeedTestData` ALONE (`--uitesting-seed` /
//  `--ui-testing-seed`), not on `isUITesting`, and that is deliberate: passing
//  `--ui-testing` makes `RustStoreAdapter.shared` in-memory, which would put the
//  seeded rows and the star/flag WRITES in two different databases. Launching
//  with the seed flag by itself keeps reads and writes on one store, which is
//  what a screenshot pass wants; a UI test that only reads may pass both.
//
//  Two things it does NOT do:
//
//   * It does not call `MailStoreMirror.shared.mirror(rows:)`. That path enforces
//     a 90-second startup embargo (rows dispatched inside the window are buffered
//     in memory and flushed later), so a seed at launch would write nothing to
//     SQLite for a minute and a half — long past any screenshot. It uses the
//     mirror's PUBLIC `storeHandle()` and upserts directly.
//   * It does not hand-build payloads. The ids and the payload field names come
//     from `ImpartStoreAdapter`'s own `nonisolated static` row builders —
//     `accountRow`, `folderRow`, `emailMessageRow` — the same functions the Mac's
//     mirror uses, so a seeded row is byte-shaped exactly like a real one
//     (deterministic UUIDv5 ids, `parentId` pointing at the folder item,
//     `createdMs` carrying the real message date). A local JSON literal here
//     would be a second spelling of the mail schema, and the one thing worse than
//     no fixture is a fixture that does not match production.
//

import Foundation
import ImpressRustCore
import MessageManagerCore
import OSLog
import PublicationManagerCore

enum ImpartIOSUITestSeed {

    private static let logger = Logger(subsystem: "com.imbib.impart", category: "uitesting")

    static let accountAddress = "ada@example.org"
    static let accountName = "Ada Lovelace"

    /// Seed the shared store with one account, four mailboxes and nine messages,
    /// unless it already holds mail. Idempotent — the row ids are deterministic,
    /// so a re-run would upsert the same rows, but the early return keeps a
    /// relaunch from touching a store the Mac may have since populated.
    @MainActor
    static func seedIfRequested() {
        guard UITestingEnvironment.shouldSeedTestData else { return }
        guard let store = MailStoreMirror.shared.storeHandle() else {
            logger.error("UI-testing seed: no shared store handle")
            return
        }
        guard MailStoreReader.shared.fetchAccounts().isEmpty else {
            logger.info("UI-testing seed: store already has mail accounts, skipping")
            return
        }

        var rows: [MailItemUpsert] = [
            ImpartStoreAdapter.accountRow(
                email: accountAddress,
                displayName: accountName,
                provider: "imap",
                sortOrder: 0)
        ]
        for (index, folder) in Self.folders.enumerated() {
            rows.append(
                ImpartStoreAdapter.folderRow(
                    accountEmail: accountAddress,
                    name: folder.name,
                    remotePath: folder.remotePath,
                    role: folder.role,
                    sortOrder: index))
        }
        rows.append(contentsOf: Self.messages.map(\.row))

        do {
            let result = try store.upsertItems(rows: rows.map(Self.shared(_:)))
            // Flag and tag one message so the row's flag stripe and the detail
            // pane's Flag/Tags block have something to render — neither field is
            // part of `MailItemUpsert` (the mirror does not carry them, which is
            // also why they SURVIVE a re-mirror), so they are set here.
            if let flagged = Self.messages.first(where: { $0.flagColor != nil }) {
                try store.setFlag(
                    id: flagged.row.id, color: flagged.flagColor, style: nil, length: nil)
            }
            for message in Self.messages where !message.tags.isEmpty {
                for tag in message.tags {
                    try store.addTag(id: message.row.id, tag: tag)
                }
            }
            logger.info(
                "UI-testing seed: wrote \(rows.count) mail rows (inserted=\(result.inserted), updated=\(result.updated))")
        } catch {
            logger.error("UI-testing seed failed: \(error.localizedDescription)")
        }
    }

    /// `MailItemUpsert` → the FFI row. The package's own `.shared` bridge is
    /// internal, so the mapping is spelled here; both types are eight public
    /// stored properties with the same names, and `MailItemUpsert`'s doc comment
    /// calls itself a "Sendable mirror of the FFI `SharedItemUpsert` row".
    private static func shared(_ row: MailItemUpsert) -> SharedItemUpsert {
        SharedItemUpsert(
            id: row.id,
            schemaRef: row.schemaRef,
            payloadJson: row.payloadJson,
            parentId: row.parentId,
            tags: row.tags,
            createdMs: row.createdMs,
            isRead: row.isRead,
            isStarred: row.isStarred)
    }

    // MARK: - Fixture

    private struct SeedFolder {
        let name: String
        let remotePath: String
        let role: String?
    }

    /// Four mailboxes covering three declared roles plus one custom folder, so
    /// the sidebar exercises `MailSidebarSnapshot`'s role ORDER (inbox, sent,
    /// archive, then custom by sort order) and its role GLYPHS — a fixture of
    /// four INBOXes would have proved neither.
    private static let folders: [SeedFolder] = [
        SeedFolder(name: "INBOX", remotePath: "INBOX", role: "inbox"),
        SeedFolder(name: "Sent", remotePath: "INBOX.Sent", role: "sent"),
        SeedFolder(name: "Archive", remotePath: "INBOX.Archive", role: "archive"),
        SeedFolder(name: "Newsletters", remotePath: "INBOX.Newsletters", role: nil),
    ]

    private struct SeedMessage {
        let row: MailItemUpsert
        let flagColor: String?
        let tags: [String]
    }

    private static func message(
        id: String,
        subject: String,
        from: String,
        to: [String] = [accountAddress],
        cc: [String] = [],
        body: String,
        folder: SeedFolder,
        minutesAgo: Int,
        threadID: String? = nil,
        isRead: Bool = true,
        isStarred: Bool = false,
        flagColor: String? = nil,
        tags: [String] = []
    ) -> SeedMessage {
        SeedMessage(
            row: ImpartStoreAdapter.emailMessageRow(
                messageID: id,
                fallbackURI: id,
                subject: subject,
                body: body,
                from: from,
                to: to,
                cc: cc,
                threadID: threadID,
                accountEmail: accountAddress,
                folderPath: folder.remotePath,
                folderName: folder.name,
                date: Date(timeIntervalSince1970: seedEpoch - Double(minutesAgo) * 60),
                isRead: isRead,
                isStarred: isStarred),
            flagColor: flagColor,
            tags: tags)
    }

    /// A FIXED clock, not `Date()`. `MailStyleRow` renders a relative date, so a
    /// wall-clock fixture would make screenshots read "now" one run and "2 min
    /// ago" the next; pinning the epoch makes the rendered dates stable evidence.
    /// 2026-07-30 12:00:00 UTC.
    private static let seedEpoch: TimeInterval = 1_785_412_800

    private static let messages: [SeedMessage] = {
        // A three-message thread, so the list's thread collapsing (newest member
        // stands in for the thread, carrying a "(n)" badge) and the detail pane's
        // thread list both have something real to show.
        let threadID = "thread-analytical-engine"
        return [
            message(
                id: "<notes-1@example.org>",
                subject: "Notes on the Analytical Engine",
                from: "charles@example.org",
                body: """
                    Ada,

                    The engine's card sequence is nearly settled. The remaining question is \
                    whether the ordering apparatus can be driven from the same barrel.

                    Charles
                    """,
                folder: folders[0],
                minutesAgo: 2_880,
                threadID: threadID),
            message(
                id: "<notes-2@example.org>",
                subject: "Re: Notes on the Analytical Engine",
                from: accountAddress,
                to: ["charles@example.org"],
                body: """
                    It can, provided the barrel is stepped twice per cycle. I have written out \
                    the sequence for the Bernoulli numbers; see the enclosed table.
                    """,
                folder: folders[0],
                minutesAgo: 1_500,
                threadID: threadID),
            message(
                id: "<notes-3@example.org>",
                subject: "Re: Notes on the Analytical Engine",
                from: "charles@example.org",
                cc: ["luigi@example.org"],
                body: """
                    Stepped twice — of course. I have asked Menabrea to look over the table \
                    before we commit it to the memoir.
                    """,
                folder: folders[0],
                minutesAgo: 240,
                threadID: threadID,
                isRead: false,
                tags: ["engine/design"]),
            message(
                id: "<bernoulli@example.org>",
                subject: "The Bernoulli number table",
                from: "luigi@example.org",
                body: """
                    The table is correct as far as B7. Note G will need a diagram of the \
                    working variables if the reader is to follow the recurrence.
                    """,
                folder: folders[0],
                minutesAgo: 90,
                isRead: false,
                isStarred: true,
                flagColor: "red",
                tags: ["engine/design", "reading/priority"]),
            message(
                id: "<memoir@example.org>",
                subject: "Translation of Menabrea's memoir",
                from: "editor@example.org",
                body: """
                    We would be glad to print the translation with your notes appended. \
                    Please confirm the running order.
                    """,
                folder: folders[0],
                minutesAgo: 45),
            message(
                id: "<confirm@example.org>",
                subject: "Re: Translation of Menabrea's memoir",
                from: accountAddress,
                to: ["editor@example.org"],
                body: "Confirmed — notes A through G, in that order, after the translation.",
                folder: folders[1],
                minutesAgo: 30),
            message(
                id: "<weaving@example.org>",
                subject: "Jacquard cards for the pattern loom",
                from: "loom@example.org",
                body: "The punched cards arrived. The pattern repeats every 48 rows.",
                folder: folders[2],
                minutesAgo: 10_000),
            message(
                id: "<society@example.org>",
                subject: "Royal Society bulletin, August",
                from: "bulletin@example.org",
                body: "This month: on the calculus of operations, and a note on tides.",
                folder: folders[3],
                minutesAgo: 600),
            message(
                id: "<society-july@example.org>",
                subject: "Royal Society bulletin, July",
                from: "bulletin@example.org",
                body: "This month: on difference engines, and a correction to the June tables.",
                folder: folders[3],
                minutesAgo: 44_000),
        ]
    }()
}
