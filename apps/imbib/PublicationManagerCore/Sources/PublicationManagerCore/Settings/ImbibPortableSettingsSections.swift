//
//  ImbibPortableSettingsSections.swift
//  PublicationManagerCore
//
//  Stage 6 phase 2: the imbib settings panes whose macOS and iOS implementations
//  were the SAME view, declared once.
//
//  WHY THIS FILE IS SHORT, and why that is the honest result rather than a
//  half-finished migration:
//
//  imbib was expected to be phase 2's big duplication kill — 3,998 lines of macOS
//  settings against 3,185 of iOS, apparently the same sixteen-odd panes twice.
//  Auditing the pairs pane by pane, that is not what they are. `AppearanceSettingsTab`
//  (530 lines: named themes, accent colours, font scale, mail-style density over
//  `ThemeSettingsStore`) and `IOSAppearanceSettingsView` (304) are not one pane
//  written twice; they are two designs for two input models. macOS `SourcesSettingsTab`
//  is a `DisclosureGroup` list with `SecureField`s and hover help; iOS's is a
//  pushed `List` with `.textInputAutocapitalization`. macOS `InboxSettingsTab`
//  edits mute rules inline in a `Form`; iOS raises `AddMuteRuleSheet`. macOS
//  `ImportExportSettingsTab` uses a segmented `Picker` and a `.popover` help
//  panel; iOS pushes `IOSCiteKeyFormatHelpView`.
//
//  Collapsing those pairs would not be a reframe. It would mean choosing one
//  platform's UI and shipping it on the other — and the migration's hard rule is
//  that **macOS stays visually equivalent**, so the choice would have to be
//  macOS's: `NSOpenPanel`, `NSColorPanel`, hover tooltips and grouped `Form`s on
//  a phone. That is worse iOS, not less code.
//
//  So the duplication phase 2 actually removes is the duplication that was
//  STRUCTURAL rather than visual: two hand-written lists of which panes exist, in
//  what order, under what headings, with what icons — four `switch`es on macOS and
//  nineteen `NavigationLink`s on iOS, unable to read each other. That list is now
//  `AppSettingsConfiguration.imbib`, and it is why iOS and macOS can no longer
//  drift about what imbib's settings ARE even though several panes still render
//  differently on purpose.
//
//  One pair genuinely WAS the same view in two wrappers, and it lives here.
//  Others can join it the day someone rewrites a pair on purpose; nothing about
//  the mechanism has to change for that, which is the point.
//

import SwiftUI

/// imbib settings panes registered ONCE for both platforms.
///
/// Composed into each platform's registry between the chassis builtins and that
/// platform's own factories (`ImbibSettingsSections.registry` on macOS,
/// `IOSImbibSettingsSections.registry` on iOS), so a portable pane overrides a
/// builtin and a platform pane overrides a portable one — the phase-1 tier order,
/// unchanged.
public enum ImbibPortableSettingsSections {

    public static let factories: [SettingsSectionFactory] = [
        SettingsSectionFactory(section: .enrichment) { context in
            AnyView(ImbibEnrichmentSettingsPane(presentation: context.presentation))
        },
    ]
}

/// Enrichment (citation sources and metadata) — the one imbib pane that was
/// already identical on both platforms.
///
/// `EnrichmentSettingsView` has lived in `PMC/SharedViews/` all along; what was
/// duplicated was the four-line wrapper around it — `EnrichmentSettingsTab` in
/// imbib's macOS target and `IOSEnrichmentSettingsView` in imbib-iOS's, differing
/// by ONE modifier. That modifier is the platform difference the context exists
/// to express, so it is read from `SettingsSectionContext.presentation` rather
/// than from an `#if`: the pane stays one type that either renderer can build,
/// and a test on macOS can still construct the iOS presentation.
struct ImbibEnrichmentSettingsPane: View {

    let presentation: SettingsSectionContext.Presentation

    @Environment(SettingsViewModel.self) private var viewModel

    var body: some View {
        content
            .task { await viewModel.loadEnrichmentSettings() }
    }

    @ViewBuilder
    private var content: some View {
        // macOS's shipped wrapper padded horizontally; the iOS one must not, for
        // the reason `SettingsForm` documents — a pushed grouped list is already
        // inset by the navigation stack, and padding it puts a visible gutter
        // down both sides.
        if presentation == .macTab {
            EnrichmentSettingsView(viewModel: viewModel)
                .padding(.horizontal)
        } else {
            EnrichmentSettingsView(viewModel: viewModel)
        }
    }
}
