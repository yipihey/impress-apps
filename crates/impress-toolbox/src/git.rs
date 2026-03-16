use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::process::Command;

use impress_git::commands;
use impress_git::models::{
    CloneResult, CommitResult, CreateMethod, CreateRepoResult, GitDiscovery, PullResult,
};
use impress_git::parse;

use crate::git_types::*;

/// Build the `/git` sub-router with all git endpoints.
pub fn router() -> Router {
    Router::new()
        .route("/discover", get(handle_discover_git))
        .route("/clone", post(handle_clone))
        .route("/status", get(handle_status))
        .route("/commit", post(handle_commit))
        .route("/push", post(handle_push))
        .route("/pull", post(handle_pull))
        .route("/log", get(handle_log))
        .route("/diff", get(handle_diff))
        .route("/diff/stat", get(handle_diff_stat))
        .route("/branches", get(handle_branches))
        .route("/checkout", post(handle_checkout))
        .route("/init", post(handle_init))
        .route("/add", post(handle_add))
        .route("/remote/add", post(handle_remote_add))
        .route("/remotes", get(handle_remotes))
        .route("/create-repo", post(handle_create_repo))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type GitResult<T> = Result<Json<T>, (StatusCode, Json<GitError>)>;

fn git_err(status: StatusCode, msg: impl Into<String>, stderr: Option<String>) -> (StatusCode, Json<GitError>) {
    (
        status,
        Json(GitError {
            error: msg.into(),
            stderr,
        }),
    )
}

/// Execute a `GitCommand` in the given working directory and return (stdout, stderr, exit_code).
async fn exec_git(
    cmd: &impress_git::models::GitCommand,
    working_dir: &str,
) -> Result<(String, String, i32), (StatusCode, Json<GitError>)> {
    let mut process = Command::new(&cmd.executable);
    process.args(&cmd.args);
    process.current_dir(working_dir);
    process.envs(&cmd.env);
    process.stdout(std::process::Stdio::piped());
    process.stderr(std::process::Stdio::piped());

    tracing::info!(
        executable = %cmd.executable,
        args = ?cmd.args,
        cwd = %working_dir,
        "git exec"
    );

    let child = process.spawn().map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to spawn git: {}", e),
            None,
        )
    })?;

    let output = child.wait_with_output().await.map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to wait for git: {}", e),
            None,
        )
    })?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let code = output.status.code().unwrap_or(-1);

    tracing::info!(exit_code = code, stdout_len = stdout.len(), stderr_len = stderr.len(), "git done");

    Ok((stdout, stderr, code))
}

/// Execute a git command, returning an error if exit code != 0.
async fn exec_git_ok(
    cmd: &impress_git::models::GitCommand,
    working_dir: &str,
) -> Result<String, (StatusCode, Json<GitError>)> {
    let (stdout, stderr, code) = exec_git(cmd, working_dir).await?;
    if code != 0 {
        return Err(git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("git exited with code {}", code),
            Some(stderr),
        ));
    }
    Ok(stdout)
}

/// Execute a standalone command (e.g., `gh`, `which`) and return stdout or None.
async fn exec_simple(executable: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(executable)
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
        .await
        .ok()?;

    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /git/discover — check git/gh availability and user config.
async fn handle_discover_git() -> GitResult<GitDiscovery> {
    let git_version = exec_simple("git", &["--version"]).await;
    let gh_version = exec_simple("gh", &["--version"]).await.map(|v| {
        // gh --version returns multiple lines; take the first
        v.lines().next().unwrap_or(&v).to_string()
    });
    let user_name = exec_simple("git", &["config", "user.name"]).await;
    let user_email = exec_simple("git", &["config", "user.email"]).await;

    Ok(Json(GitDiscovery {
        git_available: git_version.is_some(),
        git_version,
        gh_available: gh_version.is_some(),
        gh_version,
        user_name,
        user_email,
    }))
}

/// POST /git/clone
async fn handle_clone(Json(req): Json<CloneRequest>) -> GitResult<CloneResult> {
    let cmd = commands::clone_cmd(&req.url, &req.target_path, req.branch.as_deref());

    // Clone doesn't have a working dir yet — use parent of target
    let parent = std::path::Path::new(&req.target_path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| "/tmp".to_string());

    exec_git_ok(&cmd, &parent).await?;

    // Read HEAD and branch from the clone
    let head_cmd = commands::rev_parse_head_cmd();
    let head = exec_git_ok(&head_cmd, &req.target_path).await?;

    let branch_cmd = commands::current_branch_cmd();
    let branch = exec_git_ok(&branch_cmd, &req.target_path).await?;

    Ok(Json(CloneResult {
        local_path: req.target_path,
        branch: branch.trim().to_string(),
        commit_hash: head.trim().to_string(),
    }))
}

/// GET /git/status?path=...
async fn handle_status(
    axum::extract::Query(q): axum::extract::Query<PathQuery>,
) -> GitResult<impress_git::models::RepoStatus> {
    let cmd = commands::status_cmd();
    let stdout = exec_git_ok(&cmd, &q.path).await?;
    let status = parse::parse_status_porcelain_v2(&stdout).map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to parse status: {}", e),
            None,
        )
    })?;
    Ok(Json(status))
}

