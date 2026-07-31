// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). PURE: no I/O, no
// NSMetadataQuery, no FileManager. Every input is supplied by the caller, which
// is the entire reason D6's hardest decision is unit-testable.
//
//  SpotlightAvailabilityProbe.swift
//  PublicationManagerCore
//
//  ADR-0023 D6 — how the watcher knows Spotlight cannot see a folder.
//
//  ── The wrong answer, first, because it is the tempting one ─────────────────
//
//  "`NSMetadataQuery` returned nothing for a directory, therefore the volume is
//  not indexed."
//
//  This is not detection. It is a coin flip dressed as one, and it is wrong in
//  both directions:
//
//    * A watched folder that genuinely contains no `.bib` files returns nothing
//      too. Treating that as "unindexed volume" puts a permanent warning on a
//      perfectly healthy folder and trains the user to ignore the warning that
//      matters.
//    * A folder on a half-indexed volume returns SOME results. "Nonzero"
//      therefore does not prove the index is complete either — but nothing
//      short of a full walk does, and a full walk of every watched folder on
//      every launch is the thing Spotlight exists to avoid. v1 accepts that
//      limit and says so here rather than pretending otherwise.
//
//  ── The honest signal ───────────────────────────────────────────────────────
//
//  A query that FINISHED GATHERING with zero results, over a directory where a
//  direct, shallow `FileManager` probe found at least one file the same filters
//  claim, is a contradiction that only one explanation fits: the index does not
//  cover this directory. That is a counterexample, not an inference from
//  absence, and it is the signal this file encodes.
//
//  Three conditions, all load-bearing:
//
//    1. **Finished.** `isGathering == true` means "not yet", never "nothing".
//       A query still gathering must produce NO state transition at all — hence
//       `resolve` returning `nil` for "undetermined", and hence the row keeping
//       whatever it last honestly said.
//    2. **Zero results.** One result is enough to prove the index reaches here.
//    3. **A local counterexample.** The probe walks two levels and stops at the
//       first match (`DirectoryScanner.probeForMatches`). It costs one
//       `contentsOfDirectory` on the common path and it is the only part of
//       this that can distinguish "empty folder" from "invisible folder".
//

import Foundation

/// The four facts the state decision is made from, gathered by the caller.
///
/// A struct rather than four parameters so a test can name them, and so the
/// engine that fills it in cannot silently reorder two `Bool`s.
public struct SpotlightAvailabilityProbe: Hashable, Sendable {

    /// Whether a live query engine exists at all in this build (macOS) and
    /// could be started for this folder.
    ///
    /// False on iOS, and false on macOS when the predicate came back nil
    /// (no filters). Either way there is nothing to conclude about the volume.
    public let queryCouldStart: Bool

    /// `NSMetadataQueryDidFinishGathering` has fired. Until it does, NOTHING is
    /// known — see condition 1 in the file header.
    public let queryDidFinishGathering: Bool

    /// How many results the finished query holds.
    public let queryResultCount: Int

    /// How many matches a direct shallow `FileManager` walk found. The
    /// counterexample. `nil` means the probe was not run (or could not run),
    /// which — like a still-gathering query — is an absence of evidence and is
    /// treated as such.
    public let localProbeMatchCount: Int?

    public init(
        queryCouldStart: Bool,
        queryDidFinishGathering: Bool,
        queryResultCount: Int,
        localProbeMatchCount: Int?
    ) {
        self.queryCouldStart = queryCouldStart
        self.queryDidFinishGathering = queryDidFinishGathering
        self.queryResultCount = queryResultCount
        self.localProbeMatchCount = localProbeMatchCount
    }

    /// The contradiction, named. True ⇔ the index provably does not cover this
    /// directory.
    ///
    /// This is the property to assert in a test; `WatchedFolderStateResolver`
    /// only decides what to DO about it.
    public var provesSpotlightBlindSpot: Bool {
        guard queryCouldStart, queryDidFinishGathering, queryResultCount == 0 else {
            return false
        }
        guard let local = localProbeMatchCount else { return false }
        return local > 0
    }
}

/// The state a folder should be in, given what is known about it.
///
/// Separate from the probe so the decision is a total function of named
/// conditions, and so the same resolver serves the accessibility failures
/// (which have nothing to do with Spotlight) without a second code path.
public enum WatchedFolderStateResolver {

    /// The resolved state, or `nil` for **undetermined — do not transition**.
    ///
    /// `nil` is not a failure case and must not be coerced into one. It is the
    /// answer while a query is still gathering, and the row must go on showing
    /// what it last honestly showed. Collapsing it into `.live` would render an
    /// in-flight query as a complete one; collapsing it into `.fallback` would
    /// put a warning on every folder for the first second of its life.
    ///
    /// - Parameters:
    ///   - probe: what the query and the local walk know.
    ///   - accessFailure: a bookmark/permission problem, which outranks
    ///     everything — a folder we cannot open has no Spotlight question.
    ///   - fallbackEngineAvailable: whether an FSEvents+walk engine exists here.
    ///     macOS: yes. iOS: no, so a blind spot degrades to `scanOnDemand`
    ///     rather than to a fallback that cannot run.
    public static func resolve(
        probe: SpotlightAvailabilityProbe,
        accessFailure: FolderWatchFailure? = nil,
        fallbackEngineAvailable: Bool = FolderWatchAvailability.isLiveHere
    ) -> WatchedFolderState? {

        // 1. Access outranks everything. There is no useful thing to say about
        //    the index of a directory we cannot open.
        if let accessFailure {
            switch accessFailure {
            case .bookmarkUnresolvable, .accessDenied, .notADirectory:
                return accessFailure.resultingState
            case .noFilters, .noLiveEngineOnThisPlatform:
                break  // handled below, where the fallback answer lives
            }
        }

        // 2. No live engine (iOS, or no derivable predicate). Honest answer is
        //    scan-on-demand: the folder can still be walked when asked.
        guard probe.queryCouldStart else { return .scanOnDemand }

        // 3. Still gathering — undetermined. Do NOT transition.
        guard probe.queryDidFinishGathering else { return nil }

        // 4. The contradiction. Degrade to whatever this build can actually do.
        if probe.provesSpotlightBlindSpot {
            return fallbackEngineAvailable ? .fallback : .scanOnDemand
        }

        // 5. A finished query with zero results and no counterexample is an
        //    EMPTY FOLDER, and saying `.live` about it is correct: the index
        //    covers it, there is simply nothing there. The row shows "Watching"
        //    with a zero — which is the one case where zero is not a lie.
        return .live
    }
}
