//
//  CloudKitResetService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-24.
//

import Foundation
import CloudKit
import OSLog
#if os(macOS)
import Security
#endif

/// Service for resetting CloudKit data (zone purge).
///
/// When resetting to first run, simply deleting local Core Data is insufficient because
/// CloudKit will sync all the cloud records back on next app launch. This service
/// purges the CloudKit zone to ensure a complete reset.
public actor CloudKitResetService {

    public static let shared = CloudKitResetService()

    private let containerID = "iCloud.com.imbib.app"
    private let zoneName = "com.apple.coredata.cloudkit.zone"

    /// Whether this process is entitled for the CloudKit container. imbib
    /// migrated OFF CloudKit (ADR-023), so its builds carry no
    /// `com.apple.developer.icloud-container-identifiers` entitlement — and
    /// `CKContainer(identifier:)` **traps** (SIGTRAP) if the identifier isn't
    /// entitled. Guarding on the entitlement avoids constructing the container
    /// at all. (This crash surfaced only once XCUITest could run, but it also
    /// hit any iCloud-signed-in user who invoked Settings → reset-to-first-run.)
    nonisolated static let hasCloudKitEntitlement: Bool = {
        #if os(macOS)
        // SecTask entitlement APIs are macOS-only.
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return ((value as? [String])?.isEmpty == false)
        #else
        // imbib-iOS is also off CloudKit (ADR-023) — never construct the container.
        return false
        #endif
    }()

    /// Purge the CloudKit zone used by Core Data.
    ///
    /// This deletes the entire zone, which removes all records. Core Data will
    /// automatically recreate the zone when sync is next enabled.
    ///
    /// - Throws: CKError if the deletion fails (except for zoneNotFound, which is ignored)
    public func purgeCloudKitZone() async throws {
        guard Self.hasCloudKitEntitlement else {
            Logger.sync.infoCapture("CloudKit not entitled — skipping zone purge", category: "cloudkit")
            return
        }
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
        // No CloudKit entitlement → constructing the container would trap.
        guard Self.hasCloudKitEntitlement else {
            Logger.sync.infoCapture("CloudKit not entitled — cannot purge", category: "cloudkit")
            return false
        }
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
