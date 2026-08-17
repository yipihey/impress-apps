//! Editing modes and document metadata for imprint.
//!
//! This module used to hold `ImprintDocument`, an Automerge-backed CRDT
//! document that no FFI or app ever wired up. ADR-0027 moved the CRDT layer
//! to `impress-core::collab` (one runtime, one crate, behind the store verbs);
//! what remains here is the live, non-CRDT half — `EditMode` (consumed by
//! `automation.rs`) and `DocumentMetadata`.
//!
//! # Edit Modes
//!
//! imprint supports three editing modes, cycled via Tab:
//!
//! - **Mode A (DirectPdf)**: Direct PDF manipulation (WYSIWYG-like). Users click on the
//!   rendered PDF and edit at that location using the source map.
//! - **Mode B (SplitView)**: Traditional source editor on left, live preview on right.
//!   Best for writing with visual feedback.
//! - **Mode C (TextOnly)**: Full-screen source editor, no preview rendering. Best for
//!   focused writing, lower resource usage, faster typing response.

use crate::sourcemap::RenderPosition;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Errors that can occur during document operations
#[derive(Debug, Error)]
pub enum DocumentError {
    /// Invalid document structure
    #[error("Invalid document structure: {0}")]
    InvalidStructure(String),

    /// Position out of bounds
    #[error("Position {0} is out of bounds (max: {1})")]
    OutOfBounds(usize, usize),
}

/// Result type for document operations
pub type DocumentResult<T> = Result<T, DocumentError>;

/// Editing mode for the document.
///
/// imprint supports three editing modes that can be cycled through with Tab:
///
/// - **DirectPdf**: Click on the PDF to edit at that location (WYSIWYG-like)
/// - **SplitView**: Source editor on left, live preview on right
/// - **TextOnly**: Full-screen source editor, no preview (focus mode)
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum EditMode {
    /// Mode A: Direct PDF manipulation (WYSIWYG-like).
    ///
    /// The user clicks on the rendered PDF, and edits appear at that location.
    /// Uses `SourceMap` to map clicks to source positions.
    DirectPdf {
        /// Current cursor position in the rendered output
        cursor_render_pos: RenderPosition,
        /// Corresponding cursor position in source
        cursor_source_pos: usize,
    },

    /// Mode B: Split source/preview view.
    ///
    /// Traditional editor layout with source on left, live preview on right.
    SplitView {
        /// Scroll position in source (character offset)
        source_scroll: usize,
        /// Current preview page number
        preview_page: u32,
    },

    /// Mode C: Text-only mode (focus mode).
    ///
    /// Full-screen source editor with no preview rendering.
    /// Preview compiles on-demand (Cmd+P) or when switching modes.
    TextOnly {
        /// Scroll position in source (character offset)
        source_scroll: usize,
    },
}

impl EditMode {
    /// Cycle through modes: A (DirectPdf) -> B (SplitView) -> C (TextOnly) -> A
    pub fn cycle(&self) -> Self {
        match self {
            EditMode::DirectPdf {
                cursor_source_pos, ..
            } => EditMode::SplitView {
                source_scroll: *cursor_source_pos,
                preview_page: 1,
            },
            EditMode::SplitView { source_scroll, .. } => EditMode::TextOnly {
                source_scroll: *source_scroll,
            },
            EditMode::TextOnly { source_scroll } => EditMode::DirectPdf {
                cursor_render_pos: RenderPosition::default(),
                cursor_source_pos: *source_scroll,
            },
        }
    }

    /// Check if this mode shows a preview.
    pub fn shows_preview(&self) -> bool {
        !matches!(self, EditMode::TextOnly { .. })
    }

    /// Check if this mode is the direct PDF editing mode.
    pub fn is_direct_pdf(&self) -> bool {
        matches!(self, EditMode::DirectPdf { .. })
    }

    /// Get the source scroll position (if applicable).
    pub fn source_scroll(&self) -> Option<usize> {
        match self {
            EditMode::DirectPdf {
                cursor_source_pos, ..
            } => Some(*cursor_source_pos),
            EditMode::SplitView { source_scroll, .. } => Some(*source_scroll),
            EditMode::TextOnly { source_scroll } => Some(*source_scroll),
        }
    }
}

impl Default for EditMode {
    fn default() -> Self {
        EditMode::SplitView {
            source_scroll: 0,
            preview_page: 1,
        }
    }
}

/// Metadata for an imprint document
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentMetadata {
    /// Document title
    pub title: String,
    /// Document authors (user IDs or names)
    pub authors: Vec<String>,
    /// Creation timestamp (Unix milliseconds)
    pub created_at: i64,
    /// Last modified timestamp (Unix milliseconds)
    pub modified_at: i64,
}

impl Default for DocumentMetadata {
    fn default() -> Self {
        let now = chrono::Utc::now().timestamp_millis();
        Self {
            title: String::new(),
            authors: Vec::new(),
            created_at: now,
            modified_at: now,
        }
    }
}
