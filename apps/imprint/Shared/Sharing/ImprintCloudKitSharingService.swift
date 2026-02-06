//
//  ImprintCloudKitSharingService.swift
//  imprint
//
//  Coordinates CloudKit sharing for imprint folder hierarchies.
//  Sharing a folder shares its entire subtree (subfolders + document references).
//  Actual .imprint file content requires files in shared iCloud Drive location.
//

import Foundation
import CoreData
import OSLog
import ImpressLogging
#if canImport(CloudKit)
import CloudKit
#endif

private let logger = Logger(subsystem: "com.imbib.imprint", category: "sharing")

public actor ImprintCloudKitSharingService {

    public static let shared = ImprintCloudKitSharingService()

    private let copyService = SharedWorkspaceCopyService.shared

    private init() {}

    #if canImport(CloudKit)

    // MARK: - Share Folder

    /// Share a folder by wrapping it in a workspace in the shared store and creating a CKShare.
    ///
    /// - Parameter folder: The private folder to share
    /// - Returns: Tuple of the shared CDWorkspace and the CKShare
    @MainActor
    public func shareFolder(_ folder: CDFolder) async throws -> (CDWorkspace, CKShare) {
        let context = ImprintPersistenceController.shared.viewContext

        // Step 1: Copy folder tree to shared store
        let sharedWorkspace = try copyService.copyFolderToSharedStore(folder, context: context)

        // Step 2: Create CKShare
        let share = try await createShare(for: sharedWorkspace, title: folder.name)

        logger.infoCapture("Created share for folder '\(folder.name)'", category: "sharing")
        return (sharedWorkspace, share)
    }

    // MARK: - Unshare

    /// Stop sharing a workspace. Copies content back to private store, then removes share.
    @MainActor
    public func unshare(_ sharedWorkspace: CDWorkspace) async throws {
        let context = ImprintPersistenceController.shared.viewContext

        // Copy back to private store
        try copyService.copyWorkspaceToPrivateStore(sharedWorkspace, context: context)

        // Delete the shared workspace
        context.delete(sharedWorkspace)
        try context.save()

        logger.infoCapture("Unshared workspace '\(sharedWorkspace.name)'", category: "sharing")
    }

    // MARK: - Leave Share

    /// Leave a shared workspace (as a participant, not the owner).
    @MainActor
    public func leaveShare(_ sharedWorkspace: CDWorkspace, keepCopy: Bool) async throws {
        let context = ImprintPersistenceController.shared.viewContext

        if keepCopy {
            // Copy to private store before leaving
            try copyService.copyWorkspaceToPrivateStore(sharedWorkspace, context: context)
        }

        // Delete the shared workspace locally
        context.delete(sharedWorkspace)
        try context.save()

        logger.infoCapture("Left shared workspace '\(sharedWorkspace.name)' (keepCopy: \(keepCopy))", category: "sharing")
    }

    // MARK: - Permissions

    /// Set read/write permission for a participant.
    public func setPermission(
        _ permission: CKShare.ParticipantPermission,
        for participant: CKShare.Participant,
        in share: CKShare
    ) async throws {
        participant.permission = permission

        let container = CKContainer(identifier: "iCloud.com.imbib.shared")
        let database = container.sharedCloudDatabase

        try await database.save(share)

        logger.infoCapture("Set permission \(permission.rawValue) for participant", category: "sharing")
    }

    // MARK: - Private

    private func createShare(for workspace: CDWorkspace, title: String) async throws -> CKShare {
        guard let ckContainer = ImprintPersistenceController.shared.container as? NSPersistentCloudKitContainer else {
            throw ImprintSharingError.cloudKitUnavailable
        }

        // Check for existing share
        if let existingShare = try? ckContainer.fetchShares(matching: [workspace.objectID])[workspace.objectID] {
            return existingShare
        }

        // Create new share
        let share = CKShare(rootRecord: CKRecord(recordType: "CD_Workspace"))
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue

        try await ckContainer.share([workspace], to: share)

        let context = ImprintPersistenceController.shared.viewContext
        try context.performAndWait {
            try context.save()
        }

        return share
    }
    #endif
}

// MARK: - Errors

public enum ImprintSharingError: LocalizedError {
    case cloudKitUnavailable
    case sharedStoreUnavailable
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            return "CloudKit is not available. Check your iCloud settings."
        case .sharedStoreUnavailable:
            return "The shared store is not available."
        case .copyFailed(let detail):
            return "Failed to copy data: \(detail)"
        }
    }
}
