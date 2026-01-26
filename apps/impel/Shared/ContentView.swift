import SwiftUI
import ImpelCore

/// Main content view showing the impel dashboard
struct ContentView: View {
    @EnvironmentObject var client: ImpelClient

    @State private var selectedThread: ResearchThread?
    @State private var selectedTab: DashboardTab = .threads

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
        }
    }

    // MARK: - Toolbar Items

    private var connectionStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
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
}

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var client: ImpelClient

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
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
            }
            .padding()

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

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 36, weight: .bold))

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
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

            // Temperature indicator
            Circle()
                .fill(temperatureColor)
                .frame(width: 12, height: 12)
                .help("Temperature: \(String(format: "%.1f", thread.temperature))")
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
    let escalation: Escalation

    var body: some View {
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
                    .cornerRadius(4)
            }

            Text(escalation.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            if let options = escalation.options, !options.isEmpty {
                HStack {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            // TODO: Handle option selection
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var priorityColor: Color {
        if escalation.priority >= 8 { return .red }
        if escalation.priority >= 5 { return .orange }
        return .yellow
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

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ImpelClient())
}
