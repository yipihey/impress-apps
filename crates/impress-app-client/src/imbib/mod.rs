//! HTTP client for the imbib macOS app's automation API (default port 23120).

use std::sync::Mutex;
use std::time::Duration;

use reqwest::Client;
use url::Url;
use uuid::Uuid;

use crate::error::{AppClientError, Result};
use crate::transport::{decode_envelope, ServerInfo};

mod annotations;
mod artifacts;
mod libraries;
mod scix;
mod search;
mod tags;
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

    /// Build with an explicit base URL (no trailing path).
    pub fn with_base_url(base_url: Url) -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest client builds");
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
