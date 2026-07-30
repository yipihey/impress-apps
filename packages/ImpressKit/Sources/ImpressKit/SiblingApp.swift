import Foundation

/// One row of the sibling-app table: everything the suite needs in order to
/// address another app — its bundle identifier, deep-link scheme and local
/// HTTP automation port.
///
/// This is the `AppShellConfiguration` pattern one level down: adding an app to
/// the suite means adding a descriptor row, not editing N parallel `switch`
/// statements that drift the moment one of them is updated alone. (They did
/// drift: `ImpressCommandPalette.AppEndpoint` still carries a second port table
/// where impel and implore are transposed relative to this one — see the note
/// on `httpPort` below.)
public struct SiblingAppDescriptor: Sendable, Equatable, Hashable {
    /// The app this row describes.
    public let id: SiblingApp
    /// The macOS bundle identifier.
    public let bundleID: String
    /// The URL scheme for deep-linking into the app.
    public let urlScheme: String
    /// The default HTTP automation port (development/debug channel).
    public let httpPort: UInt16
    /// Human-readable display name.
    public let displayName: String

    public init(
        id: SiblingApp,
        bundleID: String,
        urlScheme: String,
        httpPort: UInt16,
        displayName: String
    ) {
        self.id = id
        self.bundleID = bundleID
        self.urlScheme = urlScheme
        self.httpPort = httpPort
        self.displayName = displayName
    }
}

/// Enumerates all apps in the Impress research suite.
public enum SiblingApp: String, CaseIterable, Sendable, Codable {
    case imbib
    case imprint
    case implore
    case impel
    case impart

    // MARK: - The Table

    /// THE sibling-app table. Bundle IDs and ports are declared here once;
    /// every accessor below is a lookup into this array.
    ///
    /// Bundle IDs are verified against each app's `PRODUCT_BUNDLE_IDENTIFIER`
    /// in `apps/*/project.yml` (note the two prefixes: imbib/implore/impel use
    /// `com.impress.`, imprint/impart use the older `com.imbib.`). URL schemes
    /// are verified against `CFBundleURLSchemes`.
    public static let descriptors: [SiblingAppDescriptor] = [
        SiblingAppDescriptor(
            id: .imbib,
            bundleID: "com.impress.imbib",
            urlScheme: "imbib",
            httpPort: 23120,
            displayName: "imbib"
        ),
        SiblingAppDescriptor(
            id: .imprint,
            bundleID: "com.imbib.imprint",
            urlScheme: "imprint",
            httpPort: 23121,
            displayName: "imprint"
        ),
        SiblingAppDescriptor(
            id: .implore,
            bundleID: "com.impress.implore",
            urlScheme: "implore",
            httpPort: 23123,
            displayName: "implore"
        ),
        SiblingAppDescriptor(
            id: .impel,
            bundleID: "com.impress.impel",
            urlScheme: "impel",
            httpPort: 23124,
            displayName: "impel"
        ),
        SiblingAppDescriptor(
            id: .impart,
            bundleID: "com.imbib.impart",
            urlScheme: "impart",
            httpPort: 23122,
            displayName: "impart"
        ),
    ]

    private static let byID: [SiblingApp: SiblingAppDescriptor] =
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

    /// This app's row in `descriptors`.
    public var descriptor: SiblingAppDescriptor {
        guard let row = Self.byID[self] else {
            // Unreachable: `descriptorTableCoversEveryApp` in ImpressKitTests
            // fails if a case is added without a descriptor row.
            preconditionFailure("SiblingApp.descriptors has no row for \(rawValue)")
        }
        return row
    }

    // MARK: - Accessors (unchanged public API — now table lookups)

    /// The macOS bundle identifier for this app.
    public var bundleID: String { descriptor.bundleID }

    /// The URL scheme for deep-linking into this app.
    public var urlScheme: String { descriptor.urlScheme }

    /// The default HTTP automation port for this app (development/debug channel).
    ///
    /// - Warning: implore's and impel's *own* HTTP servers both currently bind
    ///   23124 (`apps/implore/.../HTTPAutomationServer.swift` and
    ///   `apps/impel/Shared/Services/ImpelHTTPServer.swift`), and
    ///   `ImpressCommandPalette.AppEndpoint` transposes the two relative to this
    ///   table. This table preserves its historical values (implore 23123,
    ///   impel 23124); reconciling the collision is a behavioural change for
    ///   those apps, not a table move.
    public var httpPort: UInt16 { descriptor.httpPort }

    /// Human-readable display name.
    public var displayName: String { descriptor.displayName }

    // MARK: - Reverse Lookups

    /// The app owning a bundle identifier, if any.
    public static func app(forBundleID bundleID: String) -> SiblingApp? {
        descriptors.first { $0.bundleID == bundleID }?.id
    }

    /// The app owning a URL scheme, if any.
    public static func app(forURLScheme scheme: String) -> SiblingApp? {
        descriptors.first { $0.urlScheme == scheme }?.id
    }

    /// The app owning an HTTP automation port, if any.
    public static func app(forHTTPPort port: UInt16) -> SiblingApp? {
        descriptors.first { $0.httpPort == port }?.id
    }
}
