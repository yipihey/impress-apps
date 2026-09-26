//! HTTP client for the imbib macOS app's automation API (default port 23120).

use std::sync::Mutex;
use std::time::Duration;

use reqwest::Client;
use url::Url;
use uuid::Uuid;

use crate::error::{AppClientError, Result};
use crate::transport::{decode_envelope, ServerInfo};

mod annotations;
mod app;
mod artifacts;
mod libraries;
mod manuscripts;
mod scix;
mod search;
mod tags;
mod tail;
mod undo;

const DEFAULT_BASE_URL: &str = "http://localhost:23120";

/// Typed client for imbib's `localhost:23120` HTTP API.
///
/// Construct with [`ImbibClient::new`] (default base URL) or
/// [`ImbibClient::with_base_url`]. Use [`probe`](Self::probe) at
/// startup to confirm the app is running before issuing real calls.
pub struct ImbibClient {
    pub(crate) base_url: Url,
    pub(crate) http: Client,
    /// Tiny LRU for UUID→cite-key translation. imbib's HTTP API
    /// generally identifies papers by cite-key in URLs while our
    /// service trait uses UUID; this cache avoids hammering the lookup
    /// endpoint on hot paths.
    pub(crate) cite_key_cache: Mutex<Vec<(Uuid, String)>>,
}

impl ImbibClient {
    /// Build with the default `http://localhost:23120` base URL.
    pub fn new() -> Self {
        Self::with_base_url(Url::parse(DEFAULT_BASE_URL).expect("default URL parses"))
    }

    /// Build with an explicit base URL (no trailing path). The bearer is the
    /// suite-wide one (`crate::loopback_http_client_for`): `IMPRESS_APP_TOKEN`,
    /// else imbib's per-launch loopback token file. The old `IMBIB_TOKEN`
    /// variable is gone — one client, one variable.
    pub fn with_base_url(base_url: Url) -> Self {
        let http = crate::loopback_http_client_for(
            &base_url,
            Client::builder().timeout(Duration::from_secs(30)),
        );
        Self::with_http(base_url, http)
    }

    /// Client with an explicit bearer token attached to every request — for
    /// a caller that already holds one (a remote client across a tailnet
    /// with the network bearer from Settings > Automation, or a test).
    pub fn with_base_url_and_token(base_url: Url, token: Option<String>) -> Self {
        let mut builder = Client::builder().timeout(Duration::from_secs(30));
        if let Some(token) = token.filter(|t| !t.is_empty()) {
            builder = crate::with_bearer(builder, &token);
        }
        let http = crate::loopback_http_client(builder);
        Self::with_http(base_url, http)
    }

    fn with_http(base_url: Url, http: Client) -> Self {
        Self {
            base_url,
            http,
            cite_key_cache: Mutex::new(Vec::with_capacity(64)),
        }
    }

    /// Hit `GET /api/status` with a short timeout. Returns `Some(info)`
    /// when reachable, `None` when unreachable / timed out. Errors at
    /// the API layer (e.g. server up but auth-disabled) bubble up.
    pub async fn probe(&self) -> Option<ServerInfo> {
        let url = self.base_url.join("/api/status").ok()?;
        let resp = self
            .http
            .get(url)
            .timeout(Duration::from_secs(1))
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.json::<ServerInfo>().await.ok()
    }

    /// Resolve a publication UUID to its cite-key by calling
    /// `GET /api/items/{uuid}` (route added by the Phase D Swift work).
    /// Cached in a small LRU.
    pub(crate) async fn resolve_cite_key(&self, id: &str) -> Result<String> {
        // Try cache.
        if let Ok(uuid) = Uuid::parse_str(id) {
            if let Ok(cache) = self.cite_key_cache.lock() {
                if let Some((_, ck)) = cache.iter().find(|(u, _)| *u == uuid) {
                    return Ok(ck.clone());
                }
            }
            // Miss — fetch.
            let url = self.base_url.join(&format!("/api/items/{}", uuid))?;
            let resp = self.http.get(url).send().await?;

            #[derive(serde::Deserialize)]
            struct ItemResp {
                status: String,
                #[serde(default, rename = "citeKey")]
                cite_key_camel: Option<String>,
                #[serde(default)]
                cite_key: Option<String>,
            }
            let parsed: ItemResp = decode_envelope(resp).await?;
            if parsed.status != "ok" {
                return Err(AppClientError::Api(parsed.status));
            }
            let ck = parsed
                .cite_key
                .or(parsed.cite_key_camel)
                .ok_or_else(|| AppClientError::UnresolvedUuid(id.into()))?;

            // Stash in cache (cap at 64; evict oldest).
            if let Ok(mut cache) = self.cite_key_cache.lock() {
                cache.push((uuid, ck.clone()));
                if cache.len() > 64 {
                    cache.remove(0);
                }
            }
            return Ok(ck);
        }

        // Not a UUID — assume it's already a cite-key.
        Ok(id.to_string())
    }
}

impl Default for ImbibClient {
    fn default() -> Self {
        Self::new()
    }
}
