//! UniFFI exports for 1D plot rendering.
//!
//! Exposes plot rendering to Swift with multiple backends:
//! - SVG (always available)
//! - kuva SVG (when `kuva` feature enabled)
//! - Typst source + lilaq (always available for source, `lilaq` for compilation)
//! - Histogram computation
//! - Multi-panel grid rendering

use super::svg_render;
use super::types::*;

/// Render a PlotSpec (as JSON) to an SVG string.
///
/// Uses kuva backend if available, otherwise falls back to hand-written SVG.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn render_plot_svg(spec_json: String) -> Result<String, PlotError> {
    let spec: PlotSpec = serde_json::from_str(&spec_json).map_err(|e| PlotError::InvalidSpec {
        message: e.to_string(),
    })?;

    // Try kuva first if available
    if let Some(svg) = super::kuva_render::render_kuva_svg(&spec) {
        return Ok(svg);
    }

    Ok(svg_render::render_svg(&spec))
}

/// Convenience: create a simple line plot SVG directly.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn create_line_plot(
    title: String,
    x: Vec<f64>,
    y: Vec<f64>,
    x_label: String,
    y_label: String,
) -> String {
    svg_render::create_line_plot_svg(&title, &x, &y, &x_label, &y_label)
}

/// Render a PlotSpec to Typst source code (lilaq markup).
///
/// Always available — generates Typst source that can be compiled externally
/// or by the lilaq backend.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn render_plot_typst(spec_json: String) -> Result<String, PlotError> {
    let spec: PlotSpec = serde_json::from_str(&spec_json).map_err(|e| PlotError::InvalidSpec {
        message: e.to_string(),
    })?;
    Ok(super::lilaq_render::plot_spec_to_typst(&spec))
}

/// Render a multi-panel PlotGrid (as JSON) to SVG.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn render_grid_svg(grid_json: String) -> Result<String, PlotError> {
    let grid: PlotGrid = serde_json::from_str(&grid_json).map_err(|e| PlotError::InvalidSpec {
        message: e.to_string(),
    })?;
    Ok(svg_render::render_grid_svg(&grid))
}

/// Compute a histogram from raw data and return SVG.
///
/// - `data`: raw f64 values
/// - `config_json`: JSON-serialized `Histogram1DConfig`
///
/// Returns SVG string of the histogram plot.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn render_histogram_svg(data: Vec<f64>, config_json: String) -> Result<String, PlotError> {
    let config: crate::render::Histogram1DConfig =
        serde_json::from_str(&config_json).map_err(|e| PlotError::InvalidSpec {
            message: e.to_string(),
        })?;

    let result = super::histogram::compute_histogram(&data, &config);
    let spec = super::histogram::histogram_to_plot_spec(&result, &config);
    Ok(svg_render::render_svg(&spec))
}

/// Compute histogram statistics from raw data.
///
/// Returns JSON with bin_edges, counts, density, and statistics.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compute_histogram_stats(data: Vec<f64>, config_json: String) -> Result<String, PlotError> {
    let config: crate::render::Histogram1DConfig =
        serde_json::from_str(&config_json).map_err(|e| PlotError::InvalidSpec {
            message: e.to_string(),
        })?;

    let result = super::histogram::compute_histogram(&data, &config);

    let stats_json = serde_json::json!({
        "bin_edges": result.bin_edges,
        "counts": result.counts,
        "density": result.density,
        "kde_x": result.kde_x,
        "kde_y": result.kde_y,
        "stats": {
            "count": result.stats.count,
            "mean": result.stats.mean,
            "std_dev": result.stats.std_dev,
            "median": result.stats.median,
            "min": result.stats.min,
            "max": result.stats.max,
            "q1": result.stats.q1,
            "q3": result.stats.q3,
        }
    });

    serde_json::to_string(&stats_json).map_err(|e| PlotError::InvalidSpec {
        message: e.to_string(),
    })
}

/// Error type for plot FFI operations.
#[cfg(feature = "uniffi")]
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PlotError {
    #[error("Invalid plot spec: {message}")]
    InvalidSpec { message: String },
}
