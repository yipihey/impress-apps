import Foundation
import OSLog

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Manages Handoff activities for continuing document editing across devices.
@MainActor
public final class HandoffService {
    public static let shared = HandoffService()

    /// Activity type for editing a Typst document
    public static let editingActivityType = "com.imprint.editing-document"

    /// Activity type for viewing compiled PDF output
    public static let viewingActivityType = "com.imprint.viewing-document"

    private var currentActivity: NSUserActivity?

    private init() {
        Logger.handoff.info("imprint Handoff service initialized")
    }

    /// Start an editing activity for Handoff.
    public func startEditing(documentID: UUID, title: String, cursorLine: Int) {
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.editingActivityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif

        activity.title = "Editing: \(title)"
        activity.userInfo = [
            "documentID": documentID.uuidString,
            "cursorLine": cursorLine
        ]

        activity.becomeCurrent()
        currentActivity = activity

        Logger.handoff.debug("Started editing activity: \(title) at line \(cursorLine)")
    }

    /// Update the cursor position.
    public func updateCursorPosition(line: Int, column: Int) {
        guard let activity = currentActivity else { return }
        activity.userInfo?["cursorLine"] = line
        activity.userInfo?["cursorColumn"] = column
        activity.needsSave = true
    }

    /// Start a viewing activity for compiled PDF.
    public func startViewing(documentID: UUID, title: String) {
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.viewingActivityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif

        activity.title = title
        activity.userInfo = [
            "documentID": documentID.uuidString
        ]

        activity.becomeCurrent()
        currentActivity = activity

        Logger.handoff.debug("Started viewing activity: \(title)")
    }

    /// Stop the current editing activity.
    public func stopEditing() {
        currentActivity?.invalidate()
        currentActivity = nil
        Logger.handoff.debug("Stopped editing activity")
    }

    /// Stop any current activity.
    public func stopActivity() {
        currentActivity?.invalidate()
        currentActivity = nil
    }

    /// Parse an editing activity from an incoming Handoff.
    public static func parseEditingActivity(_ activity: NSUserActivity) -> HandoffEditingSession? {
        guard activity.activityType == editingActivityType,
              let userInfo = activity.userInfo,
              let documentIDString = userInfo["documentID"] as? String,
              let documentID = UUID(uuidString: documentIDString) else {
            return nil
        }

        let cursorLine = userInfo["cursorLine"] as? Int ?? 1
        let cursorColumn = userInfo["cursorColumn"] as? Int ?? 0

        return HandoffEditingSession(
            documentID: documentID,
            cursorLine: cursorLine,
            cursorColumn: cursorColumn
        )
    }

    /// Parse a viewing activity from an incoming Handoff.
    public static func parseViewingActivity(_ activity: NSUserActivity) -> UUID? {
        guard activity.activityType == viewingActivityType,
              let userInfo = activity.userInfo,
              let documentIDString = userInfo["documentID"] as? String,
              let documentID = UUID(uuidString: documentIDString) else {
            return nil
        }
        return documentID
    }
}

/// Data for restoring an editing session from Handoff.
public struct HandoffEditingSession: Sendable {
    public let documentID: UUID
    public let cursorLine: Int
    public let cursorColumn: Int
}

public extension Notification.Name {
    static let restoreHandoffEditing = Notification.Name("restoreHandoffEditing")
    static let restoreHandoffViewing = Notification.Name("restoreHandoffViewing")
}

extension Logger {
    static let handoff = Logger(subsystem: "com.imbib.imprint", category: "handoff")
}
