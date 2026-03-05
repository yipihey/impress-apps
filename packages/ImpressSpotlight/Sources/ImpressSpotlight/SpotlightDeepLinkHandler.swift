import CoreSpotlight
import Foundation
import ImpressKit
import OSLog

#if canImport(AppKit)
import AppKit
#endif

/// Handles Spotlight deep-link activations across all impress apps.
///
/// When a user taps a Spotlight result, macOS delivers a `CSSearchableItemActionType`
/// user activity. This handler extracts the item UUID and domain, then either:
/// - Calls a local navigation callback (if the owning app is already frontmost)
/// - Opens the owning app via its URL scheme (cross-app activation)
///
/// This handler intentionally bypasses `URLSchemeHandler` and its automation-enabled
/// gate. Spotlight deep-links are user-initiated OS interactions and must always work.
public struct SpotlightDeepLinkHandler {

    /// Notification posted when Spotlight wants to navigate to an item and no
    /// callback was provided. `userInfo` contains `"itemID"` (String) and `"domain"` (String).
    public static let navigateNotification = Notification.Name("ImpressSpotlightNavigate")

    /// Handles a `CSSearchableItemActionType` user activity.
    ///
    /// - Parameters:
    ///   - userActivity: The user activity from `application(_:continue:)` or `.onContinueUserActivity`.
    ///   - currentApp: The app currently running (used to decide local vs. cross-app routing).
    ///   - onLocalNavigation: Optional callback for local navigation. Receives the item UUID and domain.
    ///                        If nil, posts `navigateNotification` instead.
    /// - Returns: `true` if the activity was handled.
    public static func handle(
        _ userActivity: NSUserActivity,
        currentApp: SiblingApp,
        onLocalNavigation: ((UUID, String) -> Void)? = nil
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }

        guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let uuid = UUID(uuidString: identifier) else {
            Logger.spotlight.warning("Spotlight deep-link: missing or invalid identifier")
            return false
        }

        // Determine which app owns this item from the domain identifier
        let domain = userActivity.userInfo?["kCSSearchableItemDomainIdentifier"] as? String ?? ""
        let owningApp = appForDomain(domain)

        Logger.spotlight.info("Spotlight deep-link: id=\(identifier) domain=\(domain) owner=\(owningApp?.rawValue ?? "unknown")")

        if owningApp == nil || owningApp == currentApp {
            // Local navigation
            if let onLocalNavigation {
                onLocalNavigation(uuid, domain)
            } else {
                postNavigateNotification(uuid: uuid, domain: domain)
            }
            return true
        }

        // Cross-app — open via URL scheme
        #if canImport(AppKit)
        if let owningApp, let url = deepLinkURL(for: uuid, domain: domain, app: owningApp) {
            NSWorkspace.shared.open(url)
            return true
        }
        #endif

        // Fallback: local navigation
        if let onLocalNavigation {
            onLocalNavigation(uuid, domain)
        } else {
            postNavigateNotification(uuid: uuid, domain: domain)
        }
        return true
    }

    // MARK: - Helpers

    private static func postNavigateNotification(uuid: UUID, domain: String) {
        NotificationCenter.default.post(
            name: navigateNotification,
            object: nil,
            userInfo: [
                "itemID": uuid.uuidString,
                "domain": domain
            ]
        )
    }

    // MARK: - Domain → App Mapping

    private static func appForDomain(_ domain: String?) -> SiblingApp? {
        switch domain {
        case SpotlightDomain.paper: return .imbib
        case SpotlightDomain.document: return .imprint
        case SpotlightDomain.figure: return .implore
        case SpotlightDomain.conversation: return .impart
        case SpotlightDomain.task: return .impel
        default: return nil
        }
    }

    // MARK: - Deep Link URL Construction

    private static func deepLinkURL(for id: UUID, domain: String?, app: SiblingApp) -> URL? {
        let impressURL: ImpressURL
        switch domain {
        case SpotlightDomain.paper:
            impressURL = ImpressURL.openArtifact(id: id)
        case SpotlightDomain.document:
            impressURL = ImpressURL.openDocument(id: id)
        case SpotlightDomain.figure:
            impressURL = ImpressURL.openFigure(id: id)
        case SpotlightDomain.conversation:
            impressURL = ImpressURL.openConversation(id: id)
        default:
            impressURL = ImpressURL(app: app, action: "open", resourceType: "item", resourceID: id.uuidString)
        }
        return impressURL.url
    }
}
