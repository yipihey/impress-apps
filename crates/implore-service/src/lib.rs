//! `ImploreService` — implore's capability surface, generated for MCP, the CLI
//! and impel from one trait.
//!
//! Unlike `imbib-service` and `imprint-service`, there is no store-backed
//! default worth writing: implore's datasets and figures live in the running
//! app's memory, not in the shared SQLite store. So the default implementation
//! refuses and explains, and `implore-service-http` does the real work against
//! the app on port 23123 (`SiblingApp.descriptors` in packages/ImpressKit is
//! the authority; this was 23124 until the 2026-07-30 collision fix).
//!
//! # The `rg_*` family
//!
//! Those ten methods drive implore's ray-grid volume viewer. Their payloads are
//! deliberately opaque JSON strings rather than modelled structs: the viewer's
//! state and statistics shapes are its own and change with it, and re-declaring
//! them here would create exactly the parallel definition this codegen exists
//! to avoid. The descriptions carry the meaning; the JSON carries the data.

use std::sync::Arc;

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

/// One inline data series, as `create-figure`'s `series` takes it. Schema
/// only: the argument arrives as raw JSON ([`FigureSeriesArg`]) so that
/// [`validate_figure_data`] can name a bad value by index instead of serde
/// failing first with a message that has no path.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FigureSeries {
    /// Legend label (default "series N"). A legend is drawn when there is
    /// more than one series.
    #[serde(default)]
    pub label: Option<String>,
    /// X values (numbers), as many as `y`.
    pub x: Vec<f64>,
    /// Y values (numbers), as many as `x`.
    pub y: Vec<f64>,
}

/// `create-figure`'s `series` argument: a list of [`FigureSeries`], carried
/// as JSON and checked by [`validate_figure_data`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct FigureSeriesArg(pub serde_json::Value);

impl schemars::JsonSchema for FigureSeriesArg {
    fn schema_name() -> String {
        "FigureSeriesList".into()
    }
    // Inline, so the MCP `inputSchema` shows the shape at the argument
    // (no `$ref` to chase) and `Option` makes it `["array", "null"]`, which
    // the CLI reads as a repeatable flag taking one JSON object each.
    fn is_referenceable() -> bool {
        false
    }
    fn json_schema(gen: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
        let mut schema = <Vec<FigureSeries>>::json_schema(gen).into_object();
        schema.array().min_items = Some(1);
        schema.array().max_items = Some(implore_core::figure_artifact::MAX_FIGURE_SERIES as u32);
        schema.array().items = Some(schemars::schema::SingleOrVec::Single(Box::new(
            FigureSeries::json_schema(gen),
        )));
        schema.into()
    }
}

/// `create-figure`'s `spec` argument: a whole implore `PlotSpec` as JSON,
/// checked by [`validate_figure_data`] and parsed by implore's renderer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PlotSpecArg(pub serde_json::Value);

