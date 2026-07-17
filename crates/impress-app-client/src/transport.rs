//! Shared HTTP helpers: response-envelope decoding, error mapping, probe.

use crate::error::{AppClientError, Result};
use reqwest::Response;
use serde::de::DeserializeOwned;
use serde_json::Value;

/// Decode an `application/json` response from an imbib HTTP route.
///
/// imbib's HTTPAutomationRouter wraps every successful response in
/// `{"status":"ok", <data fields>...}` and errors in
/// `{"status":"error", "error":"..."}`. The data fields vary per
/// endpoint, so this helper takes the response, checks the status,
/// then deserializes the WHOLE body (including `status`) into `T`.
/// Callers define a per-endpoint response struct that captures the
/// keys they care about (and includes `pub status: String`).
pub(crate) async fn decode_envelope<T: DeserializeOwned>(resp: Response) -> Result<T> {
    let status = resp.status();
    let bytes = resp.bytes().await?;

    if status == reqwest::StatusCode::NOT_FOUND {
        let txt = String::from_utf8_lossy(&bytes).into_owned();
        return Err(AppClientError::NotFound(txt));
    }

    // Try to decode as the expected shape first.
    if let Ok(parsed) = serde_json::from_slice::<T>(&bytes) {
        return Ok(parsed);
    }

    // Fall through: try generic error envelope.
    if let Ok(err) = serde_json::from_slice::<Value>(&bytes) {
        if let Some(msg) = err.get("error").and_then(Value::as_str) {
            return Err(AppClientError::Api(msg.into()));
        }
        return Err(AppClientError::Api(err.to_string()));
    }

    Err(AppClientError::Decode(format!(
        "could not decode response (status {}): {}",
        status,
        String::from_utf8_lossy(&bytes)
    )))
}

/// For endpoints that return text (e.g. BibTeX export).
pub(crate) async fn decode_text(resp: Response) -> Result<String> {
    let status = resp.status();
    let body = resp.text().await?;
    if status == reqwest::StatusCode::NOT_FOUND {
        return Err(AppClientError::NotFound(body));
    }
    if !status.is_success() {
        return Err(AppClientError::ServerError(format!("{}: {}", status, body)));
    }
    Ok(body)
}

/// Server-info shape returned by `GET /api/status`.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ServerInfo {
    pub status: String,
    pub version: Option<String>,
    #[serde(rename = "libraryCount", default)]
    pub library_count: Option<u32>,
    #[serde(rename = "collectionCount", default)]
    pub collection_count: Option<u32>,
    #[serde(rename = "serverPort", default)]
    pub server_port: Option<u16>,
}
