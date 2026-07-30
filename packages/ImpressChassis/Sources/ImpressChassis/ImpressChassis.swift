//
//  ImpressChassis.swift
//
//  The chassis package's own file: documentation, no symbols.
//
//  Until Stage 3 item C5 this file WAS the package — eleven lines of
//  `@_exported import PublicationManagerCore`, so shells could be written
//  against the final module name while the code still lived in PMC. C5
//  reversed the arrow: the contract files listed below are really here, and
//  PMC re-exports THIS module (see
//  `PublicationManagerCore/Chassis/ImpressChassisReexport.swift`). Nothing in
//  the tree imported `ImpressChassis` at the time of the reversal, so the
//  façade could be retired outright rather than deprecated.
//
//  What is here is the part of the chassis contract that names nothing outside
//  itself:
//
//    * `Settings/SettingsSectionDescriptor.swift` — a settings section as
//      DATA (id, title, SF Symbol, availability, order).
//    * `Settings/AppSettingsConfiguration.swift` — the per-app ordered section
//      list; the settings twin of `AppShellConfiguration`.
//    * `RecordKind/RecordListHostModel.swift` — the three-state rule and the
//      row-identifier convention for a single-kind record list.
//    * `Shared/ChassisNavigation.swift` — the two "navigate into the chassis"
//      notification names.
//    * `Manuscripts/FocusedManuscript.swift` — the focused-manuscript
//      `FocusedValueKey`.
//
//  Each is read by both platforms and by more than one app, and each compiles
//  with Foundation or SwiftUI alone. The renderers that consume them —
//  `SettingsSectionRegistry`, `MacSettingsSceneContent`, `IOSSettingsScreen`,
//  `RecordListHostView`, `TabContentView`, `ManuscriptSectionView` — stayed in
//  PMC, because they reach imbib's domain and store. That asymmetry is the
//  whole finding of C5; it is recorded, with counts, in ADR-0021 D5.
//
