//
//  SyncEngineRoundTripTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0007 Phase 3 (Phase C) — adapter-level proof that the CloudKit sync
//  surface exported through the ImbibStore FFI round-trips: the Swift side
//  can drain one store's outbox, ship the snapshots, and converge a second
//  store, exactly the loop CloudSyncEngine (Phase D) will drive with
//  CKRecords in the middle.
//
//  Deliberately NOT RustStoreAdapter.shared: the adapter is a singleton on
//  the (test-diverted) shared workspace. Peer sync needs two INDEPENDENT
//  stores, so we open two ImbibStore handles on two temp files — the same
//  explicit-temp-path pattern as ManuscriptRevisionRoundTripTests. The heavy
//  convergence torture lives in Rust (sync_convergence.rs); this test pins
//  the FFI boundary: names, shapes, and the drain→apply→confirm protocol.
//

import XCTest
import ImbibRustCore
@testable import PublicationManagerCore

final class SyncEngineRoundTripTests: XCTestCase {

    private var pathA = ""
    private var pathB = ""

    override func setUp() {
        super.setUp()
        pathA = NSTemporaryDirectory() + "sync-peer-a-\(UUID().uuidString).sqlite"
        pathB = NSTemporaryDirectory() + "sync-peer-b-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: pathA)
        try? FileManager.default.removeItem(atPath: pathB)
        super.tearDown()
    }

    /// Drain `source`'s outbox and apply it to `target` — the Phase D loop
    /// without CloudKit in the middle.
    private func exchange(from source: ImbibStore, to target: ImbibStore) throws {
        let entries = try source.syncOutboxEntries(limit: 10_000)

        var itemIds: [String] = []
        var refNames: [String] = []
        var deletedIds = Set<String>()
        for entry in entries {
            switch entry.kind {
            case "item": itemIds.append(entry.recordName)
            case "reference": refNames.append(entry.recordName)
            case "delete_item": deletedIds.insert(entry.recordName)
            case "delete_reference": break // exercised via Rust suite; none here
            default: XCTFail("unexpected outbox kind \(entry.kind)")
            }
        }

        let items = try source.syncSnapshotItems(ids: itemIds)
        let refs = try source.syncSnapshotReferences(recordNames: refNames)
        let tombstones = try source.syncLocalTombstones(sinceMs: 0)
            .filter { deletedIds.contains($0.recordName) }

        _ = try target.syncApplyRemoteItems(records: items)
        _ = try target.syncApplyRemoteReferences(refs: refs)
        _ = try target.syncApplyRemoteTombstones(tombstones: tombstones)
        _ = try target.syncRetryPendingReferences()

        try source.syncOutboxRemove(seqs: entries.map(\.seq))
    }

    func testInsertDrainsApplyAndConverges() throws {
        let a = try ImbibStore.open(path: pathA)
        let b = try ImbibStore.open(path: pathB)

        // A: a library with one imported publication (library + paper + edges
        // all flow through the outbox triggers).
        let library = try a.createLibrary(name: "Sync Test")
        let pubIds = try a.importBibtex(
            bibtex: "@article{Peebles2020, title={Cosmology's Century}, author={Peebles, P. J. E.}, year={2020}}",
            libraryId: library.id)
        let pubId = try XCTUnwrap(pubIds.first)

        // Outbox captured the writes.
        let counts = try a.syncStatusCounts()
        XCTAssertGreaterThan(counts.outbox, 0, "local writes must enqueue")

        try exchange(from: a, to: b)

        // A's outbox drained; B materialized the publication verbatim.
        XCTAssertEqual(try a.syncOutboxEntries(limit: 10).count, 0)
        let onB = try b.syncSnapshotItems(ids: [pubId.lowercased()])
        XCTAssertEqual(onB.count, 1, "B must hold the replicated publication")
        let record = try XCTUnwrap(onB.first)
        XCTAssertTrue(record.payloadJson.contains("Cosmology"), "payload travels verbatim")
        XCTAssertGreaterThan(record.logicalClock, 0, "HLC clock travels with the record")

        // Applying on B is suppressed: nothing echoes into B's outbox.
        XCTAssertEqual(
            try b.syncOutboxEntries(limit: 10).count, 0,
            "remote apply must not re-enqueue")

        // The replicated snapshots are byte-identical across the peers.
        let onA = try a.syncSnapshotItems(ids: [pubId.lowercased()])
        XCTAssertEqual(onA.first?.payloadJson, record.payloadJson)
        XCTAssertEqual(onA.first?.logicalClock, record.logicalClock)
        XCTAssertEqual(onA.first?.envelopeJson, record.envelopeJson)
    }

    func testDeletePropagatesViaTombstone() throws {
        let a = try ImbibStore.open(path: pathA)
        let b = try ImbibStore.open(path: pathB)

        let library = try a.createLibrary(name: "Sync Test")
        let pubIds = try a.importBibtex(
            bibtex: "@article{Zel1970, title={Gravitational instability}, year={1970}}",
            libraryId: library.id)
        let pubId = try XCTUnwrap(pubIds.first)

        try exchange(from: a, to: b)
        XCTAssertEqual(try b.syncSnapshotItems(ids: [pubId.lowercased()]).count, 1)

        // A deletes → tombstone + delete_item outbox entry → B applies → gone.
        try a.deletePublications(ids: [pubId])
        let entries = try a.syncOutboxEntries(limit: 100)
        XCTAssertTrue(
            entries.contains { $0.kind == "delete_item" && $0.recordName == pubId.lowercased() },
            "delete must enqueue a delete_item entry")

        try exchange(from: a, to: b)

        XCTAssertEqual(
            try b.syncSnapshotItems(ids: [pubId.lowercased()]).count, 0,
            "the tombstone must delete B's replica")
        XCTAssertEqual(try a.syncOutboxEntries(limit: 10).count, 0)
        XCTAssertGreaterThan(
            try b.syncStatusCounts().tombstones, 0,
            "the applied remote tombstone is recorded for duplicate-delivery safety")
    }

    func testMetadataAndRecordStateSurvivePassThrough() throws {
        let a = try ImbibStore.open(path: pathA)

        // Engine-state plumbing the CloudSyncEngine will lean on.
        try a.syncMetadataSet(key: "sync.engine_state", value: "blob-v1")
        XCTAssertEqual(try a.syncMetadataGet(key: "sync.engine_state"), "blob-v1")
        try a.syncMetadataSet(key: "sync.engine_state", value: nil)
        XCTAssertNil(try a.syncMetadataGet(key: "sync.engine_state"))
        XCTAssertThrowsError(try a.syncMetadataSet(key: "origin_id", value: "hijack")) { _ in }

        let blob = Data([0x00, 0x7F, 0xFF, 0x42])
        try a.syncRecordStateSet(recordName: "rec-1", blob: blob)
        XCTAssertEqual(try a.syncRecordStateGet(recordName: "rec-1"), blob)
        try a.syncRecordStateDelete(recordName: "rec-1")
        XCTAssertNil(try a.syncRecordStateGet(recordName: "rec-1"))
    }
}
