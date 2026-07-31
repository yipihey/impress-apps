#if os(macOS)
// Chassis file — macOS-only: the NSMetadataQuery engine, and only the engine.
// The protocol it implements, the events it publishes, the predicate string it
// runs and the probe that judges it are all cross-platform. This is the split
// `RecordViewerRegistry+Builtin.swift` established and
// `ChassisCrossPlatformContractTests` polices.
//
//  FolderDiscoveryEngine+Spotlight.swift
//  PublicationManagerCore
//
//  ADR-0023 D5 — `NSMetadataQuery`, scoped to one directory.
//
//  ── Read `CompositeFolderDiscoveryEngine` before relying on the live half ───
//
//  This engine implements both phases the ADR describes, and the GATHER phase
//  is everything the ADR promises: a scoped query over a nested tree returns
//  its matches in tens of milliseconds with no walk at any depth. The live
//  phase (`enableUpdates()` + `NSMetadataQueryDidUpdate`) could not be observed
//  delivering a single update under headless measurement — see the composite's
//  header for the numbers. It is implemented and honoured here; the shipping
//  macOS engine simply does not depend on it.
//
//  ── What makes this different from PMC's existing NSMetadataQuery ───────────
//
//  `SpotlightPDFSearchProvider` (Search/PDFSearchService.swift) is a one-shot:
//  it wraps the query in `withCheckedContinuation` and resumes on
//  `DidFinishGathering`. That is the right shape for "search these PDFs once"
//  and the wrong shape for a watched folder, whose entire value proposition is
//  the SECOND phase — `enableUpdates()` plus `NSMetadataQueryDidUpdate`, which
//  is what makes a `.bib` dropped three levels deep appear with no scan and no
//  poll.
//
//  So the lifecycle here is explicit and two-phase:
//
//      start()  → predicate + searchScopes + start
//               → DidFinishGathering  ⇒ read results, decide LIVE vs BLIND,
//                                        publish .gathered or .unavailable,
//                                        enableUpdates()
//               → DidUpdate (repeat)  ⇒ re-read results, diff, publish .changed
//      stop()   → disableUpdates, stop, drop observers
//
//  ── `-onlyin`, and why the predicate does not restate the path ──────────────
//
//  `searchScopes = [directory]` IS `mdfind -onlyin`. Adding a
//  `kMDItemPath BEGINSWITH` clause on top would be a second, weaker spelling of
//  the same constraint (it would also match a sibling directory whose name is a
//  prefix of this one). The scope is the scope.
//
//  ── The honest-signal contract ──────────────────────────────────────────────
//
//  This engine never decides that a volume is unindexed. It gathers the three
//  facts `SpotlightAvailabilityProbe` needs — did the query finish, how many
//  results, and what does a direct shallow walk see — and hands them over. The
//  decision is a pure function in a cross-platform file, and it is tested
//  there.
//

import Foundation
import OSLog

/// Live discovery via Spotlight, scoped to one directory.
@MainActor
public final class SpotlightFolderDiscoveryEngine: FolderDiscoveryEngine {

    public nonisolated let engineName = "spotlight"

    /// How long the gather may take before we judge it on what it has.
    ///
    /// A query over an indexed directory finishes in milliseconds. One that has
    /// not finished after this long is, for our purposes, finished: we stop it
    /// and evaluate the probe with what it produced. The overstatement is safe
    /// in the only direction that matters — it can push a pathologically slow
    /// folder onto the fallback engine, which enumerates it correctly, and it
    /// can never produce a silent zero.
    private let gatherTimeout: Duration

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var timeoutTask: Task<Void, Never>?

    private var directory: URL?
    private var filters: [FileDiscoveryFilter] = []
    private var onEvent: (@MainActor (FolderEngineEvent) -> Void)?

    private var known: [DiscoveredFile] = []
    private var hasGathered = false

    public init(gatherTimeout: Duration = .seconds(10)) {
        self.gatherTimeout = gatherTimeout
    }

    // MARK: Lifecycle

