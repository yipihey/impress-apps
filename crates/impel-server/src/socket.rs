//! Unix domain socket handler for local agents

use std::path::Path;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::AppState;

/// Start the Unix socket server
pub async fn serve_unix_socket(
    path: impl AsRef<Path>,
    state: Arc<AppState>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Remove existing socket file
    let path = path.as_ref();
    if path.exists() {
        std::fs::remove_file(path)?;
    }

    let listener = UnixListener::bind(path)?;
    tracing::info!("Unix socket listening on {:?}", path);

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    if let Err(e) = handle_unix_connection(stream, state).await {
                        tracing::error!("Unix socket connection error: {}", e);
                    }
                });
            }
            Err(e) => {
                tracing::error!("Unix socket accept error: {}", e);
            }
        }
    }
}

/// Handle a Unix socket connection
async fn handle_unix_connection(
    stream: UnixStream,
    state: Arc<AppState>,
) -> Result<(), Box<dyn std::error::Error>> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line = String::new();

    while reader.read_line(&mut line).await? > 0 {
        // Parse JSON-RPC style request
        if let Ok(request) = serde_json::from_str::<serde_json::Value>(&line) {
            let response = handle_request(&request, &state).await;
            let response_str = serde_json::to_string(&response)? + "\n";
            writer.write_all(response_str.as_bytes()).await?;
        }
        line.clear();
    }

    Ok(())
}

/// Handle a request from a Unix socket client
async fn handle_request(request: &serde_json::Value, state: &Arc<AppState>) -> serde_json::Value {
    let method = request.get("method").and_then(|m| m.as_str());
    let id = request
        .get("id")
        .cloned()
        .unwrap_or(serde_json::Value::Null);

    match method {
        Some("status") => {
            let coord = state.coordination.read().await;
            serde_json::json!({
                "id": id,
                "result": {
                    "paused": coord.is_paused(),
                    "sequence": coord.current_sequence()
                }
            })
        }
        Some("threads.available") => {
            let coord = state.coordination.read().await;
            let threads: Vec<_> = coord
                .available_threads()
                .map(|t| {
                    serde_json::json!({
                        "id": t.id.to_string(),
                        "title": t.metadata.title,
                        "temperature": t.temperature.value()
                    })
                })
                .collect();

            serde_json::json!({
                "id": id,
                "result": threads
            })
        }
        Some("events.since") => {
            let since = request
                .get("params")
                .and_then(|p| p.get("sequence"))
                .and_then(|s| s.as_u64())
                .unwrap_or(0);

            let coord = state.coordination.read().await;
            let events: Vec<_> = coord
                .events_since(since)
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "id": e.id.to_string(),
                        "sequence": e.sequence,
                        "entity_id": e.entity_id,
                        "description": e.payload.description()
                    })
                })
                .collect();

            serde_json::json!({
                "id": id,
                "result": events
            })
        }
        _ => {
            serde_json::json!({
                "id": id,
                "error": {
                    "code": -32601,
                    "message": "Method not found"
                }
            })
        }
    }
}