impl schemars::JsonSchema for PlotSpecArg {
    fn schema_name() -> String {
        "ImplorePlotSpec".into()
    }
    fn is_referenceable() -> bool {
        false
    }
    /// Hand-written because `PlotSpec` lives in implore-core, which has no
    /// schemars; `implore-service`'s tests hold every example here to
    /// `validate_figure_data`, so the two cannot drift silently.
    fn json_schema(_: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
        let color = serde_json::json!({
            "description": "Blue, Red, Green, Orange, Purple, Cyan, Black, Gray, or {\"Rgb\": [r, g, b]} (0-255).",
            "anyOf": [
                {"type": "string", "enum": ["Blue", "Red", "Green", "Orange", "Purple", "Cyan", "Black", "Gray"]},
                {"type": "object", "required": ["Rgb"], "properties": {"Rgb": {"type": "array", "items": {"type": "integer", "minimum": 0, "maximum": 255}, "minItems": 3, "maxItems": 3}}}
            ]
        });
        let axis = serde_json::json!({
            "type": "object",
            "properties": {
                "label": {"type": "string"},
                "min": {"type": "number"},
                "max": {"type": "number"},
                "log_scale": {"type": "boolean", "default": false},
                "format": {"type": "string", "description": "Tick format, e.g. \".2e\"."}
            }
        });
        let numbers = serde_json::json!({"type": "array", "items": {"type": "number"}});
        let value = serde_json::json!({
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "width": {"type": "number", "exclusiveMinimum": 0, "maximum": implore_core::figure_artifact::MAX_FIGURE_SIDE, "default": 640},
                "height": {"type": "number", "exclusiveMinimum": 0, "maximum": implore_core::figure_artifact::MAX_FIGURE_SIDE, "default": 400},
                "x_axis": axis,
                "y_axis": axis,
                "series": {
                    "type": "array",
                    "maxItems": implore_core::figure_artifact::MAX_FIGURE_SERIES,
                    "items": {
                        "type": "object",
                        "required": ["x", "y"],
                        "properties": {
                            "label": {"type": "string"},
                            "x": numbers,
                            "y": numbers,
                            "error_low": {"description": "Lower error per point (as many as y); draws error bars.", "type": "array", "items": {"type": "number"}},
                            "error_high": {"description": "Upper error per point (as many as y).", "type": "array", "items": {"type": "number"}},
                            "style": {"type": "string", "enum": ["Line", "Scatter", "LineScatter", "Bar", "Step"], "default": "Line"},
                            "color": color,
                            "point_radius": {"type": "number", "default": 3.0},
                            "line_width": {"type": "number", "default": 1.5}
                        }
                    }
                },
                "legend": {
                    "type": "object",
                    "properties": {
                        "position": {"type": "string", "enum": ["TopRight", "TopLeft", "BottomRight", "BottomLeft"], "default": "TopRight"},
                        "visible": {"type": "boolean", "default": true}
                    }
                },
                "show_grid": {"type": "boolean", "default": true},
                "annotations": {
                    "description": "Reference lines, e.g. {\"HLine\": {\"y\": 0.5, \"label\": \"half\", \"color\": \"Gray\", \"dash\": true}} or {\"VLine\": {\"x\": 2, \"label\": null, \"color\": \"Red\", \"dash\": false}}.",
                    "type": "array",
                    "items": {"type": "object"}
                }
            }
        });
        serde_json::from_value(value).expect("the PlotSpec schema literal is a valid schema")
    }
}

/// The stored image a figure write produced (the `figure` row's fields).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct FigureArtifactInfo {
    /// sha256 of the PNG in the shared content store: the row's `data_hash`.
    #[serde(alias = "dataHash")]
    pub data_hash: String,
    #[serde(default)]
    pub format: String,
    /// Logical size in points (the PNG is 2x).
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
}

/// What `create-figure` answers: the figure and its stored artifact, or
/// `ok: false` and an `error` saying why nothing was created.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CreateFigureOutcome {
    pub ok: bool,
    /// Why the figure was not created (argument problems name the argument).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The figure (`id`, `name`, `dataset_id`, `created_at`), flattened
    /// into the answer as the verb returned it before it had data arguments.
    #[serde(flatten, default)]
    pub figure: Option<FigureRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<FigureArtifactInfo>,
    /// Which data argument the image was drawn from (`series`, `spec`,
    /// `svg`), or `none`: labelled empty axes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drawn_from: Option<String>,
}

impl CreateFigureOutcome {
    pub fn refused(error: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(error.into()),
            figure: None,
            artifact: None,
            drawn_from: None,
        }
    }
}

