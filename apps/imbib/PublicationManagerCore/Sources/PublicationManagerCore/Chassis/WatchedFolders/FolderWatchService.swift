// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). The service is the
// POLICY (which engine, when to gather, how to batch, what state to publish);
// the two platform APIs it drives live in the gated companions
// `FolderDiscoveryEngine+Spotlight.swift` and `FSEventsDirectoryWatcher.swift`.
// ADR-0023 D5's own words: "platform *policy* in Swift, logic in Rust" — and
// within the Swift half, policy here, platform there.
//
//  FolderWatchService.swift
//  PublicationManagerCore
//
//  ADR-0023 W1 — the chassis folder watcher.
//
//  ── What it is ──────────────────────────────────────────────────────────────
//
//  Given (a directory, a set of `FileDiscoveryFilter`s), it publishes the files
//  in that directory that the filters claim, and then keeps publishing as they
//  change. It does not parse them, hash them, dedupe them or write them
//  anywhere: D5 puts every one of those in Rust
//  (`DocsImportService.import_discovered`). A consumer of this service receives
//  paths and states, and that is the whole contract.
//
//  ── The four honest states ──────────────────────────────────────────────────
//
//  Every folder always has a `WatchedFolderState`, and the row renders it
//  verbatim. The transition into `fallback` is not guesswork: see
//  `SpotlightAvailabilityProbe`, where the signal is a query that finished with
//  zero results over a directory a direct walk proves is not empty.
//
//  ── Startup discipline (D7) ─────────────────────────────────────────────────
//
//  `FolderWatchStartupGate` is a value, not a literal `Task.sleep(for: 90)`.
//  A test constructs the service with `.immediate` and the gather runs now; a
//  test that wants to prove the embargo constructs it with a launch date in the
//  future and asserts nothing was published. Neither test sleeps.
//
//  ── What W2 must supply ─────────────────────────────────────────────────────
//
//  Three things, all of them the host's business and none of them derivable
//  here:
//
//    1. `[FileDiscoveryFilter]` — mapped from the record kinds' declared
//       `FileDiscoveryCapability` (W0). See `FileDiscoveryFilter`'s header.
//    2. The folder-picking UI, which is what produces a URL the sandbox will
//       let us bookmark.
//    3. The sink: what to do with `FolderWatchEvent`s (imbib: hand the paths to
//       `import_discovered` with provenance).
//
//  In exchange it gets `rows` — ready-made `WatchedFolderRowState`s that turn
//  into sidebar nodes with `rows.sidebarNodes(kind:)`.
//

import Foundation
import OSLog

// MARK: - Engine selection

/// Which engines this build has, behind closures.
///
/// A struct of factories rather than a `#if` inside the service: the service is
/// cross-platform policy and must stay readable as such, and a test needs to
/// supply two engines of its own without either platform API being involved.
/// `PDFSearchService.init(provider:)` is the same seam one layer up.
public struct FolderWatchEngineFactory: Sendable {

    /// The preferred engine. nil = this build has none (iOS), which is
    /// `scanOnDemand` and is reported as such rather than as failure.
    public var makePrimary: @MainActor @Sendable () -> (any FolderDiscoveryEngine)?

    /// The engine to fall back to when the primary proves blind. nil = there is
    /// no fallback, so a blind spot degrades to `scanOnDemand`.
    public var makeFallback: @MainActor @Sendable () -> (any FolderDiscoveryEngine)?

    public init(
        makePrimary: @escaping @MainActor @Sendable () -> (any FolderDiscoveryEngine)?,
        makeFallback: @escaping @MainActor @Sendable () -> (any FolderDiscoveryEngine)?
    ) {
        self.makePrimary = makePrimary
        self.makeFallback = makeFallback
    }

