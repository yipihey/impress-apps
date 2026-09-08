//
//  EnrichmentAuthorityTests.swift
//  PublicationManagerCoreTests
//
//  D1: two enrichers watched the same population — imbib's in-app coordinator
//  and impel's task kernel — so every newly ingested paper was fetched twice
//  from the same APIs and classified twice against two vocabularies. The rule
//  that settles it is the suite's shape: impel owns orchestration whenever it
//  is installed, and a machine without impel enriches its own library.
//

import XCTest
import ImpressKit
@testable import PublicationManagerCore

final class EnrichmentAuthorityTests: XCTestCase {

    override func tearDown() {
        EnrichmentAuthorityPolicy.installedProbe = nil
        SharedDefaults.suite.removeObject(forKey: EnrichmentAuthorityPolicy.overrideKey)
        super.tearDown()
    }

    // MARK: - The rule

    func testImpelInstalledMakesImpelTheAuthority() {
        EnrichmentAuthorityPolicy.installedProbe = { true }
        XCTAssertEqual(EnrichmentAuthorityPolicy.current(), .impel)
        XCTAssertFalse(
            EnrichmentAuthorityPolicy.imbibMayEnrichAutonomously(),
            "with an orchestrator present, imbib must not also enrich"
        )
    }

    func testWithoutImpelImbibEnrichesItsOwnLibrary() {
        EnrichmentAuthorityPolicy.installedProbe = { false }
        XCTAssertEqual(EnrichmentAuthorityPolicy.current(), .imbib)
        XCTAssertTrue(
            EnrichmentAuthorityPolicy.imbibMayEnrichAutonomously(),
            "a machine with no orchestrator has nobody else to defer to"
        )
    }

    /// The decision is re-read, never cached. Installing impel between two
    /// launches — or during one — has to change the answer, or imbib keeps
    /// enriching for the life of the process after impel arrives.
    func testAuthorityFollowsInstallationRatherThanLatching() {
        EnrichmentAuthorityPolicy.installedProbe = { false }
        XCTAssertEqual(EnrichmentAuthorityPolicy.current(), .imbib)

        EnrichmentAuthorityPolicy.installedProbe = { true }
        XCTAssertEqual(
            EnrichmentAuthorityPolicy.current(), .impel,
            "the first answer must not be the permanent one"
        )
    }

    // MARK: - The escape hatch

    /// impel installed but its daemon never set up means deferring to it
    /// enriches nothing at all. The override takes the library back.
    func testOverrideForcesImbibEvenWithImpelInstalled() {
        EnrichmentAuthorityPolicy.installedProbe = { true }
        SharedDefaults.suite.set(
            EnrichmentAuthority.imbib.rawValue,
            forKey: EnrichmentAuthorityPolicy.overrideKey
        )
        XCTAssertEqual(EnrichmentAuthorityPolicy.current(), .imbib)
        XCTAssertTrue(EnrichmentAuthorityPolicy.imbibMayEnrichAutonomously())
    }

    func testOverrideForcesImpelEvenWithoutItInstalled() {
        EnrichmentAuthorityPolicy.installedProbe = { false }
        SharedDefaults.suite.set(
            EnrichmentAuthority.impel.rawValue,
            forKey: EnrichmentAuthorityPolicy.overrideKey
        )
        XCTAssertEqual(EnrichmentAuthorityPolicy.current(), .impel)
    }

    /// An unrecognised override is not a vote. Guessing which way a typo meant
    /// is worse than falling back to the automatic answer.
    func testUnrecognisedOverrideFallsBackToTheAutomaticRule() {
        EnrichmentAuthorityPolicy.installedProbe = { true }
        SharedDefaults.suite.set("whatever", forKey: EnrichmentAuthorityPolicy.overrideKey)
        XCTAssertEqual(EnrichmentAuthorityPolicy.current(), .impel)
    }

    // MARK: - What the coordinator does with it

    /// Standing down is a decision the coordinator records, not a silent
    /// no-op: `authority` is what a status surface reads to answer "so who IS
    /// enriching my library?"
    func testCoordinatorReportsTheAuthorityItDeferredTo() async {
        EnrichmentAuthorityPolicy.installedProbe = { true }
        let coordinator = EnrichmentCoordinator()
        await coordinator.start()
        let authority = await coordinator.authority
        XCTAssertEqual(authority, .impel)
        let depth = await coordinator.queueDepth()
        XCTAssertEqual(depth, 0, "a stood-down coordinator queues nothing")
    }

    /// Autonomous work defers; the feed refresher's immediate enrichment is
    /// autonomous, so it returns zero rather than racing impel to the API.
    func testImmediateBatchEnrichmentDefersToImpel() async {
        EnrichmentAuthorityPolicy.installedProbe = { true }
        let coordinator = EnrichmentCoordinator()
        let enriched = await coordinator.enrichBatchByIDs([UUID(), UUID()])
        XCTAssertEqual(enriched, 0)
    }

    /// Every authority explains itself in one line — these strings reach the
    /// console the user watches while wondering why nothing is happening.
    func testEveryAuthorityExplainsItself() {
        for authority in EnrichmentAuthority.allCases {
            XCTAssertFalse(authority.explanation.isEmpty, "\(authority) has no explanation")
        }
    }
}

// MARK: - The setting the authority actually runs on

/// imbib's settings live in its own defaults domain; impel-taskd is a
/// different sandboxed executable that cannot read them. Once impel became the
/// enrichment authority, an order configured only there was an order the
/// enricher never saw — so it is mirrored to the shared workspace, in the
/// exact JSON `imbib_core::enrichment::priority` parses. Rust treats that
/// list as a PREFIX over its own larger default order, since imbib's settings
/// enum offers only three of the eight sources Rust ranks.
final class EnrichmentPreferencesMirrorTests: XCTestCase {

    private var mirrorURL: URL {
        SharedWorkspace.workspaceDirectory
            .appendingPathComponent("enrichment", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: mirrorURL)
        super.tearDown()
    }

    func testMirrorWritesTheShapeRustParses() throws {
        EnrichmentSettingsStore.persistSourcePriorityForDaemon([.ads, .openalex])

        let data = try Data(contentsOf: mirrorURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try XCTUnwrap(object)

        // These two keys and this version are the contract with
        // `the_swift_written_file_shape_parses`. A rename on either side reads
        // as "no preference" and silently reverts the daemon to its built-in
        // order — indistinguishable from a user who configured nothing.
        XCTAssertEqual(decoded["version"] as? Int, 1)
        XCTAssertEqual(decoded["source_priority"] as? [String], ["ads", "openalex"])
    }

    /// Order is the whole point — a set would lose it.
    func testMirrorPreservesTheConfiguredOrder() throws {
        EnrichmentSettingsStore.persistSourcePriorityForDaemon([.openalex, .ads])
        let data = try Data(contentsOf: mirrorURL)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            decoded["source_priority"] as? [String], ["openalex", "ads"],
            "the user putting OpenAlex ahead of ADS must survive the round trip"
        )
    }
}
