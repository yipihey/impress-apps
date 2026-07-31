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
//  RULE 5, and it was impress's own FINDING — now CLOSED (ADR-0022 X2).
//
//  It used to read: "never hand-build payloads" is exactly what this seed
//  CANNOT do for three of its five kinds, because every mail/figure/task writer
//  in the suite lives in a sibling APP's core (`ImpartStoreAdapter
//  .emailMessageRow` in MessageManagerCore, figures in implore, `task@1.0.0` in
//  impel's `TaskStoreApi`) and the chassis shipped `MailStoreReader`,
//  `FigureStoreReader`, `AgentStoreReader` and no `*StoreWriter` at all. So the
//  payloads below were hand-built, and the only mitigation available was to
//  read every SCHEMA REF from the kind's DESCRIPTOR — which left the field
//  NAMES (`subject`, `remote_path`, `sort_order`, `data_hash`, `assigned_to`, …)
//  as a second spelling of the readers' `CodingKeys` that nothing compared.
//
//  The chassis now has the WRITER half of its own vocabulary: `MailStoreWriter`,
//  `FigureStoreWriter` and `AgentStoreWriter` sit next to their readers and
//  build rows by ENCODING the readers' own payload structs. Not a store writer —
//  they open nothing and mutate nothing, and the real writers stay in the owning
//  apps' cores where mail lifecycle and task transitions belong. What they are
//  is the one place the field names are spelled, so this file no longer spells
//  any of them. `ChassisPayloadVocabularyTests` pins reader keys == writer keys.
//
//  RULE 6, found by running the suite lanes back to back on ONE simulator: this
//  seed writes the APP-GROUP store, and a simulator's app-group container is
//  SHARED BY EVERY APP IN THE GROUP. So after this suite runs, impart-iOS's own
//  suite opens a store that already holds impress's one mail account, one INBOX
//  folder and three messages — and impart's seed is idempotence-guarded on
//  exactly that probe, so it declines to write its own four mailboxes and its
//  suite fails looking for them. Nothing is wrong with either seed; they are
//  two writers of one store on a shared device. **Run each app's iOS UI lane on
//  its own simulator, or erase the group container between lanes.**
//  `scripts/run-ui-tests-isolated.sh` already runs one app at a time.
//
//  (The same sweep found a second, unrelated lane hazard worth knowing about
//  here: imprint's and impart's suites pin `.landscapeLeft` and are therefore
//  iPad suites — they fail on an iPhone for lack of list HEIGHT, from the same
//  commit that passes on an iPad. impress's and imbib's pin `.portrait` and are
//  iPhone suites. See docs/chassis-capability-matrix.md.)
//
//  PUBLICATIONS AND MANUSCRIPTS (I2) DO NOT PAY THAT COST, and the difference
//  is the point. imbib's writers are IN the chassis, so those two kinds are
//  seeded through the real ones — `RustStoreAdapter.createLibrary` +
//  `importBibTeX` (the same BibTeX parser imbib's importer runs) and
//  `RustStoreAdapter.createManuscript` (what imprint's New Manuscript calls).
//  Nothing below spells `imbib/bibliography-entry` or `manuscript`, or invents
//  a field name: the writer owns the shape. That is what the seeding convention
//  asks for, and it is available for exactly the kinds whose writer half was
//  never missing.
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
    static let libraryName = "Engine Papers"
    static let collectionName = "Note G"
    /// A fragment of the first paper's title — what the suite anchors on,
    /// because `MailStylePublicationRow` exposes no per-row identifier. Chosen
    /// so it appears on exactly ONE element: it is not a substring of the
    /// library name, the collection name or the second paper's title, and an
    /// XCUITest `CONTAINS` predicate that matches two elements taps neither.
    static let publicationTitleFragment = "Notes on the Analytical Engine"
    static let secondPublicationTitleFragment = "On the Bernoulli Numbers"
    static let manuscriptTitle = "On the Note G Correction"
    /// A markdown manuscript, so the read-only pane's Preview tab has a format
    /// it can actually render without a compiler.
    static let manuscriptFormat = "markdown"

    static func seedIfRequested() {
        guard UITestingEnvironment.shouldSeedTestData else { return }
        // UI STATE IS FIXTURE TOO, and it is reset BEFORE the idempotence guard
        // below because it is not part of what that guard is protecting.
        //
        // The composed sidebar (I3) persists which app groups and which
        // per-group sections are collapsed, in `UserDefaults.standard` inside
        // the simulator's container — which SURVIVES an app relaunch, so a test
        // that collapses the imprint group leaves every later test in this
        // suite starting from a sidebar with imprint closed. That is the same
        // class of cross-test leak the fixed `seedEpoch` exists to prevent for
        // dates: "the state the run starts in" must be chosen, not inherited.
        UserDefaults.standard.removeObject(forKey: "sidebarCompositionCollapsed")
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
        // Publications and manuscripts go through imbib's own writers, which
        // are `RustStoreAdapter`'s and therefore in the chassis. They open the
        // SAME `SharedWorkspace.databasePath` the block above wrote to (one
        // `impress.sqlite`, ADR-023), so this is not a second store — it is the
        // same store reached through a writer that exists.
        seedPublications()
        seedManuscripts(store)
        ImbibImpressStore.shared.postMutation(structural: true)
    }

    // MARK: - Mail

    private static let accountID = "11111111-1111-4111-8111-111111111111"
    private static let inboxID = "22222222-2222-4222-8222-222222222222"

    private static func seedMail(_ store: SharedStore) throws {
        var rows: [SharedItemUpsert] = [
            // `createdMs` explicit on both container rows: the retired local
            // helper defaulted it to `millis(offset: 0)`, and rule 4 (fixed
            // clock) is why. The chassis builder does not guess a date.
            MailStoreWriter.accountRow(
                id: accountID, name: accountName, address: accountAddress,
                sortOrder: 0, createdMs: millis(offset: 0)),
            MailStoreWriter.folderRow(
                id: inboxID, accountID: accountID, name: inboxName,
                // `role: "inbox"` is load-bearing: `MessageListScope
                // .allInboxes` fans out over INBOX-ROLE folders, and it is
                // the scope `.all(.message)` maps to.
                role: "inbox", remotePath: "INBOX", sortOrder: 0,
                createdMs: millis(offset: 0)),
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
                MailStoreWriter.messageRow(
                    id: message.id, folderID: inboxID,
                    subject: message.subject,
                    body: message.body,
                    from: accountAddress,
                    to: ["charles@analyticalengine.org"],
                    messageID: "<\(message.id)@analyticalengine.org>",
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

        _ = try store.upsertItems(rows: [
            FigureStoreWriter.figureRow(
                id: "44444444-4444-4444-8444-444444444441",
                title: figureTitle,
                caption: "Partial sums of the Bernoulli series, eight terms.",
                format: "png",
                // nil when the PNG failed to decode — the builder OMITS the key
                // rather than writing a null, which is the shape a figure with
                // no raster preview genuinely has.
                dataHash: dataHash,
                createdMs: millis(offset: -86_400), isStarred: true),
            FigureStoreWriter.figureRow(
                id: "44444444-4444-4444-8444-444444444442",
                title: "Engine timing (SVG)",
                caption: "Vector plot — no raster preview, by design.",
                format: "svg",
                createdMs: millis(offset: -172_800)),
        ])
    }

    // MARK: - Tasks

    private static func seedTasks(_ store: SharedStore) throws {
        _ = try store.upsertItems(rows: [
            AgentStoreWriter.taskRow(
                id: "55555555-5555-4555-8555-555555555551",
                title: taskTitle,
                state: taskState,
                description: "Re-run the table with the revised eighth term.",
                assignedTo: "counsel",
                createdMs: millis(offset: -1_800)),
            AgentStoreWriter.taskRow(
                id: "55555555-5555-4555-8555-555555555552",
                title: "File the revised note",
                state: "completed",
                description: "Store Note G revision 2 alongside the manuscript.",
                createdMs: millis(offset: -259_200)),
        ])
    }

    // MARK: - Publications (through imbib's real writers)

    private static func seedPublications() {
        let store = RustStoreAdapter.shared
        guard store.listLibraries().isEmpty else {
            logger.info("seed: libraries already present")
            return
        }
        guard let library = store.createLibrary(name: libraryName) else {
            logger.error("seed: createLibrary failed")
            return
        }
        // The BibTeX parser imbib's importer runs. Two entries, one flagged and
        // one starred through the store's own triage verbs — the same route the
        // mail rows take, for the same reason (flags are envelope facts).
        let ids = store.importBibTeX(
            """
            @article{Lovelace1843Analytical,
              author = {Lovelace, Augusta Ada},
              title = {Notes on the Analytical Engine},
              journal = {Scientific Memoirs},
              year = {1843},
              volume = {3},
              pages = {666--731},
              doi = {10.1000/notes.g}
            }

            @article{Bernoulli1713Ars,
              author = {Bernoulli, Jacob},
              title = {On the Bernoulli Numbers},
              journal = {Ars Conjectandi},
              year = {1713},
              pages = {97--98}
            }
            """,
            libraryId: library.id)
        guard !ids.isEmpty else {
            logger.error("seed: importBibTeX imported nothing")
            return
        }
        store.setStarred(ids: [ids[0]], starred: true)
        store.setFlag(ids: [ids[0]], color: "red")
        if let collection = store.createCollection(
            name: collectionName, libraryId: library.id) {
            store.addToCollection(publicationIds: [ids[0]], collectionId: collection.id)
        }

        // The Inbox SECTION resolves to the inbox LIBRARY, and a store with no
        // inbox library has no Inbox section at all (`RecordSidebarBuilder`
        // drops a section whose host nodes are empty). imbib creates it lazily
        // in `InboxManager`; impress never writes one, so the fixture does —
        // through the same `createInboxLibrary` verb, with one paper in it so
        // the section has both a row and a badge.
        if let inbox = store.createInboxLibrary(name: "Inbox") {
            _ = store.importBibTeX(
                """
                @article{Menabrea1842Sketch,
                  author = {Menabrea, Luigi Federico},
                  title = {Sketch of the Analytical Engine},
                  journal = {Biblioth\\`eque Universelle de Gen\\`eve},
                  year = {1842}
                }
                """,
                libraryId: inbox.id)
        }
        logger.info("seed: wrote \(ids.count) publications into \(libraryName)")
    }

    // MARK: - Manuscripts (through imbib's real writer)

    private static func seedManuscripts(_ shared: SharedStore) {
        let store = RustStoreAdapter.shared
        guard store.queryManuscripts(limit: 1).isEmpty else {
            logger.info("seed: manuscripts already present")
            return
        }
        let created = store.createManuscript(
            title: manuscriptTitle,
            format: manuscriptFormat,
            body: """
                # \(manuscriptTitle)

                The eighth term of the Bernoulli series was transposed in the
                published table. This note derives the correction and restates
                the convergence bound.

                ## Method

                Recompute the partial sums to eight terms and compare against
                the engine's output.
                """,
            authors: ["Augusta Ada Lovelace"])
        guard let created else {
            logger.error("seed: createManuscript failed")
            return
        }
        // RED-FLAGGED, and this one line is the fixture for the whole I3
        // regression. The composed sidebar has TWO Flagged sections — imbib's
        // binds `.publication`, imprint's binds `.manuscript` — and the flat
        // sidebar had only the first. Without a flagged manuscript in the store
        // the imprint group's red row would list nothing, and "the row exists
        // but is empty" is exactly the state that reads as working when it is
        // not. Flag through the ENVELOPE verb (`SharedStore.setFlag`), like the
        // mail rows above: flags are envelope facts, never payload fields.
        try? shared.setFlag(
            id: created.id.lowercased(), color: "red", style: nil, length: nil)
        logger.info("seed: wrote manuscript \(created.id), red-flagged")
    }

    // MARK: - Helpers

    private static func millis(offset: TimeInterval) -> Int64 {
        Int64((seedEpoch + offset) * 1000)
    }

    // The local `upsert(id:schemaRef:parentID:payload:…)` helper is GONE
    // (ADR-0022 X2). It took `[String: Any]`, which is what made every field
    // name in this file a literal — a dictionary key cannot be checked against
    // anything. `ChassisPayloadRow.upsert` replaces it inside the chassis
    // writers, with the same id-lowercasing rule and the same `tags: []`.

    /// A 4×4 solid-blue PNG. Small enough to inline, real enough to decode.
    private static let pngBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAFUlEQVR42mNk+M/AwMDAwMDA\
        wMDAAAAoAAGm1lY3AAAAAElFTkSuQmCC
        """
}
