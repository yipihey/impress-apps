// ImpelCore - Swift wrapper for impel-core Rust library
//
// This module provides a high-level Swift interface to the impel
// agent orchestration system for autonomous research teams.

import Foundation

// MARK: - Thread Types

/// State of a research thread
public enum ThreadState: String, Codable, CaseIterable, Sendable {
    case embryo = "embryo"
    case active = "active"
    case blocked = "blocked"
    case review = "review"
    case complete = "complete"
    case killed = "killed"

    public var displayName: String {
        switch self {
        case .embryo: return "Embryo"
        case .active: return "Active"
        case .blocked: return "Blocked"
        case .review: return "Review"
        case .complete: return "Complete"
        case .killed: return "Killed"
        }
    }

    public var isTerminal: Bool {
        self == .complete || self == .killed
    }

    public var systemImage: String {
        switch self {
        case .embryo: return "circle.dashed"
        case .active: return "play.circle.fill"
        case .blocked: return "pause.circle.fill"
        case .review: return "eye.circle.fill"
        case .complete: return "checkmark.circle.fill"
        case .killed: return "xmark.circle.fill"
        }
    }
}

/// A research thread being worked on by agents
public struct ResearchThread: Identifiable, Codable, Sendable {
    public let id: String
    public var title: String
    public var description: String
    public var state: ThreadState
    public var temperature: Double
    public var claimedBy: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var artifactCount: Int

    public init(
        id: String = UUID().uuidString,
        title: String,
        description: String = "",
        state: ThreadState = .embryo,
        temperature: Double = 0.5,
        claimedBy: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        artifactCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.state = state
        self.temperature = temperature
        self.claimedBy = claimedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.artifactCount = artifactCount
    }

    /// Temperature classification
    public var temperatureLevel: TemperatureLevel {
        if temperature >= 0.7 { return .hot }
        if temperature >= 0.3 { return .warm }
        return .cold
    }
}

/// Temperature classification for display
public enum TemperatureLevel: String, Sendable {
    case hot, warm, cold

    public var color: String {
        switch self {
        case .hot: return "red"
        case .warm: return "orange"
        case .cold: return "blue"
        }
    }
}

// MARK: - Agent Types

/// Type of agent in the system
public enum AgentType: String, Codable, CaseIterable, Sendable {
    case research = "research"
    case code = "code"
    case verification = "verification"
    case adversarial = "adversarial"
    case review = "review"
    case librarian = "librarian"

    public var displayName: String {
        switch self {
        case .research: return "Research"
        case .code: return "Code"
        case .verification: return "Verification"
        case .adversarial: return "Adversarial"
        case .review: return "Review"
        case .librarian: return "Librarian"
        }
    }

    public var systemImage: String {
        switch self {
        case .research: return "magnifyingglass"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .verification: return "checkmark.shield"
        case .adversarial: return "exclamationmark.triangle"
        case .review: return "eye"
        case .librarian: return "books.vertical"
        }
    }
}

/// Status of an agent
public enum AgentStatus: String, Codable, Sendable {
    case idle = "idle"
    case working = "working"
    case paused = "paused"
    case terminated = "terminated"

    public var displayName: String {
        rawValue.capitalized
    }
}

/// An agent in the system
public struct Agent: Identifiable, Codable, Sendable {
    public let id: String
    public var agentType: AgentType
    public var status: AgentStatus
    public var currentThread: String?
    public var registeredAt: Date
    public var lastActiveAt: Date
    public var threadsCompleted: Int

    public init(
        id: String,
        agentType: AgentType,
        status: AgentStatus = .idle,
        currentThread: String? = nil,
        registeredAt: Date = Date(),
        lastActiveAt: Date = Date(),
        threadsCompleted: Int = 0
    ) {
        self.id = id
        self.agentType = agentType
        self.status = status
        self.currentThread = currentThread
        self.registeredAt = registeredAt
        self.lastActiveAt = lastActiveAt
        self.threadsCompleted = threadsCompleted
    }
}

// MARK: - Escalation Types

/// Category of escalation requiring human attention
public enum EscalationCategory: String, Codable, CaseIterable, Sendable {
    case decision = "decision"
    case novelty = "novelty"
    case stuck = "stuck"
    case scope = "scope"
    case quality = "quality"
    case checkpoint = "checkpoint"

    public var displayName: String {
        switch self {
        case .decision: return "Decision Required"
        case .novelty: return "Novel Finding"
        case .stuck: return "Stuck"
        case .scope: return "Scope Change"
        case .quality: return "Quality Issue"
        case .checkpoint: return "Checkpoint"
        }
    }

    public var systemImage: String {
        switch self {
        case .decision: return "questionmark.circle"
        case .novelty: return "lightbulb"
        case .stuck: return "hand.raised"
        case .scope: return "arrow.up.left.and.arrow.down.right"
        case .quality: return "exclamationmark.triangle"
        case .checkpoint: return "flag"
        }
    }
}

/// Status of an escalation
public enum EscalationStatus: String, Codable, Sendable {
    case pending = "pending"
    case acknowledged = "acknowledged"
    case resolved = "resolved"
}

