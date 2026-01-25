//
//  SmartSearchProviderCache.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
import CoreData

// MARK: - Smart Search Provider Cache

/// Caches SmartSearchProvider instances to avoid re-fetching when switching between views.
///
/// This cache is actor-isolated for thread safety and stores providers keyed by
/// the smart search UUID. When a smart search is edited, call `invalidate` to
/// clear the cached provider.
public actor SmartSearchProviderCache {
    public static let shared = SmartSearchProviderCache()

    private var providers: [UUID: SmartSearchProvider] = [:]

    public init() {}

    /// Get an existing provider or create a new one for the smart search.
    public func getOrCreate(
        for smartSearch: CDSmartSearch,
        sourceManager: SourceManager,
        repository: PublicationRepository
    ) -> SmartSearchProvider {
        if let existing = providers[smartSearch.id] {
            return existing
        }
        let provider = SmartSearchProvider(
            from: smartSearch,
            sourceManager: sourceManager,
            repository: repository
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
    /// This variant fetches the CDSmartSearch internally on the main actor, making it safe
    /// to call from non-main-actor contexts. Returns nil if the smart search doesn't exist.
    ///
    /// - Parameters:
    ///   - smartSearchID: UUID of the smart search
    ///   - sourceManager: Source manager for searches
    ///   - repository: Publication repository for persistence
    /// - Returns: Provider or nil if smart search not found
    public func getOrCreateByID(
        smartSearchID: UUID,
        sourceManager: SourceManager,
        repository: PublicationRepository
    ) async -> SmartSearchProvider? {
        // Check cache first
        if let existing = providers[smartSearchID] {
            return existing
        }

        // Fetch smart search on main actor and create provider
        let smartSearch: CDSmartSearch? = await MainActor.run {
            let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            request.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
            request.fetchLimit = 1
            return try? PersistenceController.shared.viewContext.fetch(request).first
        }

        guard let smartSearch else { return nil }

        // Create provider on main actor (since CDSmartSearch is accessed)
        let provider = await MainActor.run {
            SmartSearchProvider(
                from: smartSearch,
                sourceManager: sourceManager,
                repository: repository
            )
        }

        providers[smartSearchID] = provider
        return provider
    }
}
