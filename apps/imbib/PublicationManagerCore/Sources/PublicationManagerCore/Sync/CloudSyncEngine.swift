//
//  CloudSyncEngine.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D): the Swift half of the sync engine.
//
//  ## Division of labour
//
//  Rust owns every *decision*: last-write-wins, tombstone races, deferred
//  references, manuscript conflict backups, FTS refresh (Phase B, proven by
//  the convergence suite). Swift owns *transport*: CloudKit I/O, scheduling,
//  and the codec. This actor is that transport layer and contains no merge
//  logic of its own — even the `serverRecordChanged` conflict path is resolved
//  by handing the server's record to `syncApplyRemoteItems` and reading the
//  report, so there is exactly ONE implementation of LWW in the system.
//
//  ## Lifecycle
//
//  `start()` is only reachable through `CloudSyncAvailability.evaluate()`, so
//  by the time any CloudKit type is constructed we know: not a test process,
//  user opted in, container entitled, iCloud account available, and we hold
//  the single-writer lease. `stop()` releases the lease.
//
//  ## Push / pull loop
//
//  - push: outbox → `state.add(pendingRecordZoneChanges:)` → CloudKit asks for
//    a batch → we snapshot + encode → on CONFIRMED save we archive system
//    fields and only then remove the outbox rows. An unconfirmed push leaves
//    the outbox intact, so a crash mid-push re-pushes rather than loses.
//  - pull: fetched changes → decode → Rust apply → retry deferred references →
//    one store event + one Darwin `syncApplied` for the whole batch.
//

import Foundation
import CloudKit
import CryptoKit
import ImbibRustCore
import ImpressKit
import ImpressLogging
import OSLog

