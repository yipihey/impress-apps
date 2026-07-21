import Foundation

/// Type-safe wrapper around the shared UserDefaults suite for cross-app preferences.
public struct SharedDefaults: Sendable {
    /// The shared UserDefaults suite for the Impress app group.
    public static let suite: UserDefaults = {
        UserDefaults(suiteName: SiblingDiscovery.suiteGroupID) ?? .standard
    }()

    // MARK: - Known Keys

    private enum Keys {
        static let lastActiveApp = "impress.lastActiveApp"
        static let appVersionPrefix = "impress.version."
        static let authorIdentifier = "impress.author.identifier"
    }

    /// A stable, opaque identifier for the person using this installation,
    /// minted once and reused across every launch and across every sibling
    /// app in the group (imbib, imprint, …). Used to attribute comments and
    /// annotations to "this user" for ownership checks — unlike a device
    /// name, it never drifts and is never `nil`.
    ///
    /// The first read mints a fresh UUID and persists it; all later reads
    /// (in any process in the group) return the same value.
    public static var authorIdentifier: String {
        if let existing = suite.string(forKey: Keys.authorIdentifier), !existing.isEmpty {
            return existing
        }
        let minted = "author:" + UUID().uuidString
        suite.set(minted, forKey: Keys.authorIdentifier)
        return minted
    }

    /// The last app in the suite that was frontmost.
    public static var lastActiveApp: SiblingApp? {
        get {
            guard let raw = suite.string(forKey: Keys.lastActiveApp) else { return nil }
            return SiblingApp(rawValue: raw)
        }
        set {
            suite.set(newValue?.rawValue, forKey: Keys.lastActiveApp)
        }
    }

    /// Records the current app's version in shared defaults (for sibling version checks).
    public static func recordVersion(_ version: String, for app: SiblingApp) {
        suite.set(version, forKey: Keys.appVersionPrefix + app.rawValue)
    }

    /// Gets the recorded version for a sibling app.
    public static func version(for app: SiblingApp) -> String? {
        suite.string(forKey: Keys.appVersionPrefix + app.rawValue)
    }
}
