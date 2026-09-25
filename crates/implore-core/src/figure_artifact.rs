//! A figure's rendered artifact: the image a `figure` row's `data_hash` names.
//!
//! A store `figure` carries no plot spec. What other apps draw (impress's
//! `plot` pane, the figure View tab) is the PNG under `data_hash` in the
//! workspace's one content-addressed store (`<workspace>/content`, ADR-0030
//! D3). Before this module nothing wrote one: `POST /api/figures` and
//! `create-figure` stored no image, and export was a TODO.
//!
//! Everything that decides what the artifact IS lives here, so implore's
//! HTTP routes, the `create-figure` verb (which reaches implore over HTTP)
//! and implore's own UI all get the same bytes:
//!
//! - [`FigureViewState`] is the JSON implore already keeps per figure
//!   (`LibraryFigure.view_state_snapshot`): `type`, `title`, `width`,
//!   `height`, `xColumn`, `yColumn`, plus optional data: an inline
//!   `series` list, a whole implore [`PlotSpec`] under `spec`, or an
//!   already-rendered `svg` (the plot viewer's output).
//! - [`render_figure`] turns it into SVG (the same renderer as
//!   `render_plot_svg`) and rasterises that to PNG with resvg.
//! - [`store_figure_artifact`] puts the PNG in the CAS and returns the
//!   hash for the row's `data_hash`. The PNG, not the SVG, is the stored
//!   artifact because every viewer can decode it (UIImage cannot decode SVG).
//! - [`export_figure_artifact`] writes a PNG or SVG file with an extension
//!   under `<workspace>/exports/figures/`: the path the `export-figure` verb
//!   promises an agent can open or embed in a manuscript.
//!
//! Rendering is deterministic, so re-storing an unchanged figure yields the
//! same hash and the row upsert is a no-op.

use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use impress_core::blobs::{sha256_hex_bytes, BlobStore};
use resvg::{tiny_skia, usvg};
use serde::Deserialize;

use crate::plot::kuva_render;
use crate::plot::svg_render;
use crate::plot::types::{PlotColor, PlotSeries, PlotSpec, SeriesStyle};

/// Default logical size, matching `POST /api/figures`'s defaults.
pub const DEFAULT_WIDTH: f64 = 800.0;
pub const DEFAULT_HEIGHT: f64 = 600.0;

/// Pixels per logical point in the stored PNG (Retina-sharp in a pane).
pub const RASTER_SCALE: f32 = 2.0;

/// Refuse to allocate a raster larger than this many pixels (~256 MB RGBA).
const MAX_PIXELS: u64 = 8192 * 8192;

/// Why an artifact could not be produced.
#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
pub enum FigureArtifactError {
    #[error("invalid figure view state: {message}")]
    InvalidViewState { message: String },
    #[error("figure render failed: {message}")]
    Render { message: String },
    #[error("figure artifact i/o failed: {message}")]
    Io { message: String },
}

impl From<io::Error> for FigureArtifactError {
    fn from(e: io::Error) -> Self {
        FigureArtifactError::Io {
            message: e.to_string(),
        }
    }
}

fn invalid(message: impl Into<String>) -> FigureArtifactError {
    FigureArtifactError::InvalidViewState {
        message: message.into(),
    }
}

/// One inline data series in a figure's view state.
#[derive(Debug, Clone, Deserialize)]
pub struct ViewSeries {
    #[serde(default)]
    pub label: Option<String>,
    pub x: Vec<f64>,
    pub y: Vec<f64>,
}

/// The per-figure JSON implore keeps (`LibraryFigure.view_state_snapshot`).
///
/// Unknown keys are ignored, so the snapshot can keep carrying whatever else
/// implore stores there.
#[derive(Debug, Default, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FigureViewState {
    #[serde(rename = "type", default)]
    pub plot_type: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub width: Option<f64>,
    #[serde(default)]
    pub height: Option<f64>,
    #[serde(default)]
    pub x_column: Option<String>,
    #[serde(default)]
    pub y_column: Option<String>,
    /// Inline data, drawn in the style `type` names.
    #[serde(default)]
    pub series: Option<Vec<ViewSeries>>,
    /// A complete implore `PlotSpec`; wins over the fields above.
    #[serde(default)]
    pub spec: Option<PlotSpec>,
    /// Already-rendered SVG (implore's plot viewer); wins over everything.
    #[serde(default)]
    pub svg: Option<String>,
}

