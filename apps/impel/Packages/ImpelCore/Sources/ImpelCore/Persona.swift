// Persona.swift - Persona types for agent behavioral configuration
//
// Personas provide rich behavioral configuration for agents, superseding
// the simpler AgentType with role descriptions, model configuration,
// tool access policies, and domain-specific prompting.

import Foundation

// MARK: - Working Style

/// Working style preferences for a persona
public enum WorkingStyle: String, Codable, CaseIterable, Sendable {
    /// Fast iterations, prototype-oriented
    case rapid
    /// Balance between speed and thoroughness
    case balanced
    /// Methodical, thorough, documentation-heavy
    case methodical
    /// Deep analysis before action
    case analytical

    public var displayName: String {
        switch self {
        case .rapid: return "Rapid"
        case .balanced: return "Balanced"
        case .methodical: return "Methodical"
        case .analytical: return "Analytical"
        }
    }

    public var description: String {
        switch self {
        case .rapid: return "Fast iterations, prototype-oriented"
        case .balanced: return "Balance between speed and thoroughness"
        case .methodical: return "Methodical, thorough, documentation-heavy"
        case .analytical: return "Deep analysis before action"
        }
    }
}

// MARK: - Tool Access

/// Access level for a tool
public enum ToolAccess: String, Codable, CaseIterable, Sendable {
    case none
    case read
    case readWrite = "read_write"
    case full

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .read: return "Read"
        case .readWrite: return "Read/Write"
        case .full: return "Full"
        }
    }

    public var canRead: Bool {
        self != .none
    }

    public var canWrite: Bool {
        self == .readWrite || self == .full
    }

    public var canExecute: Bool {
        self == .full
    }
}

// MARK: - Tool Policy

/// Policy for a specific tool
public struct ToolPolicy: Codable, Sendable {
    public let tool: String
    public let access: ToolAccess
    public let scope: [String]
    public let notes: String?

    public init(
        tool: String,
        access: ToolAccess,
        scope: [String] = [],
        notes: String? = nil
    ) {
        self.tool = tool
        self.access = access
        self.scope = scope
        self.notes = notes
    }
}

// MARK: - Tool Policy Set

/// Collection of tool policies for a persona
public struct ToolPolicySet: Codable, Sendable {
    public let policies: [ToolPolicy]
    public let defaultAccess: ToolAccess

    public init(
        policies: [ToolPolicy] = [],
        defaultAccess: ToolAccess = .none
    ) {
        self.policies = policies
        self.defaultAccess = defaultAccess
    }

    enum CodingKeys: String, CodingKey {
        case policies
        case defaultAccess = "default_access"
    }

    /// Get policy for a specific tool
    public func policy(for tool: String) -> ToolPolicy? {
        policies.first { $0.tool == tool }
    }

    /// Check if tool can be accessed
    public func canAccess(_ tool: String) -> Bool {
        policy(for: tool)?.access.canRead ?? defaultAccess.canRead
    }

    /// Check if tool can be written to
    public func canWrite(_ tool: String) -> Bool {
        policy(for: tool)?.access.canWrite ?? defaultAccess.canWrite
    }
}

// MARK: - Persona Behavior

/// Behavioral traits that shape how a persona approaches tasks
public struct PersonaBehavior: Codable, Sendable {
    /// How verbose should responses be (0.0 = terse, 1.0 = comprehensive)
    public let verbosity: Double

    /// Risk tolerance for novel approaches (0.0 = conservative, 1.0 = experimental)
    public let riskTolerance: Double

    /// How heavily to cite sources (0.0 = minimal, 1.0 = every claim)
    public let citationDensity: Double

    /// Tendency to seek human input (0.0 = autonomous, 1.0 = frequent escalation)
    public let escalationTendency: Double

    /// Preferred working style
    public let workingStyle: WorkingStyle

    /// Additional behavioral notes
    public let notes: [String]

    public init(
        verbosity: Double = 0.5,
        riskTolerance: Double = 0.3,
        citationDensity: Double = 0.5,
        escalationTendency: Double = 0.5,
        workingStyle: WorkingStyle = .balanced,
        notes: [String] = []
    ) {
        self.verbosity = verbosity
        self.riskTolerance = riskTolerance
        self.citationDensity = citationDensity
        self.escalationTendency = escalationTendency
        self.workingStyle = workingStyle
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case verbosity
        case riskTolerance = "risk_tolerance"
        case citationDensity = "citation_density"
        case escalationTendency = "escalation_tendency"
        case workingStyle = "working_style"
        case notes
    }
}

