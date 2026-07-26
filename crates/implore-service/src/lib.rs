//! `ImploreService` — implore's capability surface, generated for MCP, the CLI
//! and impel from one trait.
//!
//! Unlike `imbib-service` and `imprint-service`, there is no store-backed
//! default worth writing: implore's datasets and figures live in the running
//! app's memory, not in the shared SQLite store. So the default implementation
//! refuses and explains, and `implore-service-http` does the real work against
//! the app on port 23124.
//!
//! # The `rg_*` family
//!
//! Those ten methods drive implore's ray-grid volume viewer. Their payloads are
//! deliberately opaque JSON strings rather than modelled structs: the viewer's
//! state and statistics shapes are its own and change with it, and re-declaring
//! them here would create exactly the parallel definition this codegen exists
//! to avoid. The descriptions carry the meaning; the JSON carries the data.

use std::sync::{Arc, OnceLock};

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// An open dataset, with enough shape to plan a plot against it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct DatasetRecord {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default, alias = "rowCount")]
    pub row_count: Option<i64>,
    #[serde(default, alias = "columnCount")]
    pub column_count: Option<i64>,
    /// Column names, so a caller can choose axes without a second round trip.
    #[serde(default)]
    pub columns: Vec<String>,
}

/// A figure in implore.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct FigureRecord {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, alias = "datasetId", alias = "datasetID")]
    pub dataset_id: Option<String>,
    #[serde(default, alias = "createdAt")]
    pub created_at: Option<String>,
}

/// One line from implore's in-memory log store.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LogEntry {
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub level: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub message: String,
}

/// Free-form app state, returned verbatim.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AppStatus {
    pub running: bool,
    pub detail: String,
}

#[impress_service]
pub trait ImploreService: Send + Sync + 'static {
    /// Whether implore is running, plus its version, port and how many
    /// datasets are open.
    #[impress_method]
    async fn status(&self) -> AppStatus;

    /// Recent lines from implore's in-memory log store.
    #[impress_method]
    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry>;

    /// Datasets currently open in implore, with row and column counts. START
    /// HERE for any plotting request: figures are created against a dataset id.
    #[impress_method]
    async fn list_datasets(&self) -> Vec<DatasetRecord>;

    /// One dataset in detail, including per-column statistics where implore has
    /// computed them. Use it to pick sensible axes before creating a figure.
    #[impress_method]
    async fn get_dataset(&self, dataset_id: String) -> Option<DatasetRecord>;

    /// Figures in implore, optionally narrowed to one dataset.
    #[impress_method]
    async fn list_figures(&self, dataset_id: Option<String>) -> Vec<FigureRecord>;

    /// One figure's definition.
    #[impress_method]
    async fn get_figure(&self, figure_id: String) -> Option<FigureRecord>;

    /// Create a figure against an open dataset. `plot_type` is implore's own
    /// vocabulary (`scatter`, `line`, `bar`, …); `x` and `y` are column names
    /// from the dataset, so list it first rather than guessing.
    #[impress_method]
    async fn create_figure(
        &self,
        dataset_id: String,
        plot_type: String,
        x: String,
        y: Option<String>,
        name: Option<String>,
    ) -> Option<FigureRecord>;

    /// Export a figure to a file and return its path. `format` is `png`, `pdf`
    /// or `svg`. The path is what an agent on the user's Mac can open, or embed
    /// into a manuscript.
    #[impress_method]
    async fn export_figure(&self, figure_id: String, format: String) -> Option<String>;

    /// Plot one or more named series and return the rendered SVG.
    #[impress_method]
    async fn plot_series(&self, series: Vec<String>, title: Option<String>) -> Option<String>;

    /// Plot a histogram of one quantity and return the rendered SVG.
    #[impress_method]
    async fn plot_histogram(&self, quantity: Option<String>, bins: Option<u32>) -> Option<String>;

    // ---- Ray-grid volume viewer -------------------------------------------

    /// Load a volume dataset into the ray-grid viewer from a path on disk.
    /// Everything else in the `rg_*` family operates on whatever is loaded.
    #[impress_method]
    async fn rg_load(&self, path: String) -> String;

    /// The viewer's current state — camera, slice position, colormap, loaded
    /// dataset. Returned as JSON; the shape is the viewer's own.
    #[impress_method]
    async fn rg_state(&self) -> String;

    /// Drive the viewer: pass a JSON object of controls (camera, slice axis and
    /// index, colormap, scaling). Read `rg_state` first to see what is settable.
    #[impress_method]
    async fn rg_control(&self, params_json: String) -> String;

    /// Render the current slice as a PNG and return it (base64 or a path,
    /// depending on how the viewer answers).
    #[impress_method]
    async fn rg_slice_png(&self, format: Option<String>) -> String;

    /// Write the current slice to a file at `path`.
    #[impress_method]
    async fn rg_slice_save(&self, path: String) -> String;

    /// The current slice as raw numeric data rather than an image — for
    /// analysis rather than display. Can be large.
    #[impress_method]
    async fn rg_slice_raw(&self, params_json: Option<String>) -> String;

    /// Summary statistics over the loaded volume, or a sub-region when the
    /// parameters name one.
    #[impress_method]
    async fn rg_statistics(&self, params_json: Option<String>) -> String;

    /// Run a batch of viewer operations in one call, which is much cheaper than
    /// a round trip each when sweeping slices or angles.
    #[impress_method]
    async fn rg_batch(&self, params_json: String) -> String;

    /// Colormaps the viewer offers, for use with `rg_control`.
    #[impress_method]
    async fn rg_colormaps(&self) -> String;

    /// Render a cascade plot over the loaded volume and return the SVG.
    #[impress_method]
    async fn rg_cascade_plot(&self) -> String;
}

