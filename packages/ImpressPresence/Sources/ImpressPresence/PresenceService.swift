//
//  PresenceService.swift
//  ImpressPresence
//
//  Real-time presence service using CloudKit shared zones.
//  Provides collaborator awareness for shared content.
//

import Foundation
import OSLog

#if canImport(CloudKit)
import CloudKit
#endif

private let logger = Logger(subsystem: "com.impress.presence", category: "presence")

// MARK: - Presence Info

/// Information about a user's presence state.
public struct PresenceInfo: Identifiable, Equatable, Sendable {
    /// Unique identifier for this presence record.
    public let id: String

    /// The user's display name.
    public let userName: String

    /// The user's email (if available).
    public let userEmail: String?

    /// The user's avatar initials (derived from name).
    public var initials: String {
        let words = userName.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(userName.prefix(2)).uppercased()
    }

    /// What the user is currently viewing/editing.
    public let currentActivity: Activity?

    /// When the presence was last updated.
    public let lastUpdated: Date

    /// Whether the user is considered active (updated within threshold).
    public var isActive: Bool {
        Date().timeIntervalSince(lastUpdated) < 300 // 5 minutes
    }

    /// The type of activity the user is engaged in.
    public enum Activity: Equatable, Sendable {
        /// Reading a document/paper.
        case reading(itemId: String, itemTitle: String)

        /// Editing a document.
        case editing(itemId: String, itemTitle: String)

        /// Browsing a list/library.
        case browsing(location: String)

        /// Idle/present but no specific activity.
        case idle

        public var description: String {
            switch self {
            case .reading(_, let title):
                return "Reading \"\(title)\""
            case .editing(_, let title):
                return "Editing \"\(title)\""
            case .browsing(let location):
                return "Browsing \(location)"
            case .idle:
                return "Online"
            }
        }
    }