// MARK: - Persona Domain

/// Domain expertise specification
public struct PersonaDomain: Codable, Sendable {
    /// Primary research domains
    public let primaryDomains: [String]

    /// Methodological expertise
    public let methodologies: [String]

    /// Preferred data sources
    public let dataSources: [String]

    public init(
        primaryDomains: [String] = [],
        methodologies: [String] = [],
        dataSources: [String] = []
    ) {
        self.primaryDomains = primaryDomains
        self.methodologies = methodologies
        self.dataSources = dataSources
    }

    enum CodingKeys: String, CodingKey {
        case primaryDomains = "primary_domains"
        case methodologies
        case dataSources = "data_sources"
    }
}

// MARK: - Persona Model Config

/// Model configuration for a persona
public struct PersonaModelConfig: Codable, Sendable {
    /// Provider (e.g., "anthropic", "openai", "ollama")
    public let provider: String

    /// Model identifier
    public let model: String

    /// Sampling temperature
    public let temperature: Double

    /// Maximum tokens in response
    public let maxTokens: Int?

    /// Top-p sampling
    public let topP: Double?

    public init(
        provider: String = "anthropic",
        model: String = "claude-sonnet-4-20250514",
        temperature: Double = 0.7,
        maxTokens: Int? = nil,
        topP: Double? = nil
    ) {
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }
}

// MARK: - Persona

/// A persona is a rich behavioral configuration for an agent
public struct Persona: Identifiable, Codable, Sendable {
    /// Unique identifier
    public let id: String

    /// Human-readable display name
    public let name: String

    /// The underlying capability archetype
    public let archetype: AgentType

    /// Short description of the persona's role
    public let roleDescription: String

    /// Extended description for system prompts
    public let systemPrompt: String

    /// Behavioral configuration
    public let behavior: PersonaBehavior

    /// Domain expertise
    public let domain: PersonaDomain

    /// Model configuration
    public let model: PersonaModelConfig

    /// Tool access policies
    public let tools: ToolPolicySet

    /// Whether this persona is builtin
    public let builtin: Bool

    /// Source path if loaded from file
    public let sourcePath: String?

    public init(
        id: String,
        name: String,
        archetype: AgentType,
        roleDescription: String,
        systemPrompt: String = "",
        behavior: PersonaBehavior = PersonaBehavior(),
        domain: PersonaDomain = PersonaDomain(),
        model: PersonaModelConfig = PersonaModelConfig(),
        tools: ToolPolicySet = ToolPolicySet(),
        builtin: Bool = false,
        sourcePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.archetype = archetype
        self.roleDescription = roleDescription
        self.systemPrompt = systemPrompt
        self.behavior = behavior
        self.domain = domain
        self.model = model
        self.tools = tools
        self.builtin = builtin
        self.sourcePath = sourcePath
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case archetype
        case roleDescription = "role_description"
        case systemPrompt = "system_prompt"
        case behavior
        case domain
        case model
        case tools
        case builtin
        case sourcePath = "source_path"
    }

    /// Check if persona can use a specific tool
    public func canUse(tool: String) -> Bool {
        tools.canAccess(tool)
    }

    /// Check if persona can write with a specific tool
    public func canWrite(tool: String) -> Bool {
        tools.canWrite(tool)
    }

    /// System image for the persona's archetype
    public var systemImage: String {
        archetype.systemImage
    }

    /// Display color based on working style
    public var styleColor: String {
        switch behavior.workingStyle {
        case .rapid: return "orange"
        case .balanced: return "blue"
        case .methodical: return "green"
        case .analytical: return "purple"
        }
    }
}

// MARK: - Persona Summary

/// Lightweight summary of a persona for lists
public struct PersonaSummary: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let archetype: String
    public let roleDescription: String
    public let builtin: Bool

    public init(
        id: String,
        name: String,
        archetype: String,
        roleDescription: String,
        builtin: Bool
    ) {
        self.id = id
        self.name = name
        self.archetype = archetype
        self.roleDescription = roleDescription
        self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case archetype
        case roleDescription = "role_description"
        case builtin
    }
}

// MARK: - Mock Data