    /// The shipping value.
    ///
    /// macOS: the composite engine — Spotlight for the instant initial gather,
    /// FSEvents + bounded walk for the live phase (see
    /// `CompositeFolderDiscoveryEngine`'s header for the measurement that
    /// produced that split) — falling back to walk-only when Spotlight proves
    /// blind. iOS: no primary at all, and a walk engine driven by a notifier
    /// that only fires on request, which is exactly what "scan on demand" means
    /// and is more honest than a watcher that silently never fires.
    public static let live = FolderWatchEngineFactory(
        makePrimary: {
            #if os(macOS)
            CompositeFolderDiscoveryEngine()
            #else
            nil
            #endif
        },
        makeFallback: {
            #if os(macOS)
            WalkFolderDiscoveryEngine(notifier: FSEventsDirectoryWatcher())
            #else
            WalkFolderDiscoveryEngine(notifier: ManualDirectoryChangeNotifier())
            #endif
        })

    /// No Spotlight: go straight to the walk engine with a caller-supplied
    /// notifier. The shape every fallback test uses, and the shape an
    /// adopter would use to force the fallback for a known-unindexed volume.
    public static func walkOnly(
        notifier: @escaping @MainActor @Sendable () -> any DirectoryChangeNotifying
    ) -> FolderWatchEngineFactory {
        FolderWatchEngineFactory(
            makePrimary: { nil },
            makeFallback: { WalkFolderDiscoveryEngine(notifier: notifier()) })
    }

    /// No engines at all — the scan-on-demand floor, and the value an iOS host
    /// with no folder access should use.
    public static let none = FolderWatchEngineFactory(
        makePrimary: { nil }, makeFallback: { nil })
}

// MARK: - Service

/// Watches directories and publishes what is in them.
///
/// `@MainActor @Observable`: `rows` feeds SwiftUI directly, and both engines are
/// notification-driven objects that already live on the main queue. The
/// expensive work — the directory walk — is explicitly detached inside
/// `WalkFolderDiscoveryEngine`.
@MainActor
@Observable
public final class FolderWatchService {

    // MARK: Configuration

    private let bookmarks: WatchedFolderBookmarkStore
    private let engines: FolderWatchEngineFactory
    private let gate: FolderWatchStartupGate
    private let bounds: FolderWalkBounds
    private let maxBatchSize: Int

    /// Every watched folder, in registration order. The sidebar's source.
    public private(set) var rows: [WatchedFolderRowState] = []

    /// Live per-folder file sets, keyed by folder. The host's other read path
    /// (a folder's detail pane); the sidebar only needs `rows`.
    public private(set) var discoveredFiles: [WatchedFolderID: [DiscoveredFile]] = [:]

