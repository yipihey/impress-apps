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
//  This root replicates the environment setup imbib's App root performs
//  (imbibApp.swift): the chassis reads three `@Environment` view models —
//  `LibraryManager`, `LibraryViewModel`, `SearchViewModel` (all from PMC) —
//  plus the injected `\.appShellConfiguration`. Everything else the chassis
//  needs (`RustStoreAdapter.shared`, `ImbibImpressStore.shared`,
//  `InboxManager.shared`, `CredentialManager.shared`, …) is a PMC singleton
//  that imprint gets for free by linking PublicationManagerCore, reading the
//  SAME shared App Group store as imbib (ADR-0001: same data, different facet).
//
//  Launch TCC hang avoidance (see MEMORY fix_imprint_launch_tcc_offmain_store):
//  `RustStoreAdapter.shared`'s first touch opens the shared App Group store,
//  whose `open()` can block on a TCC prompt / WAL lock. We warm it on a DETACHED
//  background task BEFORE constructing the view models on the main actor — so
//  the (potentially blocking) open never happens on the main thread. The window
//  shows a lightweight loading state meanwhile, mirroring `ManuscriptLibraryGate`.
//

#if os(macOS)
import SwiftUI
import ImpressLogging
import PublicationManagerCore

/// Holds the three chassis view models. Constructed once, on the main actor,
/// only AFTER the shared store has been warmed off-main — so none of the
/// default-argument `= RustStoreAdapter.shared` touches block the main thread.
@MainActor
final class ChassisViewModels {
    let libraryManager: LibraryManager
    let libraryViewModel: LibraryViewModel
    let searchViewModel: SearchViewModel

    init() {
        let libraryManager = LibraryManager()
        let libraryViewModel = LibraryViewModel()
        let searchViewModel = SearchViewModel()
        // Wire the library manager into search the same way imbib does, so
        // Cmd+S imports land in the active library.
        searchViewModel.setLibraryManager(libraryManager)
        self.libraryManager = libraryManager
        self.libraryViewModel = libraryViewModel
        self.searchViewModel = searchViewModel
    }
}

/// imprint's macOS root: the shared chassis (`TabContentView`) restricted to the
/// Manuscripts facet. Gated behind an off-main store warm-up so launch never
/// blocks on the App Group store open.
struct ImprintChassisRoot: View {
    @State private var models: ChassisViewModels?

    var body: some View {
        Group {
            if let models {
                TabContentView()
                    .environment(models.libraryManager)
                    .environment(models.libraryViewModel)
                    .environment(models.searchViewModel)
                    .environment(\.appShellConfiguration, .imprint)
            } else {
                loadingView
            }
        }
        .withAppearance()
        .task {
            guard models == nil else { return }
            // Warm the shared store OFF the main thread. `RustStoreAdapter.shared`
            // is a `nonisolated(unsafe) static let`; forcing its lazy init on a
            // detached task runs the blocking `open()` there, not on main.
            await Self.warmSharedStore()
            // Now safe: the store is open, so the view models' default
            // `RustStoreAdapter.shared` references resolve without blocking.
            models = ChassisViewModels()
            logInfo("ImprintChassisRoot: chassis environment ready (Manuscripts facet)", category: "app")
        }
    }

    /// Force the shared-store open onto a background thread and await completion.
    private static func warmSharedStore() async {
        await Task.detached(priority: .userInitiated) {
            _ = RustStoreAdapter.shared
        }.value
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening workspace…")
                .font(.headline)
            Text("If macOS asks to allow access to data from other apps, click Allow.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif // os(macOS)
