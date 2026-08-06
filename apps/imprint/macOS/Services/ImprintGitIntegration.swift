import Foundation
import ImpressGit
import ImpressLogging
import SwiftUI

/// Wires `ImpressGit` into imprint's document lifecycle.
///
/// - On save: auto-commit if configured
/// - On open LaTeX project: offer to link if it's a git repo
/// - After pull: re-scan project files
@MainActor
@Observable
final class ImprintGitIntegration {
    static let shared = ImprintGitIntegration()

    /// The git project linked to the current document (if any).
    var activeProject: GitProject?

    /// Directory of the focused manuscript's on-disk file, when it has one
    /// (ADR-0023 watched/external manuscripts — e.g. the repo's ADR markdown
    /// files). Store-native manuscripts have no file, so this stays nil.
    ///
    /// Read-only git surfaces (History, status) work from any directory
    /// inside a repo, so this is enough to show history for a watched file
    /// without linking a project first.
    var activeFileDirectory: String?

    /// Where read-only git verbs (History) point: the linked project if one
    /// exists, else the focused manuscript's file directory.
    var effectiveRepoPath: String? {
        activeProject?.localPath ?? activeFileDirectory
    }

    /// Whether the git commit sheet is showing.
    var showingCommitSheet = false

    /// Whether the git link sheet is showing.
    var showingLinkSheet = false

    /// Whether the git create sheet is showing.
    var showingCreateSheet = false

    /// Whether the git history view is showing.
    var showingHistory = false

    /// Whether a git conflict panel should be shown.
    var showingConflictPanel = false

    /// Files with merge conflicts (populated after a conflicted pull).
    var conflictFiles: [String] = []

    /// Current repo status (nil if no project linked or toolbox unavailable).
    var repoStatus: RepoStatus? {
        guard let project = activeProject else { return nil }
        return GitSyncCoordinator.shared.projectStatuses[project.localPath]
    }

    /// Whether the coordinator is currently syncing.
    var isSyncing: Bool { GitSyncCoordinator.shared.isSyncing }

    private init() {}

    // MARK: - Lifecycle

    /// Call when a document opens. Checks if the file is inside a git repo.
    func documentOpened(at fileURL: URL?) {
        guard let fileURL else {
            logInfo("Git: documentOpened called with nil URL", category: "git")
            return
        }
        let path = fileURL.deletingLastPathComponent().path
        logInfo("Git: documentOpened at \(path)", category: "git")

        // Check if we have a stored project for this path
        if let project = GitProjectStore.shared.project(at: path) {
            activeProject = project
            Task {
                await GitSyncCoordinator.shared.refreshStatus(at: path)
            }
            GitSyncCoordinator.shared.startAutoSync(project: project)
            logInfo("Git: found stored project — repo=\(project.repositoryUrl), branch=\(project.branch)", category: "git")
        } else {
            logInfo("Git: no stored project for path \(path)", category: "git")
        }
    }

    /// Call when a document closes.
    func documentClosed() {
        logInfo("Git: documentClosed (project: \(activeProject?.localPath ?? "nil"))", category: "git")
        if let project = activeProject {
            GitSyncCoordinator.shared.stopAutoSync(at: project.localPath)
        }
        activeProject = nil
    }