impl FigureViewState {
    /// Parse a snapshot. An empty string is an empty view state.
    pub fn parse(json: &str) -> Result<Self, FigureArtifactError> {
        if json.trim().is_empty() {
            return Ok(Self::default());
        }
        serde_json::from_str(json).map_err(|e| invalid(e.to_string()))
    }

    /// The plot this view state describes.
    ///
    /// With no data it is still a real figure: its title and axes labelled
    /// with the chosen columns. A figure made against a dataset implore
    /// cannot load (datasets are session-scoped) looks like that, rather
    /// than showing nothing at all.
    pub fn plot_spec(&self) -> PlotSpec {
        if let Some(spec) = &self.spec {
            return spec.clone();
        }
        let style = series_style(self.plot_type.as_deref());
        let mut spec = PlotSpec::new().with_size(
            positive_or(self.width, DEFAULT_WIDTH),
            positive_or(self.height, DEFAULT_HEIGHT),
        );
        spec.title = self.title.clone().filter(|t| !t.is_empty());
        spec.x_axis.label = self.x_column.clone().filter(|c| !c.is_empty());
        spec.y_axis.label = self.y_column.clone().filter(|c| !c.is_empty());
        let series = self.series.as_deref().unwrap_or(&[]);
        spec.legend.visible = series.len() > 1;
        spec.series = series
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let label = s
                    .label
                    .clone()
                    .unwrap_or_else(|| format!("series {}", i + 1));
                PlotSeries::line(s.x.clone(), s.y.clone(), label)
                    .with_style(style)
                    .with_color(PlotColor::from_index(i))
            })
            .collect();
        spec
    }
}

fn positive_or(v: Option<f64>, default: f64) -> f64 {
    v.filter(|v| v.is_finite() && *v > 0.0).unwrap_or(default)
}

/// implore's plot-type vocabulary → a series style. Unknown types draw lines.
pub fn series_style(plot_type: Option<&str>) -> SeriesStyle {
    match plot_type
        .unwrap_or("")
        .to_ascii_lowercase()
        .replace(['-', '_', ' '], "")
        .as_str()
    {
        "scatter" | "points" | "point" => SeriesStyle::Scatter,
        "linescatter" | "linepoints" => SeriesStyle::LineScatter,
        "bar" | "bars" | "histogram" => SeriesStyle::Bar,
        "step" | "steps" => SeriesStyle::Step,
        _ => SeriesStyle::Line,
    }
}

/// SVG for a spec, by the same rule as the `render_plot_svg` export: kuva
/// when compiled in, else implore's own renderer.
pub fn render_spec_svg(spec: &PlotSpec) -> String {
    kuva_render::render_kuva_svg(spec).unwrap_or_else(|| svg_render::render_svg(spec))
}