    public init(
        id: String,
        userName: String,
        userEmail: String? = nil,
        currentActivity: Activity? = nil,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.userName = userName
        self.userEmail = userEmail
        self.currentActivity = currentActivity
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Presence Service

/// Service for managing real-time presence in shared CloudKit zones.
///
/// The presence service:
/// - Maintains the current user's presence record
/// - Subscribes to presence updates from collaborators
/// - Provides a list of active collaborators
///
/// Presence is implemented using CloudKit's shared database:
/// - Presence records are stored in the shared zone
/// - Records auto-expire based on `lastUpdated` timestamp
/// - Changes are pushed via CloudKit subscriptions
@MainActor @Observable
public final class PresenceService {

    // MARK: - Singleton

    public static let shared = PresenceService()

    // MARK: - Constants

    /// Threshold for considering a user active (5 minutes).
    public static let activeThreshold: TimeInterval = 300

    /// Interval for updating own presence (30 seconds).
    private static let updateInterval: TimeInterval = 30

    // MARK: - Published State

    /// All known collaborator presences (excluding self).
    public private(set) var collaborators: [PresenceInfo] = []

    /// Current user's presence info.
    public private(set) var currentUserPresence: PresenceInfo?

    /// Whether the service is connected and running.
    public private(set) var isRunning = false

    /// Last error encountered.
    public private(set) var lastError: Error?

    // MARK: - Private State

    #if canImport(CloudKit)
    private var container: CKContainer?
    private var database: CKDatabase?
    private var subscription: CKSubscription?
    #endif
    private var updateTimer: Timer?
    private var currentZoneID: String?
    private var currentUserID: String?

    // MARK: - Initialization

    private init() {}

    // MARK: - Lifecycle

    /// Start the presence service for a shared zone.
    ///
    /// - Parameters:
    ///   - zoneID: The CloudKit zone ID to monitor
    ///   - containerID: The CloudKit container identifier
    public func start(zoneID: String, containerID: String) async {
        #if canImport(CloudKit)
        guard !isRunning else { return }

        logger.info("Starting presence service for zone \(zoneID)")

        currentZoneID = zoneID
        container = CKContainer(identifier: containerID)
        database = container?.sharedCloudDatabase

        do {
            // Get current user
            let userID = try await container?.userRecordID()
            currentUserID = userID?.recordName

            // Fetch current user's name
            if let userID = userID {
                let userName = try await fetchUserName(userID: userID)
                currentUserPresence = PresenceInfo(
                    id: userID.recordName,
                    userName: userName,
                    currentActivity: .idle
                )
            }

            // Set up subscription for presence changes
            await setupSubscription(zoneID: zoneID)

            // Fetch existing presence records
            await fetchAllPresence()

            // Start periodic presence updates
            startUpdateTimer()

            isRunning = true
            lastError = nil

            logger.info("Presence service started successfully")

        } catch {
            logger.error("Failed to start presence service: \(error.localizedDescription)")
            lastError = error
        }
        #endif
    }

    /// Stop the presence service and clean up.
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping presence service")

        #if canImport(CloudKit)
        // Remove our presence record
        await removeOwnPresence()

        // Cancel subscription
        await removeSubscription()
        #endif

        // Stop timer
        updateTimer?.invalidate()
        updateTimer = nil

        collaborators = []
        currentUserPresence = nil
        isRunning = false

        logger.info("Presence service stopped")
    }

    // MARK: - Activity Updates

    /// Update the current user's activity.
    ///
    /// - Parameter activity: The new activity
    public func updateActivity(_ activity: PresenceInfo.Activity) async {
        guard isRunning, var presence = currentUserPresence else { return }

        presence = PresenceInfo(
            id: presence.id,
            userName: presence.userName,
            userEmail: presence.userEmail,
            currentActivity: activity,
            lastUpdated: Date()
        )
        currentUserPresence = presence

        #if canImport(CloudKit)
        await saveOwnPresence()
        #endif
    }

    // MARK: - Private Methods

    #if canImport(CloudKit)
    private func fetchUserName(userID: CKRecord.ID) async throws -> String {
        // Use device owner name as fallback since userIdentity is deprecated
        #if os(macOS)
        let fullName = NSFullUserName()
        if !fullName.isEmpty {
            return fullName
        }
        #endif

        // Fallback to a generic name with partial ID
        let shortId = String(userID.recordName.suffix(4))
        return "User \(shortId)"
    }

    private func setupSubscription(zoneID: String) async {
        guard let database = database else { return }

        let subscriptionID = "presence-\(zoneID)"

        // Check if subscription already exists
        do {
            let existing = try await database.subscription(for: subscriptionID)
            subscription = existing
            logger.debug("Found existing presence subscription")
            return
        } catch {
            // Subscription doesn't exist, create it
        }

        let recordZoneID = CKRecordZone.ID(zoneName: zoneID, ownerName: CKCurrentUserDefaultName)
        let newSubscription = CKRecordZoneSubscription(
            zoneID: recordZoneID,
            subscriptionID: subscriptionID
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        newSubscription.notificationInfo = notificationInfo

        do {
            subscription = try await database.save(newSubscription)
            logger.info("Created presence subscription")
        } catch {
            logger.error("Failed to create subscription: \(error.localizedDescription)")
        }
    }

    private func removeSubscription() async {
        guard let subscription = subscription, let database = database else { return }

        do {
            try await database.deleteSubscription(withID: subscription.subscriptionID)
            logger.info("Removed presence subscription")
        } catch {
            logger.debug("Failed to remove subscription: \(error.localizedDescription)")
        }

        self.subscription = nil
    }

    private func fetchAllPresence() async {
        guard let database = database, let zoneID = currentZoneID else { return }

        let recordZoneID = CKRecordZone.ID(zoneName: zoneID, ownerName: CKCurrentUserDefaultName)
        let query = CKQuery(recordType: "Presence", predicate: NSPredicate(value: true))

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: recordZoneID)

            var newCollaborators: [PresenceInfo] = []
            for (_, result) in results {
                if case .success(let record) = result {
                    if let presence = presenceInfo(from: record), presence.id != currentUserID {
                        newCollaborators.append(presence)
                    }
                }
            }

            // Filter to only active users
            collaborators = newCollaborators.filter { $0.isActive }

            let count = collaborators.count
            logger.info("Fetched \(count) active collaborators")

        } catch {
            logger.error("Failed to fetch presence: \(error.localizedDescription)")
        }
    }

