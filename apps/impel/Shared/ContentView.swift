import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine

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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
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

// MARK: - Counsel Gateway View

struct CounselGatewayView: View {
    @EnvironmentObject var mailGateway: MailGatewayState
    @State private var selectedThreadID: String?
    @State private var selectedConversationID: String?
    @State private var viewMode: CounselViewMode = .live
    @State private var searchQuery = ""

    enum CounselViewMode: String, CaseIterable {
        case live = "Live"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            counselStatusBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            // View mode picker
            Picker("View", selection: $viewMode) {
                ForEach(CounselViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            switch viewMode {
            case .live:
                liveView
            case .history:
                historyView
            }
        }
        .navigationTitle("Counsel Gateway")
    }

    // MARK: - Live View

    @ViewBuilder
    private var liveView: some View {
        if mailGateway.counselThreads.isEmpty && mailGateway.persistentConversations.isEmpty {
            counselEmptyState
        } else if mailGateway.counselThreads.isEmpty {
            ContentUnavailableView("No Active Requests", systemImage: "envelope.open",
                description: Text("Send an email to counsel@impress.local. Check History for past conversations."))
        } else {
            HSplitView {
                counselThreadList
                    .frame(minWidth: 280, idealWidth: 320)
                counselDetailView
                    .frame(minWidth: 350)
            }
        }
    }

    // MARK: - History View

