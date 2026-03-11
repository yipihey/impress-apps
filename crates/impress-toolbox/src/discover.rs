use std::collections::HashMap;
use std::path::Path;

use axum::http::StatusCode;
use axum::Json;

use crate::types::{DiscoverRequest, DiscoverResponse};

/// POST /discover — find executables on disk.
pub async fn handle_discover(
    Json(req): Json<DiscoverRequest>,
) -> Result<Json<DiscoverResponse>, (StatusCode, String)> {
    let mut found = HashMap::new();
    let mut not_found = Vec::new();

    // Default search paths if none provided
    let search_paths = if req.search_paths.is_empty() {
        default_search_paths()
    } else {
        req.search_paths.clone()
    };

    for name in &req.names {
        let mut located = false;
        for dir in &search_paths {
            let full_path = Path::new(dir).join(name);
            if full_path.exists() && is_executable(&full_path) {
                tracing::debug!(name, path = %full_path.display(), "Found executable");
                found.insert(name.clone(), full_path.to_string_lossy().to_string());
                located = true;
                break;
            }
        }
        if !located {
            tracing::debug!(name, "Executable not found in any search path");
            not_found.push(name.clone());
        }
    }

    Ok(Json(DiscoverResponse { found, not_found }))
}

/// Check if a path is executable (Unix permissions).
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Default search paths for macOS.
fn default_search_paths() -> Vec<String> {
    let mut paths = vec![
        "/Library/TeX/texbin".to_string(),
        "/usr/local/texlive/2025/bin/universal-darwin".to_string(),
        "/usr/local/texlive/2024/bin/universal-darwin".to_string(),
        "/opt/homebrew/bin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/bin".to_string(),
        "/bin".to_string(),
    ];

    // Also check ~/.local/bin
    if let Some(home) = dirs::home_dir() {
        paths.insert(0, home.join(".local/bin").to_string_lossy().to_string());
    }

    paths
}
