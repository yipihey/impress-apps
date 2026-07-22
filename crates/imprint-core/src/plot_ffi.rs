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
    plot.asset_id = "ffi_plot.png".into();
    for s in spec.series {
        let color = [s.color.r, s.color.g, s.color.b];
        plot = match s.kind {
            FfiSeriesKind::Line => plot.line(s.xs, s.ys, color),
            FfiSeriesKind::Scatter => plot.scatter(s.xs, s.ys, color),
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
    let rasterized = matches!(plot.chosen(), Chosen::Raster);
    let out = plot.render(PlotSize::new(w, h));

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
    let rasterized = matches!(plot.chosen(), Chosen::Raster);
    let out = plot.render(PlotSize::new(w, h));
    FfiPlotSource {
        typst: out.typst,
        rasterized,
        inline_safe: out.assets.is_empty(),
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
        };
        let out = render_plot_svg(spec);
        assert!(out.error.is_none(), "error: {:?}", out.error);
        assert!(out.rasterized, "big-N should raster");
        assert!(out.svg.contains("data:image/png") || out.svg.contains("<image"));
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
}
