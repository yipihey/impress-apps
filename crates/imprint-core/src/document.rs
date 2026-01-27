//! CRDT-based document representation for collaborative editing
//!
//! This module provides the core `ImprintDocument` type which uses Automerge CRDTs
//! to enable conflict-free collaborative editing of academic documents.
//!
//! # Features
//!
//! - **Conflict-free merging**: Multiple users can edit simultaneously without conflicts
//! - **Offline support**: Changes can be made offline and synced later
//! - **History tracking**: Full document history with undo/redo support
//! - **Structured content**: Rich document model with sections, paragraphs, and inline elements
//! - **Edit modes**: Three editing modes (DirectPdf, SplitView, TextOnly) for different workflows
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
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::document::{ImprintDocument, EditMode};
//!
//! let mut doc = ImprintDocument::new();
//! doc.insert_text(0, "Hello, academic world!");
//!
//! // Cycle through edit modes
//! doc.cycle_edit_mode();
//! ```

use crate::selection::{Selection, SelectionSet};
use crate::sourcemap::{RenderPosition, SourceMap};
use crate::transaction::Transaction;
use automerge::transaction::Transactable;
use automerge::{AutoCommit, ObjType, ReadDoc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Errors that can occur during document operations
#[derive(Debug, Error)]
pub enum DocumentError {
    /// Error from the Automerge CRDT layer
    #[error("Automerge error: {0}")]
    Automerge(#[from] automerge::AutomergeError),

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

/// A CRDT-based document for collaborative academic writing
///
/// `ImprintDocument` wraps an Automerge document to provide a high-level API
/// for creating and editing academic documents with real-time collaboration support.
pub struct ImprintDocument {
    /// The underlying Automerge document
    doc: AutoCommit,
    /// Document metadata
    metadata: DocumentMetadata,
    /// Object ID for the content text
    content_id: Option<automerge::ObjId>,
    /// Current selections (supports multi-cursor)
    selections: SelectionSet,
    /// Current edit mode
    edit_mode: EditMode,
    /// Source map for rendered output (when available)
    source_map: Option<SourceMap>,
}

impl ImprintDocument {
    /// Create a new empty document
    pub fn new() -> Self {
        let mut doc = AutoCommit::new();

        // Initialize the document structure
        let content_id = doc
            .put_object(automerge::ROOT, "content", ObjType::Text)
            .expect("failed to create content object in new document");
        doc.put_object(automerge::ROOT, "citations", ObjType::List)
            .expect("failed to create citations list in new document");

        Self {
            doc,
            metadata: DocumentMetadata::default(),
            content_id: Some(content_id),
            selections: SelectionSet::new(),
            edit_mode: EditMode::default(),
            source_map: None,
        }
    }

    /// Create a document from existing Automerge bytes
    pub fn from_bytes(bytes: &[u8]) -> DocumentResult<Self> {
        let doc = AutoCommit::load(bytes)?;

        // Try to get the content object ID
        let content_id = doc
            .get(automerge::ROOT, "content")
            .ok()
            .flatten()
            .map(|(_value, id)| id);

        Ok(Self {
            doc,
            metadata: DocumentMetadata::default(),
            content_id,
            selections: SelectionSet::new(),
            edit_mode: EditMode::default(),
            source_map: None,
        })
    }

    /// Export the document to bytes for storage or sync
    pub fn to_bytes(&mut self) -> Vec<u8> {
        self.doc.save()
    }

    /// Get the document metadata
    pub fn metadata(&self) -> &DocumentMetadata {
        &self.metadata
    }

    /// Set the document title
    pub fn set_title(&mut self, title: impl Into<String>) {
        self.metadata.title = title.into();
        self.metadata.modified_at = chrono::Utc::now().timestamp_millis();
    }

    /// Get the full text content of the document
    pub fn text(&self) -> DocumentResult<String> {
        if let Some(ref content_id) = self.content_id {
            Ok(self.doc.text(content_id)?)
        } else {
            Ok(String::new())
        }
    }

    /// Insert text at the given position
    pub fn insert_text(&mut self, pos: usize, text: &str) -> DocumentResult<()> {
        if let Some(ref content_id) = self.content_id {
            self.doc.splice_text(content_id, pos, 0, text)?;
            self.metadata.modified_at = chrono::Utc::now().timestamp_millis();
        }
        Ok(())
    }

    /// Delete text in the given range
    pub fn delete_text(&mut self, pos: usize, len: usize) -> DocumentResult<()> {
        if let Some(ref content_id) = self.content_id {
            self.doc.splice_text(content_id, pos, len as isize, "")?;
            self.metadata.modified_at = chrono::Utc::now().timestamp_millis();
        }
        Ok(())
    }

    /// Get changes since a given set of heads (for sync)
    pub fn get_changes_since(&mut self, heads: &[automerge::ChangeHash]) -> Vec<u8> {
        self.doc.save_after(heads)
    }

    /// Merge changes from another document
    pub fn merge(&mut self, other: &mut ImprintDocument) -> DocumentResult<()> {
        self.doc.merge(&mut other.doc)?;
        self.metadata.modified_at = chrono::Utc::now().timestamp_millis();
        Ok(())
    }

    /// Apply incremental changes from a sync message
    pub fn apply_changes(&mut self, changes: &[u8]) -> DocumentResult<()> {
        self.doc.load_incremental(changes)?;
        self.metadata.modified_at = chrono::Utc::now().timestamp_millis();
        Ok(())
    }

    /// Get the current heads (for sync state tracking)
    pub fn heads(&mut self) -> Vec<automerge::ChangeHash> {
        self.doc.get_heads()
    }

    // =========================================================================
    // Selection Methods
    // =========================================================================

    /// Get the current selections.
    pub fn selections(&self) -> &SelectionSet {
        &self.selections
    }

    /// Set the selections (for multi-cursor support).
    pub fn set_selections(&mut self, selections: SelectionSet) {
        self.selections = selections;
    }

    /// Get the primary selection.
    pub fn primary_selection(&self) -> Selection {
        self.selections.primary()
    }

    /// Set a single selection (convenience method).
    pub fn set_selection(&mut self, selection: Selection) {
        self.selections = SelectionSet::single(selection);
    }

    /// Move cursor to a position.
    pub fn move_cursor(&mut self, pos: usize) {
        self.selections.replace(Selection::cursor(pos));
    }

    // =========================================================================
    // Edit Mode Methods
    // =========================================================================

    /// Get the current edit mode.
    pub fn edit_mode(&self) -> &EditMode {
        &self.edit_mode
    }

    /// Set the edit mode.
    pub fn set_edit_mode(&mut self, mode: EditMode) {
        self.edit_mode = mode;
    }

    /// Cycle to the next edit mode.
    pub fn cycle_edit_mode(&mut self) {
        self.edit_mode = self.edit_mode.cycle();
    }

    // =========================================================================
    // Source Map Methods
    // =========================================================================

    /// Get the source map for the rendered output.
    pub fn source_map(&self) -> Option<&SourceMap> {
        self.source_map.as_ref()
    }

    /// Get a mutable reference to the source map.
    pub fn source_map_mut(&mut self) -> Option<&mut SourceMap> {
        self.source_map.as_mut()
    }

    /// Update the source map after compilation.
    pub fn update_source_map(&mut self, map: SourceMap) {
        self.source_map = Some(map);
    }

    /// Clear the source map (e.g., when source has changed significantly).
    pub fn clear_source_map(&mut self) {
        self.source_map = None;
    }

    // =========================================================================
    // Transaction Methods
    // =========================================================================

    /// Apply a transaction to the document.
    ///
    /// This is the primary way to make changes to the document. Transactions
    /// provide atomic changes, undo support, and CRDT compatibility.
    pub fn apply(&mut self, txn: Transaction) -> DocumentResult<()> {
        // Apply each operation in the transaction
        for op in txn.operations() {
            match op {
                crate::transaction::Operation::Insert { pos, text } => {
                    self.insert_text(*pos, text)?;
                }
                crate::transaction::Operation::Delete { range, .. } => {
                    self.delete_text(range.start, range.end - range.start)?;
                }
            }
        }

        // Update selections to the transaction's final state
        self.selections = txn.selection_after().clone();

        // Invalidate source map for affected regions
        if let Some(ref mut map) = self.source_map {
            for op in txn.operations() {
                match op {
                    crate::transaction::Operation::Insert { pos, text } => {
                        map.invalidate(*pos..*pos + text.len());
                    }
                    crate::transaction::Operation::Delete { range, .. } => {
                        map.invalidate(range.clone());
                    }
                }
            }
        }

        Ok(())
    }

    /// Create a transaction for the current selection state.
    ///
    /// Use this to start building a transaction that will be applied later.
    pub fn begin_transaction(&self) -> Transaction {
        Transaction::new(self.selections.clone())
    }
}

impl Default for ImprintDocument {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_document() {
        let doc = ImprintDocument::new();
        assert!(doc.text().unwrap().is_empty());
    }

    #[test]
    fn test_insert_text() {
        let mut doc = ImprintDocument::new();
        doc.insert_text(0, "Hello, world!").unwrap();
        assert_eq!(doc.text().unwrap(), "Hello, world!");
    }

    #[test]
    fn test_roundtrip() {
        let mut doc = ImprintDocument::new();
        doc.insert_text(0, "Test content").unwrap();

        let bytes = doc.to_bytes();
        let loaded = ImprintDocument::from_bytes(&bytes).unwrap();
        assert_eq!(loaded.text().unwrap(), "Test content");
    }
}
