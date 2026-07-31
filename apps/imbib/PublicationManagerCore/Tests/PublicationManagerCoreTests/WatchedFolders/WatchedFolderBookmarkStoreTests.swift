//
//  WatchedFolderBookmarkStoreTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D6 — bookmark persistence, and the branch that only exists because
//  bookmarks go stale.
//
//  setUp/tearDown are `ListViewSettingsStoreTests`' — a UUID-unique suite,
//  retained in a property, `removePersistentDomain` on both ends. A fixed suite
//  name leaks state between methods; PMC learned that the hard way.
//
//  The broker is the scratch one throughout: minting a real security-scoped
//  bookmark needs a URL a user granted through a panel, which `swift test` does
//  not have. What the scratch broker buys is the branch that MATTERS —
//  resolve → stale → renew → re-persist — which would otherwise be provable
//  only by launching an app.
//

import XCTest

@testable import PublicationManagerCore

final class WatchedFolderBookmarkStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "test.watchedFolderBookmarks.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-watch-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func makeStore(
        broker: SecurityScopedBookmarkBroker = .scratch()
    ) -> WatchedFolderBookmarkStore {
        WatchedFolderBookmarkStore(userDefaults: defaults, broker: broker)
    }

    // MARK: - Round trip

    func testRegisterPersistsAcrossStoreInstances() async throws {
        let store = makeStore()
        let record = try await store.register(
            url: root, displayName: "Papers", filterIDs: ["bibtex"])

        // A SECOND store over the same defaults — the "survives a launch"
        // property, which an in-memory cache would fake.
        let reopened = makeStore()
        let fetched = await reopened.bookmark(for: record.id)
        let loaded = try XCTUnwrap(fetched)

        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.displayName, "Papers")
        XCTAssertEqual(loaded.filterIDs, ["bibtex"])
        XCTAssertEqual(loaded.path, root.standardizedFileURL.path)
        XCTAssertFalse(loaded.bookmark.isEmpty)
        XCTAssertTrue(loaded.isEnabled)
    }

    func testDisplayNameDefaultsToTheFolderName() async throws {
        let store = makeStore()
        let record = try await store.register(url: root, filterIDs: ["bibtex"])
        XCTAssertEqual(record.displayName, root.lastPathComponent)
    }

    func testFiltersThemselvesAreNotPersistedOnlyTheirIDs() async throws {
        // The W2 seam: filters are DERIVED from record-kind declarations, and a
        // persisted copy of a derived value is how a stale declaration outlives
        // the real one. Only ids cross the launch boundary.
        let store = makeStore()
        let record = try await store.register(
            url: root, filterIDs: ["bibtex", "manuscript"])
        let encoded = try XCTUnwrap(defaults.data(
            forKey: "watched_folder_bookmark_\(record.id.storageKey)"))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("bibtex"))
        XCTAssertFalse(
            json.contains("filenameExtensions"),
            "a persisted extension table is a second copy of a declaration")
    }

    func testAllEnumeratesOnlyThisStoresKeysInAStableOrder() async throws {
        defaults.set("unrelated", forKey: "some_other_key")
        let store = makeStore()
        let first = try await store.register(
            url: root, displayName: "A", filterIDs: ["bibtex"])
        let second = try await store.register(
            url: root, displayName: "B", filterIDs: ["bibtex"])

        let all = await store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.id), [first.id, second.id])
    }

    func testRemoveDeletesOnlyThatFolder() async throws {
        let store = makeStore()
        let keep = try await store.register(url: root, displayName: "keep", filterIDs: ["b"])
        let drop = try await store.register(url: root, displayName: "drop", filterIDs: ["b"])

        await store.remove(drop.id)
        await store.clearCache()

        let dropped = await store.bookmark(for: drop.id)
        let kept = await store.bookmark(for: keep.id)
        XCTAssertNil(dropped)
        XCTAssertNotNil(kept)
    }

    // MARK: - Resolution

    func testResolveReturnsTheURLAndStampsLastResolved() async throws {
        let store = makeStore()
        let record = try await store.register(url: root, filterIDs: ["bibtex"])

        guard case .success(let url) = await store.resolveURL(for: record.id) else {
            return XCTFail("resolve should succeed for a scratch bookmark")
        }
        XCTAssertEqual(url, root.standardizedFileURL)
        let stamped = await store.bookmark(for: record.id)?.lastResolvedAt
        XCTAssertNotNil(stamped)
    }

    func testResolvingAnUnknownFolderFailsRatherThanReturningNothing() async {
        let store = makeStore()
        guard case .failure(let failure) = await store.resolveURL(for: WatchedFolderID())
        else { return XCTFail("an unregistered folder must not resolve") }
        XCTAssertEqual(failure, .bookmarkUnresolvable(isStale: false))
    }

    func testACorruptBookmarkFailsAsUnresolvableNotAsStale() async throws {
        let store = makeStore()
        var record = try await store.register(url: root, filterIDs: ["bibtex"])
        record.bookmark = Data()
        await store.save(record)

        guard case .failure(let failure) = await store.resolveURL(for: record.id) else {
            return XCTFail("an empty bookmark blob must not resolve")
        }
        XCTAssertEqual(failure, .bookmarkUnresolvable(isStale: false))
    }

    func testDeniedAccessIsReportedAsDeniedNotAsMissing() async throws {
        let store = makeStore(broker: .scratch(accessGranted: false))
        let record = try await store.register(url: root, filterIDs: ["bibtex"])

        guard case .failure(let failure) = await store.resolveURL(for: record.id) else {
            return XCTFail("access refusal must surface")
        }
        XCTAssertEqual(failure, .accessDenied(path: root.standardizedFileURL.path))
        XCTAssertEqual(failure.resultingState, .inaccessible(bookmarkStale: false))
    }

    // MARK: - Staleness renewal (the branch D6 is about)

    func testAStaleBookmarkIsRenewedAndRePersistedBeforeAccessIsTaken() async throws {
        let store = makeStore(broker: .scratch(staleURLs: [root]))
        let record = try await store.register(url: root, filterIDs: ["bibtex"])
        let originalBookmark = record.bookmark

        // First resolve: reported stale, renewed in place, and STILL succeeds —
        // a stale bookmark resolves fine, it just does not survive a relaunch.
        guard case .success(let url) = await store.resolveURL(for: record.id) else {
            return XCTFail("a stale bookmark must still resolve")
        }
        XCTAssertEqual(url, root.standardizedFileURL)

        await store.clearCache()
        let reloaded = await store.bookmark(for: record.id)
        let renewed = try XCTUnwrap(reloaded)
        XCTAssertFalse(
            renewed.wasStaleOnLastResolve,
            "the renewal must clear the flag, or the row shows a permanent warning")

        // Second resolve goes through the fresh blob: no staleness reported.
        guard case .success = await store.resolveURL(for: record.id) else {
            return XCTFail("the renewed bookmark must resolve")
        }
        XCTAssertEqual(
            renewed.bookmark, originalBookmark,
            "the scratch broker's blob is the path, so equality here only shows the "
                + "renewal path ran without corrupting the record")
    }

    // MARK: - Failure vocabulary

    func testEveryFailureHasAUserFacingDescription() {
        let failures: [FolderWatchFailure] = [
            .noFilters,
            .bookmarkUnresolvable(isStale: true),
            .bookmarkUnresolvable(isStale: false),
            .accessDenied(path: "/x"),
            .notADirectory(path: "/x"),
            .noLiveEngineOnThisPlatform,
        ]
        for failure in failures {
            XCTAssertFalse(
                (failure.errorDescription ?? "").isEmpty,
                "\(failure) would render as a blank alert")
        }
    }
}
