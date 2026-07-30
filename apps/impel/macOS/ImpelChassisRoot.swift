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
//  Stage 4b: the chassis boilerplate this file used to carry — a
//  `ChassisViewModels` class (declared under that same name in FOUR app
//  targets), a `warmSharedStore()` and a loading view — now lives once, in PMC's
//  `ChassisRootView`. It injects the same environment: the chassis reads three
//  `@Environment` view models — PMC's `LibraryManager`, `LibraryViewModel`,
//  `SearchViewModel` — plus `\.appShellConfiguration`. Everything else the
//  chassis needs (`RustStoreAdapter.shared`, `AgentStoreReader.shared`, …) is a
//  PMC singleton impel gets for free by linking PublicationManagerCore, reading
//  the SAME shared store impel-core's TaskStoreApi writes (ADR-0001: same data,
//  different facet).
//
//  Stage 4c: this IS impel's window. The classic `ContentView` (a 312-line
//  NavigationSplitView that re-implemented the same routing) and the
//  `impel.useChassisWindow` flag are both gone. What that cost — the parity
//  gaps the flag was protecting — is closed HERE, and each close is labelled:
//
//    * SUGGESTIONS keyboard (⏎ accept / ⎋ dismiss): lived only in ContentView's
//      key handler, so the chassis had escalation keys but not suggestion ones.
//      `SuggestionsSurface` now owns them, the way `EscalationsSurface` owns
//      1-9 — and gains the j/k selection the classic window never showed.
//    * THREADS and the AGENT ROSTER: the chassis Agents section lists the SAME
//      `task@1.0.0` rows as `ThreadListView` (via `AgentStoreReader` rather
//      than `ImpelStoreAdapter`), with star/flag/tag and an Info/Source/View
//      detail pane the classic list had none of — but it renders them as tasks,
//      losing impel's temperature dot and `claimedBy` line, and it has no
//      surface for `ImpelClient.state.agents` / `.personas` at all. Both ride
//      along as custom surfaces over the UNCHANGED views, so nothing the
//      classic sidebar reached is unreachable now.
//    * ⌘/ KEYBOARD HELP: `KeyboardHelpView` was reachable only from
//      ContentView's own ⌘/ branch. It is now a menu command (ImpelApp) →
//      notification → the sheet below, i.e. reachable from the menu bar too.
//    * UNDO: `wireUndo(to: ImpelUndoCoordinator.shared)` was on ContentView
//      only, so `registerUndo` early-returned in the chassis window.
//    * CONNECTION / SYSTEM STATUS: the classic toolbar's two indicators.
//    * URL-SCHEME NAVIGATION: `impel://navigate/...` set a `DashboardTab` that
//      only ContentView observed. ImpelApp now posts
//      `.chassisNavigateToSurface` instead.
//
//  Surface context note: impel's `ImpelClient` and `MailGatewayState` are
//  app-root `@StateObject`s that ImpelApp injects as environment objects
//  into BOTH window roots, so the surfaces below read them via
//  `@EnvironmentObject` instead of a separate ImpelSurfaceContext singleton
//  — constructing fresh view models in a context object would fork state
//  from the classic window (empty dashboard). The makeView closures capture
//  nothing, so they stay `@Sendable`-clean.
//
//  Launch TCC hang avoidance (see ImprintChassisRoot), kept by
//  `ChassisRootView`: the shared store's first `open()` can block on a TCC
//  prompt / WAL lock, so it is warmed on a DETACHED background task before the
//  main-actor view models exist.
//
//  What stays impel's: the four custom surface descriptors and the surface views
//  below, including `EscalationsSurface`'s keyboard grammar.
//

import SwiftUI
import CounselEngine
import ImpelCore
import ImpressKeyboard
import ImpressKit
import PublicationManagerCore

extension Notification.Name {
    /// ⌘/ (menu command in ImpelApp) → the keyboard cheat sheet. A notification
    /// rather than app-root `@State` because a `Commands` builder cannot reach
    /// window content, and the sheet has to live in the window that has focus.
    static let impelShowKeyboardHelp = Notification.Name("impel.showKeyboardHelp")
}

/// impel's chassis root: the shared chassis (`TabContentView`) restricted to
/// the Agents facet, with Dashboard/Escalations/Suggestions/Counsel
/// registered as custom surfaces. Gated behind an off-main store warm-up so
/// the window never blocks on the shared store open.
struct ImpelChassisRoot: View {

