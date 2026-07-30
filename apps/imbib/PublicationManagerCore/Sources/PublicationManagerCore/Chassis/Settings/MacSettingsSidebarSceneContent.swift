#if os(macOS)
// Chassis file — macOS-only: the SECOND macOS renderer, and only a renderer.
// Same declaration (`AppSettingsConfiguration`), same descriptors, same
// registry, same factories as `MacSettingsSceneContent` — a different LAYOUT.
// This is `RecordSidebarView` vs. the list renderers all over again: the data is
// shared, and how many renderers read it is a question about surfaces, not about
// the data.
//
//  MacSettingsSidebarSceneContent.swift
//  PublicationManagerCore
//
//  Stage 6 phase 2. Phase 1 shipped ONE macOS renderer because imprint has one
//  macOS settings idiom: a 13-tab `TabView`. imbib does not. imbib's Settings
//  scene is a `NavigationSplitView` whose sidebar `List` groups SIXTEEN panes
//  under six `Section` headers, and that is not a stylistic difference — past
//  roughly eight panes a macOS `TabView` overflows into an unusable strip of
//  icons, which is precisely why imbib was authored this way and why AppKit's own
//  many-pane surfaces (Mail, Xcode, System Settings) all use a source list.
//
//  The migration's hard constraint is that imbib's macOS Settings scene stays
//  VISUALLY EQUIVALENT — same panes, same order, same group headers, same
//  controls. Rendering imbib through the tab renderer would have been a redesign.
//  Rendering it through a hand-written `NavigationSplitView` in the app would
//  have left the pane list undeclared, which is the whole disease phase 1 cured.
//  So the layout becomes the second renderer, and imbib's sixteen panes become
//  sixteen descriptors that iOS can also read.
//
//  WHY NOT A `style:` FLAG ON `MacSettingsSceneContent`: the two layouts share no
//  body. One is `TabView` + `.tabItem`; this is a split view with a selection
//  binding, a source list, group headers and a detail column. A flag would be a
//  file whose body is two disjoint `if` branches, and it would put every imbib
//  layout change inside the file imprint's shipped Settings window renders from.
//  Two small renderers over one declaration is the shape the chassis already uses
//  across platforms; using it across LAYOUTS costs nothing new.
//

import SwiftUI

/// The content of a macOS `Settings` scene rendered as a grouped source list
/// plus a detail column — the many-pane macOS idiom.
///
/// ```swift
/// Settings {
///     MacSettingsSidebarSceneContent(
///         configuration: .imbib,
///         selection: $selectedSection,
///         containerIdentifier: AccessibilityID.Settings.tabView)
///         .environment(\.settingsSectionRegistry, ImbibSettingsSections.registry)
/// }
/// ```
public struct MacSettingsSidebarSceneContent: View {

    private let configuration: AppSettingsConfiguration
    /// Host-owned selection, for surfaces that deep-link to a pane. nil ⇒ the
    /// renderer keeps its own.
    private let externalSelection: Binding<SettingsSectionID?>?
    private let containerIdentifier: String

    private let sidebarMinWidth: CGFloat
    private let sidebarIdealWidth: CGFloat
    private let sidebarMaxWidth: CGFloat

    private let minWidth: CGFloat
    private let idealWidth: CGFloat
    private let maxWidth: CGFloat?
    private let minHeight: CGFloat
    private let idealHeight: CGFloat
    private let maxHeight: CGFloat?

    @Environment(\.settingsSectionRegistry) private var registry

    /// Fallback selection when the host does not own one. `@State` on the
    /// renderer rather than a required binding, so a simple adopter needs no
    /// state of its own — but a host that deep-links (imbib routes
    /// `.showInboxSettings` / `.showExplorationSettings` at its Settings window)
    /// passes `selection:` and drives it.
    @State private var internalSelection: SettingsSectionID?

