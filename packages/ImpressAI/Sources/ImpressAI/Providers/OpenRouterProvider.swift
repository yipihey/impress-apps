import Foundation

/// AI provider for OpenRouter, an AI model aggregator.
public actor OpenRouterProvider: AIProvider {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private let credentialManager: AICredentialManager
    private let urlSession: URLSession
    private var cachedModels: [AIModel]?
    private var lastModelFetch: Date?

    public nonisolated var metadata: AIProviderMetadata {
        AIProviderMetadata(
            id: "openrouter",
            name: "OpenRouter",
            description: "Access multiple AI providers through one API",
            models: defaultModels,
            capabilities: .full,
            credentialRequirement: .apiKey,
            category: .aggregator,
            registrationURL: URL(string: "https://openrouter.ai/keys"),
            iconName: "arrow.triangle.branch"
        )
    }

    /// Returns current models including dynamically discovered ones.
    public var currentModels: [AIModel] {
        cachedModels ?? defaultModels
    }

    private nonisolated let defaultModels: [AIModel] = [
        AIModel(
            id: "anthropic/claude-sonnet-4",
            name: "Claude Sonnet 4",
            description: "Anthropic's balanced model",
            contextWindow: 200_000,
            maxOutputTokens: 64_000,
            isDefault: true,
            capabilities: .full
        ),
        AIModel(
            id: "openai/gpt-4o",
            name: "GPT-4o",
            description: "OpenAI's multimodal flagship",
            contextWindow: 128_000,
            maxOutputTokens: 16_384,
            capabilities: .full
        ),
        AIModel(
            id: "google/gemini-2.0-flash-001",
            name: "Gemini 2.0 Flash",
            description: "Google's fast multimodal model",
            contextWindow: 1_000_000,
            maxOutputTokens: 8_192,
            capabilities: .full
        ),
        AIModel(
            id: "meta-llama/llama-3.3-70b-instruct",
            name: "Llama 3.3 70B",
            description: "Meta's open-weight model",
            contextWindow: 128_000,
            maxOutputTokens: 8_192,
            capabilities: .chat
        ),
        AIModel(
            id: "deepseek/deepseek-r1",
            name: "DeepSeek R1",
            description: "Advanced reasoning model",
            contextWindow: 128_000,
            maxOutputTokens: 8_192,
            capabilities: [.streaming, .systemPrompt, .thinking]
        ),
    ]

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

    /// Fetches available models from OpenRouter.
    public func refreshModels() async throws -> [AIModel] {
        let apiKey = try await getAPIKey()

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AIError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to fetch models")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["data"] as? [[String: Any]] else {
            throw AIError.parseError("Invalid models response")
        }

        let models = modelsArray.compactMap { modelDict -> AIModel? in
            guard let id = modelDict["id"] as? String,
                  let name = modelDict["name"] as? String else {
                return nil
            }

            let contextLength = modelDict["context_length"] as? Int
            let description = modelDict["description"] as? String

            // Parse capabilities from model data
            var capabilities: AICapabilities = .chat
            if modelDict["architecture"] as? [String: Any] != nil {
                capabilities.insert(.streaming)
            }

            return AIModel(
                id: id,
                name: name,
                description: description,
                contextWindow: contextLength,
                capabilities: capabilities
            )
        }

        self.cachedModels = models.isEmpty ? defaultModels : models
        self.lastModelFetch = Date()

        return self.cachedModels ?? defaultModels
    }

    // MARK: - Private Methods

    private func getAPIKey() async throws -> String {
        guard let apiKey = await credentialManager.retrieve(for: metadata.id, field: "apiKey"),
              !apiKey.isEmpty else {
            throw AIError.unauthorized(message: "OpenRouter API key not configured")
        }
        return apiKey
    }

    private func buildRequest(_ request: AICompletionRequest, apiKey: String, stream: Bool) throws -> URLRequest {
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("ImpressAI", forHTTPHeaderField: "HTTP-Referer")
        httpRequest.setValue("ImpressAI", forHTTPHeaderField: "X-Title")

        var body: [String: Any] = [
            "model": request.modelId ?? metadata.defaultModel?.id ?? "anthropic/claude-sonnet-4",
            "stream": stream
        ]

        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }

        // Build messages array (OpenAI format)
        var messages: [[String: Any]] = []

        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for message in request.messages {
            var msgDict: [String: Any] = ["role": message.role == .assistant ? "assistant" : message.role.rawValue]

            // Handle content
            if message.content.count == 1, case .text(let text) = message.content[0] {
                msgDict["content"] = text
            } else {
                msgDict["content"] = message.content.compactMap { item -> [String: Any]? in
                    switch item {
                    case .text(let text):
                        return ["type": "text", "text": text]
                    case .image(let image):
                        switch image.source {
                        case .base64(let data, let mediaType):
                            return [
                                "type": "image_url",
                                "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                            ]
                        case .url(let url):
                            return [
                                "type": "image_url",
                                "image_url": ["url": url.absoluteString]
                            ]
                        }
                    default:
                        return nil
                    }
                }
            }
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

        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
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
           let message = firstChoice["message"] as? [String: Any],
           let text = message["content"] as? String {
            content.append(.text(text))
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

        return AIStreamChunk(id: id, content: content, finishReason: finishReason)
    }
}
