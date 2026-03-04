//
//  EmbeddingProviderRegistry.swift
//  ImpressEmbeddings
//
//  Central registry for embedding providers. Manages active provider selection,
//  availability detection, and provider switching (which triggers re-indexing).
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.impress.embeddings", category: "ProviderRegistry")

// MARK: - Provider Availability

/// Information about a registered provider's availability.
public struct ProviderInfo: Sendable {
    public let id: String
    public let dimension: Int
    public let supportsLocal: Bool
    public let available: Bool
    public let unavailableReason: String?

    public init(id: String, dimension: Int, supportsLocal: Bool, available: Bool, unavailableReason: String? = nil) {
        self.id = id
        self.dimension = dimension
        self.supportsLocal = supportsLocal
        self.available = available
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Provider Registry

/// Manages embedding provider registration, selection, and switching.
///
/// Usage:
/// ```swift
/// let registry = EmbeddingProviderRegistry.shared
/// await registry.register(MyProvider())
/// let embedding = try await registry.activeProvider.embed("hello world")
/// ```
public actor EmbeddingProviderRegistry {

    public static let shared = EmbeddingProviderRegistry()

    // MARK: - Storage

    private var providers: [String: any EmbeddingProvider] = [:]
    private var activeProviderId: String?

    /// Callbacks fired when the active provider changes (e.g., to trigger re-indexing).
    private var changeHandlers: [(String, Int) -> Void] = []

    // MARK: - Registration

    /// Register a provider. The first registered provider becomes active by default.
    public func register(_ provider: any EmbeddingProvider) {
        providers[provider.id] = provider
        if activeProviderId == nil {
            activeProviderId = provider.id
            logger.info("Default provider set to \(provider.id) (dimension: \(provider.embeddingDimension))")
        }
        logger.info("Registered provider: \(provider.id) (dimension: \(provider.embeddingDimension), local: \(provider.supportsLocal))")
    }

    // MARK: - Active Provider

    /// The currently active embedding provider.
    ///
    /// Falls back to the first registered provider if the configured one isn't available.
    public var activeProvider: (any EmbeddingProvider)? {
        if let id = activeProviderId, let provider = providers[id] {
            return provider
        }
        return providers.values.first
    }

    /// The ID of the currently active provider.
    public var activeProviderID: String? {
        activeProviderId
    }

    /// The dimension of the active provider's embeddings.
    public var activeDimension: Int {
        activeProvider?.embeddingDimension ?? 384
    }

    /// Switch to a different provider.
    ///
    /// If the new provider has a different dimension, this notifies change handlers
    /// so the calling code can trigger re-indexing.
    public func setActiveProvider(_ id: String) throws {
        guard providers[id] != nil else {
            throw EmbeddingError.providerNotAvailable("Provider '\(id)' is not registered")
        }

        let oldDimension = activeProvider?.embeddingDimension ?? 0
        let newDimension = providers[id]!.embeddingDimension

        activeProviderId = id
        logger.info("Switched to provider: \(id) (dimension: \(newDimension))")

        if oldDimension != newDimension {
            logger.warning("Dimension changed from \(oldDimension) to \(newDimension) — re-indexing required")
        }

        // Notify change handlers
        for handler in changeHandlers {
            handler(id, newDimension)
        }
    }

    // MARK: - Query

    /// List all registered providers with availability information.
    public func availableProviders() -> [ProviderInfo] {
        providers.values.map { provider in
            ProviderInfo(
                id: provider.id,
                dimension: provider.embeddingDimension,
                supportsLocal: provider.supportsLocal,
                available: true
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Get a specific provider by ID.
    public func provider(for id: String) -> (any EmbeddingProvider)? {
        providers[id]
    }

    // MARK: - Change Notification

    /// Register a handler that fires when the active provider changes.
    /// The handler receives (newProviderId, newDimension).
    public func onProviderChange(_ handler: @escaping @Sendable (String, Int) -> Void) {
        changeHandlers.append(handler)
    }
}
