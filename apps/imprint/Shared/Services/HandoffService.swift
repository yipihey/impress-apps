import AppIntents
import Foundation
import OSLog
import ImpressLogging

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

    /// The manuscript the current activity is about, if any.
    public private(set) var currentDocumentID: UUID?

    private init() {
        Logger.handoff.infoCapture("imprint Handoff service initialized", category: "handoff")
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
        Self.point(activity, at: documentID)

        activity.becomeCurrent()
        currentActivity = activity
        currentDocumentID = documentID

        Logger.handoff.debugCapture("Started editing activity: \(title) at line \(cursorLine)", category: "handoff")
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
        Self.point(activity, at: documentID)

        activity.becomeCurrent()
        currentActivity = activity
        currentDocumentID = documentID

        Logger.handoff.debugCapture("Started viewing activity: \(title)", category: "handoff")
    }

    /// Start an editing activity for a manuscript unless one for the same
    /// manuscript is already current (several views may report the same
    /// focused manuscript). The title comes from the store.
    public func startEditingIfNeeded(documentID: UUID) {
        guard currentDocumentID != documentID || currentActivity == nil else { return }
        let title = ManuscriptStoreAdapter.shared.manuscript(id: documentID)?.title ?? "Manuscript"
        startEditing(documentID: documentID, title: title, cursorLine: 1)
    }

    /// Stop the current activity if it is about `documentID`.
    public func stop(documentID: UUID) {
        guard currentDocumentID == documentID else { return }
        stopActivity()
    }

    /// Name the manuscript an activity is about as the generated
    /// `ManuscriptEntity` (koine's App Intents), so Siri, Shortcuts and Apple
    /// Intelligence can act on the manuscript the person is looking at.
    private static func point(_ activity: NSUserActivity, at documentID: UUID) {
        // The generated intents are in the macOS target only (VerbIntents/).
        #if os(macOS)
        activity.appEntityIdentifier = EntityIdentifier(
            for: ManuscriptEntity.self,
            identifier: documentID.uuidString.lowercased()
        )
        #endif
    }

    /// Stop the current editing activity.
    public func stopEditing() {
        currentActivity?.invalidate()
        currentActivity = nil
        currentDocumentID = nil
        Logger.handoff.debugCapture("Stopped editing activity", category: "handoff")
    }

    /// Stop any current activity.
    public func stopActivity() {
        currentActivity?.invalidate()
        currentActivity = nil
        currentDocumentID = nil
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

