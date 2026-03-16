import Foundation
import ImpressLogging
import OSLog

/// Notification posted when git status changes for any tracked project.
extension Notification.Name {
    public static let gitStatusDidChange = Notification.Name("gitStatusDidChange")
}

/// High-level sync orchestration for git projects.
///
/// Coordinates clone, pull, commit+push, and auto-sync timing. All apps
/// use this coordinator instead of calling `GitClient` directly for sync
/// workflows.
@MainActor
@Observable
public final class GitSyncCoordinator {
    public static let shared = GitSyncCoordinator()

    /// Current status per tracked project path.
    public private(set) var projectStatuses: [String: RepoStatus] = [:]

    /// Whether any project is currently syncing.
    public private(set) var isSyncing = false

    /// Last error from a sync operation (cleared on next success).
    public private(set) var lastError: String?

    private let client = GitClient.shared
    private var autoSyncTasks: [String: Task<Void, Never>] = [:]

    /// Startup grace period (per CLAUDE.md: no background mutations in first 90s).
    private static let startupGracePeriod: TimeInterval = 90

    private let startupTime = Date()

    private init() {}

    // MARK: - Status

    /// Refresh the status of a project.
    public func refreshStatus(at path: String) async {
        do {
            let status = try await client.status(at: path)
            projectStatuses[path] = status
            lastError = nil
            NotificationCenter.default.post(name: .gitStatusDidChange, object: nil, userInfo: ["path": path])
        } catch {
            logInfo("Git status refresh failed for \(path): \(error)", category: "git")
        }
    }

    // MARK: - Sync Workflows

    /// Report describing the outcome of a sync operation.
    public struct SyncReport: Sendable {
        public let pulled: PullResult?
        public let committed: CommitResult?
        public let pushed: Bool
        public let conflicts: [String]
    }

    /// Full sync cycle: pull, detect conflicts, optionally commit+push.
    public func sync(project: GitProject) async throws -> SyncReport {
        isSyncing = true
        defer { isSyncing = false }

        logInfo("Syncing \(project.localPath) [\(project.branch)]", category: "git")

        // 1. Pull first
        let pullResult = try await client.pull(at: project.localPath, rebase: true)

        if !pullResult.conflicts.isEmpty {
            logInfo("Pull produced \(pullResult.conflicts.count) conflicts", category: "git")
            await refreshStatus(at: project.localPath)
            return SyncReport(pulled: pullResult, committed: nil, pushed: false, conflicts: pullResult.conflicts)
        }

        // 2. Check if there are local changes to commit
        let status = try await client.status(at: project.localPath)
        projectStatuses[project.localPath] = status

        var commitResult: CommitResult?
        var pushed = false

        if !status.isClean && project.autoCommit {
            // Stage and commit
            let changedFiles = status.modified.map(\.path) + status.untracked
            if !changedFiles.isEmpty {
                try await client.add(at: project.localPath, files: changedFiles)
                let message = "Update \(changedFiles.count) file\(changedFiles.count == 1 ? "" : "s") from impress"
                commitResult = try await client.commit(at: project.localPath, message: message)
                logInfo("Committed: \(commitResult?.hash.prefix(8) ?? "?")", category: "git")
            }
        }

        // 3. Push if configured
        if project.autoPush && (commitResult != nil || pullResult.newCommits > 0) {
            do {
                try await client.push(at: project.localPath)
                pushed = true
                logInfo("Pushed to remote", category: "git")
            } catch {
                // Push failed — likely behind; don't block the sync report
                logInfo("Push failed: \(error)", category: "git")
            }
        }

        await refreshStatus(at: project.localPath)
        lastError = nil

        return SyncReport(pulled: pullResult, committed: commitResult, pushed: pushed, conflicts: [])
    }

    /// Manual commit + optional push.
    public func commitAndPush(
        at path: String,
        message: String,
        files: [String],
        push: Bool = false
    ) async throws -> CommitResult {
        isSyncing = true
        defer { isSyncing = false }

        let result = try await client.commit(at: path, message: message, files: files)
        logInfo("Committed \(result.filesChanged) files: \(result.hash.prefix(8))", category: "git")

        if push {
            try await client.push(at: path)
            logInfo("Pushed", category: "git")
        }

        await refreshStatus(at: path)
        lastError = nil
        return result
    }

    /// Clone a repository and return the project metadata.
    public func linkRepo(
        url: String,
        destination: String,
        branch: String? = nil,
        appID: String? = nil
    ) async throws -> GitProject {
        isSyncing = true
        defer { isSyncing = false }

        let result = try await client.clone(url: url, to: destination, branch: branch)
        logInfo("Cloned \(url) → \(destination)", category: "git")

        let project = GitProject(
            repositoryUrl: url,
            localPath: result.localPath,
            branch: result.branch,
            lastCommitHash: result.commitHash,
            appID: appID
        )

        await refreshStatus(at: destination)
        return project
    }

    /// Create a new repository (GitHub via `gh` or local init).
    public func createAndLinkRepo(
        name: String,
        at path: String,
        description: String? = nil,
        isPrivate: Bool = true,
        org: String? = nil,
        appID: String? = nil
    ) async throws -> GitProject {
        isSyncing = true
        defer { isSyncing = false }

        let result = try await client.createRepo(
            at: path,
            name: name,
            description: description,
            isPrivate: isPrivate,
            org: org
        )
        logInfo("Created repo: \(result.method) at \(path)", category: "git")

        let project = GitProject(
            repositoryUrl: result.remoteUrl ?? "",
            localPath: result.localPath,
            branch: "main",
            lastCommitHash: result.initialCommit,
            appID: appID
        )

        await refreshStatus(at: path)
        return project
    }

    // MARK: - Auto-Sync Timer

    /// Start auto-fetching for a project at the configured interval.
    public func startAutoSync(project: GitProject) {
        guard project.syncIntervalMinutes > 0 else { return }
        let path = project.localPath
        let interval = TimeInterval(project.syncIntervalMinutes * 60)

        stopAutoSync(at: path)

        autoSyncTasks[path] = Task { [weak self] in
            // Respect startup grace period
            let elapsed = Date().timeIntervalSince(self?.startupTime ?? Date())
            if elapsed < Self.startupGracePeriod {
                let remaining = Self.startupGracePeriod - elapsed
                try? await Task.sleep(for: .seconds(remaining))
                if Task.isCancelled { return }
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await self?.refreshStatus(at: path)

                // Auto-pull if clean and behind
                if let status = self?.projectStatuses[path],
                   status.isClean && status.behind > 0 {
                    logInfo("Auto-pulling \(status.behind) commits at \(path)", category: "git")
                    _ = try? await self?.client.pull(at: path, rebase: true)
                    await self?.refreshStatus(at: path)
                }
            }
        }
    }

    /// Stop auto-sync for a project.
    public func stopAutoSync(at path: String) {
        autoSyncTasks[path]?.cancel()
        autoSyncTasks.removeValue(forKey: path)
    }

    /// Stop all auto-sync timers.
    public func stopAllAutoSync() {
        for (_, task) in autoSyncTasks {
            task.cancel()
        }
        autoSyncTasks.removeAll()
    }
}