    @ObservationIgnored private var folders: [WatchedFolderID: WatchedFolder] = [:]
    @ObservationIgnored private var order: [WatchedFolderID] = []
    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<FolderWatchEvent>.Continuation] = [:]

    public init(
        bookmarks: WatchedFolderBookmarkStore = .shared,
        engines: FolderWatchEngineFactory = .live,
        startupGate: FolderWatchStartupGate = FolderWatchStartupGate(),
        bounds: FolderWalkBounds = .default,
        maxBatchSize: Int = DiscoveryBatcher.defaultMaxBatchSize
    ) {
        self.bookmarks = bookmarks
        self.engines = engines
        self.gate = startupGate
        self.bounds = bounds
        self.maxBatchSize = Swift.max(1, maxBatchSize)
    }

    // MARK: Event stream

    /// A stream of everything this service publishes.
    ///
    /// Multi-consumer: each call gets its own buffered stream, so the sidebar
    /// and the ingest sink do not have to share one. Finishing is automatic
    /// when the caller drops the stream.
    public func events() -> AsyncStream<FolderWatchEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func publish(_ event: FolderWatchEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: Registration

    /// Register a folder for this session. Does not start it and does not
    /// persist a bookmark — see `persistAndAdd` for the sandboxed path.
    @discardableResult
    public func add(_ registration: WatchedFolderRegistration) -> WatchedFolderRowState {
        let folder = WatchedFolder(registration: registration)
        folders[registration.id] = folder
        if !order.contains(registration.id) { order.append(registration.id) }
        rebuildRows()
        return row(for: registration.id) ?? folder.rowState
    }

    /// Mint and persist a security-scoped bookmark for a URL the user just
    /// granted, then register it.
    ///
    /// The filters are NOT persisted — only their ids (see
    /// `WatchedFolderBookmark.filterIDs`), because a filter is derived from a
    /// record-kind declaration and a persisted copy of a derived value is how
    /// a stale declaration outlives the real one.
    @discardableResult
    public func persistAndAdd(
        url: URL,
        filters: [FileDiscoveryFilter],
        displayName: String? = nil,
        id: WatchedFolderID = WatchedFolderID()
    ) async throws -> WatchedFolderRegistration {
        let record = try await bookmarks.register(
            id: id,
            url: url,
            displayName: displayName,
            filterIDs: filters.map(\.id))
        let registration = WatchedFolderRegistration(
            id: record.id,
            url: URL(fileURLWithPath: record.path),
            displayName: record.displayName,
            filters: filters,
            isEnabled: record.isEnabled)
        add(registration)
        return registration
    }

    /// Rebuild this launch's registrations from persisted bookmarks.
    ///
    /// **The W2 seam on the restore side.** The host supplies the filter table
    /// it derived from the record-kind declarations, keyed by
    /// `FileDiscoveryFilter.id`; a persisted folder whose filter ids no longer
    /// resolve to anything is registered with NO filters and lands in
    /// `scanOnDemand` with `.noFilters` — visible and fixable, rather than
    /// silently watching nothing.
    ///
    /// Folders whose bookmark will not resolve are still registered, in
    /// `inaccessible`, because D6's whole point is that a folder the app cannot
    /// currently reach must remain visible.
    @discardableResult
    public func restorePersistedFolders(
        filtersByID: [String: FileDiscoveryFilter]
    ) async -> [WatchedFolderRowState] {
        for record in await bookmarks.all() {
            let filters = record.filterIDs.compactMap { filtersByID[$0] }
            switch await bookmarks.resolveURL(for: record.id) {
            case .success(let url):
                add(WatchedFolderRegistration(
                    id: record.id,
                    url: url,
                    displayName: record.displayName,
                    filters: filters,
                    isEnabled: record.isEnabled))
            case .failure(let failure):
                let registration = WatchedFolderRegistration(
                    id: record.id,
                    url: URL(fileURLWithPath: record.path),
                    displayName: record.displayName,
                    filters: filters,
                    isEnabled: record.isEnabled)
                add(registration)
                apply(failure, to: record.id)
            }
        }
        return rows
    }

    /// Stop, forget, and delete the persisted bookmark.
    public func remove(_ id: WatchedFolderID) async {
        stop(id)
        folders.removeValue(forKey: id)
        order.removeAll { $0 == id }
        discoveredFiles.removeValue(forKey: id)
        await bookmarks.remove(id)
        rebuildRows()
    }

    // MARK: Reading

    public func row(for id: WatchedFolderID) -> WatchedFolderRowState? {
        rows.first { $0.id == id }
    }

    public func files(in id: WatchedFolderID) -> [DiscoveredFile] {
        discoveredFiles[id] ?? []
    }

    /// The engine actually serving a folder — `nil` before it starts. Named for
    /// logs and for the tests that assert which engine won.
    public func engineName(for id: WatchedFolderID) -> String? {
        folders[id]?.engine?.engineName
    }

    /// Feed semantics: clear the "new since you last looked" badge.
    public func markSeen(_ id: WatchedFolderID) {
        guard let folder = folders[id] else { return }
        folder.newSinceLastVisit = 0
        rebuildRows()
    }

    // MARK: Lifecycle

    /// Start one folder, honouring the startup embargo.
    ///
    /// Awaits the remaining grace before the FIRST gather (D7). With
    /// `FolderWatchStartupGate.immediate` — every test, and any headless host —
    /// there is nothing to await.
    public func start(_ id: WatchedFolderID) async {
        guard let folder = folders[id] else { return }
        guard folder.registration.isEnabled else {
            setState(.scanOnDemand, for: id)
            return
        }
        guard folder.registration.filters.canMatchAnything else {
            apply(.noFilters, to: id)
            return
        }

        let remaining = gate.remaining()
        if remaining > 0 {
            Logger.files.infoCapture(
                "watched folder \(id.storageKey): deferring initial gather "
                    + "\(Int(remaining))s for the startup window",
                category: "watched-folders")
            // ONE sleep, cancellable. `try?` inside a loop is the trap.
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        }
        guard folders[id] != nil, !Task.isCancelled else { return }

        startEngine(preferPrimary: true, for: id)
    }

    /// Start every registered, enabled folder. The embargo is awaited ONCE, not
    /// per folder.
    public func startAll() async {
        let remaining = gate.remaining()
        if remaining > 0 {
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        for id in order {
            guard let folder = folders[id], folder.registration.isEnabled else { continue }
            guard folder.registration.filters.canMatchAnything else {
                apply(.noFilters, to: id)
                continue
            }
            startEngine(preferPrimary: true, for: id)
        }
    }

    public func stop(_ id: WatchedFolderID) {
        folders[id]?.engine?.stop()
        folders[id]?.engine = nil
        folders[id]?.isRefreshing = false
        rebuildRows()
    }

    public func stopAll() {
        for id in order { stop(id) }
    }

    /// The row's Refresh verb.
    ///
    /// A folder with no running engine (scan-on-demand, or one stopped by a
    /// failure) gets a fresh start rather than a no-op — "Refresh" on a folder
    /// that is not being watched must mean "look now", which is the only
    /// reading a user would expect.
    public func refresh(_ id: WatchedFolderID) async {
        guard let folder = folders[id], folder.registration.isEnabled else { return }
        folder.isRefreshing = true
        rebuildRows()
        if let engine = folder.engine {
            engine.refresh()
        } else {
            startEngine(preferPrimary: true, for: id)
        }
    }

    // MARK: Engine plumbing

    private func startEngine(preferPrimary: Bool, for id: WatchedFolderID) {
        guard let folder = folders[id] else { return }
        folder.engine?.stop()
        folder.engine = nil

        // Built ONCE: `makePrimary()` constructs an engine, so asking twice
        // (once for the engine, once to decide whether it was the primary)
        // would leave an orphan NSMetadataQuery behind.
        var isPrimary = false
        var engine: (any FolderDiscoveryEngine)?
        if preferPrimary, let primary = engines.makePrimary() {
            engine = primary
            isPrimary = true
        } else {
            engine = engines.makeFallback()
        }

        guard let engine else {
            // No engine at all: honest scan-on-demand, not a failure.
            folder.isRefreshing = false
            setState(.scanOnDemand, for: id)
            return
        }

        folder.engine = engine
        folder.usedPrimary = isPrimary
        folder.isRefreshing = true
        rebuildRows()

        engine.start(
            directory: folder.registration.url,
            filters: folder.registration.filters,
            bounds: bounds
        ) { [weak self] event in
            self?.handle(event, from: id)
        }
    }

    private func handle(_ event: FolderEngineEvent, from id: WatchedFolderID) {
        guard let folder = folders[id] else { return }

        switch event {
        case .gathered(let files, let isComplete):
            folder.isRefreshing = false
            folder.countIsPartial = !isComplete
            folder.lastScanDate = Date()
            let previous = discoveredFiles[id] ?? []
            discoveredFiles[id] = files
            folder.discoveredCount = files.count

            // The state a completed gather implies. `usedPrimary` distinguishes
            // "Spotlight answered" from "the walk answered", which is exactly
            // the live/fallback distinction the row shows.
            setState(folder.usedPrimary ? .live : .fallback, for: id)

            if previous.isEmpty {
                emitGather(files, for: id)
            } else {
                // A refresh of an already-gathered folder is a diff, not a
                // second gather — a consumer that has already ingested these
                // paths must not be handed them all again.
                let diff = DiscoveryDiff.between(old: previous, new: files)
                emitDiff(diff, for: id)
            }

        case .changed(let diff):
            folder.lastScanDate = Date()
            var current = discoveredFiles[id] ?? []
            let removed = Set(diff.removed)
            current.removeAll { removed.contains($0.url) }
            current.append(contentsOf: diff.added)
            let updated = DiscoveryBatcher.ordered(current)
            discoveredFiles[id] = updated
            folder.discoveredCount = updated.count
            emitDiff(diff, for: id)

        case .unavailable(let probe):
            let resolved = WatchedFolderStateResolver.resolve(
                probe: probe,
                fallbackEngineAvailable: engines.makeFallback() != nil)
            folder.engine?.stop()
            folder.engine = nil
            switch resolved {
            case .fallback:
                Logger.files.infoCapture(
                    "watched folder \(id.storageKey): primary engine is blind here, "
                        + "switching to the fallback",
                    category: "watched-folders")
                startEngine(preferPrimary: false, for: id)
            case .some(let state):
                folder.isRefreshing = false
                setState(state, for: id)
            case .none:
                // Undetermined: keep whatever the row last honestly said.
                folder.isRefreshing = false
                rebuildRows()
            }

        case .failed(let failure):
            folder.engine?.stop()
            folder.engine = nil
            folder.isRefreshing = false
            apply(failure, to: id)
        }

        rebuildRows()
    }

    // MARK: Emission (D7 batching)

    private func emitGather(_ files: [DiscoveredFile], for id: WatchedFolderID) {
        let batches = DiscoveryBatcher.batches(files, maxBatchSize: maxBatchSize)
        for (index, batch) in batches.enumerated() {
            publish(.gatheredBatch(
                id, files: batch, index: index, isFinal: index == batches.count - 1))
        }
        Logger.files.infoCapture(
            "watched folder \(id.storageKey): gathered \(files.count) file(s) in "
                + "\(batches.count) batch(es)",
            category: "watched-folders")
    }

    private func emitDiff(_ diff: DiscoveryDiff, for id: WatchedFolderID) {
        guard !diff.isEmpty else { return }
        if !diff.added.isEmpty {
            folders[id]?.newSinceLastVisit += diff.added.count
            for batch in DiscoveryBatcher.batches(diff.added, maxBatchSize: maxBatchSize)
            where !batch.isEmpty {
                publish(.filesAdded(id, files: batch))
            }
        }
        if !diff.removed.isEmpty {
            for batch in stride(from: 0, to: diff.removed.count, by: maxBatchSize) {
                let end = Swift.min(batch + maxBatchSize, diff.removed.count)
                publish(.filesRemoved(id, urls: Array(diff.removed[batch..<end])))
            }
        }
    }

    // MARK: State

    private func setState(_ state: WatchedFolderState, for id: WatchedFolderID) {
        guard let folder = folders[id], folder.state != state else {
            rebuildRows()
            return
        }
        folder.state = state
        rebuildRows()
        publish(.stateChanged(id, state))
        Logger.files.infoCapture(
            "watched folder \(id.storageKey): \(state.label)", category: "watched-folders")
    }

    private func apply(_ failure: FolderWatchFailure, to id: WatchedFolderID) {
        folders[id]?.isRefreshing = false
        setState(failure.resultingState, for: id)
        publish(.failed(id, failure))
    }

    private func rebuildRows() {
        rows = order.compactMap { folders[$0]?.rowState }
    }
}

// MARK: - Per-folder state

/// Mutable per-folder bookkeeping. A reference type so the service can hand out
/// `rows` (value snapshots) without copying this on every event.
@MainActor
private final class WatchedFolder {

    let registration: WatchedFolderRegistration
    var engine: (any FolderDiscoveryEngine)?
    var state: WatchedFolderState
    var isRefreshing = false
    var countIsPartial = false
    var lastScanDate: Date?
    var newSinceLastVisit = 0
    var usedPrimary = false
    var discoveredCount = 0

    init(registration: WatchedFolderRegistration) {
        self.registration = registration
        // Before anything runs, the honest answer is "we have not looked".
        self.state = .scanOnDemand
    }

    var rowState: WatchedFolderRowState {
        WatchedFolderRowState(
            id: registration.id,
            displayName: registration.displayName,
            path: registration.url.path,
            state: state,
            discoveredCount: discoveredCount,
            newSinceLastVisit: newSinceLastVisit,
            lastScanDate: lastScanDate,
            isRefreshing: isRefreshing,
            isEnabled: registration.isEnabled,
            countIsPartial: countIsPartial)
    }
}