    private func saveOwnPresence() async {
        guard let database = database,
              let zoneID = currentZoneID,
              let userID = currentUserID,
              let presence = currentUserPresence else { return }

        let recordZoneID = CKRecordZone.ID(zoneName: zoneID, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: "presence-\(userID)", zoneID: recordZoneID)
        let record = CKRecord(recordType: "Presence", recordID: recordID)

        record["userID"] = userID as CKRecordValue
        record["userName"] = presence.userName as CKRecordValue
        record["lastUpdated"] = presence.lastUpdated as CKRecordValue

        if let activity = presence.currentActivity {
            record["activityType"] = activityType(for: activity) as CKRecordValue
            record["activityDescription"] = activity.description as CKRecordValue

            switch activity {
            case .reading(let itemId, _), .editing(let itemId, _):
                record["activityItemId"] = itemId as CKRecordValue
            default:
                break
            }
        }

        do {
            try await database.save(record)
            logger.debug("Saved presence record")
        } catch {
            logger.error("Failed to save presence: \(error.localizedDescription)")
        }
    }

    private func removeOwnPresence() async {
        guard let database = database,
              let zoneID = currentZoneID,
              let userID = currentUserID else { return }

        let recordZoneID = CKRecordZone.ID(zoneName: zoneID, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: "presence-\(userID)", zoneID: recordZoneID)

        do {
            try await database.deleteRecord(withID: recordID)
            logger.debug("Removed presence record")
        } catch {
            logger.debug("Failed to remove presence: \(error.localizedDescription)")
        }
    }

    private func presenceInfo(from record: CKRecord) -> PresenceInfo? {
        guard let userID = record["userID"] as? String,
              let userName = record["userName"] as? String,
              let lastUpdated = record["lastUpdated"] as? Date else {
            return nil
        }

        var activity: PresenceInfo.Activity = .idle
        if let activityTypeRaw = record["activityType"] as? String,
           let activityDesc = record["activityDescription"] as? String {
            let itemId = record["activityItemId"] as? String ?? ""
            activity = parseActivity(type: activityTypeRaw, description: activityDesc, itemId: itemId)
        }

        return PresenceInfo(
            id: userID,
            userName: userName,
            currentActivity: activity,
            lastUpdated: lastUpdated
        )
    }

    private func activityType(for activity: PresenceInfo.Activity) -> String {
        switch activity {
        case .reading: return "reading"
        case .editing: return "editing"
        case .browsing: return "browsing"
        case .idle: return "idle"
        }
    }

    private func parseActivity(type: String, description: String, itemId: String) -> PresenceInfo.Activity {
        switch type {
        case "reading":
            return .reading(itemId: itemId, itemTitle: extractTitle(from: description))
        case "editing":
            return .editing(itemId: itemId, itemTitle: extractTitle(from: description))
        case "browsing":
            return .browsing(location: extractLocation(from: description))
        default:
            return .idle
        }
    }

    private func extractTitle(from description: String) -> String {
        // Extract title from "Reading/Editing \"Title\""
        if let start = description.firstIndex(of: "\""),
           let end = description.lastIndex(of: "\""),
           start < end {
            let titleStart = description.index(after: start)
            return String(description[titleStart..<end])
        }
        return "Unknown"
    }

    private func extractLocation(from description: String) -> String {
        // Extract location from "Browsing Location"
        if description.hasPrefix("Browsing ") {
            return String(description.dropFirst("Browsing ".count))
        }
        return description
    }
    #endif

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        let interval = Self.updateInterval
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.periodicUpdate()
            }
        }
    }

    private func periodicUpdate() async {
        #if canImport(CloudKit)
        await saveOwnPresence()
        await fetchAllPresence()
        #endif
    }
}

// MARK: - Notification Extension

public extension Notification.Name {
    /// Posted when collaborator presence changes.
    static let presenceDidChange = Notification.Name("com.impress.presenceDidChange")
}
