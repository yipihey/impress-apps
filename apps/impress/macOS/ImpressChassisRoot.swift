#if os(macOS)
//
//  ImpressChassisRoot.swift
//  impress
//
//  ADR-0022 D9 — the sixth shell, and the payoff the groundwork was priced for.
//
//  D9 said: "when ready, the app is a ~120-line `ImpressChassisRoot` against
//  seams tested for months". This is that file, and it is shorter than the
//  estimate, because the estimate was written before `ChassisRootView` (Stage
//  4b) existed. What is left here is the three things a shell genuinely owns:
//  WHICH preset, WHICH surfaces it adds to it, and WHAT it says when it is up.
//
//  WHAT IMPRESS RENDERS TODAY, honestly. The preset permits every section
//  (`AppShellConfiguration.impress.visibleSections` = every case, explicitly),
//  and each section reaches its content by one of three routes:
//
//    * figures / mail / agents → the REGISTRY. `RecordViewerRegistry.builtin`
//      carries `FigureSectionView`, `MessageSectionView` and `AgentSectionView`
//      (tasks and runs share the last one), so these four kinds arrive with no
//      registration from this file. That is the ADR-0021 litmus claim holding
//      in a real host: impress adds a shell, and the chassis needed no edit to
//      serve it.
//    * manuscripts → `ManuscriptSectionView`, a DELIBERATE exception. It is
//      routed by `SectionContentView`, not the viewer registry, because it
//      hosts the editor SESSION (the imbib CLAUDE.md invariant: the session is
//      owned by the host view, never by `ManuscriptDetailPane`) and a registry
//      factory has nowhere to put one.
//    * publications (inbox / libraries / sharedWithMe / scixLibraries / search /
//      exploration / flagged / citedInManuscripts / dismissed) → the
//      publication list path (`UnifiedPublicationListWrapper` and the
//      multi-select `PublicationSource` union behind it). Also a deliberate
//      exception, and the reason is recorded in ADR-0022 C2 axis 5: publication
//      content routing is `UnifiedPublicationListWrapper`'s remit and converging
//      it onto `RecordRoute` is a rewrite, not a registration.
//
//  CUSTOM SURFACES: NONE registered here, and that is a positive finding rather
//  than an omission. `CustomSurfaceRegistry` composes the chassis BUILTIN tier
//  into every shell, and `StoreSearchSurface` — the grouped mixed-kind search
//  that is impress's showcase — is exactly that builtin (ADR-0022 G4: "grouped
//  store-wide search is not an app's feature; an app that had to opt in would be
//  an app that could forget to"). Registering it app-side would REPLACE the
//  builtin with an identical copy. The chord is bound in `ImpressApp`'s menu
//  tree via `ImpressStoreSearchCommands`, which is the only part an app owes.
//
//  Nothing else renders empty without a surface: every other section is a
//  record section, and every record section resolves through one of the three
//  routes above.
//
//  D7 (link ALL renderers) is satisfied by the LINK LIST, not by code here:
//  `apps/impress/project.yml` links PublicationManagerCore, which carries
//  Typst, PDFKit, MarkdownUI, the figure CAS artifact readers, the mail viewers
//  and the agent/run viewers. "The future impress target is a link-list
//  decision, not a refactor" — it was.
//

import PublicationManagerCore
import SwiftUI

/// impress's macOS root: the shared chassis with nothing taken away.
struct ImpressChassisRoot: View {

    /// Internal, not private, so `impressTests` can assert what this shell
    /// registers — the same reason impart's and impel's are internal.
    ///
    /// No `withCustomSurfaces(_:)` and no `presenting(_:)`: macOS impress can
    /// present every kind the registry knows, so narrowing either axis would be
    /// a claim that is not true.
    static let shellConfiguration: AppShellConfiguration = .impress

    var body: some View {
        ChassisRootView(
            configuration: Self.shellConfiguration,
            readyLogMessage: "ImpressChassisRoot: chassis environment ready (every facet)"
        )
        .withAppearance()
    }
}
#endif // os(macOS)
