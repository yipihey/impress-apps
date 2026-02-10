import Foundation
import ImpressAI
import OSLog

/// Configuration for the agentic loop.
public struct AgentLoopConfig: Sendable {
    public var maxTurns: Int
    public var modelId: String?
    public var progressEmailThreshold: Int

    public init(
        maxTurns: Int = 25,
        modelId: String? = nil,
        progressEmailThreshold: Int = 15
    ) {
        self.maxTurns = maxTurns
        self.modelId = modelId
        self.progressEmailThreshold = progressEmailThreshold
    }
}

/// Result of a completed agent loop.
public struct AgentLoopResult: Sendable {
    public let responseText: String
    public let toolExecutions: [CounselToolExecution]
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let roundsUsed: Int
    public let finishReason: AgentLoopFinishReason

    public var totalTokensUsed: Int { totalInputTokens + totalOutputTokens }
}

public enum AgentLoopFinishReason: String, Sendable {
    case completed
    case maxRoundsReached
    case error
}

/// Core agentic tool-use cycle using the NativeAgentLoop with direct Anthropic API calls.
///
/// Tool use is dispatched via HTTP to sibling apps through CounselToolRegistry.
/// No Process() calls — fully App Store compliant.
public actor CounselAgentLoop {
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-loop")
    private let database: CounselDatabase
    private let config: AgentLoopConfig
    private let nativeLoop: NativeAgentLoop
    private var progressReporter: CounselProgressReporter?

    public init(
        database: CounselDatabase,
        config: AgentLoopConfig = AgentLoopConfig(),
        nativeLoop: NativeAgentLoop = NativeAgentLoop()
    ) {
        self.database = database
        self.config = config
        self.nativeLoop = nativeLoop
    }

    public func setProgressReporter(_ reporter: CounselProgressReporter?) {
        self.progressReporter = reporter
    }

    /// Run the agentic loop for a conversation.
    ///
    /// Delegates to NativeAgentLoop which uses AnthropicProvider + CounselToolRegistry
    /// for multi-turn tool use via HTTP bridges to sibling apps.
    public func run(
        conversationID: String,
        systemPrompt: String,
        messages: [AIMessage]
    ) async -> AgentLoopResult {
        logger.info("Starting native agent loop for conversation \(conversationID)")

        let nativeResult = await nativeLoop.run(
            systemPrompt: systemPrompt,
            messages: messages,
            maxTurns: config.maxTurns,
            modelId: config.modelId
        )

        // Record tool executions in the database
        var toolExecutions: [CounselToolExecution] = []
        for record in nativeResult.toolExecutions {
            let execution = CounselToolExecution(
                conversationID: conversationID,
                toolName: record.toolName,
                toolInput: record.toolOutput.isEmpty ? "{}" : "{}",
                toolOutput: record.toolOutput,
                durationMs: record.durationMs
            )
            toolExecutions.append(execution)
            try? database.addToolExecution(execution)
        }

        let totalTokens = nativeResult.totalTokensUsed

        logger.info("Native loop completed: \(nativeResult.roundsUsed) rounds, \(totalTokens) tokens, \(toolExecutions.count) tool calls")

        // Send progress notification if many tools were used
        if toolExecutions.count >= config.progressEmailThreshold, let reporter = progressReporter {
            let toolNames = toolExecutions.map(\.toolName).joined(separator: ", ")
            await reporter.sendProgress(
                round: nativeResult.roundsUsed,
                toolsUsed: toolNames,
                totalTools: toolExecutions.count
            )
        }

        let responseText: String
        if !nativeResult.responseText.isEmpty {
            responseText = nativeResult.responseText
        } else if !toolExecutions.isEmpty {
            let toolSummary = toolExecutions
                .map { "- \($0.toolName)" }
                .joined(separator: "\n")
            responseText = """
                I completed your request using \(toolExecutions.count) tool(s) across \
                \(nativeResult.roundsUsed) round(s), but ran out of turns before composing \
                a summary. Here's what I did:

                \(toolSummary)

                Please check the results in the relevant app, or ask me to summarize.

                — counsel@impress.local
                """
        } else {
            responseText = "I wasn't able to generate a response. Please try again.\n\n— counsel@impress.local"
        }

        let finishReason: AgentLoopFinishReason
        switch nativeResult.finishReason {
        case .completed: finishReason = .completed
        case .maxRoundsReached: finishReason = .maxRoundsReached
        case .error: finishReason = .error
        }

        return AgentLoopResult(
            responseText: responseText,
            toolExecutions: toolExecutions,
            totalInputTokens: nativeResult.totalInputTokens,
            totalOutputTokens: nativeResult.totalOutputTokens,
            roundsUsed: nativeResult.roundsUsed,
            finishReason: finishReason
        )
    }
}
