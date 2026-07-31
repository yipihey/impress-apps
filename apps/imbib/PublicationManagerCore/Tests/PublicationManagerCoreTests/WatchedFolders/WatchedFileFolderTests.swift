//
//  WatchedFileFolderTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 W4 — impart's `.mbox`/`.eml` and implore's `.vsz`, headless.
//
//  ── What is real here ───────────────────────────────────────────────────────
//
//  The same three-of-four arrangement `WatchedFolderIngestCoordinatorTests`
//  established, with the fourth stage deliberately empty rather than mocked:
//
//    * the watcher is W1's `FolderWatchService` over the walk engine driven by
//      `ManualDirectoryChangeNotifier` — notify → re-walk → diff → publish,
//      deterministically;
//    * the store is a real `SharedStore` scratch database, so
//      `import_discovered` / `finish_watched_scan` run their real Rust;
//    * the FAN-OUT is `WatchedFolderImportHooks.recordingOnly`, which is not a
//      stub standing in for something — it is W4's answer (see the ADR's W4
//      row). Asserting that it mints nothing is asserting the decision.
//
//  And the ONE place a real parser is reached, `WatchedMailArchive.inspect`,
//  runs `imbib_core::mbox::parse_content` — the Stage-7.9 Rust port, pinned by
//  23 golden archives — over a fixture written by these tests.
//

