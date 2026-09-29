//! In-process adapter from the generated service trait to implore's live
//! Swift state. The callback is an implementation detail of the native app;
//! only `ImploreService` defines public verb names and arguments.

use std::path::Path;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use implore_service::{
    register_backend, validate_figure_data, AppStatus, CreateFigureOutcome, DatasetRecord,
    FigureArtifactInfo, FigureExport, FigureRecord, FigureSeriesArg, ImploreBackend,
    ImploreService, LogEntry, PlotSpecArg, UpdateFigureOutcome,
};
use impress_service_core::refusal::codes;
use serde_json::{json, Value};

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct NativeReply {
    pub status: u16,
    pub body_json: String,
}

#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
#[async_trait::async_trait]
pub trait ImploreVerbHost: Send + Sync {
    async fn invoke(&self, method: String, args_json: String) -> NativeReply;
}

struct NativeService {
    host: Arc<dyn ImploreVerbHost>,
}

struct NativeBackend(Arc<NativeService>);

impl ImploreBackend for NativeBackend {
    fn service(&self) -> Arc<dyn ImploreService> {
        self.0.clone()
    }
}

/// Install the app's live-state host. Reinstalling replaces an earlier host,
/// e.g. after the automation server restarts in a hosted test.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn install_native_host(
    database_path: String,
    host: Box<dyn ImploreVerbHost>,
) -> Option<String> {
    if let Err(error) = bind_audit_store(&database_path) {
        return Some(error);
    }
    register_backend(Box::new(NativeBackend(Arc::new(NativeService {
        host: Arc::from(host),
    }))));
    None
}

fn bind_audit_store(database_path: &str) -> Result<(), String> {
    let requested = Path::new(database_path);
    if !requested.is_absolute()
        || requested.file_name().and_then(|name| name.to_str()) != Some("impress.sqlite")
    {
        return Err("expected an absolute impress.sqlite database path".into());
    }
    let parent = requested
        .parent()
        .ok_or("database has no workspace parent")?;
    std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let canonical = std::fs::canonicalize(parent)
        .map_err(|error| error.to_string())?
        .join("impress.sqlite");
    let store = impress_core::sqlite_store::SqliteItemStore::open(&canonical)
        .map_err(|error| format!("cannot open audit database: {error}"))?;
    impress_store_service::store::install_store_at(Arc::new(store), &canonical)?;
    impress_store_service::audit::install();
    Ok(())
}

impl NativeService {
    async fn call(&self, method: &str, args: Value) -> Result<Value, String> {
        let reply = self.host.invoke(method.into(), args.to_string()).await;
        let value: Value = serde_json::from_str(&reply.body_json).map_err(|error| {
            let message = format!("{method}: invalid native response: {error}");
            impress_service_core::pipeline::context::report_refusal(codes::INTERNAL, &message);
            message
        })?;
        if !(200..300).contains(&reply.status) {
            let message = value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("native operation failed")
                .to_string();
            let code = match reply.status {
                400 | 422 => codes::INVALID_ARGUMENT,
                404 => codes::NOT_FOUND,
                503 => codes::HOST_UNAVAILABLE,
                _ => codes::VERB_FAILED,
            };
            impress_service_core::pipeline::context::report_refusal(code, &message);
            return Err(message);
        }
        let valid = match method {
            "plot_series" | "plot_histogram" => value
                .get("svg")
                .and_then(Value::as_str)
                .is_some_and(|svg| !svg.is_empty()),
            "rg_statistics" => value.get("mean").is_some_and(Value::is_number),
            "rg_slice_raw" => value.get("values").is_some_and(Value::is_array),
            "rg_slice_png" => value
                .get("png_base64")
                .and_then(Value::as_str)
                .is_some_and(|png| !png.is_empty()),
            "export_figure_data" => {
                ["path", "sha256", "mimeType", "data"].iter().all(|key| {
                    value
                        .get(*key)
                        .and_then(Value::as_str)
                        .is_some_and(|field| !field.is_empty())
                }) && value
                    .get("data")
                    .and_then(Value::as_str)
                    .is_some_and(|encoded| !encoded.is_empty())
            }
            _ => true,
        };
        if !valid {
            let message = format!("{method}: native response omitted required result data");
            impress_service_core::pipeline::context::report_refusal(codes::INTERNAL, &message);
            return Err(message);
        }
        Ok(value)
    }

