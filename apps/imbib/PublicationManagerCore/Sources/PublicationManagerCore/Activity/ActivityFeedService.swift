//
//  ActivityFeedService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
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

    private let persistenceController: PersistenceController

    private init() {
        self.persistenceController = .shared
    }

    /// Initialize with custom persistence controller (for testing)
    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - Record Activity

    /// Record an activity event in a shared library.
    ///
    /// Only records for shared libraries. Silently returns for private libraries.
    ///
    /// - Parameters:
    ///   - type: The type of activity
    ///   - actorName: Display name of the person who performed the action
    ///   - targetTitle: Title of the affected paper or collection
    ///   - targetID: ID of the affected entity
    ///   - detail: Optional extra context
    ///   - library: The library where this happened
    @discardableResult
    public func recordActivity(
        type: CDActivityRecord.ActivityType,
        actorName: String? = nil,
        targetTitle: String? = nil,
        targetID: UUID? = nil,
        detail: String? = nil,
        in library: CDLibrary
    ) throws -> CDActivityRecord? {
        // Only record for shared libraries
        guard library.isSharedLibrary else { return nil }

        let context = persistenceController.viewContext

        let record = CDActivityRecord(context: context)
        record.id = UUID()
        record.activityType = type.rawValue
        record.actorDisplayName = actorName ?? resolveCurrentUserName(for: library)
        record.targetTitle = targetTitle
        record.targetID = targetID
        record.detail = detail
        record.date = Date()
        record.library = library

        try context.save()

        NotificationCenter.default.post(name: .activityFeedUpdated, object: library)

        return record
    }

    // MARK: - Queries

    /// Get recent activity for a library.
    ///
    /// - Parameters:
    ///   - library: The library to query
    ///   - limit: Maximum number of records to return (default 50)
    /// - Returns: Activity records sorted by date (newest first)
    public func recentActivity(in library: CDLibrary, limit: Int = 50) -> [CDActivityRecord] {
        (library.activityRecords ?? [])
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Count of activity records since a given date.
    /// Useful for badge display.
    public func unreadActivityCount(in library: CDLibrary, since date: Date) -> Int {
        (library.activityRecords ?? [])
            .filter { $0.date > date }
            .count
    }

    // MARK: - Helpers

    private func resolveCurrentUserName(for library: CDLibrary) -> String {
        #if canImport(CloudKit)
        if let share = PersistenceController.shared.share(for: library),
           let participant = share.currentUserParticipant,
           let nameComponents = participant.userIdentity.nameComponents {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let name = formatter.string(from: nameComponents)
            if !name.isEmpty { return name }
        }
        #endif

        #if os(macOS)
        return Host.current().localizedName ?? "You"
        #else
        return UIDevice.current.name
        #endif
    }
}
