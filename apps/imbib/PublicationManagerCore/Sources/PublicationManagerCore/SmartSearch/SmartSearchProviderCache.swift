//
//  SmartSearchProviderCache.swift
//  PublicationManagerCore
//
//  Caches SmartSearchProvider instances to avoid re-fetching when switching views.
//

import Foundation

// MARK: - Smart Search Provider Cache

/// Caches SmartSearchProvider instances to avoid re-fetching when switching between views.
///
/// This cache is actor-isolated for thread safety and stores providers keyed by
/// the smart search UUID.
public actor SmartSearchProviderCache {
    public static let shared = SmartSearchProviderCache()

    private var providers: [UUID: SmartSearchProvider] = [:]

    public init() {}

    /// Get an existing provider or create a new one for the smart search.
    public func getOrCreate(
        for smartSearch: SmartSearch,
        sourceManager: SourceManager
    ) -> SmartSearchProvider {
        if let existing = providers[smartSearch.id] {
            return existing
        }
        let provider = SmartSearchProvider(
            from: smartSearch,
            sourceManager: sourceManager
        )
        providers[smartSearch.id] = provider
        return provider
    }

    /// Invalidate cached provider (call when smart search is edited)
    public func invalidate(_ id: UUID) {
        providers.removeValue(forKey: id)
    }

    /// Invalidate all cached providers
    public func invalidateAll() {
        providers.removeAll()
    }

    /// Get or create a provider by smart search ID.
    ///
    /// This variant fetches the SmartSearch from the store internally,
    /// making it safe to call from non-main-actor contexts.
    public func getOrCreateByID(
        smartSearchID: UUID,
        sourceManager: SourceManager
    ) async -> SmartSearchProvider? {
        // Check cache first
        if let existing = providers[smartSearchID] {
            return existing
        }

        // Fetch smart search from store
        let smartSearch: SmartSearch? = await MainActor.run {
            RustStoreAdapter.shared.getSmartSearch(id: smartSearchID)
        }

        guard let smartSearch else { return nil }

        let provider = SmartSearchProvider(
            from: smartSearch,
            sourceManager: sourceManager
        )

        providers[smartSearchID] = provider
        return provider
    }
}
