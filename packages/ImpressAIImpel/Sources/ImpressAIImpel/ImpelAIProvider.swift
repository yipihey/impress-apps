import Foundation
import ImpressAI

/// AI provider that routes requests through Impel agent orchestration.
///
/// Impel provides multi-step reasoning and tool use through agent orchestration.
/// Requests are sent to the impel-server which coordinates agents to fulfill them.
///
/// Example usage:
/// ```swift
/// let provider = ImpelAIProvider()
/// await provider.setEndpoint(URL(string: "http://localhost:8080")!)
///
/// let request = AICompletionRequest(
///     modelId: "impel-research",
///     messages: [AIMessage(role: .user, text: "Research Swift concurrency best practices")]
/// )
/// let response = try await provider.complete(request)
/// ```
public actor ImpelAIProvider: AIProvider {
    private var endpoint: URL
    private var authToken: String?
    private let urlSession: URLSession
    private let credentialManager: AICredentialManager

    public let metadata = AIProviderMetadata(
        id: "impel",
        name: "Impel Agents",
        description: "Multi-step AI agents with tool use and reasoning",
        models: [
            AIModel(
                id: "impel-auto",
                name: "Auto (Recommended)",
                description: "Automatically selects the best agent for the task",
                isDefault: true,
                capabilities: [.streaming, .tools, .systemPrompt, .thinking]
            ),
            AIModel(
                id: "impel-research",
                name: "Research Agent",
                description: "Specialized for research and information gathering",
                capabilities: [.streaming, .tools, .systemPrompt]
            ),
            AIModel(
                id: "impel-code",
                name: "Code Agent",
                description: "Specialized for code analysis and generation",
                capabilities: [.streaming, .tools, .systemPrompt]
            ),
            AIModel(
                id: "impel-writing",
                name: "Writing Agent",
                description: "Specialized for writing and editing tasks",
                capabilities: [.streaming, .systemPrompt]
            ),
            AIModel(
                id: "impel-analysis",
                name: "Analysis Agent",
                description: "Specialized for data analysis and reasoning",
                capabilities: [.streaming, .tools, .systemPrompt, .thinking]
            ),
        ],
        capabilities: [.streaming, .tools, .systemPrompt, .thinking],
        credentialRequirement: .custom([
            AICredentialField(
                id: "endpoint",
                label: "Impel Server URL",
                placeholder: "http://localhost:8080",
                isSecret: false
            ),
            AICredentialField(
                id: "authToken",
                label: "Auth Token",
                placeholder: "Optional authentication token",
                isSecret: true,
                isOptional: true
            )
        ]),
        category: .agent,
        registrationURL: nil,
        iconName: "wand.and.stars"
    )

    public init(
        endpoint: URL = URL(string: "http://localhost:8080")!,
        credentialManager: AICredentialManager = .shared
    ) {
        self.endpoint = endpoint
        self.credentialManager = credentialManager

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // Agent tasks can take longer
        self.urlSession = URLSession(configuration: config)
    }

    /// Updates the server endpoint.
    public func setEndpoint(_ url: URL) {
        self.endpoint = url
    }

    /// Updates the authentication token.
    public func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        try await loadCredentials()

        let httpRequest = try buildRequest(request, stream: false)
        let (data, response) = try await urlSession.data(for: httpRequest)

        try validateResponse(response, data: data)
        return try parseResponse(data, modelId: request.modelId ?? "impel-auto")
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        try await loadCredentials()

        let httpRequest = try buildRequest(request, stream: true)
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
                            if let chunk = try? parseStreamEvent(jsonString) {
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
        try await loadCredentials()

        do {
            // Try to connect to the health endpoint
            var request = URLRequest(url: endpoint.appendingPathComponent("health"))
            request.timeoutInterval = 5

            if let token = authToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (_, response) = try await urlSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200..<300:
                    return .ready
                case 401, 403:
                    return .needsCredentials(["authToken"])
                default:
                    return .unavailable(reason: "Server returned status \(httpResponse.statusCode)")
                }
            }

            return .unavailable(reason: "Invalid response from server")
        } catch let error as URLError {
            return .unavailable(reason: "Cannot connect to Impel server: \(error.localizedDescription)")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func loadCredentials() async throws {
        if let storedEndpoint = await credentialManager.retrieve(for: metadata.id, field: "endpoint"),
           let url = URL(string: storedEndpoint) {
            self.endpoint = url
        }

        if let storedToken = await credentialManager.retrieve(for: metadata.id, field: "authToken") {
            self.authToken = storedToken
        }
    }

    private func buildRequest(_ request: AICompletionRequest, stream: Bool) throws -> URLRequest {
        var httpRequest = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = authToken, !token.isEmpty {
            httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let agentType = mapModelToAgent(request.modelId ?? "impel-auto")

        var body: [String: Any] = [
            "agent": agentType,
            "stream": stream
        ]

        // Build messages array
        var messages: [[String: Any]] = []

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

        // Agent-specific options
        var options: [String: Any] = [:]
        if let maxTokens = request.maxTokens {
            options["maxTokens"] = maxTokens
        }
        if let temperature = request.temperature {
            options["temperature"] = temperature
        }

        // Enable extended thinking for analysis tasks
        if agentType == "analysis" || agentType == "auto" {
            options["enableThinking"] = true
        }

        if !options.isEmpty {
            body["options"] = options
        }

        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
    }

    private func mapModelToAgent(_ modelId: String) -> String {
        switch modelId {
        case "impel-research": return "research"
        case "impel-code": return "code"
        case "impel-writing": return "writing"
        case "impel-analysis": return "analysis"
        default: return "auto"
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError(underlying: URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AIError.unauthorized(message: "Invalid or missing authentication token")
        case 429:
            throw AIError.rateLimited(retryAfter: 60)
        case 503:
            throw AIError.providerNotConfigured("Impel server is not available")
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data, modelId: String) throws -> AICompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parseError("Invalid JSON response")
        }

        let id = json["id"] as? String ?? UUID().uuidString

        var content: [AIContent] = []

        // Parse main response
        if let responseText = json["response"] as? String {
            content.append(.text(responseText))
        }

        // Parse thinking/reasoning if present
        if let thinking = json["thinking"] as? String {
            content.insert(.text("[Thinking]\n\(thinking)\n\n"), at: 0)
        }

        // Parse agent steps if present
        if let steps = json["steps"] as? [[String: Any]] {
            var stepsText = "[Agent Steps]\n"
            for (index, step) in steps.enumerated() {
                if let action = step["action"] as? String,
                   let result = step["result"] as? String {
                    stepsText += "\(index + 1). \(action): \(result)\n"
                }
            }
            content.insert(.text(stepsText + "\n"), at: 0)
        }

        let finishReason: AIFinishReason = json["finishReason"] as? String == "stop" ? .stop : .stop

        var usage: AIUsage?
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["inputTokens"] as? Int,
           let outputTokens = usageDict["outputTokens"] as? Int {
            usage = AIUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        }

        return AICompletionResponse(
            id: id,
            content: content,
            model: "impel-\(modelId)",
            finishReason: finishReason,
            usage: usage
        )
    }

    private func parseStreamEvent(_ jsonString: String) throws -> AIStreamChunk? {
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let eventType = json["type"] as? String ?? "content"

        var content: [AIContent] = []

        switch eventType {
        case "thinking":
            if let text = json["content"] as? String {
                content.append(.text("[Thinking] \(text)"))
            }
        case "step":
            if let action = json["action"] as? String,
               let result = json["result"] as? String {
                content.append(.text("[Step] \(action): \(result)\n"))
            }
        case "content", "delta":
            if let text = json["content"] as? String ?? json["text"] as? String {
                content.append(.text(text))
            }
        case "done", "finish":
            return AIStreamChunk(
                content: [],
                finishReason: .stop,
                usage: parseUsage(from: json)
            )
        default:
            // Unknown event type, try to extract content
            if let text = json["content"] as? String {
                content.append(.text(text))
            }
        }

        return AIStreamChunk(content: content)
    }

    private func parseUsage(from json: [String: Any]) -> AIUsage? {
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["inputTokens"] as? Int,
           let outputTokens = usageDict["outputTokens"] as? Int {
            return AIUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        }
        return nil
    }
}

/// Extension to register Impel provider with the manager.
public extension AIProviderManager {
    /// Registers the Impel AI provider.
    func registerImpelProvider() async {
        register(ImpelAIProvider())
    }
}
