import SwiftUI
import ImpelCore

/// Main content view showing the impel dashboard
struct ContentView: View {
    @EnvironmentObject var client: ImpelClient

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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            handleKeyPress(press)
        }
        .sheet(isPresented: $showKeyboardHelp) {
            KeyboardHelpView()
        }
    }

    // MARK: - Keyboard Handling

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // j/k navigation
        if press.characters == "j" && press.modifiers.isEmpty {
            navigateDown()
            return .handled
        }
        if press.characters == "k" && press.modifiers.isEmpty {
            navigateUp()
            return .handled
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

        // Cmd+/ for keyboard help
        if press.characters == "/" && press.modifiers.contains(.command) {
            showKeyboardHelp = true
            return .handled
        }

        // Cmd+R to refresh
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
        case .escalations:
            EscalationListView(escalations: client.state.pendingEscalations)
        case .suggestions:
            SuggestionListView(suggestions: client.state.activeSuggestions)
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
    case escalations
    case suggestions
}

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var client: ImpelClient

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                // Thread stats
                StatCard(
                    title: "Active Threads",
                    value: "\(client.state.activeThreads.count)",
                    icon: "play.circle.fill",
                    color: .green
                )

                StatCard(
                    title: "Working Agents",
                    value: "\(client.state.workingAgents.count)",
                    icon: "person.fill",
                    color: .blue
                )

                StatCard(
                    title: "Pending Escalations",
                    value: "\(client.state.pendingEscalations.count)",
                    icon: "exclamationmark.circle.fill",
                    color: .orange
                )

                StatCard(
                    title: "Suggestions",
                    value: "\(client.state.activeSuggestions.count)",
                    icon: "lightbulb.fill",
                    color: .purple
                )
            }
            .padding()

            // Proactive suggestions (show important ones on dashboard)
            if !client.state.importantSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Proactive Suggestions")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal)

                    ForEach(client.state.importantSuggestions.prefix(3)) { suggestion in
                        SuggestionRow(suggestion: suggestion)
                            .padding(.horizontal)
                    }
                }
                .padding(.bottom, 8)
            }

            // Recent escalations
            if !client.state.pendingEscalations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Escalations")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(client.state.pendingEscalations.prefix(3)) { escalation in
                        EscalationRow(escalation: escalation)
                            .padding(.horizontal)
                    }
                }
            }

            // Hot threads
            let hotThreads = client.state.threads
                .filter { $0.temperatureLevel == .hot }
                .sorted { $0.temperature > $1.temperature }

            if !hotThreads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hot Threads")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(hotThreads.prefix(5)) { thread in
                        ThreadRow(thread: thread)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(color)
                .symbolEffect(.bounce, value: value)

            Text(value)
                .font(.system(size: 36, weight: .bold))
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                appeared = true
            }
        }
    }
}

// MARK: - Thread List View

struct ThreadListView: View {
    let threads: [ResearchThread]
    @Binding var selectedThread: ResearchThread?

    var body: some View {
        List(threads, selection: $selectedThread) { thread in
            ThreadRow(thread: thread)
                .tag(thread)
        }
        .navigationTitle("Threads")
    }
}

struct ThreadRow: View {
    let thread: ResearchThread

