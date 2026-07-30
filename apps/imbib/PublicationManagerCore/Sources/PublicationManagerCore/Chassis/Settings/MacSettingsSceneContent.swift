#if os(macOS)
// Chassis file — macOS-only: the TABBED renderer, and only the renderer. The
// declaration it renders (`AppSettingsConfiguration`), the descriptor and the
// registry are cross-platform; this is the `RecordSidebarView.swift` shape
// (data shared, one renderer per platform).
//
//  MacSettingsSceneContent.swift
//  PublicationManagerCore
//
//  Stage 6 phase 1. Replaces the hand-written `TabView` body that each app's
//  `SettingsView` was: 13 near-identical `.tabItem { Label(...) }` +
//  `.accessibilityIdentifier(...)` stanzas per app, which is 13 chances to
//  mis-order a tab, forget an identifier, or let macOS and iOS disagree about
//  what the app's preferences ARE.
//
//  Frame only. Every control inside a pane is the pane's own, unchanged — the
//  reframe must be invisible.
//

import SwiftUI

/// The content of a macOS `Settings` scene, rendered from a declaration.
///
/// ```swift
/// Settings {
///     MacSettingsSceneContent(configuration: .imprint)
///         .environment(\.settingsSectionRegistry, ImprintSettingsSections.registry)
/// }
/// ```
public struct MacSettingsSceneContent: View {

    private let configuration: AppSettingsConfiguration
    private let minWidth: CGFloat
    private let idealWidth: CGFloat
    private let maxWidth: CGFloat?
    private let minHeight: CGFloat
    private let idealHeight: CGFloat
    private let maxHeight: CGFloat?
    private let containerIdentifier: String

    @Environment(\.settingsSectionRegistry) private var registry

    /// Defaults are imprint's shipped Settings-window metrics, so adopting
    /// this renderer does not resize anybody's window.
    ///
    /// `maxWidth` / `maxHeight` / `containerIdentifier` are Stage 6 phase-2
    /// additions with imprint's behaviour as the default (`nil` max = resizable,
    /// `settings.container`). They exist because imprint's Settings window is
    /// resizable and implore's, impel's and impart's are NOT — all three shipped
    /// a `.frame(width:height:)`, which is a fixed frame rather than a floor.
    /// Adopting the renderer with min/ideal only would have made three
    /// previously fixed windows resizable, which is a visible change to a
    /// surface the migration promises not to change.
    public init(
        configuration: AppSettingsConfiguration,
        minWidth: CGFloat = 700,
        idealWidth: CGFloat = 800,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat = 450,
        idealHeight: CGFloat = 550,
        maxHeight: CGFloat? = nil,
        containerIdentifier: String = "settings.container"
    ) {
        self.configuration = configuration
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.maxHeight = maxHeight
        self.containerIdentifier = containerIdentifier
    }

    /// A window pinned to one size — the implore / impel / impart shape.
    public static func fixed(
        configuration: AppSettingsConfiguration,
        width: CGFloat,
        height: CGFloat,
        containerIdentifier: String = "settings.container"
    ) -> MacSettingsSceneContent {
        MacSettingsSceneContent(
            configuration: configuration,
            minWidth: width, idealWidth: width, maxWidth: width,
            minHeight: height, idealHeight: height, maxHeight: height,
            containerIdentifier: containerIdentifier)
    }

    /// Tabs, in declared order, filtered by availability.
    private var sections: [SettingsSectionDescriptor] {
        configuration.sections(on: .macOS)
    }

    public var body: some View {
        TabView {
            ForEach(sections) { descriptor in
                pane(for: descriptor)
                    .tabItem {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                    }
                    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
            }
        }
        .frame(
            minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
            minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
        // Frozen per app: imprint's UI tests and `SettingsPage` address the
        // window by `settings.container`, which is also implore's shipped value.
        .accessibilityIdentifier(containerIdentifier)
    }

    @ViewBuilder
    private func pane(for descriptor: SettingsSectionDescriptor) -> some View {
        if let factory = registry[descriptor.id] {
            factory.makeContent(
                SettingsSectionContext(presentation: .macTab, descriptor: descriptor))
        } else {
            // An unregistered section is a WIRING bug (a preset naming a pane
            // nobody builds), so say so in the UI rather than showing a blank
            // tab that reads as "this pane has no settings".
            // `SettingsSectionRegistry.unresolvedSections` is the test-time
            // form of this check; the label is the runtime one.
            SettingsForm {
                Section(descriptor.title) {
                    Label(
                        "No content is registered for “\(descriptor.id.rawValue)”.",
                        systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                }
            }
        }
    }
}
#endif
