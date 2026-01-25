//! implore-core - Core visualization engine for scientific data
//!
//! This crate provides the core functionality for implore, a high-performance,
//! keyboard-driven visualization tool for large-scale scientific datasets.
//!
//! # Key Components
//!
//! - **Dataset**: Data representation with schema, source, and provenance tracking
//! - **ViewState**: Current visualization state (camera, colormap, selection)
//! - **RenderMode**: Science 2D, Box 3D, or Art shader modes
//! - **Session**: Collaborative visualization session management
//! - **Automation**: URL scheme handling for implore:// commands
//!
//! # Rendering Modes
//!
//! implore supports three rendering modes, cycled via Tab:
//!
//! - **Science2D**: 2D statistical plots with axes, colormaps, and ECDF marginals
//! - **Box3D**: 3D point cloud viewer with perspective camera
//! - **ArtShader**: Custom shader rendering for artistic visualizations

pub mod automation;
pub mod dataset;
pub mod session;
pub mod spatial;
pub mod view;

pub use automation::*;
pub use dataset::*;
pub use session::*;
pub use spatial::*;
pub use view::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