    @ViewBuilder
    private var historyView: some View {
        let conversations = mailGateway.persistentConversations
        let filtered = searchQuery.isEmpty ? conversations : conversations.filter {
            $0.subject.localizedCaseInsensitiveContains(searchQuery) ||
            $0.participantEmail.localizedCaseInsensitiveContains(searchQuery)
        }

        if conversations.isEmpty {
            ContentUnavailableView("No Conversation History", systemImage: "clock",
                description: Text("Conversations will appear here after counsel processes your first request."))
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search conversations...", text: $searchQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))

                    List(filtered, id: \.id, selection: $selectedConversationID) { conv in
                        CounselConversationRow(conversation: conv)
                            .tag(conv.id)
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 280, idealWidth: 320)

                // Detail
                if let convID = selectedConversationID,
                   let conv = conversations.first(where: { $0.id == convID }) {
                    CounselConversationDetailView(conversation: conv)
                        .environmentObject(mailGateway)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Select a conversation")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Status Bar

    private var counselStatusBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(mailGateway.smtpRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("SMTP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(mailGateway.imapRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("IMAP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(mailGateway.totalMessages) messages")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !mailGateway.persistentConversations.isEmpty {
                Text("\(mailGateway.persistentConversations.count) conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("counsel@impress.local")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Thread List

    private var counselThreadList: some View {
        List(mailGateway.counselThreads, id: \.id, selection: $selectedThreadID) { thread in
            CounselThreadRow(thread: thread)
                .tag(thread.id)
        }
        .listStyle(.inset)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var counselDetailView: some View {
        if let threadID = selectedThreadID,
           let thread = mailGateway.counselThreads.first(where: { $0.id == threadID }) {
            CounselThreadDetailView(thread: thread)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Select a request to view details")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Empty State

    private var counselEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ContentUnavailableView(
                    "No Requests Yet",
                    systemImage: "envelope",
                    description: Text("Send an email to counsel@impress.local to get started.")
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Mail Client Setup")
                        .font(.headline)

                    Text("You are PI@impress.local. Counsel is your research assistant. Set up a mail account to correspond:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        counselSetupRow("Account Name", value: "impress (local)")
                        counselSetupRow("Your Address", value: "PI@impress.local")
                        counselSetupRow("Incoming (IMAP)", value: "localhost, port \(mailGateway.imapPort)")
                        counselSetupRow("Outgoing (SMTP)", value: "localhost, port \(mailGateway.smtpPort)")
                        counselSetupRow("Security", value: "None (localhost only)")
                        counselSetupRow("Authentication", value: "Any username/password")
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))

                    Text("Then compose a new message to **counsel@impress.local** — just like emailing a colleague.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Test")
                        .font(.headline)

                    Text("Send a test email via command line:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("""
                    python3 -c "
                    import smtplib
                    from email.message import EmailMessage
                    msg = EmailMessage()
                    msg['From'] = 'PI@impress.local'
                    msg['To'] = 'counsel@impress.local'
                    msg['Subject'] = 'Find papers on dark matter halos'
                    msg.set_content('Find the 3 most cited papers from 2024.')
                    with smtplib.SMTP('localhost', \(mailGateway.smtpPort)) as s:
                        s.send_message(msg)
                        print('Sent!')
                    "
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))
                    .textSelection(.enabled)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func counselSetupRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 160, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Counsel Conversation Row (History)

struct CounselConversationRow: View {
    let conversation: CounselConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.subject)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(conversation.status.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(.rect(cornerRadius: 3))
            }

            HStack(spacing: 8) {
                Text(conversation.participantEmail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if conversation.totalTokensUsed > 0 {
                    Text("\(conversation.totalTokensUsed) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("\(conversation.messageCount) msgs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(conversation.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch conversation.status {
        case .active: return .green
        case .archived: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - Counsel Conversation Detail View (History)

struct CounselConversationDetailView: View {
    let conversation: CounselConversation
    @EnvironmentObject var mailGateway: MailGatewayState
    @State private var messages: [CounselMessage] = []
    @State private var toolExecutions: [CounselToolExecution] = []
    @State private var showTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(conversation.subject)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        Label(conversation.participantEmail, systemImage: "person")
                        Label {
                            Text(conversation.createdAt, style: .date)
                        } icon: {
                            Image(systemName: "calendar")
                        }

                        Spacer()

                        if conversation.totalTokensUsed > 0 {
                            Label("\(conversation.totalTokensUsed) tokens", systemImage: "number")
                                .foregroundStyle(.secondary)
                        }

                        Text("\(conversation.messageCount) messages")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                // Tool execution toggle
                if !toolExecutions.isEmpty {
                    DisclosureGroup("Tool Executions (\(toolExecutions.count))", isExpanded: $showTools) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(toolExecutions, id: \.id) { exec in
                                CounselToolExecutionRow(execution: exec)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 8))
                }

                // Messages
                ForEach(messages, id: \.id) { message in
                    CounselMessageBubble(message: message)
                }
            }
            .padding()
        }
        .onAppear { loadData() }
        .onChange(of: conversation.id) { _, _ in loadData() }
    }

    private func loadData() {
        guard let engine = mailGateway.counselEngine else { return }
        messages = (try? engine.messages(for: conversation.id)) ?? []
        toolExecutions = (try? engine.toolExecutions(for: conversation.id)) ?? []
    }
}

// MARK: - Counsel Message Bubble

struct CounselMessageBubble: View {
    let message: CounselMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer() }

                Label(roleLabel, systemImage: roleIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if message.role != .user { Spacer() }
            }

            if message.role == .toolUse || message.role == .toolResult {
                Text(message.content.prefix(200))
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(backgroundColor)
                    .clipShape(.rect(cornerRadius: 8))
            }

            if message.tokenCount > 0 {
                Text("\(message.tokenCount) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "PI"
        case .assistant: return "Counsel"
        case .system: return "System"
        case .toolUse: return "Tool Call"
        case .toolResult: return "Tool Result"
        }
    }

    private var roleIcon: String {
        switch message.role {
        case .user: return "person"
        case .assistant: return "brain"
        case .system: return "gearshape"
        case .toolUse: return "wrench"
        case .toolResult: return "arrow.turn.down.left"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.blue.opacity(0.08)
        case .assistant: return Color.green.opacity(0.08)
        case .system: return Color.secondary.opacity(0.06)
        case .toolUse, .toolResult: return Color.secondary.opacity(0.06)
        }
    }
}

// MARK: - Counsel Tool Execution Row

struct CounselToolExecutionRow: View {
    let execution: CounselToolExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: execution.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(execution.isError ? .red : .green)
                    .font(.caption)

                Text(execution.toolName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))

                Spacer()

                Text("\(execution.durationMs)ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !execution.toolInput.isEmpty && execution.toolInput != "{}" {
                Text(execution.toolInput.prefix(100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(execution.isError ? Color.red.opacity(0.04) : Color.clear)
        .clipShape(.rect(cornerRadius: 4))
    }
}

// MARK: - Counsel Thread Row

struct CounselThreadRow: View {
    let thread: CounselThread

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.request.subject)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(thread.request.intent.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(.rect(cornerRadius: 3))

                    Text(thread.request.from)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(thread.status.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(thread.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch thread.status {
        case .received: return "envelope.badge"
        case .acknowledged: return "checkmark.circle"
        case .working: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch thread.status {
        case .received: return .blue
        case .acknowledged: return .orange
        case .working: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Counsel Thread Detail

struct CounselThreadDetailView: View {
    let thread: CounselThread

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(thread.request.subject)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        Label(thread.request.from, systemImage: "person")
                        Label {
                            Text(thread.request.date, style: .date)
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        Label(thread.request.intent.rawValue, systemImage: "tag")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(.rect(cornerRadius: 4))

                        Spacer()

                        Text(thread.status.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(statusColor.opacity(0.15))
                            .foregroundStyle(statusColor)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("Request", systemImage: "envelope")
                        .font(.headline)
                    Text(thread.request.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(.rect(cornerRadius: 8))
                }

                if thread.status != .received {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Acknowledged", systemImage: "checkmark.circle")
                            .font(.headline)
                        Text("Received your request. Working on it now.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }

                if let response = thread.response {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Response", systemImage: "text.bubble")
                            .font(.headline)
                        Text(response.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }

                if thread.status == .working {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Processing request...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if thread.status == .failed {
                    Label("This request failed to process.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private var statusColor: Color {
        switch thread.status {
        case .received: return .blue
        case .acknowledged: return .orange
        case .working: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    private enum SettingsTab: Hashable {
        case general
        case ai
        case counsel
    }

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            ImpelAISettingsTab()
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
                .tag(SettingsTab.ai)

            CounselSettingsTab()
                .tabItem {
                    Label("Counsel", systemImage: "envelope")
                }
                .tag(SettingsTab.counsel)
        }
        .frame(width: 550, height: 560)
    }
}

struct GeneralSettingsTab: View {
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
        .formStyle(.grouped)
    }
}

struct ImpelAISettingsTab: View {
    @EnvironmentObject var mailGateway: MailGatewayState
    @AppStorage("counselModel") private var modelName = ""
    @AppStorage("counselSystemPrompt") private var systemPrompt = ""
    @State private var engineAvailable = false

    var body: some View {
        Form {
            Section("Anthropic API") {
                HStack {
                    Text("Status")
                    Spacer()
                    if engineAvailable {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Configured", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Text("Counsel uses the Anthropic API directly for AI responses. Configure your API key in Settings > AI to enable counsel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                TextField("Model (default: sonnet)", text: $modelName)
                Text("The model identifier for the Anthropic API. Leave blank for the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 80)
                    .font(.system(.body, design: .monospaced))
                Text("Custom base system prompt for counsel. Leave blank to use the built-in research assistant prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            engineAvailable = mailGateway.counselEngine != nil
        }
    }
}

struct CounselSettingsTab: View {
    @EnvironmentObject var mailGateway: MailGatewayState
    @AppStorage("counselGatewayEnabled") private var counselEnabled = true
    @AppStorage("counselSMTPPort") private var smtpPort = 2525
    @AppStorage("counselIMAPPort") private var imapPort = 1143
    @AppStorage("counselMaxTurns") private var maxTurns = 15
    @AppStorage("counselPersistenceEnabled") private var persistenceEnabled = true

    var body: some View {
        Form {
            Section("Mail Gateway") {
                Toggle("Enable Mail Gateway", isOn: $counselEnabled)
            }

            Section("Ports") {
                TextField("SMTP Port", value: $smtpPort, format: IntegerFormatStyle<Int>().grouping(.never))
                TextField("IMAP Port", value: $imapPort, format: IntegerFormatStyle<Int>().grouping(.never))
            }

            Section("Agent Loop") {
                Stepper("Max Turns: \(maxTurns)", value: $maxTurns, in: 1...50)
                Text("Counsel uses the Anthropic API directly with tool use via HTTP bridges to sibling apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Persist Conversations", isOn: $persistenceEnabled)
                Text("When disabled, counsel still processes requests but does not store conversations, messages, or tool executions in the local database. Replies include List-Id and X-Counsel headers for auto-filing in your email client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Counsel Defaults

/// Non-isolated constants for the counsel persona, accessible from @Sendable contexts.
enum CounselDefaults {
    static let systemPrompt = """
        You are counsel, a research assistant integrated into the impress research environment. \
        You communicate with the user via email. Respond helpfully and concisely. \
        Format your response as a plain-text email reply.
        """

    static let defaultModel = "sonnet"
}

/// Available models for the counsel persona.
enum CounselModel: String, CaseIterable, Identifiable {
    case haiku = "haiku"
    case sonnet = "sonnet"
    case opus = "opus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku: return "Claude Haiku"
        case .sonnet: return "Claude Sonnet"
        case .opus: return "Claude Opus"
        }
    }

    var description: String {
        switch self {
        case .haiku: return "Fastest, most cost-efficient"
        case .sonnet: return "Balanced speed and intelligence"
        case .opus: return "Most capable, deepest reasoning"
        }
    }
}

// MARK: - Persona Detail View

struct PersonaDetailView: View {
    let persona: Persona
    @EnvironmentObject var mailGateway: MailGatewayState
    @AppStorage("counselSystemPrompt") private var counselSystemPrompt = ""
    @AppStorage("counselModel") private var counselModelRaw = CounselDefaults.defaultModel
    @State private var editedPrompt = ""
    @State private var hasLoaded = false
    @State private var expandedThreadID: String?
    @State private var showAllRequests = false

    private var isCounsel: Bool { persona.id == "counsel" }

    private var selectedModelDescription: String {
        CounselModel(rawValue: counselModelRaw)?.description ?? ""
    }

    /// The effective prompt: for counsel, use the persisted value; for others, show the persona's built-in prompt.
    private var effectivePrompt: String {
        if isCounsel {
            return counselSystemPrompt.isEmpty ? CounselDefaults.systemPrompt : counselSystemPrompt
        }
        return persona.systemPrompt
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: persona.systemImage)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(persona.name)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(persona.roleDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if persona.builtin {
                        Text("Built-in")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }

                Divider()

                // Metadata
                HStack(spacing: 24) {
                    metadataItem("Archetype", value: persona.archetype.displayName)
                    metadataItem("Working Style", value: persona.behavior.workingStyle.displayName)

                    if !isCounsel {
                        metadataItem("Model", value: persona.model.model)
                    }
                }

                // Model picker for counsel
                if isCounsel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model")
                            .font(.headline)

                        Picker("Model", selection: $counselModelRaw) {
                            ForEach(CounselModel.allCases) { model in
                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                }
                                .tag(model.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text(selectedModelDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // System Prompt
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("System Prompt")
                            .font(.headline)

                        Spacer()

                        if isCounsel && editedPrompt != CounselDefaults.systemPrompt {
                            Button("Reset to Default") {
                                editedPrompt = CounselDefaults.systemPrompt
                                counselSystemPrompt = ""
                            }
                            .controlSize(.small)
                        }
                    }

                    if isCounsel {
                        TextEditor(text: $editedPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 200)
                            .padding(8)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                            .onChange(of: editedPrompt) { _, newValue in
                                if newValue == CounselDefaults.systemPrompt {
                                    counselSystemPrompt = ""
                                } else {
                                    counselSystemPrompt = newValue
                                }
                            }
                    } else {
                        Text(persona.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }

                // Domain
                if !persona.domain.primaryDomains.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Domains")
                            .font(.headline)

                        FlowLayout(spacing: 6) {
                            ForEach(persona.domain.primaryDomains, id: \.self) { domain in
                                Text(domain)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.purple.opacity(0.12))
                                    .clipShape(.rect(cornerRadius: 4))
                            }
                        }
                    }
                }

                // Behavior Notes
                if !persona.behavior.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Behavior Notes")
                            .font(.headline)

                        ForEach(persona.behavior.notes, id: \.self) { note in
                            Label(note, systemImage: "circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .labelStyle(SmallBulletLabelStyle())
                        }
                    }
                }

                // Counsel request activity
                if isCounsel {
                    Divider()

                    counselActivitySection
                }
            }
            .padding()
        }
        .navigationTitle(persona.name)
        .onAppear {
            if !hasLoaded {
                editedPrompt = effectivePrompt
                hasLoaded = true
            }
        }
    }

    // MARK: - Counsel Activity

    @ViewBuilder
    private var counselActivitySection: some View {
        let threads = mailGateway.counselThreads
        let workingCount = threads.filter { $0.status == .working }.count
        let completedCount = threads.filter { $0.status == .completed }.count
        let failedCount = threads.filter { $0.status == .failed }.count

        // Stats bar
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Activity")
                .font(.headline)

            HStack(spacing: 16) {
                counselStatPill(
                    "\(threads.count)",
                    label: "total",
                    color: .secondary
                )

                if workingCount > 0 {
                    counselStatPill(
                        "\(workingCount)",
                        label: "working",
                        color: .purple,
                        pulse: true
                    )
                }

                counselStatPill(
                    "\(completedCount)",
                    label: "completed",
                    color: .green
                )

                if failedCount > 0 {
                    counselStatPill(
                        "\(failedCount)",
                        label: "failed",
                        color: .red
                    )
                }

                Spacer()
            }
        }

        // Recent requests
        if threads.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No requests yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Send an email to counsel@impress.local")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 24)
                Spacer()
            }
        } else {
            let visibleThreads = showAllRequests ? threads : Array(threads.prefix(20))

            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleThreads, id: \.id) { thread in
                    counselRequestRow(thread)
                }
            }
            .background(Color.secondary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))

            if threads.count > 20 && !showAllRequests {
                Button("Show all \(threads.count) requests") {
                    showAllRequests = true
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func counselStatPill(_ value: String, label: String, color: Color, pulse: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .clipShape(.rect(cornerRadius: 6))
        .symbolEffect(.pulse, isActive: pulse)
    }

    @ViewBuilder
    private func counselRequestRow(_ thread: CounselThread) -> some View {
        let isExpanded = expandedThreadID == thread.id

        VStack(alignment: .leading, spacing: 0) {
            // Row header — clickable
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedThreadID = isExpanded ? nil : thread.id
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: counselStatusIcon(thread.status))
                        .foregroundColor(counselStatusColor(thread.status))
                        .symbolEffect(.pulse, isActive: thread.status == .working)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.request.subject)
                            .font(.body)
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            Text(thread.request.intent.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.15))
                                .clipShape(.rect(cornerRadius: 3))

                            Text(thread.request.from)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(thread.status.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(thread.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded inline detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Request body
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Request", systemImage: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(thread.request.body)
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 6))
                    }

                    // Working spinner
                    if thread.status == .working {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Response body
                    if let response = thread.response {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Response", systemImage: "text.bubble")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(response.body)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.06))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                    }

                    // Failed state
                    if thread.status == .failed {
                        Label("This request failed to process.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if thread.id != mailGateway.counselThreads.last?.id {
                Divider()
                    .padding(.leading, 40)
            }
        }
    }

    private func counselStatusIcon(_ status: CounselThreadStatus) -> String {
        switch status {
        case .received: return "envelope.badge"
        case .acknowledged: return "checkmark.circle"
        case .working: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func counselStatusColor(_ status: CounselThreadStatus) -> Color {
        switch status {
        case .received: return .blue
        case .acknowledged: return .orange
        case .working: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func metadataItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
        }
    }
}

/// Simple bullet-point label style with a small dot.
private struct SmallBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// A simple flow layout for wrapping chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Preview

#Preview {
    ContentView(navigateToTab: .constant(nil))
        .environmentObject(ImpelClient())
        .environmentObject(MailGatewayState())
}

#Preview("Keyboard Help") {
    KeyboardHelpView()
}
