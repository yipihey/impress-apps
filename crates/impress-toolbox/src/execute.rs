use std::path::Path;
use std::time::Instant;

use axum::body::Body;
use axum::http::{Response, StatusCode};
use axum::Json;
use tokio::process::Command;

use crate::types::{ExecuteFileRequest, ExecuteRequest, ExecuteResponse};

const DEFAULT_TIMEOUT_MS: u64 = 60_000;
const MAX_TIMEOUT_MS: u64 = 300_000;

/// POST /execute — run a process and return stdout/stderr.
pub async fn handle_execute(
    Json(req): Json<ExecuteRequest>,
) -> Result<Json<ExecuteResponse>, (StatusCode, String)> {
    let result = run_process(&req).await?;
    Ok(Json(result))
}

/// POST /execute/file — run a process and return an output file as binary.
pub async fn handle_execute_file(
    Json(req): Json<ExecuteFileRequest>,
) -> Result<Response<Body>, (StatusCode, String)> {
    let result = run_process(&req.execute).await?;

    // If the process failed, return the result as JSON so the caller sees errors
    if result.exit_code != 0 {
        let json = serde_json::to_vec(&result).unwrap_or_default();
        return Ok(Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "application/json")
            .header("x-toolbox-exit-code", result.exit_code.to_string())
            .header("x-toolbox-duration-ms", result.duration_ms.to_string())
            .body(Body::from(json))
            .unwrap());
    }

    // Read the output file
    let output_path = Path::new(&req.output_file);
    let file_data = tokio::fs::read(output_path).await.map_err(|e| {
        (
            StatusCode::NOT_FOUND,
            format!("Output file not found: {} — {}", req.output_file, e),
        )
    })?;

    Ok(Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/octet-stream")
        .header("x-toolbox-exit-code", result.exit_code.to_string())
        .header("x-toolbox-duration-ms", result.duration_ms.to_string())
        .header(
            "x-toolbox-stdout-length",
            result.stdout.len().to_string(),
        )
        .body(Body::from(file_data))
        .unwrap())
}

/// Run a process with timeout, returning structured result.
async fn run_process(req: &ExecuteRequest) -> Result<ExecuteResponse, (StatusCode, String)> {
    // Validate executable exists
    let exec_path = Path::new(&req.executable);
    if !exec_path.exists() {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("Executable not found: {}", req.executable),
        ));
    }

    // Validate working directory if specified
    if let Some(ref wd) = req.working_directory {
        let wd_path = Path::new(wd);
        if !wd_path.is_dir() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Working directory does not exist: {}", wd),
            ));
        }
    }

    let timeout_ms = req
        .timeout_ms
        .unwrap_or(DEFAULT_TIMEOUT_MS)
        .min(MAX_TIMEOUT_MS);

    let mut cmd = Command::new(&req.executable);
    cmd.args(&req.arguments);

    if let Some(ref wd) = req.working_directory {
        cmd.current_dir(wd);
    }

    // Set environment: start with current env, overlay request env
    cmd.envs(&req.environment);

    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    let start = Instant::now();

    let mut child = cmd.spawn().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to spawn process: {}", e),
        )
    })?;

    let pid = child.id();
    tracing::info!(
        executable = %req.executable,
        args = ?req.arguments,
        "Spawned process (pid={:?}, timeout={}ms)",
        pid,
        timeout_ms
    );

    // Read stdout/stderr via take() so we can still kill the child on timeout
    let stdout_pipe = child.stdout.take();
    let stderr_pipe = child.stderr.take();

    let read_output = async {
        let stdout_handle = tokio::spawn(async move {
            if let Some(mut pipe) = stdout_pipe {
                let mut buf = Vec::new();
                tokio::io::AsyncReadExt::read_to_end(&mut pipe, &mut buf).await.unwrap_or(0);
                buf
            } else {
                Vec::new()
            }
        });

        let stderr_handle = tokio::spawn(async move {
            if let Some(mut pipe) = stderr_pipe {
                let mut buf = Vec::new();
                tokio::io::AsyncReadExt::read_to_end(&mut pipe, &mut buf).await.unwrap_or(0);
                buf
            } else {
                Vec::new()
            }
        });

        let status = child.wait().await;
        let stdout_data = stdout_handle.await.unwrap_or_default();
        let stderr_data = stderr_handle.await.unwrap_or_default();
        (status, stdout_data, stderr_data)
    };

    // Wait with timeout
    let result = tokio::time::timeout(
        std::time::Duration::from_millis(timeout_ms),
        read_output,
    )
    .await;

    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok((Ok(status), stdout_data, stderr_data)) => {
            let stdout = String::from_utf8_lossy(&stdout_data).to_string();
            let stderr = String::from_utf8_lossy(&stderr_data).to_string();
            let exit_code = status.code().unwrap_or(-1);

            tracing::info!(
                executable = %req.executable,
                exit_code,
                duration_ms,
                stdout_len = stdout.len(),
                stderr_len = stderr.len(),
                "Process completed"
            );

            Ok(ExecuteResponse {
                id: req.id.clone(),
                exit_code,
                stdout,
                stderr,
                duration_ms,
                timed_out: false,
            })
        }
        Ok((Err(e), _, _)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Process I/O error: {}", e),
        )),
        Err(_) => {
            // Timeout — kill via PID since child was moved into the future
            if let Some(pid) = pid {
                // Use nix-less kill via std::process::Command
                let _ = std::process::Command::new("kill")
                    .args(["-9", &pid.to_string()])
                    .output();
            }
            tracing::warn!(
                executable = %req.executable,
                timeout_ms,
                "Process timed out, killed"
            );

            Ok(ExecuteResponse {
                id: req.id.clone(),
                exit_code: -1,
                stdout: String::new(),
                stderr: format!("Process timed out after {}ms", timeout_ms),
                duration_ms,
                timed_out: true,
            })
        }
    }
}
