use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Request to execute a process.
#[derive(Debug, Deserialize)]
pub struct ExecuteRequest {
    /// Optional request ID for correlation.
    pub id: Option<String>,
    /// Full path to the executable.
    pub executable: String,
    /// Command-line arguments.
    #[serde(default)]
    pub arguments: Vec<String>,
    /// Working directory for the process.
    pub working_directory: Option<String>,
    /// Environment variables (merged with defaults).
    #[serde(default)]
    pub environment: HashMap<String, String>,
    /// Timeout in milliseconds (default 60000, max 300000).
    pub timeout_ms: Option<u64>,
}

/// Request to execute a process and return an output file.
#[derive(Debug, Deserialize)]
pub struct ExecuteFileRequest {
    /// The execution parameters.
    #[serde(flatten)]
    pub execute: ExecuteRequest,
    /// Path to the output file to return after execution.
    pub output_file: String,
}

/// Response from process execution.
#[derive(Debug, Serialize)]
pub struct ExecuteResponse {
    /// Echoed request ID.
    pub id: Option<String>,
    /// Process exit code.
    pub exit_code: i32,
    /// Captured stdout.
    pub stdout: String,
    /// Captured stderr.
    pub stderr: String,
    /// Wall-clock duration in milliseconds.
    pub duration_ms: u64,
    /// Whether the process was killed due to timeout.
    pub timed_out: bool,
}

/// Request to discover executables.
#[derive(Debug, Deserialize)]
pub struct DiscoverRequest {
    /// Executable names to search for.
    pub names: Vec<String>,
    /// Directories to search in.
    #[serde(default)]
    pub search_paths: Vec<String>,
}

/// Response from executable discovery.
#[derive(Debug, Serialize)]
pub struct DiscoverResponse {
    /// Map of name -> full path for found executables.
    pub found: HashMap<String, String>,
    /// Names that were not found.
    pub not_found: Vec<String>,
}

/// Status response.
#[derive(Debug, Serialize)]
pub struct StatusResponse {
    pub status: String,
    pub version: String,
    pub pid: u32,
}