    async fn raw(&self, method: &str, args: Value) -> String {
        match self.call(method, args).await {
            Ok(value) => value.to_string(),
            Err(error) => json!({"status":"error", "error":error}).to_string(),
        }
    }
}

fn invalid_result(method: &str, field: &str) {
    impress_service_core::pipeline::context::report_refusal(
        codes::INTERNAL,
        format!("{method}: native response omitted or invalid {field}"),
    );
}

fn empty_figure_export() -> FigureExport {
    FigureExport {
        path: String::new(),
        sha256: String::new(),
        mime_type: String::new(),
        data: Vec::new(),
    }
}

fn array<T: serde::de::DeserializeOwned>(value: &Value, key: &str) -> Option<Vec<T>> {
    value
        .get(key)
        .and_then(|item| serde_json::from_value(item.clone()).ok())
}

fn object<T: serde::de::DeserializeOwned>(value: &Value, key: &str) -> Option<T> {
    value
        .get(key)
        .and_then(|item| serde_json::from_value(item.clone()).ok())
}

fn json_object(raw: Option<String>) -> Value {
    raw.and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

#[async_trait::async_trait]
impl ImploreService for NativeService {
    async fn status(&self) -> AppStatus {
        match self.call("status", json!({})).await {
            Ok(detail) => AppStatus {
                running: true,
                detail: detail.to_string(),
            },
            Err(error) => AppStatus {
                running: false,
                detail: error,
            },
        }
    }

    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry> {
        match self
            .call("get_logs", json!({"limit":limit,"level":level}))
            .await
        {
            Ok(value) => match value
                .get("data")
                .map(|data| array(data, "entries"))
                .unwrap_or_else(|| array(&value, "entries"))
            {
                Some(entries) => entries,
                None => {
                    invalid_result("get_logs", "entries");
                    vec![]
                }
            },
            Err(_) => vec![],
        }
    }

    async fn list_datasets(&self) -> Vec<DatasetRecord> {
        match self.call("list_datasets", json!({})).await {
            Ok(value) => array(&value, "datasets").unwrap_or_else(|| {
                invalid_result("list_datasets", "datasets");
                vec![]
            }),
            Err(_) => vec![],
        }
    }

    async fn get_dataset(&self, dataset_id: String) -> Option<DatasetRecord> {
        match self
            .call("get_dataset", json!({"dataset_id":dataset_id}))
            .await
        {
            Ok(value) => object(&value, "dataset").or_else(|| {
                invalid_result("get_dataset", "dataset");
                None
            }),
            Err(_) => None,
        }
    }

    async fn list_figures(&self, dataset_id: Option<String>) -> Vec<FigureRecord> {
        match self
            .call("list_figures", json!({"dataset_id":dataset_id}))
            .await
        {
            Ok(value) => array(&value, "figures").unwrap_or_else(|| {
                invalid_result("list_figures", "figures");
                vec![]
            }),
            Err(_) => vec![],
        }
    }

    async fn get_figure(&self, figure_id: String) -> Option<FigureRecord> {
        match self
            .call("get_figure", json!({"figure_id":figure_id}))
            .await
        {
            Ok(value) => object(&value, "figure").or_else(|| {
                invalid_result("get_figure", "figure");
                None
            }),
            Err(_) => None,
        }
    }

    #[allow(clippy::too_many_arguments)]
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
        width: Option<i64>,
        height: Option<i64>,
        title: Option<String>,
        color_column: Option<String>,
        view_state: Option<String>,
    ) -> CreateFigureOutcome {
        let data = match validate_figure_data(series.as_ref(), spec.as_ref(), svg.as_deref()) {
            Ok(data) => data,
            Err(error) => return CreateFigureOutcome::refused(error),
        };
        let mut args = json!({
            "datasetId":dataset_id,"plotType":plot_type,"x":x,"y":y,"name":name,
            "width":width,"height":height,"title":title,
            "colorColumn":color_column,"view_state":view_state
        });
        let mut drawn_from = "none";
        if let Some(data) = data {
            drawn_from = data.key();
            args[drawn_from] = data.into_json();
        }
        match self.call("create_figure", args).await {
            Ok(value) => match object::<FigureRecord>(&value, "figure") {
                Some(figure) => CreateFigureOutcome {
                    ok: true,
                    error: None,
                    figure: Some(figure),
                    artifact: object::<FigureArtifactInfo>(&value, "artifact"),
                    drawn_from: Some(drawn_from.to_string()),
                },
                None => {
                    invalid_result("create_figure", "figure");
                    CreateFigureOutcome::refused("native response omitted figure")
                }
            },
            Err(error) => CreateFigureOutcome::refused(error),
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn update_figure(
        &self,
        figure_id: String,
        name: Option<String>,
        plot_type: Option<String>,
        x: Option<String>,
        y: Option<String>,
        color_column: Option<String>,
        title: Option<String>,
        width: Option<i64>,
        height: Option<i64>,
        series: Option<FigureSeriesArg>,
        spec: Option<PlotSpecArg>,
        svg: Option<String>,
        view_state: Option<String>,
    ) -> UpdateFigureOutcome {
        let data = match validate_figure_data(series.as_ref(), spec.as_ref(), svg.as_deref()) {
            Ok(data) => data,
            Err(error) => return UpdateFigureOutcome::refused(error),
        };
        let mut args = json!({
            "name":name,"plotType":plot_type,"x":x,"y":y,
            "colorColumn":color_column,"title":title,"width":width,
            "height":height,"view_state":view_state
        });
        if let Some(data) = data {
            let key = data.key();
            args[key] = data.into_json();
        }
        args["figure_id"] = json!(figure_id);
        match self.call("update_figure", args).await {
            Ok(value) => match object::<FigureRecord>(&value, "figure") {
                Some(figure) => UpdateFigureOutcome {
                    ok: true,
                    error: None,
                    figure: Some(figure),
                    artifact: object::<FigureArtifactInfo>(&value, "artifact"),
                },
                None => {
                    invalid_result("update_figure", "figure");
                    UpdateFigureOutcome::refused("native response omitted figure")
                }
            },
            Err(error) => UpdateFigureOutcome::refused(error),
        }
    }

    async fn delete_figure(&self, figure_id: String) -> bool {
        match self
            .call("delete_figure", json!({"figure_id":figure_id}))
            .await
        {
            Ok(value) => value
                .get("deleted")
                .and_then(Value::as_bool)
                .unwrap_or_else(|| {
                    invalid_result("delete_figure", "deleted");
                    false
                }),
            Err(_) => false,
        }
    }

    async fn export_figure(&self, figure_id: String, format: String) -> Option<String> {
        match self
            .call(
                "export_figure",
                json!({"figure_id":figure_id,"format":format}),
            )
            .await
        {
            Ok(value) => value
                .get("path")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or_else(|| {
                    invalid_result("export_figure", "path");
                    None
                }),
            Err(_) => None,
        }
    }

    async fn export_figure_data(
        &self,
        figure_id: String,
        format: String,
        width: Option<f64>,
        height: Option<f64>,
        scale: Option<f64>,
        view_state: Option<String>,
    ) -> FigureExport {
        let value = match self
            .call(
                "export_figure_data",
                json!({
                    "figure_id": figure_id,
                    "format": format,
                    "width": width,
                    "height": height,
                    "scale": scale,
                    "view_state": view_state
                }),
            )
            .await
        {
            Ok(value) => value,
            Err(_) => return empty_figure_export(),
        };
        let decoded = value
            .get("data")
            .and_then(Value::as_str)
            .and_then(|encoded| BASE64.decode(encoded).ok());
        match decoded {
            Some(data) if !data.is_empty() => FigureExport {
                path: value["path"].as_str().unwrap_or_default().to_string(),
                sha256: value["sha256"].as_str().unwrap_or_default().to_string(),
                mime_type: value["mimeType"]
                    .as_str()
                    .or_else(|| value["mime_type"].as_str())
                    .unwrap_or_default()
                    .to_string(),
                data,
            },
            _ => {
                invalid_result("export_figure_data", "base64 data");
                empty_figure_export()
            }
        }
    }

    async fn plot_series(&self, series: Vec<String>, title: Option<String>) -> Option<String> {
        self.call("plot_series", json!({"series":series,"title":title}))
            .await
            .ok()
            .and_then(|v| v.get("svg").and_then(Value::as_str).map(str::to_string))
    }

    async fn plot_histogram(&self, quantity: Option<String>, bins: Option<u32>) -> Option<String> {
        self.call("plot_histogram", json!({"quantity":quantity,"bins":bins}))
            .await
            .ok()
            .and_then(|v| v.get("svg").and_then(Value::as_str).map(str::to_string))
    }

    async fn rg_load(&self, path: String) -> String {
        self.raw("rg_load", json!({"path":path})).await
    }
    async fn rg_state(&self) -> String {
        self.raw("rg_state", json!({})).await
    }
    async fn rg_control(&self, params_json: String) -> String {
        self.raw("rg_control", json_object(Some(params_json))).await
    }
    async fn rg_slice_png(&self, format: Option<String>) -> String {
        self.raw(
            "rg_slice_png",
            json!({"format":format.unwrap_or_else(||"base64".into())}),
        )
        .await
    }
    async fn rg_slice_save(&self, path: String) -> String {
        self.raw("rg_slice_save", json!({"path":path})).await
    }
    async fn rg_slice_raw(&self, params_json: Option<String>) -> String {
        self.raw("rg_slice_raw", json_object(params_json)).await
    }
    async fn rg_statistics(&self, params_json: Option<String>) -> String {
        self.raw("rg_statistics", json_object(params_json)).await
    }
    async fn rg_batch(&self, params_json: String) -> String {
        self.raw("rg_batch", json_object(Some(params_json))).await
    }
    async fn rg_colormaps(&self) -> String {
        self.raw("rg_colormaps", json!({})).await
    }
    async fn rg_cascade_plot(&self) -> String {
        self.raw("rg_cascade_plot", json!({})).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct FixtureHost {
        seen: Mutex<Vec<(String, Value)>>,
    }

    #[async_trait::async_trait]
    impl ImploreVerbHost for FixtureHost {
        async fn invoke(&self, method: String, args_json: String) -> NativeReply {
            let args: Value = serde_json::from_str(&args_json).unwrap();
            self.seen
                .lock()
                .unwrap()
                .push((method.clone(), args.clone()));
            let body = match method.as_str() {
                "plot_series" => json!({"svg":"<svg>series</svg>"}),
                "plot_histogram" => json!({"svg":"<svg>histogram</svg>"}),
                "rg_statistics" => json!({"status":"ok","scope":"slice","mean":2.5,"std":1.2}),
                "rg_slice_raw" => {
                    json!({"status":"ok","width":2,"height":1,"values":[1.0,4.0],"mean":2.5})
                }
                "rg_slice_png" => {
                    json!({"status":"ok","width":2,"height":1,"png_base64":"iVBORw0K"})
                }
                "update_figure" if args["name"] == "missing" => {
                    json!({"error":"Figure not found"})
                }
                "update_figure" if args["name"] == "bad" => {
                    json!({"error":"Figure not updated: render failed"})
                }
                "create_figure" if args["name"] == "bad" => {
                    json!({"error":"Figure not created: render failed"})
                }
                "create_figure" | "update_figure" => json!({
                    "figure": {
                        "id":"5f000000-0000-4000-8000-000000000001",
                        "name":"Figure", "datasetId":"inline", "createdAt":"now"
                    },
                    "artifact":{"dataHash":"abcd", "format":"png", "width":640, "height":400}
                }),
                "delete_figure" if args["figure_id"] == "missing" => {
                    json!({"error":"Figure not found"})
                }
                "delete_figure" => json!({"deleted":args["figure_id"] != "missing"}),
                "export_figure_data" if args["format"] == "malformed" => json!({
                    "status":"ok", "path":"/tmp/export.png", "sha256":"hash",
                    "mimeType":"image/png", "data":"not base64!"
                }),
                "export_figure_data" if args["format"] == "missing" => {
                    json!({"error":"Figure not found"})
                }
                "export_figure_data" => json!({
                    "status":"ok", "path":"/tmp/export.png", "sha256":"abc123",
                    "mimeType":"image/png", "data":"iVBORw0KGgo="
                }),
                "list_figures" => json!({
                    "status":"ok",
                    "count":1,
                    "figures":[{
                        "id":"figure-1",
                        "name":"Figure One",
                        "datasetId":"dataset-1",
                        "type":"scatter",
                        "width":800,
                        "height":600,
                        "xColumn":"time",
                        "yColumn":"value",
                        "createdAt":"2026-09-29T12:00:00Z",
                        "modifiedAt":"2026-09-29T12:30:00Z"
                    }]
                }),
                "get_figure" => json!({
                    "status":"ok",
                    "figure":{
                        "id":"figure-1",
                        "name":"Figure One",
                        "datasetId":"dataset-1",
                        "type":"scatter",
                        "width":800,
                        "height":600,
                        "xColumn":"time",
                        "yColumn":"value",
                        "createdAt":"2026-09-29T12:00:00Z",
                        "modifiedAt":"2026-09-29T12:30:00Z",
                        "datasetName":null,
                        "viewState":null
                    }
                }),
                _ => json!({"error":"unexpected method"}),
            };
            NativeReply {
                status: if (method == "export_figure_data" && args["format"] == "missing")
                    || (method == "delete_figure" && args["figure_id"] == "missing")
                    || (method == "update_figure" && args["name"] == "missing")
                {
                    404
                } else if (method == "create_figure" && args["name"] == "bad")
                    || (method == "update_figure" && args["name"] == "bad")
                {
                    400
                } else if method.starts_with("rg_")
                    || method.starts_with("plot_")
                    || method == "create_figure"
                    || method == "update_figure"
                    || method == "delete_figure"
                    || method == "export_figure_data"
                    || method == "list_figures"
                    || method == "get_figure"
                {
                    200
                } else {
                    404
                },
                body_json: body.to_string(),
            }
        }
    }

    #[tokio::test]
    async fn native_backend_keeps_numeric_plot_and_png_values() {
        let host = Arc::new(FixtureHost::default());
        let service = NativeService { host: host.clone() };
        assert_eq!(
            service
                .plot_series(vec!["energy".into()], None)
                .await
                .as_deref(),
            Some("<svg>series</svg>")
        );
        assert_eq!(
            service
                .plot_histogram(Some("vorticity".into()), Some(12))
                .await
                .as_deref(),
            Some("<svg>histogram</svg>")
        );
        let stats: Value = serde_json::from_str(
            &service
                .rg_statistics(Some(r#"{"scope":"slice"}"#.into()))
                .await,
        )
        .unwrap();
        assert_eq!(stats["mean"], 2.5);
        let raw: Value = serde_json::from_str(&service.rg_slice_raw(None).await).unwrap();
        assert_eq!(raw["values"], json!([1.0, 4.0]));
        let png: Value = serde_json::from_str(&service.rg_slice_png(None).await).unwrap();
        assert_eq!(png["png_base64"], "iVBORw0K");
        let seen = host.seen.lock().unwrap();
        assert_eq!(seen[0].1["series"], json!(["energy"]));
        assert_eq!(seen[4].1["format"], "base64");
    }

    #[tokio::test]
    async fn native_backend_forwards_figure_configuration_and_mutations() {
        let host = Arc::new(FixtureHost::default());
        let service = NativeService { host: host.clone() };
        let series = FigureSeriesArg(json!([{"x":[1,2],"y":[3,4]}]));
        let created = service
            .create_figure(
                "inline".into(),
                "line".into(),
                "time".into(),
                Some("flux".into()),
                Some("Mutation proof".into()),
                Some(series.clone()),
                None,
                None,
                Some(640),
                Some(400),
                Some("Flux over time".into()),
                Some("instrument".into()),
                Some(r#"{"annotations":[]}"#.into()),
            )
            .await;
        assert!(created.ok);
        assert_eq!(
            created
                .artifact
                .as_ref()
                .map(|artifact| artifact.data_hash.as_str()),
            Some("abcd")
        );
        let refused_create = service
            .create_figure(
                "inline".into(),
                "line".into(),
                "time".into(),
                None,
                Some("bad".into()),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await;
        assert!(!refused_create.ok);
        assert_eq!(
            refused_create.error.as_deref(),
            Some("Figure not created: render failed")
        );

        let updated = service
            .update_figure(
                "5f000000-0000-4000-8000-000000000001".into(),
                Some("Renamed".into()),
                Some("scatter".into()),
                Some("time".into()),
                Some("flux".into()),
                Some("instrument".into()),
                Some("New title".into()),
                Some(800),
                Some(500),
                Some(series),
                None,
                None,
                None,
            )
            .await;
        assert!(updated.ok);
        assert_eq!(
            updated
                .artifact
                .as_ref()
                .map(|artifact| artifact.data_hash.as_str()),
            Some("abcd")
        );
        let refused_update = service
            .update_figure(
                "missing".into(),
                Some("missing".into()),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await;
        assert!(!refused_update.ok);
        assert_eq!(refused_update.error.as_deref(), Some("Figure not found"));
        let refused_rerender = service
            .update_figure(
                "figure-id".into(),
                Some("bad".into()),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .await;
        assert!(!refused_rerender.ok);
        assert_eq!(
            refused_rerender.error.as_deref(),
            Some("Figure not updated: render failed")
        );
        assert!(
            service
                .delete_figure("5f000000-0000-4000-8000-000000000001".into())
                .await
        );
        assert!(!service.delete_figure("missing".into()).await);

        let seen = host.seen.lock().unwrap();
        assert_eq!(seen[0].0, "create_figure");
        assert_eq!(seen[0].1["datasetId"], "inline");
        assert_eq!(seen[0].1["plotType"], "line");
        assert_eq!(seen[0].1["width"], 640);
        assert_eq!(seen[0].1["height"], 400);
        assert_eq!(seen[0].1["title"], "Flux over time");
        assert_eq!(seen[0].1["colorColumn"], "instrument");
        assert_eq!(seen[0].1["view_state"], r#"{"annotations":[]}"#);
        assert_eq!(seen[0].1["series"], json!([{"x":[1,2],"y":[3,4]}]));
        assert_eq!(seen[1].0, "create_figure");
        assert_eq!(seen[1].1["name"], "bad");
        assert_eq!(seen[2].0, "update_figure");
        assert_eq!(
            seen[2].1["figure_id"],
            "5f000000-0000-4000-8000-000000000001"
        );
        assert_eq!(seen[2].1["plotType"], "scatter");
        assert_eq!(seen[2].1["width"], 800);
        assert_eq!(seen[2].1["series"], json!([{"x":[1,2],"y":[3,4]}]));
        assert_eq!(seen[3].0, "update_figure");
        assert_eq!(seen[3].1["name"], "missing");
        assert_eq!(seen[4].1["name"], "bad");
        assert_eq!(seen[5].0, "delete_figure");
        assert_eq!(seen[6].1["figure_id"], "missing");
    }

    #[tokio::test]
    async fn native_backend_decodes_export_bytes_and_forwards_render_options() {
        let host = Arc::new(FixtureHost::default());
        let service = NativeService { host: host.clone() };
        let exported = service
            .export_figure_data(
                "figure-1".into(),
                "png".into(),
                Some(320.5),
                Some(200.25),
                Some(1.5),
                Some(r#"{"title":"custom"}"#.into()),
            )
            .await;
        assert_eq!(exported.path, "/tmp/export.png");
        assert_eq!(exported.sha256, "abc123");
        assert_eq!(exported.mime_type, "image/png");
        assert_eq!(exported.data, b"\x89PNG\r\n\x1a\n");
        let seen = host.seen.lock().unwrap();
        assert_eq!(seen[0].0, "export_figure_data");
        assert_eq!(seen[0].1["figure_id"], "figure-1");
        assert_eq!(seen[0].1["format"], "png");
        assert_eq!(seen[0].1["width"], 320.5);
        assert_eq!(seen[0].1["height"], 200.25);
        assert_eq!(seen[0].1["scale"], 1.5);
        assert_eq!(seen[0].1["view_state"], r#"{"title":"custom"}"#);
    }

    #[tokio::test]
    async fn native_backend_does_not_return_malformed_or_refused_export_as_success() {
        let host = Arc::new(FixtureHost::default());
        let service = NativeService { host };
        let malformed = service
            .export_figure_data(
                "figure-1".into(),
                "malformed".into(),
                None,
                None,
                None,
                None,
            )
            .await;
        assert!(malformed.data.is_empty());
        assert!(malformed.path.is_empty());
        let refused = service
            .export_figure_data("missing".into(), "missing".into(), None, None, None, None)
            .await;
        assert!(refused.data.is_empty());
        assert!(refused.path.is_empty());
    }

    #[tokio::test]
    async fn native_figure_reads_decode_http_metadata_and_keep_absent_fields_empty() {
        let host = Arc::new(FixtureHost::default());
        let service = NativeService { host: host.clone() };

        let listed = service.list_figures(Some("dataset-1".into())).await;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, "figure-1");
        assert_eq!(listed[0].dataset_id.as_deref(), Some("dataset-1"));
        assert_eq!(listed[0].figure_type, "scatter");
        assert_eq!(listed[0].width, Some(800));
        assert_eq!(listed[0].height, Some(600));
        assert_eq!(listed[0].x_column.as_deref(), Some("time"));
        assert_eq!(listed[0].y_column.as_deref(), Some("value"));
        assert_eq!(listed[0].color_column, None);
        assert_eq!(listed[0].title, None);
        assert_eq!(listed[0].tags, None);
        assert_eq!(listed[0].folder_id, None);
        assert_eq!(
            listed[0].modified_at.as_deref(),
            Some("2026-09-29T12:30:00Z")
        );
        assert_eq!(listed[0].dataset_name, None);
        assert_eq!(listed[0].view_state, None);

        let figure = service.get_figure("figure-1".into()).await.unwrap();
        assert_eq!(figure.figure_type, "scatter");
        assert_eq!(figure.width, Some(800));
        assert_eq!(figure.height, Some(600));
        assert_eq!(figure.x_column.as_deref(), Some("time"));
        assert_eq!(figure.y_column.as_deref(), Some("value"));
        assert_eq!(figure.color_column, None);
        assert_eq!(figure.title, None);
        assert_eq!(figure.tags, None);
        assert_eq!(figure.folder_id, None);
        assert_eq!(figure.modified_at.as_deref(), Some("2026-09-29T12:30:00Z"));
        assert_eq!(figure.dataset_name, None);
        assert_eq!(figure.view_state, None);

        let seen = host.seen.lock().unwrap();
        assert_eq!(
            seen[0],
            ("list_figures".into(), json!({"dataset_id":"dataset-1"}))
        );
        assert_eq!(
            seen[1],
            ("get_figure".into(), json!({"figure_id":"figure-1"}))
        );
    }

    #[test]
    fn hosted_proof_fixture_has_real_plot_and_volume_data() {
        use implore_core::rg::ffi::RgDatasetHandle;
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../apps/implore/Tests/fixtures/rg-volume.npz");
        let dataset = RgDatasetHandle::load(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(dataset.info().grid_size, 4);
        assert!(dataset.info().data_series_names.contains(&"energy".into()));
        assert!(dataset
            .plot_data_series(vec!["energy".into()], "Energy".into())
            .unwrap()
            .contains("<svg"));
        assert!(dataset
            .plot_field_histogram("velocity_magnitude".into(), 4)
            .unwrap()
            .contains("<svg"));
        let raw = dataset
            .get_raw_slice("velocity_magnitude".into(), "z".into(), 1)
            .unwrap();
        assert_eq!((raw.width, raw.height, raw.values.len()), (4, 4, 16));
        assert!(raw.mean_value.is_finite());
    }
}
