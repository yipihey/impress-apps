import Foundation

/// AI provider for locally-running Ollama models.
public actor OllamaProvider: AIProvider {
    private var baseURL: URL
    private let urlSession: URLSession
    private var cachedModels: [AIModel]?
    private var lastModelFetch: Date?

    public nonisolated var metadata: AIProviderMetadata {
        AIProviderMetadata(
            id: "ollama",
            name: "Ollama",
            description: "Local AI models via Ollama",
            models: defaultModels,
            capabilities: .chat,
            credentialRequirement: .custom([
                AICredentialField(
                    id: "endpoint",
                    label: "Server URL",
                    placeholder: "http://localhost:11434",
                    isSecret: false,
                    isOptional: true
                )
            ]),
            category: .local,
            registrationURL: URL(string: "https://ollama.ai"),
            iconName: "desktopcomputer"
        )
    }

    /// Returns current models including dynamically discovered ones.
    public var currentModels: [AIModel] {
        cachedModels ?? defaultModels
    }

    private nonisolated let defaultModels: [AIModel] = [
        AIModel(
            id: "llama3.2",
            name: "Llama 3.2",
            description: "Meta's latest open model",
            contextWindow: 128_000,
            isDefault: true,
            capabilities: .chat
        ),
        AIModel(
            id: "qwen2.5",
            name: "Qwen 2.5",
            description: "Alibaba's multilingual model",
            contextWindow: 128_000,
            capabilities: .chat
        ),
        AIModel(
            id: "mistral",
            name: "Mistral",
            description: "Efficient open model",
            contextWindow: 32_000,
            capabilities: .chat
        ),
        AIModel(
            id: "codellama",
            name: "Code Llama",
            description: "Specialized for code generation",
            contextWindow: 100_000,
            capabilities: .chat
        ),
    ]

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? URL(string: "http://localhost:11434")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // Local models can be slower
        self.urlSession = URLSession(configuration: config)
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        try await refreshModelsIfNeeded()
        let httpRequest = try buildRequest(request, stream: false)

        let (data, response) = try await urlSession.data(for: httpRequest)
        try validateResponse(response, data: data)

        return try parseResponse(data, modelId: request.modelId ?? "llama3.2")
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        try await refreshModelsIfNeeded()
        let httpRequest = try buildRequest(request, stream: true)

        let (bytes, response) = try await urlSession.bytes(for: httpRequest)
        try validateResponse(response, data: nil)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        if let chunk = try? parseStreamChunk(line) {
                            continuation.yield(chunk)
                            if chunk.finishReason != nil {
                                continuation.finish()
                                return
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
        do {
            let url = baseURL.appendingPathComponent("api/tags")
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let (_, response) = try await urlSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                return .ready
            }
            return .unavailable(reason: "Ollama server not responding")
        } catch {
            return .unavailable(reason: "Cannot connect to Ollama at \(baseURL.absoluteString)")
        }
    }

    /// Updates the server endpoint.
    public func setEndpoint(_ url: URL) {
        self.baseURL = url
        self.cachedModels = nil
        self.lastModelFetch = nil
    }

    /// Fetches available models from the Ollama server.
    public func refreshModels() async throws -> [AIModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, response) = try await urlSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AIError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to fetch models")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]] else {
            throw AIError.parseError("Invalid models response")
        }

        let models = modelsArray.compactMap { modelDict -> AIModel? in
            guard let name = modelDict["name"] as? String else { return nil }

            // Parse model details
            let details = modelDict["details"] as? [String: Any]
            let parameterSize = details?["parameter_size"] as? String

            return AIModel(
                id: name,
                name: name.replacingOccurrences(of: ":latest", with: ""),
                description: parameterSize.map { "Parameters: \($0)" },
                capabilities: .chat
            )
        }

        self.cachedModels = models.isEmpty ? defaultModels : models
        self.lastModelFetch = Date()

        return self.cachedModels ?? defaultModels
    }

    // MARK: - Private Methods

    private func refreshModelsIfNeeded() async throws {
        // Refresh models every 5 minutes or if never fetched
        let shouldRefresh = lastModelFetch == nil ||
            Date().timeIntervalSince(lastModelFetch!) > 300

        if shouldRefresh {
            _ = try? await refreshModels()
        }
    }

    private func buildRequest(_ request: AICompletionRequest, stream: Bool) throws -> URLRequest {
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": request.modelId ?? "llama3.2",
            "stream": stream
        ]

        // Build messages array
        var messages: [[String: Any]] = []

        // Add system prompt
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for message in request.messages {
            messages.append([
                "role": message.role.rawValue,
                "content": message.text
            ])
        }
        body["messages"] = messages

        // Options
        var options: [String: Any] = [:]
        if let temperature = request.temperature {
            options["temperature"] = temperature
        }
        if let topP = request.topP {
            options["top_p"] = topP
        }
        if let maxTokens = request.maxTokens {
            options["num_predict"] = maxTokens
        }
        if let stopSequences = request.stopSequences, !stopSequences.isEmpty {
            options["stop"] = stopSequences
        }
        if !options.isEmpty {
            body["options"] = options
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
        case 404:
            throw AIError.modelNotFound("Model not found. Run 'ollama pull <model>' to download it.")
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
        if let message = json["message"] as? [String: Any],
           let text = message["content"] as? String {
            content.append(.text(text))
        }

        let done = json["done"] as? Bool ?? true

        var usage: AIUsage?
        if let promptEvalCount = json["prompt_eval_count"] as? Int,
           let evalCount = json["eval_count"] as? Int {
            usage = AIUsage(inputTokens: promptEvalCount, outputTokens: evalCount)
        }

        return AICompletionResponse(
            id: UUID().uuidString,
            content: content,
            model: modelId,
            finishReason: done ? .stop : nil,
            usage: usage
        )
    }

    private func parseStreamChunk(_ jsonString: String) throws -> AIStreamChunk? {
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var content: [AIContent] = []
        if let message = json["message"] as? [String: Any],
           let text = message["content"] as? String,
           !text.isEmpty {
            content.append(.text(text))
        }

        let done = json["done"] as? Bool ?? false

        var usage: AIUsage?
        if done {
            if let promptEvalCount = json["prompt_eval_count"] as? Int,
               let evalCount = json["eval_count"] as? Int {
                usage = AIUsage(inputTokens: promptEvalCount, outputTokens: evalCount)
            }
        }

        return AIStreamChunk(
            content: content,
            finishReason: done ? .stop : nil,
            usage: usage
        )
    }
}
