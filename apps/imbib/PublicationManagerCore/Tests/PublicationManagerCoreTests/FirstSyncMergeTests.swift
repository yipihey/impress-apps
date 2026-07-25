//
//  FirstSyncMergeTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0007 Phase 3 (Phase D): the overlapping-libraries merge.
//
//  The load-bearing property is SYMMETRY. Two devices run this pass
//  independently, with no coordination and in either order, and must reach the
//  same survivor — otherwise each deletes the other's copy and the paper
//  disappears from both. These tests drive two real temp `ImbibStore` handles
//  (same pattern as the Phase C round-trip tests) and assert both sides agree.
//

import XCTest
import ImbibRustCore
@testable import PublicationManagerCore

final class FirstSyncMergeTests: XCTestCase {

    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    private func makeStore() throws -> ImbibStore {
        let path = NSTemporaryDirectory() + "first-sync-merge-\(UUID().uuidString).sqlite"
        paths.append(path)
        return try ImbibStore.open(path: path)
    }

    /// Two publications of the same paper, each with its own origin — the
    /// cross-device duplicate FirstSyncMerge exists to collapse.
    ///
    /// Note the two-step construction: `importBibtex` deduplicates by DOI, so
    /// importing the same DOI twice yields ONE item. That is correct behavior
    /// for imports — but it is not how this duplicate arises in the field.
    /// Sync replicates items verbatim (no import dedup), so a device ends up
    /// holding two distinct items that happen to share a DOI. We reproduce
    /// exactly that: import under different DOIs, then align them.
    @discardableResult
    private func seedCrossDeviceDuplicate(
        in store: ImbibStore,
        doi: String = "10.1146/annurev-cosmo-2020",
        firstOrigin: String = "device-alpha",
        secondOrigin: String = "device-beta"
    ) throws -> (library: String, first: String, second: String) {
        let library = try store.createLibrary(name: "Papers")

        let firstIDs = try store.importBibtex(
            bibtex: "@article{A2020, title={Cosmology's Century}, doi={\(doi)}, year={2020}}",
            libraryId: library.id)
        let secondIDs = try store.importBibtex(
            bibtex: """
            @article{B2020, title={Cosmologys Century (arXiv)}, \
            doi={\(doi)-alt}, year={2020}}
            """,
            libraryId: library.id)

        let first = try XCTUnwrap(firstIDs.first)
        let second = try XCTUnwrap(secondIDs.first)
        XCTAssertNotEqual(first, second, "the fixture must be two DISTINCT items")

        // Now they collide on DOI, as they would after replication.
        _ = try store.updateField(id: second, field: "doi", value: doi)

        // Distinct origins = the papers came from different devices.
        try store.setItemOrigin(id: first, origin: firstOrigin)
        try store.setItemOrigin(id: second, origin: secondOrigin)

        return (library.id, first, second)
    }

    private func survivorAndLoser(_ a: String, _ b: String) -> (String, String) {
        a.lowercased() < b.lowercased() ? (a, b) : (b, a)
    }

    // MARK: - Core behavior

    func testCrossDeviceDuplicateCollapsesToSmallestUUID() throws {
        let store = try makeStore()
        let seeded = try seedCrossDeviceDuplicate(in: store)
        let (expectedSurvivor, expectedLoser) = survivorAndLoser(seeded.first, seeded.second)

        let report = try FirstSyncMerge.run(store: store)

        XCTAssertEqual(report.duplicateGroups, 1)
        XCTAssertEqual(report.groupsMerged, 1)
        XCTAssertEqual(report.publicationsRemoved, 1)

        XCTAssertNotNil(try store.getPublication(id: expectedSurvivor),
                        "the lexicographically smallest UUID must survive")
        XCTAssertNil(try store.getPublication(id: expectedLoser),
                     "the loser must be deleted")
    }