/// A figure rendered both ways. `width`/`height` are logical points.
#[derive(Debug, Clone)]
pub struct RenderedFigure {
    pub svg: String,
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Render a view state. `size` overrides the logical size (a spec is laid
/// out at that size; a given SVG is scaled to fit it); `scale` is pixels per
/// point in the PNG.
pub fn render_figure(
    view_state: &FigureViewState,
    size: Option<(f64, f64)>,
    scale: f32,
) -> Result<RenderedFigure, FigureArtifactError> {
    let svg = match &view_state.svg {
        Some(svg) if !svg.trim().is_empty() => svg.clone(),
        _ => {
            let mut spec = view_state.plot_spec();
            if let Some((w, h)) = size {
                spec.width = w;
                spec.height = h;
            }
            render_spec_svg(&spec)
        }
    };
    let (png, width, height) = rasterize_svg(&svg, size, scale)?;
    Ok(RenderedFigure {
        svg,
        png,
        width,
        height,
    })
}

/// System fonts, loaded once per process (tens of ms on macOS).
fn font_db() -> Arc<usvg::fontdb::Database> {
    static DB: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    DB.get_or_init(|| {
        let mut db = usvg::fontdb::Database::new();
        db.load_system_fonts();
        // implore's SVG asks for `system-ui, -apple-system, sans-serif`;
        // fontdb resolves only the generic, so point it at a face Apple
        // platforms ship.
        db.set_sans_serif_family("Helvetica");
        Arc::new(db)
    })
    .clone()
}

/// SVG → PNG on a white page. `fit` scales the drawing to fit that logical
/// size (aspect kept); returns the PNG and its logical width and height.
pub fn rasterize_svg(
    svg: &str,
    fit: Option<(f64, f64)>,
    scale: f32,
) -> Result<(Vec<u8>, u32, u32), FigureArtifactError> {
    let opt = usvg::Options {
        fontdb: font_db(),
        ..usvg::Options::default()
    };
    let tree = usvg::Tree::from_str(svg, &opt).map_err(|e| FigureArtifactError::Render {
        message: format!("svg parse: {e}"),
    })?;
    let natural = tree.size();
    let (sw, sh) = (natural.width() as f64, natural.height() as f64);
    let (lw, lh) = match fit {
        Some((w, h)) if w > 0.0 && h > 0.0 => {
            let k = (w / sw).min(h / sh);
            (sw * k, sh * k)
        }
        _ => (sw, sh),
    };
    let scale = if scale.is_finite() && scale > 0.0 {
        scale as f64
    } else {
        1.0
    };
    let px_w = (lw * scale).round().max(1.0) as u32;
    let px_h = (lh * scale).round().max(1.0) as u32;
    if px_w as u64 * px_h as u64 > MAX_PIXELS {
        return Err(FigureArtifactError::Render {
            message: format!("raster {px_w}×{px_h} exceeds the {MAX_PIXELS}-pixel cap"),
        });
    }
    let mut pixmap = tiny_skia::Pixmap::new(px_w, px_h).ok_or(FigureArtifactError::Render {
        message: format!("cannot allocate a {px_w}×{px_h} raster"),
    })?;
    pixmap.fill(tiny_skia::Color::WHITE);
    let transform =
        tiny_skia::Transform::from_scale((px_w as f64 / sw) as f32, (px_h as f64 / sh) as f32);
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    let png = pixmap
        .encode_png()
        .map_err(|e| FigureArtifactError::Render {
            message: format!("png encode: {e}"),
        })?;
    Ok((png, lw.round() as u32, lh.round() as u32))
}

/// What a figure row records about its stored artifact.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct StoredFigureArtifact {
    /// sha256 hex of the PNG: the row's `data_hash`.
    pub data_hash: String,
    /// Always `"png"`: the row's `format`.
    pub format: String,
    /// Logical size in points: the row's `width`/`height`.
    pub width: u32,
    pub height: u32,
}

/// Render a figure's view state and put its PNG in `<workspace>/content`.
pub fn store_figure_artifact(
    workspace_dir: &Path,
    view_state_json: &str,
) -> Result<StoredFigureArtifact, FigureArtifactError> {
    let view_state = FigureViewState::parse(view_state_json)?;
    let rendered = render_figure(&view_state, None, RASTER_SCALE)?;
    let data_hash = BlobStore::for_workspace(workspace_dir).put(&rendered.png)?;
    Ok(StoredFigureArtifact {
        data_hash,
        format: "png".into(),
        width: rendered.width,
        height: rendered.height,
    })
}

/// A file format `export_figure_artifact` writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactFormat {
    Png,
    Svg,
}

impl ArtifactFormat {
    pub fn parse(s: &str) -> Result<Self, FigureArtifactError> {
        match s.trim().to_ascii_lowercase().as_str() {
            "png" => Ok(Self::Png),
            "svg" => Ok(Self::Svg),
            other => Err(invalid(format!(
                "unsupported export format '{other}' (png or svg)"
            ))),
        }
    }

    pub fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Svg => "svg",
        }
    }

    pub fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Svg => "image/svg+xml",
        }
    }
}

/// An exported file.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ExportedFigure {
    pub path: String,
    pub format: String,
    pub mime_type: String,
    /// sha256 hex of the file's bytes.
    pub sha256: String,
    pub byte_count: u64,
    pub width: u32,
    pub height: u32,
}