extension Persona {
    /// Mock personas for development/demo
    public static func mockPersonas() -> [Persona] {
        [
            Persona(
                id: "scout",
                name: "Scout",
                archetype: .research,
                roleDescription: "Eager explorer of new research directions",
                systemPrompt: "You are Scout, an eager explorer of research frontiers...",
                behavior: PersonaBehavior(
                    verbosity: 0.4,
                    riskTolerance: 0.8,
                    citationDensity: 0.3,
                    escalationTendency: 0.6,
                    workingStyle: .rapid,
                    notes: ["Favors breadth over depth", "Quick to prototype ideas"]
                ),
                domain: PersonaDomain(
                    primaryDomains: ["cross-disciplinary"],
                    methodologies: ["literature survey", "trend analysis"],
                    dataSources: ["arxiv", "semantic scholar"]
                ),
                model: PersonaModelConfig(temperature: 0.7),
                tools: ToolPolicySet(
                    policies: [
                        ToolPolicy(tool: "imbib", access: .readWrite),
                        ToolPolicy(tool: "imprint", access: .read)
                    ],
                    defaultAccess: .read
                ),
                builtin: true
            ),
            Persona(
                id: "archivist",
                name: "Archivist",
                archetype: .librarian,
                roleDescription: "Citation-heavy historian of research",
                systemPrompt: "You are Archivist, the meticulous keeper of research provenance...",
                behavior: PersonaBehavior(
                    verbosity: 0.6,
                    riskTolerance: 0.1,
                    citationDensity: 1.0,
                    escalationTendency: 0.3,
                    workingStyle: .methodical,
                    notes: ["Every claim needs a citation", "Tracks idea genealogy"]
                ),
                domain: PersonaDomain(
                    primaryDomains: ["bibliography", "research history"],
                    methodologies: ["citation analysis", "systematic review"],
                    dataSources: ["crossref", "openalex", "semantic scholar"]
                ),
                model: PersonaModelConfig(temperature: 0.3),
                tools: ToolPolicySet(
                    policies: [
                        ToolPolicy(tool: "imbib", access: .full),
                        ToolPolicy(tool: "imprint", access: .read)
                    ],
                    defaultAccess: .read
                ),
                builtin: true
            ),
            Persona(
                id: "steward",
                name: "Steward",
                archetype: .review,
                roleDescription: "Project coordinator and process guardian",
                systemPrompt: "You are Steward, the project coordinator and process guardian...",
                behavior: PersonaBehavior(
                    verbosity: 0.5,
                    riskTolerance: 0.2,
                    citationDensity: 0.2,
                    escalationTendency: 0.7,
                    workingStyle: .balanced,
                    notes: ["Focuses on process, not content", "Bridges personas and human PI"]
                ),
                domain: PersonaDomain(
                    primaryDomains: ["project management"],
                    methodologies: ["progress tracking", "dependency analysis"],
                    dataSources: []
                ),
                model: PersonaModelConfig(temperature: 0.4),
                tools: ToolPolicySet(
                    policies: [
                        ToolPolicy(tool: "imbib", access: .read),
                        ToolPolicy(tool: "imprint", access: .read),
                        ToolPolicy(tool: "impel", access: .full)
                    ],
                    defaultAccess: .read
                ),
                builtin: true
            ),
            Persona(
                id: "counsel",
                name: "Counsel",
                archetype: .research,
                roleDescription: "Email gateway research assistant",
                systemPrompt: """
                    You are counsel, a research assistant integrated into the impress research environment. \
                    You communicate with the user via email. Respond helpfully and concisely. \
                    Format your response as a plain-text email reply.
                    """,
                behavior: PersonaBehavior(
                    verbosity: 0.5,
                    riskTolerance: 0.3,
                    citationDensity: 0.5,
                    escalationTendency: 0.4,
                    workingStyle: .balanced,
                    notes: ["Handles email-based research requests", "Concise plain-text responses"]
                ),
                domain: PersonaDomain(
                    primaryDomains: ["general research"],
                    methodologies: ["literature search", "summarization"],
                    dataSources: ["web", "arxiv", "semantic scholar"]
                ),
                model: PersonaModelConfig(provider: "claude-cli", model: "sonnet"),
                tools: ToolPolicySet(
                    policies: [
                        ToolPolicy(tool: "WebSearch", access: .full),
                        ToolPolicy(tool: "WebFetch", access: .full)
                    ],
                    defaultAccess: .read
                ),
                builtin: true
            )
        ]
    }
}
