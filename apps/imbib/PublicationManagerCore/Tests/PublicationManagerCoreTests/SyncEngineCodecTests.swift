//
//  SyncEngineCodecTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0007 Phase 3 (Phase D) — offline proof of the CloudKit layer.
//
//  Everything here runs with NO iCloud account, NO container, and NO network.
//  That is the point: the codec is where a wire-format mistake becomes silent
//  data loss, and the availability gate is what stands between an unentitled
//  build and the `CKContainer` trap fixed in 5edde41. Both must be provable on
//  a machine that has never seen the container.
//

import XCTest
import CloudKit
import ImbibRustCore
import ImpressKit
@testable import PublicationManagerCore

final class SyncEngineCodecTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(
        zoneName: SyncSettings.zoneName, ownerName: CKCurrentUserDefaultName)

    // MARK: - Fixtures

    private func makeItem(
        id: String = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        payload: String = #"{"title":"Cosmology's Century","year":2020}"#,
        tags: [String] = ["topics/cosmo", "methods/sims"]
    ) -> SyncItemRecord {
        SyncItemRecord(
            id: id.lowercased(),
            schemaRef: "imbib/bibliography-entry",
            payloadJson: payload,
            logicalClock: 112_345_678_901_234,
            authorKind: "human",
            authorId: "user:tabel",
            origin: "origin-laptop",
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_500_000,
            tagPaths: tags,
            isRead: true,
            isStarred: false,
            flagColor: "red",
            flagStyle: "dashed",
            flagLength: nil,
            priority: "high",
            parentId: "11111111-2222-3333-4444-555555555555",
            envelopeJson: #"{"visibility":"private","canonical_id":"doi:10.1/x"}"#)
    }

    // MARK: - Item round-trip

    func testItemRecordRoundTripsEveryField() throws {
        let original = makeItem()
        let record = try SyncRecordCodec.encode(item: original, zoneID: zoneID)

        XCTAssertEqual(record.recordType, SyncRecordCodec.RecordType.item)
        XCTAssertEqual(record.recordID.recordName, original.id,
                       "recordName must be the lowercased item UUID")
        XCTAssertEqual(record.recordID.zoneID, zoneID)

        let decoded = try SyncRecordCodec.decodeItem(record)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.schemaRef, original.schemaRef)
        XCTAssertEqual(decoded.payloadJson, original.payloadJson)
        XCTAssertEqual(decoded.logicalClock, original.logicalClock)
        XCTAssertEqual(decoded.authorKind, original.authorKind)
        XCTAssertEqual(decoded.authorId, original.authorId)
        XCTAssertEqual(decoded.origin, original.origin)
        XCTAssertEqual(decoded.createdMs, original.createdMs)
        XCTAssertEqual(decoded.modifiedMs, original.modifiedMs)
        XCTAssertEqual(decoded.tagPaths, original.tagPaths)
        XCTAssertEqual(decoded.isRead, original.isRead)
        XCTAssertEqual(decoded.isStarred, original.isStarred)
        XCTAssertEqual(decoded.flagColor, original.flagColor)
        XCTAssertEqual(decoded.flagStyle, original.flagStyle)
        XCTAssertNil(decoded.flagLength)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.parentId, original.parentId)
        XCTAssertEqual(decoded.envelopeJson, original.envelopeJson,
                       "envelope_json carries canonical_id/visibility/... untouched")
    }

    /// CloudKit infers a Development-environment schema from the first
    /// record carrying each field, and an EMPTY list gives it no element
    /// type — the save fails outright with "cannot use an empty list to
    /// initialize a new field". Hit live on 2026-07-25 the first time an
    /// untagged paper was pushed. The encoder must therefore OMIT the
    /// field rather than write `[]`.
    func testEmptyTagPathsAreOmittedNotEmptyList() throws {
        let untagged = makeItem(tags: [])
        let record = try SyncRecordCodec.encode(item: untagged, zoneID: zoneID)
        XCTAssertNil(
            record["tag_paths"],
            "an empty tag list must be absent from the record, never []")

        // And a tagged item still carries them.
        let tagged = makeItem(tags: ["physics/cosmology"])
        let taggedRecord = try SyncRecordCodec.encode(item: tagged, zoneID: zoneID)
        XCTAssertEqual(taggedRecord["tag_paths"] as? [String], ["physics/cosmology"])
    }

    func testItemWithNoOptionalsRoundTrips() throws {
        var bare = makeItem(tags: [])
        bare = SyncItemRecord(
            id: bare.id, schemaRef: bare.schemaRef, payloadJson: "{}", logicalClock: 1,
            authorKind: "system", authorId: "system:local", origin: "o",
            createdMs: 0, modifiedMs: 0, tagPaths: [], isRead: false, isStarred: false,
            flagColor: nil, flagStyle: nil, flagLength: nil, priority: "normal",
            parentId: nil, envelopeJson: "{}")

        let decoded = try SyncRecordCodec.decodeItem(
            try SyncRecordCodec.encode(item: bare, zoneID: zoneID))
        XCTAssertNil(decoded.flagColor)
        XCTAssertNil(decoded.parentId)
        XCTAssertEqual(decoded.tagPaths, [])
        XCTAssertEqual(decoded.logicalClock, 1)
    }

    /// HLC clocks are UInt64 in Rust but Int64 in CloudKit. The bit-pattern
    /// mapping must survive even the values that would overflow a signed
    /// conversion.
    func testLargeLogicalClockSurvivesInt64Bridging() throws {
        for clock: UInt64 in [0, 1, UInt64(Int64.max), UInt64.max] {
            let item = SyncItemRecord(
                id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", schemaRef: "s", payloadJson: "{}",
                logicalClock: clock, authorKind: "human", authorId: "a", origin: "o",
                createdMs: 0, modifiedMs: 0, tagPaths: [], isRead: false, isStarred: false,
                flagColor: nil, flagStyle: nil, flagLength: nil, priority: "normal",
                parentId: nil, envelopeJson: "{}")
            let decoded = try SyncRecordCodec.decodeItem(
                try SyncRecordCodec.encode(item: item, zoneID: zoneID))
            XCTAssertEqual(decoded.logicalClock, clock, "clock \(clock) must round-trip exactly")
        }
    }

    // MARK: - Asset spill

    func testLargePayloadSpillsToAssetAndDecodesBack() throws {
        let assetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-asset-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: assetDir) }

        // Comfortably past the 700KB threshold.
        let body = String(repeating: "typst body text. ", count: 60_000)
        let payload = #"{"body_content":"# + "\"\(body)\"" + #"}"#
        XCTAssertGreaterThan(payload.utf8.count, SyncRecordCodec.assetSpillThreshold)

        let item = makeItem(payload: payload)
        let record = try SyncRecordCodec.encode(
            item: item, zoneID: zoneID, assetDirectory: assetDir)

        XCTAssertEqual(record[SyncRecordCodec.ItemField.payloadInAsset] as? Int64, 1)
        XCTAssertNotNil(record[SyncRecordCodec.ItemField.payloadAsset] as? CKAsset)
        XCTAssertNil(record[SyncRecordCodec.ItemField.payloadJSON] as? String,
                     "the inline field must be cleared when the payload spills")

        let decoded = try SyncRecordCodec.decodeItem(record)
        XCTAssertEqual(decoded.payloadJson, payload, "spilled payload must decode byte-identical")
    }

    func testSmallPayloadStaysInline() throws {
        let record = try SyncRecordCodec.encode(item: makeItem(), zoneID: zoneID)
        XCTAssertEqual(record[SyncRecordCodec.ItemField.payloadInAsset] as? Int64, 0)
        XCTAssertNil(record[SyncRecordCodec.ItemField.payloadAsset] as? CKAsset)
        XCTAssertNotNil(record[SyncRecordCodec.ItemField.payloadJSON] as? String)
    }

    func testContentBlobAssetTravelsWithDescriptorAndIsNotClearedByMissingPeer() throws {
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-content-\(UUID().uuidString).bin")
        try Data("immutable bytes".utf8).write(to: assetURL)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        let base = makeItem(payload: #"{"sha256":"abc","byte_length":15,"storage_kind":"local-cas","locator":"ab/abc"}"#)
        let blob = SyncItemRecord(
            id: base.id, schemaRef: "content-blob@1.0.0", payloadJson: base.payloadJson,
            logicalClock: base.logicalClock, authorKind: base.authorKind, authorId: base.authorId,
            origin: base.origin, createdMs: base.createdMs, modifiedMs: base.modifiedMs,
            tagPaths: [], isRead: false, isStarred: false, flagColor: nil, flagStyle: nil,
            flagLength: nil, priority: "normal", parentId: nil, envelopeJson: "{}")

        let record = try SyncRecordCodec.encode(
            item: blob, zoneID: zoneID, contentBlobURL: assetURL)
        XCTAssertEqual(SyncRecordCodec.contentBlobAssetURL(record), assetURL)

        // A metadata-only peer updating this same server record must preserve
        // the existing asset rather than publishing its local `missing` state.
        let updated = try SyncRecordCodec.encode(item: blob, zoneID: zoneID, existing: record)
        XCTAssertEqual(SyncRecordCodec.contentBlobAssetURL(updated), assetURL)
    }

    func testAssetScratchPruningRemovesOnlyOldFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fresh = dir.appendingPathComponent("fresh.json")
        let stale = dir.appendingPathComponent("stale.json")
        try Data("a".utf8).write(to: fresh)
        try Data("b".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)

        SyncRecordCodec.pruneAssetScratch(olderThan: 3600, directory: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: - Reference & tombstone

    func testReferenceRecordRoundTrips() throws {
        let reference = SyncReferenceRecord(
            recordName: "ref_0123456789abcdef0123456789abcdef",
            sourceId: "11111111-1111-1111-1111-111111111111",
            targetId: "22222222-2222-2222-2222-222222222222",
            edgeType: "\"Cites\"",
            metadata: #"{"page":12}"#,
            logicalClock: 987_654_321)

        let record = SyncRecordCodec.encode(reference: reference, zoneID: zoneID)
        XCTAssertEqual(record.recordType, SyncRecordCodec.RecordType.reference)
        XCTAssertEqual(record.recordID.recordName, reference.recordName)

        let decoded = try SyncRecordCodec.decodeReference(record)
        XCTAssertEqual(decoded.recordName, reference.recordName)
        XCTAssertEqual(decoded.sourceId, reference.sourceId)
        XCTAssertEqual(decoded.targetId, reference.targetId)
        XCTAssertEqual(decoded.edgeType, reference.edgeType)
        XCTAssertEqual(decoded.metadata, reference.metadata)
        XCTAssertEqual(decoded.logicalClock, reference.logicalClock)
    }

    func testTombstoneRecordRoundTrips() throws {
        let tombstone = SyncTombstoneRecord(
            recordName: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            schemaRef: "imbib/bibliography-entry",
            deletedAtMs: 1_700_000_900_000,
            origin: "origin-phone")

        let record = SyncRecordCodec.encode(tombstone: tombstone, zoneID: zoneID)
        XCTAssertEqual(record.recordType, SyncRecordCodec.RecordType.tombstone)
        XCTAssertEqual(record.recordID.recordName, tombstone.recordName)

        let decoded = try SyncRecordCodec.decodeTombstone(record)
        XCTAssertEqual(decoded, tombstone)
    }

    func testDecodingWrongRecordTypeThrows() {
        let record = CKRecord(
            recordType: "SomethingElse",
            recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        XCTAssertThrowsError(try SyncRecordCodec.decodeItem(record)) { error in
            XCTAssertEqual(
                error as? SyncCodecError,
                .wrongRecordType(expected: SyncRecordCodec.RecordType.item, got: "SomethingElse"))
        }
    }

    func testItemMissingPayloadThrows() {
        let record = CKRecord(
            recordType: SyncRecordCodec.RecordType.item,
            recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        record[SyncRecordCodec.ItemField.schemaRef] = "s" as CKRecordValue
        XCTAssertThrowsError(try SyncRecordCodec.decodeItem(record))
    }

    // MARK: - System fields archive

    func testSystemFieldsArchiveRestoresIdentity() throws {
        let record = try SyncRecordCodec.encode(item: makeItem(), zoneID: zoneID)
        let blob = SyncRecordCodec.archiveSystemFields(record)
        let restored = try XCTUnwrap(SyncRecordCodec.restoreSystemFields(from: blob))

        XCTAssertEqual(restored.recordID, record.recordID)
        XCTAssertEqual(restored.recordType, record.recordType)
        // System-fields archives deliberately carry NO user data — that is
        // what makes them safe to keep in the store's metadata table.
        XCTAssertNil(restored[SyncRecordCodec.ItemField.payloadJSON] as? String)
    }

    func testRestoringGarbageSystemFieldsReturnsNil() {
        XCTAssertNil(SyncRecordCodec.restoreSystemFields(from: Data("not an archive".utf8)))
    }

    // MARK: - Reference record-name parity with Rust

    /// The Swift and Rust `ref_<sha256[..32]>` implementations must agree
    /// byte-for-byte, or an edge deletion would address a record that never
    /// existed. Rather than hard-code a digest, we ask the REAL Rust store for
    /// the name it produced and compare.
    func testReferenceRecordNameMatchesRustExactly() throws {
        let path = NSTemporaryDirectory() + "sync-refname-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try ImbibStore.open(path: path)
        let library = try store.createLibrary(name: "Ref Names")
        let ids = try store.importBibtex(
            bibtex: """
            @article{A, title={Paper A}, year={2020}}
            @article{B, title={Paper B}, year={2021}}
            """,
            libraryId: library.id)
        XCTAssertEqual(ids.count, 2)

        // Imported papers are the library's CHILDREN (parent_id), which is not
        // an edge. Multi-library membership is what creates real `Contains`
        // edges — and edges are what carry `ref_` record names.
        let second = try store.createLibrary(name: "Shared Shelf")
        _ = try store.libraryAddMembers(libraryId: second.id, publicationIds: ids)

        let entries = try store.syncOutboxEntries(limit: 1000)
        let referenceEntries = entries.filter { $0.kind == "reference" }
        XCTAssertFalse(referenceEntries.isEmpty, "expected Contains edges in the outbox")

        // Rust's hashed names, straight from the snapshot API.
        let rustNames = Set(
            try store.syncSnapshotReferences(
                recordNames: referenceEntries.map(\.recordName)
            ).map(\.recordName))

        // Swift's computation of the same names.
        let swiftNames = Set(referenceEntries.compactMap {
            CloudSyncEngine.referenceRecordName(rawOutboxName: $0.recordName)
        })

        XCTAssertEqual(swiftNames, rustNames,
                       "Swift's ref_ record names must match Rust's byte-for-byte")
        for name in swiftNames {
            XCTAssertTrue(name.hasPrefix("ref_"))
            XCTAssertEqual(name.count, 36) // "ref_" + 32 hex chars
        }
    }

    func testReferenceRecordNameRejectsMalformedInput() {
        XCTAssertNil(CloudSyncEngine.referenceRecordName(rawOutboxName: "only|two"))
        XCTAssertNotNil(CloudSyncEngine.referenceRecordName(rawOutboxName: "a|b|c"))
    }
}
