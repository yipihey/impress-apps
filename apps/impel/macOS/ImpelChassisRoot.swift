//
//  ImpelChassisRoot.swift
//  impel (macOS)
//
//  Stage 2-C of the GUI unification: impel's TASK/RUN BROWSING on the SAME
//  chassis as imbib/imprint/implore/impart — PublicationManagerCore's
//  `TabContentView` — filtered to the Agents facet via
//  `AppShellConfiguration.impel`. "impel = imbib filtered to agents": the
//  sidebar shows only the Agents section (Tasks with per-state smart
//  children, Runs — read from the shared store's `task@1.0.0` /
//  `agent-run@1.0.0` rows), and the dashboard / escalations / suggestions /
//  counsel experiences ride along as app-owned CUSTOM SURFACES (WP-X0)
//  wrapping the EXISTING (post-C0) views — no rewrites.
//
//  This root replicates impart's ImpartChassisRoot exactly: the chassis
//  reads three `@Environment` view models — PMC's `LibraryManager`,
//  `LibraryViewModel`, `SearchViewModel` — plus the injected
//  `\.appShellConfiguration`. Everything else the chassis needs
//  (`RustStoreAdapter.shared`, `AgentStoreReader.shared`, …) is a PMC
//  singleton impel gets for free by linking PublicationManagerCore, reading
//  the SAME shared store impel-core's TaskStoreApi writes (ADR-0001: same
//  data, different facet).
//
//  DELIBERATE deviation from implore (Stage 2-C plan, same as impart): this
//  chassis does NOT replace impel's default window. Escalation resolution /
//  counsel flows aren't chassis-wired yet, so the classic ContentView stays
//  primary behind the "impel.useChassisWindow" flag (see ImpelApp).
//
//  Surface context note: impel's `ImpelClient` and `MailGatewayState` are
//  app-root `@StateObject`s that ImpelApp injects as environment objects
//  into BOTH window roots, so the surfaces below read them via
//  `@EnvironmentObject` instead of a separate ImpelSurfaceContext singleton
//  — constructing fresh view models in a context object would fork state
//  from the classic window (empty dashboard). The makeView closures capture
//  nothing, so they stay `@Sendable`-clean.
//
//  Launch TCC hang avoidance (see ImprintChassisRoot): the shared store's
//  first `open()` can block on a TCC prompt / WAL lock, so it is warmed on
//  a DETACHED background task before the main-actor view models exist.
//

import SwiftUI
import ImpelCore
import ImpressKeyboard
import ImpressLogging
import PublicationManagerCore

/// Holds the three chassis view models. Constructed once, on the main actor,
/// only AFTER the shared store has been warmed off-main.
@MainActor
final class ChassisViewModels {
    let libraryManager: PublicationManagerCore.LibraryManager
    let libraryViewModel: PublicationManagerCore.LibraryViewModel
    let searchViewModel: PublicationManagerCore.SearchViewModel

    init() {
        let libraryManager = PublicationManagerCore.LibraryManager()
        let libraryViewModel = PublicationManagerCore.LibraryViewModel()
        let searchViewModel = PublicationManagerCore.SearchViewModel()
        searchViewModel.setLibraryManager(libraryManager)
        self.libraryManager = libraryManager
        self.libraryViewModel = libraryViewModel
        self.searchViewModel = searchViewModel
    }
}

/// impel's chassis root: the shared chassis (`TabContentView`) restricted to
/// the Agents facet, with Dashboard/Escalations/Suggestions/Counsel
/// registered as custom surfaces. Gated behind an off-main store warm-up so
/// the window never blocks on the shared store open.
struct ImpelChassisRoot: View {
    @State private var models: ChassisViewModels?