    var body: some View {
        HStack {
            Image(systemName: thread.state.systemImage)
                .foregroundColor(stateColor)
                .symbolEffect(.pulse, isActive: thread.state == .active)

            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(thread.state.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let agent = thread.claimedBy {
                        Text("• \(agent)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Temperature indicator with glow for hot threads
            Circle()
                .fill(temperatureColor)
                .frame(width: 12, height: 12)
                .overlay {
                    if thread.temperatureLevel == .hot {
                        Circle()
                            .fill(temperatureColor.opacity(0.5))
                            .frame(width: 18, height: 18)
                            .blur(radius: 4)
                    }
                }
                .help("Temperature: \(String(format: "%.1f", thread.temperature))")
                .animation(.easeInOut(duration: 0.3), value: thread.temperatureLevel)
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch thread.state {
        case .active: return .green
        case .blocked: return .orange
        case .review: return .blue
        case .complete: return .gray
        case .killed: return .red
        case .embryo: return .secondary
        }
    }

    private var temperatureColor: Color {
        switch thread.temperatureLevel {
        case .hot: return .red
        case .warm: return .orange
        case .cold: return .blue
        }
    }
}

// MARK: - Agent List View

struct AgentListView: View {
    let agents: [Agent]

    var body: some View {
        List(agents) { agent in
            HStack {
                Image(systemName: agent.agentType.systemImage)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.id)
                        .font(.headline)

                    Text(agent.agentType.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(agent.status.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor(agent.status).opacity(0.2))
                    .cornerRadius(4)

                Text("\(agent.threadsCompleted)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Agents")
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return .green
        case .idle: return .blue
        case .paused: return .orange
        case .terminated: return .red
        }
    }
}

// MARK: - Escalation List View

struct EscalationListView: View {
    let escalations: [Escalation]

    var body: some View {
        List(escalations) { escalation in
            EscalationRow(escalation: escalation)
        }
        .navigationTitle("Escalations")
    }
}

struct EscalationRow: View {
    @EnvironmentObject var client: ImpelClient
    let escalation: Escalation
    @State private var isResolving = false
    @State private var isResolved = false
    @State private var errorMessage: String?
    @State private var shakeCount = 0

    var body: some View {
        ZStack {
            // Success overlay
            if isResolved {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: isResolved)
                    Spacer()
                }
                .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: escalation.category.systemImage)
                        .foregroundColor(.orange)

                    Text(escalation.title)
                        .font(.headline)

                    Spacer()

                    Text("P\(escalation.priority)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priorityColor.opacity(0.2))
                        .clipShape(.rect(cornerRadius: 4))
                }

                Text(escalation.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if let options = escalation.options, !options.isEmpty {
                    HStack {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            Button(option) {
                                resolveWithOption(index: index, label: option)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isResolving || isResolved)
                        }

                        if isResolving {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .opacity(isResolved ? 0.3 : 1)
        }
        .padding(.vertical, 4)
        .modifier(ShakeEffect(shakes: shakeCount))
        .animation(.default, value: isResolved)
    }

    private func resolveWithOption(index: Int, label: String) {
        let escalationId = escalation.id
        isResolving = true
        errorMessage = nil

        Task {
            do {
                try await client.resolveEscalation(id: escalationId, optionIndex: index, optionLabel: label)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isResolved = true
                }
            } catch {
                errorMessage = error.localizedDescription
                // Shake on error
                withAnimation(.default) {
                    shakeCount += 1
                }
            }
            isResolving = false
        }
    }

    private var priorityColor: Color {
        if escalation.priority >= 8 { return .red }
        if escalation.priority >= 5 { return .orange }
        return .yellow
    }
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var shakes: Int
    var animatableData: CGFloat {
        get { CGFloat(shakes) }
        set { shakes = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(animatableData * .pi * 4) * 6
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - Suggestion List View

struct SuggestionListView: View {
    let suggestions: [AgentSuggestion]

    var body: some View {
        List(suggestions) { suggestion in
            SuggestionRow(suggestion: suggestion)
        }
        .navigationTitle("Suggestions")
        .overlay {
            if suggestions.isEmpty {
                ContentUnavailableView(
                    "No Suggestions",
                    systemImage: "lightbulb",
                    description: Text("The system will suggest actions based on current activity.")
                )
            }
        }
    }
}

struct SuggestionRow: View {
    @EnvironmentObject var client: ImpelClient
    let suggestion: AgentSuggestion
    @State private var isExecuting = false
    @State private var isExecuted = false
    @State private var errorMessage: String?
    @State private var shakeCount = 0

    var body: some View {
        ZStack {
            // Success overlay
            if isExecuted {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(.purple)
                            .symbolEffect(.bounce, value: isExecuted)
                        Text("Running...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: suggestion.category.systemImage)
                        .foregroundColor(.purple)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(.headline)

                        Text(suggestion.category.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Confidence badge
                    Text("\(Int(suggestion.confidence * 100))%")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(confidenceColor.opacity(0.2))
                        .foregroundColor(confidenceColor)
                        .clipShape(.rect(cornerRadius: 4))
                }

                Text(suggestion.reason)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    Button {
                        executeAction()
                    } label: {
                        HStack(spacing: 4) {
                            if isExecuting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(suggestion.action.buttonLabel)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .disabled(isExecuting || isExecuted)

                    Button("Dismiss") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            client.dismissSuggestion(id: suggestion.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExecuted)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .opacity(isExecuted ? 0.3 : 1)
        }
        .padding(.vertical, 4)
        .modifier(ShakeEffect(shakes: shakeCount))
        .animation(.default, value: isExecuted)
    }

    private func executeAction() {
        isExecuting = true
        errorMessage = nil

        Task {
            do {
                try await client.executeSuggestion(suggestion)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isExecuted = true
                }
            } catch {
                errorMessage = error.localizedDescription
                withAnimation(.default) {
                    shakeCount += 1
                }
            }
            isExecuting = false
        }
    }

    private var confidenceColor: Color {
        if suggestion.confidence >= 0.8 { return .green }
        if suggestion.confidence >= 0.6 { return .orange }
        return .secondary
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = "http://localhost:3000"
    @AppStorage("refreshInterval") private var refreshInterval = 2.0

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
            }

            Section("Display") {
                Slider(value: $refreshInterval, in: 1...10, step: 1) {
                    Text("Refresh Interval: \(Int(refreshInterval))s")
                }
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Keyboard Help View

struct KeyboardHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                shortcutSection("Navigation", shortcuts: [
                    ("j", "Move down"),
                    ("k", "Move up"),
                ])

                shortcutSection("Escalations", shortcuts: [
                    ("1-4", "Select option"),
                ])

                shortcutSection("Suggestions", shortcuts: [
                    ("↩", "Accept suggestion"),
                    ("⎋", "Dismiss suggestion"),
                ])

                shortcutSection("App", shortcuts: [
                    ("⌘R", "Refresh"),
                    ("⌘/", "Show this help"),
                ])
            }

            Spacer()
        }
        .padding()
        .frame(width: 350, height: 400)
    }

    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(shortcuts, id: \.0) { key, action in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .frame(width: 60, alignment: .center)

                    Text(action)
                        .foregroundStyle(.primary)

                    Spacer()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ImpelClient())
}

#Preview("Keyboard Help") {
    KeyboardHelpView()
}
