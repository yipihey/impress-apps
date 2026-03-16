import Foundation

// MARK: - Repository Status

/// Status of a git repository.
public struct RepoStatus: Codable, Sendable {
    public let branch: String
    public let ahead: UInt32
    public let behind: UInt32
    public let modified: [FileStatus]
    public let staged: [FileStatus]
    public let untracked: [String]
    public let hasConflicts: Bool
    public let isClean: Bool

    enum CodingKeys: String, CodingKey {
        case branch, ahead, behind, modified, staged, untracked
        case hasConflicts = "has_conflicts"
        case isClean = "is_clean"
    }
}

/// Status of a single tracked file.
public struct FileStatus: Codable, Sendable {
    public let path: String
    public let status: FileState
}

/// Possible states for a tracked file.
public enum FileState: String, Codable, Sendable {
    case modified = "Modified"
    case added = "Added"
    case deleted = "Deleted"
    case renamed = "Renamed"
    case copied = "Copied"
    case unmerged = "Unmerged"
}

// MARK: - Log

/// A single commit log entry.
public struct LogEntry: Codable, Sendable, Identifiable {
    public let hash: String
    public let shortHash: String
    public let message: String
    public let author: String
    public let email: String
    public let date: Date

    public var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, message, author, email, date
        case shortHash = "short_hash"
    }
}

// MARK: - Branch

/// A git branch (local or remote).
public struct GitBranch: Codable, Sendable, Identifiable {
    public let name: String
    public let isRemote: Bool
    public let isCurrent: Bool
    public let upstream: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, upstream
        case isRemote = "is_remote"
        case isCurrent = "is_current"
    }
}

// MARK: - Diff

/// Summary of a diff.
public struct DiffSummary: Codable, Sendable {
    public let files: [DiffFile]
    public let insertions: UInt32
    public let deletions: UInt32
}

/// A single file in a diff summary.
public struct DiffFile: Codable, Sendable, Identifiable {
    public let path: String
    public let status: String
    public let additions: UInt32
    public let removals: UInt32

    public var id: String { path }
}

// MARK: - Remote

/// Information about a git remote.
public struct RemoteInfo: Codable, Sendable, Identifiable {
    public let name: String
    public let fetchUrl: String
    public let pushUrl: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case fetchUrl = "fetch_url"
        case pushUrl = "push_url"
    }
}

// MARK: - Operation Results

/// Result of a clone operation.
public struct CloneResult: Codable, Sendable {
    public let localPath: String
    public let branch: String
    public let commitHash: String

    enum CodingKeys: String, CodingKey {
        case branch
        case localPath = "local_path"
        case commitHash = "commit_hash"
    }
}

/// Result of a commit operation.
public struct CommitResult: Codable, Sendable {
    public let hash: String
    public let filesChanged: UInt32

    enum CodingKeys: String, CodingKey {
        case hash
        case filesChanged = "files_changed"
    }
}

/// Result of a pull operation.
public struct PullResult: Codable, Sendable {
    public let newCommits: UInt32
    public let conflicts: [String]
    public let fastForward: Bool

    enum CodingKeys: String, CodingKey {
        case conflicts
        case newCommits = "new_commits"
        case fastForward = "fast_forward"
    }
}

/// Result of repo creation.
public struct CreateRepoResult: Codable, Sendable {
    public let localPath: String
    public let remoteUrl: String?
    public let initialCommit: String?
    public let method: CreateMethod

    enum CodingKeys: String, CodingKey {
        case method
        case localPath = "local_path"
        case remoteUrl = "remote_url"
        case initialCommit = "initial_commit"
    }
}

/// How the repository was created.
public enum CreateMethod: String, Codable, Sendable {
    case ghCli = "GhCli"
    case localInit = "LocalInit"
}

// MARK: - Discovery

/// Discovery result for git/gh CLI availability.
public struct GitDiscovery: Codable, Sendable {
    public let gitAvailable: Bool
    public let gitVersion: String?
    public let ghAvailable: Bool
    public let ghVersion: String?
    public let userName: String?
    public let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case gitAvailable = "git_available"
        case gitVersion = "git_version"
        case ghAvailable = "gh_available"
        case ghVersion = "gh_version"
        case userName = "user_name"
        case userEmail = "user_email"
    }
}

// MARK: - Git Project (stored in shared store)

/// A git project tracked in the shared impress-core store.
public struct GitProject: Sendable, Identifiable {
    public var id: UUID
    public var repositoryUrl: String
    public var localPath: String
    public var branch: String
    public var projectType: String?
    public var mainFile: String?
    public var lastSyncTime: Date?
    public var lastCommitHash: String?
    public var autoCommit: Bool
    public var autoPush: Bool
    public var syncIntervalMinutes: Int
    public var appID: String?

    public init(
        id: UUID = UUID(),
        repositoryUrl: String,
        localPath: String,
        branch: String = "main",
        projectType: String? = nil,
        mainFile: String? = nil,
        lastSyncTime: Date? = nil,
        lastCommitHash: String? = nil,
        autoCommit: Bool = false,
        autoPush: Bool = false,
        syncIntervalMinutes: Int = 0,
        appID: String? = nil
    ) {
        self.id = id
        self.repositoryUrl = repositoryUrl
        self.localPath = localPath
        self.branch = branch
        self.projectType = projectType
        self.mainFile = mainFile
        self.lastSyncTime = lastSyncTime
        self.lastCommitHash = lastCommitHash
        self.autoCommit = autoCommit
        self.autoPush = autoPush
        self.syncIntervalMinutes = syncIntervalMinutes
        self.appID = appID
    }
}

// MARK: - Error Response

/// Error returned from git toolbox endpoints.
public struct GitErrorResponse: Codable, Sendable {
    public let error: String
    public let stderr: String?
}
