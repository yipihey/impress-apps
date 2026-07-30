//
//  ImploreChassisRoot.swift
//  implore
//
//  Stage 2-B of the GUI unification: implore's Library mode is now the SAME
//  chassis as imbib/imprint — PublicationManagerCore's `TabContentView` —
//  filtered to the Figures facet via `AppShellConfiguration.implore`.
//  "implore = imbib filtered to figures": the sidebar shows only the Figures
//  section (All Figures / Unfiled / folders), and the Metal canvas plus the
//  old Generate/Analyze sidebar modes ride along as app-owned CUSTOM
//  SURFACES (WP-X0) wrapping the EXISTING views — no rewrites.
//
//  Stage 4b: the chassis boilerplate this file used to carry — a
//  `ChassisViewModels` class (declared under that same name in FOUR app
//  targets), a `warmSharedStore()` and a loading view — now lives once, in PMC's
//  `ChassisRootView`. It injects the same environment: the chassis reads three
//  `@Environment` view models — PMC's `LibraryManager`, `LibraryViewModel`,
//  `SearchViewModel` — plus `\.appShellConfiguration`. Everything else the
//  chassis needs (`RustStoreAdapter.shared`, `ImbibImpressStore.shared`,
//  `FigureStoreReader.shared`, …) is a PMC singleton implore gets for free by
//  linking PublicationManagerCore, reading the SAME shared App Group store
//  (ADR-0001: same data, different facet). It also keeps the off-main store
//  warm-up (see ImprintChassisRoot): the first `open()` can block on a TCC
//  prompt / WAL lock.
//
//  The name collision that forced `PublicationManagerCore.LibraryManager`
//  qualification in the old local `ChassisViewModels` is gone with it — implore
//  keeps its OWN `LibraryManager` (the JSON figure library), and the surfaces
//  below still inject that one.
//
//  What stays implore's: the two custom surface descriptors, the
//  `ImploreSurfaceContext` singleton, the surface views, `ImploreCanvasStack`
//  and `CanvasWindowView`.
//

import SwiftUI
import PublicationManagerCore

/// Shared context for the custom surfaces: the generator view model outlives
/// any single surface view (the chassis constructs surface views lazily per
/// selection), so it lives here rather than in view `@State`.
@MainActor
final class ImploreSurfaceContext {
    static let shared = ImploreSurfaceContext()
    let generatorViewModel = GeneratorViewModel()
    private init() {}
}

/// implore's macOS root: the shared chassis (`TabContentView`) restricted to
/// the Figures facet, with Generate/Analyze registered as custom surfaces.
/// Gated behind an off-main store warm-up so launch never blocks on the App
/// Group store open.
struct ImploreChassisRoot: View {

    /// The implore shell: PMC's `.implore` preset (Figures section, canvas
    /// open behavior) EXTENDED app-side with the custom surfaces — the
    /// preset cannot hold app-target views (WP-X0 seam).
    private static let shellConfiguration: AppShellConfiguration =
        AppShellConfiguration.implore.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: "generate", title: "Generate", systemImage: "waveform",
                makeView: { AnyView(GenerateSurface()) }),
            CustomSurfaceDescriptor(
                id: "analyze", title: "Analyze", systemImage: "chart.bar",
                makeView: { AnyView(AnalyzeSurface()) }),
        ])

    var body: some View {
        ChassisRootView(
            configuration: Self.shellConfiguration,
            readyLogMessage: "ImploreChassisRoot: chassis environment ready (Figures facet)")
    }
}

// MARK: - Custom surfaces (wrap the EXISTING mode views — no rewrites)

/// The old "Generate" sidebar mode as a full-pane surface: the existing
/// GeneratorBrowserSection (browser + parameter form + Generate button) on
/// the left, the existing GeneratedDataView on the right.
struct GenerateSurface: View {
    var body: some View {
        if let appState = AppState.shared {
            HSplitView {
                GeneratorBrowserSection()
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                    .frame(maxHeight: .infinity)
                GeneratedDataView(viewModel: ImploreSurfaceContext.shared.generatorViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // HSplitView does NOT fill like NavigationSplitView — the fill
            // frame is mandatory (impress-swiftui-pitfalls rule 4).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(appState)
            .environment(ImploreSurfaceContext.shared.generatorViewModel)
            .environment(LibraryManager.shared)
        } else {
            surfaceUnavailable
        }
    }
}

/// The old "Analyze" sidebar mode as a full-pane surface: the existing
/// DiagnosticsSection on the left, the live canvas stack on the right.
struct AnalyzeSurface: View {
    var body: some View {
        if let appState = AppState.shared {
            HSplitView {
                DiagnosticsSection()
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                    .frame(maxHeight: .infinity)
                ImploreCanvasStack(
                    generatorViewModel: ImploreSurfaceContext.shared.generatorViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(appState)
            .environment(ImploreSurfaceContext.shared.generatorViewModel)
            .environment(LibraryManager.shared)
        } else {
            surfaceUnavailable
        }
    }
}

private var surfaceUnavailable: some View {
    ContentUnavailableView(
        "Not Ready",
        systemImage: "hourglass",
        description: Text("The app state is still initializing.")
    )
}

// MARK: - Canvas stack

/// The Metal canvas dispatch — the exact detail branches the pre-chassis
/// ContentView used (PlotView / RgSliceView / VisualizationView /
/// GeneratedDataView / Welcome), reused by the Analyze surface and the
/// canvas window.
struct ImploreCanvasStack: View {
    @Environment(AppState.self) var appState
    var generatorViewModel: GeneratorViewModel

    var body: some View {
        if let plotState = appState.plotViewerState, appState.showingPlotView {
            PlotView(svgString: plotState.currentSVG ?? "", plotState: plotState)
                .accessibilityIdentifier("plot.container")
        } else if let rgState = appState.rgViewerState {
            RgSliceView(viewerState: rgState)
                .accessibilityIdentifier("rg.container")
        } else if let session = appState.currentSession {
            VisualizationView(session: session)
                .accessibilityIdentifier("visualization.container")
        } else if generatorViewModel.generatedData != nil {
            GeneratedDataView(viewModel: generatorViewModel)
                .accessibilityIdentifier("generatedData.container")
        } else {
            WelcomeView()
                .accessibilityIdentifier("welcome.container")
        }
    }
}

/// The `canvas` window (WindowGroup id "canvas", value = figure id string —
/// what the chassis' FigureSectionView opens via `openBehavior(for: .figure)`).
/// Loading a figure BY ID into the canvas is not implemented in the existing
/// stack (the pre-chassis vim "l" handler carried the same TODO), so this
/// window honestly does what the old GUI did: select the figure in
/// LibraryManager and present the live canvas stack.
struct CanvasWindowView: View {
    let figureID: String?

    var body: some View {
        if let appState = AppState.shared {
            ImploreCanvasStack(
                generatorViewModel: ImploreSurfaceContext.shared.generatorViewModel)
                .frame(minWidth: 640, minHeight: 480)
                .onAppear {
                    if let figureID {
                        LibraryManager.shared.selectedFigureId = figureID
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        RenderModePicker()
                    }
                }
                // Environment applied OUTERMOST so the toolbar's
                // RenderModePicker sees AppState too.
                .environment(appState)
                .environment(ImploreSurfaceContext.shared.generatorViewModel)
                .environment(LibraryManager.shared)
        } else {
            surfaceUnavailable
        }
    }
}