public actor CloudSyncEngine {

    public static let shared = CloudSyncEngine()

    // MARK: - State

    private var engine: CKSyncEngine?
    private var lease: SyncLease = .shared
    private var renewTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var eventObserverTask: Task<Void, Never>?
    private var darwinObservation: DarwinObservation?
    private var isRunning = false

    /// recordName → outbox sequence numbers awaiting confirmation. Rows are
    /// removed from the Rust outbox only once CloudKit confirms the save, so
    /// this map is the bridge between the two id spaces.
    private var pendingSeqs: [String: [Int64]] = [:]

    /// Zone every synced record lives in (plan decision 6).
    private let zoneID = CKRecordZone.ID(
        zoneName: SyncSettings.zoneName, ownerName: CKCurrentUserDefaultName)

    /// Periodic push/pull cadence when nothing else nudges us.
    private static let timerInterval: TimeInterval = 60

    private let metadataKeyEngineState = "sync.engine_state"

    public init() {}

    public var running: Bool { isRunning }

    // MARK: - Lifecycle

    /// Start syncing if every precondition holds. Safe to call repeatedly.
    ///
    /// - Returns: the availability verdict — `.available` means the engine is
    ///   now running; anything else explains why it is not.
    @discardableResult
    public func start() async -> SyncAvailability {
        guard !isRunning else { return .available }

        let availability = await CloudSyncAvailability.evaluate(lease: lease)
        guard availability == .available else {
            Logger.sync.infoCapture(
                "Sync not started: \(availability.reasonCode)", category: "sync")
            return availability
        }

        guard let container = CloudSyncAvailability.makeContainerIfEntitled() else {
            return .notEntitled
        }

        // Restore the engine's serialized state (advisory — losing it just
        // means a harmless idempotent re-push/re-fetch).
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: await loadEngineState(),
            delegate: self)
        configuration.automaticallySync = true

        let engine = CKSyncEngine(configuration)
        self.engine = engine
        isRunning = true

        await ensureZoneExists(engine: engine)
        await enqueueOutbox()

        startLeaseRenewal()
        startNudgeSources()

        Logger.sync.infoCapture("CloudSyncEngine started (zone \(zoneID.zoneName))", category: "sync")
        return .available
    }

    /// Stop syncing and release the lease. Never touches user data.
    public func stop() async {
        isRunning = false
        renewTask?.cancel(); renewTask = nil
        nudgeTask?.cancel(); nudgeTask = nil
        eventObserverTask?.cancel(); eventObserverTask = nil
        darwinObservation?.invalidate(); darwinObservation = nil
        engine = nil
        pendingSeqs.removeAll()
        await lease.release()
        Logger.sync.infoCapture("CloudSyncEngine stopped", category: "sync")
    }

    /// Ask CloudKit to push and pull now (Settings' "Sync Now", the automation
    /// API's nudge endpoint, and every internal trigger land here).
    public func nudge() async {
        guard let engine, isRunning else { return }
        await enqueueOutbox()
        do {
            try await engine.sendChanges()
            try await engine.fetchChanges()
        } catch {
            recordFailure(error, during: "nudge")
        }
    }

    // MARK: - Zone

    private func ensureZoneExists(engine: CKSyncEngine) async {
        // Adding the zone is idempotent: CloudKit ignores a create for a zone
        // that already exists, and the engine batches it with the next send.
        let zone = CKRecordZone(zoneID: zoneID)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
    }

    // MARK: - Engine state persistence

    /// `CKSyncEngine.State.Serialization` is a `Codable` value type (not
    /// `NSCoding`), so it round-trips through JSON and rides in the store's
    /// metadata table as base64.
    private func loadEngineState() async -> CKSyncEngine.State.Serialization? {
        do {
            guard let base64 = try await ImbibImpressStore.shared.syncMetadataGet(
                key: metadataKeyEngineState),
                let data = Data(base64Encoded: base64)
            else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            // A state blob we can't read is not fatal — it's advisory. Losing
            // it costs one idempotent re-push/re-fetch, nothing more.
            Logger.sync.error("Could not restore sync engine state: \(error)")
            return nil
        }
    }

    private func persistEngineState(_ state: CKSyncEngine.State.Serialization) async {
        do {
            let data = try JSONEncoder().encode(state)
            try await ImbibImpressStore.shared.syncMetadataSet(
                key: metadataKeyEngineState, value: data.base64EncodedString())
        } catch {
            Logger.sync.error("Could not persist sync engine state: \(error)")
        }
    }

    private func clearEngineState() async {
        try? await ImbibImpressStore.shared.syncMetadataSet(
            key: metadataKeyEngineState, value: nil)
    }

    // MARK: - Push: outbox → pending changes

    /// Translate the Rust outbox into CloudKit pending changes.
    ///
    /// Only the *intent* is registered here (save/delete of a record id);
    /// materialization happens later in `nextRecordZoneChangeBatch`, which is
    /// what lets CloudKit choose its own batch sizes.
    private func enqueueOutbox() async {
        guard let engine else { return }
        do {
            let entries = try await ImbibImpressStore.shared.syncOutboxEntries(limit: 10_000)
            guard !entries.isEmpty else { return }

            var changes: [CKSyncEngine.PendingRecordZoneChange] = []
            var seqs: [String: [Int64]] = [:]

            for entry in entries {
                guard let name = recordName(for: entry) else { continue }
                let id = CKRecord.ID(recordName: name, zoneID: zoneID)
                switch entry.kind {
                case "item", "reference":
                    changes.append(.saveRecord(id))
                case "delete_item":
                    // An item deletion ships as a tombstone RECORD (so peers
                    // can apply the race rule) — the CKRecord itself is also
                    // deleted so the zone doesn't keep dead weight.
                    changes.append(.saveRecord(id))
                case "delete_reference":
                    changes.append(.deleteRecord(id))
                default:
                    continue
                }
                seqs[name, default: []].append(entry.seq)
            }

            pendingSeqs.merge(seqs) { old, new in old + new }
            engine.state.add(pendingRecordZoneChanges: changes)
        } catch {
            recordFailure(error, during: "enqueue outbox")
        }
    }

    /// CloudKit record name for an outbox entry.
    ///
    /// Items and item-deletions use the lowercased UUID. Reference entries
    /// carry the raw `src|tgt|edge` triple and must be hashed into the
    /// `ref_<sha256[..32]>` form the Rust side produces — see
    /// `referenceRecordName`.
    private func recordName(for entry: SyncOutboxEntry) -> String? {
        switch entry.kind {
        case "item", "delete_item":
            return entry.recordName.lowercased()
        case "reference", "delete_reference":
            return Self.referenceRecordName(rawOutboxName: entry.recordName)
        default:
            return nil
        }
    }

    /// Mirror of `impress_core::sync::sync_reference_record_name`:
    /// `"ref_" + sha256("source|target|edge")` truncated to 32 hex chars.
    ///
    /// Both sides must agree byte-for-byte or edge deletions would target
    /// records that don't exist. `SyncEngineCodecTests` pins the parity
    /// against a name Rust actually produced.
    static func referenceRecordName(rawOutboxName: String) -> String? {
        let parts = rawOutboxName.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return referenceRecordName(
            source: String(parts[0]), target: String(parts[1]), edge: String(parts[2]))
    }

    static func referenceRecordName(source: String, target: String, edge: String) -> String {
        let digest = SHA256.hash(data: Data("\(source)|\(target)|\(edge)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ref_" + String(hex.prefix(32))
    }

    // MARK: - Pull: apply a fetched batch

    private func applyFetched(
        modifications: [CKRecord],
        deletions: [CKRecord.ID]
    ) async {
        var items: [SyncItemRecord] = []
        var references: [SyncReferenceRecord] = []
        var tombstones: [SyncTombstoneRecord] = []

        for record in modifications {
            do {
                switch record.recordType {
                case SyncRecordCodec.RecordType.item:
                    items.append(try SyncRecordCodec.decodeItem(record))
                case SyncRecordCodec.RecordType.reference:
                    references.append(try SyncRecordCodec.decodeReference(record))
                case SyncRecordCodec.RecordType.tombstone:
                    tombstones.append(try SyncRecordCodec.decodeTombstone(record))
                default:
                    Logger.sync.error("Unknown record type fetched: \(record.recordType)")
                }
                // Remember the server's change tag so our next save of this
                // record presents it instead of looking like a first write.
                try? await ImbibImpressStore.shared.syncRecordStateSet(
                    recordName: record.recordID.recordName,
                    blob: SyncRecordCodec.archiveSystemFields(record))
            } catch {
                Logger.sync.error(
                    "Could not decode \(record.recordID.recordName): \(error.localizedDescription)")
            }
        }

        guard !items.isEmpty || !references.isEmpty || !tombstones.isEmpty || !deletions.isEmpty
        else { return }

        do {
            let store = ImbibImpressStore.shared
            var applied = 0
            var affectedIDs = Set<UUID>()

            if !items.isEmpty {
                let report = try await store.syncApplyRemoteItems(records: items)
                applied += Int(report.applied)
                for item in items {
                    if let uuid = UUID(uuidString: item.id) { affectedIDs.insert(uuid) }
                }
                if report.conflictBackups > 0 {
                    Logger.sync.infoCapture(
                        "\(report.conflictBackups) manuscript conflict backup(s) created",
                        category: "sync")
                }
            }
            if !references.isEmpty {
                let report = try await store.syncApplyRemoteReferences(refs: references)
                applied += Int(report.applied)
            }
            if !tombstones.isEmpty {
                let report = try await store.syncApplyRemoteTombstones(tombstones: tombstones)
                applied += Int(report.applied)
            }
            if !deletions.isEmpty {
                let names = deletions.map(\.recordName)
                let report = try await store.syncApplyRemoteDeletions(recordNames: names)
                applied += Int(report.applied)
                for name in names {
                    try? await store.syncRecordStateDelete(recordName: name)
                }
            }

            // Deferred references may now resolve (their endpoints just landed).
            _ = try? await store.syncRetryPendingReferences()

            SyncSettings.lastPullAt = Date()
            SyncSettings.clearError()

            guard applied > 0 else { return }

            // ONE event for the whole batch, not one per record — the store
            // event fan-out drives SwiftUI re-evaluation and per-record posts
            // would be a render storm.
            if affectedIDs.isEmpty {
                ImbibImpressStore.shared.postMutation(structural: true)
            } else {
                ImbibImpressStore.shared.postMutation(
                    structural: true, affectedIDs: affectedIDs, kind: .otherField)
            }
            // Wake the siblings (imprint, impel) — they read the same store.
            ImpressNotification.post(ImpressNotification.syncApplied, from: .imbib)

            Logger.sync.infoCapture(
                "Applied \(applied) remote change(s) from CloudKit", category: "sync")
        } catch {
            recordFailure(error, during: "apply fetched changes")
        }
    }

    // MARK: - Conflict resolution

    /// Resolve a `serverRecordChanged` by deferring to the Rust merge.
    ///
    /// We do NOT re-implement LWW here. The server's record is handed to
    /// `syncApplyRemoteItems`, which runs the same comparison the convergence
    /// suite proves. If it applied, the server won and our local row now
    /// matches — nothing left to push. If it was skipped, the local row won,
    /// so we re-queue a save; the archived server change tag makes that save
    /// succeed on the next attempt instead of conflicting forever.
    private func resolveConflict(serverRecord: CKRecord) async {
        try? await ImbibImpressStore.shared.syncRecordStateSet(
            recordName: serverRecord.recordID.recordName,
            blob: SyncRecordCodec.archiveSystemFields(serverRecord))

        guard serverRecord.recordType == SyncRecordCodec.RecordType.item else {
            // References and tombstones carry no mergeable state — last write
            // is fine, so just retry ours.
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(serverRecord.recordID)])
            return
        }

        do {
            let remote = try SyncRecordCodec.decodeItem(serverRecord)
            let report = try await ImbibImpressStore.shared.syncApplyRemoteItems(records: [remote])
            if report.applied > 0 {
                Logger.sync.infoCapture(
                    "Conflict on \(serverRecord.recordID.recordName): server won",
                    category: "sync")
                if let uuid = UUID(uuidString: remote.id) {
                    ImbibImpressStore.shared.postMutation(
                        structural: false, affectedIDs: [uuid], kind: .otherField)
                }
            } else {
                Logger.sync.infoCapture(
                    "Conflict on \(serverRecord.recordID.recordName): local won, re-queuing",
                    category: "sync")
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(serverRecord.recordID)])
            }
        } catch {
            Logger.sync.error("Conflict resolution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Nudges

    private func startLeaseRenewal() {
        let interval = lease.suggestedRenewInterval
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.renewLeaseOrStop()
            }
        }
    }

    private func renewLeaseOrStop() async {
        guard isRunning else { return }
        if await lease.renew() { return }
        Logger.sync.error("Lost the sync lease — stopping engine")
        await stop()
    }

    /// Three nudge sources: local mutations (store events), sibling apps'
    /// Darwin posts, and a slow safety-net timer.
    private func startNudgeSources() {
        eventObserverTask = Task { [weak self] in
            let stream = ImbibImpressStore.shared.events.subscribe()
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.nudgePush()
            }
        }

        darwinObservation = ImpressNotification.observe(
            ImpressNotification.libraryChanged, from: .imprint
        ) { [weak self] in
            Task { await self?.nudgePush() }
        }

        nudgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.timerInterval))
                guard !Task.isCancelled, let self else { return }
                await self.nudge()
            }
        }
    }

    /// Push-only nudge for local mutations — a local edit needs uploading, not
    /// a fetch round trip.
    private func nudgePush() async {
        guard let engine, isRunning else { return }
        await enqueueOutbox()
        do {
            try await engine.sendChanges()
        } catch {
            recordFailure(error, during: "push")
        }
    }

    // MARK: - Errors

    private func recordFailure(_ error: Error, during phase: String) {
        let message = "\(phase): \(error.localizedDescription)"
        Logger.sync.error("Sync \(message)")
        SyncSettings.recordError(message)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {

        case .stateUpdate(let update):
            await persistEngineState(update.stateSerialization)

        case .accountChange(let change):
            await handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map(\.recordID))

        case .sentRecordZoneChanges(let sent):
            await handleSentChanges(sent)

        case .fetchedDatabaseChanges(let changes):
            // A deleted zone means the user wiped iCloud data for the app.
            // Local data is authoritative; drop our cursors so the next run
            // re-uploads from scratch.
            if !changes.deletions.isEmpty {
                Logger.sync.infoCapture(
                    "Sync zone deleted on the server — clearing cursors", category: "sync")
                await clearEngineState()
            }

        case .didFetchChanges:
            SyncSettings.lastPullAt = Date()

        case .didSendChanges:
            SyncRecordCodec.pruneAssetScratch()

        case .willFetchChanges, .willSendChanges, .sentDatabaseChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        // The user signed out or switched accounts. Stop, forget everything
        // CloudKit-shaped, and NEVER touch their data — the local store is
        // complete on its own (Phase 1 behavior).
        Logger.sync.infoCapture("iCloud account changed — stopping sync", category: "sync")
        await stop()
        await clearEngineState()
        SyncSettings.resetDiagnostics()
        SyncSettings.recordError("iCloud account changed. Sync stopped; your library is untouched.")

        switch change.changeType {
        case .signIn:
            SyncSettings.clearError()
        case .signOut, .switchAccounts:
            break
        @unknown default:
            break
        }
    }

    private func handleSentChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        var confirmed: [Int64] = []

        for record in sent.savedRecords {
            let name = record.recordID.recordName
            try? await ImbibImpressStore.shared.syncRecordStateSet(
                recordName: name, blob: SyncRecordCodec.archiveSystemFields(record))
            confirmed.append(contentsOf: pendingSeqs.removeValue(forKey: name) ?? [])
        }

        for deleted in sent.deletedRecordIDs {
            let name = deleted.recordName
            try? await ImbibImpressStore.shared.syncRecordStateDelete(recordName: name)
            confirmed.append(contentsOf: pendingSeqs.removeValue(forKey: name) ?? [])
        }

        for failure in sent.failedRecordSaves {
            let ckError = failure.error
            switch ckError.code {
            case .serverRecordChanged:
                if let serverRecord = ckError.serverRecord {
                    await resolveConflict(serverRecord: serverRecord)
                }
            case .zoneNotFound, .userDeletedZone:
                // Recreate the zone and retry this record.
                if let engine {
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    engine.state.add(
                        pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                }
            case .unknownItem:
                // Server lost it; a fresh save (no change tag) will recreate.
                try? await ImbibImpressStore.shared.syncRecordStateDelete(
                    recordName: failure.record.recordID.recordName)
                engine?.state.add(
                    pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            default:
                // Leave the outbox rows in place — an unconfirmed push must
                // be retried, never silently dropped.
                recordFailure(ckError, during: "save \(failure.record.recordID.recordName)")
            }
        }

        // Only CONFIRMED work leaves the outbox.
        if !confirmed.isEmpty {
            try? await ImbibImpressStore.shared.syncOutboxRemove(seqs: confirmed)
            SyncSettings.lastPushAt = Date()
            SyncSettings.clearError()
            Logger.sync.infoCapture(
                "Pushed \(confirmed.count) outbox entr(ies) to CloudKit", category: "sync")
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        // Materialize every record CloudKit is about to send. Anything the
        // store can no longer produce (deleted since it was queued) returns
        // nil, which drops it from the batch.
        let materialized = await materialize(pending: pending)

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            materialized[recordID.recordName]
        }
    }

    /// Snapshot + encode the records behind a set of pending saves.
    ///
    /// Batched by kind so the store is asked once per kind rather than once
    /// per record.
    private func materialize(
        pending: [CKSyncEngine.PendingRecordZoneChange]
    ) async -> [String: CKRecord] {
        var wanted = Set<String>()
        for change in pending {
            if case .saveRecord(let id) = change { wanted.insert(id.recordName) }
        }
        guard !wanted.isEmpty else { return [:] }

        var result: [String: CKRecord] = [:]
        let store = ImbibImpressStore.shared

        do {
            // Re-read the outbox to learn what each pending name IS: an item,
            // a reference, or a deletion needing a tombstone record.
            let entries = try await store.syncOutboxEntries(limit: 10_000)

            var itemIDs: [String] = []
            var referenceRaw: [String] = []
            var tombstoneIDs: [String] = []

            for entry in entries {
                guard let name = recordName(for: entry), wanted.contains(name) else { continue }
                switch entry.kind {
                case "item": itemIDs.append(entry.recordName)
                case "reference": referenceRaw.append(entry.recordName)
                case "delete_item": tombstoneIDs.append(entry.recordName)
                default: break
                }
            }

            if !itemIDs.isEmpty {
                for record in try await store.syncSnapshotItems(ids: itemIDs) {
                    let name = SyncRecordCodec.recordName(forItemID: record.id)
                    let existing = await restoredSystemFieldsRecord(name: name)
                    result[name] = try SyncRecordCodec.encode(
                        item: record, zoneID: zoneID, existing: existing)
                }
            }

            if !referenceRaw.isEmpty {
                for record in try await store.syncSnapshotReferences(recordNames: referenceRaw) {
                    let existing = await restoredSystemFieldsRecord(name: record.recordName)
                    result[record.recordName] = SyncRecordCodec.encode(
                        reference: record, zoneID: zoneID, existing: existing)
                }
            }

            if !tombstoneIDs.isEmpty {
                let wantedTombstones = Set(tombstoneIDs.map { $0.lowercased() })
                let tombstones = try await store.syncLocalTombstones(sinceMs: 0)
                for tombstone in tombstones
                where wantedTombstones.contains(tombstone.recordName.lowercased()) {
                    let name = tombstone.recordName.lowercased()
                    let existing = await restoredSystemFieldsRecord(name: name)
                    result[name] = SyncRecordCodec.encode(
                        tombstone: tombstone, zoneID: zoneID, existing: existing)
                }
            }
        } catch {
            recordFailure(error, during: "materialize batch")
        }

        return result
    }

    /// Rebuild a record carrying the server's system fields (change tag), so a
    /// save updates in place rather than colliding.
    private func restoredSystemFieldsRecord(name: String) async -> CKRecord? {
        let stored = try? await ImbibImpressStore.shared.syncRecordStateGet(recordName: name)
        guard let blob = stored ?? nil else { return nil }
        return SyncRecordCodec.restoreSystemFields(from: blob)
    }
}