    /// The impel shell: PMC's `.impel` preset (Agents section, detail-pane
    /// open behavior) EXTENDED app-side with the custom surfaces — the
    /// preset cannot hold app-target views (WP-X0 seam).
    private static let shellConfiguration: AppShellConfiguration =
        AppShellConfiguration.impel.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: "dashboard", title: "Dashboard", systemImage: "square.grid.2x2",
                makeView: { AnyView(DashboardSurface()) }),
            CustomSurfaceDescriptor(
                id: "escalations", title: "Escalations", systemImage: "exclamationmark.circle",
                makeView: { AnyView(EscalationsSurface()) }),
            CustomSurfaceDescriptor(
                id: "suggestions", title: "Suggestions", systemImage: "lightbulb",
                makeView: { AnyView(SuggestionsSurface()) }),
            CustomSurfaceDescriptor(
                id: "counsel", title: "Counsel", systemImage: "envelope",
                makeView: { AnyView(CounselSurface()) }),
        ])

    var body: some View {
        Group {
            if let models {
                TabContentView()
                    .environment(models.libraryManager)
                    .environment(models.libraryViewModel)
                    .environment(models.searchViewModel)
                    .environment(\.appShellConfiguration, Self.shellConfiguration)
            } else {
                loadingView
            }
        }
        .task {
            guard models == nil else { return }
            // Warm the shared store OFF the main thread (see header note).
            await Self.warmSharedStore()
            models = ChassisViewModels()
            logInfo("ImpelChassisRoot: chassis environment ready (Agents facet)", category: "app")
        }
    }

    /// Force the shared-store open onto a background thread and await completion.
    private static func warmSharedStore() async {
        await Task.detached(priority: .userInitiated) {
            _ = PublicationManagerCore.RustStoreAdapter.shared
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

// MARK: - Custom surfaces (wrap the EXISTING post-C0 views — no rewrites)

/// The existing dashboard grid as a full-pane surface. Not the default
/// landing — the shell lands on Agents/Tasks; the dashboard is one click
/// away in the sidebar.
struct DashboardSurface: View {
    var body: some View {
        DashboardView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The existing escalation list as a full-pane surface. The classic
/// window's j/k + 1-9 escalation keys stay INSIDE this surface (guarded, so
/// they never fire while typing) — replicating ContentView's handler with a
/// surface-local selection index (the classic window's List shows no
/// selection highlight either; behavior parity).
struct EscalationsSurface: View {
    @EnvironmentObject var client: ImpelClient
    @State private var selectedIndex: Int?

    var body: some View {
        EscalationListView(escalations: client.state.pendingEscalations)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focusEffectDisabled()
            .keyboardGuarded { press in handleKey(press) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let escalations = client.state.pendingEscalations
        guard !escalations.isEmpty else { return .ignored }

        if press.characters == "j" && press.modifiers.isEmpty {
            selectedIndex = selectedIndex.map { min($0 + 1, escalations.count - 1) } ?? 0
            return .handled
        }
        if press.characters == "k" && press.modifiers.isEmpty {
            selectedIndex = selectedIndex.map { max($0 - 1, 0) } ?? 0
            return .handled
        }

        // Number keys resolve the selected escalation's options (1-9).
        if press.modifiers.isEmpty,
           let index = selectedIndex, index < escalations.count {
            let escalation = escalations[index]
            if let options = escalation.options {
                let keyNum = Int(press.characters) ?? 0
                if keyNum >= 1 && keyNum <= min(options.count, 9) {
                    let optionIndex = keyNum - 1
                    let optionLabel = options[optionIndex]
                    let escalationID = escalation.id
                    Task {
                        try? await client.resolveEscalation(
                            id: escalationID,
                            optionIndex: optionIndex,
                            optionLabel: optionLabel
                        )
                    }
                    return .handled
                }
            }
        }
        return .ignored
    }
}

/// The existing proactive-suggestion list as a full-pane surface.
struct SuggestionsSurface: View {
    @EnvironmentObject var client: ImpelClient

    var body: some View {
        SuggestionListView(suggestions: client.state.activeSuggestions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The existing counsel mail-gateway stack (live/history) as a full-pane
/// surface.
struct CounselSurface: View {
    var body: some View {
        CounselGatewayView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
