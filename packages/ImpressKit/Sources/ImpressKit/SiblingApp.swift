import Foundation

/// One row of the sibling-app table: everything the suite needs in order to
/// address another app — its bundle identifier, deep-link scheme and local
/// HTTP automation port.
///
/// This is the `AppShellConfiguration` pattern one level down: adding an app to
/// the suite means adding a descriptor row, not editing N parallel `switch`
/// statements that drift the moment one of them is updated alone. (They did
/// drift, twice, and both are now fixed — see the note on `httpPort`.)
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
    /// The SF Symbol that stands for this app wherever the suite has to draw
    /// one app among several.
    ///
    /// Added when impress's sidebar became a COMPOSITION of the five sibling
    /// presets (`SidebarComposition`): each group's title and glyph had to come
    /// from somewhere, and the two candidates were this table or a sixth
    /// `switch` in the chassis. The table wins for the reason the whole type
    /// exists — a seventh app is a row here, not an edit in N files. Each
    /// symbol is the one the app's own primary section already uses, so the
    /// group header and the section beneath it agree:
    /// imbib/`books.vertical` = `.libraries`, imprint/`doc.text.image` =
    /// `.manuscripts`, implore/`photo.on.rectangle.angled` = `.figures`,
    /// impel/`brain` = `.agents`, impart/`envelope` = `.mail`. impress owns no
    /// section, so it takes the shell glyph.
    public let systemImage: String

    public init(
        id: SiblingApp,
        bundleID: String,
        urlScheme: String,
        httpPort: UInt16,
        displayName: String,
        systemImage: String
    ) {
        self.id = id
        self.bundleID = bundleID
        self.urlScheme = urlScheme
        self.httpPort = httpPort
        self.displayName = displayName
        self.systemImage = systemImage
    }
}

/// Enumerates all apps in the Impress research suite.
public enum SiblingApp: String, CaseIterable, Sendable, Codable {
    case imbib
    case imprint
    case implore
    case impel
    case impart
    /// The unifying shell (ADR-0022 D9), shipped 2026-07-30. It is a sibling
    /// like any other: it has a bundle id, a scheme and a port, and the other
    /// five discover it through this table exactly as they discover each other.
    case impress

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
            displayName: "imbib",
            systemImage: "books.vertical"
        ),
        SiblingAppDescriptor(
            id: .imprint,
            bundleID: "com.imbib.imprint",
            urlScheme: "imprint",
            httpPort: 23121,
            displayName: "imprint",
            systemImage: "doc.text.image"
        ),
        SiblingAppDescriptor(
            id: .implore,
            bundleID: "com.impress.implore",
            urlScheme: "implore",
            httpPort: 23123,
            displayName: "implore",
            systemImage: "photo.on.rectangle.angled"
        ),
        SiblingAppDescriptor(
            id: .impel,
            bundleID: "com.impress.impel",
            urlScheme: "impel",
            httpPort: 23124,
            displayName: "impel",
            systemImage: "brain"
        ),
        SiblingAppDescriptor(
            id: .impart,
            bundleID: "com.imbib.impart",
            urlScheme: "impart",
            httpPort: 23122,
            displayName: "impart",
            systemImage: "envelope"
        ),
        SiblingAppDescriptor(
            id: .impress,
            bundleID: "com.impress.impress",
            urlScheme: "impress",
            // 23125 — the next free address after impel's 23124. Assigned by
            // this table before the server existed, which is the rule: servers
            // align TO the table.
            httpPort: 23125,
            displayName: "impress",
            systemImage: "square.grid.2x2"
        ),
    ]

    // MARK: - Suite services (not apps)

    /// Ports of suite SERVICES — daemons with no bundle to launch and no URL
    /// scheme, so they are not `SiblingApp` cases, but their addresses belong
    /// in this file for the same reason the app ports do: one authoritative
    /// table, servers align TO it.
    public enum Services {
        /// impress-ai-server (the ImpartServices.app helper): local-model
        /// conversations over the shared item graph, browser pairing, and the
        /// store-maintenance cadence (WAL checkpoints, op compaction).
        /// `/api/health` and `/api/pair` are unauthenticated; everything else
        /// requires the keychain bearer (`com.impress.ai-http`).
        public static let impressAIPort: UInt16 = 8787
    }

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
    /// This is THE published address. **Servers align to this table; the table
    /// does not move to match a server.** The reasoning: siblings dial
    /// `SiblingApp.<app>.httpPort`, so whatever this table says is what the rest
    /// of the suite believes, and a server that binds anything else is simply
    /// unreachable.
    ///
    /// Resolved 2026-07-30 (hardening C3). Previously implore's and impel's own
    /// servers BOTH bound 23124 — whichever app launched first won the socket
    /// and the other's automation API silently never came up — while
    /// `ImpressCommandPalette.AppEndpoint` transposed the pair, so the palette
    /// asked each of the two for the other's commands. Both were fixed toward
    /// this table (implore's server 23124 → 23123; the palette now *derives*
    /// its endpoints from `descriptors` instead of copying them), and every
    /// binding site in the five apps is now a lookup here rather than a
    /// literal. Two further live bugs fell out of the same sweep:
    /// `MessageManagerCore.ArtifactResolver` was dialling 23121 for imbib and
    /// 23123 for imprint, and `ImpelCore.ImpelClient.defaultPort` was 23123.
    ///
    /// - Note: implore's automation port MOVED as part of this. See the
    ///   user-facing note in `docs/chassis-capability-matrix.md`.
    public var httpPort: UInt16 { descriptor.httpPort }

    /// Human-readable display name.
    public var displayName: String { descriptor.displayName }

    /// The SF Symbol that stands for this app.
    public var systemImage: String { descriptor.systemImage }

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
