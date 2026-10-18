import AppIntents
import Foundation

/// The figure on screen as the current `NSUserActivity`, naming it as the
/// generated `FigureEntity` (koine's App Intents) so Siri, Shortcuts and Apple
/// Intelligence can act on "this figure".
@MainActor
final class FigureActivity {
    static let shared = FigureActivity()

    /// Activity type; listed in Info.plist `NSUserActivityTypes`.
    static let viewingActivityType = "com.implore.viewing-figure"

    private var currentActivity: NSUserActivity?
    private(set) var currentFigureID: String?

    private init() {}

    /// Make `figureID` the current activity's entity (no-op if it already is).
    func startViewing(figureID: String, title: String?) {
        guard currentFigureID != figureID || currentActivity == nil else { return }
        currentActivity?.invalidate()

        let activity = NSUserActivity(activityType: Self.viewingActivityType)
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.title = title ?? "Figure"
        activity.userInfo = ["figureID": figureID]
        activity.appEntityIdentifier = EntityIdentifier(
            for: FigureEntity.self, identifier: figureID)
        activity.becomeCurrent()

        currentActivity = activity
        currentFigureID = figureID
    }

    /// Stop the activity if it is about `figureID` (any figure when nil).
    func stop(figureID: String? = nil) {
        guard figureID == nil || figureID == currentFigureID else { return }
        currentActivity?.invalidate()
        currentActivity = nil
        currentFigureID = nil
    }
}
