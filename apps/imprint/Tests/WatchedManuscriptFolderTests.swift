//
//  WatchedManuscriptFolderTests.swift
//  imprintTests
//
//  ADR-0023 W3 — the reference-in-place representation and the loop, headless.
//
//  ── What is real ────────────────────────────────────────────────────────────
//
//  The store is a real `SharedStore` (in-memory for the verb tests, the
//  process-scoped scratch FILE for the end-to-end one — attribution is a
//  cross-handle claim and the kernel refuses to record provenance for rows it
//  cannot see, which is the W2 "one database, two handles" lesson); the watcher
//  is W1's `FolderWatchService` over the walk engine driven by
//  `ManualDirectoryChangeNotifier`, so the live-edit path is the real
//  notify → re-walk → diff → publish sequence; the fan-out is imprint's
//  shipping `upsertExternalManuscript`.
//
//  Nothing here writes a file the test did not create in its own temp
//  directory, and nothing here can reach a user's store.
//

import ImpressKit
import ImpressRustCore
import PublicationManagerCore
import XCTest

@testable import imprint

@MainActor
final class WatchedManuscriptFolderTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-manuscripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try await super.tearDown()
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The representation

    /// The headline claim: a discovered file becomes a manuscript row that
    /// REFERENCES it — body snapshot present, file authoritative, and the row
    /// says which file it is.
    func testIndexingAFileProducesAnExternalManuscript() throws {
        let adapter = try ManuscriptStoreAdapter.forTesting()
        let file = try write("Notes.md", "# Notes\n\nThe first paragraph.")

        let outcome = try adapter.upsertExternalManuscript(
            path: file.path, folderName: "drafts")

        XCTAssertTrue(outcome.created)
        XCTAssertFalse(outcome.contentChanged, "a first index has nothing to compare against")

        let model = try XCTUnwrap(adapter.manuscript(id: outcome.id))
        XCTAssertTrue(model.isExternalReference, "the row must declare that a file owns its body")
        let source = try XCTUnwrap(model.externalSource)
        XCTAssertEqual(source.path, file.standardizedFileURL.path)
        XCTAssertEqual(source.folderName, "drafts")
        XCTAssertEqual(source.state, .present)
        XCTAssertFalse(source.contentHash.isEmpty)
        // The title is the FILE's name: an external manuscript is named by the
        // thing it indexes, not by anything the store invented.
        XCTAssertEqual(model.title, "Notes")
        XCTAssertEqual(model.format, .markdown)
        XCTAssertEqual(model.body, "# Notes\n\nThe first paragraph.")
    }

    /// Identity is the PATH, so a re-scan updates one row instead of minting a
    /// second — and the body snapshot is REPLACED wholesale, which is the whole
    /// no-fight argument: the store can never hold text the file does not.
    func testReIndexingAnEditedFileReplacesTheSnapshotInPlace() throws {
        let adapter = try ManuscriptStoreAdapter.forTesting()
        let file = try write("Notes.md", "first")
        let first = try adapter.upsertExternalManuscript(path: file.path)

        try "second, and longer".write(to: file, atomically: true, encoding: .utf8)
        let second = try adapter.upsertExternalManuscript(path: file.path)

        XCTAssertEqual(first.id, second.id, "the path is the identity")
        XCTAssertFalse(second.created)
        XCTAssertTrue(second.contentChanged)
        let model = try XCTUnwrap(adapter.manuscript(id: second.id))
        XCTAssertEqual(model.body, "second, and longer")
        XCTAssertEqual(
            adapter.externalManuscripts().count, 1,
            "an edited file must not produce a second manuscript")
    }

    /// A vanished file flags its row and KEEPS it — and keeps the body, because
    /// throwing the snapshot away would turn "your file moved" into "your text
    /// is gone" (D4, in its other direction).
    func testAMissingFileFlagsTheRowAndNeverDeletesIt() throws {
        let adapter = try ManuscriptStoreAdapter.forTesting()
        let file = try write("Gone.md", "the body that must survive")
        let outcome = try adapter.upsertExternalManuscript(path: file.path)

        let flagged = try adapter.markExternalManuscriptMissing(path: file.path)
        XCTAssertEqual(flagged, outcome.id)

        let model = try XCTUnwrap(adapter.manuscript(id: outcome.id))
        XCTAssertEqual(model.externalSource?.state, .missing)
        XCTAssertTrue(model.externalSource?.isMissing ?? false)
        XCTAssertEqual(model.body, "the body that must survive")

        // Reversible: a system-raised flag a system can lower.
        let restored = try adapter.markExternalManuscriptPresent(path: file.path)
        XCTAssertEqual(restored, outcome.id)
        XCTAssertEqual(adapter.manuscript(id: outcome.id)?.externalSource?.state, .present)

        // And flagging twice is a no-op, not a second write.
        _ = try adapter.markExternalManuscriptMissing(path: file.path)
        XCTAssertNil(try adapter.markExternalManuscriptMissing(path: file.path))
    }

    /// Import-a-copy produces an ORDINARY manuscript: editable, store-backed,
    /// and with no claim on the file. The original row keeps watching.
    func testImportingACopyProducesAnOrdinaryManuscript() throws {
        let adapter = try ManuscriptStoreAdapter.forTesting()
        let file = try write("Paper.typ", "= Paper\n\nBody.")
        let external = try adapter.upsertExternalManuscript(path: file.path)

        let copyID = try adapter.importCopyOfExternalManuscript(id: external.id)
        XCTAssertNotEqual(copyID, external.id)

        let copy = try XCTUnwrap(adapter.manuscript(id: copyID))
        XCTAssertFalse(
            copy.isExternalReference,
            "a copy is the user's manuscript now — nothing on disk owns it")
        XCTAssertNil(copy.externalSource)
        XCTAssertEqual(copy.body, "= Paper\n\nBody.")
        // Provenance is kept, as the DETACHED kind — the opposite claim from
        // `external_source`, and the distinction the two fields exist for.
        XCTAssertEqual(copy.importSource?.originalPath, file.standardizedFileURL.path)

        // The original is untouched and still external.
        XCTAssertTrue(adapter.manuscript(id: external.id)?.isExternalReference ?? false)
    }

    /// The structural no-write-back guarantee, as one predicate: an external
    /// manuscript never takes an editor session, so no debounced save exists to
    /// fire late over a file somebody else is editing.
    func testExternalManuscriptsTakeNoEditorSession() throws {
        let adapter = try ManuscriptStoreAdapter.forTesting()
        let file = try write("Ref.md", "referenced")
        let external = try adapter.upsertExternalManuscript(path: file.path)
        let ordinary = try adapter.createManuscript(title: "Mine", format: .typst, body: "mine")

        XCTAssertFalse(
            WatchedManuscriptGuard.allowsEditorSession(adapter.manuscript(id: external.id)),
            "the file is authoritative — an editor here would be a second writer")
        XCTAssertTrue(
            WatchedManuscriptGuard.allowsEditorSession(adapter.manuscript(id: ordinary)))
    }

    /// A file too large to snapshot is still INDEXED — path, hash and both
    /// affordances — rather than refused. Only the body is withheld.
    func testAnOversizeFileIsIndexedWithoutASnapshot() throws {
        let adapter = try ManuscriptStoreAdapter.forTesting()
        let huge = String(repeating: "x", count: ExternalManuscriptReader.maximumSnapshotBytes + 1)
        let file = try write("Huge.txt", huge)

        let outcome = try adapter.upsertExternalManuscript(path: file.path)
        let model = try XCTUnwrap(adapter.manuscript(id: outcome.id))
        XCTAssertTrue(model.isExternalReference)
        XCTAssertTrue(model.body.isEmpty, "the snapshot is withheld above the cap")
        XCTAssertFalse(
            model.externalSource?.contentHash.isEmpty ?? true,
            "the hash is computed regardless, so 'has it changed?' stays answerable")
    }

    // MARK: - The loop, end to end

    /// Drop a `.md` in a watched folder and it becomes a manuscript, tagged
    /// with the folder's provenance tag — then EDIT the file and watch the row
    /// follow it. Real watcher, real store verbs, real fan-out.
    func testWatchedFolderIngestsAndThenFollowsAnExternalEdit() async throws {
        let suiteName = "test.watchedManuscripts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try SharedWorkspace.ensureDirectoryExists()
        let watchedStore = WatchedFolderStoreAdapter(
            store: try SharedStore.open(path: SharedWorkspace.databasePath))
        let adapter = ManuscriptStoreAdapter.shared

        let notifier = ManualDirectoryChangeNotifier()
        let watcher = FolderWatchService(
            bookmarks: WatchedFolderBookmarkStore(userDefaults: defaults, broker: .scratch()),
            engines: FolderWatchEngineFactory(
                makePrimary: { nil },
                makeFallback: {
                    WalkFolderDiscoveryEngine(notifier: notifier, debounce: .milliseconds(1))
                }),
            startupGate: .immediate)
        let coordinator = WatchedFolderIngestCoordinator(
            kindScope: WatchedManuscriptFolders.kindScope,
            watcher: watcher,
            store: watchedStore,
            hooks: WatchedManuscriptFolders.hooks)

        let file = try write("Draft.md", "# Draft\n\nOne paragraph.")
        let expectedID = ExternalManuscriptSource.manuscriptID(forPath: file.path)

        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("the manuscript to be indexed") {
            adapter.manuscript(id: expectedID)?.isExternalReference ?? false
        }

        let indexed = try XCTUnwrap(adapter.manuscript(id: expectedID))
        XCTAssertEqual(indexed.body, "# Draft\n\nOne paragraph.")

        // The provenance tag — W2's mechanism, which is ALSO the folder row's
        // list scope. Both halves asserted, because a tag that is not the scope
        // would be a label rather than an identity.
        let tag = WatchedFolderProvenanceTag.path(forFolderNamed: row.displayName)
        XCTAssertTrue(
            indexed.tags.contains(tag),
            "the manuscript must carry its folder's provenance tag; got \(indexed.tags)")
        // `WatchedManuscriptFolders.storeScope(forFolder:)` resolves the same
        // tag through the PROCESS registry, which this test deliberately does
        // not join (it drives its own watcher). What is asserted here is the
        // half that matters and that a registry cannot fake: the tag the ingest
        // actually wrote IS a working list scope. The registry lookup itself is
        // exercised end to end by `WatchedManuscriptFolderUITests`.
        XCTAssertTrue(
            adapter.listManuscripts(scope: .tag(tag), limit: 0).contains { $0.id == expectedID },
            "the folder's scope must list the manuscript it produced")

        // The Swift-side hash and the KERNEL's must agree. They are two
        // implementations of "SHA-256 of the file's bytes", and W0 already fixed
        // one lossy-UTF8 divergence — this is the guard that keeps them equal.
        let storeFolder = try XCTUnwrap(
            watchedStore.folders().first { $0.path == root.standardizedFileURL.path })
        let watchedFiles = try watchedStore.files(folderID: storeFolder.id).files
        let watchedFile = try XCTUnwrap(
            watchedFiles.first { $0.path == file.standardizedFileURL.path })
        XCTAssertEqual(
            watchedFile.contentHash, indexed.externalSource?.contentHash,
            "the manuscript's file hash must be the kernel's hash of the same bytes")
        XCTAssertEqual(
            watchedFile.producedIDs, [expectedID.uuidString.lowercased()],
            "the watched-file row must attribute the manuscript it produced")

        // THE LIVE EDIT. Somebody else's editor rewrites the file.
        try "# Draft\n\nOne paragraph.\n\nA second paragraph.".write(
            to: file, atomically: true, encoding: .utf8)
        notifier.fire()

        await waitUntil("the manuscript body to follow the file") {
            adapter.manuscript(id: expectedID)?.body.contains("second paragraph") ?? false
        }

        let followed = try XCTUnwrap(adapter.manuscript(id: expectedID))
        XCTAssertNotEqual(
            followed.externalSource?.contentHash, indexed.externalSource?.contentHash,
            "the recorded file hash must move with the file")
        XCTAssertEqual(
            adapter.externalManuscripts().filter { $0.id == expectedID }.count, 1,
            "the edit updated a row; it did not add one")

        // THE VANISHING. Deleting the file must flag the manuscript and keep
        // it — the store row outlives the file, always (D4).
        try FileManager.default.removeItem(at: file)
        notifier.fire()

        await waitUntil("the watched-file row to be swept") {
            (try? watchedStore.files(folderID: storeFolder.id).files
                .first { $0.path == file.standardizedFileURL.path }?.isMissing) ?? false ?? false
        }
        // The half imprint owns: mirroring the swept INDEX row into the
        // MANUSCRIPT row. In the app `WatchedManuscriptFolders.reconcileMissing()`
        // does this on every `.watchedFoldersDidChange`; it reads the process
        // registry, which this test deliberately does not join, so the verb it
        // calls is invoked directly here.
        _ = try adapter.markExternalManuscriptMissing(path: file.path)

        let vanished = try XCTUnwrap(adapter.manuscript(id: expectedID))
        XCTAssertEqual(
            vanished.externalSource?.state, .missing,
            "a manuscript whose file is gone is FLAGGED, never deleted")
        XCTAssertTrue(
            vanished.body.contains("second paragraph"),
            "the last text the file held survives — 'your file moved' must not become "
                + "'your text is gone'")

        await coordinator.removeFolder(row.id)
        coordinator.stop()
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}
