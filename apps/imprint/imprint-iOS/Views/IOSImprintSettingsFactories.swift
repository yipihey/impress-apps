//
//  IOSImprintSettingsFactories.swift
//  imprint-iOS
//
//  Stage 6 phase 1: tier 3 of `ImprintSettingsSections.registry` — the panes
//  that are imprint-specific AND iOS-specific.
//
//  There are none yet, and that is a real statement rather than a stub: every
//  pane imprint-iOS shows today is either chassis-generic (Appearance,
//  registered by `SettingsSectionRegistry.builtin`) or portable imprint code
//  (General, Editor, Documents, Account, in `Shared/Settings/ImprintSettingsPanes.swift`).
//  Nothing in imprint's iOS settings needs an iOS-only implementation.
//
//  The file exists because the composition in `ImprintSettingsSections` names
//  `platformFactories` unconditionally, with no `#if` — one definition per
//  platform, each in its own target. An empty array here is the honest iOS
//  answer, and it is also the seam: the day an iOS-shaped pane exists (a
//  document-provider picker, an on-device model chooser), it registers here and
//  its descriptor's `availability.platforms` gains `.iOS`. Nothing else changes
//  — not the renderer, not the preset's shape, not the macOS side.
//
//  This mirrors `RecordViewerRegistry.builtin`, which resolves to an EMPTY
//  registry on iOS for the same structural reason: the registry must exist even
//  when its platform tier is empty, or the sections cannot be NAMED there.
//

import PublicationManagerCore

extension ImprintSettingsSections {
    /// iOS-only imprint panes. Empty by design — see the file header.
    static let platformFactories: [SettingsSectionFactory] = []
}