/// An escalation requiring human attention
public struct Escalation: Identifiable, Codable, Sendable {
    public let id: String
    public var category: EscalationCategory
    public var priority: Int
    public var status: EscalationStatus
    public var title: String
    public var description: String
    public var threadId: String?
    public var createdBy: String
    public var createdAt: Date
    public var options: [String]?

    public init(
        id: String = UUID().uuidString,
        category: EscalationCategory,
        priority: Int,
        status: EscalationStatus = .pending,
        title: String,
        description: String,
        threadId: String? = nil,
        createdBy: String,
        createdAt: Date = Date(),
        options: [String]? = nil
    ) {
        self.id = id
        self.category = category
        self.priority = priority
        self.status = status
        self.title = title
        self.description = description
        self.threadId = threadId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.options = options
    }
}

// MARK: - System State

/// Overall system state for the dashboard
public struct SystemState: Sendable {
    public var threads: [ResearchThread]
    public var agents: [Agent]
    public var escalations: [Escalation]
    public var isPaused: Bool
    public var lastUpdated: Date

    public init(
        threads: [ResearchThread] = [],
        agents: [Agent] = [],
        escalations: [Escalation] = [],
        isPaused: Bool = false,
        lastUpdated: Date = Date()
    ) {
        self.threads = threads
        self.agents = agents
        self.escalations = escalations
        self.isPaused = isPaused
        self.lastUpdated = lastUpdated
    }

    // MARK: - Computed Properties

    public var activeThreads: [ResearchThread] {
        threads.filter { $0.state == .active }
    }

    public var pendingEscalations: [Escalation] {
        escalations.filter { $0.status == .pending }
            .sorted { $0.priority > $1.priority }
    }

    public var workingAgents: [Agent] {
        agents.filter { $0.status == .working }
    }

    public var threadsByState: [ThreadState: [ResearchThread]] {
        Dictionary(grouping: threads, by: { $0.state })
    }
}

// MARK: - Impel Client

/// Client for connecting to an impel server
@MainActor
public class ImpelClient: ObservableObject {
    @Published public private(set) var state: SystemState
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var connectionError: String?

    private var serverURL: URL?
    private var refreshTask: Task<Void, Never>?

    public init() {
        self.state = SystemState()
    }

    /// Connect to an impel server
    public func connect(to url: URL) async {
        serverURL = url
        isConnected = false
        connectionError = nil

        // Start periodic refresh
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Disconnect from the server
    public func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        isConnected = false
        serverURL = nil
    }

    /// Refresh state from server
    public func refresh() async {
        guard let url = serverURL else { return }

        // TODO: Implement actual HTTP request to impel-server
        // For now, use mock data
        _ = url

        // Simulate successful connection with mock data
        state = Self.mockState()
        isConnected = true
        connectionError = nil
    }

    /// Load mock data for development/demo
    public func loadMockData() {
        state = Self.mockState()
        isConnected = true
    }

    // MARK: - Mock Data

    private static func mockState() -> SystemState {
        let threads = [
            ResearchThread(
                id: "thread-1",
                title: "Literature Review: LLM Reasoning",
                description: "Survey of recent advances in LLM reasoning capabilities",
                state: .active,
                temperature: 0.8,
                claimedBy: "research-1",
                artifactCount: 12
            ),
            ResearchThread(
                id: "thread-2",
                title: "Implement Evaluation Framework",
                description: "Build reproducible benchmark suite",
                state: .active,
                temperature: 0.6,
                claimedBy: "code-1",
                artifactCount: 5
            ),
            ResearchThread(
                id: "thread-3",
                title: "Verify Citation Claims",
                description: "Cross-check claims against source papers",
                state: .blocked,
                temperature: 0.4,
                artifactCount: 3
            ),
            ResearchThread(
                id: "thread-4",
                title: "Draft Introduction",
                description: "Write paper introduction section",
                state: .embryo,
                temperature: 0.3,
                artifactCount: 0
            ),
        ]

        let agents = [
            Agent(id: "research-1", agentType: .research, status: .working, currentThread: "thread-1", threadsCompleted: 5),
            Agent(id: "code-1", agentType: .code, status: .working, currentThread: "thread-2", threadsCompleted: 3),
            Agent(id: "verification-1", agentType: .verification, status: .idle, threadsCompleted: 8),
            Agent(id: "librarian-1", agentType: .librarian, status: .working, threadsCompleted: 12),
        ]

        let escalations = [
            Escalation(
                category: .decision,
                priority: 8,
                title: "Scope: Include multi-modal models?",
                description: "Should we expand the survey to cover vision-language models?",
                threadId: "thread-1",
                createdBy: "research-1",
                options: ["Yes, include VLMs", "No, focus on text-only", "Brief mention only"]
            ),
            Escalation(
                category: .novelty,
                priority: 6,
                title: "Unexpected correlation found",
                description: "Found strong correlation between model size and reasoning depth",
                threadId: "thread-1",
                createdBy: "research-1"
            ),
        ]

        return SystemState(
            threads: threads,
            agents: agents,
            escalations: escalations,
            isPaused: false,
            lastUpdated: Date()
        )
    }
}