    /// The whole point: whichever device runs the pass, the same paper wins.
    func testSurvivorSelectionIsSymmetricAcrossDevices() throws {
        let deviceA = try makeStore()
        let deviceB = try makeStore()

        // Same two item UUIDs on both devices (that is what sync produces).
        let seededA = try seedCrossDeviceDuplicate(in: deviceA)
        let libraryB = try deviceB.createLibrary(name: "Papers")
        // Recreate the identical pair on B by importing the same records and
        // forcing the same identity via canonical ids is impossible through
        // BibTeX import, so we instead assert the RULE is a pure function of
        // the UUID pair — evaluated in both possible orders.
        _ = libraryB

        let (survivorForward, _) = survivorAndLoser(seededA.first, seededA.second)
        let (survivorReverse, _) = survivorAndLoser(seededA.second, seededA.first)
        XCTAssertEqual(survivorForward, survivorReverse,
                       "survivor choice must not depend on which side is examined first")

        // And the real pass on device A agrees with that pure rule.
        _ = try FirstSyncMerge.run(store: deviceA)
        XCTAssertNotNil(try deviceA.getPublication(id: survivorForward))
    }

    /// Running the merge on both peers must converge on the SAME survivor id,
    /// with each store independently reaching the verdict.
    func testBothPeersIndependentlyKeepTheSameSurvivor() throws {
        // Build the same duplicate pair on two stores by replicating the exact
        // records through the sync surface — this is the real cross-device
        // shape, ids included.
        let deviceA = try makeStore()
        let deviceB = try makeStore()
        let seeded = try seedCrossDeviceDuplicate(in: deviceA)

        // Ship A's whole state to B (drain → apply), so B holds the same two
        // items with the same UUIDs and origins.
        let entries = try deviceA.syncOutboxEntries(limit: 10_000)
        let itemIDs = entries.filter { $0.kind == "item" }.map(\.recordName)
        let records = try deviceA.syncSnapshotItems(ids: itemIDs)
        _ = try deviceB.syncApplyRemoteItems(records: records)
        let refNames = entries.filter { $0.kind == "reference" }.map(\.recordName)
        _ = try deviceB.syncApplyRemoteReferences(
            refs: try deviceA.syncSnapshotReferences(recordNames: refNames))
        _ = try deviceB.syncRetryPendingReferences()

        let reportA = try FirstSyncMerge.run(store: deviceA)
        let reportB = try FirstSyncMerge.run(store: deviceB)

        XCTAssertEqual(reportA.groupsMerged, 1)
        XCTAssertEqual(reportB.groupsMerged, 1, "B must independently reach the same verdict")

        let (survivor, loser) = survivorAndLoser(seeded.first, seeded.second)
        for (name, store) in [("A", deviceA), ("B", deviceB)] {
            XCTAssertNotNil(try store.getPublication(id: survivor),
                            "survivor must be alive on device \(name)")
            XCTAssertNil(try store.getPublication(id: loser),
                         "loser must be gone on device \(name)")
        }
    }

    // MARK: - Data preservation

    func testMergeUnionsTagsAndOrsReadAndStarred() throws {
        let store = try makeStore()
        let seeded = try seedCrossDeviceDuplicate(in: store)
        let (survivor, loser) = survivorAndLoser(seeded.first, seeded.second)

        // Knowledge lives only on the loser — it must not be lost.
        _ = try store.addTag(ids: [loser], tagPath: "topics/cosmology")
        _ = try store.setRead(ids: [loser], read: true)
        _ = try store.setStarred(ids: [loser], starred: true)
        _ = try store.addTag(ids: [survivor], tagPath: "methods/sims")

        let report = try FirstSyncMerge.run(store: store)
        XCTAssertGreaterThan(report.tagsUnioned, 0)

        let merged = try XCTUnwrap(try store.getPublication(id: survivor))
        let tags = Set(merged.tags.map(\.path))
        XCTAssertTrue(tags.contains("topics/cosmology"), "the loser's tag must be carried over")
        XCTAssertTrue(tags.contains("methods/sims"), "the survivor's own tag must remain")
        XCTAssertTrue(merged.isRead, "read on either device means read")
        XCTAssertTrue(merged.isStarred, "starred on either device means starred")
    }

    func testMergedLoserLeavesATombstoneSoPeersNoOp() throws {
        let store = try makeStore()
        let seeded = try seedCrossDeviceDuplicate(in: store)
        let (_, loser) = survivorAndLoser(seeded.first, seeded.second)

        _ = try FirstSyncMerge.run(store: store)

        let tombstones = try store.syncLocalTombstones(sinceMs: 0)
        XCTAssertTrue(
            tombstones.contains { $0.recordName == loser.lowercased() },
            "deleting through the normal path must record a tombstone for the peer")
    }

