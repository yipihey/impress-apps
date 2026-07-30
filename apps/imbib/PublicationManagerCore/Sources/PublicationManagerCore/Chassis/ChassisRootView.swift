#if os(macOS)
// Chassis file — macOS-only (the chassis roots are macOS window contents; iOS
// hosts have their own shells).
//
//  ChassisRootView.swift
//  PublicationManagerCore
//
//  Stage 4b: the chassis root, ONCE.
//
//  Four sibling apps each carried a `*ChassisRoot.swift` whose first ~75 lines
//  were the same file four times over:
//
//    * a `final class ChassisViewModels` — same NAME in four different app
//      targets — constructing PMC's three `@Observable` view models and wiring
//      `searchViewModel.setLibraryManager(libraryManager)`;
//    * a `warmSharedStore()` that forces `RustStoreAdapter.shared`'s lazy open
//      onto a detached task (see MEMORY fix_imprint_launch_tcc_offmain_store:
//      that open can block on a TCC prompt or a WAL lock, and doing it on the
//      main thread hangs launch);
//    * a `loadingView` — byte-identical in all four, down to the
//      "click Allow" hint.
//
//  Only three things ever differed: the `AppShellConfiguration` (each app's
//  preset, usually `.withCustomSurfaces([...])`), the log line's facet name, and
//  whether the app applied its own `.withAppearance()` — which stays OUTSIDE
//  this view, because each app defines that modifier itself.
//
//  What each root keeps is exactly its app-specific half: its custom surface
//  descriptors, its surface-context singleton, its `@EnvironmentObject`-based
//  surfaces, its extra windows.
//

import SwiftUI
import ImpressLogging

// MARK: - View models

/// The three chassis view models `TabContentView` reads from `@Environment`.
///
/// Constructed once, on the main actor, only AFTER the shared store has been
/// warmed off-main — so none of the default-argument `= RustStoreAdapter.shared`
/// touches inside their initializers blocks the main thread.
@MainActor
public final class ChassisViewModels {
    public let libraryManager: LibraryManager
    public let libraryViewModel: LibraryViewModel
    public let searchViewModel: SearchViewModel

    public init() {
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

// MARK: - Store warm-up

extension RustStoreAdapter {

    /// Force the shared-store open onto a background thread and await completion.
    ///
    /// `RustStoreAdapter.shared` is a `nonisolated(unsafe) static let`; forcing
    /// its lazy init on a detached task runs the blocking `open()` there, not on
    /// main. Removing this is how imprint's launch hung on a TCC prompt.
    public static func warmOffMain() async {
        await Task.detached(priority: .userInitiated) {
            _ = RustStoreAdapter.shared
        }.value
    }
}

// MARK: - Root

/// The chassis root every sibling app's macOS window renders.
///
/// Warms the shared store off-main, then hands `TabContentView` the three view
/// models and the app's `AppShellConfiguration`. Shows a loading state until the
/// store is open.
///
/// A host wraps this in whatever is genuinely its own — its `.withAppearance()`,
/// its `.environment(appState)`, its `.onReceive` window plumbing:
///
/// ```swift
/// struct ImploreChassisRoot: View {
///     var body: some View {
///         ChassisRootView(
///             configuration: Self.shellConfiguration,
///             readyLogMessage: "ImploreChassisRoot: chassis environment ready (Figures facet)")
///     }
/// }
/// ```
public struct ChassisRootView: View {

    /// The app's shell preset, normally `.withCustomSurfaces([...])` applied to
    /// one of `AppShellConfiguration`'s presets.
    private let configuration: AppShellConfiguration

    /// Logged at `info` on the `"app"` category once the environment is live.
    /// Each root passed its own string; keeping it a parameter means the log
    /// stays greppable per app instead of collapsing into one anonymous line.
    private let readyLogMessage: String

    @State private var models: ChassisViewModels?

    public init(configuration: AppShellConfiguration, readyLogMessage: String) {
        self.configuration = configuration
        self.readyLogMessage = readyLogMessage
    }

    public var body: some View {
        Group {
            if let models {
                TabContentView()
                    .environment(models.libraryManager)
                    .environment(models.libraryViewModel)
                    .environment(models.searchViewModel)
                    .environment(\.appShellConfiguration, configuration)
            } else {
                ChassisRootLoadingView()
            }
        }
        .task {
            guard models == nil else { return }
            await RustStoreAdapter.warmOffMain()
            // Now safe: the store is open, so the view models' default
            // `RustStoreAdapter.shared` references resolve without blocking.
            models = ChassisViewModels()
            logInfo(readyLogMessage, category: "app")
        }
    }
}

/// The "Opening workspace…" state, shown while the store open runs off-main.
/// Mirrors imprint's `ManuscriptLibraryGate`.
public struct ChassisRootLoadingView: View {

    public init() {}

    public var body: some View {
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
#endif
