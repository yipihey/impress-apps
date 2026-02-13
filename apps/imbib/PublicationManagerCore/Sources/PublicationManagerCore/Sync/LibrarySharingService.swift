//
//  LibrarySharingService.swift
//  PublicationManagerCore
//
//  Manages CKShare lifecycle for shared libraries:
//  creating shares, accepting invitations, managing participants.
//

import Foundation
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Library Sharing Service

/// Manages CloudKit sharing for imbib libraries.
///
/// Each shared library maps to a single `CKShare` in the user's private database.
/// All items belonging to that library (publications, comments, artifacts) are
/// added to the share's zone so participants can access them.
public actor LibrarySharingService {

    public static let shared = LibrarySharingService()

    // MARK: - Configuration

    private let containerIdentifier = "iCloud.com.imbib.app"
    private let libraryRecordType = "Library"

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
    #endif

    private init() {}

    // MARK: - Share Creation

    #if canImport(CloudKit)

    /// Create a CKShare for a library, enabling collaborative access.
    ///
    /// - Parameter libraryID: The local library UUID
    /// - Returns: The created CKShare for use with UICloudSharingController
    public func shareLibrary(_ libraryID: UUID) async throws -> CKShare {
        let zoneName = "Library-\(libraryID.uuidString)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        // Ensure zone exists
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await privateDatabase.save(zone)

        // Create root record for the library
        let rootRecordID = CKRecord.ID(recordName: libraryID.uuidString, zoneID: zoneID)
        let rootRecord = CKRecord(recordType: libraryRecordType, recordID: rootRecordID)

        let store = await MainActor.run { RustStoreAdapter.shared }
        let libraries = await MainActor.run { store.listLibraries() }
        let library = libraries.first { $0.id == libraryID }

        rootRecord["name"] = (library?.name ?? "Shared Library") as CKRecordValue
        rootRecord["localID"] = libraryID.uuidString as CKRecordValue

        // Save root record
        _ = try await privateDatabase.save(rootRecord)

        // Create share
        let share = CKShare(rootRecord: rootRecord)
        share[CKShare.SystemFieldKey.title] = (library?.name ?? "Shared Library") as CKRecordValue

        // Save share and root record together
        let operation = CKModifyRecordsOperation(
            recordsToSave: [rootRecord, share],
            recordIDsToDelete: nil
        )
        operation.isAtomic = true

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

        Logger.sync.info("[LibrarySharing] Created share for library \(libraryID)")
        return share
    }

    /// Accept a share invitation.
    ///
    /// Call this from the app's `userDidAcceptCloudKitShareWith` handler.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await container.accept(metadata)
        Logger.sync.info("[LibrarySharing] Accepted share invitation")

        NotificationCenter.default.post(name: .sharedLibraryAccepted, object: nil)
    }

    /// Stop sharing a library (owner only).
    ///
    /// This deletes the CKShare, revoking access for all participants.
    public func stopSharing(libraryID: UUID) async throws {
        let zoneName = "Library-\(libraryID.uuidString)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        // Delete the entire zone (removes share + all records)
        try await privateDatabase.deleteRecordZone(withID: zoneID)

        Logger.sync.info("[LibrarySharing] Stopped sharing library \(libraryID)")
    }

    /// Leave a shared library (participant, not owner).
    public func leaveShare(libraryID: UUID) async throws {
        // Find the share for this library in the shared database
        let zones = try await sharedDatabase.allRecordZones()
        for zone in zones {
            let recordID = CKRecord.ID(recordName: libraryID.uuidString, zoneID: zone.zoneID)
            do {
                let record = try await sharedDatabase.record(for: recordID)
                if let share = record.share {
                    let fullShare = try await sharedDatabase.record(for: share.recordID) as? CKShare
                    if let fullShare {
                        // Remove self from participants
                        let currentUser = try await container.userIdentity(forUserRecordID: CKRecord.ID(recordName: CKCurrentUserDefaultName))
                        _ = currentUser
                        // Delete the zone from shared database to leave
                        try await sharedDatabase.deleteRecordZone(withID: zone.zoneID)
                        _ = fullShare // suppress warning
                        Logger.sync.info("[LibrarySharing] Left shared library \(libraryID)")
                        return
                    }
                }
            } catch {
                continue
            }
        }

        throw SharingError.shareNotFound
    }

    // MARK: - Participant Management

    /// List participants for a shared library.
    public func participants(for libraryID: UUID) async throws -> [ShareParticipant] {
        let zoneName = "Library-\(libraryID.uuidString)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let rootRecordID = CKRecord.ID(recordName: libraryID.uuidString, zoneID: zoneID)

        // Fetch the root record and its share
        let record = try await privateDatabase.record(for: rootRecordID)
        guard let shareRef = record.share else {
            return [] // Not shared
        }

        let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
        guard let share = shareRecord as? CKShare else {
            return []
        }

        return share.participants.map { ckParticipant in
            mapParticipant(ckParticipant, share: share)
        }
    }

    /// Set permission level for a participant.
    public func setPermission(
        _ permission: ShareParticipant.Permission,
        for participantID: String,
        in libraryID: UUID
    ) async throws {
        let zoneName = "Library-\(libraryID.uuidString)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let rootRecordID = CKRecord.ID(recordName: libraryID.uuidString, zoneID: zoneID)

        let record = try await privateDatabase.record(for: rootRecordID)
        guard let shareRef = record.share else {
            throw SharingError.shareNotFound
        }

        let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
        guard let share = shareRecord as? CKShare else {
            throw SharingError.shareNotFound
        }

        guard let participant = share.participants.first(where: {
            $0.userIdentity.lookupInfo?.emailAddress == participantID ||
            $0.userIdentity.userRecordID?.recordName == participantID
        }) else {
            throw SharingError.participantNotFound
        }

        let ckPermission: CKShare.ParticipantPermission = switch permission {
        case .readOnly: .readOnly
        case .readWrite: .readWrite
        }

        participant.permission = ckPermission

        _ = try await privateDatabase.save(share)
        Logger.sync.info("[LibrarySharing] Updated permission for participant in library \(libraryID)")
    }

    // MARK: - User Identity

    /// Fetch the current user's CloudKit identity.
    ///
    /// Returns display name and email from CKUserIdentity. Falls back to device name.
    public func currentUserIdentity() async -> (name: String?, identifier: String) {
        do {
            let userRecordID = try await container.userRecordID()
            let identity = try await container.userIdentity(forUserRecordID: userRecordID)

            let name: String? = {
                guard let identity else { return nil }
                let components = identity.nameComponents
                if let given = components?.givenName, let family = components?.familyName {
                    return "\(given) \(family)"
                }
                return components?.givenName ?? components?.familyName
            }()

            return (name: name, identifier: userRecordID.recordName)
        } catch {
            Logger.sync.info("[LibrarySharing] Could not fetch CloudKit identity: \(error)")
            // Fallback to device name
            #if os(macOS)
            let deviceName = Host.current().localizedName ?? "Unknown"
            #else
            let deviceName = await UIDevice.current.name
            #endif
            return (name: deviceName, identifier: deviceName)
        }
    }

    // MARK: - Private Helpers

    private func mapParticipant(_ ckParticipant: CKShare.Participant, share: CKShare) -> ShareParticipant {
        let identity = ckParticipant.userIdentity
        let name: String? = {
            let components = identity.nameComponents
            if let given = components?.givenName, let family = components?.familyName {
                return "\(given) \(family)"
            }
            return components?.givenName ?? components?.familyName
        }()

        let email = identity.lookupInfo?.emailAddress
        let recordID = identity.userRecordID?.recordName ?? UUID().uuidString

        let permission: ShareParticipant.Permission = switch ckParticipant.permission {
        case .readWrite: .readWrite
        default: .readOnly
        }

        let acceptance: ShareParticipant.AcceptanceStatus = switch ckParticipant.acceptanceStatus {
        case .accepted: .accepted
        case .pending: .pending
        case .removed: .removed
        default: .unknown
        }

        let isOwner = share.owner == ckParticipant
        let isCurrentUser = ckParticipant.role == .owner || ckParticipant.userIdentity.hasiCloudAccount

        return ShareParticipant(
            id: recordID,
            displayName: name,
            emailAddress: email,
            permission: permission,
            acceptanceStatus: acceptance,
            isOwner: isOwner,
            isCurrentUser: isCurrentUser
        )
    }

    #else

    public func shareLibrary(_ libraryID: UUID) async throws -> Never {
        fatalError("CloudKit not available on this platform")
    }

    public func participants(for libraryID: UUID) async throws -> [ShareParticipant] {
        return []
    }

    public func currentUserIdentity() async -> (name: String?, identifier: String) {
        return (name: "Unknown", identifier: "unknown")
    }

    #endif
}

// MARK: - Errors

public enum SharingError: LocalizedError {
    case shareNotFound
    case participantNotFound
    case notOwner
    case cloudKitUnavailable

    public var errorDescription: String? {
        switch self {
        case .shareNotFound: "No share found for this library."
        case .participantNotFound: "Participant not found in this share."
        case .notOwner: "Only the share owner can perform this action."
        case .cloudKitUnavailable: "CloudKit is not available."
        }
    }
}
