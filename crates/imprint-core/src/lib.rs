//! Imprint Core - CRDT-based collaborative academic writing
//!
//! This crate provides the core functionality for the imprint academic writing application:
//!
//! - **Document**: CRDT-based document representation with Automerge for conflict-free
//!   collaborative editing
//! - **Selection**: Multi-cursor selection support (Helix-inspired)
//! - **Transaction**: Atomic editing operations with undo/redo and CRDT transform support
//! - **SourceMap**: Bidirectional mapping between Typst source and PDF output for direct
//!   manipulation editing
//! - **LaTeX**: Bidirectional LaTeX ↔ Typst conversion for import/export
//! - **Bibliography**: Citation tracking and management integrated with academic-domain
//!   publication types
//! - **Citations**: Trait-based citation provider system for flexible reference management
//! - **Collaboration**: Real-time sync and presence tracking for multi-user editing
//! - **Note Import**: Import annotations and highlights from PDF readers (imbib)
//! - **Render**: Typst-based document rendering (requires `typst-render` feature)
//!
//! # Edit Modes
//!
//! imprint supports three editing modes (from ADR-001), cycled via Tab:
//!
//! - **Mode A (DirectPdf)**: WYSIWYG-like direct PDF manipulation using source maps
//! - **Mode B (SplitView)**: Traditional source editor with live preview
//! - **Mode C (TextOnly)**: Full-screen source editor for focused writing

pub mod bibliography;
pub mod citations;
pub mod collaboration;
pub mod document;
pub mod latex;
pub mod note_import;
pub mod render;
pub mod selection;
pub mod sourcemap;
pub mod transaction;

pub use bibliography::*;
pub use citations::*;
pub use collaboration::*;
pub use document::*;
pub use latex::*;
pub use note_import::*;
pub use render::*;
pub use selection::*;
pub use sourcemap::*;
pub use transaction::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
