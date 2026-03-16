import SwiftUI

/// Panel for reviewing and resolving git merge conflicts.
public struct GitConflictPanel: View {
    let repoPath: String
    let conflictFiles: [String]
    let onResolved: () -> Void
    let onDismiss: () -> Void

    @State private var selectedFile: String?
    @State private var resolutions: [String: ConflictResolution] = [:]
    @State private var isResolving = false

    public enum ConflictResolution: String, Sendable {
        case ours
        case theirs
        case manual
    }

    public init(
        repoPath: String,
        conflictFiles: [String],
        onResolved: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.repoPath = repoPath
        self.conflictFiles = conflictFiles
        self.onResolved = onResolved
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("\(conflictFiles.count) Merge Conflict\(conflictFiles.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button("Cancel Merge") { onDismiss() }
            }
            .padding()

            Divider()

            // File list with resolution actions
            List(conflictFiles, id: \.self, selection: $selectedFile) { file in
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.red)

                    Text(file)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if let resolution = resolutions[file] {
                        resolvedBadge(resolution)
                    } else {
                        resolutionButtons(for: file)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Footer
            HStack {
                Text("Resolve each file, then apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Apply Resolutions") {
                    Task { await applyResolutions() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(resolutions.count < conflictFiles.count || isResolving)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private func resolutionButtons(for file: String) -> some View {
        HStack(spacing: 4) {
            Button("Mine") { resolutions[file] = .ours }
                .controlSize(.small)
            Button("Theirs") { resolutions[file] = .theirs }
                .controlSize(.small)
        }
    }

    private func resolvedBadge(_ resolution: ConflictResolution) -> some View {
        Text(resolution.rawValue.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.green.opacity(0.2))
            .foregroundStyle(.green)
            .clipShape(Capsule())
    }

    private func applyResolutions() async {
        isResolving = true
        let client = GitClient.shared

        do {
            // For each resolved file, checkout the appropriate version
            for (file, resolution) in resolutions {
                switch resolution {
                case .ours:
                    try await client.checkout(at: repoPath, branch: "--ours -- \(file)")
                case .theirs:
                    try await client.checkout(at: repoPath, branch: "--theirs -- \(file)")
                case .manual:
                    break // User resolved manually
                }
            }

            // Stage all resolved files
            try await client.add(at: repoPath, files: conflictFiles)
            onResolved()
        } catch {
            // Error handling is minimal — the UI is a first pass
        }

        isResolving = false
    }
}
