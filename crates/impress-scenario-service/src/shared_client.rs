//! The shared Tier B loopback client (docs/plan-self-reflective-layer.md §
//! Scenarios: "the layout Tier B `Http` helper lifted into
//! `impress-scenario-service` as the one client, with the loopback token
//! from `impress_core::loopback_token`").
//!
//! Lifted from `impress-layout-service/src/tier_b.rs`'s private `Http`
//! (same header comment explains why raw `reqwest` rather than
//! `impress-app-client`'s typed, domain-specific clients: this crate is
//! kit-adjacent and taking on two whole domain stacks to make a handful of
//! loopback requests is the trade that crate's own header refuses). Once
//! H-P5-1 (`POST /api/verb/<name>`, P5) lands, [`LoopbackClient::call`]
//! grows a generic path and the per-service dispatch below shrinks to a
//! fallback for apps that predate it.

use std::time::Duration;

use serde_json::Value;

/// A loopback JSON client over one app's automation surface.
pub struct LoopbackClient {
    client: reqwest::Client,
    base: String,
}

impl LoopbackClient {
    pub fn new(base: &str) -> Self {
        // `no_proxy`: every request here goes to 127.0.0.1 (see the header
        // comment in `impress-layout-service`'s copy, which exists because
        // asking macOS for the proxy config from a sandboxed process can
        // abort). The app bearer (P0, SEC-2) comes from the per-launch
        // loopback token file, or `IMPRESS_APP_TOKEN`.
        let mut builder = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(10));
        if let Some(token) = impress_core::loopback_token::client_token_for_url(base) {
            let mut headers = reqwest::header::HeaderMap::new();
            if let Ok(mut value) =
                reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))
            {
                value.set_sensitive(true);
                headers.insert(reqwest::header::AUTHORIZATION, value);
                builder = builder.default_headers(headers);
            }
        }
        let client = builder.build().unwrap_or_else(|_| reqwest::Client::new());
        Self {
            client,
            base: base.trim_end_matches('/').to_string(),
        }
    }

    pub async fn get(&self, path: &str) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("GET {path}: {e}"))?;
        read(path, response).await
    }

    pub async fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .post(&url)
            .json(body)
            .send()
            .await
            .map_err(|e| format!("POST {path}: {e}"))?;
        read(path, response).await
    }

    pub async fn delete(&self, path: &str) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .delete(&url)
            .send()
            .await
            .map_err(|e| format!("DELETE {path}: {e}"))?;
        read(path, response).await
    }
}

/// The status and JSON body of one response — the caller decides whether a
/// non-2xx or an `{"ok": false}` envelope is a step failure (a scenario may
/// deliberately expect a refusal), unlike the layout catalogue's own
/// `decode`, which always treats it as an error.
async fn read(path: &str, response: reqwest::Response) -> Result<(u16, Value), String> {
    let status = response.status().as_u16();
    let text = response
        .text()
        .await
        .map_err(|e| format!("{path}: reading body: {e}"))?;
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| format!("{path}: HTTP {status}, body is not JSON ({e}): {text}"))?;
    Ok((status, value))
}
