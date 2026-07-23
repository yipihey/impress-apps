//! UniFFI surface for native plotting: a declarative plot spec in, a compiled
//! SVG figure out — so Swift (imbib/imprint) can render a plot without touching
//! Typst or the plotting internals.
//!
//! The spec mirrors `impress-plot`'s types as FFI-friendly records/enums
//! (fixed-size arrays and borrowed types aren't UniFFI-able, so colors become
//! `{r,g,b}` and axis limits become `Option<f64>`). Rendering compiles the
//! generated Typst — plus any raster asset the big-N fallback produced — through
//! the persistent engine and returns the first page's SVG.
//!
//! Gated on `typst-render` (the engine + `impress-plot` come with it). The
//! `#[uniffi::export]` attribute is applied only when `uniffi` is also on, so the
//! function stays callable from plain Rust tests.
#![cfg(feature = "typst-render")]

use crate::render::{PersistentTypstRenderer, RenderOptions};
use impress_plot::{Axis, Chosen, Colormap, Plot, PlotSize, Strategy};

#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug)]
pub enum FfiAxisScale {
    Linear,
    Log,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiAxis {
    pub scale: FfiAxisScale,
    /// Manual lower limit; `min` and `max` must both be set to take effect.
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub label: Option<String>,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug)]
pub enum FfiSeriesKind {
    Line,
    Scatter,
    /// Density contours of the points (binned, iso-lined, heatmap underlay).
    Contour,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Copy, Debug)]
pub struct FfiColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiSeries {
    pub kind: FfiSeriesKind,
    pub xs: Vec<f64>,
    pub ys: Vec<f64>,
    pub color: FfiColor,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug)]
