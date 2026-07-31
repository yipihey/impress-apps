#if os(macOS)
// Chassis file — macOS-only: it composes the two macOS engines. The
// composition LOGIC (seed, dedupe, forward) is trivial and lives here rather
// than in the cross-platform service, because a service that knew about
// "Spotlight plus FSEvents" would be naming a platform arrangement in a
// platform-free file.
//
//  CompositeFolderDiscoveryEngine.swift
//  PublicationManagerCore
//
//  ADR-0023 D5 — the engine the shipping macOS build actually runs, and the
//  measurement that produced it.
//
//  ── What was measured ───────────────────────────────────────────────────────
//
//  ADR-0023's premise is that `NSMetadataQuery` "delivers **live updates**: a
//  `.bib` dropped three levels deep in a watched folder can appear in imbib
//  without a scan, a poll, or a recursive walk". Half of that is true and
//  measurable, and half of it did not reproduce:
//
//    * **The initial gather is everything the ADR says.** A query scoped to a
//      nested temp tree returned its matches in ~35 ms, with no walk. On a
//      home directory that difference is the whole feature.
//    * **The live phase did not deliver.** With the same query running and
//      `enableUpdates()` called, a `.bib` created three levels down produced no
//      `NSMetadataQueryDidUpdate` in 30 s — and, decisively, re-reading
//      `query.results` directly 12 s later still did not contain it, while
//      `mdfind -onlyin <dir>` DID return it 8 s after creation. So the index
//      had the file and the running query never saw it. That was reproduced
//      with and without `operationQueue`, and with the main run loop spun
//      explicitly, so it is not a run-loop artefact of the test host.
//
//  (The caveat that keeps this honest: those measurements are from a headless
//  `swift test` process. It is possible a full app session behaves better.
//  What is NOT acceptable is shipping "your folder updates live" on the basis
//  of an API whose live half could not be observed working even once.)
//
//  ── The response ────────────────────────────────────────────────────────────
//
//  Use each mechanism for the half it demonstrably does:
//
//      NSMetadataQuery  → the initial gather (instant, no walk, any depth)
//      FSEvents + walk  → the live phase (recursive, sub-second, verified in
//                         `FSEventsDirectoryWatcherTests`)
//
//  `NSMetadataQueryDidUpdate` is still honoured when it does arrive; it simply
//  is not relied upon. Duplicate reports from the two sources are collapsed
//  here against one `known` set, so a consumer sees each file appear once
//  whichever mechanism noticed it first.
//
//  The walk in the live phase is not a poll: it runs only when FSEvents says
//  something under the root changed, it is debounced, it is bounded, and it
//  runs off the main actor. The steady state is still event-driven, which is
//  what D7 asks for.
//

import Foundation
import OSLog

/// The macOS primary engine: Spotlight for the gather, FSEvents for the live
/// phase.
@MainActor
public final class CompositeFolderDiscoveryEngine: FolderDiscoveryEngine {

    public nonisolated let engineName = "spotlight+fsevents"

    private let gatherEngine: SpotlightFolderDiscoveryEngine
    private let liveEngine: WalkFolderDiscoveryEngine

    private var onEvent: (@MainActor (FolderEngineEvent) -> Void)?
    private var known: [DiscoveredFile] = []
    private var knownURLs: Set<URL> = []
    private var hasGathered = false

    public init(
        gatherEngine: SpotlightFolderDiscoveryEngine = SpotlightFolderDiscoveryEngine(),
        liveEngine: WalkFolderDiscoveryEngine = WalkFolderDiscoveryEngine(
            notifier: FSEventsDirectoryWatcher())
    ) {
        self.gatherEngine = gatherEngine
        self.liveEngine = liveEngine
    }

    public func start(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds,
        onEvent: @escaping @MainActor (FolderEngineEvent) -> Void
    ) {
        stop()
        self.onEvent = onEvent
        self.known = []
        self.knownURLs = []
        self.hasGathered = false

        gatherEngine.start(directory: directory, filters: filters, bounds: bounds) {
            [weak self] event in
            guard let self else { return }
            switch event {
            case .gathered(let files, let isComplete):
                self.adoptGather(files)
                onEvent(.gathered(files: files, isComplete: isComplete))
                // Hand the live phase over, seeded so it re-publishes nothing.
                self.liveEngine.startTrackingChanges(
                    directory: directory, filters: filters, bounds: bounds, seed: files
                ) { [weak self] liveEvent in
                    self?.forwardLive(liveEvent)
                }

            case .changed(let diff):
                // Honoured if it ever arrives; not relied upon.
                self.forwardLive(.changed(diff))

            case .unavailable, .failed:
                // The service decides (fallback, or a visible failure). No live
                // phase to start.
                onEvent(event)
            }
        }
    }

    public func refresh() {
        gatherEngine.refresh()
        // The walk is the half that can actually see a change the index missed,
        // so an explicit Refresh must go through it.
        liveEngine.refresh()
    }

    public func stop() {
        gatherEngine.stop()
        liveEngine.stop()
        onEvent = nil
        known = []
        knownURLs = []
        hasGathered = false
    }

    // MARK: Dedupe

    private func adoptGather(_ files: [DiscoveredFile]) {
        known = files
        knownURLs = Set(files.map(\.url))
        hasGathered = true
    }

    /// Collapse a live event against what is already known.
    ///
    /// Both sources report the whole delta they see, and after a Spotlight
    /// update the walk's own baseline is briefly stale — so without this a file
    /// would be published twice and the host would ingest it twice.
    private func forwardLive(_ event: FolderEngineEvent) {
        guard let onEvent else { return }
        switch event {
        case .changed(let diff):
            let added = diff.added.filter { !knownURLs.contains($0.url) }
            let removed = diff.removed.filter { knownURLs.contains($0) }
            guard !added.isEmpty || !removed.isEmpty else { return }

            let removedSet = Set(removed)
            known.removeAll { removedSet.contains($0.url) }
            known.append(contentsOf: added)
            known = DiscoveryBatcher.ordered(known)
            knownURLs = Set(known.map(\.url))

            onEvent(.changed(DiscoveryDiff(added: added, removed: removed)))

        case .gathered(let files, let isComplete):
            // The live engine is seeded, so it should not gather. If it ever
            // does (a future refactor), fold it in as a diff rather than
            // letting a second gather reach the host.
            guard hasGathered else {
                adoptGather(files)
                onEvent(.gathered(files: files, isComplete: isComplete))
                return
            }
            forwardLive(.changed(DiscoveryDiff.between(old: known, new: files)))

        case .unavailable, .failed:
            // The gather already succeeded, so a live-phase hiccup is not a
            // reason to tear the folder down; log it and keep the last honest
            // state.
            Logger.files.warningCapture(
                "watched folder live phase reported \(String(describing: event))",
                category: "watched-folders")
        }
    }
}
#endif
