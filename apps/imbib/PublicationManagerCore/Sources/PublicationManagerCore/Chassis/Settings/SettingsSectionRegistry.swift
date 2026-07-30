// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the registry, the
// factory value type and the environment key are pure data over SwiftUI
// `AnyView` closures. This is `RecordViewerRegistry` one level over: a viewer
// is a record kind's section, a settings factory is a preferences pane.
//
// iOS had no settings registry — indeed no settings — while panes lived inside
// a macOS `TabView` body, so a pane could not even be NAMED there. Naming is
// most of what this file buys.
//
//  SettingsSectionRegistry.swift
//  PublicationManagerCore
//
//  Factories live HERE, never on `SettingsSectionDescriptor`: descriptors stay
//  Sendable DATA (ADR-0021 D3). This file is the one place in Chassis/Settings/
//  that knows views exist.
//
//  What is deliberately NOT registered as a builtin: everything imprint-shaped.
//  A LaTeX distribution browser, an AI-task list, an imbib bridge and a
//  template picker are app content, and the chassis linking `TeXDistributionManager`
//  would be the CustomSurface mistake ("the views live in APP TARGETS"). Those
//  register from imprint's own code — `ImprintSettingsSections` — and the
//  absence of app-specific builtins here is asserted by
//  `SettingsSectionRegistryTests.testBuiltinRegistryCarriesOnlyGenericChrome`.
//

import Foundation
import SwiftUI
import ImpressSpotlight
import ImpressTheme

// MARK: - Content context

/// What a settings factory is handed when it builds its pane.
///
/// Thin on purpose. Settings panes read their own stores (`@AppStorage`,
/// `@Observable` singletons) — the same stores they read before this refactor,
/// which is what keeps every persistence key untouched. The context carries
/// the RENDERING situation, because one pane body has to look right as a macOS
/// tab (a padded `Form`, its own scroll view) and as an iOS pushed screen (a
/// `Form` inside the navigation stack, no padding, a title in the bar).
public struct SettingsSectionContext: Sendable {

    /// How the pane is being presented.
    public enum Presentation: String, Sendable, Hashable {
        /// macOS: one tab of a `TabView` in the Settings scene.
        case macTab
        /// iOS: a screen pushed onto the settings `NavigationStack`.
        case iOSPushedScreen
    }

    public let presentation: Presentation
    /// The descriptor being rendered — so a factory can reuse its title
    /// instead of repeating the string.
    public let descriptor: SettingsSectionDescriptor

    public init(presentation: Presentation, descriptor: SettingsSectionDescriptor) {
        self.presentation = presentation
        self.descriptor = descriptor
    }
}

// MARK: - Factory

/// The view one settings section contributes.
public struct SettingsSectionFactory: Identifiable, Sendable {
    public var id: SettingsSectionID { section }
    public let section: SettingsSectionID
    /// The pane's content. Renderers supply the chrome (tab item, nav title);
    /// the factory supplies the `Form`.
    public let makeContent: @MainActor @Sendable (SettingsSectionContext) -> AnyView

    public init(
        section: SettingsSectionID,
        makeContent: @escaping @MainActor @Sendable (SettingsSectionContext) -> AnyView
    ) {
        self.section = section
        self.makeContent = makeContent
    }

    /// Convenience for the common case: a pane that ignores the context.
    public init<Content: View>(
        section: SettingsSectionID,
        @ViewBuilder content: @escaping @MainActor @Sendable () -> Content
    ) {
        self.init(section: section, makeContent: { _ in AnyView(content()) })
    }
}

// MARK: - Registry

