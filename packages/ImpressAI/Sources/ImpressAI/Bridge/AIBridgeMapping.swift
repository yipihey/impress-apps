import Foundation

/// Pure conversions between the ImpressAI request/response types callers
/// use and the bridge types that cross into Rust. Kept free of I/O so they
/// are unit-testable without a bridge.
public enum AIBridgeMapping {
    /// Keys in `AICompletionRequest.additionalParameters` the bridge honours.
    public static let thinkingParameter = "thinking"
    public static let responseFormatParameter = "responseFormat"

    public static func bridgeRequest(
        _ request: AICompletionRequest,
        taskCategory: String? = nil
    ) -> AIBridgeChatRequest {
        let thinking = request.additionalParameters?[thinkingParameter]?.get() as Bool? ?? false
        let responseFormat = request.additionalParameters?[responseFormatParameter]?.get() as AIBridgeResponseFormat?
        return AIBridgeChatRequest(
            providerId: request.providerId,
            modelId: request.modelId,
            taskCategory: taskCategory,
            messages: request.messages.map(bridgeMessage),
            systemPrompt: request.systemPrompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stopSequences: request.stopSequences ?? [],
            tools: (request.tools ?? []).map(bridgeTool),
            responseFormat: responseFormat,
            thinking: thinking
        )
    }

    public static func bridgeMessage(_ message: AIMessage) -> AIBridgeMessage {
        AIBridgeMessage(role: message.role, content: message.content.map(bridgePart))
    }

    public static func bridgePart(_ content: AIContent) -> AIBridgeContentPart {
        switch content {
        case .text(let text):
            return .text(text)
        case .image(let image):
            switch image.source {
            case .base64(let data, let mediaType):
                return .image(base64: data, mediaType: mediaType, detail: image.detail?.rawValue)
            case .url(let url):
                return .imageURL(url.absoluteString, detail: image.detail?.rawValue)
            }
        case .toolUse(let use):
            return .toolUse(id: use.id, name: use.name, inputJSON: jsonString(use.input.mapValues { $0.toJSONValue() }))
        case .toolResult(let result):
            return .toolResult(toolUseId: result.toolUseId, content: result.content, isError: result.isError)
        }
    }

    public static func bridgeTool(_ tool: AITool) -> AIBridgeToolSpec {
        AIBridgeToolSpec(
            name: tool.name,
            description: tool.description,
            inputSchemaJSON: jsonString(tool.inputSchema.mapValues { $0.toJSONValue() })
        )
    }

    public static func completionResponse(_ response: AIBridgeChatResponse) -> AICompletionResponse {
        AICompletionResponse(
            id: response.id,
            content: response.content.compactMap(content),
            model: response.target.modelId,
            finishReason: response.finishReason,
            usage: response.usage
        )
    }

    /// Bridge content back into `AIContent`. Tool results and images never
    /// come back from a model, so only text and tool use are mapped.
    public static func content(_ part: AIBridgeContentPart) -> AIContent? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : .text(text)
        case .toolUse(let id, let name, let inputJSON):
            return .toolUse(AIToolUse(id: id, name: name, input: jsonObject(inputJSON)))
        case .image, .imageURL, .toolResult:
            return nil
        }
    }

    /// Accumulates streamed tool-call fragments by index until the stream
    /// finishes, then emits whole `AIToolUse` values.
    public struct ToolCallAccumulator: Sendable {
        private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

        public init() {}

        public mutating func push(index: Int, id: String?, name: String?, arguments: String) {
            var call = calls[index] ?? (id: "", name: "", arguments: "")
            if let id, !id.isEmpty { call.id = id }
            if let name, !name.isEmpty { call.name += name }
            call.arguments += arguments
            calls[index] = call
        }

        public var isEmpty: Bool { calls.isEmpty }

        public mutating func finish() -> [AIToolUse] {
            let uses = calls.keys.sorted().compactMap { index -> AIToolUse? in
                guard let call = calls[index], !call.name.isEmpty else { return nil }
                return AIToolUse(id: call.id, name: call.name, input: jsonObject(call.arguments))
            }
            calls.removeAll()
            return uses
        }
    }

    /// Fold one bridge event into a chunk, buffering tool-call fragments in
    /// `accumulator`. Returns nil when the event produces nothing to yield.
    public static func streamChunk(
        for event: AIBridgeStreamEvent,
        accumulator: inout ToolCallAccumulator
    ) throws -> AIStreamChunk? {
        switch event {
        case .started:
            return nil
        case .text(let text):
            return AIStreamChunk(content: [.text(text)])
        case .reasoning(let text):
            return AIStreamChunk(content: [], reasoning: text)
        case .toolCallDelta(let index, let id, let name, let arguments):
            accumulator.push(index: index, id: id, name: name, arguments: arguments)
            return nil
        case .toolCall(let id, let name, let inputJSON):
            return AIStreamChunk(content: [.toolUse(AIToolUse(id: id, name: name, input: jsonObject(inputJSON)))])
        case .usage(let usage):
            return AIStreamChunk(content: [], usage: usage)
        case .done(let finishReason):
            let pending = accumulator.finish().map(AIContent.toolUse)
            let reason = finishReason ?? (pending.isEmpty ? nil : .toolUse)
            return AIStreamChunk(content: pending, finishReason: reason)
        case .failed(let error):
            throw error.asAIError
        }
    }

    // MARK: - JSON helpers

    static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    static func jsonObject(_ string: String) -> [String: AnySendable] {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.mapValues(AnySendable.fromJSON)
    }
}