/// `<workspace>/exports/figures`: where exported figure files go.
pub fn figure_export_dir(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join("exports").join("figures")
}

/// A figure id as a file stem: must be a UUID, written lowercase (the
/// store's own spelling), so an id can never name a path outside the dir.
fn export_stem(figure_id: &str) -> Result<String, FigureArtifactError> {
    uuid::Uuid::parse_str(figure_id.trim())
        .map(|u| u.hyphenated().to_string())
        .map_err(|_| invalid(format!("figure id '{figure_id}' is not a UUID")))
}

/// Render a figure and write `<workspace>/exports/figures/<id>.<ext>`.
///
/// `width`/`height` override the logical size; `scale` is PNG pixels per
/// point (default [`RASTER_SCALE`], so a default PNG export is byte-for-byte
/// the stored artifact).
pub fn export_figure_artifact(
    workspace_dir: &Path,
    figure_id: &str,
    view_state_json: &str,
    format: &str,
    width: Option<f64>,
    height: Option<f64>,
    scale: Option<f64>,
) -> Result<ExportedFigure, FigureArtifactError> {
    let format = ArtifactFormat::parse(format)?;
    let stem = export_stem(figure_id)?;
    let view_state = FigureViewState::parse(view_state_json)?;
    let size = match (width, height) {
        (None, None) => None,
        (w, h) => {
            let spec = view_state.plot_spec();
            Some((positive_or(w, spec.width), positive_or(h, spec.height)))
        }
    };
    let scale = scale
        .filter(|s| s.is_finite() && *s > 0.0)
        .map(|s| s as f32)
        .unwrap_or(RASTER_SCALE);
    let rendered = render_figure(&view_state, size, scale)?;
    let bytes: &[u8] = match format {
        ArtifactFormat::Png => &rendered.png,
        ArtifactFormat::Svg => rendered.svg.as_bytes(),
    };
    let dir = figure_export_dir(workspace_dir);
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{stem}.{}", format.extension()));
    write_atomic(&dir, &path, bytes)?;
    Ok(ExportedFigure {
        path: path.display().to_string(),
        format: format.extension().into(),
        mime_type: format.mime_type().into(),
        sha256: sha256_hex_bytes(bytes),
        byte_count: bytes.len() as u64,
        width: rendered.width,
        height: rendered.height,
    })
}

fn write_atomic(dir: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("export"),
        std::process::id()
    ));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// Remove a figure's exported files (every format). Returns how many went.
