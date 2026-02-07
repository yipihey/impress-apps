//
//  CloudKitSharingService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

/// Coordinates CloudKit sharing operations for libraries and collections.
///
/// This service manages the full sharing lifecycle:
/// 1. Copy content to shared store via `SharedLibraryCopyService`
/// 2. Create/manage CKShare via `NSPersistentCloudKitContainer`
/// 3. Handle unsharing (privatize shared content)
/// 4. Manage participant permissions
public actor CloudKitSharingService {

    public static let shared = CloudKitSharingService()

    private let copyService = SharedLibraryCopyService.shared

    private init() {}

    #if canImport(CloudKit)
    // MARK: - Share Library

    /// Share a library by creating a copy in the shared store and a CKShare.
    ///
    /// - Parameter library: The private library to share
    /// - Returns: Tuple of the shared CDLibrary and the CKShare for presenting sharing UI
    /// - Throws: If copying or share creation fails
    public func shareLibrary(_ library: CDLibrary, options: ShareOptions = .default) async throws -> (CDLibrary, CKShare) {
        let context = PersistenceController.shared.viewContext

        // Step 1: Copy library content to shared store
        let sharedLibrary = try await copyService.copyLibraryToSharedStore(library, context: context, options: options)

        // Step 2: Create CKShare
        let share = try await createShare(for: sharedLibrary, title: library.name)

        Logger.sync.info("Created share for library '\(library.name)'")
        return (sharedLibrary, share)
    }

    /// Share a collection by wrapping it in a shared library.
    ///
    /// - Parameter collection: The private collection to share
    /// - Returns: Tuple of the shared CDLibrary wrapper and the CKShare
    /// - Throws: If copying or share creation fails
    public func shareCollection(_ collection: CDCollection, options: ShareOptions = .default) async throws -> (CDLibrary, CKShare) {
        let context = PersistenceController.shared.viewContext

        // Step 1: Copy collection to shared store (wrapped in a CDLibrary)
        let sharedLibrary = try await copyService.copyCollectionToSharedStore(collection, context: context, options: options)

        // Step 2: Create CKShare
        let share = try await createShare(for: sharedLibrary, title: collection.name)

        Logger.sync.info("Created share for collection '\(collection.name)'")
        return (sharedLibrary, share)
    }

    // MARK: - Unshare

    /// Stop sharing a library. Copies content back to private store for the owner,
    /// then removes the shared zone.
    ///
    /// Recipients will lose access, but if they previously had the share,
    /// their cached data remains until CloudKit cleans up.
    ///
    /// - Parameter sharedLibrary: The shared library to unshare
    /// - Throws: If privatization or share deletion fails
    public func unshare(_ sharedLibrary: CDLibrary) async throws {
        let context = PersistenceController.shared.viewContext

        // Copy shared content back to private store so owner keeps data
        _ = try await copyService.copyToPrivateStore(sharedLibrary, context: context)

        // Delete the CKShare (revokes access for all participants)
        if let share = PersistenceController.shared.share(for: sharedLibrary) {
            try await deleteShare(share)
        }

        // Delete the shared library object
        context.performAndWait {
            context.delete(sharedLibrary)
            try? context.save()
        }

        Logger.sync.info("Unshared library and privatized content")
        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
    }

    /// Leave a shared library (as a participant). Optionally copies content to private store first.
    ///
    /// - Parameters:
    ///   - sharedLibrary: The shared library to leave
    ///   - keepCopy: If true, copies content to private store before leaving
    /// - Throws: If operations fail
    public func leaveShare(_ sharedLibrary: CDLibrary, keepCopy: Bool) async throws {
        let context = PersistenceController.shared.viewContext

        if keepCopy {
            _ = try await copyService.copyToPrivateStore(sharedLibrary, context: context)
            Logger.sync.info("Copied shared library to private store before leaving")
        }

        // Remove participation
        if let share = PersistenceController.shared.share(for: sharedLibrary),
           let currentUser = share.currentUserParticipant {
            share.removeParticipant(currentUser)
            try context.performAndWait {
                try context.save()
            }
        }

        Logger.sync.info("Left shared library (keepCopy: \(keepCopy))")
        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
    }

    // MARK: - Participant Management

    /// Update a participant's permission level.
    ///
    /// - Parameters:
    ///   - permission: The new permission level
    ///   - participant: The participant to update
    ///   - library: The shared library containing the participant
    /// - Throws: If the permission update fails
    public func setPermission(
        _ permission: CKShare.ParticipantPermission,
        for participant: CKShare.Participant,
        in library: CDLibrary
    ) async throws {
        guard let share = PersistenceController.shared.share(for: library) else {
            throw CloudKitSharingError.shareNotFound
        }

        participant.permission = permission

        let context = PersistenceController.shared.viewContext
        try context.performAndWait {
            try context.save()
        }

        Logger.sync.info("Updated participant permission to \(String(describing: permission))")
    }

    // MARK: - Helpers

    private func createShare(for library: CDLibrary, title: String) async throws -> CKShare {
        guard let ckContainer = PersistenceController.shared.container as? NSPersistentCloudKitContainer else {
            throw CloudKitSharingError.cloudKitUnavailable
        }

        // If the library already has a share, return it
        if let existingShare = try? ckContainer.fetchShares(matching: [library.objectID])[library.objectID] {
            return existingShare
        }

        // Create new share
        let share = CKShare(rootRecord: CKRecord(recordType: "CD_Library"))
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue

        // Use the persistent container's share method
        try await ckContainer.share([library], to: share)

        let context = PersistenceController.shared.viewContext
        try context.performAndWait {
            try context.save()
        }

        return share
    }

    private func deleteShare(_ share: CKShare) async throws {
        let containerID = PersistenceController.shared.configuration.cloudKitContainerIdentifier
            ?? "iCloud.com.imbib.app"
        let ckContainer = CKContainer(identifier: containerID)
        let database = ckContainer.sharedCloudDatabase

        let operation = CKModifyRecordZonesOperation(
            recordZonesToSave: nil,
            recordZoneIDsToDelete: [share.recordID.zoneID]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
    #endif
}

// MARK: - Errors

public enum CloudKitSharingError: LocalizedError {
    case cloudKitUnavailable
    case shareNotFound
    case sharingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            return "CloudKit is not available. Enable iCloud sync to share libraries."
        case .shareNotFound:
            return "Could not find sharing information for this library."
        case .sharingFailed(let reason):
            return "Sharing failed: \(reason)"
        }
    }
}
