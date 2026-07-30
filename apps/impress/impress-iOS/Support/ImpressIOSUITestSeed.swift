//
//  ImpressIOSUITestSeed.swift
//  impress-iOS
//
//  The `--uitesting-seed` fixture: a few records of SEVERAL kinds, so the
//  mixed-kind shell has something mixed to show.
//
//  The four rules this inherits from impart's and imprint's seeds:
//
//   1. Gated on `UITestingEnvironment.shouldSeedTestData` ALONE, never on
//      `isUITesting`. `--ui-testing` redirects `RustStoreAdapter` to an
//      in-memory database, which would split the seeded rows from the store the
//      chassis readers open.
//   2. Writes the REAL app-group store, because `MailStoreReader`,
//      `FigureStoreReader` and `AgentStoreReader` all open
//      `SharedWorkspace.databasePath` unconditionally with no UI-testing
//      redirect. That path is inside the simulator's own container — this
//      never touches a developer's real store.
//   3. Idempotent: it returns early if the store already holds a seeded row,
//      and every id is deterministic, so a re-run overwrites rather than
//      duplicates.
//   4. Fixed clock, so relative dates in screenshots are stable.
//
//  RULE 5, and it is impress's own FINDING: "never hand-build payloads — use
//  the app core's own row builders" is exactly what this seed CANNOT do. Every
//  writer in the suite lives in a sibling APP's core, not in the chassis:
//  `ImpartStoreAdapter.emailMessageRow` is in MessageManagerCore, figure
//  writing is implore's, and `task@1.0.0` rows are written by impel's
//  `TaskStoreApi`. The chassis is read-only — it ships `MailStoreReader`,
//  `FigureStoreReader`, `AgentStoreReader` and no `*StoreWriter` at all. So the
//  payloads below are hand-built, and the mitigation is that every SCHEMA REF
//  is read from the kind's DESCRIPTOR (`primarySchemaRef`) rather than typed as
//  a literal — the one thing `schema-refs.json` exists to keep true. The field
//  NAMES are still a second spelling of the reader's `CodingKeys`, and that is
//  the honest cost of a chassis with no writer half.
//

import Foundation
import ImpressKit
import ImpressRustCore
import OSLog
import PublicationManagerCore

@MainActor
enum ImpressIOSUITestSeed {

    private static let logger = Logger(
        subsystem: "com.impress.impress", category: "uitesting")

    /// 2026-07-30T12:00:00Z. Fixed so "2 hours ago" is the same in every run.
    private static let seedEpoch: TimeInterval = 1_785_412_800

    // Fixture facts, spelled once. The UI suite mirrors these locally rather
    // than importing PMC into the runner.
    static let accountName = "Ada Lovelace"
    static let accountAddress = "ada@analyticalengine.org"
    static let inboxName = "INBOX"
    static let starredSubject = "Note G, revised"
    static let figureTitle = "Bernoulli convergence"
    static let taskTitle = "Recompute the Bernoulli table"
    static let taskState = "queued"

    static func seedIfRequested() {
        guard UITestingEnvironment.shouldSeedTestData else { return }
        // `ensureDirectoryExists()` FIRST, and it is load-bearing rather than
        // defensive. Every chassis reader opens the store like this, and the
        // seed runs BEFORE any of them — so on a cold install nothing has
        // created `workspace/` yet and `SharedStore.open` fails. The failure is
        // silent in the UI: the app launches, the sidebar builds from the
        // preset and every list is empty, which reads exactly like "no data
        // yet". Caught by the first cold-install UI run; kept as the reason
        // this line exists.
        try? SharedWorkspace.ensureDirectoryExists()
        guard let store = try? SharedStore.open(path: SharedWorkspace.databasePath) else {
            logger.error("seed: could not open the shared store")
            return
        }
        // Idempotence: one probe, on the kind the shell lands on.
        guard MailStoreReader.shared.fetchAccounts().isEmpty else {
            logger.info("seed: store already seeded")
            return
        }

        do {
            try seedMail(store)
            try seedFigures(store)
            try seedTasks(store)
            logger.info("seed: wrote mail + figures + tasks")
        } catch {
            logger.error("seed failed: \(error)")
        }
        ImbibImpressStore.shared.postMutation(structural: true)
    }

    // MARK: - Mail

    private static let accountID = "11111111-1111-4111-8111-111111111111"
    private static let inboxID = "22222222-2222-4222-8222-222222222222"

