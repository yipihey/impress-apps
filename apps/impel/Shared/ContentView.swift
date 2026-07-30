import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

/// Main content view showing the impel dashboard
struct ContentView: View {
    @EnvironmentObject var client: ImpelClient
    @EnvironmentObject var mailGateway: MailGatewayState

    /// External navigation request (e.g. from URL scheme handler).
    @Binding var navigateToTab: DashboardTab?

    @State private var selectedThread: ResearchThread?
    @State private var selectedTab: DashboardTab = .threads
    @State private var selectedEscalationIndex: Int?
    @State private var selectedSuggestionIndex: Int?
    @State private var showKeyboardHelp = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                connectionStatus
                Spacer()
                systemStatus
            }
        }
        .wireUndo(to: ImpelUndoCoordinator.shared)
        .focusable()
        .focusEffectDisabled()
        .keyboardGuarded { press in
            handleKeyPress(press)
        }
        .sheet(isPresented: $showKeyboardHelp) {
            KeyboardHelpView()
        }
        .onChange(of: navigateToTab) { _, tab in
            if let tab {
                selectedTab = tab
                navigateToTab = nil
            }
        }
    }

    // MARK: - Keyboard Handling

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Single-key navigation via the one shared catalog (TriageKeyGrammar).
        if press.modifiers.isEmpty {
            switch TriageKeyGrammar.command(forCharacters: press.characters) {
            case .navigateDown:
                navigateDown()
                return .handled
            case .navigateUp:
                navigateUp()
                return .handled
            default:
                // impel's dashboard owns no other single-key command; fall
                // through so number/return/escape handling below still runs.
                break
            }
        }

        // Number keys for escalation options (1-4)
        if selectedTab == .escalations,
           let index = selectedEscalationIndex,
           index < client.state.pendingEscalations.count {
            let escalation = client.state.pendingEscalations[index]
            if let options = escalation.options {
                let keyNum = Int(press.characters) ?? 0
                if keyNum >= 1 && keyNum <= options.count {
                    resolveEscalation(escalation, optionIndex: keyNum - 1)
                    return .handled
                }
            }
        }

        // Enter to accept suggestion
        if press.key == .return && selectedTab == .suggestions,
           let index = selectedSuggestionIndex,
           index < client.state.activeSuggestions.count {
            let suggestion = client.state.activeSuggestions[index]
            Task { try? await client.executeSuggestion(suggestion) }
            return .handled
        }

        // Escape to dismiss
        if press.key == .escape {
            if selectedTab == .suggestions,
               let index = selectedSuggestionIndex,
               index < client.state.activeSuggestions.count {
                let suggestion = client.state.activeSuggestions[index]
                client.dismissSuggestion(id: suggestion.id)
                return .handled
            }
        }

        // ⌘/ for keyboard help — key taken from the shared ⌘-layer catalog
        // (UniversalShortcut.shortcutsHelp) instead of a hardcoded "/".
        if press.characters == String(UniversalShortcut.shortcutsHelp.key.character),
           press.modifiers.contains(.command) {
            showKeyboardHelp = true
            return .handled
        }

        // Cmd+R to refresh — app-local; no UniversalShortcut for refresh yet.
        if press.characters == "r" && press.modifiers.contains(.command) {
            Task { await client.refresh() }
            return .handled
        }

        return .ignored
    }

    private func navigateDown() {
        switch selectedTab {
        case .escalations:
            let count = client.state.pendingEscalations.count
            if count > 0 {
                if let current = selectedEscalationIndex {
                    selectedEscalationIndex = min(current + 1, count - 1)
                } else {
                    selectedEscalationIndex = 0
                }
            }
        case .suggestions:
            let count = client.state.activeSuggestions.count
            if count > 0 {
                if let current = selectedSuggestionIndex {
                    selectedSuggestionIndex = min(current + 1, count - 1)
                } else {
                    selectedSuggestionIndex = 0
                }
            }
        default:
            break
        }
    }

    private func navigateUp() {
        switch selectedTab {
        case .escalations:
            if let current = selectedEscalationIndex, current > 0 {
                selectedEscalationIndex = current - 1
            }
        case .suggestions:
            if let current = selectedSuggestionIndex, current > 0 {
                selectedSuggestionIndex = current - 1
            }
        default:
            break
        }
    }

    private func resolveEscalation(_ escalation: Escalation, optionIndex: Int) {
        guard let options = escalation.options, optionIndex < options.count else { return }
        Task {
            try? await client.resolveEscalation(
                id: escalation.id,
                optionIndex: optionIndex,
                optionLabel: options[optionIndex]
            )
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedTab) {
            Section("Overview") {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    .tag(DashboardTab.dashboard)
            }

            Section("Threads (\(client.state.threads.count))") {
                Label("All Threads", systemImage: "list.bullet")
                    .tag(DashboardTab.threads)

                ForEach(ThreadState.allCases.filter { !$0.isTerminal }, id: \.self) { state in
                    let count = client.state.threads.filter { $0.state == state }.count
                    if count > 0 {
                        Label("\(state.displayName) (\(count))", systemImage: state.systemImage)
                            .tag(DashboardTab.threadsByState(state))
                    }
                }
            }

            Section("Agents (\(client.state.agents.count))") {
                Label("All Agents", systemImage: "person.3")
                    .tag(DashboardTab.agents)

                ForEach(client.state.personas) { persona in
                    Label(persona.name, systemImage: persona.systemImage)
                        .tag(DashboardTab.persona(persona.id))
                }
            }

            Section("Escalations") {
                let pending = client.state.pendingEscalations.count
                Label("Pending (\(pending))", systemImage: "exclamationmark.circle")
                    .tag(DashboardTab.escalations)
                    .badge(pending)
            }

            Section("Suggestions") {
                let active = client.state.activeSuggestions.count
                Label("Proactive (\(active))", systemImage: "lightbulb")
                    .tag(DashboardTab.suggestions)
                    .badge(active)
            }

            Section("Counsel") {
                Label("Mail Gateway", systemImage: "envelope")
                    .tag(DashboardTab.counsel)
                    .badge(mailGateway.totalMessages)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .dashboard:
            DashboardView()
        case .threads:
            ThreadListView(threads: client.state.threads, selectedThread: $selectedThread)
        case .threadsByState(let state):
            ThreadListView(
                threads: client.state.threads.filter { $0.state == state },
                selectedThread: $selectedThread
            )
        case .agents:
            AgentListView(agents: client.state.agents)
        case .persona(let id):
            if let persona = client.state.personas.first(where: { $0.id == id }) {
                PersonaDetailView(persona: persona)
            } else {
                ContentUnavailableView("Persona Not Found", systemImage: "person.crop.circle.badge.questionmark")
            }
        case .escalations:
            EscalationListView(escalations: client.state.pendingEscalations)
        case .suggestions:
            SuggestionListView(suggestions: client.state.activeSuggestions)
        case .counsel:
            CounselGatewayView()
        }
    }

    // MARK: - Toolbar Items

    private var connectionStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .overlay {
                    if client.isConnected {
                        Circle()
                            .stroke(Color.green.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1.5)
                            .opacity(0)
                            .animation(
                                .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                                value: client.isConnected
                            )
                    }
                }
            Text(client.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: client.isConnected)
    }

    private var systemStatus: some View {
        HStack(spacing: 12) {
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

// MARK: - Dashboard Tab

enum DashboardTab: Hashable {
    case dashboard
    case threads
    case threadsByState(ThreadState)
    case agents
    case persona(String)
    case escalations
    case suggestions
    case counsel
}

// MARK: - Preview

#Preview {
    ContentView(navigateToTab: .constant(nil))
        .environmentObject(ImpelClient())
        .environmentObject(MailGatewayState())
}
