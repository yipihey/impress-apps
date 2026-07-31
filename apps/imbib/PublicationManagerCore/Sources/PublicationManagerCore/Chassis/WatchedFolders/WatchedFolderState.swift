// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Data only.
//
//  WatchedFolderState.swift
//  PublicationManagerCore
//
//  ADR-0023 D6 — "honest platform and volume limits", as an enum the UI renders
//  verbatim.
//
//  ── The risk this file is the mitigation for ────────────────────────────────
//
//  ADR-0023's own risk register: "Spotlight blind spots read as data loss —
//  the folder row must never render an unindexed volume as '0 files'."
//
//  A watched folder that Spotlight cannot see looks, from inside the query,
//  EXACTLY like a watched folder with nothing in it: `NSMetadataQuery` finishes
//  gathering and hands back an empty result set, with no error, no warning and
//  no flag. Rendering that as "0" is not a cosmetic bug — the user's `.bib`
//  files are sitting right there on an external disk and the app is telling
//  them the folder is empty.
//
//  So a folder always carries a STATE alongside its count, the state has a
//  label, and the label is what the row shows. `countIsTrustworthy` is the
//  property that makes it impossible to render the lie by accident: a row in a
//  degraded state has no badge at all, because a badge is a claim about
//  completeness that the folder cannot currently make.
//

import Foundation

// MARK: - Availability

/// Where the folder watcher runs, as DATA.
///
/// ADR-0023 D6: v1 is macOS-only, "by declared `SettingsPlatform`-style
/// availability". This is that declaration, and it reuses `SettingsPlatform`
/// (ImpressChassis) rather than minting a parallel platform enum — the whole
/// point of that type's doc comment is that availability is data both platforms
/// can read and a macOS test can assert about.
///
/// Note what this is NOT: an `#if os(macOS)` around the watcher's types. The
/// filters, the states, the row model, the batching and the bookmark store all
/// compile and are exercised on iOS; only the two live ENGINES
/// (`NSMetadataQuery`, `FSEvents`) are gated. iOS therefore gets a service that
/// answers `.scanOnDemand` honestly instead of a service that does not exist.
public enum FolderWatchAvailability {

    /// Platforms with a live discovery engine.
    ///
    /// iOS has no `mdfind` and no user-visible folder to point at; D6 records
    /// iCloud-Drive folders as the iOS follow-up.
    public static let livePlatforms: Set<SettingsPlatform> = [.macOS]

    /// Whether this build can watch a folder live.
    public static var isLiveHere: Bool { livePlatforms.contains(.current) }

    /// Why not, in the user's words, for a platform that cannot. `nil` when it
    /// can — so a caller cannot accidentally show the excuse on macOS.
    public static func unsupportedReason(on platform: SettingsPlatform) -> String? {
        guard !livePlatforms.contains(platform) else { return nil }
        switch platform {
        case .iOS:
            return "Live folder watching needs Spotlight, which iOS does not offer. "
                + "Folders can still be scanned on demand."
        case .macOS:
            return nil
        }
    }
}

// MARK: - State

/// What a watched folder can currently do — the four honest answers.
///
/// Ordered by capability, most capable first, which is also the order the
/// service tries to reach: `live` → `fallback` → `scanOnDemand`, with
/// `inaccessible` as the orthogonal "we cannot even open it".
public enum WatchedFolderState: Hashable, Sendable, Codable {

    /// Spotlight is indexing this directory and the query is delivering live
    /// updates. Counts are complete; a file dropped three levels deep appears
    /// without a scan.
    case live

    /// Spotlight returned nothing for a directory that provably contains
    /// matches, so the folder is being watched by FSEvents with a bounded
    /// manual walk behind it. Counts are complete up to the walk's bounds;
    /// updates are event-driven but coarser.
    case fallback

    /// Neither engine is available (no Spotlight, no FSEvents — an iOS build,
    /// or a volume that supports neither). The folder is only inspected when
    /// the user asks. Counts are as of the last explicit scan.
    case scanOnDemand

    /// The folder cannot be opened at all: the security-scoped bookmark did not
    /// resolve, or resolved to something that is gone. `bookmarkStale` says
    /// which — a stale bookmark can often be renewed silently, a missing
    /// directory needs the user.
    case inaccessible(bookmarkStale: Bool)

    // MARK: Presentation — rendered VERBATIM by the row

