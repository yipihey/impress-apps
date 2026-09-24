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
import ImpressAutomation
import ImpressLayout
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

// MARK: - Composed sidebar

/// The `SidebarComposition` a shell renders, or nil for a shell that runs a
/// single flat preset.
///
/// An environment value rather than a flag on `AppShellConfiguration`, because
/// composing is not a property of a PRESET — the `.impress` preset is still the
/// flat union, and the parity suites still pin it — it is a property of the
/// WINDOW: this window shows five apps' sidebars. It is also what keeps the
/// chassis free of an `appID == "impress"` test (ADR-0022 D9): the one shell
/// that composes is the one root that passes the value.
public struct SidebarCompositionKeyEnvironment: EnvironmentKey {
    public static let defaultValue: SidebarComposition? = nil
}

public extension EnvironmentValues {
    var sidebarComposition: SidebarComposition? {
        get { self[SidebarCompositionKeyEnvironment.self] }
        set { self[SidebarCompositionKeyEnvironment.self] = newValue }
    }
}

// MARK: - Root

/// The chassis root every sibling app's macOS window renders.
///
/// Warms the shared store off-main, then hands the layout tree
/// (`LayoutTreeHost`) the three view models and the app's
/// `AppShellConfiguration`. Shows a loading state until the
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

    /// The composed sidebar this shell renders, or nil for a single-preset
    /// shell. DEFAULTED to nil so the five sibling roots are unchanged — they
    /// do not pass it, and a shell that does not pass it cannot accidentally
    /// acquire a group tier.
    private let sidebarComposition: SidebarComposition?

    @State private var models: ChassisViewModels?

    public init(
        configuration: AppShellConfiguration,
        readyLogMessage: String,
        sidebarComposition: SidebarComposition? = nil
    ) {
        self.configuration = configuration
        self.readyLogMessage = readyLogMessage
        self.sidebarComposition = sidebarComposition
        // The kit renders `placeholder`, `surface` and `console` alone; every chassis
        // view kind is registered here, in `init`, so it is in the registry
        // before this root's body — and so before any pane — renders (plan
        // wave 6, W6).
        ChassisViewKinds.registerIfNeeded()
    }

    /// The window's content: the ADR-0031 layout tree, always (plan wave 6
    /// W5 removed the `impress.layoutTree.enabled` flag and the preset's
    /// `usesLayoutTree`). `TabContentView` is still reachable — a `legacy`
    /// pane hosts it, whole or scoped to one route — but it is no longer a
    /// window root for any chassis app.
    private var root: some View {
        LayoutTreeHost(appID: configuration.appID, services: Self.layoutServices)
            // h / l pressed INSIDE a pane that claims them first. `DetailView`
            // (the `info` pane) and the publication list (in a `legacy` pane)
            // answer h/l as `.handled` and post `.cycleFocusLeft/Right` for
            // imbib's pre-chassis `ContentView` to cycle its own pane focus.
            // In a chassis window nobody else observes them, so before W5 the
            // key was swallowed there and focus never moved. The tree is the
            // only root now, so they route to the one place focus lives. (In
            // `LayoutWindowView` until W6 moved it to the kit, which cannot
            // see PMC's notification names.)
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusLeft)) { _ in
                LayoutTreeRuntime.shared.controller?.apply(.focusDirection(.left))
            }
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusRight)) { _ in
                LayoutTreeRuntime.shared.controller?.apply(.focusDirection(.right))
            }
    }

    /// What the kit's `LayoutTreeHost` needs from the chassis: the shared
    /// store (warmed off-main, exactly as this root's own `.task` does), and
    /// the HTTP automation host registered while the tree is open — "a tree
    /// is rendering" and "layout automation works" stay one fact.
    @MainActor
    static let layoutServices = LayoutHostServices(
        openStore: {
            await RustStoreAdapter.warmOffMain()
            return RustStoreAdapter.shared.layoutSharedStore()
        },
        didOpen: { controller in LayoutAutomation.shared.host = controller },
        didClose: { _ in LayoutAutomation.shared.host = nil },
        loading: { AnyView(ChassisRootLoadingView()) }
    )

    public var body: some View {
        Group {
            if let models {
                root
                    .environment(models.libraryManager)
                    .environment(models.libraryViewModel)
                    .environment(models.searchViewModel)
                    .environment(\.appShellConfiguration, configuration)
                    .environment(\.sidebarComposition, sidebarComposition)
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
