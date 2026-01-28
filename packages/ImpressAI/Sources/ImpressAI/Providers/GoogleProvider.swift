import Foundation

/// AI provider for Google's Gemini models.
public actor GoogleProvider: AIProvider {
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    private let credentialManager: AICredentialManager
    private let urlSession: URLSession

    public let metadata = AIProviderMetadata(
        id: "google",
        name: "Google AI",
        description: "Gemini models from Google",
        models: [
            AIModel(
                id: "gemini-2.0-flash",
                name: "Gemini 2.0 Flash",
                description: "Fast and versatile multimodal model",
                contextWindow: 1_000_000,
                maxOutputTokens: 8_192,
                isDefault: true,
                capabilities: .full
            ),
            AIModel(
                id: "gemini-2.0-flash-thinking-exp",
                name: "Gemini 2.0 Flash Thinking",
                description: "Enhanced reasoning capabilities",
                contextWindow: 1_000_000,
                maxOutputTokens: 64_000,
                capabilities: [.streaming, .vision, .tools, .systemPrompt, .jsonMode, .thinking]
            ),
            AIModel(
                id: "gemini-1.5-pro",
                name: "Gemini 1.5 Pro",
                description: "Best for complex reasoning tasks",
                contextWindow: 2_000_000,
                maxOutputTokens: 8_192,
                capabilities: .full
            ),
            AIModel(
                id: "gemini-1.5-flash",
                name: "Gemini 1.5 Flash",
                description: "Fast, efficient for high-volume tasks",
                contextWindow: 1_000_000,
                maxOutputTokens: 8_192,
                capabilities: .full
            ),
        ],
        capabilities: .full,
        credentialRequirement: .apiKey,
        category: .cloud,
        registrationURL: URL(string: "https://aistudio.google.com/apikey"),
        rateLimit: AIRateLimit(requestsPerInterval: 60, intervalSeconds: 60),
        iconName: "sparkles"
    )

    public init(credentialManager: AICredentialManager = .shared) {
        self.credentialManager = credentialManager
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.urlSession = URLSession(configuration: config)
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let apiKey = try await getAPIKey()
        let modelId = request.modelId ?? metadata.defaultModel?.id ?? "gemini-2.0-flash"
        let httpRequest = try buildRequest(request, modelId: modelId, apiKey: apiKey, stream: false)

        let (data, response) = try await urlSession.data(for: httpRequest)
        try validateResponse(response, data: data)

        return try parseResponse(data, modelId: modelId)
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let apiKey = try await getAPIKey()
        let modelId = request.modelId ?? metadata.defaultModel?.id ?? "gemini-2.0-flash"
        let httpRequest = try buildRequest(request, modelId: modelId, apiKey: apiKey, stream: true)

        let (bytes, response) = try await urlSession.bytes(for: httpRequest)
        try validateResponse(response, data: nil)

        return AsyncThrowingStream { continuation in
            Task {
                var buffer = ""
                do {
                    for try await line in bytes.lines {
                        buffer += line
                        // Google sends JSON objects separated by newlines
                        if let chunk = try? parseStreamChunk(buffer) {
                            continuation.yield(chunk)
                            buffer = ""
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
            throw AIError.unauthorized(message: "Google API key not configured")
        }
        return apiKey
    }

    private func buildRequest(_ request: AICompletionRequest, modelId: String, apiKey: String, stream: Bool) throws -> URLRequest {
        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent("models/\(modelId):\(endpoint)"), resolvingAgainstBaseURL: true)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var httpRequest = URLRequest(url: urlComponents.url!)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]

        // Build contents array
        var contents: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            let role = message.role == .assistant ? "model" : "user"
            var parts: [[String: Any]] = []

            for item in message.content {
                switch item {
                case .text(let text):
                    parts.append(["text": text])
                case .image(let image):
                    switch image.source {
                    case .base64(let data, let mediaType):
                        parts.append([
                            "inline_data": [
                                "mime_type": mediaType,
                                "data": data
                            ]
                        ])
                    case .url(let url):
                        // Gemini requires inline data, fetch the URL
                        parts.append(["text": "[Image: \(url.absoluteString)]"])
                    }
                default:
                    break
                }
            }

            contents.append(["role": role, "parts": parts])
        }
        body["contents"] = contents

        // System instruction
        if let systemPrompt = request.systemPrompt {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        } else if let systemMessage = request.messages.first(where: { $0.role == .system }) {
            body["systemInstruction"] = ["parts": [["text": systemMessage.text]]]
        }

        // Generation config
        var generationConfig: [String: Any] = [:]
        if let maxTokens = request.maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let temperature = request.temperature {
            generationConfig["temperature"] = temperature
        }
        if let topP = request.topP {
            generationConfig["topP"] = topP
        }
        if let stopSequences = request.stopSequences, !stopSequences.isEmpty {
            generationConfig["stopSequences"] = stopSequences
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
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
        case 401, 403:
            throw AIError.unauthorized(message: "Invalid API key")
        case 429:
            throw AIError.rateLimited(retryAfter: 60)
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data, modelId: String) throws -> AICompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parseError("Invalid JSON response")
        }

        var content: [AIContent] = []
        if let candidates = json["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let candidateContent = firstCandidate["content"] as? [String: Any],
           let parts = candidateContent["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String {
                    content.append(.text(text))
                }
            }
        }

        let finishReason: AIFinishReason? = (json["candidates"] as? [[String: Any]])?
            .first?["finishReason"]
            .flatMap { $0 as? String }
            .flatMap {
                switch $0 {
                case "STOP": return .stop
                case "MAX_TOKENS": return .length
                case "SAFETY": return .contentFilter
                default: return nil
                }
            }

        var usage: AIUsage?
        if let usageMetadata = json["usageMetadata"] as? [String: Any],
           let promptTokens = usageMetadata["promptTokenCount"] as? Int,
           let candidateTokens = usageMetadata["candidatesTokenCount"] as? Int {
            usage = AIUsage(inputTokens: promptTokens, outputTokens: candidateTokens)
        }

        return AICompletionResponse(
            id: UUID().uuidString,
            content: content,
            model: modelId,
            finishReason: finishReason,
            usage: usage
        )
    }

    private func parseStreamChunk(_ jsonString: String) throws -> AIStreamChunk? {
        // Google wraps streaming responses in an array
        var cleanedJson = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedJson.hasPrefix("[") { cleanedJson.removeFirst() }
        if cleanedJson.hasPrefix(",") { cleanedJson.removeFirst() }
        if cleanedJson.hasSuffix("]") { cleanedJson.removeLast() }

        guard let data = cleanedJson.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var content: [AIContent] = []
        if let candidates = json["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let candidateContent = firstCandidate["content"] as? [String: Any],
           let parts = candidateContent["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String {
                    content.append(.text(text))
                }
            }
        }

        let finishReason: AIFinishReason? = (json["candidates"] as? [[String: Any]])?
            .first?["finishReason"]
            .flatMap { $0 as? String }
            .flatMap {
                switch $0 {
                case "STOP": return .stop
                case "MAX_TOKENS": return .length
                case "SAFETY": return .contentFilter
                default: return nil
                }
            }

        return AIStreamChunk(content: content, finishReason: finishReason)
    }
}
