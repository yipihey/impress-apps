import SwiftUI

/// Sheet for cloning a remote repo or linking an existing local git repo.
public struct GitLinkSheet: View {
    let defaultDestination: String
    let appID: String
    let onLink: (GitProject) -> Void
    let onDismiss: () -> Void

    enum LinkMode: String, CaseIterable {
        case cloneRemote = "Clone Remote"
        case linkExisting = "Link Existing"
    }

    @State private var mode: LinkMode = .cloneRemote

    // Clone Remote state
    @State private var repoURL = ""
    @State private var destination = ""
    @State private var branch = ""

    // Link Existing state
    @State private var localRepoPath = ""
    @State private var detectedRemoteURL = ""
    @State private var detectedBranch = ""
    @State private var isDetecting = false
    @State private var detectionError: String?

    // Shared state
    @State private var autoCommit = false
    @State private var autoPush = false
    @State private var syncInterval = 0
    @State private var isCloning = false
    @State private var errorMessage: String?
    @State private var toolboxAvailable: Bool?

    public init(
        defaultDestination: String = "",
        appID: String = "imprint",
        onLink: @escaping (GitProject) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.defaultDestination = defaultDestination
        self.appID = appID
        self.onLink = onLink
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Link Git Repository")
                .font(.headline)

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
            }

            Picker("Mode", selection: $mode) {
                ForEach(LinkMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Form {
                switch mode {
                case .cloneRemote:
                    cloneRemoteForm
                case .linkExisting:
                    linkExistingForm
                }

                Section("Sync Settings") {
                    Toggle("Auto-commit on save", isOn: $autoCommit)
                    Toggle("Auto-push after commit", isOn: $autoPush)
                        .disabled(!autoCommit)
                    Picker("Auto-fetch interval", selection: $syncInterval) {
                        Text("Manual only").tag(0)
                        Text("Every 5 minutes").tag(5)
                        Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30)
                        Text("Every hour").tag(60)
                    }
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isCloning || isDetecting {
                    ProgressView()
                        .controlSize(.small)
                }

                switch mode {
                case .cloneRemote:
                    Button("Clone & Link") { Task { await cloneRepo() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(repoURL.isEmpty || destination.isEmpty || isCloning || toolboxAvailable == false)

                case .linkExisting:
                    Button("Link") { Task { await linkExisting() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(localRepoPath.isEmpty || isDetecting || toolboxAvailable == false)
                }
            }
        }
        .padding()
        .frame(width: 500)
        .onAppear {
            if destination.isEmpty { destination = defaultDestination }
        }
        .task {
            do {
                _ = try await GitClient.shared.discoverGit()
                toolboxAvailable = true
            } catch {
                toolboxAvailable = false
            }
        }
    }

    // MARK: - Clone Remote Form

    @ViewBuilder
    private var cloneRemoteForm: some View {
        Section("Repository") {
            TextField("URL (SSH or HTTPS)", text: $repoURL)
                .textFieldStyle(.roundedBorder)
                .help("e.g. git@github.com:user/paper.git")

            HStack {
                TextField("Local path", text: $destination)
                    .textFieldStyle(.roundedBorder)

                #if os(macOS)
                Button("Browse...") { browseFolder(binding: $destination) }
                #endif
            }

            TextField("Branch (leave empty for default)", text: $branch)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Link Existing Form

    @ViewBuilder
    private var linkExistingForm: some View {
        Section("Local Repository") {
            HStack {
                TextField("Path to local git repo", text: $localRepoPath)
                    .textFieldStyle(.roundedBorder)

                #if os(macOS)
                Button("Browse...") { browseFolder(binding: $localRepoPath) }
                #endif
            }

            if !detectedRemoteURL.isEmpty {
                LabeledContent("Remote") {
                    Text(detectedRemoteURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if !detectedBranch.isEmpty {
                LabeledContent("Branch") {
                    Text(detectedBranch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = detectionError {
                Text(error)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .onChange(of: localRepoPath) { _, newPath in
            guard !newPath.isEmpty else { return }
            Task { await detectRepoInfo(at: newPath) }
        }
    }

    // MARK: - Actions

    #if os(macOS)
    private func browseFolder(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
    #endif

    private func detectRepoInfo(at path: String) async {
        isDetecting = true
        detectionError = nil
        detectedRemoteURL = ""
        detectedBranch = ""

        do {
            // Check if it's a valid repo by fetching status
            let status = try await GitClient.shared.status(at: path)
            detectedBranch = status.branch

            // Try to get remotes
            let remotes = try await GitClient.shared.remotes(at: path)
            if let origin = remotes.first(where: { $0.name == "origin" }) {
                detectedRemoteURL = origin.fetchUrl
            } else if let first = remotes.first {
                detectedRemoteURL = first.fetchUrl
            }
        } catch {
            detectionError = "Not a valid git repository, or toolbox unavailable."
        }

        isDetecting = false
    }

    private func cloneRepo() async {
        isCloning = true
        errorMessage = nil

        do {
            let project = try await GitSyncCoordinator.shared.linkRepo(
                url: repoURL,
                destination: destination,
                branch: branch.isEmpty ? nil : branch,
                appID: appID
            )
            var linked = project
            linked.autoCommit = autoCommit
            linked.autoPush = autoPush
            linked.syncIntervalMinutes = syncInterval
            onLink(linked)
        } catch {
            errorMessage = error.localizedDescription
        }

        isCloning = false
    }

    private func linkExisting() async {
        errorMessage = nil

        // Verify this is actually a repo
        do {
            let status = try await GitClient.shared.status(at: localRepoPath)

            let project = GitProject(
                repositoryUrl: detectedRemoteURL,
                localPath: localRepoPath,
                branch: status.branch,
                autoCommit: autoCommit,
                autoPush: autoPush,
                syncIntervalMinutes: syncInterval,
                appID: appID
            )
            onLink(project)
        } catch {
            errorMessage = "Failed to verify repository: \(error.localizedDescription)"
        }
    }
}
