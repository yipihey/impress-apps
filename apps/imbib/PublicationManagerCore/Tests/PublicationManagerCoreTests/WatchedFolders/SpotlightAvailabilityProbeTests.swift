//
//  SpotlightAvailabilityProbeTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D6 — the degraded-state decision, as a truth table.
//
//  This is the suite that matters most in W1. The risk register's second entry
//  is "Spotlight blind spots read as data loss … the folder row must never
//  render an unindexed volume as '0 files'", and the decision that prevents it
//  is four lines of pure logic. Those four lines are testable exhaustively and
//  instantly, on either platform, with no Spotlight, no volume and no sandbox —
//  which is exactly why the honest signal was defined as a pure function of
//  named conditions rather than as something the engine infers inline.
//

import XCTest

@testable import PublicationManagerCore

final class SpotlightAvailabilityProbeTests: XCTestCase {

    private func probe(
        couldStart: Bool = true,
        finished: Bool = true,
        results: Int = 0,
        localMatches: Int? = nil
    ) -> SpotlightAvailabilityProbe {
        SpotlightAvailabilityProbe(
            queryCouldStart: couldStart,
            queryDidFinishGathering: finished,
            queryResultCount: results,
            localProbeMatchCount: localMatches)
    }

    // MARK: - provesSpotlightBlindSpot

    func testZeroResultsAloneIsNotEvidenceOfABlindSpot() {
        // The tempting wrong answer. A folder with no `.bib` files in it also
        // returns zero, and flagging that folder trains the user to ignore the
        // warning that matters.
        XCTAssertFalse(probe(results: 0, localMatches: nil).provesSpotlightBlindSpot)
        XCTAssertFalse(probe(results: 0, localMatches: 0).provesSpotlightBlindSpot)
    }

    func testZeroResultsPlusALocalCounterexampleProvesABlindSpot() {
        XCTAssertTrue(probe(results: 0, localMatches: 1).provesSpotlightBlindSpot)
        XCTAssertTrue(probe(results: 0, localMatches: 12).provesSpotlightBlindSpot)
    }

    func testAStillGatheringQueryProvesNothingEvenWithACounterexample() {
        XCTAssertFalse(
            probe(finished: false, results: 0, localMatches: 3).provesSpotlightBlindSpot,
            "`isGathering` means \"not yet\", never \"nothing\"")
    }

    func testAnyResultAtAllDisprovesABlindSpot() {
        XCTAssertFalse(probe(results: 1, localMatches: 99).provesSpotlightBlindSpot)
    }

    func testNoQueryMeansNoConclusionAboutTheVolume() {
        XCTAssertFalse(
            probe(couldStart: false, results: 0, localMatches: 5).provesSpotlightBlindSpot)
    }

    // MARK: - The resolver

    func testStillGatheringIsUndeterminedAndMustNotTransition() {
        XCTAssertNil(
            WatchedFolderStateResolver.resolve(probe: probe(finished: false)),
            "nil is \"keep saying what you last honestly said\" — coercing it to "
                + ".live renders an in-flight query as a complete one")
    }

    func testAFinishedEmptyQueryOverAnEmptyFolderIsLive() {
        // The one case where a zero badge is honest: the index covers the
        // folder and there is genuinely nothing in it.
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(probe: probe(results: 0, localMatches: 0)),
            .live)
    }

    func testAFinishedNonEmptyQueryIsLive() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(probe: probe(results: 7)), .live)
    }

    func testABlindSpotBecomesFallbackWhenAFallbackEngineExists() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(results: 0, localMatches: 1),
                fallbackEngineAvailable: true),
            .fallback)
    }

    func testABlindSpotBecomesScanOnDemandWhenThereIsNoFallback() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(results: 0, localMatches: 1),
                fallbackEngineAvailable: false),
            .scanOnDemand)
    }

    func testNoLiveEngineIsScanOnDemandNotAFailure() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(probe: probe(couldStart: false)),
            .scanOnDemand)
    }

    // MARK: - Access failures outrank the Spotlight question

    func testAStaleBookmarkOutranksEverythingElse() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(results: 9),
                accessFailure: .bookmarkUnresolvable(isStale: true)),
            .inaccessible(bookmarkStale: true))
    }

    func testAMissingFolderIsInaccessibleWithoutClaimingStaleness() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(results: 0, localMatches: 0),
                accessFailure: .bookmarkUnresolvable(isStale: false)),
            .inaccessible(bookmarkStale: false))
    }

    func testDeniedAccessAndNotADirectoryAreBothInaccessible() {
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(), accessFailure: .accessDenied(path: "/x")),
            .inaccessible(bookmarkStale: false))
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(), accessFailure: .notADirectory(path: "/x")),
            .inaccessible(bookmarkStale: false))
    }

    func testNoFiltersDoesNotMasqueradeAsAnAccessProblem() {
        // `.noFilters` is a configuration bug, not a broken folder: it must
        // fall through to the normal path and land on scan-on-demand.
        XCTAssertEqual(
            WatchedFolderStateResolver.resolve(
                probe: probe(couldStart: false), accessFailure: .noFilters),
            .scanOnDemand)
    }

    // MARK: - The state's own honesty rules

    func testOnlyLiveAndFallbackCarryTrustworthyCounts() {
        XCTAssertTrue(WatchedFolderState.live.countIsTrustworthy)
        XCTAssertTrue(WatchedFolderState.fallback.countIsTrustworthy)
        XCTAssertFalse(WatchedFolderState.scanOnDemand.countIsTrustworthy)
        XCTAssertFalse(
            WatchedFolderState.inaccessible(bookmarkStale: false).countIsTrustworthy)
    }

    func testEveryDegradedStateHasANonEmptyLabelAndExplanation() {
        let states: [WatchedFolderState] = [
            .live, .fallback, .scanOnDemand,
            .inaccessible(bookmarkStale: true), .inaccessible(bookmarkStale: false),
        ]
        for state in states {
            XCTAssertFalse(
                state.label.isEmpty,
                "a state with no label cannot be rendered verbatim, which is D6's "
                    + "whole requirement")
            XCTAssertFalse(state.explanation.isEmpty)
            XCTAssertFalse(state.systemImage.isEmpty)
        }
    }

    func testAnInaccessibleFolderDoesNotOfferRefresh() {
        // "Omit the affordance rather than showing a dead one" — a folder we
        // cannot open needs re-authorisation, not a re-scan.
        XCTAssertFalse(WatchedFolderState.inaccessible(bookmarkStale: true).isRefreshable)
        XCTAssertTrue(WatchedFolderState.inaccessible(bookmarkStale: true).needsReauthorization)
        XCTAssertTrue(WatchedFolderState.scanOnDemand.isRefreshable)
        XCTAssertFalse(WatchedFolderState.live.needsReauthorization)
    }

    // MARK: - Availability as data

    func testAvailabilityIsDeclaredAsDataAndIsMacOSOnlyInV1() {
        XCTAssertEqual(FolderWatchAvailability.livePlatforms, [.macOS])
        XCTAssertNil(FolderWatchAvailability.unsupportedReason(on: .macOS))
        XCTAssertNotNil(
            FolderWatchAvailability.unsupportedReason(on: .iOS),
            "a platform that cannot do this must say WHY, in the user's words — "
                + "the SettingsSectionAvailability rule")
    }
}
