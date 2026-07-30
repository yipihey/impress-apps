// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a settings section
// declared as DATA. No closures, no views, no AppKit — the factory that builds
// the pane lives in `SettingsSectionRegistry`, exactly as `RecordViewerFactory`
// keeps view builders off `RecordKindDescriptor` (ADR-0021 D3).
//
//  SettingsSectionDescriptor.swift
//  PublicationManagerCore
//
//  Stage 6 phase 1 of the declarative chassis: settings stop being authored
//  per app AND per platform. Before this file the suite had ~7.9k lines of
//  settings UI with zero shared frame — and imprint-iOS had NO settings at
//  all, because "which panes does this app have, in what order" existed only
//  as the literal body of a macOS `TabView`. A platform that could not run
//  that `TabView` could not even NAME the panes.
//
//  So the answer is a declaration. A descriptor says WHAT a section is (id,
//  title, symbol, where it can appear, where it sorts); a registry says HOW to
//  build it; two renderers (macOS tabs, iOS grouped list) read the same
//  declaration. Adding a pane is one descriptor + one factory, and it appears
//  on every platform whose availability rules it satisfies — instead of once
//  per platform, by hand, with the drift that implies.
//

import Foundation

// MARK: - Section id

/// Stable identity of a settings section.
///
/// String-backed for the ADR-0021 D3 reason: sections are ADDITIVE (an app
/// grows a pane without the chassis growing an enum case), and the trade —
/// exhaustiveness moves from the compiler to tests — is paid by
/// `SettingsSectionRegistryTests` asserting every preset's descriptors resolve
/// to a registered factory.
///
/// The rawValue is also the accessibility-identifier suffix
/// (`settings.tabs.<rawValue>`), so it is NOT free to rename: imprint's UI
/// tests and page objects address panes by those strings.
public struct SettingsSectionID: RawRepresentable, Hashable, Sendable, Codable,
                                 ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// The accessibility identifier the renderers attach to this section's
    /// tab / row. Frozen: imprint shipped `settings.tabs.<id>` and its UI
    /// tests address panes by it, on both platforms (an iOS row is still
    /// "the same tab" to a test).
    public var accessibilityIdentifier: String { "settings.tabs.\(rawValue)" }
}

// MARK: - Availability

/// A platform a settings section can render on.
///
/// Deliberately NOT `#if`-derived: availability is DATA that both platforms
/// can read and tests can assert about. A macOS test must be able to ask
/// "what does imprint's iOS settings screen contain" without being iOS.
public enum SettingsPlatform: String, Hashable, Sendable, Codable, CaseIterable {
    case macOS
    case iOS

    /// The platform this binary is running on.
    public static var current: SettingsPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}

/// A capability a settings section needs before it is worth showing.
///
/// These are the reasons a pane is absent that are NOT "wrong platform" — the
/// imprint survey turned up four, and each one had previously been encoded as
/// a pane that simply did not exist in the other platform's settings body.
public enum SettingsRequirement: String, Hashable, Sendable, Codable, CaseIterable {
    /// An in-process HTTP automation server. Needs the
    /// `com.apple.security.network.server` entitlement, which iOS does not
    /// grant — imprint-iOS runs no HTTP server at all (see
    /// `IOSManuscriptLibraryView.handleIncomingURL`, which is why the on-device
    /// surface is driven by a URL instead).
    case httpAutomation

    /// Spawning external processes / reading a system-wide toolchain: TeX
    /// distributions, `latexmk`, the impress-toolbox server, `git`. Sandboxed
    /// iOS has no such surface.
    case localToolchain

    /// Locating and talking to another impress app on the same machine
    /// (`ImbibIntegrationService.openImbib()`, NSWorkspace URL probing). iOS
    /// has cross-app URL schemes but no installed-app discovery, so a pane
    /// whose whole content is "is imbib installed, here is its path" is honest
    /// only on the Mac.
    case siblingAppDiscovery

    /// A Spotlight (CoreSpotlight) index coordinator installed by the host.
    /// imprint installs one from its macOS app delegate only.
    case spotlightIndex
}

/// Where a section may appear, and what it needs in order to be useful.
///
/// The chassis rule this encodes is `RecordTriageNewTagPrompt`'s: **omit the
/// affordance rather than showing a dead one.** A LaTeX pane on iOS would be a
/// screen full of "Not found" — worse than no pane.
public struct SettingsSectionAvailability: Hashable, Sendable, Codable {

    /// Platforms whose renderers may show this section.
    public let platforms: Set<SettingsPlatform>

    /// Capabilities the host must have. A renderer resolves these through
    /// `SettingsHostCapabilities`, so a Mac that (say) has no toolchain can
    /// still be told to show the pane — the requirement is about the PLATFORM
    /// class, not a runtime probe. Runtime probes stay inside the pane, where
    /// they can say something useful ("Install MacTeX or TeX Live").
    public let requirements: Set<SettingsRequirement>

    public init(
        platforms: Set<SettingsPlatform> = Set(SettingsPlatform.allCases),
        requirements: Set<SettingsRequirement> = []
    ) {
        self.platforms = platforms
        self.requirements = requirements
    }

    /// Both platforms, no extra capability — the default for generic chrome.
    public static let everywhere = SettingsSectionAvailability()

