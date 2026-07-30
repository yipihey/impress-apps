#if os(iOS)
// Chassis file — iOS-only: the GROUPED-LIST renderer, and only the renderer.
// Its declaration (`AppSettingsConfiguration`), descriptor and registry are
// cross-platform; the `RecordSidebarView.swift` shape.
//
//  IOSSettingsScreen.swift
//  PublicationManagerCore
//
//  Stage 6 phase 1. This file is why the phase exists: imprint-iOS shipped NO
//  settings at all — a standing user report — not because the panes were
//  impossible on iOS but because "which panes does imprint have" lived inside
//  a macOS `TabView` body. Once that list is data, the iOS screen is a
//  renderer over it, and it cannot fall out of step with the Mac's.
//
//  iOS idiom, not a ported TabView: a grouped `List` of navigation rows, each
//  pushing the SAME factory content the macOS tab shows. The rows a platform
//  has no business showing are filtered by `availability` — see
//  `SettingsRequirement` for the four reasons — rather than pushed and left to
//  render a screen full of "Not found".
//

import SwiftUI

/// imprint-iOS's (and any iOS shell's) settings screen.
///
/// ```swift
/// .sheet(isPresented: $showSettings) {
///     IOSSettingsScreen(configuration: .imprint)
///         .environment(\.settingsSectionRegistry, ImprintSettingsSections.registry)
/// }
/// ```
public struct IOSSettingsScreen: View {

    private let configuration: AppSettingsConfiguration
    private let title: String
    /// Presented as a sheet ⇒ show a Done button. Pushed ⇒ don't.
    private let onDone: (() -> Void)?
    private let containerIdentifier: String
    private let doneIdentifier: String

    @Environment(\.settingsSectionRegistry) private var registry

    /// `containerIdentifier` / `doneIdentifier` are Stage 6 phase-2 additions with
    /// imprint's shipped values as defaults, so imprint is untouched.
    ///
    /// They exist because imprint-iOS had NO settings before phase 1 and so no
    /// identifiers to preserve, while **imbib-iOS shipped its settings sheet
    /// years earlier** with `settings.doneButton` — and `imbib-iOSUITests/Pages/
    /// IOSSettingsPage.swift` taps exactly that string. A renderer that renamed it
    /// would break a green test suite for cosmetic reasons, which is the same
    /// argument `SettingsSectionID.accessibilityIdentifier` already makes about
    /// `settings.tabs.<id>`: the identifier is a shipped API, not an
    /// implementation detail. Parameterising is cheaper than migrating every
    /// adopter's page objects to the chassis's spelling.
    public init(
        configuration: AppSettingsConfiguration,
        title: String = "Settings",
        containerIdentifier: String = "settings.container",
        doneIdentifier: String = "settings.done",
        onDone: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.title = title
        self.containerIdentifier = containerIdentifier
        self.doneIdentifier = doneIdentifier
        self.onDone = onDone
    }

    private var sections: [SettingsSectionDescriptor] {
        configuration.sections(on: .iOS)
    }

