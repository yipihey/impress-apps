#if os(macOS)
//
//  FSEventsDirectoryWatcherTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D6 — the FSEvents adapter, exercised for real.
//
//  This one DOES work headless, unlike `NSMetadataQuery` (see
//  `SpotlightFolderDiscoveryEngineTests`): FSEvents is a kernel-backed
//  notification service with no index behind it, it works on `/var/folders`
//  temp directories, and `FSEventStreamSetDispatchQueue` means it needs no
//  run loop. So the fallback engine's live path is covered by a real stream
//  here, and by `ManualDirectoryChangeNotifier` in `FolderWatchServiceTests`
//  where determinism matters more than fidelity.
//
//  Timeouts are generous (5 s against a 0.2 s coalescing latency) because this
//  is the one suite whose timing depends on a system daemon.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class FSEventsDirectoryWatcherTests: XCTestCase {

    private var root: URL!
    private var watcher: FSEventsDirectoryWatcher!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsevents-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        watcher = FSEventsDirectoryWatcher(latency: 0.05)
    }

    override func tearDown() async throws {
        watcher?.stopWatching()
        watcher = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testStartWatchingSucceedsForARealDirectory() {
        XCTAssertTrue(watcher.startWatching(root) {})
    }

    func testAFileCreatedAtTheRootRaisesAChange() async throws {
        let fired = expectation(description: "FSEvents raised a change")
        fired.assertForOverFulfill = false
        XCTAssertTrue(watcher.startWatching(root) { fired.fulfill() })

        try "@article{x,}".write(
            to: root.appendingPathComponent("a.bib"), atomically: true, encoding: .utf8)

        await fulfillment(of: [fired], timeout: 5)
    }

    func testAFileCreatedThreeLevelsDeepRaisesAChange() async throws {
        // The whole reason ADR-0023 names FSEvents rather than
        // `DispatchSource.makeFileSystemObjectSource`: the latter fires only
        // for DIRECT children, so the ".bib dropped three levels deep" case —
        // the ADR's opening scenario — would produce no event at all.
        let nested = root
            .appendingPathComponent("one/two/three", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let fired = expectation(description: "a deep change was seen")
        fired.assertForOverFulfill = false
        XCTAssertTrue(watcher.startWatching(root) { fired.fulfill() })

        try "@article{x,}".write(
            to: nested.appendingPathComponent("deep.bib"), atomically: true, encoding: .utf8)

        await fulfillment(of: [fired], timeout: 5)
    }

    func testStopWatchingIsIdempotentAndSilencesTheStream() async throws {
        var fireCount = 0
        XCTAssertTrue(watcher.startWatching(root) { fireCount += 1 })
        watcher.stopWatching()
        watcher.stopWatching()

        try "x".write(
            to: root.appendingPathComponent("after-stop.bib"),
            atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(fireCount, 0, "a stopped stream must not deliver into a dead handler")
    }

    func testWatchingAMissingDirectoryDoesNotCrashTheCaller() {
        // FSEvents accepts a path that does not exist (it watches for it to
        // appear); what matters is that the adapter returns a definite answer
        // and leaves nothing running.
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        _ = watcher.startWatching(missing) {}
        watcher.stopWatching()
    }

    func testTheWalkEngineRePublishesThroughARealFSEventsStream() async throws {
        // End-to-end over the fallback engine: real stream → debounce →
        // re-walk → diff → `.changed`.
        let engine = WalkFolderDiscoveryEngine(
            notifier: FSEventsDirectoryWatcher(latency: 0.05),
            debounce: .milliseconds(50))
        let filters = [FileDiscoveryFilter(id: "bibtex", filenameExtensions: ["bib"])]

        let gathered = expectation(description: "initial gather")
        let changed = expectation(description: "live change")
        changed.assertForOverFulfill = false
        let box = EventBox()

        engine.start(directory: root, filters: filters, bounds: .default) { event in
            switch event {
            case .gathered(let files, _):
                box.gathered = files
                gathered.fulfill()
            case .changed(let diff):
                box.added.append(contentsOf: diff.added)
                changed.fulfill()
            default:
                break
            }
        }

        await fulfillment(of: [gathered], timeout: 5)
        XCTAssertTrue(box.gathered.isEmpty)

        try "@article{x,}".write(
            to: root.appendingPathComponent("live.bib"), atomically: true, encoding: .utf8)

        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(box.added.map(\.url.lastPathComponent), ["live.bib"])
        engine.stop()
    }
}

@MainActor
private final class EventBox {
    var gathered: [DiscoveredFile] = []
    var added: [DiscoveredFile] = []
}
#endif