/// POST /git/add
async fn handle_add(Json(req): Json<AddRequest>) -> GitResult<serde_json::Value> {
    let file_refs: Vec<&str> = req.files.iter().map(|s| s.as_str()).collect();
    let cmd = commands::add_cmd(&file_refs);
    exec_git_ok(&cmd, &req.path).await?;
    Ok(Json(serde_json::json!({"ok": true})))
}

/// POST /git/commit
async fn handle_commit(Json(req): Json<CommitRequest>) -> GitResult<CommitResult> {
    // Stage files if specified
    if !req.files.is_empty() {
        let file_refs: Vec<&str> = req.files.iter().map(|s| s.as_str()).collect();
        let add_cmd = commands::add_cmd(&file_refs);
        exec_git_ok(&add_cmd, &req.path).await?;
    }

    let path_refs: Vec<&str> = Vec::new();
    let cmd = commands::commit_cmd(&req.message, &path_refs);
    let (stdout, stderr, code) = exec_git(&cmd, &req.path).await?;

    if code != 0 {
        return Err(git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("git commit failed (exit {})", code),
            Some(stderr),
        ));
    }

    // Parse the commit result — get hash
    let head_cmd = commands::rev_parse_head_cmd();
    let head = exec_git_ok(&head_cmd, &req.path).await?;

    // Count files changed from the output (rough parse)
    let files_changed = stdout
        .lines()
        .find(|l| l.contains("file") && l.contains("changed"))
        .and_then(|l| l.split_whitespace().next())
        .and_then(|n| n.parse::<u32>().ok())
        .unwrap_or(0);

    Ok(Json(CommitResult {
        hash: head.trim().to_string(),
        files_changed,
    }))
}

/// POST /git/push
async fn handle_push(Json(req): Json<PushRequest>) -> GitResult<serde_json::Value> {
    let remote = req.remote.as_deref().unwrap_or("origin");
    let branch = match &req.branch {
        Some(b) => b.clone(),
        None => {
            let cmd = commands::current_branch_cmd();
            exec_git_ok(&cmd, &req.path).await?.trim().to_string()
        }
    };
    let cmd = commands::push_cmd(remote, &branch);
    exec_git_ok(&cmd, &req.path).await?;
    Ok(Json(serde_json::json!({"ok": true})))
}