    // MARK: - Restraint

    /// Same-origin duplicates are the user's own local double-import. Silently
    /// deleting one would be a surprise — that stays the manual dedup UI's job.
    func testLocalOnlyDuplicatesAreLeftAlone() throws {
        let store = try makeStore()
        let seeded = try seedCrossDeviceDuplicate(
            in: store, firstOrigin: "same-device", secondOrigin: "same-device")

        let report = try FirstSyncMerge.run(store: store)

        XCTAssertEqual(report.duplicateGroups, 1)
        XCTAssertEqual(report.groupsMerged, 0)
        XCTAssertEqual(report.groupsSkippedSingleOrigin, 1)
        XCTAssertNotNil(try store.getPublication(id: seeded.first))
        XCTAssertNotNil(try store.getPublication(id: seeded.second),
                        "local duplicates must survive untouched")
    }

    func testPublicationsWithoutIdentifiersAreNeverMerged() throws {
        let store = try makeStore()
        let library = try store.createLibrary(name: "Papers")
        let ids = try store.importBibtex(
            bibtex: """
            @article{X, title={Untitled Note One}, year={2020}}
            @article{Y, title={Untitled Note Two}, year={2020}}
            """,
            libraryId: library.id)
        try store.setItemOrigin(id: ids[0], origin: "device-alpha")
        try store.setItemOrigin(id: ids[1], origin: "device-beta")

        let report = try FirstSyncMerge.run(store: store)

        XCTAssertEqual(report.duplicateGroups, 0, "no identifier means nothing to pair on")
        XCTAssertEqual(report.publicationsRemoved, 0)
        for id in ids { XCTAssertNotNil(try store.getPublication(id: id)) }
    }

    func testMergeIsIdempotent() throws {
        let store = try makeStore()
        _ = try seedCrossDeviceDuplicate(in: store)

        let first = try FirstSyncMerge.run(store: store)
        let second = try FirstSyncMerge.run(store: store)

        XCTAssertEqual(first.publicationsRemoved, 1)
        XCTAssertEqual(second.publicationsRemoved, 0, "a second pass must find nothing to do")
        XCTAssertEqual(second.groupsMerged, 0)
    }

    func testCleanLibraryIsUntouched() throws {
        let store = try makeStore()
        let library = try store.createLibrary(name: "Papers")
        let ids = try store.importBibtex(
            bibtex: """
            @article{A, title={Paper A}, doi={10.1/a}, year={2020}}
            @article{B, title={Paper B}, doi={10.1/b}, year={2021}}
            """,
            libraryId: library.id)

        let report = try FirstSyncMerge.run(store: store)

        XCTAssertEqual(report.duplicateGroups, 0)
        XCTAssertEqual(report.publicationsRemoved, 0)
        for id in ids { XCTAssertNotNil(try store.getPublication(id: id)) }
    }

    // MARK: - Grouping rules

    func testIdentifierNormalizationPairsCaseAndWhitespaceVariants() {
        XCTAssertEqual(FirstSyncMerge.normalize("  10.1234/ABC  "), "10.1234/abc")
        XCTAssertNil(FirstSyncMerge.normalize("   "))
        XCTAssertNil(FirstSyncMerge.normalize(nil))
    }

    func testGroupKeyPrefersDoiThenBibcodeThenArxiv() {
        func candidate(doi: String?, bibcode: String?, arxiv: String?) -> FirstSyncMerge.Candidate {
            FirstSyncMerge.Candidate(
                id: "x", doi: doi, arxivID: arxiv, bibcode: bibcode,
                isRead: false, isStarred: false, tagPaths: [], libraryIDs: [])
        }
        XCTAssertEqual(
            FirstSyncMerge.groupKey(for: candidate(doi: "d", bibcode: "b", arxiv: "a")), "doi:d")
        XCTAssertEqual(
            FirstSyncMerge.groupKey(for: candidate(doi: nil, bibcode: "b", arxiv: "a")), "bibcode:b")
        XCTAssertEqual(
            FirstSyncMerge.groupKey(for: candidate(doi: nil, bibcode: nil, arxiv: "a")), "arxiv:a")
        XCTAssertNil(
            FirstSyncMerge.groupKey(for: candidate(doi: nil, bibcode: nil, arxiv: nil)))
    }
}
