//! HTTP-backed `ImploreService`, routing to the running implore app.
//!
//! Mirrors `imbib-service-http` and `imprint-service-http`: probe the app's
//! automation port, install the backend if it answers, otherwise leave the
//! refusing default in place. Nothing here silently falls back to a local
//! substitute, because there is no local substitute — implore's datasets and
//! figures only exist in the app.

use std::sync::Arc;
use std::time::Duration;

use implore_core::figure_artifact::FigureData;
use implore_service::{
    register_backend, validate_figure_data, AppStatus, CreateFigureOutcome, DatasetRecord,
    FigureArtifactInfo, FigureRecord, FigureSeriesArg, ImploreBackend, ImploreService, LogEntry,
    PlotSpecArg,
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

/// The `POST /api/figures` body for `create-figure`. `plotType`/`x`/`y` are
/// the spellings the router reads besides its own `type`/`xColumn`/`yColumn`;
/// the one data key (`series`, `spec` or `svg`) is the name the router's
/// `copyArtifactData` copies into the view state `figure_artifact` renders.
fn create_figure_body(
    dataset_id: String,
    plot_type: String,
    x: String,
    y: Option<String>,
    name: Option<String>,
    data: Option<FigureData>,
) -> Value {
    let mut body = json!({
        "datasetId": dataset_id,
        "plotType": plot_type,
        "x": x,
        "y": y,
        "name": name,
    });
    if let Some(d) = data {
        let key = d.key();
        body[key] = d.into_json();
    }
    body
}

/// Read implore's answer: `{status: "ok", figure, artifact}` on 201, or
/// `{status: "error", error}` (a 400 names why the figure could not be
/// rendered, and nothing was stored).
fn create_figure_outcome(v: &Value, drawn_from: &str) -> CreateFigureOutcome {
    match object_field::<FigureRecord>(v, &["figure"]) {
        Some(figure) => CreateFigureOutcome {
            ok: true,
            error: None,
            figure: Some(figure),
            artifact: object_field::<FigureArtifactInfo>(v, &["artifact"]),
            drawn_from: Some(drawn_from.to_string()),
        },
        None => {
            let why = v
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| format!("implore answered without a figure: {v}"));
            log_err("create_figure", &why);
            CreateFigureOutcome::refused(why)
        }
    }
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
        series: Option<FigureSeriesArg>,
        spec: Option<PlotSpecArg>,
        svg: Option<String>,
    ) -> CreateFigureOutcome {
        let data = match validate_figure_data(series.as_ref(), spec.as_ref(), svg.as_deref()) {
            Ok(d) => d,
            Err(e) => {
                log_err("create_figure", &e);
                return CreateFigureOutcome::refused(e);
            }
        };
        let body = create_figure_body(dataset_id, plot_type, x, y, name, data);
        let drawn_from = ["series", "spec", "svg"]
            .into_iter()
            .find(|k| body.get(*k).is_some())
            .unwrap_or("none");
        match self.client.post_json("/api/figures", body).await {
            Ok(v) => create_figure_outcome(&v, drawn_from),
            Err(e) => {
                log_err("create_figure", &e);
                CreateFigureOutcome::refused(format!("implore did not answer: {e}"))
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
        implore_service::clear_backend();
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
        // Release a backend an earlier probe installed: implore has quit, and
        // a refusal names that, where a dead HTTP client just times out.
        implore_service::clear_backend();
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

#[cfg(test)]
mod tests {
    //! Pass-through: what `create-figure` sends is what implore's router
    //! reads, and what the router builds from it renders to the real plot.
    //! A one-request mock stands in for implore; the render is
    //! `implore_core::figure_artifact` itself, the one renderer.

    use super::*;
    use implore_core::figure_artifact::{render_figure, FigureViewState, RASTER_SCALE};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Serve one request with `status`/`reply`; return the base URL and a
    /// handle yielding the request body (None if no request arrived).
    async fn mock_implore(
        status: u16,
        reply: Value,
    ) -> (Url, tokio::task::JoinHandle<Option<Value>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let handle = tokio::spawn(async move {
            let accept = tokio::time::timeout(Duration::from_millis(1500), listener.accept()).await;
            let (mut sock, _) = accept.ok()?.ok()?;
            let mut buf = Vec::new();
            let mut chunk = [0u8; 65536];
            let body_start;
            let content_length;
            loop {
                let n = sock.read(&mut chunk).await.ok()?;
                buf.extend_from_slice(&chunk[..n]);
                if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    body_start = i + 4;
                    let head = String::from_utf8_lossy(&buf[..i]).to_ascii_lowercase();
                    content_length = head
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length:"))
                        .map(|v| v.trim().parse::<usize>().unwrap())
                        .unwrap_or(0);
                    break;
                }
            }
            while buf.len() < body_start + content_length {
                let n = sock.read(&mut chunk).await.ok()?;
                buf.extend_from_slice(&chunk[..n]);
            }
            let body: Value = serde_json::from_slice(&buf[body_start..]).ok()?;
            let text = reply.to_string();
            let resp = format!(
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
                text.len()
            );
            sock.write_all(resp.as_bytes()).await.ok()?;
            Some(body)
        });
        (url, handle)
    }

    fn created(drawn: &str) -> Value {
        json!({"status": "ok",
               "figure": {"id": "C563336D-1111-4222-8333-444455556666", "name": "Decay",
                          "datasetId": "inline", "createdAt": "2026-09-25T00:00:00Z"},
               "artifact": {"dataHash": format!("{drawn}-hash"), "format": "png",
                            "width": 800, "height": 600}})
    }

    /// The view state `ImploreHTTPRouter.handleCreateFigure` builds from a
    /// body: `type`←`plotType`, `xColumn`←`x`, `yColumn`←`y`, default
    /// 800×600, and `copyArtifactData`'s three keys copied verbatim.
    fn router_view_state(body: &Value) -> FigureViewState {
        let mut vs = json!({
            "type": body["plotType"], "width": 800, "height": 600,
            "xColumn": body["x"], "yColumn": body["y"],
        });
        for key in ["series", "spec", "svg"] {
            if let Some(v) = body.get(key).filter(|v| !v.is_null()) {
                vs[key] = v.clone();
            }
        }
        FigureViewState::parse(&vs.to_string()).unwrap()
    }

    fn png_size(png: &[u8]) -> (u32, u32) {
        assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
        (
            u32::from_be_bytes(png[16..20].try_into().unwrap()),
            u32::from_be_bytes(png[20..24].try_into().unwrap()),
        )
    }

    async fn create(
        url: Url,
        series: Option<Value>,
        spec: Option<Value>,
        svg: Option<&str>,
    ) -> CreateFigureOutcome {
        let svc = HttpImploreService::new(Arc::new(ImploreClient::with_base_url(url)));
        svc.create_figure(
            "inline".into(),
            "scatter".into(),
            "time (s)".into(),
            Some("flux".into()),
            Some("Decay".into()),
            series.map(FigureSeriesArg),
            spec.map(PlotSpecArg),
            svg.map(str::to_string),
        )
        .await
    }

    #[tokio::test]
    async fn series_pass_through_and_render_the_data() {
        let series = json!([{"label": "run 1", "x": [0, 1, 2, 3], "y": [1.0, 0.61, 0.37, 0.22]}]);
        let (url, seen) = mock_implore(201, created("series")).await;
        let out = create(url, Some(series.clone()), None, None).await;
        let body = seen.await.unwrap().expect("implore got the request");

        assert_eq!(
            body["series"], series,
            "sent verbatim under the router's key"
        );
        assert!(body.get("spec").is_none() && body.get("svg").is_none());
        assert_eq!(
            (
                &body["datasetId"],
                &body["plotType"],
                &body["x"],
                &body["y"],
                &body["name"]
            ),
            (
                &json!("inline"),
                &json!("scatter"),
                &json!("time (s)"),
                &json!("flux"),
                &json!("Decay")
            )
        );
        assert!(out.ok);
        assert_eq!(out.drawn_from.as_deref(), Some("series"));
        assert_eq!(
            out.figure.as_ref().unwrap().dataset_id.as_deref(),
            Some("inline")
        );
        assert_eq!(out.artifact.as_ref().unwrap().data_hash, "series-hash");

        let vs = router_view_state(&body);
        let r = render_figure(&vs, None, RASTER_SCALE).unwrap();
        assert_eq!(png_size(&r.png), (1600, 1200));
        assert!(r.png.len() > 10_000, "a real plot, {} B", r.png.len());
        let empty = render_figure(
            &router_view_state(&json!({"plotType": "scatter",
            "x": "time (s)", "y": "flux"})),
            None,
            RASTER_SCALE,
        )
        .unwrap();
        assert_ne!(r.png, empty.png, "the points are drawn, not only the axes");
    }

    #[tokio::test]
    async fn a_spec_passes_through_and_renders_at_its_size() {
        let spec = json!({"title": "decay", "width": 480, "height": 320,
            "series": [{"x": [0, 1, 2], "y": [1, 0.5, 0.25], "style": "LineScatter"}]});
        let (url, seen) = mock_implore(201, created("spec")).await;
        let out = create(url, None, Some(spec.clone()), None).await;
        let body = seen.await.unwrap().unwrap();
        assert_eq!(body["spec"], spec);
        assert!(body.get("series").is_none() && body.get("svg").is_none());
        assert_eq!(out.drawn_from.as_deref(), Some("spec"));
        let r = render_figure(&router_view_state(&body), None, RASTER_SCALE).unwrap();
        assert_eq!(png_size(&r.png), (960, 640));
    }

    #[tokio::test]
    async fn an_svg_passes_through_and_is_rasterised() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="250" height="100"><rect x="10" y="10" width="200" height="60" fill="green"/></svg>"#;
        let (url, seen) = mock_implore(201, created("svg")).await;
        let out = create(url, None, None, Some(svg)).await;
        let body = seen.await.unwrap().unwrap();
        assert_eq!(body["svg"], json!(svg));
        assert_eq!(out.drawn_from.as_deref(), Some("svg"));
        let r = render_figure(&router_view_state(&body), None, RASTER_SCALE).unwrap();
        assert_eq!(png_size(&r.png), (500, 200));
    }

    #[tokio::test]
    async fn no_data_still_creates_empty_axes() {
        let (url, seen) = mock_implore(201, created("none")).await;
        let out = create(url, None, None, None).await;
        let body = seen.await.unwrap().unwrap();
        assert!(["series", "spec", "svg"]
            .iter()
            .all(|k| body.get(*k).is_none()));
        assert!(out.ok);
        assert_eq!(out.drawn_from.as_deref(), Some("none"));
    }

    #[tokio::test]
    async fn a_bad_call_is_refused_without_reaching_implore() {
        let (url, seen) = mock_implore(201, created("x")).await;
        let out = create(
            url,
            Some(json!([{"x": [1, 2, 3], "y": [1, 2]}])),
            None,
            None,
        )
        .await;
        assert!(!out.ok);
        assert_eq!(
            out.error.as_deref(),
            Some("create-figure refused: series[0]: x has 3 values but y has 2")
        );
        assert!(seen.await.unwrap().is_none(), "nothing was sent");

        let (url, seen) = mock_implore(201, created("x")).await;
        let out = create(
            url,
            Some(json!([{"x": [1], "y": [1]}])),
            Some(json!({})),
            None,
        )
        .await;
        assert_eq!(
            out.error.as_deref(),
            Some("create-figure refused: give at most one of series, spec and svg; got series and spec")
        );
        assert!(seen.await.unwrap().is_none());
    }

    #[tokio::test]
    async fn implores_own_refusal_is_relayed() {
        let (url, seen) = mock_implore(
            400,
            json!({"status": "error",
                   "error": "Figure not created: figure render failed: svg parse: bad"}),
        )
        .await;
        let out = create(
            url,
            None,
            None,
            Some(r#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>"#),
        )
        .await;
        seen.await.unwrap();
        assert!(!out.ok);
        assert_eq!(
            out.error.as_deref(),
            Some("Figure not created: figure render failed: svg parse: bad")
        );
    }
}