/// POST /git/pull
async fn handle_pull(Json(req): Json<PullRequest>) -> GitResult<PullResult> {
    let remote = req.remote.as_deref().unwrap_or("origin");
    let branch = match &req.branch {
        Some(b) => b.clone(),
        None => {
            let cmd = commands::current_branch_cmd();
            exec_git_ok(&cmd, &req.path).await?.trim().to_string()
        }
    };

    // Get current HEAD before pull
    let pre_head_cmd = commands::rev_parse_head_cmd();
    let pre_head = exec_git_ok(&pre_head_cmd, &req.path).await?;

    let cmd = commands::pull_cmd(remote, &branch, req.rebase);
    let (stdout, stderr, code) = exec_git(&cmd, &req.path).await?;

    // Check for conflicts
    let has_conflicts = stderr.contains("CONFLICT") || stdout.contains("CONFLICT");
    let conflict_files: Vec<String> = if has_conflicts {
        let status_cmd = commands::status_cmd();
        let status_out = exec_git_ok(&status_cmd, &req.path).await.unwrap_or_default();
        let status = parse::parse_status_porcelain_v2(&status_out).unwrap_or_else(|_| {
            impress_git::models::RepoStatus {
                branch: String::new(),
                ahead: 0,
                behind: 0,
                modified: vec![],
                staged: vec![],
                untracked: vec![],
                has_conflicts: false,
                is_clean: true,
            }
        });
        impress_git::conflict::detect_conflicts(&status)
    } else {
        vec![]
    };

    // Count new commits by comparing HEAD before and after
    let post_head_cmd = commands::rev_parse_head_cmd();
    let post_head = exec_git_ok(&post_head_cmd, &req.path).await.unwrap_or_default();
    let fast_forward = stdout.contains("Fast-forward") || stdout.contains("fast-forward");

    // Rough commit count from log between old and new HEAD
    let new_commits = if pre_head.trim() != post_head.trim() && code == 0 {
        // Count commits between old and new HEAD
        let count_out = exec_simple(
            "git",
            &[
                "-C",
                &req.path,
                "rev-list",
                "--count",
                &format!("{}..{}", pre_head.trim(), post_head.trim()),
            ],
        )
        .await
        .and_then(|s| s.trim().parse::<u32>().ok())
        .unwrap_or(0);
        count_out
    } else {
        0
    };

    if code != 0 && !has_conflicts {
        return Err(git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("git pull failed (exit {})", code),
            Some(stderr),
        ));
    }

    Ok(Json(PullResult {
        new_commits,
        conflicts: conflict_files,
        fast_forward,
    }))
}

/// GET /git/log?path=...&count=20
async fn handle_log(
    axum::extract::Query(q): axum::extract::Query<LogQuery>,
) -> GitResult<Vec<impress_git::models::LogEntry>> {
    let cmd = commands::log_cmd(q.count);
    let stdout = exec_git_ok(&cmd, &q.path).await?;
    let entries = parse::parse_log(&stdout).map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to parse log: {}", e),
            None,
        )
    })?;
    Ok(Json(entries))
}

/// GET /git/diff?path=...&cached=false
async fn handle_diff(
    axum::extract::Query(q): axum::extract::Query<DiffQuery>,
) -> GitResult<String> {
    let cmd = commands::diff_cmd(q.cached);
    let stdout = exec_git_ok(&cmd, &q.path).await?;
    Ok(Json(stdout))
}

/// GET /git/diff/stat?path=...&cached=false
async fn handle_diff_stat(
    axum::extract::Query(q): axum::extract::Query<DiffQuery>,
) -> GitResult<impress_git::models::DiffSummary> {
    let cmd = commands::diff_stat_cmd(q.cached);
    let stdout = exec_git_ok(&cmd, &q.path).await?;
    let summary = parse::parse_diff_stat(&stdout).map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to parse diff stat: {}", e),
            None,
        )
    })?;
    Ok(Json(summary))
}

/// GET /git/branches?path=...
async fn handle_branches(
    axum::extract::Query(q): axum::extract::Query<PathQuery>,
) -> GitResult<Vec<impress_git::models::Branch>> {
    let cmd = commands::branch_list_cmd();
    let stdout = exec_git_ok(&cmd, &q.path).await?;
    let branches = parse::parse_branch_list(&stdout).map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to parse branches: {}", e),
            None,
        )
    })?;
    Ok(Json(branches))
}

/// POST /git/checkout
async fn handle_checkout(Json(req): Json<CheckoutRequest>) -> GitResult<serde_json::Value> {
    let cmd = commands::checkout_cmd(&req.branch);
    exec_git_ok(&cmd, &req.path).await?;
    Ok(Json(serde_json::json!({"ok": true, "branch": req.branch})))
}

/// POST /git/init
async fn handle_init(Json(req): Json<InitRequest>) -> GitResult<serde_json::Value> {
    // Ensure directory exists
    tokio::fs::create_dir_all(&req.path).await.map_err(|e| {
        git_err(
            StatusCode::BAD_REQUEST,
            format!("Failed to create directory: {}", e),
            None,
        )
    })?;

    let cmd = commands::init_cmd();
    exec_git_ok(&cmd, &req.path).await?;
    Ok(Json(serde_json::json!({"ok": true, "path": req.path})))
}

