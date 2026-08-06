import Foundation
import ImpressLogging

/// A local or self-hosted server exposing the OpenAI `/v1` API.
///
/// This intentionally is not tied to one runtime. It supports OMLX, vLLM,
/// llama.cpp, LM Studio, and other compatible servers through one suite-wide
/// endpoint and optional bearer token.
public actor OpenAICompatibleProvider: AIModelDiscoveringProvider, AIServiceActivatingProvider {
    public static let providerId = "openai-compatible"
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8000/v1")!

    public let metadata = AIProviderMetadata(
        id: providerId,
        name: "Local OpenAI-compatible server",
        description: "OMLX, vLLM, llama.cpp, LM Studio, or another OpenAI-compatible /v1 endpoint",
        models: [],
        capabilities: [.streaming, .tools, .systemPrompt, .jsonMode],
        credentialRequirement: .custom([
            AICredentialField(
                id: "endpoint",
                label: "Base URL",
                placeholder: "http://127.0.0.1:8000/v1",
                isOptional: true
            ),
            AICredentialField(
                id: "apiKey",
                label: "Bearer token",
                placeholder: "Optional unless server authentication is enabled",
                isSecret: true,
                isOptional: true
            ),
        ]),
        category: .local,
        iconName: "server.rack"
    )

    private let credentialManager: AICredentialManager
    private let explicitEndpoint: URL?
    private let explicitAPIKey: String?
    private let urlSession: URLSession
    private let serviceStarter: any OMLXServiceStarting
    private let automaticallyStartOMLX: Bool
    private let startupTimeout: TimeInterval
    private let startupPollInterval: TimeInterval

    public init(
        credentialManager: AICredentialManager = .shared,
        endpoint: URL? = nil,
        apiKey: String? = nil,
        urlSession: URLSession? = nil,
        serviceStarter: any OMLXServiceStarting = OMLXServiceController.shared,
        automaticallyStartOMLX: Bool = true,
        startupTimeout: TimeInterval = 60,
        startupPollInterval: TimeInterval = 0.5
    ) {
        self.credentialManager = credentialManager
        self.explicitEndpoint = endpoint
        self.explicitAPIKey = apiKey
        self.serviceStarter = serviceStarter
        self.automaticallyStartOMLX = automaticallyStartOMLX
        self.startupTimeout = startupTimeout
        self.startupPollInterval = startupPollInterval
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 300
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    public func discoverModels() async throws -> [AIModel] {
        try await fetchModels()
    }

    private func fetchModels() async throws -> [AIModel] {
        var request = URLRequest(url: try await baseURL().appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        try await authorize(&request)

        let (data, response) = try await urlSession.data(for: request)
        try validateResponse(response, data: data)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else {
            throw AIError.parseError("The server returned an invalid /models response")
        }

        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return AIModel(
                id: id,
                name: id,
                description: "Discovered from the configured server",
                isDefault: false,
                capabilities: metadata.capabilities
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        do {
            return try await performCompletion(request)
        } catch {
            guard try await recoverOMLXIfEligible(after: error) else { throw error }
            return try await performCompletion(request)
        }
    }

    private func performCompletion(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let modelId = try await resolveModelId(request.modelId)
        let httpRequest = try await buildRequest(request, modelId: modelId, stream: false)
        let (data, response) = try await urlSession.data(for: httpRequest)
        try validateResponse(response, data: data)
        return try parseResponse(data)
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        do {
            return try await performStream(request)
        } catch {
            guard try await recoverOMLXIfEligible(after: error) else { throw error }
            return try await performStream(request)
        }
    }

    private func performStream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let modelId = try await resolveModelId(request.modelId)
        let httpRequest = try await buildRequest(request, modelId: modelId, stream: true)
        let (bytes, response) = try await urlSession.bytes(for: httpRequest)
        try validateResponse(response, data: nil)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        if let chunk = try parseStreamChunk(payload) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.from(error))
                }
            }
        }
    }

    /// Starts oMLX only when this provider points at oMLX's conventional local
    /// endpoint and that endpoint is unreachable. This method is reserved for
    /// explicit actions such as Test Connection; `validate()` stays passive.
    public func activateServiceIfNeeded() async throws {
        do {
            _ = try await fetchModels()
        } catch {
            guard try await recoverOMLXIfEligible(after: error) else { throw error }
        }
    }

    public func validate() async throws -> AIProviderStatus {
        do {
            let models = try await discoverModels()
            return models.isEmpty ? .unavailable(reason: "The server is reachable but reports no loaded models") : .ready
        } catch let error as AIError {
            return .unavailable(reason: error.localizedDescription)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    private func recoverOMLXIfEligible(after error: Error) async throws -> Bool {
        let endpoint = try await baseURL()
        guard automaticallyStartOMLX,
              Self.isManagedOMLXEndpoint(endpoint),
              Self.isConnectionFailure(error)
        else {
            return false
        }

        logInfo(
            "Local AI endpoint is unreachable; requesting oMLX startup",
            category: "ai.local-service"
        )
        try await serviceStarter.startOMLX()
        try await waitForServiceReadiness()
        return true
    }

    private func waitForServiceReadiness() async throws {
        let deadline = Date().addingTimeInterval(startupTimeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                _ = try await fetchModels()
                logInfo("oMLX model endpoint is ready", category: "ai.local-service")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            let nanoseconds = UInt64(max(0.01, startupPollInterval) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }

        let detail = lastError?.localizedDescription ?? "No response from /v1/models"
        logError(
            "oMLX did not become ready within \(Int(startupTimeout))s: \(detail)",
            category: "ai.local-service"
        )
        throw AIError.providerNotConfigured(
            "oMLX was launched but did not become ready within \(Int(startupTimeout)) seconds. \(detail)"
        )
    }

    private static func isManagedOMLXEndpoint(_ endpoint: URL) -> Bool {
        #if os(macOS)
        guard endpoint.scheme?.lowercased() == "http",
              endpoint.port == 8000,
              let host = endpoint.host?.lowercased()
        else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
        #else
        return false
        #endif
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        if let aiError = error as? AIError,
           case .networkError(let underlying) = aiError {
            return isConnectionFailure(underlying)
        }

        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
    }

    private func baseURL() async throws -> URL {
        if let explicitEndpoint { return explicitEndpoint }
        if let value = await credentialManager.retrieve(for: metadata.id, field: "endpoint"),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
                throw AIError.invalidRequest("The OpenAI-compatible base URL must be an http(s) URL")
            }
            return url
        }
        return Self.defaultEndpoint
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let storedAPIKey = await credentialManager.retrieve(for: metadata.id, field: "apiKey")
        let apiKey = explicitAPIKey ?? storedAPIKey
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func resolveModelId(_ requested: String?) async throws -> String {
        if let requested, !requested.isEmpty { return requested }
        guard let first = try await discoverModels().first else {
            throw AIError.providerNotConfigured("The OpenAI-compatible server reports no loaded models")
        }
        return first.id
    }

    private func buildRequest(
        _ request: AICompletionRequest,
        modelId: String,
        stream: Bool
    ) async throws -> URLRequest {
        var httpRequest = URLRequest(url: try await baseURL().appendingPathComponent("chat/completions"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await authorize(&httpRequest)

        var body: [String: Any] = [
            "model": modelId,
            "stream": stream,
            "messages": buildMessages(request),
        ]
        if let maxTokens = request.maxTokens { body["max_tokens"] = maxTokens }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if let topP = request.topP { body["top_p"] = topP }
        if let stopSequences = request.stopSequences, !stopSequences.isEmpty { body["stop"] = stopSequences }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.mapValues { $0.toJSONValue() },
                    ],
                ]
            }
        }
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
    }

    private func buildMessages(_ request: AICompletionRequest) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            result.append(["role": "system", "content": systemPrompt])
        }

        for message in request.messages {
            let toolResults = message.content.compactMap { content -> AIToolResult? in
                guard case .toolResult(let result) = content else { return nil }
                return result
            }
            if !toolResults.isEmpty {
                for toolResult in toolResults {
                    result.append([
                        "role": "tool",
                        "tool_call_id": toolResult.toolUseId,
                        "content": toolResult.content,
                    ])
                }
                continue
            }

            var row: [String: Any] = ["role": message.role.rawValue]
            let text = message.text
            row["content"] = text.isEmpty ? NSNull() : text

            let toolUses = message.content.compactMap { content -> AIToolUse? in
                guard case .toolUse(let use) = content else { return nil }
                return use
            }
            if !toolUses.isEmpty {
                row["tool_calls"] = toolUses.map { use in
                    let arguments = use.input.mapValues { $0.toJSONValue() }
                    let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                    return [
                        "id": use.id,
                        "type": "function",
                        "function": [
                            "name": use.name,
                            "arguments": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                        ],
                    ]
                }
            }
            result.append(row)
        }
        return result
    }

    private func validateResponse(_ response: URLResponse, data: Data?) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AIError.networkError(underlying: URLError(.badServerResponse))
        }
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AIError.unauthorized(message: "The server rejected the bearer token")
        case 429:
            throw AIError.rateLimited(
                retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw AIError.apiError(statusCode: response.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data) throws -> AICompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else { throw AIError.parseError("The server returned an invalid chat completion") }

        var content: [AIContent] = []
        if let text = message["content"] as? String, !text.isEmpty { content.append(.text(text)) }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String,
                      let argumentData = arguments.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any]
                else { continue }
                content.append(.toolUse(AIToolUse(
                    id: id,
                    name: name,
                    input: object.mapValues(AnySendable.fromJSON)
                )))
            }
        }

        return AICompletionResponse(
            id: json["id"] as? String ?? UUID().uuidString,
            content: content,
            model: json["model"] as? String ?? "",
            finishReason: finishReason(choice["finish_reason"] as? String),
            usage: parseUsage(json["usage"] as? [String: Any])
        )
    }

    private func parseStreamChunk(_ string: String) throws -> AIStreamChunk? {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first
        else { return nil }
        let text = (choice["delta"] as? [String: Any])?["content"] as? String
        return AIStreamChunk(
            id: json["id"] as? String,
            content: text.map { [.text($0)] } ?? [],
            finishReason: finishReason(choice["finish_reason"] as? String),
            usage: parseUsage(json["usage"] as? [String: Any])
        )
    }

    private func finishReason(_ value: String?) -> AIFinishReason? {
        switch value {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls": return .toolUse
        case "content_filter": return .contentFilter
        default: return nil
        }
    }

    private func parseUsage(_ value: [String: Any]?) -> AIUsage? {
        guard let value,
              let input = value["prompt_tokens"] as? Int,
              let output = value["completion_tokens"] as? Int
        else { return nil }
        return AIUsage(inputTokens: input, outputTokens: output)
    }
}