    /// The impel shell: PMC's `.impel` preset (Agents section, detail-pane
    /// open behavior) EXTENDED app-side with the custom surfaces — the
    /// preset cannot hold app-target views (WP-X0 seam).
    /// Internal, not private, so `impelTests` can assert that every
    /// `impel://navigate/...` section names a surface that is actually
    /// REGISTERED — the failure mode of a string-keyed navigation seam is a URL
    /// that silently navigates nowhere, which is precisely what the old
    /// `DashboardTab` path did once the chassis became the default window.
    static let shellConfiguration: AppShellConfiguration =
        AppShellConfiguration.impel.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: "dashboard", title: "Dashboard", systemImage: "square.grid.2x2",
                makeView: { AnyView(DashboardSurface()) }),
            // Stage 4c: `ImpelClient`'s thread and agent/persona views. The
            // Agents SECTION next door reads the same task rows from the shared
            // store; these two read `ImpelClient.state`, keep impel's own row
            // chrome (temperature, claimedBy) and are the only home the persona
            // editors have ever had.
            CustomSurfaceDescriptor(
                id: "threads", title: "Threads", systemImage: "list.bullet",
                makeView: { AnyView(ThreadsSurface()) }),
            CustomSurfaceDescriptor(
                id: "roster", title: "Roster", systemImage: "person.3",
                makeView: { AnyView(RosterSurface()) }),
            CustomSurfaceDescriptor(
                id: "escalations", title: "Escalations",
                systemImage: "exclamationmark.circle",
                makeView: { AnyView(EscalationsSurface()) }),
            CustomSurfaceDescriptor(
                id: "suggestions", title: "Suggestions", systemImage: "lightbulb",
                makeView: { AnyView(SuggestionsSurface()) }),
            CustomSurfaceDescriptor(
                id: "counsel", title: "Counsel", systemImage: "envelope",
                makeView: { AnyView(CounselSurface()) }),
        ])

    /// Surface ids `impel://navigate/{section}` may target. Declared next to the
    /// registrations so a renamed surface breaks the URL map in one place
    /// instead of silently navigating nowhere.
    static let surfaceIDsByURLSection: [String: String] = [
        "dashboard": "dashboard",
        "threads": "threads",
        "agents": "roster",
        "escalations": "escalations",
        "suggestions": "suggestions",
        "counsel": "counsel",
    ]

    @EnvironmentObject private var client: ImpelClient
    @State private var showKeyboardHelp = false

    var body: some View {
        ChassisRootView(
            configuration: Self.shellConfiguration,
            readyLogMessage: "ImpelChassisRoot: chassis environment ready (Agents facet)")
            // Was on ContentView only: without it `ImpelUndoCoordinator`'s
            // `undoManager` stays nil and every `registerUndo` early-returns, so
            // counsel edits were silently un-undoable in this window.
            .wireUndo(to: ImpelUndoCoordinator.shared)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    connectionStatus
                    systemStatus
                }
            }
            .sheet(isPresented: $showKeyboardHelp) {
                KeyboardHelpView()
            }
            .onNotifications([
                (.impelShowKeyboardHelp, { _ in showKeyboardHelp = true }),
            ])
    }

    // MARK: - Toolbar indicators (moved verbatim from ContentView)

    private var connectionStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: client.isConnected)
    }

    private var systemStatus: some View {
        Group {
            if client.state.isPaused {
                Label("PAUSED", systemImage: "pause.circle.fill")
                    .foregroundColor(.orange)
            } else {
                Label("RUNNING", systemImage: "play.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .font(.caption)
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

        // Single-key navigation via the one shared catalog (TriageKeyGrammar).
        if press.modifiers.isEmpty {
            switch TriageKeyGrammar.command(forCharacters: press.characters) {
            case .navigateDown:
                selectedIndex = selectedIndex.map { min($0 + 1, escalations.count - 1) } ?? 0
                return .handled
            case .navigateUp:
                selectedIndex = selectedIndex.map { max($0 - 1, 0) } ?? 0
                return .handled
            default:
                // No other single-key command applies to the escalation list;
                // fall through to the numeric option keys below.
                break
            }
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
///
/// Stage 4c: the classic window's ⏎ (accept) / ⎋ (dismiss) keys lived in
/// `ContentView.handleKeyPress`, gated on a `selectedSuggestionIndex` that
/// `SuggestionListView` never rendered a highlight for — so the keys existed but
/// the user could not see what they would act on. They move here (the
/// `EscalationsSurface` shape), and the surface-local index now drives a REAL
/// `List` selection, which is a small honest improvement rather than a
/// reproduction of the invisible original.
struct SuggestionsSurface: View {
    @EnvironmentObject var client: ImpelClient
    @State private var selectedIndex: Int?

    var body: some View {
        SuggestionListView(suggestions: client.state.activeSuggestions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focusEffectDisabled()
            .keyboardGuarded { press in handleKey(press) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let suggestions = client.state.activeSuggestions
        guard !suggestions.isEmpty else { return .ignored }

        // Single-key navigation via the one shared catalog (TriageKeyGrammar).
        if press.modifiers.isEmpty {
            switch TriageKeyGrammar.command(forCharacters: press.characters) {
            case .navigateDown:
                selectedIndex = selectedIndex.map { min($0 + 1, suggestions.count - 1) } ?? 0
                return .handled
            case .navigateUp:
                selectedIndex = selectedIndex.map { max($0 - 1, 0) } ?? 0
                return .handled
            default:
                break
            }
        }

        guard let index = selectedIndex, index < suggestions.count else { return .ignored }
        let suggestion = suggestions[index]

        // ⏎ accepts the selected suggestion, ⎋ dismisses it (classic parity).
        if press.key == .return {
            Task { try? await client.executeSuggestion(suggestion) }
            return .handled
        }
        if press.key == .escape {
            client.dismissSuggestion(id: suggestion.id)
            return .handled
        }
        return .ignored
    }
}

/// impel's OWN thread list as a full-pane surface (`ImpelClient.state.threads`).
///
/// Not a duplicate of the Agents/Tasks section for a reason worth stating: both
/// read `task@1.0.0`, but through different handles and into different shapes.
/// The chassis maps rows to `TaskRowData` (star/flag/tag, Info/Source/View);
/// `ImpelStoreAdapter` maps them to `ResearchThread`, which is what carries
/// impel's derived `temperature` and `claimedBy`. Deleting this view to "avoid
/// duplication" would have deleted those two, which is a capability, not chrome.
struct ThreadsSurface: View {
    @EnvironmentObject var client: ImpelClient
    @State private var selectedThread: ResearchThread?

    var body: some View {
        ThreadListView(threads: client.state.threads, selectedThread: $selectedThread)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The agent roster and personas — a faithful port of the classic sidebar's
/// "Agents (n)" section, which offered "All Agents" plus one row per persona and
/// rendered `AgentListView` / `PersonaDetailView` in the detail column.
///
/// This is the one classic capability with NO chassis analogue: the Agents
/// section's Runs child lists `agent-run@1.0.0` provenance rows, not the live
/// agent roster (`AgentStatus`, `threadsCompleted`), and personas have no record
/// kind at all. `PersonaDetailView` also owns the counsel model picker and the
/// system-prompt editor, so losing it would have taken two editors with it.
struct RosterSurface: View {
    @EnvironmentObject var client: ImpelClient
    @State private var selection: RosterSelection = .allAgents

    /// Left-pane rows: the roster, then one row per persona.
    private enum RosterSelection: Hashable {
        case allAgents
        case persona(String)
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section("Agents (\(client.state.agents.count))") {
                    Label("All Agents", systemImage: "person.3")
                        .tag(RosterSelection.allAgents)
                }
                Section("Personas") {
                    ForEach(client.state.personas) { persona in
                        Label(persona.name, systemImage: persona.systemImage)
                            .tag(RosterSelection.persona(persona.id))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            .frame(maxHeight: .infinity)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // HSplitView does NOT fill like NavigationSplitView — the fill frame is
        // mandatory (impress-swiftui-pitfalls rule).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .allAgents:
            AgentListView(agents: client.state.agents)
        case .persona(let id):
            if let persona = client.state.personas.first(where: { $0.id == id }) {
                PersonaDetailView(persona: persona)
            } else {
                ContentUnavailableView(
                    "Persona Not Found",
                    systemImage: "person.crop.circle.badge.questionmark")
            }
        }
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
