// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Data only.
//
//  WatchedFolderTypes.swift
//  PublicationManagerCore
//
//  ADR-0023 D5/D7 — the vocabulary the watcher publishes in, and the two
//  bounded-ness rules (batch size, startup grace) as values rather than as
//  literals buried in a loop.
//

import Foundation

// MARK: - Identity

/// A watched folder's stable id.
///
/// A wrapper rather than a bare `UUID` because this id is the key of THREE
/// separate things — the persisted bookmark, the running engine, and the
/// sidebar row's route key — and a bare UUID at those boundaries is the shape
/// that let a feed id and a collection id be used interchangeably elsewhere in
/// this codebase.
public struct WatchedFolderID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }

    /// Lowercased, because every id that crosses the Rust store boundary is
    /// lowercased there (imbib CLAUDE.md's "Manuscript UUID strings crossing
    /// the FFI must be lowercased" invariant) and W2 will hand this to
    /// `import_discovered`.
    public var storageKey: String { uuid.uuidString.lowercased() }

    public var description: String { storageKey }
}

// MARK: - Registration

/// A folder the host wants watched: which directory, under what name, for what
/// file types.
///
/// The security-scoped bookmark is deliberately NOT here. A registration is
/// what a host hands the service *this launch*; the bookmark is what the
/// service persists so it can hand itself a registration on the *next* launch
/// (see `WatchedFolderBookmarkStore`). Keeping the two apart is what makes the
/// service constructible in a test from a plain temp-directory URL, with no
/// sandbox and no panel.
public struct WatchedFolderRegistration: Sendable, Equatable, Identifiable {

    public let id: WatchedFolderID

    /// The directory. On a sandboxed launch this is the URL a resolved
    /// bookmark produced; in a test it is a temp dir.
    public let url: URL

    /// Row title. Defaults to the directory's own name.
    public let displayName: String

    /// What to look for. Empty ⇒ the service refuses to start the folder and
    /// says so, rather than watching everything.
    public let filters: [FileDiscoveryFilter]

    /// A disabled folder keeps its row and its bookmark and runs no engine.
    public let isEnabled: Bool

    public init(
        id: WatchedFolderID = WatchedFolderID(),
        url: URL,
        displayName: String? = nil,
        filters: [FileDiscoveryFilter],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.filters = filters
        self.isEnabled = isEnabled
    }
}

// MARK: - Discovered files

/// One file the watcher found, attributed to the filter that claimed it.
///
/// `filterID` is the whole point of the attribution: ADR-0023 D3 says the
/// ingest UNIT differs by kind (`.bib` fans out to entries, a manuscript is the
/// record), so the host must be able to route each hit to the kind that asked
/// for it without re-deriving the match.
public struct DiscoveredFile: Hashable, Sendable {

    public let url: URL

    /// `FileDiscoveryFilter.id` of the filter that claimed this file.
    public let filterID: String

    /// Content-modification date where the engine could cheaply supply one.
    /// nil is not an error — a Spotlight result and a walk result carry
    /// different metadata, and the re-scan diffing that cares lives in Rust
    /// (D5), keyed on a content hash rather than on this.
    public let modificationDate: Date?

    /// Size in bytes where known.
    public let byteSize: Int64?

    public init(
        url: URL, filterID: String, modificationDate: Date? = nil, byteSize: Int64? = nil
    ) {
        // Standardised so a walk result and a Spotlight result for the SAME
        // file compare equal — `/tmp` vs `/private/tmp` otherwise produces two
        // "different" discoveries of one file, which reads as a spurious
        // add+remove pair on every refresh.
        self.url = url.standardizedFileURL
        self.filterID = filterID
        self.modificationDate = modificationDate
        self.byteSize = byteSize
    }
}

public extension Set where Element == DiscoveredFile {
    var urls: Set<URL> { Set<URL>(map(\.url)) }
}

// MARK: - Events

