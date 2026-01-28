import Foundation

/// A request for AI completion.
public struct AICompletionRequest: Sendable {
    /// Target provider ID. If nil, uses the default provider.
    public let providerId: String?

    /// Target model ID. If nil, uses the provider's default model.
    public let modelId: String?

    /// Messages in the conversation.
    public let messages: [AIMessage]

    /// Optional system prompt.
    public let systemPrompt: String?

    /// Maximum tokens to generate.
    public let maxTokens: Int?

    /// Temperature for response randomness (0.0 - 2.0).
    public let temperature: Double?

    /// Top-p nucleus sampling parameter.
    public let topP: Double?

    /// Stop sequences that will halt generation.
    public let stopSequences: [String]?

    /// Whether to enable streaming (hint to provider).
    public let stream: Bool

    /// Optional tools available for the model to use.
    public let tools: [AITool]?

    /// Additional provider-specific parameters.
    public let additionalParameters: [String: AnySendable]?

    public init(
        providerId: String? = nil,
        modelId: String? = nil,
        messages: [AIMessage],
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
        stream: Bool = false,
        tools: [AITool]? = nil,
        additionalParameters: [String: AnySendable]? = nil
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.stream = stream
        self.tools = tools
        self.additionalParameters = additionalParameters
    }
}

/// A message in an AI conversation.
public struct AIMessage: Sendable, Identifiable, Equatable {
    public let id: String
    public let role: AIRole
    public let content: [AIContent]
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: AIRole,
        content: [AIContent],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    /// Convenience initializer for text-only messages.
    public init(
        id: String = UUID().uuidString,
        role: AIRole,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = [.text(text)]
        self.timestamp = timestamp
    }

    /// Combined text content of the message.
    public var text: String {
        content.compactMap { content in
            if case .text(let text) = content {
                return text
            }
            return nil
        }.joined()
    }
}

/// Role of a message sender.
public enum AIRole: String, Sendable, Codable, Equatable {
    case system
    case user
    case assistant
    case tool
}

/// Content within a message.
public enum AIContent: Sendable, Equatable {
    case text(String)
    case image(AIImageContent)
    case toolUse(AIToolUse)
    case toolResult(AIToolResult)
}

/// Image content for vision-capable models.
public struct AIImageContent: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case base64(data: String, mediaType: String)
        case url(URL)
    }

    public let source: Source
    public let detail: ImageDetail?

    public enum ImageDetail: String, Sendable, Equatable {
        case low
        case high
        case auto
    }

    public init(source: Source, detail: ImageDetail? = nil) {
        self.source = source
        self.detail = detail
    }
}

/// Tool use by the assistant.
public struct AIToolUse: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let input: [String: AnySendable]

    public init(id: String, name: String, input: [String: AnySendable]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Result of a tool execution.
public struct AIToolResult: Sendable, Equatable {
    public let toolUseId: String
    public let content: String
    public let isError: Bool

    public init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

/// Tool definition for function calling.
public struct AITool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: [String: AnySendable]

    public init(name: String, description: String, inputSchema: [String: AnySendable]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Response from an AI completion request.
public struct AICompletionResponse: Sendable {
    /// Unique identifier for this response.
    public let id: String

    /// The generated content.
    public let content: [AIContent]

    /// Model that generated the response.
    public let model: String

    /// Reason the generation stopped.
    public let finishReason: AIFinishReason?

    /// Token usage statistics.
    public let usage: AIUsage?

    public init(
        id: String,
        content: [AIContent],
        model: String,
        finishReason: AIFinishReason? = nil,
        usage: AIUsage? = nil
    ) {
        self.id = id
        self.content = content
        self.model = model
        self.finishReason = finishReason
        self.usage = usage
    }

    /// Combined text content of the response.
    public var text: String {
        content.compactMap { content in
            if case .text(let text) = content {
                return text
            }
            return nil
        }.joined()
    }
}

/// Reason generation stopped.
public enum AIFinishReason: String, Sendable, Codable {
    case stop = "stop"
    case length = "length"
    case toolUse = "tool_use"
    case contentFilter = "content_filter"
    case error = "error"
}

/// Token usage statistics.
public struct AIUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A chunk from a streaming response.
public struct AIStreamChunk: Sendable {
    /// Chunk identifier.
    public let id: String?

    /// Content in this chunk.
    public let content: [AIContent]

    /// Finish reason if this is the final chunk.
    public let finishReason: AIFinishReason?

    /// Usage statistics (typically only in final chunk).
    public let usage: AIUsage?

    public init(
        id: String? = nil,
        content: [AIContent],
        finishReason: AIFinishReason? = nil,
        usage: AIUsage? = nil
    ) {
        self.id = id
        self.content = content
        self.finishReason = finishReason
        self.usage = usage
    }

    /// Combined text content of this chunk.
    public var text: String {
        content.compactMap { content in
            if case .text(let text) = content {
                return text
            }
            return nil
        }.joined()
    }
}

/// Type-erased Sendable wrapper for dynamic values.
public struct AnySendable: Sendable, Equatable {
    private let value: Any
    private let equalsFunction: @Sendable (Any) -> Bool

    public init<T: Sendable & Equatable>(_ value: T) {
        self.value = value
        self.equalsFunction = { other in
            guard let otherT = other as? T else { return false }
            return value == otherT
        }
    }

    public static func == (lhs: AnySendable, rhs: AnySendable) -> Bool {
        lhs.equalsFunction(rhs.value)
    }

    public func get<T>() -> T? {
        value as? T
    }
}
