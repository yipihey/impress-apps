use serde::{Deserialize, Serialize};

/// POST /git/clone
#[derive(Debug, Deserialize)]
pub struct CloneRequest {
    pub url: String,
    pub target_path: String,
    pub branch: Option<String>,
}

/// GET /git/status?path=...
#[derive(Debug, Deserialize)]
pub struct PathQuery {
    pub path: String,
}

/// POST /git/commit
#[derive(Debug, Deserialize)]
pub struct CommitRequest {
    pub path: String,
    pub message: String,
    #[serde(default)]
    pub files: Vec<String>,
}

/// POST /git/push
#[derive(Debug, Deserialize)]
pub struct PushRequest {
    pub path: String,
    pub remote: Option<String>,
    pub branch: Option<String>,
}

/// POST /git/pull
#[derive(Debug, Deserialize)]
pub struct PullRequest {
    pub path: String,
    pub remote: Option<String>,
    pub branch: Option<String>,
    #[serde(default)]
    pub rebase: bool,
}

/// GET /git/log?path=...&count=20
#[derive(Debug, Deserialize)]
pub struct LogQuery {
    pub path: String,
    #[serde(default = "default_log_count")]
    pub count: u32,
}

fn default_log_count() -> u32 {
    20
}

/// GET /git/diff?path=...&cached=false
#[derive(Debug, Deserialize)]
pub struct DiffQuery {
    pub path: String,
    #[serde(default)]
    pub cached: bool,
}

/// POST /git/checkout
#[derive(Debug, Deserialize)]
pub struct CheckoutRequest {
    pub path: String,
    pub branch: String,
}

/// POST /git/init
#[derive(Debug, Deserialize)]
pub struct InitRequest {
    pub path: String,
}

/// POST /git/remote/add
#[derive(Debug, Deserialize)]
pub struct RemoteAddRequest {
    pub path: String,
    pub name: String,
    pub url: String,
}

/// POST /git/create-repo
#[derive(Debug, Deserialize)]
pub struct CreateRepoRequest {
    pub path: String,
    pub name: String,
    pub description: Option<String>,
    #[serde(default = "default_true")]
    pub private: bool,
    pub org: Option<String>,
}

fn default_true() -> bool {
    true
}

/// POST /git/add
#[derive(Debug, Deserialize)]
pub struct AddRequest {
    pub path: String,
    pub files: Vec<String>,
}

/// Generic error response.
#[derive(Debug, Serialize)]
pub struct GitError {
    pub error: String,
    pub stderr: Option<String>,
}
