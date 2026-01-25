//
//  EnrichmentSettingsView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - Enrichment Settings View

/// A settings view for configuring publication enrichment behavior.
///
/// Allows users to:
/// - Set their preferred citation source
/// - Enable/disable automatic background sync
/// - Set the refresh interval for stale data
///
/// ## Usage
///
/// ```swift
/// EnrichmentSettingsView(viewModel: settingsViewModel)
///     .task {
///         await viewModel.loadEnrichmentSettings()
///     }
/// ```
public struct EnrichmentSettingsView: View {

    // MARK: - Properties

    @Bindable public var viewModel: SettingsViewModel

    // MARK: - State

    @State private var isWoSConfigured = false

    // MARK: - Computed Properties

    /// Available sources (excludes WoS if not configured)
    private var availableSources: [EnrichmentSource] {
        EnrichmentSource.allCases.filter { source in
            source != .wos || isWoSConfigured
        }
    }

    // MARK: - Initialization

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Body

    public var body: some View {
        Form {
            // Preferred Source Section
            Section {
                Picker("Preferred Source", selection: preferredSourceBinding) {
                    ForEach(availableSources) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Citation Display")
            } footer: {
                Text("The source used for displaying citation counts in your library.")
            }

            // Auto-Sync Section
            Section {
                Toggle("Enable Background Sync", isOn: autoSyncBinding)

                if viewModel.enrichmentSettings.autoSyncEnabled {
                    Picker("Refresh Interval", selection: refreshIntervalBinding) {
                        Text("Daily").tag(1)
                        Text("Every 3 Days").tag(3)
                        Text("Weekly").tag(7)
                        Text("Every 2 Weeks").tag(14)
                        Text("Monthly").tag(30)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Background Sync")
            } footer: {
                if viewModel.enrichmentSettings.autoSyncEnabled {
                    Text("Papers older than \(viewModel.enrichmentSettings.refreshIntervalDays) days will be automatically refreshed.")
                } else {
                    Text("Enrichment data will only be fetched when you manually refresh.")
                }
            }

            // Reset Section
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    Task {
                        await viewModel.resetEnrichmentSettingsToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Enrichment")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Check if WoS API key is configured
            isWoSConfigured = await CredentialManager.shared.apiKey(for: "wos") != nil
        }
    }

    // MARK: - Bindings

    private var preferredSourceBinding: Binding<EnrichmentSource> {
        Binding(
            get: { viewModel.enrichmentSettings.preferredSource },
            set: { newValue in
                Task {
                    await viewModel.updatePreferredSource(newValue)
                }
            }
        )
    }

    private var autoSyncBinding: Binding<Bool> {
        Binding(
            get: { viewModel.enrichmentSettings.autoSyncEnabled },
            set: { newValue in
                Task {
                    await viewModel.updateAutoSyncEnabled(newValue)
                }
            }
        )
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { viewModel.enrichmentSettings.refreshIntervalDays },
            set: { newValue in
                Task {
                    await viewModel.updateRefreshIntervalDays(newValue)
                }
            }
        )
    }
}

// MARK: - Compact Enrichment Settings

/// A compact version of enrichment settings for inline display
public struct CompactEnrichmentSettingsView: View {

    @Bindable public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Preferred source
            HStack {
                Text("Citation Source:")
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { viewModel.enrichmentSettings.preferredSource },
                    set: { newValue in Task { await viewModel.updatePreferredSource(newValue) } }
                )) {
                    ForEach(EnrichmentSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Auto-sync toggle
            Toggle("Auto-sync citations", isOn: Binding(
                get: { viewModel.enrichmentSettings.autoSyncEnabled },
                set: { newValue in Task { await viewModel.updateAutoSyncEnabled(newValue) } }
            ))
            .toggleStyle(.switch)
        }
        .padding()
    }
}

// MARK: - Preview

#Preview("Enrichment Settings") {
    NavigationStack {
        EnrichmentSettingsView(viewModel: SettingsViewModel())
    }
}

#Preview("Compact Settings") {
    CompactEnrichmentSettingsView(viewModel: SettingsViewModel())
        .frame(width: 300)
}
