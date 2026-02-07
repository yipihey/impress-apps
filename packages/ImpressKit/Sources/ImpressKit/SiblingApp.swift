import Foundation

/// Enumerates all apps in the Impress research suite.
public enum SiblingApp: String, CaseIterable, Sendable, Codable {
    case imbib
    case imprint
    case implore
    case impel
    case impart

    /// The macOS bundle identifier for this app.
    public var bundleID: String {
        switch self {
        case .imbib: return "com.imbib.app.ios"
        case .imprint: return "com.imbib.imprint"
        case .implore: return "com.impress.implore"
        case .impel: return "com.impress.impel"
        case .impart: return "com.imbib.impart"
        }
    }

    /// The URL scheme for deep-linking into this app.
    public var urlScheme: String { rawValue }

    /// The default HTTP automation port for this app (development/debug channel).
    public var httpPort: UInt16 {
        switch self {
        case .imbib: return 23120
        case .imprint: return 23121
        case .implore: return 23123
        case .impel: return 23124
        case .impart: return 23122
        }
    }

    /// Human-readable display name.
    public var displayName: String { rawValue }
}
