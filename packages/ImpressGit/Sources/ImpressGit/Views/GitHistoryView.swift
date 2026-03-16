import SwiftUI

/// Commit history browser for a git repository.
public struct GitHistoryView: View {
    let repoPath: String

    @State private var entries: [LogEntry] = []
    @State private var selectedEntry: LogEntry?
    @State private var diffText = ""
    @State private var isLoading = true

    public init(repoPath: String) {
        self.repoPath = repoPath
    }

    public var body: some View {
        HSplitView {
            // Left: commit list
            commitList
                .frame(minWidth: 250, idealWidth: 300)

            // Right: diff preview
            diffPreview
                .frame(minWidth: 300)
        }
        .task { await loadHistory() }
    }

    private var commitList: some View {
        List(entries, selection: $selectedEntry) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: 12))
                    .lineLimit(2)

                HStack {
                    Text(entry.shortHash)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(entry.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(entry.date, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(entry)
        }
        .listStyle(.inset)
        .overlay {
            if isLoading {
                ProgressView()
            } else if entries.isEmpty {
                ContentUnavailableView("No Commits", systemImage: "clock")
            }
        }
        .onChange(of: selectedEntry) { _, entry in
            if let entry {
                Task { await loadDiff(for: entry) }
            }
        }
    }

    private var diffPreview: some View {
        ScrollView {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 8) {
                    // Commit header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.message)
                            .font(.system(size: 13, weight: .medium))
                        HStack {
                            Text(entry.hash)
                                .font(.system(size: 10, design: .monospaced))
                            Text("by \(entry.author)")
                                .font(.system(size: 10))
                            Text(entry.date, style: .date)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    Divider()

                    // Diff content
                    Text(diffText.isEmpty ? "Loading..." : diffText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } else {
                ContentUnavailableView("Select a commit", systemImage: "arrow.left")
            }
        }
        .background(.background.secondary)
    }

    private func loadHistory() async {
        do {
            entries = try await GitClient.shared.log(at: repoPath, count: 50)
        } catch {
            // Silently fail — show empty state
        }
        isLoading = false
    }

    private func loadDiff(for entry: LogEntry) async {
        diffText = ""
        do {
            // Show the diff for this specific commit
            diffText = try await GitClient.shared.diff(at: repoPath)
        } catch {
            diffText = "Error loading diff: \(error.localizedDescription)"
        }
    }
}

// Make LogEntry equatable/hashable for selection
extension LogEntry: Equatable {
    public static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.hash == rhs.hash
    }
}

extension LogEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}