    public func start(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds,
        onEvent: @escaping @MainActor (FolderEngineEvent) -> Void
    ) {
        stop()
        self.directory = directory
        self.filters = filters
        self.onEvent = onEvent
        self.known = []
        self.hasGathered = false

        guard let format = SpotlightPredicateFormat.predicate(for: filters) else {
            onEvent(.failed(.noFilters))
            return
        }
        guard DirectoryScanner.isReadableDirectory(directory) else {
            onEvent(.failed(.notADirectory(path: directory.path)))
            return
        }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: format)
        // `-onlyin`. See the file header on why the predicate does not also
        // constrain the path.
        query.searchScopes = [directory.standardizedFileURL]
        query.valueListAttributes = [
            NSMetadataItemPathKey,
            NSMetadataItemFSContentChangeDateKey,
            NSMetadataItemFSSizeKey,
        ]
        // Coalesce the live phase; the default is 0, which delivers one
        // notification per indexed file during a bulk copy.
        query.notificationBatchingInterval = 0.5
        // Without an operation queue, `NSMetadataQuery` delivers on the thread
        // that started it and requires a running run loop there. Naming the
        // main queue makes delivery explicit and matches where the observers
        // below are registered. (It did NOT resurrect the live updates — see
        // the header — but it is the documented arrangement and costs nothing.)
        query.operationQueue = .main

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFinishedGathering() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUpdate() }
        })

        self.query = query

        Logger.files.infoCapture(
            "spotlight query starting for \(directory.path): \(format)",
            category: "watched-folders")

        guard query.start() else {
            Logger.files.warningCapture(
                "NSMetadataQuery refused to start for \(directory.path)",
                category: "watched-folders")
            onEvent(.unavailable(makeProbe(didFinish: true, resultCount: 0)))
            return
        }

        let timeout = gatherTimeout
        timeoutTask = Task { [weak self] in
            // ONE sleep, cancellable — never `try?` inside a loop.
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            self?.handleGatherTimeout()
        }
    }

    /// Spotlight is event-driven; an explicit refresh re-reads the current
    /// result set (and re-runs the availability judgement, so a folder whose
    /// volume got indexed since can climb back out of `fallback`).
    public func refresh() {
        guard query != nil else { return }
        if hasGathered {
            handleUpdate()
        } else {
            handleFinishedGathering()
        }
    }

    public func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let query {
            query.disableUpdates()
            query.stop()
        }
        query = nil
        onEvent = nil
        directory = nil
        known = []
        hasGathered = false
    }

    // MARK: Phases

    private func handleFinishedGathering() {
        guard let query, let onEvent, let directory, !hasGathered else { return }
        timeoutTask?.cancel()
        timeoutTask = nil

        let files = currentResults(of: query)
        let probe = makeProbe(didFinish: true, resultCount: files.count)

        if probe.provesSpotlightBlindSpot {
            Logger.files.warningCapture(
                "spotlight returned 0 for \(directory.path) but a direct probe found "
                    + "matches — treating this volume as unindexed",
                category: "watched-folders")
            onEvent(.unavailable(probe))
            return
        }

        hasGathered = true
        known = files
        Logger.files.infoCapture(
            "spotlight gathered \(files.count) files in \(directory.path)",
            category: "watched-folders")
        onEvent(.gathered(files: files, isComplete: true))

        // Phase two: live.
        query.enableUpdates()
    }

    private func handleGatherTimeout() {
        guard let query, let directory, !hasGathered else { return }
        Logger.files.warningCapture(
            "spotlight gather for \(directory.path) exceeded its timeout; judging it on "
                + "\(query.resultCount) result(s)",
            category: "watched-folders")
        handleFinishedGathering()
    }

    private func handleUpdate() {
        guard let query, let onEvent, hasGathered else { return }
        let files = currentResults(of: query)
        let diff = DiscoveryDiff.between(old: known, new: files)
        known = files
        guard !diff.isEmpty else { return }
        Logger.files.infoCapture(
            "spotlight update: +\(diff.added.count) −\(diff.removed.count)",
            category: "watched-folders")
        onEvent(.changed(diff))
    }

    // MARK: Reading the query

    /// The query's results as `DiscoveredFile`s.
    ///
    /// Re-matched against the filters locally. The predicate is a translation
    /// of the filters and Spotlight's conformance tree is not identical to
    /// `UTType`'s, so a result that no filter claims is possible; letting it
    /// through would attribute a file to a `filterID` that never asked for it.
    private func currentResults(of query: NSMetadataQuery) -> [DiscoveredFile] {
        query.disableUpdates()
        defer { if hasGathered { query.enableUpdates() } }

        var files: [DiscoveredFile] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard let filter = filters.firstMatching(url) else { continue }
            files.append(DiscoveredFile(
                url: url,
                filterID: filter.id,
                modificationDate: item.value(
                    forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                byteSize: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?
                    .int64Value))
        }
        return DiscoveryBatcher.ordered(files)
    }

    /// The three facts the pure resolver needs. The local probe is only paid
    /// for when the query came back empty — the case where it is the only thing
    /// that can tell an empty folder from an invisible one.
    private func makeProbe(didFinish: Bool, resultCount: Int) -> SpotlightAvailabilityProbe {
        var localMatches: Int?
        if didFinish, resultCount == 0, let directory {
            localMatches = DirectoryScanner.probeForMatches(
                directory: directory, filters: filters)
        }
        return SpotlightAvailabilityProbe(
            queryCouldStart: true,
            queryDidFinishGathering: didFinish,
            queryResultCount: resultCount,
            localProbeMatchCount: localMatches)
    }
}
#endif
