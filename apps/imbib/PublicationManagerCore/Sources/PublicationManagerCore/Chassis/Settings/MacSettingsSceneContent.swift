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
    /// `settings.container`). They were added because implore's, impel's and
    /// impart's windows shipped pinned (`.frame(width:height:)`) and the
    /// migration promised not to change that. Since 2026-09-06 all six apps
    /// use resizable windows (`resizable(configuration:width:height:)`), and
    /// `fixed` remains only for source compatibility.
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

    /// A resizable window that opens at `width` × `height` and treats that
    /// size as its floor. Every app's Settings window is resizable since
    /// 2026-09-06: panes that grew with the suite-wide AI settings (a
    /// provider's full model list, task categories) need the room, and a
    /// pinned frame hid rows behind the window edge instead of scrolling.
    public static func resizable(
        configuration: AppSettingsConfiguration,
        width: CGFloat,
        height: CGFloat,
        containerIdentifier: String = "settings.container"
    ) -> MacSettingsSceneContent {
        MacSettingsSceneContent(
            configuration: configuration,
            minWidth: width, idealWidth: width, maxWidth: nil,
            minHeight: height, idealHeight: height, maxHeight: nil,
            containerIdentifier: containerIdentifier)
    }

    /// A window pinned to one size — the shape implore, impel and impart
    /// shipped before their windows became resizable. Kept so out-of-tree
    /// adopters compile; new code uses `resizable`.
    @available(*, deprecated, message: "Settings windows are resizable suite-wide; use resizable(configuration:width:height:)")
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
