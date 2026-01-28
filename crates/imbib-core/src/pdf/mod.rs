//! PDF processing with pdfium-render
//!
//! Provides:
//! - Text extraction for search indexing
//! - Thumbnail generation
//! - Page count and metadata
//! - Heuristic metadata extraction from text

pub mod extract;
pub mod metadata;
pub mod metadata_heuristics;
pub mod thumbnails;

pub use extract::*;
pub use metadata::*;
pub use metadata_heuristics::*;
pub use thumbnails::*;
