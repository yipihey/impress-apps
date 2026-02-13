//
//  CommentCloudKitEngine.swift
//  PublicationManagerCore
//
//  CloudKit sync engine for comments. Handles push/pull of comment items
//  between local Rust/SQLite store and CloudKit private/shared databases.
//

import Foundation
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Comment CloudKit Engine

/// Syncs comments bidirectionally with CloudKit.
///
/// - Private zone: personal multi-device sync
/// - Shared zones: collaborative sync via CKShare
///
/// Uses item-level sync (not operation replay) for simplicity.
/// The `canonical_id` field on each Item maps to the CKRecord.recordID.
public actor CommentCloudKitEngine {

    public static let shared = CommentCloudKitEngine()

    // MARK: - Configuration

    private let containerIdentifier = "iCloud.com.imbib.app"
    private let privateZoneName = "ImbibComments"
    private let recordType = "Comment"

    // MARK: - State

    private var privateChangeToken: Data? {
        get { UserDefaults.standard.data(forKey: "commentSync.privateChangeToken") }
        set { UserDefaults.standard.set(newValue, forKey: "commentSync.privateChangeToken") }
    }

    private var sharedChangeTokens: [String: Data] = [:]
    private var pendingUploads: Set<UUID> = []
    private var isRunning = false
    private var lastSyncDate: Date?
    private var lastError: String?

    #if canImport(CloudKit)
    private lazy var container: CKContainer = {
        CKContainer(identifier: containerIdentifier)
    }()

    private lazy var privateDatabase: CKDatabase = {
        container.privateCloudDatabase
    }()

    private lazy var sharedDatabase: CKDatabase = {
        container.sharedCloudDatabase
    }()

    private lazy var privateZoneID: CKRecordZone.ID = {
        CKRecordZone.ID(zoneName: privateZoneName, ownerName: CKCurrentUserDefaultName)
    }()
    #endif

    private init() {}

    // MARK: - Public API

    /// Current sync status for UI display.
    public struct SyncStatus: Sendable {
        public let isRunning: Bool
        public let lastSyncDate: Date?
        public let lastError: String?
        public let pendingUploadCount: Int
    }

    public func status() -> SyncStatus {
        SyncStatus(
            isRunning: isRunning,
            lastSyncDate: lastSyncDate,
            lastError: lastError,
            pendingUploadCount: pendingUploads.count
        )
    }

    /// Mark a comment as needing push to CloudKit.
    public func markForUpload(_ commentID: UUID) {
        pendingUploads.insert(commentID)
    }

    /// Full sync cycle: push pending, then pull remote changes.
    ///
    /// Respects `CloudKitSyncSettingsStore.commentSyncEnabled` — skips if disabled.
    public func sync() async {
        // Check if comment sync is enabled
        let settings = CloudKitSyncSettingsStore.shared
        guard settings.commentSyncEnabled, settings.shouldAttemptSync else {
            Logger.sync.info("[CommentSync] Comment sync disabled, skipping")
            return
        }

        guard !isRunning else {
            Logger.sync.info("[CommentSync] Sync already in progress, skipping")
            return
        }

        isRunning = true
        lastError = nil
        defer { isRunning = false }

        #if canImport(CloudKit)
        do {
            // Ensure zone exists
            try await ensurePrivateZone()

            // Push local changes to CloudKit
            try await pushPendingComments()

            // Pull remote changes from CloudKit
            try await fetchRemoteChanges()

            lastSyncDate = Date()
            settings.recordSuccessfulCommentSync()
            Logger.sync.info("[CommentSync] Sync completed successfully")
        } catch {
            lastError = error.localizedDescription
            settings.commentSyncError = error.localizedDescription
            Logger.sync.error("[CommentSync] Sync failed: \(error)")
        }
        #else
        lastError = "CloudKit not available on this platform"
        #endif
    }

    #if canImport(CloudKit)

    // MARK: - Zone Setup

    private func ensurePrivateZone() async throws {
        let zone = CKRecordZone(zoneID: privateZoneID)
        let _ = try await privateDatabase.save(zone)
    }

    // MARK: - Push (Local → CloudKit)

    private func pushPendingComments() async throws {
        guard !pendingUploads.isEmpty else { return }

        let store = await MainActor.run { RustStoreAdapter.shared }
        let idsToUpload = pendingUploads
        var records: [CKRecord] = []

        for commentID in idsToUpload {
            // commentID is the parent item — get its comments
            let itemComments = await MainActor.run { store.commentsForItem(commentID) }
            if itemComments.isEmpty {
                continue
            }

            for comment in itemComments {
                let record = commentToRecord(comment)
                records.append(record)
            }
        }

        if records.isEmpty {
            pendingUploads.removeAll()
            return
        }

        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.isAtomic = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.privateDatabase.add(operation)
        }

        // On success, update canonical_ids and clear pending
        for record in records {
            let localID = record["localID"] as? String
            if let localID, let uuid = UUID(uuidString: localID) {
                await MainActor.run {
                    store.setItemCanonicalId(id: uuid, canonicalId: record.recordID.recordName)
                }
            }
        }

        pendingUploads.subtract(idsToUpload)
        Logger.sync.info("[CommentSync] Pushed \(records.count) comments to CloudKit")
    }

    // MARK: - Pull (CloudKit → Local)

    private func fetchRemoteChanges() async throws {
        let store = await MainActor.run { RustStoreAdapter.shared }
        var changeToken: CKServerChangeToken? = nil
        if let data = privateChangeToken {
            changeToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = changeToken

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [privateZoneID],
            configurationsByRecordZoneID: [privateZoneID: config]
        )

        var receivedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var newChangeToken: CKServerChangeToken?

        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result {
                receivedRecords.append(record)
            }
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }

        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            newChangeToken = token
        }

        operation.recordZoneFetchResultBlock = { _, result in
            if case .success(let (token, _, _)) = result {
                newChangeToken = token
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.privateDatabase.add(operation)
        }

        // Process received records
        for record in receivedRecords {
            await processReceivedRecord(record, store: store)
        }

        // Process deletions
        for recordID in deletedRecordIDs {
            await processRecordDeletion(recordID, store: store)
        }

        // Save new change token
        if let token = newChangeToken {
            privateChangeToken = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }

        Logger.sync.info("[CommentSync] Pulled \(receivedRecords.count) changes, \(deletedRecordIDs.count) deletions")
    }

    // MARK: - Record Conversion

    private func commentToRecord(_ comment: Comment) -> CKRecord {
        let recordID = CKRecord.ID(recordName: comment.id.uuidString, zoneID: privateZoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["text"] = comment.text as CKRecordValue
        record["authorIdentifier"] = comment.authorIdentifier as CKRecordValue?
        record["authorDisplayName"] = comment.authorDisplayName as CKRecordValue?
        record["parentItemID"] = comment.parentItemID.uuidString as CKRecordValue
        record["parentCommentID"] = comment.parentCommentID?.uuidString as CKRecordValue?
        record["parentSchema"] = comment.parentSchema as CKRecordValue?
        record["localID"] = comment.id.uuidString as CKRecordValue
        return record
    }

    private func processReceivedRecord(_ record: CKRecord, store: RustStoreAdapter) async {
        guard record.recordType == recordType else { return }

        let localID = record["localID"] as? String
        let text = record["text"] as? String ?? ""
        let authorIdentifier = record["authorIdentifier"] as? String
        let authorDisplayName = record["authorDisplayName"] as? String
        let parentItemIDStr = record["parentItemID"] as? String
        let parentCommentIDStr = record["parentCommentID"] as? String

        // Dedup: check if we already have this comment
        if let localID, UUID(uuidString: localID) != nil {
            let existing = await MainActor.run {
                store.findByCanonicalId(canonicalId: record.recordID.recordName)
            }
            if existing != nil {
                // Already have this record, skip
                return
            }
        }

        guard let parentItemIDStr, let parentItemID = UUID(uuidString: parentItemIDStr) else {
            Logger.sync.warning("[CommentSync] Received record with no parentItemID, skipping")
            return
        }

        let parentCommentID = parentCommentIDStr.flatMap { UUID(uuidString: $0) }

        // Create local comment
        await MainActor.run {
            let comment = store.createCommentOnItem(
                itemId: parentItemID,
                text: text,
                authorIdentifier: authorIdentifier,
                authorDisplayName: authorDisplayName,
                parentCommentId: parentCommentID
            )
            if let comment {
                store.setItemCanonicalId(id: comment.id, canonicalId: record.recordID.recordName)
                store.setItemOrigin(id: comment.id, origin: "cloudkit")
            }
        }
    }

    private func processRecordDeletion(_ recordID: CKRecord.ID, store: RustStoreAdapter) async {
        let canonicalId = recordID.recordName
        let localID = await MainActor.run {
            store.findByCanonicalId(canonicalId: canonicalId)
        }
        if let localID, let uuid = UUID(uuidString: localID) {
            await MainActor.run {
                store.deleteComment(uuid)
            }
        }
    }

    // MARK: - Push Notifications

    /// Register for CloudKit change notifications.
    public func registerForNotifications() async {
        let subscription = CKDatabaseSubscription(subscriptionID: "comment-changes")
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            try await privateDatabase.save(subscription)
            Logger.sync.info("[CommentSync] Registered for push notifications")
        } catch {
            Logger.sync.error("[CommentSync] Failed to register for push: \(error)")
        }
    }

    /// Handle a remote notification (call from AppDelegate/App).
    public func handleRemoteNotification() async {
        await sync()
    }

    #endif
}