/// Runtime registry of settings-pane factories, injected through the
/// environment (the `RecordViewerRegistry` / `CustomSurfaceRegistry` shape).
///
/// Registration happens at app boot or at construction; the lock lets the type
/// be a plain `Sendable` environment value without pinning it to the main
/// actor.
public final class SettingsSectionRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var factories: [SettingsSectionID: SettingsSectionFactory]

    public init(_ factories: [SettingsSectionFactory] = []) {
        self.factories = Dictionary(
            factories.map { ($0.section, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Register (or REPLACE) the factory for a section.
    ///
    /// Replacement is a feature, and imprint uses it: the chassis ships a
    /// generic `automation` pane, imprint's has an MCP-config block and drives
    /// `ImprintHTTPServer`, so imprint registers over the builtin rather than
    /// the chassis growing an app flag. Last registration wins, and app
    /// registrations are applied after builtins (`composing(_:)`).
    public func register(_ factory: SettingsSectionFactory) {
        lock.withLock { factories[factory.section] = factory }
    }

    /// Lookup by section; nil when nothing is registered.
    public subscript(section: SettingsSectionID) -> SettingsSectionFactory? {
        lock.withLock { factories[section] }
    }

    public var registeredSections: Set<SettingsSectionID> {
        lock.withLock { Set(factories.keys) }
    }

    /// A NEW registry: these factories layered over the receiver's.
    ///
    /// Returns a copy rather than mutating, so `SettingsSectionRegistry.builtin`
    /// (a shared `static let`) is never scribbled on by one app's registration —
    /// the bug that a mutating `register` on a global would ship the day a
    /// second app adopted this.
    public func composing(_ additional: [SettingsSectionFactory]) -> SettingsSectionRegistry {
        let existing = lock.withLock { Array(factories.values) }
        return SettingsSectionRegistry(existing + additional)
    }

    /// Whether every section a configuration declares can actually be built on
    /// `platform`. What a parity test asks, and what a renderer would
    /// otherwise discover as a blank tab.
    public func unresolvedSections(
        of configuration: AppSettingsConfiguration,
        on platform: SettingsPlatform,
        capabilities: Set<SettingsRequirement>? = nil
    ) -> [SettingsSectionID] {
        configuration
            .sections(on: platform, capabilities: capabilities)
            .map(\.id)
            .filter { self[$0] == nil }
    }

    // MARK: Builtin

    /// The GENERIC chrome the chassis ships a pane for.
    ///
    /// Two sections, and the bar for a third is high: a builtin has to be
    /// something no app should author (or fork) for itself. Appearance is the
    /// canonical case — every impress app had its own segmented System/Light/
    /// Dark picker over the same `appearanceMode` key. Spotlight is the second:
    /// `SpotlightSettingsSection` was ALREADY shared as a component, and every
    /// adopter wrapped it in the identical `Form`, so the wrapper is the thing
    /// worth sharing.
    ///
    /// Note what is NOT here and why the `RecordViewerRegistry+Builtin.swift`
    /// gated-split was NOT needed: both factories build plain SwiftUI over
    /// packages PMC already links on both platforms (ImpressTheme,
    /// ImpressSpotlight). Nothing AppKit-adjacent reached the builtin tier, so
    /// there is nothing to split out. Where a section IS platform-bound the
    /// mechanism is the descriptor's `availability` — data, testable from
    /// either platform — not an `#if` that makes the section unnameable.
    public static let builtin = SettingsSectionRegistry([
        SettingsSectionFactory(section: .appearance) {
            AppearanceSettingsPane()
        },
        SettingsSectionFactory(section: .spotlight) {
            SpotlightSettingsPane()
        },
    ])
}

// MARK: - Builtin panes

/// The shared appearance pane.
///
/// Reads `appearanceMode` — the SAME key imprint's `AppearanceSettingsView`
/// used, with the same three rawValues, because `AppearanceMode` is
/// `String`-backed as `system`/`light`/`dark`. A user's stored preference
/// survives this refactor untouched; that is the whole point of reusing the
/// key rather than "modernising" it.
struct AppearanceSettingsPane: View {
    /// FULLY QUALIFIED on purpose. PMC declares its OWN `AppearanceMode`
    /// (`Theme/ThemeSettings.swift`) with the identical three `String` cases —
    /// two enums, one key, one meaning. The shared component takes
    /// ImpressTheme's, so an unqualified `AppearanceMode` here resolves to the
    /// PMC one and fails to compile; it would be worse if the two ever differed
    /// in rawValue, which is exactly why this reads the shared one. (Merging
    /// them is a phase-2 cleanup: PMC's copy has non-appearance callers.)
    @AppStorage("appearanceMode") private var mode: ImpressTheme.AppearanceMode = .system

    var body: some View {
        SettingsForm {
            Section("Color Scheme") {
                // The shared component (ImpressTheme) — a section COMPONENT,
                // which is content; the Form around it is frame, and that is
                // what this file contributes.
                AppearanceSettingsSection(mode: $mode)

                Text("Choose whether to follow system appearance or always use light/dark mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The shared Spotlight pane — `SpotlightSettingsSection` plus the `Form` every
/// adopter was writing around it.
struct SpotlightSettingsPane: View {
    var body: some View {
        SettingsForm {
            SpotlightSettingsSection()
        }
    }
}

// MARK: - Shared pane chrome

/// The `Form` wrapper every settings pane wants, with the ONE platform
/// difference the panes should not each re-encode: macOS grouped forms in a
/// Settings tab carry an outer `.padding()`, iOS pushed screens must not (the
/// navigation stack already insets, and padding a grouped `List` on iOS puts a
/// visible gutter down both sides).
///
/// Cross-platform by `#if` ISLAND, not by gating the file: both branches are
/// two lines and keeping them adjacent is what stops them diverging.
public struct SettingsForm<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .padding()
        #else
        Form { content }
        #endif
    }
}

// MARK: - Environment

private struct SettingsSectionRegistryKey: EnvironmentKey {
    static let defaultValue = SettingsSectionRegistry.builtin
}

public extension EnvironmentValues {
    var settingsSectionRegistry: SettingsSectionRegistry {
        get { self[SettingsSectionRegistryKey.self] }
        set { self[SettingsSectionRegistryKey.self] = newValue }
    }
}
