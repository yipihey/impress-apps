import Foundation

/// AI provider for OpenAI's GPT models.
public actor OpenAIProvider: AIProvider {
    private let baseURL = URL(string: "https://api.openai.com/v1")!
    private let credentialManager: AICredentialManager
    private let urlSession: URLSession

    public let metadata = AIProviderMetadata(
        id: "openai",
        name: "OpenAI",
        description: "GPT models from OpenAI",
        models: [
            AIModel(
                id: "gpt-4o",
                name: "GPT-4o",
                description: "Most capable multimodal model",
                contextWindow: 128_000,
                maxOutputTokens: 16_384,
                isDefault: true,
                capabilities: .full
            ),
            AIModel(
                id: "gpt-4o-mini",
                name: "GPT-4o Mini",
                description: "Fast and affordable multimodal model",
                contextWindow: 128_000,
                maxOutputTokens: 16_384,
                capabilities: .full
            ),
            AIModel(
                id: "o1",
                name: "o1",
                description: "Advanced reasoning model",
                contextWindow: 200_000,
                maxOutputTokens: 100_000,
                capabilities: [.streaming, .vision, .tools, .jsonMode, .thinking]
            ),
            AIModel(
                id: "o1-mini",
                name: "o1 Mini",
                description: "Fast reasoning model",
                contextWindow: 128_000,
                maxOutputTokens: 65_536,
                capabilities: [.streaming, .jsonMode, .thinking]
            ),
            AIModel(
                id: "o3-mini",
                name: "o3 Mini",
                description: "Latest compact reasoning model",
                contextWindow: 200_000,
                maxOutputTokens: 100_000,
                capabilities: [.streaming, .vision, .tools, .jsonMode, .thinking]
            ),
        ],
        capabilities: .full,
        credentialRequirement: .apiKey,
        category: .cloud,
        registrationURL: URL(string: "https://platform.openai.com/api-keys"),
        rateLimit: AIRateLimit(requestsPerInterval: 60, intervalSeconds: 60),
        iconName: "cpu"
    )

    public init(credentialManager: AICredentialManager = .shared) {
        self.credentialManager = credentialManager
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.urlSession = URLSession(configuration: config)
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let apiKey = try await getAPIKey()
        let httpRequest = try buildRequest(request, apiKey: apiKey, stream: false)

        let (data, response) = try await urlSession.data(for: httpRequest)
        try validateResponse(response, data: data)

        return try parseResponse(data)
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let apiKey = try await getAPIKey()
        let httpRequest = try buildRequest(request, apiKey: apiKey, stream: true)

        let (bytes, response) = try await urlSession.bytes(for: httpRequest)
        try validateResponse(response, data: nil)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))
                            if jsonString == "[DONE]" {
                                continuation.finish()
                                return
                            }
                            if let chunk = try? parseStreamChunk(jsonString) {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.from(error))
                }
            }
        }
    }

    public func validate() async throws -> AIProviderStatus {
        guard await credentialManager.hasCredential(for: metadata.id, field: "apiKey") else {
            return .needsCredentials(["apiKey"])
        }
        return .ready
    }

    // MARK: - Private Methods

    private func getAPIKey() async throws -> String {
        guard let apiKey = await credentialManager.retrieve(for: metadata.id, field: "apiKey"),
              !apiKey.isEmpty else {
            throw AIError.unauthorized(message: "OpenAI API key not configured")
        }
        return apiKey
    }

    private func buildRequest(_ request: AICompletionRequest, apiKey: String, stream: Bool) throws -> URLRequest {
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": request.modelId ?? metadata.defaultModel?.id ?? "gpt-4o",
            "stream": stream
        ]

        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }

        // Build messages array
        var messages: [[String: Any]] = []

        // Add system prompt
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for message in request.messages {
            var msgDict: [String: Any] = ["role": message.role == .assistant ? "assistant" : message.role.rawValue]
            msgDict["content"] = buildContent(message.content)
            messages.append(msgDict)
        }
        body["messages"] = messages

        // Optional parameters
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let topP = request.topP {
            body["top_p"] = topP
        }
        if let stopSequences = request.stopSequences, !stopSequences.isEmpty {
            body["stop"] = stopSequences
        }

        // Tools
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema
                    ]
                ]
            }
        }

        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
    }

    private func buildContent(_ content: [AIContent]) -> Any {
        if content.count == 1, case .text(let text) = content[0] {
            return text
        }

        return content.compactMap { item -> [String: Any]? in
            switch item {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let image):
                switch image.source {
                case .base64(let data, let mediaType):
                    return [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(mediaType);base64,\(data)",
                            "detail": image.detail?.rawValue ?? "auto"
                        ]
                    ]
                case .url(let url):
                    return [
                        "type": "image_url",
                        "image_url": [
                            "url": url.absoluteString,
                            "detail": image.detail?.rawValue ?? "auto"
                        ]
                    ]
                }
            default:
                return nil
            }
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError(underlying: URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw AIError.unauthorized(message: "Invalid API key")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw AIError.rateLimited(retryAfter: retryAfter)
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data) throws -> AICompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parseError("Invalid JSON response")
        }

        let id = json["id"] as? String ?? UUID().uuidString
        let model = json["model"] as? String ?? ""

        var content: [AIContent] = []
        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any] {

            if let text = message["content"] as? String {
                content.append(.text(text))
            }

            // Handle tool calls
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    if let function = toolCall["function"] as? [String: Any],
                       let toolId = toolCall["id"] as? String,
                       let name = function["name"] as? String,
                       let arguments = function["arguments"] as? String,
                       let argData = arguments.data(using: .utf8),
                       let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] {
                        let sendableArgs = argDict.compactMapValues { value -> AnySendable? in
                            if let str = value as? String { return AnySendable(str) }
                            if let num = value as? Int { return AnySendable(num) }
                            if let bool = value as? Bool { return AnySendable(bool) }
                            return nil
                        }
                        content.append(.toolUse(AIToolUse(id: toolId, name: name, input: sendableArgs)))
                    }
                }
            }
        }

        let finishReason: AIFinishReason? = (json["choices"] as? [[String: Any]])?
            .first?["finish_reason"]
            .flatMap { $0 as? String }
            .flatMap {
                switch $0 {
                case "stop": return .stop
                case "length": return .length
                case "tool_calls": return .toolUse
                case "content_filter": return .contentFilter
                default: return nil
                }
            }

        var usage: AIUsage?
        if let usageDict = json["usage"] as? [String: Any],
           let promptTokens = usageDict["prompt_tokens"] as? Int,
           let completionTokens = usageDict["completion_tokens"] as? Int {
            usage = AIUsage(inputTokens: promptTokens, outputTokens: completionTokens)
        }

        return AICompletionResponse(
            id: id,
            content: content,
            model: model,
            finishReason: finishReason,
            usage: usage
        )
    }

    private func parseStreamChunk(_ jsonString: String) throws -> AIStreamChunk? {
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let id = json["id"] as? String

        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            return nil
        }

        var content: [AIContent] = []
        if let delta = firstChoice["delta"] as? [String: Any],
           let text = delta["content"] as? String {
            content.append(.text(text))
        }

        let finishReason: AIFinishReason? = (firstChoice["finish_reason"] as? String).flatMap {
            switch $0 {
            case "stop": return .stop
            case "length": return .length
            case "tool_calls": return .toolUse
            case "content_filter": return .contentFilter
            default: return nil
            }
        }

        var usage: AIUsage?
        if let usageDict = json["usage"] as? [String: Any],
           let promptTokens = usageDict["prompt_tokens"] as? Int,
           let completionTokens = usageDict["completion_tokens"] as? Int {
            usage = AIUsage(inputTokens: promptTokens, outputTokens: completionTokens)
        }

        return AIStreamChunk(id: id, content: content, finishReason: finishReason, usage: usage)
    }
}
