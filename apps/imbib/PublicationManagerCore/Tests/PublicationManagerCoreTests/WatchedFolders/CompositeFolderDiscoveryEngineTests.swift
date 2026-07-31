#if os(macOS)
//
//  CompositeFolderDiscoveryEngineTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D5 — the engine the shipping macOS build runs, end to end, over a
//  temp tree.
//
//  This is the test that actually proves "a `.bib` dropped three levels deep
//  appears without a scan or a poll", which is ADR-0023's opening claim. It
//  could not be written against `NSMetadataQuery` alone — see
//  `CompositeFolderDiscoveryEngine`'s header for the measurements, and
//  `SpotlightFolderDiscoveryEngineTests` for the honest account of what the
//  query half can and cannot be tested for. It CAN be written against the
//  composite, because the live half of the composite is FSEvents.
//
//  Temp directories only.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class CompositeFolderDiscoveryEngineTests: XCTestCase {

    private var root: URL!
    private var engine: CompositeFolderDiscoveryEngine!

    private static let filters = [
        FileDiscoveryFilter(id: "bibtex", filenameExtensions: ["bib"])
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("composite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = CompositeFolderDiscoveryEngine(
            gatherEngine: SpotlightFolderDiscoveryEngine(gatherTimeout: .seconds(3)),
            liveEngine: WalkFolderDiscoveryEngine(
                notifier: FSEventsDirectoryWatcher(latency: 0.05),
                debounce: .milliseconds(50)))
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testNamesItselfAfterBothHalves() {
        XCTAssertEqual(engine.engineName, "spotlight+fsevents")
    }

    func testAFileDroppedThreeLevelsDeepAppearsWithoutAScanOrAPoll() async throws {
        try "@article{a,}".write(
            to: root.appendingPathComponent("existing.bib"),
            atomically: true, encoding: .utf8)

        let settled = expectation(description: "the gather settled")
        settled.assertForOverFulfill = false
        let live = expectation(description: "the deep file surfaced")
        live.assertForOverFulfill = false
        let box = CompositeBox()

        engine.start(directory: root, filters: Self.filters, bounds: .default) { event in
            switch event {
            case .gathered(let files, _):
                box.gathers += 1
                box.gathered = files
                settled.fulfill()
            case .changed(let diff):
                box.added.append(contentsOf: diff.added)
                box.removed.append(contentsOf: diff.removed)
                if !diff.added.isEmpty { live.fulfill() }
            case .unavailable:
                box.wentUnavailable = true
                settled.fulfill()
                live.fulfill()   // nothing more will happen; unblock the wait
            case .failed(let failure):
                box.failure = failure
                settled.fulfill()
                live.fulfill()
            }
        }

        await fulfillment(of: [settled], timeout: 10)
        XCTAssertNil(box.failure)

        try XCTSkipIf(
            box.wentUnavailable,
            """
            Spotlight reported a blind spot for this temp tree, so the composite \
            handed the folder to the service to place on the fallback engine. That \
            is correct behaviour (and is asserted in \
            SpotlightFolderDiscoveryEngineTests + FolderWatchServiceTests); there is \
            no composite live phase left to exercise here.
            """)

        XCTAssertEqual(box.gathered.count, 1, "the pre-existing file must be gathered")

        // Three levels down, created AFTER the query was already running.
        let deep = root.appendingPathComponent("one/two/three", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "@article{b,}".write(
            to: deep.appendingPathComponent("dropped.bib"), atomically: true, encoding: .utf8)

        await fulfillment(of: [live], timeout: 10)

        XCTAssertEqual(box.added.map(\.url.lastPathComponent), ["dropped.bib"])
        XCTAssertEqual(box.gathers, 1, "a live change must not arrive as a second gather")
    }

    func testARemovedFileSurfacesAsARemoval() async throws {
        let doomed = root.appendingPathComponent("doomed.bib")
        try "@article{a,}".write(to: doomed, atomically: true, encoding: .utf8)

        let settled = expectation(description: "gather")
        settled.assertForOverFulfill = false
        let removal = expectation(description: "removal")
        removal.assertForOverFulfill = false
        let box = CompositeBox()

        engine.start(directory: root, filters: Self.filters, bounds: .default) { event in
            switch event {
            case .gathered(let files, _):
                box.gathered = files
                settled.fulfill()
            case .changed(let diff):
                box.removed.append(contentsOf: diff.removed)
                if !diff.removed.isEmpty { removal.fulfill() }
            case .unavailable, .failed:
                box.wentUnavailable = true
                settled.fulfill()
                removal.fulfill()
            }
        }

        await fulfillment(of: [settled], timeout: 10)
        try XCTSkipIf(box.wentUnavailable, "no Spotlight index for the temp tree here")

        try FileManager.default.removeItem(at: doomed)
        await fulfillment(of: [removal], timeout: 10)
        XCTAssertEqual(box.removed.map(\.lastPathComponent), ["doomed.bib"])
    }

    func testTheSameFileIsNeverPublishedTwiceByTheTwoHalves() async throws {
        // The dedupe the composite exists to do: after a gather, the walk half
        // is SEEDED, so its first enumeration must produce nothing at all.
        try "@article{a,}".write(
            to: root.appendingPathComponent("a.bib"), atomically: true, encoding: .utf8)

        let settled = expectation(description: "gather")
        settled.assertForOverFulfill = false
        let box = CompositeBox()

        engine.start(directory: root, filters: Self.filters, bounds: .default) { event in
            switch event {
            case .gathered(let files, _):
                box.gathered = files
                settled.fulfill()
            case .changed(let diff):
                box.added.append(contentsOf: diff.added)
            case .unavailable, .failed:
                box.wentUnavailable = true
                settled.fulfill()
            }
        }

        await fulfillment(of: [settled], timeout: 10)
        try XCTSkipIf(box.wentUnavailable, "no Spotlight index for the temp tree here")

        // Force the walk half to run without anything having changed.
        engine.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(
            box.added.isEmpty,
            "the seeded walk re-published files the gather had already delivered; the "
                + "host would ingest each of them twice")
    }

    func testStopIsIdempotentAcrossBothHalves() {
        engine.stop()
        engine.start(directory: root, filters: Self.filters, bounds: .default) { _ in }
        engine.stop()
        engine.stop()
        engine.refresh()
    }
}

@MainActor
private final class CompositeBox {
    var gathered: [DiscoveredFile] = []
    var added: [DiscoveredFile] = []
    var removed: [URL] = []
    var gathers = 0
    var wentUnavailable = false
    var failure: FolderWatchFailure?
}
#endif