    /// macOS only, for a stated reason.
    public static func macOSOnly(
        requiring requirements: Set<SettingsRequirement> = []
    ) -> SettingsSectionAvailability {
        SettingsSectionAvailability(platforms: [.macOS], requirements: requirements)
    }

    /// Whether a host on `platform` offering `capabilities` should show it.
    public func isSatisfied(
        on platform: SettingsPlatform,
        capabilities: Set<SettingsRequirement>
    ) -> Bool {
        platforms.contains(platform) && requirements.isSubset(of: capabilities)
    }
}

/// What a HOST platform can do — the other half of `isSatisfied`.
///
/// Derived from the platform rather than hand-passed, so a preset cannot claim
/// iOS runs an HTTP server. A host with an unusual configuration overrides it
/// explicitly (which is also how tests drive the filter both ways).
public enum SettingsHostCapabilities {
    /// Everything macOS grants imprint today: the network.server entitlement,
    /// process spawning, NSWorkspace app discovery, a Spotlight coordinator.
    public static let macOS: Set<SettingsRequirement> = Set(SettingsRequirement.allCases)

    /// What iOS grants: none of the four. Not a pessimistic default — each is
    /// a documented absence (see `SettingsRequirement`).
    public static let iOS: Set<SettingsRequirement> = []

    public static func `default`(for platform: SettingsPlatform) -> Set<SettingsRequirement> {
        switch platform {
        case .macOS: return macOS
        case .iOS: return iOS
        }
    }
}

// MARK: - Group

/// A named band of related sections in a settings surface.
///
/// Added in Stage 6 phase 2 for a reason phase 1 could not have found: imprint's
/// settings surface is a 13-tab `TabView`, and a `TabView` has no grouping to
/// declare. **imbib's is a `NavigationSplitView` whose sidebar `List` carries
/// SIX named `Section` headers over sixteen panes** ("General", "Content",
/// "Inbox & Feeds", "Sync & Backup", "Import & Export", "System"), and those
/// headers are the only thing making sixteen panes navigable. Sixteen tabs would
/// not be visually equivalent — it would be a redesign, which the migration
/// forbids — so the group had to become data alongside everything else, or the
/// declaration could not describe imbib's shipped surface at all.
///
/// String-backed and `nil`-by-default, so it is purely ADDITIVE: imprint's
/// preset declares no groups and renders exactly as before. The rawValue IS the
/// header text — there is no separate title, because a second representation of
/// one string is the drift `SettingsSectionID` already pays a test to prevent.
///
/// **Group ORDER is not declared**, deliberately. It is the order of each
/// group's first member under `descriptor.order`, so a group cannot sort
/// differently from the sections inside it — the same "two representations of
/// one truth" argument that made `order` authoritative. `SettingsSurfaceContract`
/// tests assert every rendered group's members are CONTIGUOUS, which is the one
/// way this derivation could surprise someone.
public struct SettingsSectionGroup: RawRepresentable, Hashable, Sendable, Codable,
                                    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// The sidebar `Section` header text.
    public var title: String { rawValue }
    public var description: String { rawValue }
}

// MARK: - Descriptor

/// One settings section, as data.
///
/// Sendable, `Hashable`, no closures — the ADR-0021 D3 discipline. A renderer
/// gets the pane's CONTENT from `SettingsSectionRegistry`; everything the
/// chassis needs to lay out, order, label and filter a settings surface is
/// here.
public struct SettingsSectionDescriptor: Identifiable, Hashable, Sendable, Codable {

    public let id: SettingsSectionID

    /// Tab label on macOS, row label on iOS.
    public let title: String

    /// SF Symbol for the tab item / row icon.
    public let systemImage: String

    /// A one-line description. macOS tabs have no room for it; the iOS grouped
    /// list does, and a row that is only "LaTeX" is a worse row than one that
    /// says what it configures. nil renders nothing.
    public let subtitle: String?

    public let availability: SettingsSectionAvailability

    /// Sort key. Presets declare sections in display order AND give ascending
    /// `order` values; `AppSettingsConfiguration` sorts by `order` (stably, so
    /// ties keep declaration order) and
    /// `AppSettingsConfigurationTests.testPresetDeclarationOrderMatchesSortOrder`
    /// fails if the two ever disagree. Two representations of one truth is a
    /// drift risk; a test that pins them together is the cheap way to keep the
    /// ordering readable at the declaration site AND authoritative in data.
    public let order: Int

    /// The sidebar band this section belongs to, for renderers that group.
    ///
    /// nil ⇒ ungrouped, which is what a `TabView` surface wants and what every
    /// phase-1 descriptor is. Only `MacSettingsSidebarSceneContent` reads it;
    /// `MacSettingsSceneContent` and `IOSSettingsScreen` render one flat run of
    /// sections and ignore it, so declaring a group never changes their output.
    public let group: SettingsSectionGroup?

    public init(
        id: SettingsSectionID,
        title: String,
        systemImage: String,
        subtitle: String? = nil,
        availability: SettingsSectionAvailability = .everywhere,
        group: SettingsSectionGroup? = nil,
        order: Int
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.availability = availability
        self.group = group
        self.order = order
    }

    /// `settings.tabs.<id>` — see `SettingsSectionID.accessibilityIdentifier`.
    public var accessibilityIdentifier: String { id.accessibilityIdentifier }
}
