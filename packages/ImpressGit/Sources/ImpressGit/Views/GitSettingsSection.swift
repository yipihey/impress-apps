import SwiftUI

/// Reusable settings section for git configuration.
///
/// Each app drops this into their Settings view to show git status and
/// default sync preferences.
public struct GitSettingsSection: View {
    @State private var discovery: GitDiscovery?
    @State private var isLoading = true

    @AppStorage("gitAutoCommit") private var defaultAutoCommit = false
    @AppStorage("gitAutoPush") private var defaultAutoPush = false
    @AppStorage("gitSyncInterval") private var defaultSyncInterval = 0

    public init() {}

    public var body: some View {
        Form {
            Section("Git Status") {
                if isLoading {
                    ProgressView("Checking...")
                } else if let disc = discovery {
                    statusRow("git", available: disc.gitAvailable, version: disc.gitVersion)
                    statusRow("gh (GitHub CLI)", available: disc.ghAvailable, version: disc.ghVersion)

                    if let name = disc.userName, let email = disc.userEmail {
                        LabeledContent("User") {
                            Text("\(name) <\(email)>")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Could not connect to impress-toolbox", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Default Sync Settings") {
                Toggle("Auto-commit on save", isOn: $defaultAutoCommit)
                Toggle("Auto-push after commit", isOn: $defaultAutoPush)
                    .disabled(!defaultAutoCommit)
                Picker("Auto-fetch interval", selection: $defaultSyncInterval) {
                    Text("Manual only").tag(0)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadDiscovery() }
    }

    private func statusRow(_ name: String, available: Bool, version: String?) -> some View {
        LabeledContent(name) {
            HStack {
                if available {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadDiscovery() async {
        do {
            discovery = try await GitClient.shared.discoverGit()
        } catch {
            discovery = nil
        }
        isLoading = false
    }
}