/// What the service publishes.
///
/// Every case names its folder, because one service watches many and a
/// consumer's `for await` is a single stream.
public enum FolderWatchEvent: Sendable, Equatable {

    /// The folder's state changed. Always published on transition, including
    /// the transition INTO a degraded state — this is the event a row must
    /// render rather than inferring emptiness from a zero count.
    case stateChanged(WatchedFolderID, WatchedFolderState)

    /// One bounded chunk of the initial gather (D7). `index` is 0-based,
    /// `isFinal` marks the last chunk of the gather — including the case where
    /// the gather found nothing at all, so a consumer always gets a terminator.
    case gatheredBatch(
        WatchedFolderID, files: [DiscoveredFile], index: Int, isFinal: Bool)

    /// Live change: files that appeared. Also chunked to `maxBatchSize`.
    case filesAdded(WatchedFolderID, files: [DiscoveredFile])

    /// Live change: files that went away. D4 says a vanished file marks its row
    /// `missing` rather than deleting it; that decision is the host's, this is
    /// only the notification.
    case filesRemoved(WatchedFolderID, urls: [URL])

    /// The folder could not be watched, with a reason worth showing.
    case failed(WatchedFolderID, FolderWatchFailure)
}

/// Why a folder is not being watched. Each case is a thing the user can act on.
public enum FolderWatchFailure: Hashable, Sendable, Error, LocalizedError {

    /// The registration named no file types, so nothing could ever match.
    case noFilters

    /// The bookmark did not resolve, or resolved to nothing that exists.
    case bookmarkUnresolvable(isStale: Bool)

    /// The directory resolved but the sandbox refused access to it.
    case accessDenied(path: String)

    /// The path is not a directory (a file was watched by mistake).
    case notADirectory(path: String)

    /// This build has no live engine (iOS — D6). Not fatal: the folder falls
    /// back to `scanOnDemand`.
    case noLiveEngineOnThisPlatform

    public var errorDescription: String? {
        switch self {
        case .noFilters:
            return "This folder is not watching for any file types."
        case .bookmarkUnresolvable(let stale):
            return stale
                ? "Permission to read this folder has expired. Choose it again to restore access."
                : "This folder could not be found. It may have been moved or its disk disconnected."
        case .accessDenied(let path):
            return "Permission to read \(path) was refused."
        case .notADirectory(let path):
            return "\(path) is not a folder."
        case .noLiveEngineOnThisPlatform:
            return FolderWatchAvailability.unsupportedReason(on: .current)
                ?? "Live folder watching is not available here."
        }
    }

    /// The state a folder lands in because of this failure.
    public var resultingState: WatchedFolderState {
        switch self {
        case .bookmarkUnresolvable(let stale): return .inaccessible(bookmarkStale: stale)
        case .accessDenied, .notADirectory: return .inaccessible(bookmarkStale: false)
        case .noFilters, .noLiveEngineOnThisPlatform: return .scanOnDemand
        }
    }
}

// MARK: - Batching (D7)

/// The bounded-chunk rule, as a pure function.
///
/// ADR-0023 D7: "initial ingest of a large folder is batched through the
/// store-mirror-style write gate (≤500 rows, ordered)". The gate itself is
/// Rust-side/host-side; what belongs here is the guarantee the WATCHER makes
/// about what it hands over — ordered, deduplicated, never more than
/// `maxBatchSize` at a time, and with a final chunk even when the set is empty
/// so a consumer's state machine always terminates.
public enum DiscoveryBatcher {

    /// The suite's write-gate row cap. Same number as
    /// `StoreMirrorWriteGate`'s default, deliberately: a batch larger than the
    /// gate's is just a batch the gate re-splits.
    public static let defaultMaxBatchSize = 500

