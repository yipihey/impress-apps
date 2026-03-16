use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Status of a git repository (parsed from `git status --porcelain=v2 --branch`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoStatus {
    pub branch: String,
    pub ahead: u32,
    pub behind: u32,
    pub modified: Vec<FileStatus>,
    pub staged: Vec<FileStatus>,
    pub untracked: Vec<String>,
    pub has_conflicts: bool,
    pub is_clean: bool,
}

/// Status of a single file in the working tree or index.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileStatus {
    pub path: String,
    pub status: FileState,
}

/// Possible states for a tracked file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileState {
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    Unmerged,
}

/// A single commit log entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEntry {
    pub hash: String,
    pub short_hash: String,
    pub message: String,
    pub author: String,
    pub email: String,
    pub date: DateTime<Utc>,
}

/// A git branch (local or remote).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Branch {
    pub name: String,
    pub is_remote: bool,
    pub is_current: bool,
    pub upstream: Option<String>,
}

/// Summary of a diff (parsed from `git diff --numstat`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffSummary {
    pub files: Vec<DiffFile>,
    pub insertions: u32,
    pub deletions: u32,
}

/// A single file in a diff summary.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffFile {
    pub path: String,
    pub status: String,
    pub additions: u32,
    pub removals: u32,
}

/// A region of conflict markers in a file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictRegion {
    pub ours: String,
    pub theirs: String,
    pub base: Option<String>,
    /// Byte offset of the conflict start in the original file.
    pub start_offset: usize,
    /// Byte offset of the conflict end in the original file.
    pub end_offset: usize,
}

/// A resolved conflict region for applying back to a file.
#[derive(Debug, Clone)]
pub struct ResolvedRegion {
    pub start_offset: usize,
    pub end_offset: usize,
    pub resolution: String,
}

/// Result of a clone operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloneResult {
    pub local_path: String,
    pub branch: String,
    pub commit_hash: String,
}

/// Result of a commit operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitResult {
    pub hash: String,
    pub files_changed: u32,
}

/// Result of a pull operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullResult {
    pub new_commits: u32,
    pub conflicts: Vec<String>,
    pub fast_forward: bool,
}

/// Information about a git remote.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteInfo {
    pub name: String,
    pub fetch_url: String,
    pub push_url: String,
}

/// Result of repository creation (via `gh` or manual init).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateRepoResult {
    pub local_path: String,
    pub remote_url: Option<String>,
    pub initial_commit: Option<String>,
    pub method: CreateMethod,
}

/// How the repository was created.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CreateMethod {
    /// Created via `gh repo create`
    GhCli,
    /// Created via `git init` only (no remote)
    LocalInit,
}

/// Discovery result for git/gh CLI availability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitDiscovery {
    pub git_available: bool,
    pub git_version: Option<String>,
    pub gh_available: bool,
    pub gh_version: Option<String>,
    pub user_name: Option<String>,
    pub user_email: Option<String>,
}

/// A constructed git command ready for execution.
#[derive(Debug, Clone)]
pub struct GitCommand {
    pub executable: String,
    pub args: Vec<String>,
    pub env: HashMap<String, String>,
}
