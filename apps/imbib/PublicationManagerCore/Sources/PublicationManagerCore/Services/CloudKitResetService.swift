//
//  CloudKitResetService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-24.
//

import Foundation
import CloudKit
import OSLog

/// Service for resetting CloudKit data (zone purge).
///
/// When resetting to first run, simply deleting local Core Data is insufficient because
/// CloudKit will sync all the cloud records back on next app launch. This service
/// purges the CloudKit zone to ensure a complete reset.
public actor CloudKitResetService {

    public static let shared = CloudKitResetService()

    private let containerID = "iCloud.com.imbib.app"
    private let zoneName = "com.apple.coredata.cloudkit.zone"

    /// Purge the CloudKit zone used by Core Data.
    ///
    /// This deletes the entire zone, which removes all records. Core Data will
    /// automatically recreate the zone when sync is next enabled.
    ///
    /// - Throws: CKError if the deletion fails (except for zoneNotFound, which is ignored)
    public func purgeCloudKitZone() async throws {
        let container = CKContainer(identifier: containerID)
        let database = container.privateCloudDatabase

        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        Logger.sync.infoCapture("Purging CloudKit zone: \(self.zoneName)", category: "cloudkit")

        do {
            try await database.deleteRecordZone(withID: zoneID)
            Logger.sync.infoCapture("CloudKit zone purged successfully", category: "cloudkit")
        } catch let error as CKError where error.code == .zoneNotFound {
            // Zone doesn't exist - nothing to delete, this is fine
            Logger.sync.infoCapture("CloudKit zone not found (already empty)", category: "cloudkit")
        }
    }

    /// Check if CloudKit is available for reset operations.
    ///
    /// - Returns: `true` if iCloud is signed in and available
    public func canPurgeCloudKit() async -> Bool {
        // Check if iCloud is available (user is signed in)
        guard FileManager.default.ubiquityIdentityToken != nil else {
            Logger.sync.infoCapture("iCloud not available (not signed in)", category: "cloudkit")
            return false
        }

        let container = CKContainer(identifier: containerID)
        do {
            let status = try await container.accountStatus()
            let available = status == .available
            Logger.sync.infoCapture("CloudKit account status: \(status.rawValue), available: \(available)", category: "cloudkit")
            return available
        } catch {
            Logger.sync.errorCapture("Failed to check CloudKit account status: \(error.localizedDescription)", category: "cloudkit")
            return false
        }
    }
}
