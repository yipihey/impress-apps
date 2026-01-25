//
//  SettingsViewModel.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog
import SwiftUI

// MARK: - Settings View Model

/// View model for application settings.
@MainActor
@Observable
public final class SettingsViewModel {

    // MARK: - Published State

    public private(set) var sourceCredentials: [SourceCredentialInfo] = []
    public private(set) var isLoading = false
    public private(set) var error: Error?

    // MARK: - Enrichment Settings State

    public private(set) var enrichmentSettings: EnrichmentSettings = .default
    public private(set) var isLoadingEnrichment = false

    // MARK: - Smart Search Settings State

    public private(set) var smartSearchSettings: SmartSearchSettings = .default
    public private(set) var isLoadingSmartSearch = false

    // MARK: - Inbox Settings State

    public private(set) var inboxSettings: InboxSettings = .default
    public private(set) var isLoadingInbox = false

    // MARK: - Dependencies

    private let sourceManager: SourceManager
    private let credentialManager: CredentialManager
    private let enrichmentSettingsStore: EnrichmentSettingsStore
    private let smartSearchSettingsStore: SmartSearchSettingsStore
    private let inboxSettingsStore: InboxSettingsStore

    // MARK: - Initialization

    public init(
        sourceManager: SourceManager = SourceManager(),
        credentialManager: CredentialManager = .shared,
        enrichmentSettingsStore: EnrichmentSettingsStore = .shared,
        smartSearchSettingsStore: SmartSearchSettingsStore = .shared,
        inboxSettingsStore: InboxSettingsStore = .shared
    ) {
        self.sourceManager = sourceManager
        self.credentialManager = credentialManager
        self.enrichmentSettingsStore = enrichmentSettingsStore
        self.smartSearchSettingsStore = smartSearchSettingsStore
        self.inboxSettingsStore = inboxSettingsStore
    }

    // MARK: - Loading

    public func loadCredentialStatus() async {
        Logger.viewModels.entering()
        defer { Logger.viewModels.exiting() }

        isLoading = true
        sourceCredentials = await sourceManager.credentialStatus()
        isLoading = false
    }

    // MARK: - Credential Management

    public func saveAPIKey(_ apiKey: String, for sourceID: String) async throws {
        Logger.viewModels.info("Saving API key for \(sourceID)")

        guard credentialManager.validate(apiKey, type: .apiKey) else {
            throw CredentialError.invalid("Invalid API key format")
        }

        try await credentialManager.storeAPIKey(apiKey, for: sourceID)
        await loadCredentialStatus()
    }

    public func saveEmail(_ email: String, for sourceID: String) async throws {
        Logger.viewModels.info("Saving email for \(sourceID)")

        guard credentialManager.validate(email, type: .email) else {
            throw CredentialError.invalid("Invalid email format")
        }

        try await credentialManager.storeEmail(email, for: sourceID)
        await loadCredentialStatus()
    }

    public func deleteCredentials(for sourceID: String) async {
        Logger.viewModels.info("Deleting credentials for \(sourceID)")

        await credentialManager.deleteAll(for: sourceID)
        await loadCredentialStatus()
    }

    public func getAPIKey(for sourceID: String) async -> String? {
        await credentialManager.apiKey(for: sourceID)
    }

    public func getEmail(for sourceID: String) async -> String? {
        await credentialManager.email(for: sourceID)
    }

    // MARK: - Enrichment Settings

    /// Load current enrichment settings
    public func loadEnrichmentSettings() async {
        isLoadingEnrichment = true
        enrichmentSettings = await enrichmentSettingsStore.settings
        isLoadingEnrichment = false
    }

    /// Update the preferred enrichment source
    public func updatePreferredSource(_ source: EnrichmentSource) async {
        await enrichmentSettingsStore.updatePreferredSource(source)
        enrichmentSettings = await enrichmentSettingsStore.settings
        Logger.enrichment.infoCapture(
            "Preferred citation source changed to \(source.displayName)",
            category: "enrichment"
        )
    }

    /// Update the source priority order
    public func updateSourcePriority(_ priority: [EnrichmentSource]) async {
        await enrichmentSettingsStore.updateSourcePriority(priority)
        enrichmentSettings = await enrichmentSettingsStore.settings
        Logger.enrichment.infoCapture(
            "Source priority updated: \(priority.map { $0.displayName }.joined(separator: " → "))",
            category: "enrichment"
        )
    }

    /// Move a source to a new position in the priority list
    public func moveSource(_ source: EnrichmentSource, to index: Int) async {
        await enrichmentSettingsStore.moveSource(source, to: index)
        enrichmentSettings = await enrichmentSettingsStore.settings
    }

    /// Update auto-sync enabled setting
    public func updateAutoSyncEnabled(_ enabled: Bool) async {
        await enrichmentSettingsStore.updateAutoSyncEnabled(enabled)
        enrichmentSettings = await enrichmentSettingsStore.settings
        Logger.enrichment.infoCapture(
            "Background sync \(enabled ? "enabled" : "disabled")",
            category: "enrichment"
        )
    }

    /// Update refresh interval in days
    public func updateRefreshIntervalDays(_ days: Int) async {
        await enrichmentSettingsStore.updateRefreshIntervalDays(days)
        enrichmentSettings = await enrichmentSettingsStore.settings
        Logger.enrichment.infoCapture(
            "Enrichment refresh interval set to \(days) days",
            category: "enrichment"
        )
    }

    /// Reset enrichment settings to defaults
    public func resetEnrichmentSettingsToDefaults() async {
        await enrichmentSettingsStore.resetToDefaults()
        enrichmentSettings = await enrichmentSettingsStore.settings
        Logger.enrichment.infoCapture(
            "Enrichment settings reset to defaults",
            category: "enrichment"
        )
    }

    // MARK: - Smart Search Settings

    /// Load current smart search settings
    public func loadSmartSearchSettings() async {
        isLoadingSmartSearch = true
        smartSearchSettings = await smartSearchSettingsStore.settings
        isLoadingSmartSearch = false
    }

    /// Update the default maximum results for smart searches
    public func updateDefaultMaxResults(_ maxResults: Int16) async {
        await smartSearchSettingsStore.updateDefaultMaxResults(maxResults)
        smartSearchSettings = await smartSearchSettingsStore.settings
        Logger.smartSearch.infoCapture(
            "Default smart search max results set to \(maxResults)",
            category: "smartsearch"
        )
    }

    /// Reset smart search settings to defaults
    public func resetSmartSearchSettingsToDefaults() async {
        await smartSearchSettingsStore.reset()
        smartSearchSettings = await smartSearchSettingsStore.settings
        Logger.smartSearch.infoCapture(
            "Smart search settings reset to defaults",
            category: "smartsearch"
        )
    }

    // MARK: - Inbox Settings

    /// Load current inbox settings
    public func loadInboxSettings() async {
        isLoadingInbox = true
        inboxSettings = await inboxSettingsStore.settings
        isLoadingInbox = false
    }

    /// Update the inbox age limit
    public func updateInboxAgeLimit(_ ageLimit: AgeLimitPreset) async {
        await inboxSettingsStore.updateAgeLimit(ageLimit)
        inboxSettings = await inboxSettingsStore.settings
        Logger.inbox.infoCapture(
            "Inbox age limit set to \(ageLimit.displayName)",
            category: "settings"
        )
    }

    /// Reset inbox settings to defaults
    public func resetInboxSettingsToDefaults() async {
        await inboxSettingsStore.reset()
        inboxSettings = await inboxSettingsStore.settings
        Logger.inbox.infoCapture(
            "Inbox settings reset to defaults",
            category: "settings"
        )
    }
}