/// POST /git/remote/add
async fn handle_remote_add(Json(req): Json<RemoteAddRequest>) -> GitResult<serde_json::Value> {
    let cmd = commands::remote_add_cmd(&req.name, &req.url);
    exec_git_ok(&cmd, &req.path).await?;
    Ok(Json(serde_json::json!({"ok": true})))
}

/// GET /git/remotes?path=...
async fn handle_remotes(
    axum::extract::Query(q): axum::extract::Query<PathQuery>,
) -> GitResult<Vec<impress_git::models::RemoteInfo>> {
    let cmd = commands::remote_list_cmd();
    let stdout = exec_git_ok(&cmd, &q.path).await?;
    let remotes = parse::parse_remote_list(&stdout).map_err(|e| {
        git_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to parse remotes: {}", e),
            None,
        )
    })?;
    Ok(Json(remotes))
}

/// POST /git/create-repo — create a new git repo, optionally on GitHub via `gh`.
async fn handle_create_repo(Json(req): Json<CreateRepoRequest>) -> GitResult<CreateRepoResult> {
    // Ensure directory exists
    tokio::fs::create_dir_all(&req.path).await.map_err(|e| {
        git_err(
            StatusCode::BAD_REQUEST,
            format!("Failed to create directory: {}", e),
            None,
        )
    })?;

    // Write .gitignore
    let gitignore_path = std::path::Path::new(&req.path).join(".gitignore");
    if !gitignore_path.exists() {
        tokio::fs::write(&gitignore_path, impress_git::gitignore::latex_gitignore())
            .await
            .map_err(|e| {
                git_err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Failed to write .gitignore: {}", e),
                    None,
                )
            })?;
    }

    // Check if gh is available
    let gh_available = exec_simple("gh", &["--version"]).await.is_some();

    if gh_available {
        // Try gh repo create
        let init_cmd = commands::init_cmd();
        exec_git_ok(&init_cmd, &req.path).await?;

        // Stage and commit
        let add_cmd = commands::add_cmd(&["."]);
        exec_git_ok(&add_cmd, &req.path).await?;

        let commit_cmd = commands::commit_cmd("Initial commit from imprint", &[]);
        exec_git_ok(&commit_cmd, &req.path).await?;

        // Build gh command
        let mut gh_args = vec![
            "repo".to_string(),
            "create".to_string(),
        ];

        let repo_name = if let Some(ref org) = req.org {
            format!("{}/{}", org, req.name)
        } else {
            req.name.clone()
        };
        gh_args.push(repo_name);

        if req.private {
            gh_args.push("--private".into());
        } else {
            gh_args.push("--public".into());
        }

        if let Some(ref desc) = req.description {
            gh_args.push("--description".into());
            gh_args.push(desc.clone());
        }

        gh_args.push("--source".into());
        gh_args.push(req.path.clone());
        gh_args.push("--remote".into());
        gh_args.push("origin".into());
        gh_args.push("--push".into());

        let gh_arg_refs: Vec<&str> = gh_args.iter().map(|s| s.as_str()).collect();
        let gh_output = exec_simple("gh", &gh_arg_refs).await;

        let remote_url = gh_output.clone();

        // Get HEAD hash
        let head_cmd = commands::rev_parse_head_cmd();
        let head = exec_git_ok(&head_cmd, &req.path).await.unwrap_or_default();

        Ok(Json(CreateRepoResult {
            local_path: req.path,
            remote_url,
            initial_commit: Some(head.trim().to_string()),
            method: CreateMethod::GhCli,
        }))
    } else {
        // Fallback: git init only
        let init_cmd = commands::init_cmd();
        exec_git_ok(&init_cmd, &req.path).await?;

        let add_cmd = commands::add_cmd(&["."]);
        exec_git_ok(&add_cmd, &req.path).await?;

        let commit_cmd = commands::commit_cmd("Initial commit from imprint", &[]);
        exec_git_ok(&commit_cmd, &req.path).await?;

        let head_cmd = commands::rev_parse_head_cmd();
        let head = exec_git_ok(&head_cmd, &req.path).await.unwrap_or_default();

        Ok(Json(CreateRepoResult {
            local_path: req.path,
            remote_url: None,
            initial_commit: Some(head.trim().to_string()),
            method: CreateMethod::LocalInit,
        }))
    }
}
