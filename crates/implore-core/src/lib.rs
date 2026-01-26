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
//! - **Plugin**: Data generation system with built-in noise, fractal, and statistical generators
//!
//! # Rendering Modes
//!
//! implore supports three rendering modes, cycled via Tab:
//!
//! - **Science2D**: 2D statistical plots with axes, colormaps, and ECDF marginals
//! - **Box3D**: 3D point cloud viewer with perspective camera
//! - **ArtShader**: Custom shader rendering for artistic visualizations

pub mod automation;
pub mod axis;
pub mod camera;
pub mod colormap;
pub mod dataset;
pub mod error;
pub mod export;
pub mod input;
pub mod library;
pub mod plugin;
pub mod render;
pub mod session;
pub mod spatial;
pub mod sync;
pub mod types;
pub mod view;

pub use automation::*;
pub use axis::*;
pub use camera::*;
pub use colormap::*;
pub use dataset::*;
pub use types::*;
pub use library::{FigureFolder, FigureLibrary, ImprintLink, LibraryFigure};
pub use plugin::{
    DataGenerator, GeneratedData, GeneratedDataFfi, GeneratorCategory, GeneratorError,
    GeneratorErrorFfi, GeneratorMetadata, GeneratorParams, GeneratorRegistry,
    GeneratorRegistryHandle, MetadataEntry, ParameterConstraints, ParameterSpec, ParameterType,
    ParameterValue,
};
pub use session::*;
pub use spatial::*;
pub use sync::{FigureExportData, FigureSyncService, FigureUpdateNotification, SyncResult};
pub use view::*;

// render module exports GPU-specific types, access via render:: prefix

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
