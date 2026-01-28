import Foundation

/// AI provider for Anthropic's Claude models.
public actor AnthropicProvider: AIProvider {
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private let credentialManager: AICredentialManager
    private let urlSession: URLSession

    public let metadata = AIProviderMetadata(
        id: "anthropic",
        name: "Claude (Anthropic)",
        description: "Claude AI models from Anthropic",
        models: [
            AIModel(
                id: "claude-sonnet-4-20250514",
                name: "Claude Sonnet 4",
                description: "Best combination of speed and intelligence",
                contextWindow: 200_000,
                maxOutputTokens: 64_000,
                isDefault: true,
                capabilities: .full
            ),
            AIModel(
                id: "claude-opus-4-20250514",
                name: "Claude Opus 4",
                description: "Most capable model for complex tasks",
                contextWindow: 200_000,
                maxOutputTokens: 32_000,
                capabilities: [.streaming, .vision, .tools, .systemPrompt, .jsonMode, .thinking]
            ),
            AIModel(
                id: "claude-3-5-haiku-20241022",
                name: "Claude 3.5 Haiku",
                description: "Fastest model for simple tasks",
                contextWindow: 200_000,
                maxOutputTokens: 8_192,
                capabilities: .full
            ),
        ],
        capabilities: .full,
        credentialRequirement: .apiKey,
        category: .cloud,
        registrationURL: URL(string: "https://console.anthropic.com/account/keys"),
        rateLimit: AIRateLimit(requestsPerInterval: 50, intervalSeconds: 60),
        iconName: "brain.head.profile"
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
                                if chunk.finishReason != nil {
                                    continuation.finish()
                                    return
                                }
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

        // Optional: Make a lightweight API call to verify the key
        return .ready
    }

    // MARK: - Private Methods

    private func getAPIKey() async throws -> String {
        guard let apiKey = await credentialManager.retrieve(for: metadata.id, field: "apiKey"),
              !apiKey.isEmpty else {
            throw AIError.unauthorized(message: "Anthropic API key not configured")
        }
        return apiKey
    }

    private func buildRequest(_ request: AICompletionRequest, apiKey: String, stream: Bool) throws -> URLRequest {
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        httpRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": request.modelId ?? metadata.defaultModel?.id ?? "claude-sonnet-4-20250514",
            "max_tokens": request.maxTokens ?? 4096,
            "stream": stream
        ]

        // Build messages array
        var messages: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            var msgDict: [String: Any] = ["role": message.role.rawValue]
            msgDict["content"] = buildContent(message.content)
            messages.append(msgDict)
        }
        body["messages"] = messages

        // System prompt
        if let systemPrompt = request.systemPrompt {
            body["system"] = systemPrompt
        } else if let systemMessage = request.messages.first(where: { $0.role == .system }) {
            body["system"] = systemMessage.text
        }

        // Optional parameters
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let topP = request.topP {
            body["top_p"] = topP
        }
        if let stopSequences = request.stopSequences, !stopSequences.isEmpty {
            body["stop_sequences"] = stopSequences
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
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": data
                        ]
                    ]
                case .url(let url):
                    return [
                        "type": "image",
                        "source": [
                            "type": "url",
                            "url": url.absoluteString
                        ]
                    ]
                }
            case .toolUse(let toolUse):
                return [
                    "type": "tool_use",
                    "id": toolUse.id,
                    "name": toolUse.name,
                    "input": toolUse.input
                ]
            case .toolResult(let toolResult):
                return [
                    "type": "tool_result",
                    "tool_use_id": toolResult.toolUseId,
                    "content": toolResult.content,
                    "is_error": toolResult.isError
                ]
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
        if let contentArray = json["content"] as? [[String: Any]] {
            for item in contentArray {
                if let type = item["type"] as? String {
                    switch type {
                    case "text":
                        if let text = item["text"] as? String {
                            content.append(.text(text))
                        }
                    case "tool_use":
                        if let toolId = item["id"] as? String,
                           let name = item["name"] as? String,
                           let input = item["input"] as? [String: Any] {
                            let sendableInput = input.mapValues { AnySendable($0 as! String) }
                            content.append(.toolUse(AIToolUse(id: toolId, name: name, input: sendableInput)))
                        }
                    default:
                        break
                    }
                }
            }
        }

        let finishReason: AIFinishReason? = (json["stop_reason"] as? String).flatMap {
            switch $0 {
            case "end_turn", "stop_sequence": return .stop
            case "max_tokens": return .length
            case "tool_use": return .toolUse
            default: return nil
            }
        }

        var usage: AIUsage?
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["input_tokens"] as? Int,
           let outputTokens = usageDict["output_tokens"] as? Int {
            usage = AIUsage(inputTokens: inputTokens, outputTokens: outputTokens)
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

        let type = json["type"] as? String

        switch type {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return AIStreamChunk(content: [.text(text)])
            }
        case "message_delta":
            let finishReason: AIFinishReason? = (json["delta"] as? [String: Any])?["stop_reason"]
                .flatMap { $0 as? String }
                .flatMap {
                    switch $0 {
                    case "end_turn", "stop_sequence": return .stop
                    case "max_tokens": return .length
                    case "tool_use": return .toolUse
                    default: return nil
                    }
                }

            var usage: AIUsage?
            if let usageDict = json["usage"] as? [String: Any],
               let outputTokens = usageDict["output_tokens"] as? Int {
                usage = AIUsage(inputTokens: 0, outputTokens: outputTokens)
            }

            return AIStreamChunk(content: [], finishReason: finishReason, usage: usage)
        default:
            break
        }

        return nil
    }
}
