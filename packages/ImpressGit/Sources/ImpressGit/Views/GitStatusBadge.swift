import SwiftUI

/// Compact toolbar badge showing git repository status.
///
/// Shows an icon reflecting the current state (clean, dirty, syncing, conflict,
/// offline) plus an ahead/behind pill when applicable.
public struct GitStatusBadge: View {
    let status: RepoStatus?
    let isSyncing: Bool
    let onTap: () -> Void

    public init(status: RepoStatus?, isSyncing: Bool = false, onTap: @escaping () -> Void = {}) {
        self.status = status
        self.isSyncing = isSyncing
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                statusIcon
                    .font(.system(size: 12))

                if let status, (status.ahead > 0 || status.behind > 0) {
                    aheadBehindPill(ahead: status.ahead, behind: status.behind)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isSyncing {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate)
        } else if let status {
            if status.hasConflicts {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if status.isClean {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func aheadBehindPill(ahead: UInt32, behind: UInt32) -> some View {
        HStack(spacing: 2) {
            if ahead > 0 {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9))
                Text("\(ahead)")
                    .font(.system(size: 10, design: .monospaced))
            }
            if behind > 0 {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9))
                Text("\(behind)")
                    .font(.system(size: 10, design: .monospaced))
            }
        }
        .foregroundStyle(.secondary)
    }

    private var helpText: String {
        guard let status else { return "Git: no connection to toolbox" }
        if isSyncing { return "Syncing..." }
        if status.hasConflicts { return "Git: merge conflicts detected" }
        if status.isClean {
            var text = "Git: \(status.branch) — clean"
            if status.ahead > 0 { text += ", \(status.ahead) ahead" }
            if status.behind > 0 { text += ", \(status.behind) behind" }
            return text
        }
        let changes = status.modified.count + status.staged.count + status.untracked.count
        return "Git: \(status.branch) — \(changes) change\(changes == 1 ? "" : "s")"
    }
}
