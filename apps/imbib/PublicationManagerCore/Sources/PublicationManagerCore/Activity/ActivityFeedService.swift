//
//  ActivityFeedService.swift
//  PublicationManagerCore
//
//  Service for recording and querying activity in shared libraries.
//

import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Activity Feed Service

/// Service for recording and querying activity in shared libraries.
///
/// Privacy principle: Records what happens to *shared content* (papers added,
/// annotations made) but never tracks personal behavior (reading habits,
/// time spent, completion status).
@MainActor
public final class ActivityFeedService {

    public static let shared = ActivityFeedService()

    private let store: RustStoreAdapter

    private init() {
        self.store = .shared
    }

    // MARK: - Record Activity

    /// Record an activity event in a library.
    ///
    /// - Parameters:
    ///   - type: The type of activity
    ///   - actorName: Display name of the person who performed the action
    ///   - targetTitle: Title of the affected paper or collection
    ///   - targetID: ID of the affected entity
    ///   - detail: Optional extra context
    ///   - libraryID: The library where this happened
    @discardableResult
    public func recordActivity(
        type: ActivityType,
        actorName: String? = nil,
        targetTitle: String? = nil,
        targetID: UUID? = nil,
        detail: String? = nil,
        in libraryID: UUID
    ) -> ActivityRecord? {
        let resolvedActorName = actorName ?? resolveCurrentUserName()

        let record = store.createActivityRecord(
            libraryId: libraryID,
            activityType: type.rawValue,
            actorDisplayName: resolvedActorName,
            targetTitle: targetTitle,
            targetId: targetID?.uuidString,
            detail: detail
        )

        if record != nil {
            NotificationCenter.default.post(name: .activityFeedUpdated, object: libraryID)
        }

        return record
    }

    // MARK: - Queries

    /// Get recent activity for a library.
    ///
    /// - Parameters:
    ///   - libraryID: The library to query
    ///   - limit: Maximum number of records to return (default 50)
    /// - Returns: Activity records sorted by date (newest first)
    public func recentActivity(in libraryID: UUID, limit: Int = 50) -> [ActivityRecord] {
        store.listActivityRecords(libraryId: libraryID, limit: UInt32(limit))
    }

    /// Count of activity records since a given date.
    /// Useful for badge display.
    public func unreadActivityCount(in libraryID: UUID, since date: Date) -> Int {
        let records = store.listActivityRecords(libraryId: libraryID)
        return records.filter { $0.date > date }.count
    }

    /// Clear all activity records for a library.
    public func clearActivity(in libraryID: UUID) {
        store.clearActivityRecords(libraryId: libraryID)
    }

    // MARK: - Helpers

    private func resolveCurrentUserName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "You"
        #else
        return UIDevice.current.name
        #endif
    }
}