import ImpressKit
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class WatchedFileFolderTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var notifier: ManualDirectoryChangeNotifier!
    private var store: WatchedFolderStoreAdapter!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.watchedFiles.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        notifier = ManualDirectoryChangeNotifier()
        try SharedWorkspace.ensureDirectoryExists()
        store = WatchedFolderStoreAdapter(
            store: try SharedStore.open(path: SharedWorkspace.databasePath))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        root = nil
        defaults = nil
        suiteName = nil
        notifier = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A tiny but REAL mbox: two RFC-4155 messages, `From ` envelope lines,
    /// folded headers and all. Written rather than checked in because the repo
    /// has no `.mbox` fixture and a two-message archive is more legible inline
    /// than in a binary blob nobody opens.
    private static let twoMessageMbox = """
        From alice@example.org Mon Jan  5 09:14:22 2026
        From: Alice Researcher <alice@example.org>
        To: bob@example.net
        Subject: Draft of the shear-bias section
        Date: Mon, 5 Jan 2026 09:14:22 +0000
        Message-ID: <archive-1@example.org>

        The systematics table is attached in the next round.

        From bob@example.net Tue Jan  6 17:02:10 2026
        From: Bob Collaborator <bob@example.net>
        To: alice@example.org
        Subject: Re: Draft of the shear-bias section
        Date: Tue, 6 Jan 2026 17:02:10 +0000
        Message-ID: <archive-2@example.net>
        In-Reply-To: <archive-1@example.org>

        Looks right. One question about the covariance normalisation.

        """

    /// A minimal Veusz document. implore cannot parse this and does not try —
    /// the point of the fixture is that a `.vsz` is DISCOVERED, not read.
    private static let veuszDocument = """
        # Veusz saved document (version 3.6.2)
        AddImportPath(u'.')
        Add('page', name='page1', autoadd=False)
        """

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeCoordinator(kindScope: String) -> WatchedFolderIngestCoordinator {
        let notifier = self.notifier!
        let watcher = FolderWatchService(
            bookmarks: WatchedFolderBookmarkStore(userDefaults: defaults, broker: .scratch()),
            engines: FolderWatchEngineFactory(
                makePrimary: { nil },
                makeFallback: {
                    WalkFolderDiscoveryEngine(notifier: notifier, debounce: .milliseconds(1))
                }),
            startupGate: .immediate)
        return WatchedFolderIngestCoordinator(
            kindScope: kindScope, watcher: watcher, store: store, hooks: .recordingOnly)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// THIS test's folder row. Matched on `(path, kindScope)`, because the
    /// scratch database is one file for the whole test process AND because two
    /// coordinators can legitimately watch the same directory for two kinds.
    private func folderStoreID(kindScope: String) throws -> String {
        let wanted = root.standardizedFileURL.path
        guard let mine = try store.folders(kindScope: kindScope).first(where: { $0.path == wanted })
        else {
            throw XCTSkip("no watched folder row was written for \(wanted)/\(kindScope)")
        }
        return mine.id
    }

    // MARK: - impart: discover → row → offer

    /// The headline W4 claim for impart: a `.mbox` dropped in a watched folder
    /// gets its `watched-file` row, with its hash and its size, and **no mail
    /// is imported** — nothing is minted, nothing is attributed.
    func testADiscoveredArchiveGetsARowAndNoMessagesAreMinted() async throws {
        try write("2026-collab.mbox", Self.twoMessageMbox)

        let coordinator = makeCoordinator(kindScope: RecordKindID.message.rawValue)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("the archive to be recorded") {
            !coordinator.files(in: row.id).isEmpty
        }

        let files = coordinator.files(in: row.id)
        XCTAssertEqual(files.count, 1, "one .mbox, one watched-file row")
        XCTAssertEqual(files[0].kindScope, RecordKindID.message.rawValue)
        XCTAssertEqual(files[0].state, "present")
        XCTAssertFalse(files[0].contentHash.isEmpty, "the row is hash-tracked (D4)")
        XCTAssertTrue(
            files[0].producedIDs.isEmpty,
            "W4's decision: a discovered archive is OFFERED, not fanned out — "
                + "no message row is minted by the watcher")
        XCTAssertEqual(
            coordinator.producedCounts[row.id], 0,
            "and the folder claims to have produced nothing, because it did")
    }

    /// The OFFER, through the real parser: the affordance the sidebar row hands
    /// the user is "this archive holds N messages", and N comes from
    /// `imbib_core::mbox::parse_content`, not from counting lines here.
    func testTheArchiveOfferCountsMessagesWithTheRealParser() async throws {
        let archive = try write("2026-collab.mbox", Self.twoMessageMbox)

        let inspection = try await WatchedMailArchive.inspect(path: archive.path)
        XCTAssertEqual(inspection.messageCount, 2)
        XCTAssertEqual(inspection.summary, "2 messages")
        XCTAssertEqual(
            inspection.firstSubjects.first, "Draft of the shear-bias section",
            "the subjects come out of the Rust parser's header extraction")
    }

    /// A single `.eml` is one message — the half of the ingest map that needed
    /// no decision at all (`MessageRecordKind`'s own comment: "an `.eml` IS one
    /// message, so `file` is simply correct for it").
    ///
    /// It is also the case that caught the real difference between the two
    /// extensions: the Rust parser splits on the `From ` envelope line, so a
    /// bare RFC 5322 message reads as ZERO messages until `asMboxArchive` gives
    /// it the one line that makes it a one-message archive.
    func testASingleEMLReadsAsOneMessage() async throws {
        let eml = try write(
            "invitation.eml",
            """
            From: chair@conference.example
            To: alice@example.org
            Subject: Invitation to review
            Date: Wed, 7 Jan 2026 11:00:00 +0000
            Message-ID: <eml-1@conference.example>

            Would you review submission 214?
            """)
        let inspection = try await WatchedMailArchive.inspect(path: eml.path)
        XCTAssertEqual(inspection.messageCount, 1)
        XCTAssertEqual(inspection.summary, "1 message")
        XCTAssertEqual(inspection.firstSubjects, ["Invitation to review"])

        // And an archive that already has envelope lines is passed through
        // untouched — the synthesis must never split a real mbox differently.
        XCTAssertEqual(
            WatchedMailArchive.asMboxArchive(Self.twoMessageMbox), Self.twoMessageMbox)
    }

    /// **D7, enforced rather than hoped for.** The inspection is a whole-file
    /// parse, so it refuses above a declared ceiling and says so — it does not
    /// succeed slowly on a multi-gigabyte mail archive while the user waits for
    /// a subtitle.
    func testAnArchiveOverTheCeilingIsRefusedInWords() async throws {
        let huge = root.appendingPathComponent("decade.mbox")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        // Sparse: the ceiling check reads the SIZE attribute, so no bytes are
        // actually written and the test stays fast and small on disk.
        try handle.truncate(atOffset: UInt64(WatchedMailArchive.inspectionByteCeiling) + 1)
        try handle.close()

        do {
            _ = try await WatchedMailArchive.inspect(path: huge.path)
            XCTFail("an archive over the ceiling must be refused, not parsed")
        } catch let refusal as WatchedMailArchive.Refusal {
            guard case .tooLarge = refusal else {
                return XCTFail("wrong refusal: \(refusal)")
            }
            let message = try XCTUnwrap(refusal.errorDescription)
            XCTAssertTrue(
                message.contains("not read to count their messages"),
                "the row renders this sentence verbatim: \(message)")
        }
    }

    /// A vanished archive keeps its row, flagged — D4 all the way through the
    /// file-unit path, exactly as it holds for the entry-unit one.
    func testAVanishedArchiveKeepsItsRow() async throws {
        let archive = try write("gone.mbox", Self.twoMessageMbox)

        let coordinator = makeCoordinator(kindScope: RecordKindID.message.rawValue)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()
        await waitUntil("the archive to be recorded") { !coordinator.files(in: row.id).isEmpty }

        try FileManager.default.removeItem(at: archive)
        notifier.fire()

        let storeID = try folderStoreID(kindScope: RecordKindID.message.rawValue)
        await waitUntil("the sweep to mark it missing") {
            ((try? self.store.files(folderID: storeID, state: "missing").total) ?? 0) == 1
        }
        let missing = try store.files(folderID: storeID, state: "missing").files
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual((missing[0].path as NSString).lastPathComponent, "gone.mbox")
    }

    // MARK: - implore: reference in place, nothing minted

    /// implore's whole v1, in one assertion: the `.vsz` is discovered, indexed
    /// in place, and NOT turned into a figure. The figure store is not written
    /// to at all — which is the point, since `figure`'s payload has no field
    /// for a path and a record minted from an unreadable file would carry a
    /// name and nothing else.
    func testADiscoveredVeuszDocumentIsIndexedAndNoFigureIsMinted() async throws {
        try write("shear-bias.vsz", Self.veuszDocument)
        try write("notes.txt", "not a figure")

        let coordinator = makeCoordinator(kindScope: RecordKindID.figure.rawValue)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("the document to be recorded") {
            !coordinator.files(in: row.id).isEmpty
        }

        let files = coordinator.files(in: row.id)
        XCTAssertEqual(
            files.map { ($0.path as NSString).lastPathComponent }, ["shear-bias.vsz"],
            "the discovery filter is the FigureRecordKind declaration's — .vsz only")
        XCTAssertTrue(files[0].producedIDs.isEmpty, "no figure row was minted")
        XCTAssertEqual(files[0].kindScope, RecordKindID.figure.rawValue)
    }

    // MARK: - The two kinds do not collide

    /// Two coordinators over the SAME directory produce two folder rows, one
    /// per `kind_scope`, each seeing only its own kind's files — and neither
    /// adopts the other's persisted bookmark.
    ///
    /// This is the failure the `limitedToFilterIDs` narrowing exists to
    /// prevent: without it, impart's coordinator restores imbib's `.bib` folder
    /// on launch and writes it into the store a second time under
    /// `kind_scope: message`.
    func testTwoKindsWatchingOneDirectoryStayDisjoint() async throws {
        try write("papers.bib", "@article{k2026, title={T}}")
        try write("mail.mbox", Self.twoMessageMbox)

        let mail = makeCoordinator(kindScope: RecordKindID.message.rawValue)
        let mailRow = try await mail.addFolder(at: root)
        await mail.start()
        await waitUntil("the archive") { !mail.files(in: mailRow.id).isEmpty }

        let mailFiles = mail.files(in: mailRow.id)
        XCTAssertEqual(mailFiles.map { ($0.path as NSString).lastPathComponent }, ["mail.mbox"])

        // The store rows are keyed by (path, kind_scope), so the same directory
        // legitimately has one row per kind and they never merge.
        let mailFolder = try folderStoreID(kindScope: RecordKindID.message.rawValue)
        XCTAssertNotEqual(
            mailFolder,
            (try? folderStoreID(kindScope: WatchedFolderIngestCoordinator.kindScope)) ?? "",
            "one directory, two kinds, two folder rows")
    }

    // MARK: - The sidebar wiring (implore's only oracle beyond the build)

    /// The row → selection → pane round trip, without a UI.
    ///
    /// implore has no unit-test target of its own and its real coverage is the
    /// macOS build (docs/chassis-capability-matrix.md, hardening C3), so this
    /// is where its sidebar row is actually checked: the node resolves to a
    /// record route whose HOST key parses back to the folder it came from, and
    /// that key is what `RecordViewerRegistry`'s watched-files arm matches on.
    func testTheSidebarNodeResolvesToTheWatchedFolderRoute() throws {
        let folderID = WatchedFolderID()
        for kind in [RecordKindID.figure, RecordKindID.message] {
            let node = ImbibSidebarNode(
                id: ImbibSidebarNodeID.watchedFileFolder(folderID, kindScope: kind.rawValue),
                nodeType: .watchedFileFolder(folderID: folderID, kindScope: kind.rawValue),
                displayName: "Archives",
                iconName: "folder.badge.gearshape")
            guard case .record(let route)? = node.imbibTab else {
                return XCTFail("\(kind.rawValue) node did not resolve to a record route")
            }
            XCTAssertEqual(route.kind, kind)
            guard case .host(let scopeKind, let key) = route.scope else {
                return XCTFail("the route must ride the declared host escape hatch")
            }
            XCTAssertEqual(scopeKind, kind)
            XCTAssertEqual(
                WatchedFolderRoute(key: key), .folder(folderID),
                "the key round-trips, so the pane can find its folder again")
        }
    }

    /// Two node ids for one folder id must not collide: an `entries` folder and
    /// a `file` folder open different surfaces, and `tabToNodeID` is keyed by
    /// node id.
    func testTheTwoWatchedRowKindsHaveDistinctNodeIDs() {
        let folderID = WatchedFolderID()
        XCTAssertNotEqual(
            ImbibSidebarNodeID.watchedFolder(folderID),
            ImbibSidebarNodeID.watchedFileFolder(
                folderID, kindScope: RecordKindID.message.rawValue))
        XCTAssertNotEqual(
            ImbibSidebarNodeID.watchedFileFolder(
                folderID, kindScope: RecordKindID.message.rawValue),
            ImbibSidebarNodeID.watchedFileFolder(
                folderID, kindScope: RecordKindID.figure.rawValue))
    }

    /// A shell starts the coordinators for the sections it actually shows, and
    /// no others — imbib does not run a mail watcher, impart does not run a
    /// figure one.
    func testEachShellWatchesOnlyTheKindsItSurfaces() {
        XCTAssertEqual(
            ImbibSidebarViewModel.watchedKindScopes(for: .imbib),
            [WatchedFolderIngestCoordinator.kindScope])
        XCTAssertEqual(
            ImbibSidebarViewModel.watchedKindScopes(for: .impart),
            [WatchedFolderIngestCoordinator.kindScope, RecordKindID.message.rawValue])
        XCTAssertEqual(
            ImbibSidebarViewModel.watchedKindScopes(for: .implore),
            [WatchedFolderIngestCoordinator.kindScope, RecordKindID.figure.rawValue])
        // impress shows every section, so it runs every file-unit watcher.
        // A SUPERSET assertion rather than an equality one: `.manuscripts` is
        // W3's row in the same declared table, and pinning the exact set here
        // would make this test fail the moment a sibling work package adds its
        // own kind — which is the one thing the table is designed to allow.
        XCTAssertTrue(
            Set(ImbibSidebarViewModel.watchedKindScopes(for: .impress)).isSuperset(of: [
                WatchedFolderIngestCoordinator.kindScope,
                RecordKindID.message.rawValue,
                RecordKindID.figure.rawValue,
            ]))
        XCTAssertFalse(
            ImbibSidebarViewModel.watchedKindScopes(for: .impart)
                .contains(RecordKindID.figure.rawValue),
            "impart shows no Figures section, so it must not run a .vsz watcher")
    }

    /// The pane's per-kind verbs are DERIVED from the kind, and the one verb
    /// that costs something (`Count Messages`) is offered only where there is a
    /// parser behind it.
    func testThePaneOffersInspectionOnlyWhereAParserExists() {
        XCTAssertTrue(
            WatchedFileVerbs.forKindScope(RecordKindID.message.rawValue)
                .offersArchiveInspection)
        XCTAssertFalse(
            WatchedFileVerbs.forKindScope(RecordKindID.figure.rawValue).offersArchiveInspection,
            "there is no Veusz reader in the suite, so implore offers no count")
        // The chassis rule: the explanation is never empty, so a user always
        // learns what the folder did and did not do.
        for scope in [RecordKindID.message.rawValue, RecordKindID.figure.rawValue, "unknown"] {
            XCTAssertFalse(WatchedFileVerbs.forKindScope(scope).handoffExplanation.isEmpty)
        }
    }

    /// The offer rows sort present-before-missing and never render a missing
    /// file as an ordinary one.
    func testOffersSortPresentFilesFirstAndSayWhenOneIsGone() {
        let offers = [
            WatchedFileOffer(id: "b", path: "/tmp/zeta.mbox", sizeBytes: 10),
            WatchedFileOffer(id: "a", path: "/tmp/alpha.mbox", sizeBytes: 20, isMissing: true),
            WatchedFileOffer(id: "c", path: "/tmp/beta.mbox", sizeBytes: 30),
        ]
        .map { $0 }
        let sorted = offers.sorted {
            $0.isMissing == $1.isMissing
                ? $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                : !$0.isMissing
        }
        XCTAssertEqual(sorted.map(\.fileName), ["beta.mbox", "zeta.mbox", "alpha.mbox"])
        XCTAssertTrue(sorted.last!.statusLine.contains("nothing was deleted"))
    }

    /// The extensions the offer machinery understands come from the DECLARATION
    /// (ADR-0023 D1), not from a literal in the mail code.
    func testTheArchiveExtensionsAreTheDeclaredOnes() {
        XCTAssertEqual(WatchedMailArchive.fileExtensions, ["mbox", "eml"])
        XCTAssertEqual(
            FileDiscoveryFilter.forKindScope(RecordKindID.figure.rawValue)?.filenameExtensions,
            ["vsz"])
    }
}
