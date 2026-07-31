#if os(macOS)
//
//  SpotlightFolderDiscoveryEngineTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D5 — the primary engine, and an honest account of what a headless
//  test can and cannot prove about it.
//
//  ── The honest answer on NSMetadataQuery testability ────────────────────────
//
//  It is worth being precise here, because the intuition ("Spotlight does not
//  index temp directories, so none of this is testable") turned out to be
//  WRONG in one direction and right in the other. What was actually measured,
//  headless, in this test process:
//
//    * **The gather works, and works beautifully.** A query scoped to a
//      `/var/folders/…` temp tree returned its matches in ~35 ms. `TMPDIR` on
//      this machine IS indexed (`mdutil -s /` → enabled; `mdfind -onlyin`
//      confirms), so the assertions below are real assertions about a real
//      query, not vacuous ones over an unindexed volume.
//    * **The live phase could not be observed working, at all.** With the query
//      still running and `enableUpdates()` called, a `.bib` created three
//      levels down produced no `NSMetadataQueryDidUpdate` within 30 s — and
//      re-reading `query.results` directly 12 s after creation still did not
//      contain it, while `mdfind -onlyin` returned it 8 s after creation. The
//      index had the file; the running query never saw it. Reproduced with and
//      without `query.operationQueue`, and with the main run loop spun
//      explicitly, so it is not an artefact of the async test host.
//
//  That second finding is a PRODUCT finding, not a testing one, and it is why
//  the shipping macOS engine is `CompositeFolderDiscoveryEngine`: Spotlight for
//  the gather (the half that measurably delivers), FSEvents + a bounded walk
//  for the live phase (verified end to end in
//  `CompositeFolderDiscoveryEngineTests` and `FSEventsDirectoryWatcherTests`).
//  `NSMetadataQueryDidUpdate` is still honoured when it arrives; nothing
//  depends on it.
//
//  So the coverage is split, and this file says which part is which:
//
//    1. **The predicate** — pure string derivation, pinned exhaustively in
//       `FileDiscoveryFilterTests`, on every platform.
//    2. **The gather + lifecycle + the blind-spot verdict** — here, against a
//       real `NSMetadataQuery`.
//    3. **Live discovery over real files** — `CompositeFolderDiscoveryEngineTests`
//       (the shipping macOS engine) and `FolderWatchServiceTests` (the whole
//       diff/batch/state pipeline, deterministically).
//
//  ── The test below is the useful one ────────────────────────────────────────
//
//  A temp directory that provably contains `.bib` files, watched by the real
//  Spotlight engine, must NEVER produce "gathered, 0 files". Either the engine
//  finds them (this machine indexes the temp hierarchy — the observed outcome)
//  or it reports the blind spot with its counterexample (a CI runner with
//  indexing off, an external volume, `mdutil -i off`). Both outcomes are
//  asserted, so the test is meaningful on any machine and vacuous on none —
//  which is the property that makes it worth having as a regression guard for
//  D6's risk-register entry.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class SpotlightFolderDiscoveryEngineTests: XCTestCase {

    private var root: URL!
    private var engine: SpotlightFolderDiscoveryEngine!

    private static let filters = [
        FileDiscoveryFilter(
            id: "bibtex",
            contentTypeIdentifiers: ["com.impress.bibtex-entry"],
            filenameExtensions: ["bib", "ris"])
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlight-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = SpotlightFolderDiscoveryEngine(gatherTimeout: .seconds(3))
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - The invariant that holds on any machine

    func testABlindQueryOverANonEmptyFolderNeverRendersAsAnEmptyFolder() async throws {
        // The risk register's second entry, reproduced: this directory
        // demonstrably holds two `.bib` files.
        try "@article{a,}".write(
            to: root.appendingPathComponent("a.bib"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "@article{b,}".write(
            to: nested.appendingPathComponent("b.bib"), atomically: true, encoding: .utf8)

        let settled = expectation(description: "the engine reached a verdict")
        settled.assertForOverFulfill = false
        let box = VerdictBox()

        engine.start(directory: root, filters: Self.filters, bounds: .default) { event in
            switch event {
            case .gathered(let files, _):
                box.gatheredCount = files.count
                settled.fulfill()
            case .unavailable(let probe):
                box.probe = probe
                settled.fulfill()
            case .failed(let failure):
                box.failure = failure
                settled.fulfill()
            case .changed:
                break
            }
        }

        // Generous: the gather timeout is 3 s and the local probe runs after it.
        await fulfillment(of: [settled], timeout: 10)

        XCTAssertNil(box.failure, "a readable directory with a valid predicate must not fail")

        if let probe = box.probe {
            // Spotlight cannot see /var/folders — the expected outcome, and the
            // one that proves the honest signal fires for real.
            XCTAssertTrue(
                probe.provesSpotlightBlindSpot,
                "the engine reported `unavailable` without the counterexample that "
                    + "justifies it")
            XCTAssertEqual(
                WatchedFolderStateResolver.resolve(
                    probe: probe, fallbackEngineAvailable: true),
                .fallback)
        } else {
            // The other legal outcome: this machine really does index the temp
            // hierarchy. Then the results must be the files that are there.
            XCTAssertGreaterThan(
                box.gatheredCount, 0,
                """
                The engine reported a completed gather of ZERO files over a directory \
                that contains two `.bib` files. That is the exact bug ADR-0023's risk \
                register calls out — an unindexed volume rendering as "0 files" — and \
                it means the blind-spot probe did not fire.
                """)
        }
    }

    // MARK: - Lifecycle and failure branches

    func testAnEmptyFilterSetFailsBeforeAQueryIsEverBuilt() {
        var failure: FolderWatchFailure?
        engine.start(directory: root, filters: [], bounds: .default) { event in
            if case .failed(let reason) = event { failure = reason }
        }
        XCTAssertEqual(failure, .noFilters)
    }

    func testAMissingDirectoryFailsAsNotADirectory() {
        var failure: FolderWatchFailure?
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        engine.start(directory: missing, filters: Self.filters, bounds: .default) { event in
            if case .failed(let reason) = event { failure = reason }
        }
        XCTAssertEqual(failure, .notADirectory(path: missing.path))
    }

    func testAFileInsteadOfADirectoryFailsRatherThanWatchingItsParent() throws {
        let file = root.appendingPathComponent("a.bib")
        try "@article{a,}".write(to: file, atomically: true, encoding: .utf8)

        var failure: FolderWatchFailure?
        engine.start(directory: file, filters: Self.filters, bounds: .default) { event in
            if case .failed(let reason) = event { failure = reason }
        }
        XCTAssertEqual(failure, .notADirectory(path: file.path))
    }

    func testStopAndRefreshAreSafeBeforeAndAfterAQueryRuns() {
        // `stop()` must be idempotent (the protocol says so) and `refresh()`
        // on a stopped engine must be a no-op rather than a crash — the row's
        // Refresh verb can arrive at any moment.
        engine.stop()
        engine.refresh()
        engine.start(directory: root, filters: Self.filters, bounds: .default) { _ in }
        engine.refresh()
        engine.stop()
        engine.stop()
        engine.refresh()
    }

    func testTheEngineNamesItselfSoTheServiceCanReportWhichOneWon() {
        XCTAssertEqual(engine.engineName, "spotlight")
    }
}

@MainActor
private final class VerdictBox {
    var gatheredCount = 0
    var probe: SpotlightAvailabilityProbe?
    var failure: FolderWatchFailure?
}
#endif