/// Check `create-figure`'s data arguments; `Ok(None)` is "no data".
///
/// The rules are implore-core's ([`implore_core::figure_artifact::validate_figure_data`],
/// the module that renders the data): at most one of the three; `series`
/// a non-empty list of `{label?, x, y}` with equal-length numeric x and y;
/// `spec` a parseable implore plot spec; `svg` a parseable SVG; at most
/// [`MAX_FIGURE_SERIES`](implore_core::figure_artifact::MAX_FIGURE_SERIES)
/// series and [`MAX_FIGURE_POINTS`](implore_core::figure_artifact::MAX_FIGURE_POINTS)
/// points. The error is prefixed `create-figure refused:`.
pub fn validate_figure_data(
    series: Option<&FigureSeriesArg>,
    spec: Option<&PlotSpecArg>,
    svg: Option<&str>,
) -> Result<Option<implore_core::figure_artifact::FigureData>, String> {
    implore_core::figure_artifact::validate_figure_data(
        series.map(|s| &s.0),
        spec.map(|s| &s.0),
        svg,
    )
    .map_err(|e| format!("create-figure refused: {e}"))
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

    /// Create a figure in implore and store its rendered image (a PNG in the
    /// shared content store, named by the figure row's `data_hash`), which is
    /// what implore's View tab, every app's figure detail and impress's `plot`
    /// pane draw.
    ///
    /// Data: give AT MOST ONE of `series` (inline x/y lists; the usual
    /// choice), `spec` (a whole implore plot spec: error bars, log axes, axis
    /// ranges, per-series style) or `svg` (a finished SVG). With none of them
    /// the figure is labelled EMPTY AXES: `x` and `y` become axis labels and
    /// nothing is plotted (implore cannot load a dataset by id).
    ///
    /// `plot_type` styles `series`: scatter, line, line-scatter, bar (or
    /// histogram), step; anything else draws lines. `x`/`y` are the axis
    /// labels (the dataset's column names). `spec` and `svg` replace
    /// `plot_type`, `x` and `y`. `dataset_id` is recorded on the figure; with
    /// inline data any short label for where the data came from will do.
    /// `name` is the figure's name in implore (default "Untitled Figure").
    ///
    /// Caps: 32 series and 50000 points in all; `svg` up to 2 MB and 4096
    /// points a side; `spec` width/height up to 4096. A refusal answers
    /// `ok: false` with an `error` naming the argument (and index), e.g.
    /// "create-figure refused: series[1]: x has 4 values but y has 3".
    /// Success answers `ok: true`, the figure's `id`, the `artifact`
    /// (`data_hash`, `width`, `height`) and `drawn_from`.
    ///
    /// Example (MCP): {"dataset_id": "inline", "plot_type": "scatter",
    /// "x": "time (s)", "y": "flux", "name": "Decay", "series": [{"label":
    /// "run 1", "x": [0, 1, 2, 3], "y": [1.0, 0.61, 0.37, 0.22]}]}
    ///
    /// Example (CLI): impress create-figure --dataset-id inline --plot-type
    /// scatter --x 'time (s)' --y flux --name Decay --series
    /// '{"label":"run 1","x":[0,1,2,3],"y":[1.0,0.61,0.37,0.22]}'
    #[impress_method]
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
    ) -> CreateFigureOutcome;

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
        series: Option<FigureSeriesArg>,
        spec: Option<PlotSpecArg>,
        svg: Option<String>,
    ) -> CreateFigureOutcome {
        // A malformed call is named as such even with implore closed, so
        // the caller fixes it before opening the app, not after.
        if let Err(e) = validate_figure_data(series.as_ref(), spec.as_ref(), svg.as_deref()) {
            return CreateFigureOutcome::refused(e);
        }
        refuse("create_figure");
        CreateFigureOutcome::refused(NOT_RUNNING)
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

static BACKEND: impress_service_core::BackendSlot<dyn ImploreBackend> =
    impress_service_core::BackendSlot::new();

/// Install a backend at process startup. First call wins.
pub fn register_backend(backend: Box<dyn ImploreBackend>) {
    BACKEND.install(std::sync::Arc::from(backend));
}

/// Uninstall the current backend: dispatch returns to the default
/// implementation. Called by the reachability probe when the app stops
/// answering — see [`impress_service_core::BackendSlot`].
pub fn clear_backend() {
    BACKEND.clear();
}

pub fn has_custom_backend() -> bool {
    BACKEND.is_installed()
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
            /// Recorded on the figure as its dataset. With inline data, any
            /// short label for the data's source (e.g. "inline").
            dataset_id: String,
            /// Styles `series`: scatter, line, line-scatter, bar (or
            /// histogram), step; anything else draws lines. Ignored for
            /// `spec` and `svg`.
            plot_type: String,
            /// X-axis label (a dataset column name). Ignored for `spec`/`svg`.
            x: String,
            /// Y-axis label (a dataset column name). Ignored for `spec`/`svg`.
            y: Option<String>,
            /// The figure's name in implore (default "Untitled Figure").
            name: Option<String>,
            /// Inline data: a list of 1-32 series, each {"label"?: string,
            /// "x": [numbers], "y": [numbers]} with x and y the same length
            /// (at least 1; at most 50000 points over all series). Drawn in
            /// the style `plot_type` names; two or more series get a legend.
            /// Give at most one of series, spec and svg.
            ///
            /// CLI: repeat the flag, one JSON object per series:
            /// --series '{"label":"a","x":[1,2,3],"y":[2,4,9]}'
            /// --series '{"label":"b","x":[1,2,3],"y":[1,1,2]}'
            series: Option<FigureSeriesArg>,
            /// A whole implore plot spec, for what inline series cannot say:
            /// error bars, log axes, axis ranges, per-series style and
            /// colour, reference lines. Only series[].x and series[].y are
            /// required; the rest defaults (640x400 points, grid on, legend
            /// top right, lines in the colour cycle). Replaces plot_type, x
            /// and y. Enum values are capitalised: style Line | Scatter |
            /// LineScatter | Bar | Step. Give at most one of series, spec and
            /// svg.
            ///
            /// CLI: one JSON object, e.g. --spec '{"title":"decay",
            /// "x_axis":{"label":"t (s)"},"y_axis":{"label":"flux",
            /// "log_scale":true},"series":[{"label":"run 1","x":[0,1,2],
            /// "y":[1,0.5,0.25],"style":"LineScatter","error_low":[0.05,0.05,0.05],
            /// "error_high":[0.05,0.05,0.05]}]}'
            spec: Option<PlotSpecArg>,
            /// A finished SVG document (at most 2 MB, at most 4096 points a
            /// side), stored as-is: rasterised to a 2x PNG on white. Use it
            /// for a plot drawn elsewhere, e.g. the SVG `plot-series` returns.
            /// Replaces plot_type, x and y. Give at most one of series, spec
            /// and svg.
            ///
            /// CLI: --svg "$(cat plot.svg)"
            svg: Option<String>
        ) -> CreateFigureOutcome,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn create_figure_tool() -> &'static impress_service_core::McpToolDescriptor {
        impress_service_core::McpToolDescriptor::iter()
            .find(|t| t.name == "implore-service_create-figure")
            .expect("create-figure is in the inventory")
    }

    fn schema() -> Value {
        (create_figure_tool().input_schema)()
    }

    fn call(args: Value) -> Value {
        impress_service_core::runtime::block_on((create_figure_tool().handler)(args)).unwrap()
    }

    fn base() -> Value {
        json!({"dataset_id": "inline", "plot_type": "scatter", "x": "t", "y": "f", "name": null,
               "series": null, "spec": null, "svg": null})
    }

    #[test]
    fn the_input_schema_describes_each_data_argument() {
        let s = schema();
        let props = &s["properties"];
        // series: a nullable array of {label?, x, y}, inline (no $ref), so
        // the CLI makes it a repeatable flag taking a JSON object each.
        assert_eq!(props["series"]["type"], json!(["array", "null"]));
        assert_eq!(props["series"]["maxItems"], json!(32));
        let item = &props["series"]["items"];
        assert_eq!(item["required"], json!(["x", "y"]));
        assert_eq!(item["additionalProperties"], json!(false));
        assert_eq!(item["properties"]["x"]["items"]["type"], json!("number"));
        assert!(props["series"]["description"]
            .as_str()
            .unwrap()
            .contains("--series '{\"label\":\"a\""));
        // spec: a nullable object with the PlotSpec fields spelled out.
        assert_eq!(props["spec"]["type"], json!(["object", "null"]));
        assert_eq!(
            props["spec"]["properties"]["series"]["items"]["properties"]["style"]["enum"],
            json!(["Line", "Scatter", "LineScatter", "Bar", "Step"])
        );
        assert!(props["spec"]["description"]
            .as_str()
            .unwrap()
            .contains("--spec '"));
        assert!(props["svg"]["description"]
            .as_str()
            .unwrap()
            .contains("2 MB"));
        // The data arguments are optional; the old ones keep their shape.
        let required: Vec<&str> = s["required"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert_eq!(required, vec!["dataset_id", "plot_type", "x"]);
        let desc = create_figure_tool().description;
        assert!(
            desc.contains("EMPTY AXES"),
            "the no-data behaviour is stated"
        );
        assert!(desc.contains("Example (CLI): impress create-figure"));
    }

    /// Every example the descriptions show is one the validator accepts:
    /// the hand-written schema and the Rust rules cannot drift silently.
    #[test]
    fn the_documented_examples_validate() {
        let series = json!([{"label": "run 1", "x": [0, 1, 2, 3], "y": [1.0, 0.61, 0.37, 0.22]}]);
        let spec = json!({"title": "decay", "x_axis": {"label": "t (s)"},
        "y_axis": {"label": "flux", "log_scale": true},
        "series": [{"label": "run 1", "x": [0, 1, 2], "y": [1, 0.5, 0.25],
                    "style": "LineScatter", "error_low": [0.05, 0.05, 0.05],
                    "error_high": [0.05, 0.05, 0.05]}],
        "legend": {"position": "BottomLeft", "visible": true},
        "annotations": [
            {"HLine": {"y": 0.5, "label": "half", "color": "Gray", "dash": true}},
            {"VLine": {"x": 2, "label": null, "color": {"Rgb": [200, 0, 0]}, "dash": false}}
        ]});
        let s = FigureSeriesArg(series);
        let p = PlotSpecArg(spec);
        assert_eq!(
            validate_figure_data(Some(&s), None, None)
                .unwrap()
                .unwrap()
                .key(),
            "series"
        );
        assert_eq!(
            validate_figure_data(None, Some(&p), None)
                .unwrap()
                .unwrap()
                .key(),
            "spec"
        );
    }

    #[test]
    fn the_default_service_names_a_bad_call_before_saying_implore_is_closed() {
        let mut args = base();
        args["series"] = json!([{"x": [1, 2], "y": [1]}]);
        args["svg"] = json!("<svg/>");
        let out = call(args);
        assert_eq!(out["ok"], json!(false));
        assert_eq!(
            out["error"],
            json!("create-figure refused: give at most one of series, spec and svg; got series and svg")
        );

        let mut args = base();
        args["series"] = json!([{"x": [1, 2], "y": [1]}]);
        assert_eq!(
            call(args)["error"],
            json!("create-figure refused: series[0]: x has 2 values but y has 1")
        );

        let mut args = base();
        args["series"] = json!([{"x": [1], "y": [1]}]);
        let out = call(args);
        assert_eq!(out["ok"], json!(false));
        assert!(out["error"]
            .as_str()
            .unwrap()
            .starts_with("implore is not running"));
        assert!(out.get("id").is_none(), "no figure fields on a refusal");
    }

    #[test]
    fn a_success_flattens_the_figure_as_before() {
        let out = CreateFigureOutcome {
            ok: true,
            error: None,
            figure: Some(FigureRecord {
                id: "F".into(),
                name: "n".into(),
                dataset_id: Some("d".into()),
                created_at: None,
            }),
            artifact: None,
            drawn_from: Some("series".into()),
        };
        let v = serde_json::to_value(out).unwrap();
        assert_eq!(v["id"], json!("F"));
        assert_eq!(v["ok"], json!(true));
        assert!(v.get("error").is_none());
    }
}
