//
//  SyncRecordCodec.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D): CKRecord ⇄ Rust sync DTO translation.
//
//  This file is deliberately PURE — it constructs and reads `CKRecord`s but
//  never talks to a CloudKit *server*, so every path here is unit-testable
//  with no account, no container, and no network. That matters: the codec is
//  where wire-format mistakes become silent data loss, and it must be provable
//  offline.
//
//  ## Schema (ADR-0007 D27 + our amendments)
//
//  Three record types in the `ImpressGraph` zone:
//
//  - **ImpressItem** — recordName = lowercased item UUID. Envelope columns
//    that CloudKit shouldn't have to know about are folded into
//    `envelope_json` (decision 4: canonical_id, visibility, message_type,
//    produced_by, version, batch_id), so the CK schema stays frozen as the
//    Rust envelope grows.
//  - **ImpressReference** — recordName = the `ref_<sha256(src|tgt|edge)[..32]>`
//    name the Rust side already computes (decision 5); deletion of an edge is
//    a CKRecord deletion, not a tombstone.
//  - **ImpressTombstone** — recordName = lowercased item UUID (decision 3).
//
//  ## Large payloads
//
//  CloudKit rejects records whose total field size exceeds ~1MB. Manuscript
//  bodies can approach that, so `payload_json` above `assetSpillThreshold`
//  (700KB) moves into a `CKAsset` (`payload_asset`) with `payload_in_asset`
//  set; decode reverses it transparently. `content-blob@1.0.0` records also
//  carry their immutable bytes in `content_asset`; Rust verifies SHA-256 and
//  length before accepting a fetched asset into the local CAS.
//

import Foundation
import CloudKit
import ImbibRustCore
import ImpressLogging
import OSLog

/// Errors the codec can raise. All are programmer/wire errors, not user errors.
public enum SyncCodecError: Error, LocalizedError, Equatable {
    case wrongRecordType(expected: String, got: String)
    case missingField(String, recordType: String)
    case assetUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .wrongRecordType(let expected, let got):
            return "Expected a \(expected) record, got \(got)"
        case .missingField(let field, let recordType):
            return "\(recordType) record is missing required field '\(field)'"
        case .assetUnreadable(let name):
            return "Could not read the payload asset for record \(name)"
        }
    }
}

/// Translates between CloudKit records and the Rust sync DTOs.
public enum SyncRecordCodec {

    // MARK: - Schema constants

    public enum RecordType {
        public static let item = "ImpressItem"
        public static let reference = "ImpressReference"
        public static let tombstone = "ImpressTombstone"
    }

    enum ItemField {
        static let schemaRef = "schema_ref"
        static let payloadJSON = "payload_json"
        static let payloadAsset = "payload_asset"
        static let payloadInAsset = "payload_in_asset"
        static let contentAsset = "content_asset"
        static let logicalClock = "logical_clock"
        static let authorKind = "author_kind"
        static let authorID = "author_id"
        static let origin = "origin"
        static let createdMs = "created_ms"
        static let modifiedMs = "modified_ms"
        static let tagPaths = "tag_paths"
        static let isRead = "is_read"
        static let isStarred = "is_starred"
        static let flagColor = "flag_color"
        static let flagStyle = "flag_style"
        static let flagLength = "flag_length"
        static let priority = "priority"
        static let parentID = "parent_id"
        static let envelopeJSON = "envelope_json"
    }

    enum ReferenceField {
        static let sourceID = "source_id"
        static let targetID = "target_id"
        static let edgeType = "edge_type"
        static let metadata = "metadata"
        static let logicalClock = "logical_clock"
    }

    enum TombstoneField {
        static let schemaRef = "schema_ref"
        static let deletedAtMs = "deleted_at_ms"
        static let origin = "origin"
    }

    /// Payloads larger than this move into a `CKAsset`. CloudKit's per-record
    /// ceiling is ~1MB across all fields; 700KB leaves room for the envelope
    /// and CloudKit's own overhead.
    public static let assetSpillThreshold = 700 * 1024

