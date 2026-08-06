//
//  ImprintChassisRoot.swift
//  imprint
//
//  GUI-meld Phase 6: imprint's macOS GUI is now the SAME chassis as imbib —
//  PublicationManagerCore's `TabContentView` — filtered to the Manuscripts
//  facet via `AppShellConfiguration.imprint`. "imprint = imbib filtered to
//  manuscripts": the sidebar shows only Manuscripts (+ cited-in-manuscripts,
//  flagged, search), and it lands on a manuscript in the Source (editor) tab.
//
//  Stage 4b: the ~75 lines of chassis boilerplate this file used to carry — a
//  `ChassisViewModels` class (declared under that same name in FOUR app
//  targets), a `warmSharedStore()` and a loading view — now live once, in PMC's
//  `ChassisRootView`. That view still does exactly what the comment below
//  described, and the reasons are worth keeping here because this is the file
//  people open when launch hangs:
//
//    * It injects the environment imbib's App root injects (imbibApp.swift):
//      the chassis reads three `@Environment` view models — `LibraryManager`,
//      `LibraryViewModel`, `SearchViewModel` (all PMC) — plus
//      `\.appShellConfiguration`. Everything else the chassis needs
//      (`RustStoreAdapter.shared`, `ImbibImpressStore.shared`,
//      `InboxManager.shared`, `CredentialManager.shared`, …) is a PMC singleton
//      imprint gets for free by linking PMC, reading the SAME shared App Group
//      store as imbib (ADR-0001: same data, different facet).
//    * It warms the store OFF the main thread first (see MEMORY
//      fix_imprint_launch_tcc_offmain_store): `RustStoreAdapter.shared`'s first
//      touch opens the shared App Group store, whose `open()` can block on a TCC
//      prompt / WAL lock. A window-time loading state covers the gap.
//
//  What stays imprint's: `.withAppearance()` (imprint defines that modifier
//  itself, in ImprintApp.swift) and the `#if os(macOS)` wrapper.
//

#if os(macOS)
import SwiftUI
import PublicationManagerCore

/// imprint's macOS root: the shared chassis restricted to the Manuscripts facet.
struct ImprintChassisRoot: View {
    var body: some View {
        ChassisRootView(
            configuration: .imprint,
            readyLogMessage:
                "ImprintChassisRoot: chassis environment ready (Manuscripts facet)"
        )
        // The Git menu's observers + sheets. This attachment IS the wiring:
        // the menu posts notifications, and a modifier nobody applies receives
        // none of them — which is exactly what happened when the legacy
        // ContentView (the previous host) retired.
        .modifier(GitIntegrationModifier())
        .withAppearance()
    }
}
#endif // os(macOS)
