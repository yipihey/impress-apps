//! HTTP-backed `ImploreService`, routing to the running implore app.
//!
//! Mirrors `imbib-service-http` and `imprint-service-http`: probe the app's
//! automation port, install the backend if it answers, otherwise leave the
//! refusing default in place. Nothing here silently falls back to a local
//! substitute, because there is no local substitute — implore's datasets and
//! figures only exist in the app.

use std::sync::Arc;
use std::time::Duration;

use implore_service::{
    register_backend, AppStatus, DatasetRecord, FigureRecord, ImploreBackend, ImploreService,
    LogEntry,
};
use serde::Deserialize;
use serde_json::{json, Value};
use url::Url;

// implore's automation port. Authority: `SiblingApp.descriptors` in
// packages/ImpressKit (implore = 23123). This said 23124 — impel's port — for
// as long as implore's own server bound 23124 too; both were aligned to the
// table on 2026-07-30 (hardening C3).
const DEFAULT_BASE_URL: &str = "http://localhost:23123";

fn log_err(method: &str, e: impl std::fmt::Display) {
    eprintln!("[implore-service-http] {method}: {e}");
}

pub struct ImploreClient {
    base_url: Url,
    http: reqwest::Client,
}

impl ImploreClient {
    pub fn new() -> Self {
        Self::with_base_url(Url::parse(DEFAULT_BASE_URL).expect("default URL parses"))
    }

    pub fn with_base_url(base_url: Url) -> Self {
        // no_proxy + no panic: see impress_app_client::loopback_http_client.
        let http = impress_app_client::loopback_http_client(
            reqwest::Client::builder().timeout(Duration::from_secs(30)),
        );
        Self { base_url, http }
    }

    async fn get_text(&self, path: &str) -> Result<String, String> {
        let url = self.base_url.join(path).map_err(|e| e.to_string())?;
        self.http
            .get(url)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())
    }

    async fn get_json(&self, path: &str) -> Result<Value, String> {
        let text = self.get_text(path).await?;
        serde_json::from_str(&text).map_err(|e| e.to_string())
    }

    async fn post_json(&self, path: &str, body: Value) -> Result<Value, String> {
        let url = self.base_url.join(path).map_err(|e| e.to_string())?;
        let text = self
            .http
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())?;
        serde_json::from_str(&text).map_err(|e| e.to_string())
    }

    /// Raw JSON as a string, for the `rg_*` passthroughs.
    async fn raw(&self, method: &str, path: &str, body: Option<Value>) -> String {
        let result = match body {
            Some(b) => self.post_json(path, b).await,
            None => self.get_json(path).await,
        };
        match result {
            Ok(v) => v.to_string(),
            Err(e) => {
                log_err(method, &e);
                json!({ "error": e }).to_string()
            }
        }
    }
}

impl Default for ImploreClient {
    fn default() -> Self {
        Self::new()
    }
}

/// Pull a named array out of a `{status, <key>: [...]}` envelope.
fn array_field<T: for<'de> Deserialize<'de>>(v: &Value, keys: &[&str]) -> Vec<T> {
    for key in keys {
        if let Some(arr) = v.get(key) {
            if let Ok(parsed) = serde_json::from_value::<Vec<T>>(arr.clone()) {
                return parsed;
            }
        }
    }
    Vec::new()
}

fn object_field<T: for<'de> Deserialize<'de>>(v: &Value, keys: &[&str]) -> Option<T> {
    for key in keys {
        if let Some(obj) = v.get(key) {
            if let Ok(parsed) = serde_json::from_value::<T>(obj.clone()) {
                return Some(parsed);
            }
        }
    }
    None
}

pub struct HttpImploreService {
    client: Arc<ImploreClient>,
}

