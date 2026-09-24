#if os(macOS)
//
//  ImpressLayoutReexport.swift
//  PublicationManagerCore
//
//  The layout host left this package for `packages/ImpressLayout` (plan wave
//  6, W6; ADR-0033 D7). What stayed here is the domain half: the view-kind
//  factories that need the chassis (outline, list, info, pdf, notes, bibtex,
//  source, legacy), the row mapper, the suite-aware surface hooks and the
//  `LayoutAutomationHost` conformance — registered into the kit at startup by
//  `ChassisViewKinds.registerIfNeeded()`.
//
//  Re-exported for the reason `ImpressChassisReexport.swift` gives: the move
//  is a relocation, and every app that reached `LayoutTreeRuntime`,
//  `LayoutController` or `ViewKindRegistry` through PMC keeps reaching them
//  without a second import. The arrow points one way: the kit never imports
//  PMC (`scripts/check-kit-packages.sh`).
//

@_exported import ImpressLayout
#endif
