//! 1D plot support — declarative PlotSpec → multi-backend rendering.
//!
//! Provides a data model (`PlotSpec`, `PlotSeries`, `PlotGrid`) and multiple
//! rendering backends:
//!
//! - **svg_render** — Pure-Rust SVG generation (always available)
//! - **kuva_render** — kuva crate for higher-quality output (feature `kuva`)
//! - **lilaq_render** — Typst + lilaq for publication figures (feature `lilaq`)
//! - **histogram** — Histogram computation with KDE and statistics

pub mod histogram;
pub mod kuva_render;
pub mod lilaq_render;
pub mod svg_render;
pub mod types;

#[cfg(feature = "uniffi")]
pub mod ffi;