    /// Track the chassis's focused manuscript. Resolves the manuscript's
    /// external file (if it is a watched/external row) so read-only git verbs
    /// have a repo to point at, and picks up a stored project for that
    /// directory when one exists.
    func focusedManuscriptChanged(_ id: UUID?) {
        guard let id else {
            activeFileDirectory = nil
            return
        }
        let model = ManuscriptStoreAdapter.shared.manuscript(id: id)
        guard let path = model?.externalSource?.path else {
            activeFileDirectory = nil
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        activeFileDirectory = dir
        logInfo("Git: focused manuscript is external file at \(dir)", category: "git")
        if activeProject == nil, let project = GitProjectStore.shared.project(at: dir) {
            activeProject = project
            Task { await GitSyncCoordinator.shared.refreshStatus(at: dir) }
            logInfo("Git: found stored project for focused file — \(project.repositoryUrl)", category: "git")
        }
    }

    // MARK: - Save Hook

    /// Call after a document save. If auto-commit is enabled, commits and optionally pushes.
    func documentSaved(at fileURL: URL?) {
        logInfo("Git: documentSaved (autoCommit: \(activeProject?.autoCommit ?? false))", category: "git")
        guard let project = activeProject, project.autoCommit else { return }
        guard let fileURL else { return }

        let path = project.localPath
        let relativePath = fileURL.path.replacingOccurrences(of: path + "/", with: "")

        Task {
            do {
                let message = "Update \(relativePath) from imprint"
                let result = try await GitSyncCoordinator.shared.commitAndPush(
                    at: path,
                    message: message,
                    files: [relativePath],
                    push: project.autoPush
                )
                logInfo("Auto-committed: \(result.hash.prefix(8))", category: "git")
            } catch {
                logInfo("Auto-commit failed: \(error)", category: "git")
            }
        }
    }

    // MARK: - Menu Actions

    func handleCommit() {
        logInfo("Git: commit requested (project: \(activeProject != nil))", category: "git")
        guard activeProject != nil else {
            showingLinkSheet = true // No project — prompt to link
            return
        }
        showingCommitSheet = true
    }

    func handlePush() {
        logInfo("Git: push requested (project: \(activeProject?.localPath ?? "nil"))", category: "git")
        guard let project = activeProject else {
            logInfo("Git: push with no linked project — opening link sheet", category: "git")
            showingLinkSheet = true
            return
        }
        Task {
            do {
                try await GitClient.shared.push(at: project.localPath)
                await GitSyncCoordinator.shared.refreshStatus(at: project.localPath)
                logInfo("Git: pushed successfully", category: "git")
            } catch {
                logInfo("Git: push failed: \(error)", category: "git")
            }
        }
    }

    func handlePull() {
        logInfo("Git: pull requested (project: \(activeProject?.localPath ?? "nil"))", category: "git")
        guard let project = activeProject else {
            logInfo("Git: pull with no linked project — opening link sheet", category: "git")
            showingLinkSheet = true
            return
        }
        Task {
            do {
                let result = try await GitClient.shared.pull(at: project.localPath, rebase: true)
                await GitSyncCoordinator.shared.refreshStatus(at: project.localPath)

                if !result.conflicts.isEmpty {
                    conflictFiles = result.conflicts
                    showingConflictPanel = true
                    logInfo("Git: pull found \(result.conflicts.count) conflicts", category: "git")
                } else {
                    logInfo("Git: pulled \(result.newCommits) commits", category: "git")
                }
            } catch {
                logInfo("Git: pull failed: \(error)", category: "git")
            }
        }
    }

    func handleLink() {
        logInfo("Git: opening link sheet", category: "git")
        showingLinkSheet = true
    }

    func handleCreateRepo() {
        logInfo("Git: opening create repo sheet", category: "git")
        showingCreateSheet = true
    }

    func handleHistory() {
        logInfo(
            "Git: history requested (repo: \(effectiveRepoPath ?? "none"))",
            category: "git")
        guard effectiveRepoPath != nil else {
            // Nothing to show history OF: no linked project and the focused
            // manuscript is store-native. Open the link sheet so the menu
            // item always answers with something.
            logInfo("Git: history with no repo in scope — opening link sheet", category: "git")
            showingLinkSheet = true
            return
        }
        showingHistory = true
    }

    // MARK: - Callbacks

    func onProjectLinked(_ project: GitProject) {
        logInfo("Git: project linked — repo=\(project.repositoryUrl), path=\(project.localPath)", category: "git")
        activeProject = project
        GitProjectStore.shared.add(project)
        showingLinkSheet = false
        showingCreateSheet = false
        GitSyncCoordinator.shared.startAutoSync(project: project)
    }

    func onCommitCompleted(message: String, files: [String], push: Bool) {
        guard let project = activeProject else { return }
        Task {
            do {
                _ = try await GitSyncCoordinator.shared.commitAndPush(
                    at: project.localPath,
                    message: message,
                    files: files,
                    push: push
                )
            } catch {
                logInfo("Commit failed: \(error)", category: "git")
            }
        }
        showingCommitSheet = false
    }

    func onConflictsResolved() {
        showingConflictPanel = false
        conflictFiles = []
        if let project = activeProject {
            Task { await GitSyncCoordinator.shared.refreshStatus(at: project.localPath) }
        }
    }
}

// MARK: - View Modifier

/// The Git menu's observers + sheets, attached once at the chassis root
/// (`ImprintChassisRoot`). Extracted as a modifier to keep the root's
/// type-checking cheap.
struct GitIntegrationModifier: ViewModifier {
    @Bindable private var git = ImprintGitIntegration.shared
    /// The chassis's focused manuscript (set by `ManuscriptSectionView` /
    /// the standalone editor window) — how git learns which file, and thus
    /// which repo, is in scope.
    @FocusedValue(\.focusedManuscriptID) private var focusedManuscriptID