pub enum FfiColormap {
    Viridis,
    Magma,
    Plasma,
    Inferno,
    Cividis,
    Turbo,
    Greys,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
#[derive(Clone, Copy, Debug)]
pub enum FfiStrategy {
    Auto,
    Vector,
    Raster,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiPlotSpec {
    pub title: String,
    pub x: FfiAxis,
    pub y: FfiAxis,
    pub series: Vec<FfiSeries>,
    pub strategy: FfiStrategy,
    pub colormap: FfiColormap,
    pub width: f64,
    pub height: f64,
    /// Point count above which `Auto` switches to raster. 0 → default (10 000).
    pub raster_threshold: u32,
    /// Number of contour levels for Contour series. 0 → default (7).
    pub contour_levels: u32,
    /// Inline level labels on contour rings.
    pub contour_labels: bool,
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiRenderedPlot {
    /// First-page SVG of the figure (empty on error).
    pub svg: String,
    /// True when the big-N raster fallback was used.
    pub rasterized: bool,
    /// Non-nil on compile failure.
    pub error: Option<String>,
}

fn to_axis(a: &FfiAxis) -> Axis {
    let mut ax = match a.scale {
        FfiAxisScale::Linear => Axis::linear(),
        FfiAxisScale::Log => Axis::log(),
    };
    if let (Some(min), Some(max)) = (a.min, a.max) {
        ax = ax.with_limits(min, max);
    }
    if let Some(l) = &a.label {
        ax = ax.with_label(l.clone());
    }
    ax
}

fn to_cmap(c: FfiColormap) -> Colormap {
    match c {
        FfiColormap::Viridis => Colormap::Viridis,
        FfiColormap::Magma => Colormap::Magma,
        FfiColormap::Plasma => Colormap::Plasma,
        FfiColormap::Inferno => Colormap::Inferno,
        FfiColormap::Cividis => Colormap::Cividis,
        FfiColormap::Turbo => Colormap::Turbo,
        FfiColormap::Greys => Colormap::Greys,
    }
}

fn to_strategy(s: FfiStrategy) -> Strategy {
    match s {
        FfiStrategy::Auto => Strategy::Auto,
        FfiStrategy::Vector => Strategy::Vector,
        FfiStrategy::Raster => Strategy::Raster,
    }
}

/// Build an `impress-plot` [`Plot`] from an FFI spec.
fn build_plot(spec: FfiPlotSpec) -> Plot {
    let mut plot = Plot::new(to_axis(&spec.x), to_axis(&spec.y)).title(spec.title);
    plot.strategy = to_strategy(spec.strategy);
    plot.cmap = to_cmap(spec.colormap);
    if spec.raster_threshold > 0 {
        plot.raster_threshold = spec.raster_threshold as usize;
    }
    if spec.contour_levels > 0 {
        plot.contour_levels = spec.contour_levels as usize;
    }
    plot.contour_labels = spec.contour_labels;
    plot.asset_id = "ffi_plot.png".into();
    for s in spec.series {
        let color = [s.color.r, s.color.g, s.color.b];
        plot = match s.kind {
            FfiSeriesKind::Line => plot.line(s.xs, s.ys, color),
            FfiSeriesKind::Scatter => plot.scatter(s.xs, s.ys, color),
            FfiSeriesKind::Contour => plot.contour(s.xs, s.ys),
        };
    }
    plot
}

/// The Typst source for a plot, for inserting into a manuscript.
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiPlotSource {
    /// Self-contained Typst for the figure box.
    pub typst: String,
    pub rasterized: bool,
    /// True when the source references no external asset — i.e. it can be
    /// inserted inline and will compile in the manuscript as-is. Vector plots
    /// are inline-safe; raster plots need their PNG materialized as a figure.
    pub inline_safe: bool,
}

thread_local! {
    /// Reused across calls on the same thread so the ~0.5s font load is paid
    /// once, not per render — the difference between a sluggish and a live
    /// interactive panel. The engine isn't `Sync`, so a thread-local (not a
    /// shared object) is the right cache; drive renders from one Swift queue to
    /// keep hitting the same thread.
    static PLOT_RENDERER: std::cell::RefCell<PersistentTypstRenderer> =
        std::cell::RefCell::new(PersistentTypstRenderer::new());
}

/// Render `spec` to an SVG figure. Picks vector or raster automatically (unless
/// forced), compiling the generated Typst — and any raster asset — through a
/// thread-local persistent engine (fast on repeat).
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn render_plot_svg(spec: FfiPlotSpec) -> FfiRenderedPlot {
    let (w, h) = (spec.width.max(32.0), spec.height.max(32.0));
    let plot = build_plot(spec);
    let out = plot.render(PlotSize::new(w, h));
    // Raster if the auto-strategy chose it OR the render produced an image
    // asset (contour plots with a heatmap underlay).
    let rasterized = matches!(plot.chosen(), Chosen::Raster) || !out.assets.is_empty();

    // Render on a page sized to the figure, not an A4 sheet: the trailing
    // `#set page(width: auto, ...)` overrides the renderer's A4 preamble so the
    // SVG viewBox hugs the plot box (right for an inline panel preview). The
    // crate's PlotOutput stays page-policy-free for in-document embedding.
    let figure_source = format!(
        "#set page(width: auto, height: auto, margin: 3pt)\n{}",
        out.typst
    );

    PLOT_RENDERER.with(|cell| {
        let mut r = cell.borrow_mut();
        r.clear_assets();
        for (path, bytes) in &out.assets {
            r.set_asset(path, bytes.clone());
        }
        match r.render_svg(&figure_source, &RenderOptions::a4()) {
            Ok((svgs, _warn, _pages, _map)) => FfiRenderedPlot {
                svg: svgs.into_iter().next().unwrap_or_default(),
                rasterized,
                error: None,
            },
            Err(e) => FfiRenderedPlot {
                svg: String::new(),
                rasterized,
                error: Some(format!("{e:?}")),
            },
        }
    })
}

/// Return the plot's Typst source (for inserting into a manuscript at the
/// cursor). Does not compile — just generates. Check `inline_safe` before
/// inserting: vector plots compile inline; raster plots need their PNG written
/// as a figure first (a follow-up once figures are wired).
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn render_plot_typst(spec: FfiPlotSpec) -> FfiPlotSource {
    let (w, h) = (spec.width.max(32.0), spec.height.max(32.0));
    let plot = build_plot(spec);
    let out = plot.render(PlotSize::new(w, h));
    let rasterized = matches!(plot.chosen(), Chosen::Raster) || !out.assets.is_empty();
    FfiPlotSource {
        typst: out.typst,
        rasterized,
        inline_safe: out.assets.is_empty(),
    }
}

// ===========================================================================
// Figure saving: persist a plot into a manuscript's figures/ dir.
// ===========================================================================

/// Result of saving a plot as a manuscript figure.
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiSavedFigure {
    /// Path relative to the manuscript dir (e.g. "figures/density.png").
    pub rel_path: String,
    /// Ready-to-insert Typst snippet referencing `rel_path`.
    pub typst_snippet: String,
    pub error: Option<String>,
}

/// Save `spec`'s heatmap under `<manuscript_dir>/figures/<name>.png` and
/// return the Typst snippet to insert. Used for RASTER plots (a heatmap PNG
/// can't be inlined as Typst source). The PNG is ONLY the heatmap layer — the
/// snippet keeps the full plot Typst (vector axes, ticks, colorbar) with its
/// `image(...)` pointing at the saved file, so the inserted figure stays
/// crisp and document-cohesive; the manuscript compile resolves it via
/// `CompileOptions.figures_root = manuscript_dir`. Vector plots don't need
/// this — `render_plot_typst` inserts them inline with no file.
///
/// The whole pipeline is Rust-side: render, write, build snippet. `name` is
/// sanitized to `[A-Za-z0-9_-]`; the file is overwritten if present.
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn save_plot_figure(spec: FfiPlotSpec, manuscript_dir: String, name: String) -> FfiSavedFigure {
    let (w, h) = (spec.width.max(32.0), spec.height.max(32.0));
    let title = spec.title.clone();

    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let safe = if safe.is_empty() {
        "plot".to_string()
    } else {
        safe
    };
    let rel_path = format!("figures/{safe}.png");

    // Force the raster path and point its asset id at the figures-relative
    // path, so the generated Typst references image("/figures/<name>.png") —
    // which the manuscript compile resolves under figures_root.
    let mut plot = build_plot(spec);
    plot.strategy = Strategy::Raster;
    plot.asset_id = rel_path.clone();
    let out = plot.render(PlotSize::new(w, h));

    let Some((_, png)) = out.assets.into_iter().next() else {
        return FfiSavedFigure {
            rel_path,
            typst_snippet: String::new(),
            error: Some("Raster render produced no image".into()),
        };
    };

    let dir = std::path::Path::new(&manuscript_dir).join("figures");
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return FfiSavedFigure {
            rel_path,
            typst_snippet: String::new(),
            error: Some(format!("create figures dir: {e}")),
        };
    }
    if let Err(e) = std::fs::write(dir.join(format!("{safe}.png")), &png) {
        return FfiSavedFigure {
            rel_path,
            typst_snippet: String::new(),
            error: Some(format!("write figure: {e}")),
        };
    }

    // Full plot (vector axes + colorbar, raster heatmap) wrapped as a figure.
    // Caption falls back to the sanitized name when the spec has no title.
    let caption = if title.is_empty() {
        safe.clone()
    } else {
        title
    };
    let typst_snippet = format!("#figure(\n[\n{}],\n    caption: [{caption}],\n)", out.typst);
    FfiSavedFigure {
        rel_path,
        typst_snippet,
        error: None,
    }
}

// ===========================================================================
// Real-dataset binding: load numeric columns from a file (CSV today).
// ===========================================================================

/// One numeric column loaded from a data file.
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiDataColumn {
    pub name: String,
    pub values: Vec<f64>,
}

/// The numeric columns of a data file — everything the plot panel needs to bind
/// real x/y series. Non-numeric columns are dropped (they can't be plotted).
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct FfiDataTable {
    pub columns: Vec<FfiDataColumn>,
    pub row_count: u64,
    pub error: Option<String>,
}

/// Load a data file's numeric columns as `[Double]` arrays, reusing implore-io's
/// tested reader (`open_file` → `read_column` → `DataColumn::to_f64`). CSV is
/// wired today (pure Rust); HDF5/FITS are implore-io features with C deps, a
/// follow-up. The whole table is read eagerly — fine for typical CSVs; a
/// schema-first + selective-column path is the big-data optimization.
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn load_data_table(path: String) -> FfiDataTable {
    // `.npz` (numpy) isn't a `DataReader`/`open_file` format — it's a zip of
    // named arrays — so it takes its own path: every 1-D array becomes a column.
    let ext = std::path::Path::new(&path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ext == "npz" {
        return load_npz_table(&path);
    }

    let reader = match implore_io::open_file(&path) {
        Ok(r) => r,
        Err(e) => {
            return FfiDataTable {
                columns: Vec::new(),
                row_count: 0,
                error: Some(format!("{e}")),
            }
        }
    };
    let schema = match reader.read_schema() {
        Ok(s) => s,
        Err(e) => {
            return FfiDataTable {
                columns: Vec::new(),
                row_count: 0,
                error: Some(format!("{e}")),
            }
        }
    };
    let mut columns = Vec::new();
    for col in &schema.columns {
        if !col.dtype.is_numeric() {
            continue;
        }
        if let Ok(data) = reader.read_column(&col.name) {
            if let Some(values) = data.to_f64() {
                columns.push(FfiDataColumn {
                    name: col.name.clone(),
                    values,
                });
            }
        }
    }
    if columns.is_empty() {
        return FfiDataTable {
            columns,
            row_count: schema.num_records as u64,
            error: Some("No numeric columns found in file".into()),
        };
    }
    FfiDataTable {
        columns,
        row_count: schema.num_records as u64,
        error: None,
    }
}

/// Load an `.npz` (numpy zip-of-arrays): every 1-D array becomes a column.
/// Higher-rank arrays are skipped (not a single plottable series).
fn load_npz_table(path: &str) -> FfiDataTable {
    let file = match implore_io::npz_reader::NpzFile::open(path) {
        Ok(f) => f,
        Err(e) => {
            return FfiDataTable {
                columns: Vec::new(),
                row_count: 0,
                error: Some(format!("{e}")),
            }
        }
    };
    let mut columns = Vec::new();
    for name in file.array_names() {
        match file.peek_shape(&name) {
            Ok(shape) if shape.len() == 1 => {
                if let Ok(values) = file.read_1d_f32(&name) {
                    columns.push(FfiDataColumn {
                        name,
                        values: values.into_iter().map(|v| v as f64).collect(),
                    });
                }
            }
            _ => continue,
        }
    }
    if columns.is_empty() {
        return FfiDataTable {
            columns,
            row_count: 0,
            error: Some("No 1-D numeric arrays in .npz".into()),
        };
    }
    let row_count = columns.iter().map(|c| c.values.len()).max().unwrap_or(0) as u64;
    FfiDataTable {
        columns,
        row_count,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn axis(scale: FfiAxisScale) -> FfiAxis {
        FfiAxis {
            scale,
            min: None,
            max: None,
            label: None,
        }
    }

    #[test]
    fn ffi_vector_line_compiles() {
        let xs: Vec<f64> = (0..80).map(|i| i as f64).collect();
        let ys: Vec<f64> = xs.iter().map(|x| x * x).collect();
        let spec = FfiPlotSpec {
            title: "ffi parabola".into(),
            x: axis(FfiAxisScale::Linear),
            y: axis(FfiAxisScale::Linear),
            series: vec![FfiSeries {
                kind: FfiSeriesKind::Line,
                xs,
                ys,
                color: FfiColor {
                    r: 31,
                    g: 111,
                    b: 214,
                },
            }],
            strategy: FfiStrategy::Auto,
            colormap: FfiColormap::Viridis,
            width: 320.0,
            height: 200.0,
            raster_threshold: 0,
            contour_levels: 0,
            contour_labels: true,
        };
        let out = render_plot_svg(spec);
        assert!(out.error.is_none(), "error: {:?}", out.error);
        assert!(!out.rasterized);
        assert!(out.svg.contains("<svg"));
        // Tight page: the figure isn't sitting on an A4 sheet (595pt wide).
        assert!(
            out.svg.contains("width=\"3") || out.svg.contains("width=\"2"),
            "expected a figure-sized page, got: {}",
            &out.svg[..out.svg.find('>').unwrap_or(120).min(out.svg.len())]
        );
    }

    #[test]
    fn ffi_big_n_falls_back_to_raster() {
        let n = 30_000usize;
        let xs: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let ys: Vec<f64> = xs.clone();
        let spec = FfiPlotSpec {
            title: "ffi big-n".into(),
            x: axis(FfiAxisScale::Linear),
            y: axis(FfiAxisScale::Linear),
            series: vec![FfiSeries {
                kind: FfiSeriesKind::Scatter,
                xs,
                ys,
                color: FfiColor { r: 0, g: 0, b: 0 },
            }],
            strategy: FfiStrategy::Auto,
            colormap: FfiColormap::Magma,
            width: 320.0,
            height: 220.0,
            raster_threshold: 0,
            contour_levels: 0,
            contour_labels: true,
        };
        let out = render_plot_svg(spec);
        assert!(out.error.is_none(), "error: {:?}", out.error);
        assert!(out.rasterized, "big-N should raster");
        assert!(out.svg.contains("data:image/png") || out.svg.contains("<image"));
    }

    #[test]
    fn ffi_contour_renders_with_underlay_and_vector_lines() {
        let n = 20_000usize;
        let mut s: u64 = 0xFEED;
        let mut nrm = || {
            let mut g = || {
                s = s.wrapping_mul(6364136223846793005).wrapping_add(1);
                ((s >> 11) as f64) / ((1u64 << 53) as f64)
            };
            let (u1, u2) = (g().max(1e-12), g());
            (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
        };
        let xs: Vec<f64> = (0..n).map(|_| nrm()).collect();
        let ys: Vec<f64> = (0..n).map(|_| 0.6 * nrm()).collect();
        let spec = FfiPlotSpec {
            title: "contour test".into(),
            x: axis(FfiAxisScale::Linear),
            y: axis(FfiAxisScale::Linear),
            series: vec![FfiSeries {
                kind: FfiSeriesKind::Contour,
                xs,
                ys,
                color: FfiColor { r: 0, g: 0, b: 0 },
            }],
            strategy: FfiStrategy::Auto,
            colormap: FfiColormap::Viridis,
            width: 340.0,
            height: 240.0,
            raster_threshold: 0,
            contour_levels: 5,
            contour_labels: true,
        };
        let out = render_plot_svg(spec);
        assert!(out.error.is_none(), "error: {:?}", out.error);
        assert!(out.rasterized, "underlay asset → rasterized");
        // Heatmap underlay (embedded raster) AND vector contour lines.
        assert!(out.svg.contains("data:image/png") || out.svg.contains("<image"));
        assert!(
            out.svg.matches("<path").count() > 10,
            "vector contour paths present"
        );
    }

    #[test]
    fn load_csv_numeric_columns() {
        let dir = std::env::temp_dir();
        let path = dir.join("impress_plot_ffi_test.csv");
        std::fs::write(&path, "x,y,label\n1,10,a\n2,20,b\n3,30,c\n").unwrap();
        let table = load_data_table(path.to_string_lossy().to_string());
        assert!(table.error.is_none(), "error: {:?}", table.error);
        // Numeric x/y kept; non-numeric `label` dropped.
        let names: Vec<&str> = table.columns.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"x") && names.contains(&"y"));
        assert!(!names.contains(&"label"));
        let y = table.columns.iter().find(|c| c.name == "y").unwrap();
        assert_eq!(y.values, vec![10.0, 20.0, 30.0]);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn load_missing_file_errors_cleanly() {
        let table = load_data_table("/nonexistent/nope.csv".into());
        assert!(table.error.is_some());
        assert!(table.columns.is_empty());
    }

    /// The figures vertical end-to-end: save a raster plot into a manuscript
    /// dir, then compile a manuscript whose source contains the returned
    /// snippet with `figures_root` set — the image must resolve and render.
    #[test]
    fn save_figure_and_compile_roundtrip() {
        let n = 30_000usize;
        let xs: Vec<f64> = (0..n).map(|i| (i % 173) as f64).collect();
        let ys: Vec<f64> = (0..n).map(|i| (i % 211) as f64).collect();
        let spec = FfiPlotSpec {
            title: "density map".into(),
            x: axis(FfiAxisScale::Linear),
            y: axis(FfiAxisScale::Linear),
            series: vec![FfiSeries {
                kind: FfiSeriesKind::Scatter,
                xs,
                ys,
                color: FfiColor { r: 0, g: 0, b: 0 },
            }],
            strategy: FfiStrategy::Auto,
            colormap: FfiColormap::Viridis,
            width: 320.0,
            height: 220.0,
            raster_threshold: 0,
            contour_levels: 0,
            contour_labels: true,
        };

        let dir = std::env::temp_dir().join(format!("impress_fig_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mdir = dir.to_string_lossy().to_string();

        let saved = save_plot_figure(spec, mdir.clone(), "density map #1".into());
        assert!(saved.error.is_none(), "save error: {:?}", saved.error);
        assert_eq!(saved.rel_path, "figures/density_map__1.png");
        assert!(dir.join(&saved.rel_path).exists(), "PNG written");
        assert!(saved.typst_snippet.contains("figures/density_map__1.png"));

        // Compile a manuscript containing the snippet, figures_root set.
        let source = format!(
            "= Results\n\nSee the density map.\n\n{}",
            saved.typst_snippet
        );
        let mut r = PersistentTypstRenderer::new();
        r.set_figures_root(Some(&mdir));
        let opts = RenderOptions::a4();
        let (pdf, _map) = r.render_pdf(&source, &opts).expect("compile with figure");
        assert!(pdf.as_pdf().unwrap().starts_with(b"%PDF-"));

        // Negative control: WITHOUT figures_root the image must not resolve.
        let mut r2 = PersistentTypstRenderer::new();
        assert!(
            r2.render_pdf(&source, &opts).is_err(),
            "compile without figures_root should fail to resolve the image"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
