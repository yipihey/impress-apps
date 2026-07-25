//
//  SyncSettingsSections.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase E): the Settings building blocks, shared by the
//  macOS Sync tab and the iOS Sync pane.
//
//  Both platforms show the same facts in the same order — status, then
//  diagnostics, then actions — so the sections live here once and each host
//  only supplies its own `Form` chrome. Every one of these views is thin: they
//  render `SyncStatusModel.snapshot` and call `SyncActions`. No view computes
//  sync state.
//

import SwiftUI
import ImpressKit

// MARK: - Status

/// Master switch + the current verdict (and, when unavailable, why).
public struct SyncStatusSection: View {
    @Bindable var model: SyncStatusModel

    public init(model: SyncStatusModel) {
        self.model = model
    }

    public var body: some View {
        let snapshot = model.snapshot

        Toggle("Enable iCloud Sync", isOn: Binding(
            get: { snapshot.enabled },
            set: { newValue in Task { await model.setEnabled(newValue) } }
        ))
        .disabled(model.isBusy)

        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(snapshot))
                    .frame(width: 8, height: 8)
                Text(snapshot.headline)
                    .foregroundStyle(.secondary)
            }
        }

        // The explanation is the whole point when something is off — a bare
        // "Unavailable" would send the user hunting.
        if snapshot.enabled && !snapshot.available {
            Text(unavailableMessage(snapshot))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let error = snapshot.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Name the lease holder when another app owns it — "another app is
    /// syncing" is only useful if you can tell which one.
    private func unavailableMessage(_ snapshot: SyncStatusSnapshot) -> String {
        if snapshot.reasonCode == "lease_held_by_other", let holder = snapshot.leaseHolder {
            return "\(holder) is currently running sync for the impress suite. "
                + "Your changes are queued and will sync from this app when it takes over."
        }
        return snapshot.explanation
    }

    private func statusColor(_ snapshot: SyncStatusSnapshot) -> Color {
        guard snapshot.enabled else { return .secondary }
        if snapshot.available { return snapshot.lastError == nil ? .green : .orange }
        return .orange
    }
}

// MARK: - Diagnostics

/// Timestamps, queue depths, bootstrap state, and the first-sync merge report.
public struct SyncDiagnosticsSection: View {
    let snapshot: SyncStatusSnapshot

    public init(snapshot: SyncStatusSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        LabeledContent("Last Push", value: Self.relative(snapshot.lastPushAt))
        LabeledContent("Last Pull", value: Self.relative(snapshot.lastPullAt))

        LabeledContent("Pending Changes", value: "\(snapshot.outbox)")
        if snapshot.pendingRefs > 0 {
            LabeledContent("Deferred Links", value: "\(snapshot.pendingRefs)")
        }
        LabeledContent("Deletion Markers", value: "\(snapshot.tombstones)")

        if let account = snapshot.accountStatus {
            LabeledContent("iCloud Account", value: Self.humanize(account))
        }
        if let holder = snapshot.leaseHolder {
            LabeledContent("Sync Owner", value: holder)
        }
        LabeledContent("First Sync", value: snapshot.bootstrapDone ? "Complete" : "Not yet run")

        if let merge = snapshot.mergeReport, merge.duplicateGroups > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("First-sync merge")
                    .font(.callout)
                Text(Self.describe(merge))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func describe(_ report: FirstSyncMergeReport) -> String {
        var parts: [String] = []
        if report.groupsMerged > 0 {
            parts.append(
                "combined \(report.groupsMerged) duplicate paper(s) found on both devices, "
                + "removing \(report.publicationsRemoved) extra cop\(report.publicationsRemoved == 1 ? "y" : "ies")")
        }
        if report.groupsSkippedSingleOrigin > 0 {
            parts.append(
                "left \(report.groupsSkippedSingleOrigin) duplicate(s) from this device alone "
                + "for you to review")
        }
        return parts.isEmpty ? "No duplicates needed merging." : parts.joined(separator: "; ") + "."
    }

    static func humanize(_ code: String) -> String {
        switch code {
        case "available": return "Signed in"
        case "no_account": return "Not signed in"
        case "restricted": return "Restricted"
        case "temporarily_unavailable": return "Temporarily unavailable"
        case "could_not_determine": return "Unknown"
        default: return code
        }
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Actions

/// "Sync Now" plus the clearly-fenced destructive reset.
public struct SyncActionsSection: View {
    @Bindable var model: SyncStatusModel
    @State private var confirmingReset = false

    public init(model: SyncStatusModel) {
        self.model = model
    }

    public var body: some View {
        Button {
            Task { await model.syncNow() }
        } label: {
            HStack {
                Text("Sync Now")
                if model.isBusy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(model.isBusy || !model.snapshot.enabled)

        if let message = model.actionMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button("Reset Sync State…", role: .destructive) {
            confirmingReset = true
        }
        .disabled(model.isBusy)
        .confirmationDialog(
            "Reset sync state?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Sync State", role: .destructive) {
                Task { await model.resetSyncState() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.resetExplanation)
        }
    }

    /// Say plainly what is and is not destroyed — "reset" next to a sync
    /// feature reads like "delete my library" unless you spell it out.
    static let resetExplanation =
        """
        This clears only this device's sync bookkeeping — the change cursor and \
        first-sync marker — and runs a fresh full sync next time.

        Your papers, notes, tags, and manuscripts are not touched, on this \
        device or in iCloud.
        """
}

// MARK: - Scope footer

/// What does and does not sync (the plan's "Known 3.0 limitations", stated
/// where the user is deciding whether to trust it).
public struct SyncScopeFooter: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What syncs")
                .font(.caption.weight(.semibold))
            Text(Self.syncsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("What doesn't sync yet")
                .font(.caption.weight(.semibold))
                .padding(.top, 2)
            Text(Self.doesNotSyncText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let syncsText =
        """
        Papers and their metadata, tags, flags, read and starred state, \
        collections and libraries, notes, and manuscript text.
        """

    static let doesNotSyncText =
        """
        PDF attachments and very large manuscript bodies (over ~1 MB) stay on \
        the device that created them — the paper itself still syncs, but the \
        file won't be available elsewhere. Edit history and undo are per-device.
        """
}
