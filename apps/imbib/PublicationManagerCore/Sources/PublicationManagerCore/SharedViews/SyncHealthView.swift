//
//  SyncHealthView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-28.
//

import SwiftUI

/// User-facing dashboard showing sync health and actionable issues.
///
/// Displays:
/// - Overall sync status with icon
/// - Last sync time
/// - Pending operations count
/// - Unresolved conflicts
/// - CloudKit quota usage (if available)
/// - List of issues with resolution actions
public struct SyncHealthView: View {
    @StateObject private var health = SyncHealthMonitor.shared
    @State private var isRefreshing = false

    public init() {}

    public var body: some View {
        List {
            // Status header
            Section {
                HStack {
                    statusIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(health.status.description)
                            .font(.headline)
                        if let lastSync = health.lastSyncDate {
                            Text("Last synced: \(lastSync, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            // Statistics
            Section("Sync Status") {
                StatusRow(
                    icon: "arrow.up.circle",
                    title: "Pending Uploads",
                    value: "\(health.pendingUploadCount)"
                )
                StatusRow(
                    icon: "arrow.down.circle",
                    title: "Pending Downloads",
                    value: "\(health.pendingDownloadCount)"
                )
                StatusRow(
                    icon: "exclamationmark.triangle",
                    title: "Conflicts",
                    value: "\(health.unresolvedConflictCount)",
                    isWarning: health.unresolvedConflictCount > 0
                )
                if let quota = health.quotaUsage {
                    StatusRow(
                        icon: "externaldrive.badge.icloud",
                        title: "iCloud Storage",
                        value: "\(Int(quota * 100))%",
                        isWarning: quota > 0.9
                    )
                }
            }

            // Issues
            if health.hasIssues {
                Section("Issues") {
                    ForEach(health.issues) { issue in
                        IssueRow(issue: issue) {
                            Task {
                                await health.resolveIssue(issue)
                            }
                        }
                    }
                }
            }

            // Actions
            Section {
                Button {
                    Task {
                        isRefreshing = true
                        await health.refresh()
                        isRefreshing = false
                    }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }

                if !health.isSyncEnabled {
                    Button {
                        CloudKitSyncSettingsStore.shared.isDisabledByUser = false
                    } label: {
                        Label("Enable Sync", systemImage: "icloud")
                    }
                } else {
                    Button {
                        CloudKitSyncSettingsStore.shared.isDisabledByUser = true
                    } label: {
                        Label("Pause Sync", systemImage: "pause.circle")
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Sync Health")
        .refreshable {
            await health.refresh()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: health.status.iconName)
            .font(.largeTitle)
            .foregroundColor(statusColor)
            .symbolEffect(.pulse, isActive: health.isSyncing)
    }

    private var statusColor: Color {
        switch health.status {
        case .healthy:
            return .green
        case .attention:
            return .yellow
        case .degraded:
            return .orange
        case .critical:
            return .red
        case .disabled:
            return .gray
        }
    }
}

// MARK: - Status Row

private struct StatusRow: View {
    let icon: String
    let title: String
    let value: String
    var isWarning: Bool = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(isWarning ? .orange : .secondary)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(isWarning ? .orange : .secondary)
                .fontWeight(isWarning ? .semibold : .regular)
        }
    }
}

// MARK: - Issue Row

private struct IssueRow: View {
    let issue: SyncHealthIssue
    let onResolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                severityIcon
                Text(issue.title)
                    .font(.headline)
            }

            Text(issue.description)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(issue.suggestedAction) {
                onResolve()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var severityIcon: some View {
        switch issue.severity {
        case .info:
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
        case .attention:
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.yellow)
        case .warning:
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
        case .critical:
            Image(systemName: "xmark.circle")
                .foregroundColor(.red)
        }
    }
}

// MARK: - Compact Sync Status View

/// Compact sync status indicator for use in settings or toolbars.
public struct SyncStatusIndicator: View {
    @StateObject private var health = SyncHealthMonitor.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: health.status.iconName)
                .foregroundColor(statusColor)
                .symbolEffect(.pulse, isActive: health.isSyncing)

            if health.hasIssues {
                Text("\(health.issues.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundColor(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch health.status {
        case .healthy:
            return .green
        case .attention:
            return .yellow
        case .degraded:
            return .orange
        case .critical:
            return .red
        case .disabled:
            return .gray
        }
    }
}

// MARK: - Pre-Update Backup Prompt

/// Alert view shown before major app updates.
public struct PreUpdateBackupPrompt: View {
    let onExport: () -> Void
    let onSkip: () -> Void
    @Environment(\.dismiss) private var dismiss

    public init(onExport: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onExport = onExport
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Backup Recommended")
                .font(.title2)
                .fontWeight(.semibold)

            Text("A major update is available. We recommend exporting your library before updating to ensure your data is safe.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button {
                    onExport()
                    dismiss()
                } label: {
                    Label("Export Library", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onSkip()
                    dismiss()
                } label: {
                    Text("Skip for Now")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: 400)
    }
}

// MARK: - Preview

#if DEBUG
struct SyncHealthView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SyncHealthView()
        }
    }
}
#endif