    private static func seedMail(_ store: SharedStore) throws {
        let messageSchema = MessageRecordKind.descriptor.primarySchemaRef
        var rows: [SharedItemUpsert] = [
            upsert(
                id: accountID, schemaRef: "mail-account",
                payload: ["name": accountName, "address": accountAddress, "sort_order": 0]),
            upsert(
                id: inboxID, schemaRef: "mail-folder", parentID: accountID,
                payload: [
                    "name": inboxName, "remote_path": "INBOX",
                    // `role: "inbox"` is load-bearing: `MessageListScope
                    // .allInboxes` fans out over INBOX-ROLE folders, and it is
                    // the scope `.all(.message)` maps to.
                    "role": "inbox", "sort_order": 0,
                ]),
        ]

        let messages: [(id: String, subject: String, body: String, offset: TimeInterval)] = [
            ("33333333-3333-4333-8333-333333333331", starredSubject,
             "The revised note is attached. The convergence proof now runs to eight terms.",
             -3_600),
            ("33333333-3333-4333-8333-333333333332", "Engine time next week",
             "Can we book the difference engine for Thursday afternoon?", -7_200),
            ("33333333-3333-4333-8333-333333333333", "Re: Note G, revised",
             "Received — I will check the eighth term against the table.", -10_800),
        ]
        for message in messages {
            rows.append(
                upsert(
                    id: message.id, schemaRef: messageSchema, parentID: inboxID,
                    payload: [
                        "subject": message.subject,
                        "body": message.body,
                        "from": accountAddress,
                        "to": ["charles@analyticalengine.org"],
                        "message_id": "<\(message.id)@analyticalengine.org>",
                    ],
                    createdMs: millis(offset: message.offset),
                    isRead: message.offset < -3_600,
                    isStarred: message.subject == starredSubject))
        }

        _ = try store.upsertItems(rows: rows)
        // Triage state through the store's own verbs, not a payload field —
        // flags and tags are ENVELOPE facts (the chassis reads them off
        // `SharedItemRow`, never out of JSON).
        try store.setFlag(id: messages[1].id, color: "red", style: nil, length: nil)
        try store.addTag(id: messages[0].id, tag: "engine/notes")
    }

    // MARK: - Figures

    private static func seedFigures(_ store: SharedStore) throws {
        let schema = FigureRecordKind.descriptor.primarySchemaRef
        // A real PNG, so the (newly cross-platform) `FigureDetailPane` View tab
        // has something to decode on iOS. Written straight into the CAS
        // directory under its own digest — `BlobStore.store(data:ext:)` is
        // `async` and this seed must complete before the first view body runs.
        var dataHash: String?
        if let png = Data(base64Encoded: Self.pngBase64) {
            let hash = BlobStore.computeSHA256(data: png)
            let root = BlobStore.defaultRootURL()
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            try? png.write(to: root.appendingPathComponent(hash))
            dataHash = hash
        }

        var figurePayload: [String: Any] = [
            "title": figureTitle,
            "caption": "Partial sums of the Bernoulli series, eight terms.",
            "format": "png",
        ]
        if let dataHash { figurePayload["data_hash"] = dataHash }

        _ = try store.upsertItems(rows: [
            upsert(
                id: "44444444-4444-4444-8444-444444444441", schemaRef: schema,
                payload: figurePayload,
                createdMs: millis(offset: -86_400), isStarred: true),
            upsert(
                id: "44444444-4444-4444-8444-444444444442", schemaRef: schema,
                payload: [
                    "title": "Engine timing (SVG)",
                    "caption": "Vector plot — no raster preview, by design.",
                    "format": "svg",
                ],
                createdMs: millis(offset: -172_800)),
        ])
    }

    // MARK: - Tasks

    private static func seedTasks(_ store: SharedStore) throws {
        let schema = TaskRecordKind.descriptor.primarySchemaRef
        _ = try store.upsertItems(rows: [
            upsert(
                id: "55555555-5555-4555-8555-555555555551", schemaRef: schema,
                payload: [
                    "title": taskTitle,
                    "state": taskState,
                    "description": "Re-run the table with the revised eighth term.",
                    "assigned_to": "counsel",
                ],
                createdMs: millis(offset: -1_800)),
            upsert(
                id: "55555555-5555-4555-8555-555555555552", schemaRef: schema,
                payload: [
                    "title": "File the revised note",
                    "state": "completed",
                    "description": "Store Note G revision 2 alongside the manuscript.",
                ],
                createdMs: millis(offset: -259_200)),
        ])
    }

    // MARK: - Helpers

    private static func millis(offset: TimeInterval) -> Int64 {
        Int64((seedEpoch + offset) * 1000)
    }

    private static func upsert(
        id: String,
        schemaRef: String,
        parentID: String? = nil,
        payload: [String: Any],
        createdMs: Int64? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil
    ) -> SharedItemUpsert {
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return SharedItemUpsert(
            // Lowercased at the boundary — the store's canonical id form
            // (imbib CLAUDE.md invariant).
            id: id.lowercased(),
            schemaRef: schemaRef,
            payloadJson: json,
            parentId: parentID?.lowercased(),
            tags: [],
            createdMs: createdMs ?? millis(offset: 0),
            isRead: isRead,
            isStarred: isStarred)
    }

    /// A 4×4 solid-blue PNG. Small enough to inline, real enough to decode.
    private static let pngBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAFUlEQVR42mNk+M/AwMDAwMDA\
        wMDAAAAoAAGm1lY3AAAAAElFTkSuQmCC
        """
}
