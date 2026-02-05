//
//  CloudKitSyncSettingsView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import SwiftUI
#if canImport(CloudKit)
import CloudKit
#endif

/// Settings view for configuring iCloud sync.
///
/// Shows:
/// - Toggle to enable/disable sync (auto-enabled when iCloud available)
/// - Current iCloud account status
/// - Current sync status (Synced/Syncing/Local only)
/// - Error messages if any
/// - Note that restart required after changing
public struct CloudKitSyncSettingsView: View {

    // MARK: - State

    @State private var isDisabledByUser: Bool = false
    @State private var accountStatus: CKAccountStatus?
    @State private var isCheckingStatus: Bool = true
    @State private var lastSyncDate: Date?
    @State private var lastError: String?
    @State private var isCloudKitEnabled: Bool = false
    @State private var explorationIsLocalOnly: Bool = true

    // MARK: - Body

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Enable iCloud Sync", isOn: Binding(
                    get: { !isDisabledByUser },
                    set: { enabled in
                        isDisabledByUser = !enabled
                        CloudKitSyncSettingsStore.shared.isDisabledByUser = !enabled
                    }
                ))
                .disabled(accountStatus != .available)

                if accountStatus != .available && !isDisabledByUser {
                    Text("iCloud sync will be enabled automatically when you sign in to iCloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud Sync")
            } footer: {
                if isCloudKitEnabled != !isDisabledByUser {
                    Label("Restart required to apply changes", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("iCloud Account Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    if isCheckingStatus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(accountStatusColor)
                                .frame(width: 8, height: 8)
                            Text(accountStatusText)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Sync Status") {
                HStack {
                    Text("Current Mode")
                    Spacer()
                    Text(syncModeText)
                        .foregroundStyle(.secondary)
                }

                if let date = lastSyncDate {
                    HStack {
                        Text("Last Synced")
                        Spacer()
                        Text(date, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = lastError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Keep exploration results on this device only", isOn: $explorationIsLocalOnly)
                    .onChange(of: explorationIsLocalOnly) { _, newValue in
                        ExplorationSettingsStore.shared.isLocalOnly = newValue
                    }
            } header: {
                Text("Exploration Sync")
            } footer: {
                Text(explorationIsLocalOnly
                    ? "Exploration results stay on this device and are not synced to iCloud."
                    : "Exploration results sync across all your devices via iCloud.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How iCloud Sync Works")
                        .font(.headline)

                    Text("When enabled, your libraries, papers, collections, and settings sync across all your devices signed into the same iCloud account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("PDF files are stored locally and not synced to iCloud to conserve storage space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadSettings()
            await checkAccountStatus()
        }
    }

    // MARK: - Account Status

    private var accountStatusColor: Color {
        switch accountStatus {
        case .available:
            return .green
        case .noAccount:
            return .red
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            return .orange
        case .none:
            return .gray
        @unknown default:
            return .gray
        }
    }

    private var accountStatusText: String {
        switch accountStatus {
        case .available:
            return "Signed In"
        case .noAccount:
            return "Not Signed In"
        case .restricted:
            return "Restricted"
        case .couldNotDetermine:
            return "Unknown"
        case .temporarilyUnavailable:
            return "Temporarily Unavailable"
        case .none:
            return "Checking..."
        @unknown default:
            return "Unknown"
        }
    }

    // MARK: - Sync Mode

    private var syncModeText: String {
        if isDisabledByUser {
            return "Local Only (disabled)"
        }

        if !isCloudKitEnabled {
            return "Local Only"
        }

        switch accountStatus {
        case .available:
            return "iCloud Sync Active"
        case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
            return "Local Only (iCloud unavailable)"
        case .none:
            return "Checking..."
        @unknown default:
            return "Local Only"
        }
    }

    // MARK: - Actions

    private func loadSettings() async {
        isDisabledByUser = CloudKitSyncSettingsStore.shared.isDisabledByUser
        lastSyncDate = CloudKitSyncSettingsStore.shared.lastSyncDate
        lastError = CloudKitSyncSettingsStore.shared.lastError
        isCloudKitEnabled = PersistenceController.shared.isCloudKitEnabled
        explorationIsLocalOnly = ExplorationSettingsStore.shared.isLocalOnly
    }

    private func checkAccountStatus() async {
        isCheckingStatus = true

        #if canImport(CloudKit)
        do {
            let container = CKContainer(identifier: "iCloud.com.imbib.app")
            let status = try await container.accountStatus()
            await MainActor.run {
                accountStatus = status
                isCheckingStatus = false
            }
        } catch {
            await MainActor.run {
                accountStatus = .couldNotDetermine
                isCheckingStatus = false
            }
        }
        #else
        accountStatus = .couldNotDetermine
        isCheckingStatus = false
        #endif
    }
}

#Preview {
    CloudKitSyncSettingsView()
}