    // MARK: - Item

    /// Encode an item record for CloudKit.
    ///
    /// - Parameters:
    ///   - record: the Rust DTO to encode.
    ///   - zoneID: the destination zone.
    ///   - existing: a server-materialized `CKRecord` to update in place
    ///     (carries the change tag needed to avoid spurious conflicts). When
    ///     nil a fresh record is minted.
    ///   - assetDirectory: where spill files are written (defaults to the
    ///     shared scratch directory).
    public static func encode(
        item: SyncItemRecord,
        zoneID: CKRecordZone.ID,
        existing: CKRecord? = nil,
        assetDirectory: URL? = nil,
        contentBlobURL: URL? = nil
    ) throws -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: RecordType.item,
            recordID: CKRecord.ID(recordName: recordName(forItemID: item.id), zoneID: zoneID))

        record[ItemField.schemaRef] = item.schemaRef as CKRecordValue
        record[ItemField.logicalClock] = clockToInt64(item.logicalClock) as CKRecordValue
        record[ItemField.authorKind] = item.authorKind as CKRecordValue
        record[ItemField.authorID] = item.authorId as CKRecordValue
        record[ItemField.origin] = item.origin as CKRecordValue
        record[ItemField.createdMs] = item.createdMs as CKRecordValue
        record[ItemField.modifiedMs] = item.modifiedMs as CKRecordValue
        // Empty list ⇒ omit the field entirely. CloudKit infers the schema of
        // a Development environment from the first record carrying each
        // field, and an empty list gives it no element type to infer:
        //   "cannot use an empty list to initialize a new field
        //    (field 'tag_paths' in record type 'ImpressItem')"
        // — a hard save failure, hit live the first time an untagged paper
        // was pushed. Absent and empty are equivalent on decode (`?? []`),
        // so omitting loses nothing; clearing a paper's last tag still
        // works because CKRecord treats assigning nil as a field delete.
        if item.tagPaths.isEmpty {
            record[ItemField.tagPaths] = nil as CKRecordValue?
        } else {
            record[ItemField.tagPaths] = item.tagPaths as CKRecordValue
        }
        record[ItemField.isRead] = (item.isRead ? 1 : 0) as CKRecordValue
        record[ItemField.isStarred] = (item.isStarred ? 1 : 0) as CKRecordValue
        record[ItemField.flagColor] = item.flagColor as CKRecordValue?
        record[ItemField.flagStyle] = item.flagStyle as CKRecordValue?
        record[ItemField.flagLength] = item.flagLength as CKRecordValue?
        record[ItemField.priority] = item.priority as CKRecordValue
        record[ItemField.parentID] = item.parentId as CKRecordValue?
        record[ItemField.envelopeJSON] = item.envelopeJson as CKRecordValue

        // Payload: inline when small, CKAsset when large.
        let payloadBytes = item.payloadJson.utf8.count
        if payloadBytes > assetSpillThreshold {
            let url = try writeSpillFile(
                contents: item.payloadJson,
                recordName: record.recordID.recordName,
                directory: assetDirectory)
            record[ItemField.payloadAsset] = CKAsset(fileURL: url)
            record[ItemField.payloadInAsset] = 1 as CKRecordValue
            record[ItemField.payloadJSON] = nil
            Logger.sync.infoCapture(
                "Payload spilled to CKAsset (\(payloadBytes) bytes) for \(item.id)",
                category: "sync")
        } else {
            record[ItemField.payloadJSON] = item.payloadJson as CKRecordValue
            record[ItemField.payloadInAsset] = 0 as CKRecordValue
            record[ItemField.payloadAsset] = nil
        }

        // Availability is device-local. A device without the bytes must not
        // clear an existing server asset while updating the item envelope.
        if item.schemaRef == "content-blob@1.0.0", let contentBlobURL {
            record[ItemField.contentAsset] = CKAsset(fileURL: contentBlobURL)
        }

        return record
    }

    /// Decode a fetched item record back into the Rust DTO.
    public static func decodeItem(_ record: CKRecord) throws -> SyncItemRecord {
        guard record.recordType == RecordType.item else {
            throw SyncCodecError.wrongRecordType(expected: RecordType.item, got: record.recordType)
        }

        let payloadJSON: String
        if (record[ItemField.payloadInAsset] as? Int64 ?? 0) == 1 {
            guard let asset = record[ItemField.payloadAsset] as? CKAsset,
                  let url = asset.fileURL,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else {
                throw SyncCodecError.assetUnreadable(record.recordID.recordName)
            }
            payloadJSON = text
        } else {
            guard let inline = record[ItemField.payloadJSON] as? String else {
                throw SyncCodecError.missingField(
                    ItemField.payloadJSON, recordType: RecordType.item)
            }
            payloadJSON = inline
        }

        guard let schemaRef = record[ItemField.schemaRef] as? String else {
            throw SyncCodecError.missingField(ItemField.schemaRef, recordType: RecordType.item)
        }

        return SyncItemRecord(
            id: record.recordID.recordName,
            schemaRef: schemaRef,
            payloadJson: payloadJSON,
            logicalClock: int64ToClock(record[ItemField.logicalClock] as? Int64 ?? 0),
            authorKind: record[ItemField.authorKind] as? String ?? "human",
            authorId: record[ItemField.authorID] as? String ?? "",
            origin: record[ItemField.origin] as? String ?? "",
            createdMs: record[ItemField.createdMs] as? Int64 ?? 0,
            modifiedMs: record[ItemField.modifiedMs] as? Int64 ?? 0,
            tagPaths: record[ItemField.tagPaths] as? [String] ?? [],
            isRead: (record[ItemField.isRead] as? Int64 ?? 0) != 0,
            isStarred: (record[ItemField.isStarred] as? Int64 ?? 0) != 0,
            flagColor: record[ItemField.flagColor] as? String,
            flagStyle: record[ItemField.flagStyle] as? String,
            flagLength: record[ItemField.flagLength] as? String,
            priority: record[ItemField.priority] as? String ?? "normal",
            parentId: record[ItemField.parentID] as? String,
            envelopeJson: record[ItemField.envelopeJSON] as? String ?? "{}")
    }

    /// CloudKit's temporary download URL. The caller must copy it into the
    /// durable CAS before the fetched-change callback returns.
    public static func contentBlobAssetURL(_ record: CKRecord) -> URL? {
        guard record.recordType == RecordType.item,
              let asset = record[ItemField.contentAsset] as? CKAsset
        else { return nil }
        return asset.fileURL
    }

    // MARK: - Reference

    public static func encode(
        reference: SyncReferenceRecord,
        zoneID: CKRecordZone.ID,
        existing: CKRecord? = nil
    ) -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: RecordType.reference,
            recordID: CKRecord.ID(recordName: reference.recordName, zoneID: zoneID))
        record[ReferenceField.sourceID] = reference.sourceId as CKRecordValue
        record[ReferenceField.targetID] = reference.targetId as CKRecordValue
        record[ReferenceField.edgeType] = reference.edgeType as CKRecordValue
        record[ReferenceField.metadata] = reference.metadata as CKRecordValue?
        record[ReferenceField.logicalClock] = clockToInt64(reference.logicalClock) as CKRecordValue
        return record
    }

    public static func decodeReference(_ record: CKRecord) throws -> SyncReferenceRecord {
        guard record.recordType == RecordType.reference else {
            throw SyncCodecError.wrongRecordType(
                expected: RecordType.reference, got: record.recordType)
        }
        guard let sourceID = record[ReferenceField.sourceID] as? String else {
            throw SyncCodecError.missingField(
                ReferenceField.sourceID, recordType: RecordType.reference)
        }
        guard let targetID = record[ReferenceField.targetID] as? String else {
            throw SyncCodecError.missingField(
                ReferenceField.targetID, recordType: RecordType.reference)
        }
        guard let edgeType = record[ReferenceField.edgeType] as? String else {
            throw SyncCodecError.missingField(
                ReferenceField.edgeType, recordType: RecordType.reference)
        }
        return SyncReferenceRecord(
            recordName: record.recordID.recordName,
            sourceId: sourceID,
            targetId: targetID,
            edgeType: edgeType,
            metadata: record[ReferenceField.metadata] as? String,
            logicalClock: int64ToClock(record[ReferenceField.logicalClock] as? Int64 ?? 0))
    }

    // MARK: - Tombstone

    public static func encode(
        tombstone: SyncTombstoneRecord,
        zoneID: CKRecordZone.ID,
        existing: CKRecord? = nil
    ) -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: RecordType.tombstone,
            recordID: CKRecord.ID(
                recordName: tombstone.recordName.lowercased(), zoneID: zoneID))
        record[TombstoneField.schemaRef] = tombstone.schemaRef as CKRecordValue
        record[TombstoneField.deletedAtMs] = tombstone.deletedAtMs as CKRecordValue
        record[TombstoneField.origin] = tombstone.origin as CKRecordValue
        return record
    }

    public static func decodeTombstone(_ record: CKRecord) throws -> SyncTombstoneRecord {
        guard record.recordType == RecordType.tombstone else {
            throw SyncCodecError.wrongRecordType(
                expected: RecordType.tombstone, got: record.recordType)
        }
        return SyncTombstoneRecord(
            recordName: record.recordID.recordName,
            schemaRef: record[TombstoneField.schemaRef] as? String ?? "unknown",
            deletedAtMs: record[TombstoneField.deletedAtMs] as? Int64 ?? 0,
            origin: record[TombstoneField.origin] as? String ?? "")
    }

    // MARK: - System-fields archive

    /// Archive a record's CloudKit system fields (recordID, change tag,
    /// timestamps) for later reconstruction.
    ///
    /// Storing these is what lets a later push present the server's change tag
    /// instead of blindly overwriting: without them every save looks like a
    /// first write and CloudKit answers `serverRecordChanged` for everything.
    /// The blob is stashed per record via `sync_record_state_set`.
    public static func archiveSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Rebuild a bare `CKRecord` (system fields only, no user fields) from an
    /// archived blob. Returns nil if the blob is unreadable — the caller then
    /// treats the record as new.
    public static func restoreSystemFields(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }

    // MARK: - Helpers

    /// CloudKit record names for items are the lowercased UUID — matching the
    /// `record_name` the Rust outbox produces, so both sides agree without
    /// coordination.
    public static func recordName(forItemID id: String) -> String { id.lowercased() }

    /// HLC clocks are `UInt64` in Rust but CloudKit stores `Int64`. Real
    /// clocks (`wall_ms << 16`) never approach the sign bit, but bit-pattern
    /// conversion keeps the mapping lossless and reversible regardless.
    static func clockToInt64(_ clock: UInt64) -> Int64 { Int64(bitPattern: clock) }
    static func int64ToClock(_ value: Int64) -> UInt64 { UInt64(bitPattern: value) }

    /// Directory holding spilled payload files awaiting upload.
    public static var defaultAssetDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-sync-assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeSpillFile(
        contents: String,
        recordName: String,
        directory: URL?
    ) throws -> URL {
        let dir = directory ?? defaultAssetDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Unique per encode: CloudKit reads the file asynchronously during
        // upload, so reusing a name could hand it a half-rewritten file.
        let url = dir.appendingPathComponent("\(recordName)-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Delete spill files older than `maxAge`. Called after a send cycle —
    /// CloudKit has copied whatever it needed by then.
    public static func pruneAssetScratch(
        olderThan maxAge: TimeInterval = 3600,
        directory: URL? = nil
    ) {
        let dir = directory ?? defaultAssetDirectory
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
