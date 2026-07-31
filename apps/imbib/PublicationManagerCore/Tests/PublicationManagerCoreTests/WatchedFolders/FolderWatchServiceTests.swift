//
//  FolderWatchServiceTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 W1 — the service's policy: which engine, when to gather, how to
//  batch, what state to publish.
//
//  Everything here runs against the WALK engine driven by
//  `ManualDirectoryChangeNotifier`. That is deliberate and is the honest
//  arrangement, not a shortcut: see `SpotlightFolderDiscoveryEngineTests` for
//  why `NSMetadataQuery` cannot be exercised end-to-end in `swift test`. The
//  walk engine is the fallback D6 requires, the notifier seam is the exact
//  sequence a real FSEvents callback triggers (notify → re-walk → diff →
//  publish), and `FSEventsDirectoryWatcherTests` covers the real stream on its
//  own.
//
//  Temp directories only. Nothing here touches a user folder or the real store.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class FolderWatchServiceTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var notifier: ManualDirectoryChangeNotifier!
    private var collector: EventCollector!
    private var collectorTask: Task<Void, Never>?

    private static let bibFilter = FileDiscoveryFilter(
        id: "bibtex", filenameExtensions: ["bib", "ris"])
    private static let textFilter = FileDiscoveryFilter(
        id: "text", contentTypeIdentifiers: ["public.plain-text"])

    override func setUp() async throws {
        suiteName = "test.folderWatchService.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-watch-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        notifier = ManualDirectoryChangeNotifier()
        collector = EventCollector()
    }

    override func tearDown() async throws {
        collectorTask?.cancel()
        collectorTask = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        notifier = nil
        collector = nil
    }

    // MARK: - Fixtures

    @discardableResult
    private func write(_ relativePath: String, contents: String = "@article{x,}") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeService(
        gate: FolderWatchStartupGate = .immediate,
        maxBatchSize: Int = DiscoveryBatcher.defaultMaxBatchSize,
        bounds: FolderWalkBounds = .default,
        engines: FolderWatchEngineFactory? = nil
    ) -> FolderWatchService {
        // One collector at a time: the "relaunch" tests build a second service
        // over the same defaults and only the second one's events matter.
        collectorTask?.cancel()
        let notifier = self.notifier!
        let service = FolderWatchService(
            bookmarks: WatchedFolderBookmarkStore(
                userDefaults: defaults, broker: .scratch()),
            engines: engines ?? FolderWatchEngineFactory(
                makePrimary: { nil },
                makeFallback: {
                    WalkFolderDiscoveryEngine(notifier: notifier, debounce: .milliseconds(1))
                }),
            startupGate: gate,
            bounds: bounds,
            maxBatchSize: maxBatchSize)
        let stream = service.events()
        let collector = self.collector!
        collectorTask = Task { @MainActor in
            for await event in stream { collector.append(event) }
        }
        return service
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: - Initial gather

    func testInitialGatherFindsNestedMatchesByExtensionAndByUTI() async throws {
        try write("top.bib")
        try write("nested/deeper/bottom.ris")
        try write("nested/notes.txt", contents: "plain")

        let service = makeService()
        let registration = WatchedFolderRegistration(
            url: root, filters: [Self.bibFilter, Self.textFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("the gather to finish") {
            service.files(in: registration.id).count == 3
        }

        let byFilter = Dictionary(
            grouping: service.files(in: registration.id), by: \.filterID
        ).mapValues(\.count)
        XCTAssertEqual(byFilter["bibtex"], 2)
        XCTAssertEqual(byFilter["text"], 1)
    }

    func testGatherPublishesABatchedTerminatedSequence() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("a final gather batch") { self.collector.finalGatherBatchCount == 1 }
        XCTAssertEqual(self.collector.gatheredFiles.count, 1)
    }

    func testAnEmptyFolderStillPublishesAFinalBatch() async throws {
        // The terminator rule: a consumer's state machine must be able to tell
        // "finished, found nothing" from "never finished".
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("a final gather batch") { self.collector.finalGatherBatchCount == 1 }
        XCTAssertTrue(self.collector.gatheredFiles.isEmpty)
    }

    // MARK: - Batch bounds (D7)

    func testGatherIsChunkedToTheConfiguredBatchSize() async throws {
        for index in 0..<5 { try write("f\(index).bib") }

        let service = makeService(maxBatchSize: 2)
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("a final gather batch") { self.collector.finalGatherBatchCount == 1 }

        let batches = collector.gatherBatches
        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        XCTAssertEqual(batches.count, 3)
        XCTAssertTrue(
            collector.gatherBatchIndices == [0, 1, 2],
            "batch indices must be contiguous and 0-based; a consumer resumes on them")
    }

    func testBatcherIsPureAndBoundedIndependentlyOfTheService() {
        let files = (0..<1001).map {
            DiscoveredFile(url: URL(fileURLWithPath: "/tmp/\($0).bib"), filterID: "bibtex")
        }
        let batches = DiscoveryBatcher.batches(files)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches.map(\.count), [500, 500, 1])
        XCTAssertEqual(DiscoveryBatcher.batches([]).count, 1, "empty yields one empty batch")
        XCTAssertEqual(DiscoveryBatcher.batches(files, maxBatchSize: 0).first?.count, 1,
                       "a zero batch size clamps to 1 rather than dividing by zero")
    }

    // MARK: - Live updates

    func testLiveUpdateFiresWhenAFileIsAdded() async throws {
        try write("existing.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)
        await waitUntil("the initial gather") { service.files(in: registration.id).count == 1 }

        try write("nested/added.bib")
        notifier.fire()

        await waitUntil("the added file to surface") {
            service.files(in: registration.id).count == 2
        }
        XCTAssertEqual(collector.addedURLs.map(\.lastPathComponent), ["added.bib"])
        XCTAssertTrue(collector.removedURLs.isEmpty)
    }

    func testLiveUpdateFiresWhenAFileIsRemoved() async throws {
        let doomed = try write("doomed.bib")
        try write("survivor.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)
        await waitUntil("the initial gather") { service.files(in: registration.id).count == 2 }

        try FileManager.default.removeItem(at: doomed)
        notifier.fire()

        await waitUntil("the removal to surface") {
            service.files(in: registration.id).count == 1
        }
        XCTAssertEqual(collector.removedURLs.map(\.lastPathComponent), ["doomed.bib"])
    }

    func testTouchingAFileIsNotRepublishedAsAnAddition() async throws {
        let file = try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)
        await waitUntil("the initial gather") { service.files(in: registration.id).count == 1 }

        try "@article{y,}".write(to: file, atomically: true, encoding: .utf8)
        notifier.fire()
        // Give the debounce + re-walk a window in which it COULD misbehave.
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(
            collector.addedURLs.isEmpty,
            "re-scan diffing is hash-keyed in Rust (D4); a touched file must not "
                + "arrive as new")
    }

    func testNewSinceLastVisitAccumulatesAndMarkSeenClearsIt() async throws {
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)
        await waitUntil("the initial gather") {
            self.collector.finalGatherBatchCount == 1
        }

        try write("one.bib")
        notifier.fire()
        await waitUntil("the badge to rise") {
            service.row(for: registration.id)?.newSinceLastVisit == 1
        }

        service.markSeen(registration.id)
        XCTAssertEqual(service.row(for: registration.id)?.newSinceLastVisit, 0)
    }

    // MARK: - States (D6)

    func testAWalkOnlyServiceReportsFallbackNotLive() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("the fallback state") {
            service.row(for: registration.id)?.state == .fallback
        }
        XCTAssertEqual(service.engineName(for: registration.id), "walk+manual")
        XCTAssertTrue(
            collector.states.contains(.fallback),
            "a state transition must be published, not only stored")
    }

    func testAFolderWithNoEnginesIsScanOnDemandNotAFailure() async throws {
        try write("a.bib")
        let service = makeService(engines: .none)
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        XCTAssertEqual(service.row(for: registration.id)?.state, .scanOnDemand)
        XCTAssertNil(service.row(for: registration.id)?.badgeCount)
    }

    func testAFolderWithNoFiltersFailsVisiblyRatherThanWatchingEverything() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [])
        service.add(registration)
        await service.start(registration.id)

        XCTAssertEqual(service.row(for: registration.id)?.state, .scanOnDemand)
        await waitUntil("the noFilters failure to be published") {
            self.collector.failures.contains(.noFilters)
        }
        XCTAssertTrue(service.files(in: registration.id).isEmpty)
    }

    func testAMissingDirectoryIsInaccessibleNotEmpty() async throws {
        let service = makeService()
        let registration = WatchedFolderRegistration(
            url: root.appendingPathComponent("gone", isDirectory: true),
            filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("the inaccessible state") {
            service.row(for: registration.id)?.state == .inaccessible(bookmarkStale: false)
        }
        let row = try XCTUnwrap(service.row(for: registration.id))
        XCTAssertNil(row.badgeCount, "a folder we cannot open makes no claim about counts")
        XCTAssertFalse(row.offersRefresh)
        XCTAssertTrue(row.offersReauthorization)
    }

    func testATruncatedWalkSuppressesTheBadgeRatherThanUnderreporting() async throws {
        for index in 0..<10 { try write("f\(index).bib") }
        let service = makeService(bounds: FolderWalkBounds(maxDepth: 2, maxFiles: 3))
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("the truncated gather") {
            service.row(for: registration.id)?.countIsPartial == true
        }
        let row = try XCTUnwrap(service.row(for: registration.id))
        XCTAssertEqual(row.discoveredCount, 3)
        XCTAssertNil(row.badgeCount, "\"3\" would be a lie about a folder holding 10")
        XCTAssertTrue(row.statusLine.contains("first 3"))
    }

    // MARK: - Startup discipline (D7)

    func testTheStartupWindowDefersTheFirstGather() async throws {
        try write("a.bib")
        // A 90-second window that opened a moment ago: the gather must not run.
        let service = makeService(
            gate: FolderWatchStartupGate(
                graceSeconds: 90, launchDate: Date(), isAttachedToLiveAppContext: true))
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)

        let task = Task { await service.start(registration.id) }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(
            service.files(in: registration.id).isEmpty,
            "a background service that publishes during the first 90s is the render-loop bug")
        XCTAssertEqual(collector.gatherBatches.count, 0)
        task.cancel()
    }

    func testAWindowThatAlreadyClosedDoesNotDefer() async throws {
        try write("a.bib")
        let service = makeService(
            gate: FolderWatchStartupGate(
                graceSeconds: 90,
                launchDate: Date().addingTimeInterval(-120),
                isAttachedToLiveAppContext: true))
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)

        await waitUntil("the gather") { service.files(in: registration.id).count == 1 }
    }

    func testTheGateIsPureAndAskableWithoutSleeping() {
        let now = Date()
        let gate = FolderWatchStartupGate(graceSeconds: 90, launchDate: now)
        XCTAssertFalse(gate.permitsInitialGather(asOf: now))
        XCTAssertEqual(gate.remaining(asOf: now), 90, accuracy: 0.01)
        XCTAssertTrue(gate.permitsInitialGather(asOf: now.addingTimeInterval(91)))

        // A headless host has no settling UI to protect.
        let headless = FolderWatchStartupGate(
            graceSeconds: 90, launchDate: now, isAttachedToLiveAppContext: false)
        XCTAssertTrue(headless.permitsInitialGather(asOf: now))
        XCTAssertTrue(FolderWatchStartupGate.immediate.permitsInitialGather(asOf: now))

        // The default must be the SAFE direction: assume there is a UI.
        XCTAssertTrue(FolderWatchStartupGate().isAttachedToLiveAppContext)
        XCTAssertEqual(FolderWatchStartupGate.defaultGraceSeconds, 90)
    }

    // MARK: - Refresh and lifecycle

    func testRefreshOnAnAlreadyGatheredFolderPublishesADiffNotASecondGather() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)
        await waitUntil("the initial gather") { self.collector.finalGatherBatchCount == 1 }

        try write("b.bib")
        await service.refresh(registration.id)

        await waitUntil("the refresh diff") { self.collector.addedURLs.count == 1 }
        XCTAssertEqual(
            collector.finalGatherBatchCount, 1,
            "a consumer that already ingested these paths must not be handed them again")
    }

    func testRefreshOnAStoppedFolderStartsItAgain() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(url: root, filters: [Self.bibFilter])
        service.add(registration)
        await service.start(registration.id)
        await waitUntil("the initial gather") { service.files(in: registration.id).count == 1 }

        service.stop(registration.id)
        XCTAssertNil(service.engineName(for: registration.id))

        await service.refresh(registration.id)
        await waitUntil("the engine to come back") {
            service.engineName(for: registration.id) != nil
        }
    }

    func testADisabledFolderKeepsItsRowAndRunsNoEngine() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = WatchedFolderRegistration(
            url: root, filters: [Self.bibFilter], isEnabled: false)
        service.add(registration)
        await service.start(registration.id)

        let row = try XCTUnwrap(service.row(for: registration.id))
        XCTAssertNil(service.engineName(for: registration.id))
        XCTAssertFalse(row.isEnabled)
        XCTAssertFalse(row.offersRefresh)
        XCTAssertEqual(row.statusLine, "Paused")
    }

    func testRowsFollowRegistrationOrder() async throws {
        let service = makeService()
        let other = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let first = WatchedFolderRegistration(
            url: root, displayName: "First", filters: [Self.bibFilter])
        let second = WatchedFolderRegistration(
            url: other, displayName: "Second", filters: [Self.bibFilter])
        service.add(first)
        service.add(second)

        XCTAssertEqual(service.rows.map(\.displayName), ["First", "Second"])
    }

    // MARK: - Persistence integration

    func testPersistAndRestoreReproducesTheRegistrationsAcrossLaunches() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = try await service.persistAndAdd(
            url: root, filters: [Self.bibFilter], displayName: "Papers")

        // "Relaunch": a brand-new service over the same defaults.
        let relaunched = makeService()
        let restored = await relaunched.restorePersistedFolders(
            filtersByID: [Self.bibFilter.id: Self.bibFilter])

        XCTAssertEqual(restored.map(\.id), [registration.id])
        XCTAssertEqual(restored.first?.displayName, "Papers")

        await relaunched.start(registration.id)
        await waitUntil("the restored folder to gather") {
            relaunched.files(in: registration.id).count == 1
        }
    }

    func testARestoredFolderWhoseFilterIDsNoLongerResolveIsVisiblyBroken() async throws {
        try write("a.bib")
        let service = makeService()
        let registration = try await service.persistAndAdd(
            url: root, filters: [Self.bibFilter])

        let relaunched = makeService()
        // The host's filter table no longer contains "bibtex" — a kind was
        // renamed or dropped.
        _ = await relaunched.restorePersistedFolders(filtersByID: [:])
        await relaunched.start(registration.id)

        XCTAssertEqual(relaunched.row(for: registration.id)?.state, .scanOnDemand)
        await waitUntil(
            "the restored folder to declare that it watches for nothing"
        ) {
            self.collector.failures.contains(.noFilters)
        }
    }
}