// ---------------------------------------------------------------------------
// Default (refusing) implementation
// ---------------------------------------------------------------------------

#[derive(Clone, Default)]
pub struct DefaultImploreService;

impl DefaultImploreService {
    pub fn new() -> Self {
        Self
    }
}

const NOT_RUNNING: &str =
    "implore is not running. Its datasets and figures live in the app's memory, \
     not in the shared store, so there is nothing to read while it is closed. \
     Open implore and try again.";

fn refuse(method: &str) {
    eprintln!("[implore-service] {method}: implore not running; refused");
}

fn refuse_json(method: &str) -> String {
    refuse(method);
    serde_json::json!({ "error": NOT_RUNNING }).to_string()
}

#[async_trait::async_trait]
impl ImploreService for DefaultImploreService {
    async fn status(&self) -> AppStatus {
        AppStatus {
            running: false,
            detail: "implore is not running.".into(),
        }
    }
    async fn get_logs(&self, _limit: u32, _level: Option<String>) -> Vec<LogEntry> {
        refuse("get_logs");
        vec![]
    }
    async fn list_datasets(&self) -> Vec<DatasetRecord> {
        refuse("list_datasets");
        vec![]
    }
    async fn get_dataset(&self, _dataset_id: String) -> Option<DatasetRecord> {
        refuse("get_dataset");
        None
    }
    async fn list_figures(&self, _dataset_id: Option<String>) -> Vec<FigureRecord> {
        refuse("list_figures");
        vec![]
    }
    async fn get_figure(&self, _figure_id: String) -> Option<FigureRecord> {
        refuse("get_figure");
        None
    }
    async fn create_figure(
        &self,
        _dataset_id: String,
        _plot_type: String,
        _x: String,
        _y: Option<String>,
        _name: Option<String>,
    ) -> Option<FigureRecord> {
        refuse("create_figure");
        None
    }
    async fn export_figure(&self, _figure_id: String, _format: String) -> Option<String> {
        refuse("export_figure");
        None
    }
    async fn plot_series(&self, _series: Vec<String>, _title: Option<String>) -> Option<String> {
        refuse("plot_series");
        None
    }
    async fn plot_histogram(
        &self,
        _quantity: Option<String>,
        _bins: Option<u32>,
    ) -> Option<String> {
        refuse("plot_histogram");
        None
    }
    async fn rg_load(&self, _path: String) -> String {
        refuse_json("rg_load")
    }
    async fn rg_state(&self) -> String {
        refuse_json("rg_state")
    }
    async fn rg_control(&self, _params_json: String) -> String {
        refuse_json("rg_control")
    }
    async fn rg_slice_png(&self, _format: Option<String>) -> String {
        refuse_json("rg_slice_png")
    }
    async fn rg_slice_save(&self, _path: String) -> String {
        refuse_json("rg_slice_save")
    }
    async fn rg_slice_raw(&self, _params_json: Option<String>) -> String {
        refuse_json("rg_slice_raw")
    }
    async fn rg_statistics(&self, _params_json: Option<String>) -> String {
        refuse_json("rg_statistics")
    }
    async fn rg_batch(&self, _params_json: String) -> String {
        refuse_json("rg_batch")
    }
    async fn rg_colormaps(&self) -> String {
        refuse_json("rg_colormaps")
    }
    async fn rg_cascade_plot(&self) -> String {
        refuse_json("rg_cascade_plot")
    }
}

// ---------------------------------------------------------------------------
// Pluggable backend
// ---------------------------------------------------------------------------

/// Implemented by `implore-service-http`. One service, so this is a single
/// method rather than the per-trait registry imbib needs.
pub trait ImploreBackend: Send + Sync + 'static {
    fn service(&self) -> Arc<dyn ImploreService>;
}

static BACKEND: OnceLock<Box<dyn ImploreBackend>> = OnceLock::new();

/// Install a backend at process startup. First call wins.
pub fn register_backend(backend: Box<dyn ImploreBackend>) {
    let _ = BACKEND.set(backend);
}

pub fn has_custom_backend() -> bool {
    BACKEND.get().is_some()
}

pub fn service_instance() -> Arc<dyn ImploreService> {
    match BACKEND.get() {
        Some(b) => b.service(),
        None => Arc::new(DefaultImploreService::new()),
    }
}

impress_service_impl! {
    service = ImploreService,
    impl = DefaultImploreService,
    instance = service_instance,
    methods = [
        status() -> AppStatus,
        get_logs(limit: u32, level: Option<String>) -> Vec<LogEntry>,
        list_datasets() -> Vec<DatasetRecord>,
        get_dataset(dataset_id: String) -> Option<DatasetRecord>,
        list_figures(dataset_id: Option<String>) -> Vec<FigureRecord>,
        get_figure(figure_id: String) -> Option<FigureRecord>,
        create_figure(
            dataset_id: String,
            plot_type: String,
            x: String,
            y: Option<String>,
            name: Option<String>
        ) -> Option<FigureRecord>,
        export_figure(figure_id: String, format: String) -> Option<String>,
        plot_series(series: Vec<String>, title: Option<String>) -> Option<String>,
        plot_histogram(quantity: Option<String>, bins: Option<u32>) -> Option<String>,
        rg_load(path: String) -> String,
        rg_state() -> String,
        rg_control(params_json: String) -> String,
        rg_slice_png(format: Option<String>) -> String,
        rg_slice_save(path: String) -> String,
        rg_slice_raw(params_json: Option<String>) -> String,
        rg_statistics(params_json: Option<String>) -> String,
        rg_batch(params_json: String) -> String,
        rg_colormaps() -> String,
        rg_cascade_plot() -> String,
    ],
}
