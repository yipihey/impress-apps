import Foundation
import ImpressAI
import ImpressKit
import OSLog

/// Native agentic loop that replaces ClaudeCLIClient with direct Anthropic API calls.
///
/// Uses `AnthropicProvider` for completions and `CounselToolRegistry` for tool execution
/// via HTTP to sibling apps. This is fully App Store compliant — no `Process()` calls.
public actor NativeAgentLoop {
    private let provider: AnthropicProvider
    private let toolRegistry: CounselToolRegistry
    private let logger = Logger(subsystem: "com.impress.impel", category: "native-agent-loop")

    public init(provider: AnthropicProvider = AnthropicProvider(), toolRegistry: CounselToolRegistry = CounselToolRegistry()) {
        self.provider = provider
        self.toolRegistry = toolRegistry
    }

    /// Run the agentic loop with tool use.
    ///
    /// Sends messages to Claude, executes any tool calls via HTTP bridges,
    /// and loops until Claude stops requesting tools or maxTurns is reached.
    public func run(
        systemPrompt: String,
        messages: [AIMessage],
        maxTurns: Int = 25,
        modelId: String? = nil
    ) async -> NativeAgentLoopResult {
        var conversationMessages = messages
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var toolExecutions: [ToolExecutionRecord] = []
        let tools = toolRegistry.allTools()

        for round in 0..<maxTurns {
            logger.info("Agent loop round \(round + 1)/\(maxTurns)")

            let request = AICompletionRequest(
                modelId: modelId,
                messages: conversationMessages,
                systemPrompt: systemPrompt,
                maxTokens: 8192,
                tools: tools.isEmpty ? nil : tools
            )

            let response: AICompletionResponse
            do {
                response = try await provider.complete(request)
            } catch {
                logger.error("API call failed: \(error.localizedDescription)")
                return NativeAgentLoopResult(
                    responseText: "I encountered an error: \(error.localizedDescription)",
                    toolExecutions: toolExecutions,
                    totalInputTokens: totalInputTokens,
                    totalOutputTokens: totalOutputTokens,
                    roundsUsed: round + 1,
                    finishReason: .error
                )
            }

            // Track token usage
            if let usage = response.usage {
                totalInputTokens += usage.inputTokens
                totalOutputTokens += usage.outputTokens
            }

            // If no tool use, return the text response
            guard response.finishReason == .toolUse else {
                let text = response.text
                return NativeAgentLoopResult(
                    responseText: text.isEmpty ? "I completed the task." : text,
                    toolExecutions: toolExecutions,
                    totalInputTokens: totalInputTokens,
                    totalOutputTokens: totalOutputTokens,
                    roundsUsed: round + 1,
                    finishReason: .completed
                )
            }

            // Append assistant response (with tool_use blocks)
            conversationMessages.append(AIMessage(role: .assistant, content: response.content))

            // Execute each tool call and collect results
            var toolResults: [AIContent] = []
            for content in response.content {
                guard case .toolUse(let toolUse) = content else { continue }

                logger.info("Executing tool: \(toolUse.name)")
                let startTime = Date()

                let result = await toolRegistry.execute(toolUse)
                let duration = Date().timeIntervalSince(startTime)

                toolExecutions.append(ToolExecutionRecord(
                    toolName: toolUse.name,
                    toolInput: toolUse.input.mapValues { $0.toJSONValue() },
                    toolOutput: result.content,
                    isError: result.isError,
                    durationMs: Int(duration * 1000)
                ))

                toolResults.append(.toolResult(result))
            }

            // Append tool results as a user message
            conversationMessages.append(AIMessage(role: .user, content: toolResults))
        }

        // Max turns reached
        let finalText = conversationMessages.last(where: { $0.role == .assistant })?.text ?? ""
        return NativeAgentLoopResult(
            responseText: finalText.isEmpty ? "I reached the maximum number of turns." : finalText,
            toolExecutions: toolExecutions,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            roundsUsed: maxTurns,
            finishReason: .maxRoundsReached
        )
    }
}

// MARK: - Result Types

/// Result of a native agent loop execution.
public struct NativeAgentLoopResult: Sendable {
    public let responseText: String
    public let toolExecutions: [ToolExecutionRecord]
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let roundsUsed: Int
    public let finishReason: NativeAgentFinishReason

    public var totalTokensUsed: Int { totalInputTokens + totalOutputTokens }
}

/// A record of a single tool execution.
public struct ToolExecutionRecord: Sendable {
    public let toolName: String
    public let toolInput: [String: Any]
    public let toolOutput: String
    public let isError: Bool
    public let durationMs: Int

    // Sendable workaround for [String: Any]
    nonisolated(unsafe) let _input: [String: Any]

    public init(toolName: String, toolInput: [String: Any], toolOutput: String, isError: Bool, durationMs: Int) {
        self.toolName = toolName
        self._input = toolInput
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.isError = isError
        self.durationMs = durationMs
    }
}

/// Finish reasons for the native agent loop.
public enum NativeAgentFinishReason: String, Sendable {
    case completed
    case maxRoundsReached
    case error
}