// MARK: - Event collection

/// Accumulates the service's stream so a test can assert on it after the fact.
@MainActor
final class EventCollector {

    private(set) var events: [FolderWatchEvent] = []

    func append(_ event: FolderWatchEvent) { events.append(event) }

    var gatherBatches: [[DiscoveredFile]] {
        events.compactMap {
            if case .gatheredBatch(_, let files, _, _) = $0 { return files }
            return nil
        }
    }

    var gatherBatchIndices: [Int] {
        events.compactMap {
            if case .gatheredBatch(_, _, let index, _) = $0 { return index }
            return nil
        }
    }

    var finalGatherBatchCount: Int {
        events.filter {
            if case .gatheredBatch(_, _, _, let isFinal) = $0 { return isFinal }
            return false
        }.count
    }

    var gatheredFiles: [DiscoveredFile] { gatherBatches.flatMap { $0 } }

    var addedURLs: [URL] {
        events.flatMap { event -> [URL] in
            if case .filesAdded(_, let files) = event { return files.map(\.url) }
            return []
        }
    }

    var removedURLs: [URL] {
        events.flatMap { event -> [URL] in
            if case .filesRemoved(_, let urls) = event { return urls }
            return []
        }
    }

    var states: [WatchedFolderState] {
        events.compactMap {
            if case .stateChanged(_, let state) = $0 { return state }
            return nil
        }
    }

    var failures: [FolderWatchFailure] {
        events.compactMap {
            if case .failed(_, let failure) = $0 { return failure }
            return nil
        }
    }
}
