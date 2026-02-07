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
public struct ResearchThread: Identifiable, Codable, Sendable, Hashable {
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
    public var personas: [Persona]
    public var escalations: [Escalation]
    public var suggestions: [AgentSuggestion]
    public var isPaused: Bool
    public var lastUpdated: Date

    public init(
        threads: [ResearchThread] = [],
        agents: [Agent] = [],
        personas: [Persona] = [],
        escalations: [Escalation] = [],
        suggestions: [AgentSuggestion] = [],
        isPaused: Bool = false,
        lastUpdated: Date = Date()
    ) {
        self.threads = threads
        self.agents = agents
        self.personas = personas
        self.escalations = escalations
        self.suggestions = suggestions
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

    public var builtinPersonas: [Persona] {
        personas.filter { $0.builtin }
    }

    public var customPersonas: [Persona] {
        personas.filter { !$0.builtin }
    }

    /// Get persona by ID
    public func persona(id: String) -> Persona? {
        personas.first { $0.id == id }
    }

    /// Active (non-dismissed) suggestions sorted by confidence
    public var activeSuggestions: [AgentSuggestion] {
        suggestions
            .filter { !$0.isDismissed }
            .sorted { $0.confidence > $1.confidence }
    }

    /// High-confidence suggestions (>= 0.7)
    public var importantSuggestions: [AgentSuggestion] {
        activeSuggestions.filter { $0.confidence >= 0.7 }
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
    private let suggestionEngine = SuggestionEngine()

    /// Default impel server port
    public static let defaultPort = 23123

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

    /// Connect to localhost with default port
    public func connectToLocalhost() async {
        guard let url = URL(string: "http://127.0.0.1:\(Self.defaultPort)") else { return }
        await connect(to: url)
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

        // TODO: Implement actual HTTP requests to impel-server
        // For now, use mock data
        _ = url

        // Simulate successful connection with mock data
        var newState = Self.mockState()

        // Generate proactive suggestions based on current state
        let suggestions = await suggestionEngine.generateSuggestions(for: newState)
        newState.suggestions = suggestions

        state = newState
        isConnected = true
        connectionError = nil
    }

    /// Dismiss a suggestion
    public func dismissSuggestion(id: String) {
        if let index = state.suggestions.firstIndex(where: { $0.id == id }) {
            state.suggestions[index].isDismissed = true
        }
    }

    /// Execute a suggested action
    public func executeSuggestion(_ suggestion: AgentSuggestion) async throws {
        switch suggestion.action {
        case .assignThread(let threadId, let agentId):
            // In production, this would call the server to assign the thread
            if let threadIndex = state.threads.firstIndex(where: { $0.id == threadId }),
               let agentIndex = state.agents.firstIndex(where: { $0.id == agentId }) {
                state.threads[threadIndex].claimedBy = agentId
                state.agents[agentIndex].currentThread = threadId
                state.agents[agentIndex].status = .working
            }

        case .raiseTemperature(let threadId, let newTemp),
             .lowerTemperature(let threadId, let newTemp):
            if let index = state.threads.firstIndex(where: { $0.id == threadId }) {
                state.threads[index].temperature = newTemp
            }

        case .spawnAgent(let agentType, _):
            // In production, this would call the server to spawn an agent
            let newAgent = Agent(
                id: "\(agentType.rawValue)-\(UUID().uuidString.prefix(4))",
                agentType: agentType,
                status: .idle
            )
            state.agents.append(newAgent)

        case .resolveBlock(let threadId, _):
            // Navigate to the thread's escalation
            // This would trigger UI navigation in the view layer
            _ = threadId

        case .viewDetails:
            // This would trigger UI navigation
            break
        }

        // Mark suggestion as dismissed after execution
        dismissSuggestion(id: suggestion.id)
    }

    /// Fetch personas from server
    public func fetchPersonas() async throws -> [Persona] {
        guard let url = serverURL else {
            return Persona.mockPersonas()
        }

        let personasURL = url.appendingPathComponent("personas")
        let (data, _) = try await URLSession.shared.data(from: personasURL)

        struct PersonasResponse: Decodable {
            let personas: [PersonaSummary]
        }

        // For now, return mock data since we need the full persona detail
        // In production, this would fetch from /personas and then
        // fetch each persona's details from /personas/{id}
        _ = data
        return Persona.mockPersonas()
    }

    /// Fetch a specific persona by ID
    public func fetchPersona(id: String) async throws -> Persona? {
        guard let url = serverURL else {
            return Persona.mockPersonas().first { $0.id == id }
        }

        let personaURL = url.appendingPathComponent("personas").appendingPathComponent(id)
        let (data, response) = try await URLSession.shared.data(from: personaURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        return try JSONDecoder().decode(Persona.self, from: data)
    }

    /// Load mock data for development/demo
    public func loadMockData() async {
        var mockState = Self.mockState()
        let suggestions = await suggestionEngine.generateSuggestions(for: mockState)
        mockState.suggestions = suggestions
        state = mockState
        isConnected = true
    }

    // MARK: - State Mutations (for HTTP API)

    /// Append a new thread to the state.
    public func appendThread(_ thread: ResearchThread) {
        state.threads.append(thread)
    }

    /// Mutate a thread by ID. Returns true if found.
    @discardableResult
    public func mutateThread(id: String, _ mutation: (inout ResearchThread) -> Void) -> Bool {
        if let idx = state.threads.firstIndex(where: { $0.id == id }) {
            mutation(&state.threads[idx])
            return true
        }
        return false
    }

    /// Append a new agent to the state.
    public func appendAgent(_ agent: Agent) {
        state.agents.append(agent)
    }

    /// Mutate an agent by ID. Returns true if found.
    @discardableResult
    public func mutateAgent(id: String, _ mutation: (inout Agent) -> Void) -> Bool {
        if let idx = state.agents.firstIndex(where: { $0.id == id }) {
            mutation(&state.agents[idx])
            return true
        }
        return false
    }

    /// Append a new escalation to the state.
    public func appendEscalation(_ escalation: Escalation) {
        state.escalations.append(escalation)
    }

    /// Mutate an escalation by ID. Returns true if found.
    @discardableResult
    public func mutateEscalation(id: String, _ mutation: (inout Escalation) -> Void) -> Bool {
        if let idx = state.escalations.firstIndex(where: { $0.id == id }) {
            mutation(&state.escalations[idx])
            return true
        }
        return false
    }

    // MARK: - Escalation Actions

    /// Resolve an escalation by selecting an option
    /// - Parameters:
    ///   - escalationId: The ID of the escalation to resolve
    ///   - optionIndex: The 0-based index of the selected option
    ///   - optionLabel: The label of the selected option (used as resolution text)
    public func resolveEscalation(id escalationId: String, optionIndex: Int, optionLabel: String) async throws {
        guard let url = serverURL else {
            throw ImpelClientError.notConnected
        }

        let resolveURL = url.appendingPathComponent("escalations/\(escalationId)/resolve")

        var request = URLRequest(url: resolveURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "by": "user",
            "resolution": optionLabel,
            "selected_option": optionIndex
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImpelClientError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ImpelClientError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        // Remove from local state immediately for responsive UI
        if let index = state.escalations.firstIndex(where: { $0.id == escalationId }) {
            state.escalations[index].status = .resolved
        }
    }

    /// Acknowledge an escalation
    public func acknowledgeEscalation(id escalationId: String) async throws {
        guard let url = serverURL else {
            throw ImpelClientError.notConnected
        }

        let ackURL = url.appendingPathComponent("escalations/\(escalationId)/acknowledge")

        var request = URLRequest(url: ackURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["by": "user"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImpelClientError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ImpelClientError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        // Update local state
        if let index = state.escalations.firstIndex(where: { $0.id == escalationId }) {
            state.escalations[index].status = .acknowledged
        }
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
            personas: Persona.mockPersonas(),
            escalations: escalations,
            isPaused: false,
            lastUpdated: Date()
        )
    }
}

// MARK: - Errors

public enum ImpelClientError: LocalizedError {
    case notConnected
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to impel server"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

// MARK: - Proactive Suggestions

/// Category of proactive suggestion
public enum SuggestionCategory: String, Codable, CaseIterable, Sendable {
    case threadAssignment = "thread_assignment"
    case threadPriority = "thread_priority"
    case agentSpawn = "agent_spawn"
    case workflowOptimization = "workflow_optimization"
    case blockResolution = "block_resolution"

    public var displayName: String {
        switch self {
        case .threadAssignment: return "Thread Assignment"
        case .threadPriority: return "Priority Change"
        case .agentSpawn: return "Spawn Agent"
        case .workflowOptimization: return "Workflow Tip"
        case .blockResolution: return "Resolve Block"
        }
    }

    public var systemImage: String {
        switch self {
        case .threadAssignment: return "arrow.right.circle"
        case .threadPriority: return "flame"
        case .agentSpawn: return "plus.circle"
        case .workflowOptimization: return "lightbulb"
        case .blockResolution: return "hand.point.right"
        }
    }
}

/// A proactive suggestion for the user
public struct AgentSuggestion: Identifiable, Codable, Sendable {
    public let id: String
    public let category: SuggestionCategory
    public let title: String
    public let reason: String
    public let confidence: Double
    public let threadId: String?
    public let agentId: String?
    public let action: SuggestedAction
    public let createdAt: Date
    public var isDismissed: Bool

    public init(
        id: String = UUID().uuidString,
        category: SuggestionCategory,
        title: String,
        reason: String,
        confidence: Double,
        threadId: String? = nil,
        agentId: String? = nil,
        action: SuggestedAction,
        createdAt: Date = Date(),
        isDismissed: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.reason = reason
        self.confidence = confidence
        self.threadId = threadId
        self.agentId = agentId
        self.action = action
        self.createdAt = createdAt
        self.isDismissed = isDismissed
    }
}

/// An action that can be taken on a suggestion
public enum SuggestedAction: Codable, Sendable {
    case assignThread(threadId: String, agentId: String)
    case raiseTemperature(threadId: String, newTemperature: Double)
    case lowerTemperature(threadId: String, newTemperature: Double)
    case spawnAgent(agentType: AgentType, forThread: String?)
    case resolveBlock(threadId: String, hint: String)
    case viewDetails(resourceType: String, resourceId: String)

    public var buttonLabel: String {
        switch self {
        case .assignThread: return "Assign"
        case .raiseTemperature: return "Raise Priority"
        case .lowerTemperature: return "Lower Priority"
        case .spawnAgent: return "Spawn"
        case .resolveBlock: return "Investigate"
        case .viewDetails: return "View"
        }
    }
}

// MARK: - Suggestion Engine

/// Engine for generating proactive suggestions
public actor SuggestionEngine {

    /// Generate suggestions based on current system state
    public func generateSuggestions(for state: SystemState) -> [AgentSuggestion] {
        var suggestions: [AgentSuggestion] = []

        // 1. Idle agents + unassigned hot threads
        suggestions.append(contentsOf: suggestThreadAssignments(state))

        // 2. Blocked threads with idle agents that could help
        suggestions.append(contentsOf: suggestBlockResolutions(state))

        // 3. Priority adjustments based on activity patterns
        suggestions.append(contentsOf: suggestPriorityChanges(state))

        // 4. Agent spawn suggestions for backlogged work
        suggestions.append(contentsOf: suggestAgentSpawns(state))

        // Sort by confidence and limit
        return suggestions
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Private Suggestion Generators

    private func suggestThreadAssignments(_ state: SystemState) -> [AgentSuggestion] {
        var suggestions: [AgentSuggestion] = []

        // Find idle agents
        let idleAgents = state.agents.filter { $0.status == .idle }

        // Find unassigned hot threads
        let unassignedHotThreads = state.threads.filter {
            $0.claimedBy == nil && $0.temperature >= 0.6 && !$0.state.isTerminal
        }

        for thread in unassignedHotThreads {
            // Find a matching idle agent
            let matchingAgent = idleAgents.first { agent in
                // Match agent type to thread needs (simplified heuristic)
                switch thread.state {
                case .embryo:
                    return agent.agentType == .research
                case .active:
                    return agent.agentType == .code || agent.agentType == .research
                case .review:
                    return agent.agentType == .review || agent.agentType == .verification
                case .blocked:
                    return agent.agentType == .adversarial
                default:
                    return false
                }
            }

            if let agent = matchingAgent {
                let confidence = thread.temperature * 0.8 + 0.2
                suggestions.append(AgentSuggestion(
                    category: .threadAssignment,
                    title: "Assign \(agent.agentType.displayName) to \"\(thread.title)\"",
                    reason: "Thread is hot (\(Int(thread.temperature * 100))%) and \(agent.id) is idle",
                    confidence: confidence,
                    threadId: thread.id,
                    agentId: agent.id,
                    action: .assignThread(threadId: thread.id, agentId: agent.id)
                ))
            }
        }

        return suggestions
    }

    private func suggestBlockResolutions(_ state: SystemState) -> [AgentSuggestion] {
        var suggestions: [AgentSuggestion] = []

        let blockedThreads = state.threads.filter { $0.state == .blocked }

        for thread in blockedThreads {
            // Check if there's a pending escalation for this thread
            let hasEscalation = state.escalations.contains {
                $0.threadId == thread.id && $0.status == .pending
            }

            if hasEscalation {
                suggestions.append(AgentSuggestion(
                    category: .blockResolution,
                    title: "Resolve block on \"\(thread.title)\"",
                    reason: "Thread is blocked with pending escalation",
                    confidence: 0.9,
                    threadId: thread.id,
                    action: .resolveBlock(threadId: thread.id, hint: "Review pending escalation")
                ))
            }
        }

        return suggestions
    }

    private func suggestPriorityChanges(_ state: SystemState) -> [AgentSuggestion] {
        var suggestions: [AgentSuggestion] = []

        // Suggest raising priority for stale active threads
        let staleActiveThreads = state.threads.filter {
            $0.state == .active &&
            $0.temperature < 0.5 &&
            $0.updatedAt.timeIntervalSinceNow < -3600 // Stale for > 1 hour
        }

        for thread in staleActiveThreads {
            suggestions.append(AgentSuggestion(
                category: .threadPriority,
                title: "Raise priority of \"\(thread.title)\"",
                reason: "Active thread with low priority hasn't progressed recently",
                confidence: 0.7,
                threadId: thread.id,
                action: .raiseTemperature(threadId: thread.id, newTemperature: 0.7)
            ))
        }

        // Suggest lowering priority for too many hot threads
        let hotThreads = state.threads.filter { $0.temperature >= 0.7 && !$0.state.isTerminal }
        if hotThreads.count > 3 {
            // Suggest lowering the least recently updated hot thread
            if let coldestHot = hotThreads.sorted(by: { $0.updatedAt < $1.updatedAt }).first {
                suggestions.append(AgentSuggestion(
                    category: .threadPriority,
                    title: "Lower priority of \"\(coldestHot.title)\"",
                    reason: "Too many hot threads (\(hotThreads.count)) - focus efforts",
                    confidence: 0.65,
                    threadId: coldestHot.id,
                    action: .lowerTemperature(threadId: coldestHot.id, newTemperature: 0.5)
                ))
            }
        }

        return suggestions
    }

    private func suggestAgentSpawns(_ state: SystemState) -> [AgentSuggestion] {
        var suggestions: [AgentSuggestion] = []

        // Count agents by type
        let agentsByType = Dictionary(grouping: state.agents, by: { $0.agentType })

        // Check for bottlenecks
        let activeResearchThreads = state.threads.filter {
            $0.state == .active && $0.claimedBy != nil
        }
        let researchAgents = agentsByType[.research]?.count ?? 0

        if activeResearchThreads.count > researchAgents * 2 {
            suggestions.append(AgentSuggestion(
                category: .agentSpawn,
                title: "Spawn additional Research agent",
                reason: "\(activeResearchThreads.count) active research threads with only \(researchAgents) research agents",
                confidence: 0.75,
                action: .spawnAgent(agentType: .research, forThread: nil)
            ))
        }

        // Suggest verification agent if many threads pending review
        let reviewThreads = state.threads.filter { $0.state == .review }
        let verificationAgents = agentsByType[.verification]?.count ?? 0

        if reviewThreads.count >= 2 && verificationAgents == 0 {
            suggestions.append(AgentSuggestion(
                category: .agentSpawn,
                title: "Spawn Verification agent",
                reason: "\(reviewThreads.count) threads pending review with no verification agents",
                confidence: 0.8,
                action: .spawnAgent(agentType: .verification, forThread: reviewThreads.first?.id)
            ))
        }

        return suggestions
    }
}
