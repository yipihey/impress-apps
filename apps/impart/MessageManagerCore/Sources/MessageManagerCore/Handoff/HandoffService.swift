import Foundation
import OSLog

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Manages Handoff activities for continuing conversation viewing across devices.
@MainActor
public final class HandoffService {
    public static let shared = HandoffService()

    /// Activity type for viewing a conversation thread
    public static let viewingActivityType = "com.impart.viewing-conversation"

    /// Activity type for composing a message
    public static let composingActivityType = "com.impart.composing-message"

    private var currentActivity: NSUserActivity?

    private init() {
        Logger.handoff.info("impart Handoff service initialized")
    }

    /// Start a viewing activity for a conversation.
    public func startViewing(conversationID: UUID, subject: String) {
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.viewingActivityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif

        activity.title = subject
        activity.userInfo = [
            "conversationID": conversationID.uuidString,
            "subject": subject
        ]

        activity.becomeCurrent()
        currentActivity = activity

        Logger.handoff.debug("Started viewing conversation: \(subject)")
    }

    /// Start a composing activity for a message draft.
    public func startComposing(to: String, subject: String, draftBody: String) {
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.composingActivityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif

        activity.title = "Composing: \(subject)"
        activity.userInfo = [
            "to": to,
            "subject": subject,
            "draftBody": draftBody
        ]

        activity.becomeCurrent()
        currentActivity = activity

        Logger.handoff.debug("Started composing activity: \(subject)")
    }

    /// Stop any current activity.
    public func stopActivity() {
        currentActivity?.invalidate()
        currentActivity = nil
        Logger.handoff.debug("Stopped handoff activity")
    }

    /// Parse a viewing activity from an incoming Handoff.
    public static func parseViewingActivity(_ activity: NSUserActivity) -> (conversationID: UUID, subject: String)? {
        guard activity.activityType == viewingActivityType,
              let userInfo = activity.userInfo,
              let conversationIDString = userInfo["conversationID"] as? String,
              let conversationID = UUID(uuidString: conversationIDString) else {
            return nil
        }
        let subject = userInfo["subject"] as? String ?? ""
        return (conversationID, subject)
    }

    /// Parse a composing activity from an incoming Handoff.
    public static func parseComposingActivity(_ activity: NSUserActivity) -> (to: String, subject: String, draftBody: String)? {
        guard activity.activityType == composingActivityType,
              let userInfo = activity.userInfo,
              let to = userInfo["to"] as? String,
              let subject = userInfo["subject"] as? String else {
            return nil
        }
        let draftBody = userInfo["draftBody"] as? String ?? ""
        return (to, subject, draftBody)
    }
}

public extension Notification.Name {
    static let restoreHandoffViewing = Notification.Name("impartRestoreHandoffViewing")
    static let restoreHandoffComposing = Notification.Name("impartRestoreHandoffComposing")
}

extension Logger {
    static let handoff = Logger(subsystem: "com.imbib.impart", category: "handoff")
}
