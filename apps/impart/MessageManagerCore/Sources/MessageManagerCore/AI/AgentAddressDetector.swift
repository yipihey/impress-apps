//
//  AgentAddressDetector.swift
//  MessageManagerCore
//
//  Detects and parses AI agent email addresses.
//  Format: {role}-{model}@impart.local
//  Example: counsel-opus4.5@impart.local
//

import Foundation

// MARK: - Agent Type

/// Type of AI agent.
public enum AgentType: String, Codable, CaseIterable, Sendable {
    /// Counsel agent - provides advice and analysis.
    case counsel

    /// Research agent - finds papers, references, information.
    case research

    /// Triage agent - helps prioritize and categorize messages.
    case triage

    /// Draft agent - helps compose responses.
    case draft

    /// Summary agent - summarizes threads/conversations.
    case summary

    /// Custom agent type.
    case custom

    public var displayName: String {
        switch self {
        case .counsel: return "Counsel"
        case .research: return "Research"
        case .triage: return "Triage"
        case .draft: return "Draft"
        case .summary: return "Summary"
        case .custom: return "Custom"
        }
    }

    public var iconName: String {
        switch self {
        case .counsel: return "brain.head.profile"
        case .research: return "magnifyingglass"
        case .triage: return "tray.2"
        case .draft: return "pencil"
        case .summary: return "doc.text"
        case .custom: return "cpu"
        }
    }
}

// MARK: - Agent Address

/// Parsed AI agent email address.
public struct AgentAddress: Codable, Hashable, Sendable {
    /// Full email address.
    public let email: String

    /// Agent type (counsel, research, etc.).
    public let agentType: AgentType

    /// Model name (opus4.5, gemini, sonnet, etc.).
    public let modelName: String

    /// Local part of the email (before @).
    public let localPart: String

    /// Domain part of the email (after @).
    public let domain: String

    /// Display name for the agent.
    public var displayName: String {
        "\(agentType.displayName) (\(modelName))"
    }

    /// Short display name.
    public var shortName: String {
        "\(agentType.rawValue)-\(modelName)"
    }

    // MARK: - Detection

    /// Domain suffix for agent addresses.
    public static let agentDomain = "impart.local"

    /// Alternate domains for agent addresses.
    public static let alternateDomains = ["impart.ai", "agents.impart.local"]

    /// Detect if an email is an agent address.
    /// - Parameter email: Email address to check.
    /// - Returns: Parsed AgentAddress if valid, nil otherwise.
    public static func detect(from email: String) -> AgentAddress? {
        let lowercased = email.lowercased().trimmingCharacters(in: .whitespaces)

        // Split into local and domain
        let parts = lowercased.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let localPart = String(parts[0])
        let domain = String(parts[1])

        // Check domain
        let validDomains = [agentDomain] + alternateDomains
        guard validDomains.contains(domain) else { return nil }

        // Parse local part: {role}-{model}
        let localParts = localPart.split(separator: "-", maxSplits: 1)
        guard localParts.count == 2 else { return nil }

        let roleString = String(localParts[0])
        let modelName = String(localParts[1])

        // Map role to agent type
        let agentType: AgentType
        if let type = AgentType(rawValue: roleString) {
            agentType = type
        } else {
            agentType = .custom
        }

        return AgentAddress(
            email: lowercased,
            agentType: agentType,
            modelName: modelName,
            localPart: localPart,
            domain: domain
        )
    }

    /// Create an agent email address.
    /// - Parameters:
    ///   - type: Agent type.
    ///   - model: Model name.
    ///   - domain: Domain (defaults to impart.local).
    /// - Returns: Email address string.
    public static func create(type: AgentType, model: String, domain: String = agentDomain) -> String {
        "\(type.rawValue)-\(model.lowercased())@\(domain)"
    }

    /// Check if any address in a list is an agent address.
    public static func containsAgent(in addresses: [EmailAddress]) -> Bool {
        addresses.contains { detect(from: $0.email) != nil }
    }

    /// Find all agent addresses in a list.
    public static func findAgents(in addresses: [EmailAddress]) -> [AgentAddress] {
        addresses.compactMap { detect(from: $0.email) }
    }
}

// MARK: - Known Models

/// Known AI models for agent addresses.
public enum KnownModel: String, CaseIterable, Sendable {
    // Claude models
    case opus = "opus4.5"
    case sonnet = "sonnet4"
    case haiku = "haiku"

    // Other models
    case gemini = "gemini"
    case gpt4 = "gpt4"
    case gpt4o = "gpt4o"
    case o1 = "o1"
    case o3 = "o3"

    // Local models
    case local = "local"
    case llama = "llama"

    public var displayName: String {
        switch self {
        case .opus: return "Claude Opus 4.5"
        case .sonnet: return "Claude Sonnet 4"
        case .haiku: return "Claude Haiku"
        case .gemini: return "Gemini"
        case .gpt4: return "GPT-4"
        case .gpt4o: return "GPT-4o"
        case .o1: return "o1"
        case .o3: return "o3"
        case .local: return "Local Model"
        case .llama: return "Llama"
        }
    }

    public var provider: String {
        switch self {
        case .opus, .sonnet, .haiku: return "Anthropic"
        case .gemini: return "Google"
        case .gpt4, .gpt4o, .o1, .o3: return "OpenAI"
        case .local, .llama: return "Local"
        }
    }
}
