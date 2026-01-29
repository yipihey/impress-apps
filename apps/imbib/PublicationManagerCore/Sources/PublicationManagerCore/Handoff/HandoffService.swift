//
//  HandoffService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import OSLog

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Handoff Service

/// Manages Handoff activities for continuing PDF reading across devices.
///
/// This service enables users to start reading a PDF on one device (e.g., Mac)
/// and continue on another device (e.g., iPad) at the exact same position.
///
/// Features:
/// - Track current reading activity with publication ID, page, and zoom
/// - Automatically advertise activity via NSUserActivity
/// - Restore reading position from incoming Handoff
///
/// Integration:
/// - Call `startReading()` when user opens a PDF
/// - Call `updatePosition()` when page or zoom changes
/// - Call `stopReading()` when user closes the PDF
/// - Handle `onContinueUserActivity` in the app for incoming Handoff
///
/// Info.plist requirement:
/// ```xml
/// <key>NSUserActivityTypes</key>
/// <array>
///     <string>com.imbib.reading-pdf</string>
/// </array>
/// ```
@MainActor
public final class HandoffService {

    // MARK: - Singleton

    public static let shared = HandoffService()

    // MARK: - Constants

    /// Activity type for reading a PDF
    public static let readingActivityType = "com.imbib.reading-pdf"

    /// Activity type for viewing a publication (without PDF)
    public static let viewingActivityType = "com.imbib.viewing-publication"

    // MARK: - State

    private var currentActivity: NSUserActivity?

    // MARK: - Initialization

    private init() {
        Logger.handoff.info("Handoff service initialized")
    }

    // MARK: - Reading Activity

    /// Start a reading activity for Handoff.
    ///
    /// Call this when the user opens a PDF. The activity will be advertised
    /// to nearby devices logged into the same iCloud account.
    ///
    /// - Parameters:
    ///   - publicationID: UUID of the publication being read
    ///   - citeKey: The cite key for display and fallback lookup
    ///   - title: The paper title for display
    ///   - page: Current page number (1-indexed)
    ///   - zoom: Current zoom level (1.0 = 100%)
    public func startReading(
        publicationID: UUID,
        citeKey: String,
        title: String,
        page: Int,
        zoom: CGFloat
    ) {
        // Invalidate any existing activity
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.readingActivityType)

        // Configure for Handoff
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false  // Use Spotlight service for search
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif

        // User-visible title
        activity.title = "Reading: \(title)"

        // Data to restore
        activity.userInfo = [
            "publicationID": publicationID.uuidString,
            "citeKey": citeKey,
            "page": page,
            "zoom": Double(zoom)
        ]

        // Make this the current activity
        activity.becomeCurrent()
        currentActivity = activity

        Logger.handoff.debug("Started reading activity: \(citeKey) at page \(page)")
    }

    /// Update the reading position.
    ///
    /// Call this when the page or zoom changes. Updates are batched
    /// by the system to avoid excessive network traffic.
    ///
    /// - Parameters:
    ///   - page: New page number
    ///   - zoom: New zoom level
    public func updatePosition(page: Int, zoom: CGFloat) {
        guard let activity = currentActivity else { return }

        activity.userInfo?["page"] = page
        activity.userInfo?["zoom"] = Double(zoom)
        activity.needsSave = true

        Logger.handoff.debug("Updated reading position: page \(page), zoom \(Int(zoom * 100))%")
    }

    /// Stop the current reading activity.
    ///
    /// Call this when the user closes the PDF or navigates away.
    public func stopReading() {
        currentActivity?.invalidate()
        currentActivity = nil

        Logger.handoff.debug("Stopped reading activity")
    }

    // MARK: - Viewing Activity

    /// Start a viewing activity for a publication (without PDF).
    ///
    /// Use this when viewing publication metadata without a PDF open.
    ///
    /// - Parameters:
    ///   - publicationID: UUID of the publication
    ///   - citeKey: The cite key
    ///   - title: The paper title
    public func startViewing(
        publicationID: UUID,
        citeKey: String,
        title: String
    ) {
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.viewingActivityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif

        activity.title = title
        activity.userInfo = [
            "publicationID": publicationID.uuidString,
            "citeKey": citeKey
        ]

        activity.becomeCurrent()
        currentActivity = activity

        Logger.handoff.debug("Started viewing activity: \(citeKey)")
    }

    /// Stop any current activity.
    public func stopActivity() {
        currentActivity?.invalidate()
        currentActivity = nil
    }

    // MARK: - Activity Restoration

    /// Parse a reading activity from an incoming Handoff.
    ///
    /// - Parameter activity: The NSUserActivity from Handoff
    /// - Returns: Reading session data, or nil if the activity is invalid
    public static func parseReadingActivity(_ activity: NSUserActivity) -> HandoffReadingSession? {
        guard activity.activityType == readingActivityType,
              let userInfo = activity.userInfo,
              let publicationIDString = userInfo["publicationID"] as? String,
              let publicationID = UUID(uuidString: publicationIDString),
              let citeKey = userInfo["citeKey"] as? String else {
            return nil
        }

        let page = userInfo["page"] as? Int ?? 1
        let zoom = userInfo["zoom"] as? Double ?? 1.0

        return HandoffReadingSession(
            publicationID: publicationID,
            citeKey: citeKey,
            page: page,
            zoom: CGFloat(zoom)
        )
    }

    /// Parse a viewing activity from an incoming Handoff.
    ///
    /// - Parameter activity: The NSUserActivity from Handoff
    /// - Returns: Publication identifiers, or nil if the activity is invalid
    public static func parseViewingActivity(_ activity: NSUserActivity) -> (publicationID: UUID, citeKey: String)? {
        guard activity.activityType == viewingActivityType,
              let userInfo = activity.userInfo,
              let publicationIDString = userInfo["publicationID"] as? String,
              let publicationID = UUID(uuidString: publicationIDString),
              let citeKey = userInfo["citeKey"] as? String else {
            return nil
        }

        return (publicationID, citeKey)
    }
}

// MARK: - Handoff Reading Session

/// Data for restoring a reading session from Handoff.
public struct HandoffReadingSession: Sendable {
    /// UUID of the publication
    public let publicationID: UUID

    /// Cite key for display and fallback lookup
    public let citeKey: String

    /// Page number to restore (1-indexed)
    public let page: Int

    /// Zoom level to restore (1.0 = 100%)
    public let zoom: CGFloat
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when a Handoff reading activity is received.
    ///
    /// userInfo:
    /// - `session`: HandoffReadingSession with the restoration data
    static let restoreHandoffReading = Notification.Name("restoreHandoffReading")

    /// Posted when a Handoff viewing activity is received.
    ///
    /// userInfo:
    /// - `publicationID`: UUID of the publication
    /// - `citeKey`: String cite key
    static let restoreHandoffViewing = Notification.Name("restoreHandoffViewing")
}

// MARK: - Logger Extension

extension Logger {
    static let handoff = Logger(subsystem: "com.imbib.app", category: "handoff")
}
