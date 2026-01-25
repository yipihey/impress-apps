//
//  SourceManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Source Manager

/// Manages source plugins and coordinates searches across multiple sources.
public actor SourceManager {

    // MARK: - Properties

    private var plugins: [String: any SourcePlugin] = [:]
    private let credentialManager: CredentialManager

    // MARK: - Initialization

    public init(credentialManager: CredentialManager = .shared) {
        self.credentialManager = credentialManager
    }

    // MARK: - Plugin Registration

    /// Register a source plugin
    public func register(_ plugin: some SourcePlugin) {
        Logger.sources.info("Registering source: \(plugin.metadata.name)")
        plugins[plugin.metadata.id] = plugin
    }

    /// Unregister a source plugin
    public func unregister(id: String) {
        plugins.removeValue(forKey: id)
    }

    /// Get all registered sources
    public var availableSources: [SourceMetadata] {
        plugins.values.map { $0.metadata }.sorted { $0.name < $1.name }
    }

    /// Get a specific plugin
    public func plugin(for id: String) -> (any SourcePlugin)? {
        plugins[id]
    }

    // MARK: - Search

    /// Search across all available sources
    public func search(
        query: String,
        options: SearchOptions = .default
    ) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        let sourceIDs = options.sourceIDs ?? Array(plugins.keys)

        // Filter to sources that have valid credentials
        let availableSourceIDs = await filterAvailableSources(sourceIDs)

        guard !availableSourceIDs.isEmpty else {
            Logger.sources.warning("No available sources for search")
            return []
        }

        Logger.sources.info("Searching \(availableSourceIDs.count) sources for: \(query)")

        // Search in parallel
        return try await withThrowingTaskGroup(of: [SearchResult].self) { group in
            for sourceID in availableSourceIDs {
                guard let plugin = plugins[sourceID] else { continue }

                group.addTask {
                    do {
                        let results = try await plugin.search(query: query, maxResults: options.maxResults)
                        Logger.sources.debug("\(sourceID): found \(results.count) results")
                        return results
                    } catch {
                        Logger.sources.error("\(sourceID) search failed: \(error.localizedDescription)")
                        return []
                    }
                }
            }

            var allResults: [SearchResult] = []
            for try await results in group {
                allResults.append(contentsOf: results)
            }

            // Limit results
            if allResults.count > options.maxResults {
                allResults = Array(allResults.prefix(options.maxResults))
            }

            Logger.sources.info("Total results: \(allResults.count)")
            return allResults
        }
    }

    /// Search a specific source
    public func search(
        query: String,
        sourceID: String,
        maxResults: Int = 50
    ) async throws -> [SearchResult] {
        guard let plugin = plugins[sourceID] else {
            throw SourceError.unknownSource(sourceID)
        }

        // Check credentials
        let hasCredentials = await hasValidCredentials(for: sourceID)
        if !hasCredentials {
            throw SourceError.authenticationRequired(sourceID)
        }

        return try await plugin.search(query: query, maxResults: maxResults)
    }

    // MARK: - BibTeX Fetching

    /// Fetch BibTeX for a search result
    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        guard let plugin = plugins[result.sourceID] else {
            throw SourceError.unknownSource(result.sourceID)
        }

        let entry = try await plugin.fetchBibTeX(for: result)
        return plugin.normalize(entry)
    }

    // MARK: - Credential Management

    /// Check if a source has valid credentials
    public func hasValidCredentials(for sourceID: String) async -> Bool {
        guard let plugin = plugins[sourceID] else { return false }

        let requirement = plugin.metadata.credentialRequirement

        switch requirement {
        case .none:
            return true

        case .apiKeyOptional, .emailOptional:
            return true  // Optional credentials are always "valid"

        case .apiKey:
            return await credentialManager.hasCredential(for: sourceID, type: .apiKey)

        case .email:
            return await credentialManager.hasCredential(for: sourceID, type: .email)

        case .apiKeyAndEmail:
            let hasKey = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
            let hasEmail = await credentialManager.hasCredential(for: sourceID, type: .email)
            return hasKey && hasEmail
        }
    }

    /// Get credential status for all sources
    public func credentialStatus() async -> [SourceCredentialInfo] {
        var results: [SourceCredentialInfo] = []

        for (sourceID, plugin) in plugins {
            let metadata = plugin.metadata
            let status = await getCredentialStatus(for: sourceID, requirement: metadata.credentialRequirement)

            results.append(SourceCredentialInfo(
                sourceID: sourceID,
                sourceName: metadata.name,
                requirement: metadata.credentialRequirement,
                status: status,
                registrationURL: metadata.registrationURL
            ))
        }

        return results.sorted { $0.sourceName < $1.sourceName }
    }

    private func getCredentialStatus(
        for sourceID: String,
        requirement: CredentialRequirement
    ) async -> CredentialStatus {
        switch requirement {
        case .none:
            return .notRequired

        case .apiKeyOptional:
            let hasKey = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
            return hasKey ? .optionalValid : .optionalMissing

        case .emailOptional:
            let hasEmail = await credentialManager.hasCredential(for: sourceID, type: .email)
            return hasEmail ? .optionalValid : .optionalMissing

        case .apiKey:
            let hasKey = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
            return hasKey ? .valid : .missing

        case .email:
            let hasEmail = await credentialManager.hasCredential(for: sourceID, type: .email)
            return hasEmail ? .valid : .missing

        case .apiKeyAndEmail:
            let hasKey = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
            let hasEmail = await credentialManager.hasCredential(for: sourceID, type: .email)
            if hasKey && hasEmail {
                return .valid
            } else {
                return .missing
            }
        }
    }

    // MARK: - Private Helpers

    private func filterAvailableSources(_ sourceIDs: [String]) async -> [String] {
        var available: [String] = []

        for sourceID in sourceIDs {
            if await hasValidCredentials(for: sourceID) {
                available.append(sourceID)
            }
        }

        return available
    }

    // MARK: - Default Sources

    /// Register all built-in sources
    public func registerBuiltInSources() async {
        Logger.sources.info("Registering built-in sources")

        // arXiv - no credentials required
        register(ArXivSource())

        // ADS and SciX - require API key
        register(ADSSource(credentialManager: credentialManager))
        register(SciXSource(credentialManager: credentialManager))

        // Web of Science - require API key
        register(WoSSource(credentialManager: credentialManager))

        // Crossref - email optional for polite pool
        register(CrossrefSource(credentialManager: credentialManager))

        // PubMed - API key optional for higher rate limits
        register(PubMedSource(credentialManager: credentialManager))

        // OpenAlex - email optional for polite pool (100K req/day)
        register(OpenAlexSource(credentialManager: credentialManager))

        Logger.sources.info("Registered \(self.plugins.count) sources")
    }
}
