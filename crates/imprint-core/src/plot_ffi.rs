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

/// Render `spec` to an SVG figure. Picks vector or raster automatically (unless
/// forced), compiling the generated Typst — and any raster asset — through a
/// fresh persistent engine.
///
/// A fresh renderer per call keeps this stateless (the engine isn't `Sync`); the
/// ~0.5s cold font-load dominates first use. A cached-renderer object is the
/// natural optimization once this is wired into a live editor.
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn render_plot_svg(spec: FfiPlotSpec) -> FfiRenderedPlot {
    let (w, h) = (spec.width.max(32.0), spec.height.max(32.0));
    let plot = build_plot(spec);
    let rasterized = matches!(plot.chosen(), Chosen::Raster);
    let out = plot.render(PlotSize::new(w, h));

    let mut r = PersistentTypstRenderer::new();
    for (path, bytes) in &out.assets {
        r.set_asset(path, bytes.clone());
    }
    match r.render_svg(&out.typst, &RenderOptions::a4()) {
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
}
