import SwiftUI

/// Sheet for composing a git commit with diff preview and file selection.
public struct GitCommitSheet: View {
    let repoPath: String
    let onCommit: (String, [String], Bool) -> Void // (message, files, push)
    let onDismiss: () -> Void

    @State private var message = ""
    @State private var status: RepoStatus?
    @State private var diffText = ""
    @State private var selectedFiles: Set<String> = []
    @State private var pushAfterCommit = false
    @State private var isLoading = true
    @State private var isCommitting = false
    @State private var toolboxAvailable: Bool?

    public init(
        repoPath: String,
        onCommit: @escaping (String, [String], Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.repoPath = repoPath
        self.onCommit = onCommit
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Commit Changes")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            if toolboxAvailable == false {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("impress-toolbox is not running. Start it with: `impress-toolbox`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
            }

            Divider()

            if isLoading {
                ProgressView("Loading changes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Left: file list
                    fileList
                        .frame(minWidth: 200, idealWidth: 250)

                    // Right: diff preview
                    diffPreview
                        .frame(minWidth: 300)
                }
            }

            Divider()

            // Commit message + actions
            VStack(spacing: 8) {
                TextField("Commit message", text: $message, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Toggle("Push after commit", isOn: $pushAfterCommit)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Text("\(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s") selected")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Button("Commit") {
                        isCommitting = true
                        onCommit(message, Array(selectedFiles), pushAfterCommit)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.isEmpty || selectedFiles.isEmpty || isCommitting || toolboxAvailable == false)
                }
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            do {
                _ = try await GitClient.shared.discoverGit()
                toolboxAvailable = true
            } catch {
                toolboxAvailable = false
            }
            await loadChanges()
        }
    }

    private var fileList: some View {
        List {
            if let status {
                if !status.staged.isEmpty {
                    Section("Staged") {
                        ForEach(status.staged, id: \.path) { file in
                            fileRow(file.path, state: file.status, isStaged: true)
                        }
                    }
                }
                if !status.modified.isEmpty {
                    Section("Modified") {
                        ForEach(status.modified, id: \.path) { file in
                            fileRow(file.path, state: file.status, isStaged: false)
                        }
                    }
                }
                if !status.untracked.isEmpty {
                    Section("Untracked") {
                        ForEach(status.untracked, id: \.self) { path in
                            fileRow(path, state: .added, isStaged: false)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func fileRow(_ path: String, state: FileState, isStaged: Bool) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { selectedFiles.contains(path) },
                set: { if $0 { selectedFiles.insert(path) } else { selectedFiles.remove(path) } }
            )) {
                HStack(spacing: 4) {
                    Text(stateLabel(state))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(stateColor(state))
                        .frame(width: 16)
                    Text(path)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var diffPreview: some View {
        ScrollView {
            Text(diffText.isEmpty ? "No diff available" : diffText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.background.secondary)
    }

    private func loadChanges() async {
        do {
            let client = GitClient.shared
            async let statusResult = client.status(at: repoPath)
            async let diffResult = client.diff(at: repoPath)
            let (s, d) = try await (statusResult, diffResult)
            status = s
            diffText = d

            // Pre-select all changed files
            for file in s.staged { selectedFiles.insert(file.path) }
            for file in s.modified { selectedFiles.insert(file.path) }
            for path in s.untracked { selectedFiles.insert(path) }

            // Auto-suggest commit message
            if message.isEmpty {
                let count = selectedFiles.count
                message = "Update \(count) file\(count == 1 ? "" : "s") from impress"
            }
        } catch {
            diffText = "Error loading changes: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func stateLabel(_ state: FileState) -> String {
        switch state {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .unmerged: "U"
        }
    }

    private func stateColor(_ state: FileState) -> Color {
        switch state {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .copied: .blue
        case .unmerged: .red
        }
    }
}
