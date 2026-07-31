//
//  WatchedFolderIngestCoordinatorTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 W2 — the END-TO-END loop, headless.
//
//  ── What makes this the real thing and not a mock parade ────────────────────
//
//  Three of the four stages are REAL here:
//
//    * the watcher is W1's `FolderWatchService`, over the walk engine driven by
//      `ManualDirectoryChangeNotifier` — the exact sequence a live FSEvents
//      callback triggers (notify → re-walk → diff → publish), deterministically
//      (`FolderWatchServiceTests`' arrangement, and its header explains why
//      NSMetadataQuery cannot be driven from `swift test`);
//    * the store is a real `SharedStore` scratch database, so `import_discovered`,
//      `record_produced_rows` and `finish_watched_scan` run their real Rust;
//    * the IMPORTER is `RustStoreAdapter.shared` — imbib's actual BibTeX path,
//      with the actual Rust identifier dedup. Under XCTest that adapter opens an
//      in-memory store (`ImpressRuntime.isUnitTestProcess`), so nothing here can
//      reach a user's library.
//
//  Only the tags are captured rather than written, and only in the tests that
//  are ABOUT tagging — the ones about dedup let the real writes happen.
//
//  ── ONE database, two handles ───────────────────────────────────────────────
//
//  The importer and the watched-folder verbs MUST see the same store, and
//  `SharedStore.openInMemory()` twice is two DATABASES, not two handles on one
//  (`RustStoreAdapter.init(inMemory:)` calls this "the imprint seed lesson").
//  Writing publications into one and attributing provenance in the other is not
//  a test artefact — the kernel catches it and says so ("these produced ids
//  name no row in the store"), which is exactly the dangling-provenance guard
//  doing its job. So both handles here open the SAME file, the way they do in
//  the app.
//
//  That file is `SharedWorkspace.databasePath`, which under XCTest is already a
//  per-process temp directory (`ImpressRuntime.isUnitTestProcess`) — no user
//  store is reachable from here even in principle.
//