    func body(content: Content) -> some View {
        content
            .onChange(of: focusedManuscriptID) { _, id in
                git.focusedManuscriptChanged(id)
            }
            .sheet(isPresented: $git.showingCommitSheet) {
                commitSheet
            }
            .sheet(isPresented: $git.showingLinkSheet) {
                linkSheet
            }
            .sheet(isPresented: $git.showingCreateSheet) {
                createSheet
            }
            .sheet(isPresented: $git.showingConflictPanel) {
                conflictSheet
            }
            .sheet(isPresented: $git.showingHistory) {
                historySheet
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitCommit)) { _ in git.handleCommit() }
            .onReceive(NotificationCenter.default.publisher(for: .gitPush)) { _ in git.handlePush() }
            .onReceive(NotificationCenter.default.publisher(for: .gitPull)) { _ in git.handlePull() }
            .onReceive(NotificationCenter.default.publisher(for: .gitLink)) { _ in git.handleLink() }
            .onReceive(NotificationCenter.default.publisher(for: .gitCreateRepo)) { _ in git.handleCreateRepo() }
            .onReceive(NotificationCenter.default.publisher(for: .gitHistory)) { _ in git.handleHistory() }
    }

    @ViewBuilder
    private var commitSheet: some View {
        if let project = git.activeProject {
            GitCommitSheet(
                repoPath: project.localPath,
                onCommit: { msg, files, push in git.onCommitCompleted(message: msg, files: files, push: push) },
                onDismiss: { git.showingCommitSheet = false }
            )
        }
    }

    @ViewBuilder
    private var linkSheet: some View {
        GitLinkSheet(
            appID: "imprint",
            onLink: { git.onProjectLinked($0) },
            onDismiss: { git.showingLinkSheet = false }
        )
    }

    @ViewBuilder
    private var createSheet: some View {
        GitCreateSheet(
            localPath: git.activeProject?.localPath ?? NSHomeDirectory(),
            appID: "imprint",
            onCreated: { git.onProjectLinked($0) },
            onDismiss: { git.showingCreateSheet = false }
        )
    }

    @ViewBuilder
    private var conflictSheet: some View {
        if let project = git.activeProject {
            GitConflictPanel(
                repoPath: project.localPath,
                conflictFiles: git.conflictFiles,
                onResolved: { git.onConflictsResolved() },
                onDismiss: { git.showingConflictPanel = false }
            )
        }
    }

    @ViewBuilder
    private var historySheet: some View {
        // The linked project when there is one; else the focused external
        // file's directory (git log works from any directory in the repo).
        if let repoPath = git.effectiveRepoPath {
            GitHistoryView(repoPath: repoPath)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
