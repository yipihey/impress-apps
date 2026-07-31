// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). The PROTOCOL both
// engines implement, plus the one engine that needs no platform API (the
// bounded walk). The Spotlight engine and the FSEvents notifier are the gated
// companions — `FolderDiscoveryEngine+Spotlight.swift` and
// `FSEventsDirectoryWatcher.swift`.
//
//  FolderDiscoveryEngine.swift
//  PublicationManagerCore
//
//  ADR-0023 D5/D6 — "NSMetadataQuery (live) with an FSEvents + manual-walk
//  fallback".
//
//  The split follows `PDFSearchService`, PMC's existing NSMetadataQuery site:
//  a cross-platform `protocol`, a `#if os(macOS)` implementation that talks to
//  Spotlight, and an initialiser that takes an implementation so a test can
//  supply its own. What is added here that `PDFSearchService` does not have is
//  LIVE updates — that file resumes a `withCheckedContinuation` on
//  `DidFinishGathering` and stops, which is a one-shot query and is exactly the
//  shape not to copy.
//

import Foundation
import OSLog

// MARK: - Engine vocabulary

/// What an engine tells the service.
public enum FolderEngineEvent: Sendable {

    /// The initial enumeration finished. `isComplete` is false when bounds
    /// truncated it, which is what makes the folder's count a floor.
    case gathered(files: [DiscoveredFile], isComplete: Bool)

    /// A live change since the gather.
    case changed(DiscoveryDiff)

    /// This engine cannot honestly serve this directory, and here is the
    /// evidence. The service decides what to do (swap to the fallback, or
    /// declare scan-on-demand); the engine only reports.
    case unavailable(SpotlightAvailabilityProbe)

    /// A hard failure with a user-actionable reason.
    case failed(FolderWatchFailure)
}

/// One discovery mechanism over one directory.
///
/// `@MainActor` deliberately. Both real implementations are notification-driven
/// AppKit-adjacent objects (`NSMetadataQuery` posts to an `OperationQueue`;
/// `FSEventStream` needs a dispatch queue and a stable callback context), and
/// the service that owns them is a `@MainActor @Observable` model feeding
/// SwiftUI. Putting the boundary anywhere else buys an actor hop per event and
/// a `Sendable` fight for no isolation that matters — the expensive work (the
/// walk) is explicitly detached where it happens.
@MainActor
public protocol FolderDiscoveryEngine: AnyObject {

    /// For logs and for `FolderWatchService.engineName(for:)` in tests.
    nonisolated var engineName: String { get }

    /// Begin. Publishes exactly one `.gathered` (or one `.unavailable`/
    /// `.failed`) and then zero or more `.changed`.
    func start(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds,
        onEvent: @escaping @MainActor (FolderEngineEvent) -> Void)

    /// Re-enumerate now (the row's Refresh verb).
    func refresh()

    /// Stop and release everything. Must be idempotent.
    func stop()
}

// MARK: - Change notification seam

/// "Something under this directory changed."
///
/// Extracted from the walk engine so the FSEvents path is testable without
/// FSEvents: `ManualDirectoryChangeNotifier` lets a test drive the exact
/// sequence (notify → re-walk → diff → publish) that a real event triggers,
/// deterministically and in milliseconds, on both platforms. The real
/// `FSEventsDirectoryWatcher` is then a thin adapter with one job, and
/// `FSEventsDirectoryWatcherTests` exercises that job on its own.
@MainActor
public protocol DirectoryChangeNotifying: AnyObject {

    nonisolated var notifierName: String { get }

    /// Returns false when this notifier cannot watch the directory — the
    /// engine then falls back to explicit refreshes only.
    @discardableResult
    func startWatching(_ directory: URL, onChange: @escaping @MainActor () -> Void) -> Bool

    func stopWatching()
}

/// A notifier that only fires when told to.
///
/// Two users: unit tests, and any host with no OS-level watcher (iOS), where
/// "changes arrive when the user refreshes" is the honest behaviour and a
/// silently dead watcher would not be.
@MainActor
public final class ManualDirectoryChangeNotifier: DirectoryChangeNotifying {

    public nonisolated let notifierName = "manual"

    private var onChange: (@MainActor () -> Void)?
    public private(set) var watchedDirectory: URL?

    public init() {}

    @discardableResult
    public func startWatching(
        _ directory: URL, onChange: @escaping @MainActor () -> Void
    ) -> Bool {
        self.watchedDirectory = directory
        self.onChange = onChange
        return true
    }

    public func stopWatching() {
        onChange = nil
        watchedDirectory = nil
    }

    /// Simulate a filesystem change.
    public func fire() { onChange?() }
}

// MARK: - The walk engine