impl HttpImploreService {
    pub fn new(client: Arc<ImploreClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImploreService for HttpImploreService {
    async fn status(&self) -> AppStatus {
        match self.client.get_text("/api/status").await {
            Ok(detail) => AppStatus {
                running: true,
                detail,
            },
            Err(e) => {
                log_err("status", &e);
                AppStatus {
                    running: false,
                    detail: format!("implore did not answer: {e}"),
                }
            }
        }
    }

    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry> {
        let mut path = format!("/api/logs?limit={}", if limit == 0 { 50 } else { limit });
        if let Some(l) = level.as_deref().filter(|l| !l.is_empty()) {
            path.push_str(&format!("&level={}", urlencoding::encode(l)));
        }
        match self.client.get_json(&path).await {
            // Same nested envelope as imbib and imprint: {status, data:{entries}}.
            Ok(v) => {
                let nested = v.get("data").map(|d| array_field(d, &["entries"]));
                match nested {
                    Some(e) if !e.is_empty() => e,
                    _ => array_field(&v, &["entries", "logs"]),
                }
            }
            Err(e) => {
                log_err("get_logs", e);
                vec![]
            }
        }
    }

    async fn list_datasets(&self) -> Vec<DatasetRecord> {
        match self.client.get_json("/api/datasets").await {
            Ok(v) => array_field(&v, &["datasets"]),
            Err(e) => {
                log_err("list_datasets", e);
                vec![]
            }
        }
    }

    async fn get_dataset(&self, dataset_id: String) -> Option<DatasetRecord> {
        let path = format!("/api/datasets/{}", urlencoding::encode(&dataset_id));
        match self.client.get_json(&path).await {
            Ok(v) => object_field(&v, &["dataset"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("get_dataset", e);
                None
            }
        }
    }

    async fn list_figures(&self, dataset_id: Option<String>) -> Vec<FigureRecord> {
        let path = match dataset_id.as_deref().filter(|d| !d.is_empty()) {
            Some(d) => format!("/api/figures?datasetId={}", urlencoding::encode(d)),
            None => "/api/figures".to_string(),
        };
        match self.client.get_json(&path).await {
            Ok(v) => array_field(&v, &["figures"]),
            Err(e) => {
                log_err("list_figures", e);
                vec![]
            }
        }
    }

    async fn get_figure(&self, figure_id: String) -> Option<FigureRecord> {
        let path = format!("/api/figures/{}", urlencoding::encode(&figure_id));
        match self.client.get_json(&path).await {
            Ok(v) => object_field(&v, &["figure"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("get_figure", e);
                None
            }
        }
    }

    async fn create_figure(
        &self,
        dataset_id: String,
        plot_type: String,
        x: String,
        y: Option<String>,
        name: Option<String>,
    ) -> Option<FigureRecord> {
        let body = json!({
            "datasetId": dataset_id,
            "plotType": plot_type,
            "x": x,
            "y": y,
            "name": name,
        });
        match self.client.post_json("/api/figures", body).await {
            Ok(v) => object_field(&v, &["figure"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("create_figure", e);
                None
            }
        }
    }

    async fn export_figure(&self, figure_id: String, format: String) -> Option<String> {
        let path = format!("/api/figures/{}/export", urlencoding::encode(&figure_id));
        match self
            .client
            .post_json(&path, json!({ "format": format }))
            .await
        {
            Ok(v) => v
                .get("path")
                .and_then(|p| p.as_str())
                .map(|s| s.to_string()),
            Err(e) => {
                log_err("export_figure", e);
                None
            }
        }
    }

    async fn plot_series(&self, series: Vec<String>, title: Option<String>) -> Option<String> {
        let body = json!({ "series": series, "title": title });
        match self.client.post_json("/api/plot/svg", body).await {
            Ok(v) => v.get("svg").and_then(|s| s.as_str()).map(|s| s.to_string()),
            Err(e) => {
                log_err("plot_series", e);
                None
            }
        }
    }

    async fn plot_histogram(&self, quantity: Option<String>, bins: Option<u32>) -> Option<String> {
        let body = json!({ "quantity": quantity, "bins": bins });
        match self.client.post_json("/api/plot/histogram", body).await {
            Ok(v) => v.get("svg").and_then(|s| s.as_str()).map(|s| s.to_string()),
            Err(e) => {
                log_err("plot_histogram", e);
                None
            }
        }
    }

    // ---- Ray-grid passthroughs --------------------------------------------

    async fn rg_load(&self, path: String) -> String {
        self.client
            .raw("rg_load", "/api/rg/load", Some(json!({ "path": path })))
            .await
    }
    async fn rg_state(&self) -> String {
        self.client.raw("rg_state", "/api/rg/state", None).await
    }
    async fn rg_control(&self, params_json: String) -> String {
        let body = serde_json::from_str(&params_json).unwrap_or(json!({}));
        self.client
            .raw("rg_control", "/api/rg/control", Some(body))
            .await
    }
    async fn rg_slice_png(&self, format: Option<String>) -> String {
        self.client
            .raw(
                "rg_slice_png",
                "/api/rg/slice/png",
                Some(json!({ "format": format })),
            )
            .await
    }
    async fn rg_slice_save(&self, path: String) -> String {
        self.client
            .raw(
                "rg_slice_save",
                "/api/rg/slice/save",
                Some(json!({ "path": path })),
            )
            .await
    }
    async fn rg_slice_raw(&self, params_json: Option<String>) -> String {
        let body = params_json
            .and_then(|p| serde_json::from_str(&p).ok())
            .unwrap_or(json!({}));
        self.client
            .raw("rg_slice_raw", "/api/rg/slice/raw", Some(body))
            .await
    }
    async fn rg_statistics(&self, params_json: Option<String>) -> String {
        let body = params_json
            .and_then(|p| serde_json::from_str(&p).ok())
            .unwrap_or(json!({}));
        self.client
            .raw("rg_statistics", "/api/rg/statistics", Some(body))
            .await
    }
    async fn rg_batch(&self, params_json: String) -> String {
        let body = serde_json::from_str(&params_json).unwrap_or(json!({}));
        self.client
            .raw("rg_batch", "/api/rg/batch", Some(body))
            .await
    }
    async fn rg_colormaps(&self) -> String {
        self.client
            .raw("rg_colormaps", "/api/rg/colormaps", None)
            .await
    }
    async fn rg_cascade_plot(&self) -> String {
        self.client
            .raw("rg_cascade_plot", "/api/rg/cascade_plot", None)
            .await
    }
}

pub struct HttpBackend {
    client: Arc<ImploreClient>,
}

impl HttpBackend {
    pub fn new(client: Arc<ImploreClient>) -> Self {
        Self { client }
    }
}

impl ImploreBackend for HttpBackend {
    fn service(&self) -> Arc<dyn ImploreService> {
        Arc::new(HttpImploreService::new(self.client.clone()))
    }
}

/// Probe implore and install the HTTP backend if it answers.
///
/// `IMPLORE_HTTP_URL` overrides the default port. `IMPLORE_BACKEND=off` skips
/// the probe entirely, for tests that must not touch the network.
pub fn maybe_install_http_backend() -> bool {
    if std::env::var("IMPLORE_BACKEND").as_deref() == Ok("off") {
        eprintln!("[implore-service-http] IMPLORE_BACKEND=off — skipping probe");
        return false;
    }

    let base_url = std::env::var("IMPLORE_HTTP_URL")
        .ok()
        .and_then(|s| Url::parse(&s).ok())
        .unwrap_or_else(|| Url::parse(DEFAULT_BASE_URL).expect("default URL parses"));

    let client = Arc::new(ImploreClient::with_base_url(base_url));
    let reachable =
        impress_service_runtime_block_on(async { client.get_text("/api/status").await.is_ok() });

    if reachable {
        eprintln!("[implore-service-http] implore reachable; using HTTP backend");
        register_backend(Box::new(HttpBackend::new(client)));
        true
    } else {
        eprintln!("[implore-service-http] implore unreachable; tools will refuse");
        false
    }
}

/// Run a future to completion on a private runtime.
///
/// `impress-service-core`'s helper is not a dependency here — this crate has
/// one blocking call at startup and does not need the whole service runtime.
fn impress_service_runtime_block_on<F: std::future::Future>(fut: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("current-thread runtime builds")
        .block_on(fut)
}