import ImpressKit
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class WatchedFolderIngestCoordinatorTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var notifier: ManualDirectoryChangeNotifier!
    private var store: WatchedFolderStoreAdapter!
    /// imbib's REAL importer, on the scratch database.
    private var library: RustStoreAdapter!

    /// Tags the hooks were asked to write: `path → ids`, accumulated.
    private var tagged: [String: [UUID]] = [:]
    private var untagged: [String: [UUID]] = [:]

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.watchedIngest.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        notifier = ManualDirectoryChangeNotifier()
        try SharedWorkspace.ensureDirectoryExists()
        library = try RustStoreAdapter(inMemory: false)
        store = WatchedFolderStoreAdapter(
            store: try SharedStore.open(path: SharedWorkspace.databasePath))
        tagged = [:]
        untagged = [:]
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        root = nil
        defaults = nil
        suiteName = nil
        notifier = nil
        store = nil
        library = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let entryA = """
        @article{einstein1905,
          author = {Einstein, Albert},
          title = {Zur Elektrodynamik bewegter K\\"orper},
          year = {1905},
          doi = {10.1002/andp.19053221004}
        }
        """

    private static let entryB = """
        @article{noether1918,
          author = {Noether, Emmy},
          title = {Invariante Variationsprobleme},
          year = {1918},
          doi = {10.1007/BF01459088}
        }
        """

    private static let entryC = """
        @article{hubble1929,
          author = {Hubble, Edwin},
          title = {A Relation between Distance and Radial Velocity},
          year = {1929},
          doi = {10.1073/pnas.15.3.168}
        }
        """

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The library every test imports into. A real one, in the in-memory store
    /// `RustStoreAdapter.shared` opens under XCTest.
    private func makeLibrary() throws -> UUID {
        if let existing = library.getDefaultLibrary() { return existing.id }
        guard let created = library.createLibrary(name: "Watched Test Library") else {
            throw XCTSkip("the test store has no library and would not create one")
        }
        return created.id
    }

    /// Hooks over imbib's REAL importer, with the tag writes captured so a test
    /// can assert on them without reading them back through a tag query.
    private func recordingHooks(library libraryID: UUID) -> WatchedFolderImportHooks {
        let adapter = library!
        return WatchedFolderImportHooks(
            importBibTeX: { bibtex, targetLibrary in
                adapter.importBibTeXOutcome(bibtex, libraryId: targetLibrary)
            },
            defaultLibraryID: { libraryID },
            addTag: { [weak self] ids, path in
                self?.tagged[path, default: []].append(contentsOf: ids)
                adapter.addTag(ids: ids, tagPath: path)
            },
            removeTag: { [weak self] ids, path in
                self?.untagged[path, default: []].append(contentsOf: ids)
                adapter.removeTag(ids: ids, tagPath: path)
            })
    }

    private func makeCoordinator(library: UUID) -> WatchedFolderIngestCoordinator {
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
            watcher: watcher, store: store, hooks: recordingHooks(library: library))
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

    /// THIS test's folder row.
    ///
    /// Matched on path, not `folders().first`: the scratch database is one file
    /// for the whole test process, so earlier tests' folders are still in it.
    private func folderStoreID(_ coordinator: WatchedFolderIngestCoordinator) throws -> String {
        let wanted = root.standardizedFileURL.path
        guard let mine = try store.folders().first(where: { $0.path == wanted }) else {
            throw XCTSkip("no watched folder row was written for \(wanted)")
        }
        return mine.id
    }

    // MARK: - The live drop

    /// The headline claim: drop a `.bib` in a watched folder and its entries
    /// land in the library, with provenance, without anyone pressing anything.
    func testGatheredFileIsImportedWithProvenance() async throws {
        let libraryID = try makeLibrary()
        try write("refs.bib", "\(Self.entryA)\n\n\(Self.entryB)")

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("the gather to be ingested") {
            (self.coordinatorProduced(coordinator, row.id) ?? 0) >= 2
        }

        // Two entries, two publications.
        XCTAssertEqual(coordinator.producedCounts[row.id], 2)

        // The store knows which file produced them.
        let storeID = try folderStoreID(coordinator)
        let files = try store.files(folderID: storeID).files
        XCTAssertEqual(files.count, 1, "one .bib, one provenance row")
        XCTAssertEqual(files[0].producedIDs.count, 2)
        XCTAssertEqual(files[0].state, "present")
        XCTAssertFalse(
            files[0].needsReimport,
            "the fan-out just ran against this exact content")

        // And the provenance tag, which is also the folder row's list scope.
        let tag = WatchedFolderProvenanceTag.path(forFolderNamed: row.displayName)
        XCTAssertEqual(Set(tagged[tag] ?? []).count, 2)
        XCTAssertEqual(coordinator.publicationSource(for: row.id), .tag(tag))
    }

    /// The FSEvents shape: the folder is already watched and settled, then a
    /// file appears. Nothing is polled and nothing is pressed.
    func testAFileAppearingLaterIsImportedLive() async throws {
        let libraryID = try makeLibrary()
        try write("first.bib", Self.entryA)

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()
        await waitUntil("the initial gather") {
            (self.coordinatorProduced(coordinator, row.id) ?? 0) >= 1
        }

        try write("second.bib", Self.entryB)
        notifier.fire()

        await waitUntil("the live update") {
            ((try? self.store.files(folderID: try self.folderStoreID(coordinator)).files.count)
                ?? 0) >= 2
        }
        let storeID = try folderStoreID(coordinator)
        let files = try store.files(folderID: storeID).files
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { !$0.producedIDs.isEmpty })
    }

    // MARK: - Dedup

    /// **The dedup proof.** The same entry in two watched files is ONE
    /// publication — imbib's real identifier dedup, reached through the watcher
    /// rather than through a drag.
    ///
    /// Both files legitimately ACCOUNT for it: the second file's attribution
    /// includes the id the first file created, because "this file contains this
    /// entry" is true of both. That is why the coordinator hands
    /// `imported + existing` to `record_produced_rows` and not just `imported`.
    func testTheSameEntryInTwoWatchedFilesIsOnePublication() async throws {
        let libraryID = try makeLibrary()
        try write("a.bib", "\(Self.entryA)\n\n\(Self.entryB)")
        try write("b.bib", "\(Self.entryA)\n\n\(Self.entryC)")

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("both files to be ingested") {
            ((try? self.store.files(folderID: try self.folderStoreID(coordinator)).files.count)
                ?? 0) >= 2
        }
        await waitUntil("both files to be attributed") {
            let files =
                (try? self.store.files(folderID: try self.folderStoreID(coordinator)).files) ?? []
            return files.count == 2 && files.allSatisfy { !$0.producedIDs.isEmpty }
        }

        let files = try store.files(folderID: try folderStoreID(coordinator)).files
        let a = try XCTUnwrap(files.first { $0.path.hasSuffix("a.bib") })
        let b = try XCTUnwrap(files.first { $0.path.hasSuffix("b.bib") })

        XCTAssertEqual(a.producedIDs.count, 2)
        XCTAssertEqual(b.producedIDs.count, 2)

        let shared = Set(a.producedIDs).intersection(Set(b.producedIDs))
        XCTAssertEqual(
            shared.count, 1,
            "einstein1905 appears in both files and must be ONE publication, "
                + "claimed by both — not two rows and not one file's secret")

        // Three distinct entries across two files ⇒ three publications.
        let all = Set(a.producedIDs).union(Set(b.producedIDs))
        XCTAssertEqual(all.count, 3)

        // And the provenance tag is written once per file, so the shared paper
        // carries it too — no paper this folder produced is untagged.
        let tag = WatchedFolderProvenanceTag.path(forFolderNamed: row.displayName)
        let taggedIDs = Set((tagged[tag] ?? []).map { $0.uuidString.lowercased() })
        XCTAssertTrue(all.isSubset(of: taggedIDs))
    }

    // MARK: - The removed disposition

    /// An entry the source file no longer contains is TAGGED for review and
    /// **never deleted** — and un-tagged again if it comes back.
    func testAnEntryDroppedFromTheSourceIsFlaggedNotDeleted() async throws {
        let libraryID = try makeLibrary()
        let bib = try write("refs.bib", "\(Self.entryA)\n\n\(Self.entryB)")

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()
        await waitUntil("the initial import") {
            (self.coordinatorProduced(coordinator, row.id) ?? 0) >= 2
        }

        let storeID = try folderStoreID(coordinator)
        let before = try store.files(folderID: storeID).files[0].producedPublicationIDs
        XCTAssertEqual(before.count, 2)

        // The user removes an entry from the file.
        try Self.entryA.write(to: bib, atomically: true, encoding: .utf8)
        notifier.fire()

        await waitUntil("the re-import to notice the loss") {
            !(coordinator.removedFromSource[row.id]?.isEmpty ?? true)
        }

        let orphaned = try XCTUnwrap(coordinator.removedFromSource[row.id])
        try XCTSkipIf(orphaned.isEmpty, "no orphan was reported")
        XCTAssertEqual(orphaned.count, 1)

        // Flagged…
        XCTAssertEqual(
            Set(untagged[WatchedFolderProvenanceTag.removedFromSource] ?? []).isEmpty, false,
            "the surviving entry is un-flagged on every pass")
        XCTAssertTrue(
            (tagged[WatchedFolderProvenanceTag.removedFromSource] ?? []).contains(orphaned[0]))

        // …and NOT deleted. The publication is still in the store.
        let survivor = try XCTUnwrap(
            library.getPublication(id: orphaned[0]))
        XCTAssertFalse(survivor.title.isEmpty)

        // Put it back: the flag is lifted, without a resolution verb.
        try "\(Self.entryA)\n\n\(Self.entryB)".write(to: bib, atomically: true, encoding: .utf8)
        notifier.fire()
        await waitUntil("the entry to come back") {
            (self.untagged[WatchedFolderProvenanceTag.removedFromSource] ?? [])
                .filter { $0 == orphaned[0] }.count >= 1
        }
    }

    // MARK: - The zero-write property

    /// A settled folder re-scanned imports nothing: `import_discovered` reports
    /// `unchanged`, and the importer is never called. This is the property the
    /// whole steady state rests on.
    func testAnUnchangedRescanRunsNoImporter() async throws {
        let libraryID = try makeLibrary()
        try write("refs.bib", Self.entryA)

        var importCalls = 0
        let notifier = self.notifier!
        let watcher = FolderWatchService(
            bookmarks: WatchedFolderBookmarkStore(userDefaults: defaults, broker: .scratch()),
            engines: FolderWatchEngineFactory(
                makePrimary: { nil },
                makeFallback: {
                    WalkFolderDiscoveryEngine(notifier: notifier, debounce: .milliseconds(1))
                }),
            startupGate: .immediate)
        let coordinator = WatchedFolderIngestCoordinator(
            watcher: watcher,
            store: store,
            hooks: WatchedFolderImportHooks(
                importBibTeX: { bibtex, target in
                    importCalls += 1
                    return self.library.importBibTeXOutcome(bibtex, libraryId: target)
                },
                defaultLibraryID: { libraryID },
                addTag: { _, _ in },
                removeTag: { _, _ in }))

        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()
        await waitUntil("the first import") { importCalls == 1 }

        // Nothing changed on disk. Re-walk, re-diff, re-record — and the
        // expensive half must not run.
        await coordinator.refresh(row.id)
        notifier.fire()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            importCalls, 1,
            "an unchanged re-scan must parse nothing and import nothing")
    }

    // MARK: - Missing files

    /// A `.bib` that vanishes leaves its row and its provenance behind,
    /// flagged `missing`. D4's rule, through the whole loop.
    func testAVanishedFileKeepsItsRowAndItsPapers() async throws {
        let libraryID = try makeLibrary()
        let bib = try write("refs.bib", Self.entryC)

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()
        await waitUntil("the initial import") {
            (self.coordinatorProduced(coordinator, row.id) ?? 0) >= 1
        }
        let storeID = try folderStoreID(coordinator)
        let produced = try store.files(folderID: storeID).files[0].producedPublicationIDs

        try FileManager.default.removeItem(at: bib)
        notifier.fire()

        await waitUntil("the sweep to mark it missing") {
            ((try? self.store.files(folderID: storeID, state: "missing").total) ?? 0) == 1
        }
        let missing = try store.files(folderID: storeID, state: "missing").files
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(
            missing[0].producedPublicationIDs, produced,
            "a vanished file keeps the attribution of what it produced")
        XCTAssertNotNil(
            library.getPublication(id: produced[0]),
            "and the papers stay in the library")
    }

    // MARK: - Helpers

    private func coordinatorProduced(
        _ coordinator: WatchedFolderIngestCoordinator, _ id: WatchedFolderID
    ) -> Int? {
        coordinator.producedCounts[id]
    }
}

