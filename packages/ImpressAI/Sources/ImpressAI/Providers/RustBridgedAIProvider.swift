import Foundation
import ImpressLogging

/// An `AIProvider` for one catalogue entry whose requests run in Rust.
///
/// The actor owns nothing but caches: discovery, health and the wire
/// protocol all live behind the `AIBridge`. It adds the two behaviours the
/// GUI is responsible for — retrying once after Rust asks the host to
/// launch oMLX.app, and keeping passive checks passive.
public actor RustBridgedAIProvider: AIModelDiscoveringProvider, AIServiceActivatingProvider {
    public nonisolated let descriptor: AIProviderDescriptor
    public nonisolated let metadata: AIProviderMetadata

    private let bridge: any AIBridge
    private let hostLauncher: any AIHostLaunching
    private let startupTimeout: TimeInterval
    private var modelCache: (models: [AIDiscoveredModel], at: Date)?
    private var healthCache: (health: AIProviderHealth, at: Date)?

    private static let modelCacheLifetime: TimeInterval = 30
    private static let healthCacheLifetime: TimeInterval = 10

    public init(
        descriptor: AIProviderDescriptor,
        bridge: any AIBridge,
        hostLauncher: any AIHostLaunching,
        startupTimeout: TimeInterval = 60
    ) {
        self.descriptor = descriptor
        self.metadata = descriptor.metadata
        self.bridge = bridge
        self.hostLauncher = hostLauncher
        self.startupTimeout = startupTimeout
    }

    // MARK: - AIProvider

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let bridgeRequest = targeted(AIBridgeMapping.bridgeRequest(request))
        do {
            return AIBridgeMapping.completionResponse(try await bridge.complete(bridgeRequest))
        } catch {
            guard try await recoverHostIfAsked(after: error) else { throw AIError.from(unwrapped(error)) }
            return AIBridgeMapping.completionResponse(try await bridge.complete(bridgeRequest))
        }
    }

    public func stream(_ request: AICompletionRequest) async throws -> AsyncThrowingStream<AIStreamChunk, Error> {
        let bridgeRequest = targeted(AIBridgeMapping.bridgeRequest(request))
        let events: AsyncThrowingStream<AIBridgeStreamEvent, Error>
        do {
            events = try await bridge.stream(bridgeRequest)
        } catch {
            guard try await recoverHostIfAsked(after: error) else { throw AIError.from(unwrapped(error)) }
            events = try await bridge.stream(bridgeRequest)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var accumulator = AIBridgeMapping.ToolCallAccumulator()
                do {
                    for try await event in events {
                        if let chunk = try AIBridgeMapping.streamChunk(for: event, accumulator: &accumulator) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.from(Self.unwrap(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Passive: a health probe only. Opening a settings pane must never
    /// launch another application.
    public func validate() async throws -> AIProviderStatus {
        let health = try await self.health()
        switch health.state {
        case .ready, .foreign:
            return .ready
        case .empty:
            return .unavailable(reason: health.detail.isEmpty ? "The server is reachable but reports no models" : health.detail)
        case .needsCredentials:
            return .needsCredentials(descriptor.credentialFields.filter { !$0.isOptional }.map(\.id))
        case .needsEndpoint:
            return .unavailable(reason: "No endpoint configured")
        case .unreachable, .foreignUnavailable:
            return .unavailable(reason: health.detail.isEmpty ? "Not reachable" : health.detail)
        }
    }

    // MARK: - Discovery

    public func discoverModels() async throws -> [AIModel] {
        try await discoverModels(forceRefresh: false, includeHelpers: false).map(\.model)
    }

    public func discoverModels(forceRefresh: Bool, includeHelpers: Bool) async throws -> [AIDiscoveredModel] {
        if !forceRefresh, let cached = modelCache, Date().timeIntervalSince(cached.at) < Self.modelCacheLifetime {
            return includeHelpers ? cached.models : cached.models.filter { !$0.isHelper }
        }
        let models: [AIDiscoveredModel]
        do {
            models = try await bridge.discoverModels(providerId: descriptor.id)
        } catch {
            throw AIError.from(unwrapped(error))
        }
        modelCache = (models, Date())
        return includeHelpers ? models : models.filter { !$0.isHelper }
    }

    public func health(forceRefresh: Bool = false) async throws -> AIProviderHealth {
        if !forceRefresh, let cached = healthCache, Date().timeIntervalSince(cached.at) < Self.healthCacheLifetime {
            return cached.health
        }
        let health: AIProviderHealth
        do {
            health = try await bridge.providerHealth(providerId: descriptor.id)
        } catch {
            throw AIError.from(unwrapped(error))
        }
        healthCache = (health, Date())
        return health
    }

    // MARK: - AIServiceActivatingProvider

    /// Explicit user action (Test Connection, a request): start the managed
    /// host if Rust says it may, launching the app when Rust asks for it.
    public func activateServiceIfNeeded() async throws {
        guard descriptor.canAutoStart else { return }
        do {
            _ = try await ensureHost(afterLaunch: false)
        } catch let error as AIBridgeError where error.kind == .hostLaunchRequired {
            try await launchHost(bundleId: error.bundleId)
            _ = try await ensureHost(afterLaunch: true)
        } catch {
            throw AIError.from(unwrapped(error))
        }
        healthCache = nil
        modelCache = nil
    }

    // MARK: - Private

    private func targeted(_ request: AIBridgeChatRequest) -> AIBridgeChatRequest {
        var request = request
        request.providerId = descriptor.id
        return request
    }

    private func ensureHost(afterLaunch: Bool) async throws -> AIProviderHealth {
        try await bridge.ensureOMLXRunning(timeout: startupTimeout)
    }

    private func launchHost(bundleId: String?) async throws {
        let bundleId = bundleId ?? "app.omlx"
        logInfo("Local AI host is not running; launching \(bundleId)", category: "ai.local-service")
        try await hostLauncher.launchApplication(bundleId: bundleId)
    }

    /// Only a `hostLaunchRequired` from Rust may launch anything; a plain
    /// unreachable error propagates so a custom runtime's port is never
    /// claimed by the suite.
    private func recoverHostIfAsked(after error: Error) async throws -> Bool {
        guard descriptor.canAutoStart,
              let bridgeError = error as? AIBridgeError,
              bridgeError.kind == .hostLaunchRequired
        else { return false }
        try await launchHost(bundleId: bridgeError.bundleId)
        do {
            _ = try await ensureHost(afterLaunch: true)
        } catch {
            throw AIError.from(unwrapped(error))
        }
        healthCache = nil
        modelCache = nil
        return true
    }

    private nonisolated func unwrapped(_ error: Error) -> Error {
        Self.unwrap(error)
    }

    private nonisolated static func unwrap(_ error: Error) -> Error {
        if let bridgeError = error as? AIBridgeError {
            return bridgeError.asAIError
        }
        return error
    }
}
