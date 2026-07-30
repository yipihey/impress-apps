// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  ImpressChassisReexport.swift
//  PublicationManagerCore
//
//  Stage 3 item C5 (ADR-0021 D5): THE compatibility invariant of the chassis
//  lift, in one line.
//
//  Five contract files moved out of `Chassis/` into `packages/ImpressChassis`.
//  Every one of them is public API that app targets, their tests and the iOS
//  shells reach through `import PublicationManagerCore` — a few hundred call
//  sites across five apps. Re-exporting the module here means not one of them
//  changes: `AppSettingsConfiguration`, `SettingsSectionDescriptor`,
//  `RecordListPhase`, `.chassisNavigateToSurface` and `focusedManuscriptID`
//  resolve exactly as before, from exactly the same import.
//
//  Why re-export rather than make every consumer add a second import: the
//  point of the lift is to move code, not to spend a hundred diffs proving it
//  moved. When (if) the extraction grows to the point where apps genuinely
//  depend on ImpressChassis and not on PMC, they can import it directly and
//  this line becomes the compatibility shim it looks like. Until then it is
//  the reason C5 could be verified by "the suite still builds" rather than by
//  reading a churn diff.
//
//  Note that this is NOT the old façade in reverse. The old
//  `ImpressChassis.swift` re-exported PMC *from* the package; this re-exports
//  the package *from* PMC. The dependency arrow — and therefore which module
//  can be built without the other — really did flip.

@_exported import ImpressChassis