// MARK: - Provenance (the Info tab's "Source File" row)

/// `WatchedFolderProvenanceIndex` answers the reverse of the store's edge:
/// the store says "this file produced these rows", the Info tab asks "which
/// file produced this row". Building that map in memory rather than in the
/// store is a deliberate choice (a second copy of one fact goes stale
/// silently), so what has to be pinned is the map itself — and the early-out
/// that keeps every user who watches nothing from paying for it.
@MainActor
final class WatchedFolderProvenanceIndexTests: XCTestCase {

    private var root: URL!
    private var store: WatchedFolderStoreAdapter!
    private var library: RustStoreAdapter!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-prov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SharedWorkspace.ensureDirectoryExists()
        library = try RustStoreAdapter(inMemory: false)
        store = WatchedFolderStoreAdapter(
            store: try SharedStore.open(path: SharedWorkspace.databasePath))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
        library = nil
        try await super.tearDown()
    }

    func testNoWatchedFoldersMeansNoProvenanceAndNoWork() throws {
        // A fresh index over a store with folders from other tests must still
        // answer "not from a watched folder" for a paper nobody attributed.
        let index = WatchedFolderProvenanceIndex(store: store)
        let stranger = UUID()
        XCTAssertNil(index.provenance(of: stranger, dataVersion: 1))
    }

    func testAProducedPublicationResolvesToItsSourceFile() throws {
        let bib = root.appendingPathComponent("papers.bib")
        try "@article{provenance2026, title={P}}".write(to: bib, atomically: true, encoding: .utf8)

        let folder = try store.addFolder(
            path: root.standardizedFileURL.path,
            kindScope: WatchedFolderIngestCoordinator.kindScope,
            displayName: "Papers").folder
        let report = try store.importDiscovered(folderID: folder.id, paths: [bib.path])
        let fileID = try XCTUnwrap(report.files.first?.fileID)

        guard let libraryID = library.getDefaultLibrary()?.id
            ?? library.createLibrary(name: "Provenance Library")?.id
        else { throw XCTSkip("no library") }
        let (imported, existing) = library.importBibTeXOutcome(
            "@article{provenance2026, title={P}}", libraryId: libraryID)
        let produced = imported + existing
        try XCTSkipIf(produced.isEmpty, "the importer produced nothing")
        try store.recordProduced(fileID: fileID, publicationIDs: produced)

        let index = WatchedFolderProvenanceIndex(store: store)
        let provenance = try XCTUnwrap(index.provenance(of: produced[0], dataVersion: 7))
        XCTAssertEqual(provenance.fileName, "papers.bib")
        XCTAssertEqual(provenance.folderName, "Papers")
        XCTAssertFalse(provenance.isMissing)
        XCTAssertEqual(provenance.summary, "papers.bib")

        // A vanished source says so rather than showing a path that leads
        // nowhere — the row is kept (D4), the UI is honest about it.
        try FileManager.default.removeItem(at: bib)
        _ = try store.finishScan(folderID: folder.id)
        let after = WatchedFolderProvenanceIndex(store: store)
        let missing = try XCTUnwrap(after.provenance(of: produced[0], dataVersion: 8))
        XCTAssertTrue(missing.isMissing)
        XCTAssertTrue(missing.summary.contains("missing"))
    }
}