    /// Split into ordered chunks of at most `maxBatchSize`.
    ///
    /// An EMPTY input yields ONE empty chunk, not zero chunks. That is the
    /// terminator rule: "the gather finished and found nothing" is a fact the
    /// consumer needs, and a loop that emits nothing is indistinguishable from
    /// a gather that never finished — which is precisely the ambiguity D6
    /// exists to remove.
    public static func batches(
        _ files: [DiscoveredFile], maxBatchSize: Int = defaultMaxBatchSize
    ) -> [[DiscoveredFile]] {
        let size = Swift.max(1, maxBatchSize)
        guard !files.isEmpty else { return [[]] }
        return stride(from: 0, to: files.count, by: size).map {
            Array(files[$0..<Swift.min($0 + size, files.count)])
        }
    }

    /// The canonical order for a discovered set: by path, case-insensitively.
    ///
    /// Ordered output is what makes a re-scan's diff stable and the D7 batches
    /// reproducible; neither Spotlight nor `FileManager.enumerator` promises an
    /// order, and two runs that disagree look like churn to an incremental
    /// importer.
    public static func ordered(_ files: some Sequence<DiscoveredFile>) -> [DiscoveredFile] {
        files.sorted {
            let left = $0.url.path
            let right = $1.url.path
            if left.caseInsensitiveCompare(right) == .orderedSame {
                return $0.filterID < $1.filterID
            }
            return left.caseInsensitiveCompare(right) == .orderedAscending
        }
    }
}

// MARK: - Startup discipline (D7)

/// The 90-second rule, as an injectable value.
///
/// The suite's background-service invariant (CLAUDE.md, "Background Services
/// Must Defer Startup Work") is that nothing may mutate data — and therefore
/// nothing may publish a `.storeDidMutate`-shaped event — during the first ~90
/// seconds of launch, because the resulting SwiftUI body re-evaluations compound
/// into a render loop.
///
/// This copies `StoreMirrorWriteGate`'s injection shape rather than
/// `FeedScheduler`'s literal sleep: `launchDate` is a parameter, so a test puts
/// the window in the past and asserts the gather ran, or in the future and
/// asserts it did not — without sleeping for 90 seconds and without the service
/// having to know it is under test.
public struct FolderWatchStartupGate: Sendable, Equatable {

    /// Matches `InboxScheduler`/`FeedScheduler`. Do not reduce (imbib
    /// CLAUDE.md pins the number).
    public static let defaultGraceSeconds: TimeInterval = 90

    public let graceSeconds: TimeInterval
    public let launchDate: Date

    /// Whether the service is attached to a live app context at all.
    ///
    /// A watcher constructed by a unit test, a CLI, or an agent-facing service
    /// has no settling UI to protect, and making it wait 90 seconds would be
    /// ceremony rather than safety. The DEFAULT is `true` — an omitted flag
    /// must mean "assume there is a UI", because the failure mode of the wrong
    /// default in that direction is a beachball and in the other direction is a
    /// slightly late scan.
    public let isAttachedToLiveAppContext: Bool

    public init(
        graceSeconds: TimeInterval = defaultGraceSeconds,
        launchDate: Date = Date(),
        isAttachedToLiveAppContext: Bool = true
    ) {
        self.graceSeconds = graceSeconds
        self.launchDate = launchDate
        self.isAttachedToLiveAppContext = isAttachedToLiveAppContext
    }

    /// No embargo at all — headless hosts and tests.
    public static let immediate = FolderWatchStartupGate(
        graceSeconds: 0, isAttachedToLiveAppContext: false)

    /// Seconds still to wait as of `now`, or 0 when the window has closed (or
    /// never applied).
    public func remaining(asOf now: Date = Date()) -> TimeInterval {
        guard isAttachedToLiveAppContext, graceSeconds > 0 else { return 0 }
        return Swift.max(0, graceSeconds - now.timeIntervalSince(launchDate))
    }

    /// Whether an initial gather may run now.
    public func permitsInitialGather(asOf now: Date = Date()) -> Bool {
        remaining(asOf: now) <= 0
    }
}