    /// The row's status text. Short enough to sit next to a folder name.
    ///
    /// These strings are the product surface of D6. A renderer must show this
    /// rather than paraphrase it, and must never substitute an empty state.
    public var label: String {
        switch self {
        case .live: return "Watching"
        case .fallback: return "Watching (no Spotlight index)"
        case .scanOnDemand: return "Scan on demand"
        case .inaccessible(let stale):
            return stale ? "Permission expired" : "Folder unavailable"
        }
    }

    /// The longer form, for a tooltip / detail line. Says what the user can
    /// expect, not what the API returned.
    public var explanation: String {
        switch self {
        case .live:
            return "Spotlight is indexing this folder. New files appear automatically."
        case .fallback:
            return "This volume is not indexed by Spotlight, so this folder is watched "
                + "directly. New files appear, but discovery is limited to "
                + "\(FolderWalkBounds.default.maxDepth) levels deep."
        case .scanOnDemand:
            return "This folder can only be scanned when you ask. Its contents may have "
                + "changed since the last scan."
        case .inaccessible(let stale):
            return stale
                ? "This app's permission to read the folder has expired. Choose it again to "
                    + "restore access."
                : "The folder could not be opened. It may have been moved, renamed, or be on "
                    + "a disconnected volume."
        }
    }

    public var systemImage: String {
        switch self {
        case .live: return "folder.badge.gearshape"
        case .fallback: return "folder.badge.questionmark"
        case .scanOnDemand: return "folder.badge.plus"
        case .inaccessible: return "folder.badge.minus"
        }
    }

    // MARK: Semantics the renderer must not re-derive

    /// Whether a count from this folder means "this is everything".
    ///
    /// **This is the invariant.** A row must show a badge only when this is
    /// true; otherwise the number is a floor, not a total, and showing it as a
    /// total is the "0 files" bug in its general form. `live` and `fallback`
    /// both complete their enumeration, so both are trustworthy; a folder that
    /// has not been scanned since the app launched, or cannot be opened, is
    /// not.
    public var countIsTrustworthy: Bool {
        switch self {
        case .live, .fallback: return true
        case .scanOnDemand, .inaccessible: return false
        }
    }

    /// Whether the row should read as a warning rather than as normal chrome.
    public var isDegraded: Bool {
        switch self {
        case .live: return false
        case .fallback, .scanOnDemand, .inaccessible: return true
        }
    }

    /// Whether asking for a refresh can plausibly change anything. A folder we
    /// cannot open needs the user to re-grant access, not a re-scan.
    public var isRefreshable: Bool {
        switch self {
        case .live, .fallback, .scanOnDemand: return true
        case .inaccessible: return false
        }
    }

    /// Whether the folder needs the user to reselect it in a panel.
    public var needsReauthorization: Bool {
        if case .inaccessible = self { return true }
        return false
    }
}

// MARK: - Walk bounds

/// How far the fallback walk is allowed to go, per ADR-0023 D7's "bounded".
///
/// A watched folder can be a home directory; an unbounded recursive walk of one
/// is the burst the ADR's risk register warns about. Bounds are DATA so a test
/// can force a tiny walk and a host can widen one for a folder it knows is
/// small.
public struct FolderWalkBounds: Hashable, Sendable, Codable {

    /// Directory levels below the watched root. 0 = the root's own files only.
    public let maxDepth: Int

    /// Hard cap on files returned. The walk stops when it is reached and says
    /// so (`DirectoryScanResult.hitLimit`), rather than silently truncating.
    public let maxFiles: Int

    /// Whether to descend into `.`-prefixed directories. Off: a watched home
    /// folder should not enumerate `.git` or `Library` caches.
    public let includesHiddenDirectories: Bool

    public init(maxDepth: Int = 8, maxFiles: Int = 20_000,
                includesHiddenDirectories: Bool = false) {
        self.maxDepth = Swift.max(0, maxDepth)
        self.maxFiles = Swift.max(0, maxFiles)
        self.includesHiddenDirectories = includesHiddenDirectories
    }

    public static let `default` = FolderWalkBounds()

    /// The probe used to answer "does this directory provably contain matches"
    /// — see `SpotlightAvailabilityProbe`. Shallow and cheap on purpose: it is
    /// asked while a query is already running, and its job is to find ONE
    /// counterexample, not to enumerate the folder.
    public static let probe = FolderWalkBounds(maxDepth: 2, maxFiles: 64)
}