pub fn remove_figure_exports(
    workspace_dir: &Path,
    figure_id: &str,
) -> Result<u32, FigureArtifactError> {
    let stem = export_stem(figure_id)?;
    let dir = figure_export_dir(workspace_dir);
    let mut removed = 0;
    for format in [ArtifactFormat::Png, ArtifactFormat::Svg] {
        match fs::remove_file(dir.join(format!("{stem}.{}", format.extension()))) {
            Ok(()) => removed += 1,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(removed)
}

// ── UniFFI surface (implore's Swift maps these; it decides nothing) ─────

/// The exports, named as Swift calls them. A submodule so they can share
/// the names of the Rust functions they wrap (and so the binding lint,
/// which maps `pub fn` names, finds them).
#[cfg(feature = "uniffi")]
pub mod ffi {
    use std::path::Path;

    use super::{ExportedFigure, FigureArtifactError, StoredFigureArtifact};

    /// Render a figure's view state and store its PNG in the workspace CAS.
    #[uniffi::export]
    pub fn store_figure_artifact(
        workspace_dir: String,
        view_state_json: String,
    ) -> Result<StoredFigureArtifact, FigureArtifactError> {
        super::store_figure_artifact(Path::new(&workspace_dir), &view_state_json)
    }

    /// Export a figure to `<workspace>/exports/figures/<id>.<png|svg>`.
    #[uniffi::export]
    pub fn export_figure_artifact(
        workspace_dir: String,
        figure_id: String,
        view_state_json: String,
        format: String,
        width: Option<f64>,
        height: Option<f64>,
        scale: Option<f64>,
    ) -> Result<ExportedFigure, FigureArtifactError> {
        super::export_figure_artifact(
            Path::new(&workspace_dir),
            &figure_id,
            &view_state_json,
            &format,
            width,
            height,
            scale,
        )
    }

    /// Remove a deleted figure's exported files.
    #[uniffi::export]
    pub fn remove_figure_exports(
        workspace_dir: String,
        figure_id: String,
    ) -> Result<u32, FigureArtifactError> {
        super::remove_figure_exports(Path::new(&workspace_dir), &figure_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";

    fn png_size(png: &[u8]) -> (u32, u32) {
        assert!(png.starts_with(PNG_MAGIC), "not a PNG");
        let w = u32::from_be_bytes(png[16..20].try_into().unwrap());
        let h = u32::from_be_bytes(png[20..24].try_into().unwrap());
        (w, h)
    }

    const SCATTER: &str = r#"{"type":"scatter","title":"t","width":400,"height":300,
        "xColumn":"mass","yColumn":"radius",
        "series":[{"label":"a","x":[1,2,3],"y":[2,4,9]}]}"#;

    #[test]
    fn view_state_maps_type_columns_and_series_to_a_spec() {
        let vs = FigureViewState::parse(SCATTER).unwrap();
        let spec = vs.plot_spec();
        assert_eq!(spec.title.as_deref(), Some("t"));
        assert_eq!((spec.width, spec.height), (400.0, 300.0));
        assert_eq!(spec.x_axis.label.as_deref(), Some("mass"));
        assert_eq!(spec.y_axis.label.as_deref(), Some("radius"));
        assert_eq!(spec.series.len(), 1);
        assert_eq!(spec.series[0].style, SeriesStyle::Scatter);
        assert_eq!(spec.series[0].y, vec![2.0, 4.0, 9.0]);
    }

    #[test]
    fn the_router_default_view_state_renders_without_data() {
        // Exactly what `POST /api/figures` stores when given no data.
        let vs = FigureViewState::parse(
            r#"{"type":"scatter","width":800,"height":600,"xColumn":"x","yColumn":"y"}"#,
        )
        .unwrap();
        let r = render_figure(&vs, None, RASTER_SCALE).unwrap();
        assert_eq!((r.width, r.height), (800, 600));
        assert_eq!(png_size(&r.png), (1600, 1200));
        assert!(r.svg.contains("<svg"));
    }

    #[test]
    fn empty_and_unknown_view_state_still_render() {
        let vs = FigureViewState::parse("").unwrap();
        assert!(render_figure(&vs, None, 1.0).is_ok());
        let vs = FigureViewState::parse(r#"{"type":"mystery","extra":{"k":1}}"#).unwrap();
        assert_eq!(vs.plot_spec().width, DEFAULT_WIDTH);
    }

    #[test]
    fn malformed_view_state_is_a_named_error() {
        let err = FigureViewState::parse("{not json").unwrap_err();
        assert!(matches!(err, FigureArtifactError::InvalidViewState { .. }));
    }

    #[test]
    fn a_whole_spec_wins_over_the_simple_fields() {
        let spec = PlotSpec::new()
            .with_title("from spec")
            .with_size(320.0, 200.0);
        let json = serde_json::json!({ "type": "bar", "title": "ignored", "spec": spec });
        let vs = FigureViewState::parse(&json.to_string()).unwrap();
        assert_eq!(vs.plot_spec().title.as_deref(), Some("from spec"));
        let r = render_figure(&vs, None, 1.0).unwrap();
        assert_eq!((r.width, r.height), (320, 200));
    }

    #[test]
    fn a_given_svg_is_rasterised_as_is_and_fits_an_override() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="red"/></svg>"#;
        let vs = FigureViewState {
            svg: Some(svg.into()),
            ..Default::default()
        };
        let r = render_figure(&vs, None, 2.0).unwrap();
        assert_eq!(r.svg, svg);
        assert_eq!(png_size(&r.png), (200, 100));
        let r = render_figure(&vs, Some((400.0, 400.0)), 1.0).unwrap();
        assert_eq!((r.width, r.height), (400, 200), "aspect is kept");
    }

    #[test]
    fn text_is_drawn_so_system_fonts_resolve() {
        // Two renders that differ only in the title must differ in pixels;
        // if no font resolved, text would be dropped and they would match.
        let a = FigureViewState {
            title: Some("Alpha".into()),
            ..Default::default()
        };
        let b = FigureViewState {
            title: Some("Omega Omega".into()),
            ..Default::default()
        };
        let pa = render_figure(&a, None, 1.0).unwrap().png;
        let pb = render_figure(&b, None, 1.0).unwrap().png;
        assert_ne!(pa, pb);
    }

    #[test]
    fn storing_is_content_addressed_and_deterministic() {
        let dir = tempfile::tempdir().unwrap();
        let a = store_figure_artifact(dir.path(), SCATTER).unwrap();
        let b = store_figure_artifact(dir.path(), SCATTER).unwrap();
        assert_eq!(a, b, "same view state, same artifact");
        assert_eq!(a.format, "png");
        assert_eq!((a.width, a.height), (400, 300));
        let blob = BlobStore::for_workspace(dir.path());
        let bytes = blob.get(&a.data_hash).unwrap().unwrap();
        assert_eq!(sha256_hex_bytes(&bytes), a.data_hash);
        assert_eq!(png_size(&bytes), (800, 600));
        assert_eq!(
            fs::read_dir(blob.root()).unwrap().count(),
            1,
            "an unchanged re-store writes nothing new"
        );

        let edited = SCATTER.replace("\"t\"", "\"edited\"");
        let c = store_figure_artifact(dir.path(), &edited).unwrap();
        assert_ne!(c.data_hash, a.data_hash, "an edit is a new artifact");
    }

    #[test]
    fn default_png_export_is_the_stored_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let id = "C563336D-1111-4222-8333-444455556666";
        let stored = store_figure_artifact(dir.path(), SCATTER).unwrap();
        let png = export_figure_artifact(dir.path(), id, SCATTER, "png", None, None, None).unwrap();
        assert_eq!(png.sha256, stored.data_hash);
        assert_eq!(png.mime_type, "image/png");
        assert!(png
            .path
            .ends_with("exports/figures/c563336d-1111-4222-8333-444455556666.png"));
        assert_eq!(fs::read(&png.path).unwrap().len() as u64, png.byte_count);

        let svg = export_figure_artifact(dir.path(), id, SCATTER, "SVG", None, None, None).unwrap();
        assert!(fs::read_to_string(&svg.path).unwrap().contains("<svg"));
        assert_eq!(svg.mime_type, "image/svg+xml");

        let big = export_figure_artifact(
            dir.path(),
            id,
            SCATTER,
            "png",
            Some(1000.0),
            None,
            Some(1.0),
        )
        .unwrap();
        assert_eq!((big.width, big.height), (1000, 300));

        assert_eq!(remove_figure_exports(dir.path(), id).unwrap(), 2);
        assert_eq!(remove_figure_exports(dir.path(), id).unwrap(), 0);
    }

    #[test]
    fn export_refuses_bad_formats_and_non_uuid_ids() {
        let dir = tempfile::tempdir().unwrap();
        let id = "c563336d-1111-4222-8333-444455556666";
        assert!(matches!(
            export_figure_artifact(dir.path(), id, SCATTER, "pdf", None, None, None),
            Err(FigureArtifactError::InvalidViewState { .. })
        ));
        assert!(export_figure_artifact(
            dir.path(),
            "../../etc/x",
            SCATTER,
            "png",
            None,
            None,
            None
        )
        .is_err());
        assert!(remove_figure_exports(dir.path(), "../x").is_err());
    }

    #[test]
    fn plot_types_map_to_styles() {
        assert_eq!(series_style(Some("Scatter")), SeriesStyle::Scatter);
        assert_eq!(series_style(Some("line-scatter")), SeriesStyle::LineScatter);
        assert_eq!(series_style(Some("histogram")), SeriesStyle::Bar);
        assert_eq!(series_style(Some("step")), SeriesStyle::Step);
        assert_eq!(series_style(None), SeriesStyle::Line);
    }
}