    /// Sections banded by `descriptor.group`, so an app with many panes reads as
    /// grouped rows rather than one long undifferentiated card.
    ///
    /// Phase 1 rendered a single `Section` because imprint's five iOS rows need no
    /// grouping and its preset declares none. imbib declares six groups (its macOS
    /// sidebar has always had them) and shows eleven rows on iOS — and imbib-iOS's
    /// hand-written screen ALSO grouped, under "Display", "Library", "Developer",
    /// "Help & Support", "About". Honouring `group` here is what lets one preset
    /// serve both surfaces without either losing its headings. An ungrouped preset
    /// still yields exactly one headerless band, i.e. phase 1's output unchanged.
    private var bands: [AppSettingsConfiguration.SectionGroup] {
        configuration.sectionGroups(on: .iOS)
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(bands) { band in
                    Section {
                        rows(of: band)
                    } header: {
                        // An empty header renders no header view, which is the
                        // ungrouped (phase-1 / imprint) case.
                        if let title = band.title { Text(title) }
                    }
                }

                // The footer hangs off its own trailing section rather than the
                // last band's: with grouping, "the last band" is whichever
                // capability filtering left standing, and a note about Mac-only
                // panes attached under "About" would read as being about About.
                Section {
                    EmptyView()
                } footer: {
                    macOnlyFooter
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier(doneIdentifier)
                    }
                }
            }
        }
        .accessibilityIdentifier(containerIdentifier)
    }

    @ViewBuilder
    private func rows(of band: AppSettingsConfiguration.SectionGroup) -> some View {
        ForEach(band.sections) { descriptor in
            NavigationLink {
                paneScreen(for: descriptor)
            } label: {
                row(for: descriptor)
            }
            // The SAME identifier the macOS tab carries: to a test, an iOS row
            // and a macOS tab are the same section.
            .accessibilityIdentifier(descriptor.accessibilityIdentifier)
        }
    }

    // MARK: - Row

    private func row(for descriptor: SettingsSectionDescriptor) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                if let subtitle = descriptor.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: descriptor.systemImage)
                .foregroundStyle(.tint)
        }
    }

    /// Honesty about the difference rather than a silent one. The user of a
    /// two-platform app who finds eleven rows here and sixteen panes on the Mac
    /// deserves to be told that is deliberate — and both the count AND the reasons
    /// come from the declaration, so neither can go stale.
    ///
    /// The REASONS were hardcoded in phase 1 ("a TeX toolchain, an HTTP server, or
    /// another impress app") because imprint was the only adopter and those were
    /// exactly its three. On imbib the same sentence was simply false: imbib has no
    /// TeX anything, and its Mac-only panes are an embedding provider, an E-Ink
    /// transfer surface, a colour-well editor and a library-location picker. A
    /// footer that explains an absence with the wrong reason is worse than one that
    /// does not explain it — so the reasons are now derived from the
    /// `SettingsRequirement`s the hidden sections actually declare, and a section
    /// hidden purely because its implementation is macOS-only contributes no
    /// spurious capability claim.
    @ViewBuilder
    private var macOnlyFooter: some View {
        let shown = Set(sections.map(\.id))
        let hiddenSections = configuration.sections.filter { !shown.contains($0.id) }
        if !hiddenSections.isEmpty {
            Text(Self.footerText(hiding: hiddenSections))
        }
    }

    /// Built outside the view builder: a count, a pluralisation and a joined clause
    /// list in one `Text(...)` interpolation is past the type checker's budget.
    static func footerText(hiding hidden: [SettingsSectionDescriptor]) -> String {
        let count = hidden.count
        let lead = "\(count) more setting\(count == 1 ? "" : "s") "
            + "\(count == 1 ? "is" : "are") available on the Mac"

        let requirements = Set(hidden.flatMap(\.availability.requirements))
        guard !requirements.isEmpty else {
            // Every hidden pane is "macOS-only implementation", with no capability
            // claim to make. Say the weaker, true thing.
            return lead + "."
        }

        // Stable order so the sentence does not shuffle between launches.
        let clauses = SettingsRequirement.allCases
            .filter { requirements.contains($0) }
            .map(\.iosAbsenceClause)
        return lead + " — they need " + clauses.listed + "."
    }

    // MARK: - Pushed pane

    @ViewBuilder
    private func paneScreen(for descriptor: SettingsSectionDescriptor) -> some View {
        Group {
            if let factory = registry[descriptor.id] {
                factory.makeContent(
                    SettingsSectionContext(
                        presentation: .iOSPushedScreen, descriptor: descriptor))
            } else {
                // A preset naming an unregistered pane is a wiring bug; say so
                // instead of pushing an empty screen. (Test-time form:
                // `SettingsSectionRegistry.unresolvedSections`.)
                ContentUnavailableView(
                    descriptor.title,
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "No content is registered for “\(descriptor.id.rawValue)”."))
            }
        }
        .navigationTitle(descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.pane.\(descriptor.id.rawValue)")
    }
}

// MARK: - Footer wording

private extension SettingsRequirement {
    /// How to name this capability to a user who cannot have it.
    ///
    /// Deliberately NOT the doc-comment prose from `SettingsRequirement` — that
    /// text explains the constraint to a developer ("the
    /// `com.apple.security.network.server` entitlement, which iOS does not
    /// grant"); this is the half-clause a person reads under a settings list.
    var iosAbsenceClause: String {
        switch self {
        case .httpAutomation: return "a local HTTP server"
        case .localToolchain: return "command-line tools on the same machine"
        case .siblingAppDiscovery: return "another impress app installed alongside"
        case .spotlightIndex: return "a Spotlight index"
        }
    }
}

private extension Array where Element == String {
    /// "a", "a or b", "a, b, or c".
    var listed: String {
        switch count {
        case 0: return ""
        case 1: return self[0]
        case 2: return "\(self[0]) or \(self[1])"
        default: return dropLast().joined(separator: ", ") + ", or " + self[count - 1]
        }
    }
}
#endif
