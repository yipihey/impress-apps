import SwiftUI

/// Sheet for creating a new GitHub repository from a local project.
public struct GitCreateSheet: View {
    let localPath: String
    let appID: String
    let onCreated: (GitProject) -> Void
    let onDismiss: () -> Void

    @State private var repoName: String
    @State private var description = ""
    @State private var isPrivate = true
    @State private var org = ""
    @State private var discovery: GitDiscovery?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var manualURL = ""
    @State private var showManualFlow = false

    public init(
        localPath: String,
        appID: String = "imprint",
        onCreated: @escaping (GitProject) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.localPath = localPath
        self.appID = appID
        self.onCreated = onCreated
        self.onDismiss = onDismiss
        // Pre-fill repo name from folder name
        let folderName = URL(fileURLWithPath: localPath).lastPathComponent
        self._repoName = State(initialValue: folderName)
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Create GitHub Repository")
                .font(.headline)

            if discovery == nil {
                ProgressView("Checking git availability...")
            } else if showManualFlow {
                manualFlowView
            } else {
                mainFormView
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }

                if showManualFlow {
                    Button("Link Remote") { Task { await linkManualRemote() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(manualURL.isEmpty || isCreating)
                } else {
                    Button("Create Repository") { Task { await createRepo() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(repoName.isEmpty || isCreating)
                }
            }
        }
        .padding()
        .frame(width: 480)
        .task { await checkGitAvailability() }
    }

    private var mainFormView: some View {
        Form {
            Section("Repository") {
                TextField("Name", text: $repoName)
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $description)
                    .textFieldStyle(.roundedBorder)

                Picker("Visibility", selection: $isPrivate) {
                    Text("Private").tag(true)
                    Text("Public").tag(false)
                }
                .pickerStyle(.segmented)

                if !(discovery?.userName ?? "").isEmpty {
                    TextField("Organization (optional)", text: $org)
                        .textFieldStyle(.roundedBorder)
                        .help("Leave empty to create under your personal account")
                }
            }

            Section("Status") {
                ghStatusRow
            }

            Section {
                Text("Local path: \(localPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var ghStatusRow: some View {
        if let disc = discovery {
            HStack {
                if disc.ghAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("GitHub CLI available")
                            .font(.caption)
                        if let user = disc.userName {
                            Text("Signed in as \(user)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("GitHub CLI not found")
                            .font(.caption)
                        Text("Install with: brew install gh")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Create Manually") {
                        showManualFlow = true
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var manualFlowView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Setup")
                .font(.subheadline)
                .bold()

            Text("A local git repository has been initialized. To push to GitHub:")
                .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Create a repository on github.com")
                Text("2. Copy the repository URL and paste it below")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Repository URL", text: $manualURL)
                .textFieldStyle(.roundedBorder)
                .help("e.g. git@github.com:user/repo.git")
        }
    }

    private func checkGitAvailability() async {
        do {
            discovery = try await GitClient.shared.discoverGit()
            if !(discovery?.ghAvailable ?? false) {
                // gh not available — still allow manual flow
            }
        } catch {
            discovery = GitDiscovery(
                gitAvailable: false, gitVersion: nil,
                ghAvailable: false, ghVersion: nil,
                userName: nil, userEmail: nil
            )
        }
    }

    private func createRepo() async {
        isCreating = true
        errorMessage = nil

        do {
            let project = try await GitSyncCoordinator.shared.createAndLinkRepo(
                name: repoName,
                at: localPath,
                description: description.isEmpty ? nil : description,
                isPrivate: isPrivate,
                org: org.isEmpty ? nil : org,
                appID: appID
            )
            onCreated(project)
        } catch {
            errorMessage = error.localizedDescription
            // If gh failed, offer manual flow
            if !(discovery?.ghAvailable ?? false) {
                showManualFlow = true
            }
        }

        isCreating = false
    }

    private func linkManualRemote() async {
        isCreating = true
        errorMessage = nil

        do {
            let client = GitClient.shared
            // Init if not already a repo
            try await client.initRepo(at: localPath)
            try await client.addRemote(at: localPath, name: "origin", url: manualURL)
            try await client.add(at: localPath, files: ["."])
            let result = try await client.commit(at: localPath, message: "Initial commit from impress")
            try await client.push(at: localPath)

            let project = GitProject(
                repositoryUrl: manualURL,
                localPath: localPath,
                branch: "main",
                lastCommitHash: result.hash,
                appID: appID
            )
            onCreated(project)
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreating = false
    }
}
