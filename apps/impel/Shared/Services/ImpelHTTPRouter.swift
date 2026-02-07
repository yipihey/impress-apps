//
//  ImpelHTTPRouter.swift
//  impel
//
//  Route parsing and response handling for HTTP automation API.
//  Implements JSON REST endpoints for AI agent and MCP integration.
//

import Foundation
import ImpressAutomation
import ImpelCore
import OSLog

private let routerLogger = Logger(subsystem: "com.impress.impel", category: "httpRouter")

// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers for impel's thread/agent/escalation API.
///
/// API matches the MCP client contract defined in `impress-mcp/src/impel/client.ts`.
public actor ImpelHTTPRouter: HTTPRouter {

    // MARK: - Initialization

    public init() {}

    // MARK: - Routing

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return handleCORSPreflight()
        }

        let path = request.path
        let pathLower = path.lowercased()

        // GET endpoints
        if request.method == "GET" {
            if pathLower == "/status" || pathLower == "/api/status" {
                return await handleStatus()
            }
            if pathLower == "/api/logs" {
                return await handleGetLogs(request)
            }

            // Threads
            if pathLower == "/threads" {
                return await handleListThreads(request)
            }
            if pathLower == "/threads/available" {
                return await handleAvailableThreads()
            }
            if pathLower.hasPrefix("/threads/") {
                let remainder = String(path.dropFirst("/threads/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/events") {
                    let threadId = String(remainder.dropLast("/events".count))
                    return await handleThreadEvents(id: threadId)
                }
                if !remainder.contains("/") {
                    return await handleGetThread(id: remainder)
                }
            }

            // Personas
            if pathLower == "/personas" {
                return await handleListPersonas()
            }
            if pathLower.hasPrefix("/personas/") {
                let id = String(path.dropFirst("/personas/".count))
                if !id.contains("/") {
                    return await handleGetPersona(id: id)
                }
            }

            // Agents
            if pathLower == "/agents" {
                return await handleListAgents()
            }
            if pathLower.hasPrefix("/agents/") {
                let remainder = String(path.dropFirst("/agents/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/next-thread") {
                    let agentId = String(remainder.dropLast("/next-thread".count))
                    return await handleNextThread(agentId: agentId, request: request)
                }
                if !remainder.contains("/") {
                    return await handleGetAgent(id: remainder)
                }
            }

            // Escalations
            if pathLower == "/escalations" {
                return await handleListEscalations(request)
            }
            if pathLower.hasPrefix("/escalations/") {
                let remainder = String(path.dropFirst("/escalations/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/poll") {
                    let escId = String(remainder.dropLast("/poll".count))
                    return await handlePollEscalation(id: escId, request: request)
                }
                if !remainder.contains("/") {
                    return await handleGetEscalation(id: remainder)
                }
            }

            // Events
            if pathLower == "/events" {
                return await handleEvents(request)
            }
        }

        // POST endpoints
        if request.method == "POST" {
            if pathLower == "/threads" {
                return await handleCreateThread(request)
            }
            if pathLower.hasPrefix("/threads/") {
                let remainder = String(path.dropFirst("/threads/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/claim") {
                    let threadId = String(remainder.dropLast("/claim".count))
                    return await handleClaimThread(id: threadId, request: request)
                }
                if remainderLower.hasSuffix("/release") {
                    let threadId = String(remainder.dropLast("/release".count))
                    return await handleReleaseThread(id: threadId)
                }
            }

            if pathLower == "/agents" {
                return await handleRegisterAgent(request)
            }

            if pathLower == "/escalations" {
                return await handleCreateEscalation(request)
            }
        }

        // PUT endpoints
        if request.method == "PUT" {
            if pathLower.hasPrefix("/threads/") {
                let remainder = String(path.dropFirst("/threads/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/activate") {
                    let threadId = String(remainder.dropLast("/activate".count))
                    return await handleActivateThread(id: threadId)
                }
                if remainderLower.hasSuffix("/block") {
                    let threadId = String(remainder.dropLast("/block".count))
                    return await handleBlockThread(id: threadId, request: request)
                }
                if remainderLower.hasSuffix("/unblock") {
                    let threadId = String(remainder.dropLast("/unblock".count))
                    return await handleUnblockThread(id: threadId)
                }
                if remainderLower.hasSuffix("/review") {
                    let threadId = String(remainder.dropLast("/review".count))
                    return await handleReviewThread(id: threadId)
                }
                if remainderLower.hasSuffix("/complete") {
                    let threadId = String(remainder.dropLast("/complete".count))
                    return await handleCompleteThread(id: threadId)
                }
                if remainderLower.hasSuffix("/kill") {
                    let threadId = String(remainder.dropLast("/kill".count))
                    return await handleKillThread(id: threadId, request: request)
                }
                if remainderLower.hasSuffix("/temperature") {
                    let threadId = String(remainder.dropLast("/temperature".count))
                    return await handleSetTemperature(id: threadId, request: request)
                }
            }

            if pathLower.hasPrefix("/escalations/") {
                let remainder = String(path.dropFirst("/escalations/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/acknowledge") {
                    let escId = String(remainder.dropLast("/acknowledge".count))
                    return await handleAcknowledgeEscalation(id: escId, request: request)
                }
                if remainderLower.hasSuffix("/resolve") {
                    let escId = String(remainder.dropLast("/resolve".count))
                    return await handleResolveEscalation(id: escId, request: request)
                }
            }
        }

        // DELETE endpoints
        if request.method == "DELETE" {
            if pathLower.hasPrefix("/agents/") {
                let id = String(path.dropFirst("/agents/".count))
                if !id.contains("/") {
                    return await handleUnregisterAgent(id: id, request: request)
                }
            }
        }

        // Root
        if pathLower == "/" || pathLower == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - Status

    /// GET /status, GET /api/status
    private func handleStatus() async -> HTTPResponse {
        let state = await getState()

        return .json([
            "status": "ok",
            "app": "impel",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "port": ImpelHTTPServer.defaultPort,
            "threads": state.threads.count,
            "activeThreads": state.activeThreads.count,
            "agents": state.agents.count,
            "workingAgents": state.workingAgents.count,
            "personas": state.personas.count,
            "escalations": state.escalations.count,
            "pendingEscalations": state.pendingEscalations.count
        ])
    }

    /// GET /api/logs
    private func handleGetLogs(_ request: HTTPRequest) async -> HTTPResponse {
        await MainActor.run {
            LogEndpointHandler.handle(request)
        }
    }

    // MARK: - Thread Handlers

    /// GET /threads — List threads with optional filters.
    private func handleListThreads(_ request: HTTPRequest) async -> HTTPResponse {
        let state = await getState()
        var threads = state.threads

        // Filter by state
        if let stateFilter = request.queryParams["state"],
           let threadState = ThreadState(rawValue: stateFilter) {
            threads = threads.filter { $0.state == threadState }
        }

        // Filter by temperature range
        if let minTempStr = request.queryParams["min_temperature"],
           let minTemp = Double(minTempStr) {
            threads = threads.filter { $0.temperature >= minTemp }
        }
        if let maxTempStr = request.queryParams["max_temperature"],
           let maxTemp = Double(maxTempStr) {
            threads = threads.filter { $0.temperature <= maxTemp }
        }

        let threadDicts: [[String: Any]] = threads.map { threadToDict($0) }

        return .json([
            "status": "ok",
            "count": threads.count,
            "threads": threadDicts
        ])
    }

    /// GET /threads/available — Unclaimed, non-terminal threads.
    private func handleAvailableThreads() async -> HTTPResponse {
        let state = await getState()
        let available = state.threads.filter {
            $0.claimedBy == nil && !$0.state.isTerminal && $0.state != .blocked
        }

        return .json([
            "status": "ok",
            "count": available.count,
            "threads": available.map { threadToDict($0) }
        ])
    }

    /// GET /threads/{id}
    private func handleGetThread(id: String) async -> HTTPResponse {
        let state = await getState()
        guard let thread = state.threads.first(where: { $0.id == id }) else {
            return .notFound("Thread not found: \(id)")
        }

        return .json([
            "status": "ok",
            "thread": threadToDict(thread)
        ])
    }

    /// POST /threads — Create a new thread.
    private func handleCreateThread(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSON(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard let title = json["title"] as? String else {
            return .badRequest("Missing 'title' parameter")
        }

        let description = json["description"] as? String ?? ""
        let temperature = json["temperature"] as? Double ?? 0.5

        let thread = ResearchThread(
            title: title,
            description: description,
            temperature: temperature
        )

        await MainActor.run {
            getClient()?.appendThread(thread)
        }

        return .json([
            "status": "ok",
            "message": "Thread created",
            "thread": threadToDict(thread)
        ])
    }

    /// PUT /threads/{id}/activate
    private func handleActivateThread(id: String) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.state = .active
            thread.updatedAt = Date()
        }
    }

    /// POST /threads/{id}/claim
    private func handleClaimThread(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSON(request),
              let agentId = json["agent_id"] as? String else {
            return .badRequest("Missing 'agent_id' parameter")
        }

        return await mutateThread(id: id) { thread in
            thread.claimedBy = agentId
            thread.state = .active
            thread.updatedAt = Date()
        }
    }

    /// POST /threads/{id}/release
    private func handleReleaseThread(id: String) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.claimedBy = nil
            thread.updatedAt = Date()
        }
    }

    /// PUT /threads/{id}/block
    private func handleBlockThread(id: String, request: HTTPRequest) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.state = .blocked
            thread.updatedAt = Date()
        }
    }

    /// PUT /threads/{id}/unblock
    private func handleUnblockThread(id: String) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.state = .active
            thread.updatedAt = Date()
        }
    }

    /// PUT /threads/{id}/review
    private func handleReviewThread(id: String) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.state = .review
            thread.updatedAt = Date()
        }
    }

    /// PUT /threads/{id}/complete
    private func handleCompleteThread(id: String) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.state = .complete
            thread.updatedAt = Date()
        }
    }

    /// PUT /threads/{id}/kill
    private func handleKillThread(id: String, request: HTTPRequest) async -> HTTPResponse {
        return await mutateThread(id: id) { thread in
            thread.state = .killed
            thread.updatedAt = Date()
        }
    }

    /// PUT /threads/{id}/temperature
    private func handleSetTemperature(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSON(request),
              let temperature = json["temperature"] as? Double else {
            return .badRequest("Missing 'temperature' parameter")
        }

        guard (0.0...1.0).contains(temperature) else {
            return .badRequest("Temperature must be between 0.0 and 1.0")
        }

        return await mutateThread(id: id) { thread in
            thread.temperature = temperature
            thread.updatedAt = Date()
        }
    }

    /// GET /threads/{id}/events
    private func handleThreadEvents(id: String) async -> HTTPResponse {
        let state = await getState()
        guard state.threads.contains(where: { $0.id == id }) else {
            return .notFound("Thread not found: \(id)")
        }

        // Events are not yet tracked per-thread; return empty list
        return .json([
            "status": "ok",
            "threadId": id,
            "events": [] as [Any]
        ])
    }

    // MARK: - Persona Handlers

    /// GET /personas
    private func handleListPersonas() async -> HTTPResponse {
        let state = await getState()
        let personas: [[String: Any]] = state.personas.map { personaToDict($0) }

        return .json([
            "status": "ok",
            "count": state.personas.count,
            "personas": personas
        ])
    }

    /// GET /personas/{id}
    private func handleGetPersona(id: String) async -> HTTPResponse {
        let state = await getState()
        guard let persona = state.persona(id: id) else {
            return .notFound("Persona not found: \(id)")
        }

        return .json([
            "status": "ok",
            "persona": personaDetailToDict(persona)
        ])
    }

    // MARK: - Agent Handlers

    /// GET /agents
    private func handleListAgents() async -> HTTPResponse {
        let state = await getState()
        let agents: [[String: Any]] = state.agents.map { agentToDict($0) }

        return .json([
            "status": "ok",
            "count": state.agents.count,
            "agents": agents
        ])
    }

    /// GET /agents/{id}
    private func handleGetAgent(id: String) async -> HTTPResponse {
        let state = await getState()
        guard let agent = state.agents.first(where: { $0.id == id }) else {
            return .notFound("Agent not found: \(id)")
        }

        return .json([
            "status": "ok",
            "agent": agentToDict(agent)
        ])
    }

    /// POST /agents — Register a new agent.
    private func handleRegisterAgent(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSON(request),
              let agentTypeStr = json["agent_type"] as? String,
              let agentType = AgentType(rawValue: agentTypeStr) else {
            return .badRequest("Missing or invalid 'agent_type' parameter")
        }

        let agent = Agent(
            id: "\(agentType.rawValue)-\(UUID().uuidString.prefix(8))",
            agentType: agentType
        )

        await MainActor.run {
            getClient()?.appendAgent(agent)
        }

        return .json([
            "status": "ok",
            "message": "Agent registered",
            "agent": agentToDict(agent)
        ])
    }

    /// DELETE /agents/{id}
    private func handleUnregisterAgent(id: String, request: HTTPRequest) async -> HTTPResponse {
        let removed = await MainActor.run { () -> Bool in
            getClient()?.mutateAgent(id: id) { $0.status = .terminated } ?? false
        }

        guard removed else {
            return .notFound("Agent not found: \(id)")
        }

        return .json([
            "status": "ok",
            "message": "Agent terminated"
        ])
    }

    /// GET /agents/{id}/next-thread
    private func handleNextThread(agentId: String, request: HTTPRequest) async -> HTTPResponse {
        let state = await getState()
        guard state.agents.contains(where: { $0.id == agentId }) else {
            return .notFound("Agent not found: \(agentId)")
        }

        let autoClaim = request.queryParams["auto_claim"] == "true"

        // Find highest-temperature available thread
        let available = state.threads
            .filter { $0.claimedBy == nil && !$0.state.isTerminal && $0.state != .blocked }
            .sorted { $0.temperature > $1.temperature }

        guard let next = available.first else {
            return .json([
                "status": "ok",
                "thread": NSNull()
            ])
        }

        if autoClaim {
            await MainActor.run {
                guard let client = getClient() else { return }
                client.mutateThread(id: next.id) {
                    $0.claimedBy = agentId
                    $0.state = .active
                    $0.updatedAt = Date()
                }
                client.mutateAgent(id: agentId) {
                    $0.currentThread = next.id
                    $0.status = .working
                    $0.lastActiveAt = Date()
                }
            }
        }

        return .json([
            "status": "ok",
            "thread": threadToDict(next),
            "auto_claimed": autoClaim
        ])
    }

    // MARK: - Escalation Handlers

    /// GET /escalations
    private func handleListEscalations(_ request: HTTPRequest) async -> HTTPResponse {
        let state = await getState()
        var escalations = state.escalations

        if request.queryParams["open_only"] == "true" {
            escalations = escalations.filter { $0.status != .resolved }
        }

        return .json([
            "status": "ok",
            "count": escalations.count,
            "escalations": escalations.map { escalationToDict($0) }
        ])
    }

    /// GET /escalations/{id}
    private func handleGetEscalation(id: String) async -> HTTPResponse {
        let state = await getState()
        guard let escalation = state.escalations.first(where: { $0.id == id }) else {
            return .notFound("Escalation not found: \(id)")
        }

        return .json([
            "status": "ok",
            "escalation": escalationToDict(escalation)
        ])
    }

    /// POST /escalations
    private func handleCreateEscalation(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSON(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard let categoryStr = json["category"] as? String,
              let category = EscalationCategory(rawValue: categoryStr) else {
            return .badRequest("Missing or invalid 'category' parameter")
        }

        guard let title = json["title"] as? String else {
            return .badRequest("Missing 'title' parameter")
        }

        let escalation = Escalation(
            category: category,
            priority: json["priority"] as? Int ?? 5,
            title: title,
            description: json["description"] as? String ?? "",
            threadId: json["thread_id"] as? String,
            createdBy: json["created_by"] as? String ?? "api",
            options: json["options"] as? [String]
        )

        await MainActor.run {
            getClient()?.appendEscalation(escalation)
        }

        return .json([
            "status": "ok",
            "message": "Escalation created",
            "escalation": escalationToDict(escalation)
        ])
    }

    /// PUT /escalations/{id}/acknowledge
    private func handleAcknowledgeEscalation(id: String, request: HTTPRequest) async -> HTTPResponse {
        let json = parseJSON(request)
        let by = json?["by"] as? String ?? "api"

        let found = await MainActor.run { () -> Bool in
            getClient()?.mutateEscalation(id: id) { $0.status = .acknowledged } ?? false
        }

        guard found else {
            return .notFound("Escalation not found: \(id)")
        }

        return .json([
            "status": "ok",
            "message": "Escalation acknowledged by \(by)"
        ])
    }

    /// PUT /escalations/{id}/resolve
    private func handleResolveEscalation(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSON(request) else {
            return .badRequest("Invalid JSON body")
        }

        let by = json["by"] as? String ?? "api"
        let resolution = json["resolution"] as? String ?? ""

        let found = await MainActor.run { () -> Bool in
            getClient()?.mutateEscalation(id: id) { $0.status = .resolved } ?? false
        }

        guard found else {
            return .notFound("Escalation not found: \(id)")
        }

        return .json([
            "status": "ok",
            "message": "Escalation resolved by \(by)",
            "resolution": resolution
        ])
    }

    /// GET /escalations/{id}/poll — Long-poll for resolution.
    private func handlePollEscalation(id: String, request: HTTPRequest) async -> HTTPResponse {
        let timeoutSec = Int(request.queryParams["timeout"] ?? "30") ?? 30
        let maxTimeout = min(timeoutSec, 120)

        let deadline = Date().addingTimeInterval(TimeInterval(maxTimeout))

        while Date() < deadline {
            let state = await getState()
            if let escalation = state.escalations.first(where: { $0.id == id }) {
                if escalation.status == .resolved {
                    return .json([
                        "status": "ok",
                        "resolved": true,
                        "escalation": escalationToDict(escalation)
                    ])
                }
            } else {
                return .notFound("Escalation not found: \(id)")
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        // Timeout — return current state
        let state = await getState()
        if let escalation = state.escalations.first(where: { $0.id == id }) {
            return .json([
                "status": "ok",
                "resolved": false,
                "escalation": escalationToDict(escalation)
            ])
        }

        return .notFound("Escalation not found: \(id)")
    }

    // MARK: - Events

    /// GET /events
    private func handleEvents(_ request: HTTPRequest) async -> HTTPResponse {
        // Event stream not yet implemented; return empty
        return .json([
            "status": "ok",
            "events": [] as [Any]
        ])
    }

    // MARK: - Helpers

    private func handleCORSPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    private func handleAPIInfo() -> HTTPResponse {
        .json([
            "name": "impel HTTP API",
            "version": "1.0.0",
            "endpoints": [
                "GET /status": "Server health and system overview",
                "GET /api/logs": "Query log entries",
                "GET /threads": "List threads (params: state, min_temperature, max_temperature)",
                "GET /threads/available": "List unclaimed non-terminal threads",
                "GET /threads/{id}": "Get thread detail",
                "POST /threads": "Create thread (body: {title, description?, temperature?})",
                "PUT /threads/{id}/activate": "Activate thread",
                "POST /threads/{id}/claim": "Claim thread (body: {agent_id})",
                "POST /threads/{id}/release": "Release thread",
                "PUT /threads/{id}/block": "Block thread",
                "PUT /threads/{id}/unblock": "Unblock thread",
                "PUT /threads/{id}/review": "Submit for review",
                "PUT /threads/{id}/complete": "Mark complete",
                "PUT /threads/{id}/kill": "Kill thread",
                "PUT /threads/{id}/temperature": "Set temperature (body: {temperature})",
                "GET /threads/{id}/events": "Thread event history",
                "GET /personas": "List personas",
                "GET /personas/{id}": "Persona detail",
                "GET /agents": "List agents",
                "GET /agents/{id}": "Agent detail",
                "POST /agents": "Register agent (body: {agent_type})",
                "DELETE /agents/{id}": "Unregister agent",
                "GET /agents/{id}/next-thread": "Next available thread (param: auto_claim)",
                "GET /escalations": "List escalations (param: open_only)",
                "GET /escalations/{id}": "Escalation detail",
                "POST /escalations": "Create escalation",
                "PUT /escalations/{id}/acknowledge": "Acknowledge (body: {by})",
                "PUT /escalations/{id}/resolve": "Resolve (body: {by, resolution})",
                "GET /escalations/{id}/poll": "Long-poll for resolution (param: timeout)",
                "GET /events": "Event stream"
            ],
            "port": ImpelHTTPServer.defaultPort,
            "localhost_only": true
        ])
    }

    // MARK: - State Access

    /// Get current system state from ImpelClient on the main actor.
    @MainActor
    private func getState() -> SystemState {
        getClient()?.state ?? SystemState()
    }

    /// Get the ImpelClient environment object.
    ///
    /// Since ImpelClient is created as @StateObject in ImpelApp and passed via
    /// environmentObject, we access it through the first window's root view controller.
    /// This uses NSApp on macOS.
    @MainActor
    private func getClient() -> ImpelClient? {
        // Walk the responder chain from the key window to find the hosting controller
        // that has the ImpelClient as an environment object.
        // Fallback: use a static reference set at app startup.
        return ImpelHTTPRouterState.shared.client
    }

    /// Mutate a thread by ID and return success/failure response.
    private func mutateThread(id: String, mutation: @escaping (inout ResearchThread) -> Void) async -> HTTPResponse {
        let found = await MainActor.run { () -> Bool in
            getClient()?.mutateThread(id: id, mutation) ?? false
        }

        guard found else {
            return .notFound("Thread not found: \(id)")
        }

        let state = await getState()
        if let thread = state.threads.first(where: { $0.id == id }) {
            return .json([
                "status": "ok",
                "thread": threadToDict(thread)
            ])
        }

        return .json(["status": "ok"])
    }

    private func parseJSON(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Serialization Helpers

    private func threadToDict(_ thread: ResearchThread) -> [String: Any] {
        var dict: [String: Any] = [
            "id": thread.id,
            "title": thread.title,
            "description": thread.description,
            "state": thread.state.rawValue,
            "temperature": thread.temperature,
            "temperatureLevel": thread.temperatureLevel.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: thread.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: thread.updatedAt),
            "artifactCount": thread.artifactCount
        ]
        if let claimedBy = thread.claimedBy {
            dict["claimedBy"] = claimedBy
        }
        return dict
    }

    private func personaToDict(_ persona: Persona) -> [String: Any] {
        [
            "id": persona.id,
            "name": persona.name,
            "archetype": persona.archetype.rawValue,
            "roleDescription": persona.roleDescription,
            "builtin": persona.builtin
        ]
    }

    private func personaDetailToDict(_ persona: Persona) -> [String: Any] {
        var dict = personaToDict(persona)
        dict["systemPrompt"] = persona.systemPrompt
        dict["behavior"] = [
            "verbosity": persona.behavior.verbosity,
            "riskTolerance": persona.behavior.riskTolerance,
            "citationDensity": persona.behavior.citationDensity,
            "escalationTendency": persona.behavior.escalationTendency,
            "workingStyle": persona.behavior.workingStyle.rawValue,
            "notes": persona.behavior.notes
        ]
        dict["model"] = [
            "provider": persona.model.provider,
            "model": persona.model.model,
            "temperature": persona.model.temperature,
            "maxTokens": persona.model.maxTokens as Any
        ]
        return dict
    }

    private func agentToDict(_ agent: Agent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": agent.id,
            "agentType": agent.agentType.rawValue,
            "status": agent.status.rawValue,
            "registeredAt": ISO8601DateFormatter().string(from: agent.registeredAt),
            "lastActiveAt": ISO8601DateFormatter().string(from: agent.lastActiveAt),
            "threadsCompleted": agent.threadsCompleted
        ]
        if let currentThread = agent.currentThread {
            dict["currentThread"] = currentThread
        }
        return dict
    }

    private func escalationToDict(_ escalation: Escalation) -> [String: Any] {
        var dict: [String: Any] = [
            "id": escalation.id,
            "category": escalation.category.rawValue,
            "priority": escalation.priority,
            "status": escalation.status.rawValue,
            "title": escalation.title,
            "description": escalation.description,
            "createdBy": escalation.createdBy,
            "createdAt": ISO8601DateFormatter().string(from: escalation.createdAt)
        ]
        if let threadId = escalation.threadId {
            dict["threadId"] = threadId
        }
        if let options = escalation.options {
            dict["options"] = options
        }
        return dict
    }
}

// MARK: - Router State (static reference to ImpelClient)

/// Holds a reference to ImpelClient so the HTTP router can access state.
/// Set from ImpelApp at startup.
@MainActor
final class ImpelHTTPRouterState {
    static let shared = ImpelHTTPRouterState()
    weak var client: ImpelClient?
    private init() {}
}