    /// Defaults are imbib's shipped Settings-window metrics, so adopting this
    /// renderer does not resize anybody's window.
    public init(
        configuration: AppSettingsConfiguration,
        selection: Binding<SettingsSectionID?>? = nil,
        containerIdentifier: String = "settings.container",
        sidebarMinWidth: CGFloat = 180,
        sidebarIdealWidth: CGFloat = 200,
        sidebarMaxWidth: CGFloat = 250,
        minWidth: CGFloat = 700,
        idealWidth: CGFloat = 850,
        maxWidth: CGFloat? = 1200,
        minHeight: CGFloat = 500,
        idealHeight: CGFloat = 650,
        maxHeight: CGFloat? = 900
    ) {
        self.configuration = configuration
        self.externalSelection = selection
        self.containerIdentifier = containerIdentifier
        self.sidebarMinWidth = sidebarMinWidth
        self.sidebarIdealWidth = sidebarIdealWidth
        self.sidebarMaxWidth = sidebarMaxWidth
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.maxHeight = maxHeight
        self._internalSelection = State(
            initialValue: configuration.defaultSection
                ?? configuration.sections(on: .macOS).first?.id)
    }

    // MARK: - Derived

    private var bands: [AppSettingsConfiguration.SectionGroup] {
        configuration.sectionGroups(on: .macOS)
    }

    private var selection: Binding<SettingsSectionID?> {
        externalSelection ?? $internalSelection
    }

    /// The descriptor the detail column shows. Falls back to the default (then
    /// the first available) section rather than showing nothing, because a
    /// `Settings` window opening on an empty right-hand pane reads as a bug.
    private var selectedDescriptor: SettingsSectionDescriptor? {
        let available = configuration.sections(on: .macOS)
        if let id = selection.wrappedValue, let match = available.first(where: { $0.id == id }) {
            return match
        }
        if let fallback = configuration.defaultSection,
           let match = available.first(where: { $0.id == fallback }) {
            return match
        }
        return available.first
    }

    // MARK: - Body

    public var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(bands) { band in
                    if let title = band.title {
                        Section(title) { rows(of: band) }
                    } else {
                        Section { rows(of: band) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: sidebarMinWidth, ideal: sidebarIdealWidth, max: sidebarMaxWidth)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Frozen per app: imbib's UI tests address its Settings window by
        // `settings.tabView`, a string that shipped before this renderer existed
        // and is not free to "modernise" (see `SettingsSectionID`).
        .accessibilityIdentifier(containerIdentifier)
        .frame(
            minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
            minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
    }

    @ViewBuilder
    private func rows(of band: AppSettingsConfiguration.SectionGroup) -> some View {
        ForEach(band.sections) { descriptor in
            Label(descriptor.title, systemImage: descriptor.systemImage)
                .tag(descriptor.id)
                // `subtitle` is the row's tooltip here. The tab renderer has no
                // room for it and the iOS list shows it as caption text — one
                // string, three honest presentations, which is what kept imbib's
                // per-tab `helpText` from being deleted in the reframe.
                .help(descriptor.subtitle ?? descriptor.title)
                .accessibilityIdentifier(descriptor.accessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let descriptor = selectedDescriptor {
            pane(for: descriptor)
                // `settings.pane.<id>`, the identifier `IOSSettingsScreen`
                // already puts on a pushed pane. The ROW carries
                // `settings.tabs.<id>`, so a test clicks the row and asserts on
                // the pane without one query matching two elements.
                .accessibilityIdentifier("settings.pane.\(descriptor.id.rawValue)")
        } else {
            // A preset with no macOS-available section at all. Structurally
            // possible, and silently blank would be worse than said out loud.
            ContentUnavailableView(
                "No Settings",
                systemImage: "gearshape",
                description: Text("This app declares no settings for macOS."))
        }
    }

    @ViewBuilder
    private func pane(for descriptor: SettingsSectionDescriptor) -> some View {
        if let factory = registry[descriptor.id] {
            factory.makeContent(
                SettingsSectionContext(presentation: .macTab, descriptor: descriptor))
        } else {
            // An unregistered section is a WIRING bug (a preset naming a pane
            // nobody builds) — the same runtime complaint the tab renderer
            // makes, whose test-time form is `unresolvedSections`.
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