/// Discovery by bounded walk, kept current by a change notifier.
///
/// This is D6's fallback: what runs when Spotlight cannot see a volume. It is
/// also the only engine that exists on iOS, where it degrades to
/// refresh-on-demand because `ManualDirectoryChangeNotifier` fires only when
/// asked.
///
/// The debounce is not decoration. An atomic save is a `rename` followed by a
/// `write`, an unzip is thousands of creates, and a copy of a folder is one
/// event per file; re-walking per event would turn a 200-file copy into 200
/// walks. `VeuszPlotWatcher` learned this in imprint and its 500 ms is the
/// number copied here. The sleep is a SINGLE `Task.sleep` inside a cancellable
/// task, never `try?` inside a loop — the suite's uncancellable-loop trap.
@MainActor
public final class WalkFolderDiscoveryEngine: FolderDiscoveryEngine {

    public nonisolated let engineName: String

    private let notifier: any DirectoryChangeNotifying
    private let debounce: Duration

    private var directory: URL?
    private var filters: [FileDiscoveryFilter] = []
    private var bounds: FolderWalkBounds = .default
    private var onEvent: (@MainActor (FolderEngineEvent) -> Void)?

    /// Last complete enumeration, for diffing.
    private var known: [DiscoveredFile] = []
    private var hasGathered = false

    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    public init(
        notifier: any DirectoryChangeNotifying,
        debounce: Duration = .milliseconds(500)
    ) {
        self.notifier = notifier
        self.debounce = debounce
        self.engineName = "walk+\(notifier.notifierName)"
    }

    public func start(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds,
        onEvent: @escaping @MainActor (FolderEngineEvent) -> Void
    ) {
        stop()
        self.directory = directory
        self.filters = filters
        self.bounds = bounds
        self.onEvent = onEvent
        self.known = []
        self.hasGathered = false

        guard filters.canMatchAnything else {
            onEvent(.failed(.noFilters))
            return
        }
        guard DirectoryScanner.isReadableDirectory(directory) else {
            onEvent(.failed(.notADirectory(path: directory.path)))
            return
        }

        notifier.startWatching(directory) { [weak self] in
            self?.scheduleDebouncedRescan()
        }
        performScan()
    }

    /// Start in DELTA mode: adopt a set someone else already enumerated, and
    /// publish only what changes from here.
    ///
    /// The composite macOS engine uses this. Spotlight answers "what is in this
    /// tree" in milliseconds without a walk — that is the expensive question on
    /// a large directory and the one it is worth having an index for. Re-walking
    /// immediately afterwards to learn what we already know would throw that
    /// away, so the tracker is seeded instead and walks only when something
    /// actually changes.
    public func startTrackingChanges(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds,
        seed: [DiscoveredFile],
        onEvent: @escaping @MainActor (FolderEngineEvent) -> Void
    ) {
        stop()
        self.directory = directory
        self.filters = filters
        self.bounds = bounds
        self.onEvent = onEvent
        self.known = seed
        // Already "gathered" — the next scan publishes a diff, not a gather.
        self.hasGathered = true

        guard filters.canMatchAnything,
              DirectoryScanner.isReadableDirectory(directory) else { return }
        notifier.startWatching(directory) { [weak self] in
            self?.scheduleDebouncedRescan()
        }
    }

    public func refresh() {
        debounceTask?.cancel()
        debounceTask = nil
        performScan()
    }

    public func stop() {
        scanTask?.cancel()
        scanTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        notifier.stopWatching()
        onEvent = nil
        directory = nil
        known = []
        hasGathered = false
    }

    // MARK: Internals

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        let interval = debounce
        debounceTask = Task { [weak self] in
            // ONE sleep, cancellable. Never `try?` in a loop.
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled else { return }
            self?.performScan()
        }
    }

    private func performScan() {
        guard let directory, let onEvent else { return }
        let filters = self.filters
        let bounds = self.bounds

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            // The walk is the expensive part and it is pure — run it off the
            // main actor so a 20,000-file tree does not stall the UI.
            let result = await Task.detached(priority: .utility) {
                DirectoryScanner.scan(
                    directory: directory, filters: filters, bounds: bounds)
            }.value

            guard !Task.isCancelled, let self else { return }

            if !result.unreadableDirectories.isEmpty {
                Logger.files.warningCapture(
                    "walk of \(directory.path): \(result.unreadableDirectories.count) "
                        + "unreadable subdirectories",
                    category: "watched-folders")
            }

            if self.hasGathered {
                let diff = DiscoveryDiff.between(old: self.known, new: result.files)
                self.known = result.files
                if !diff.isEmpty { onEvent(.changed(diff)) }
            } else {
                self.hasGathered = true
                self.known = result.files
                onEvent(.gathered(files: result.files, isComplete: result.isComplete))
            }
        }
    }
}
