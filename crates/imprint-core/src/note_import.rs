//! Import annotations and notes from PDF readers
//!
//! This module provides functionality to import highlights, annotations, and notes
//! from PDF reading applications (particularly imbib) into imprint documents.
//!
//! # Features
//!
//! - **Annotation import**: Import PDF highlights and annotations
//! - **Note conversion**: Convert annotations to document content
//! - **Citation linking**: Automatically link imported notes to their source publications
//! - **Batch import**: Import annotations from multiple PDFs at once
//!
//! # Supported Formats
//!
//! - imbib annotations (via `academic-domain::Annotation`)
//! - Standard PDF annotations (highlights, notes, underlines)
//! - Markdown export from various PDF readers
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::note_import::{NoteImporter, ImportOptions};
//! use impress_domain::Annotation;
//!
//! let importer = NoteImporter::new();
//! let annotations = vec![/* annotations from imbib */];
//! let content = importer.import_annotations(&annotations, &options)?;
//! ```

use impress_domain::{Annotation, AnnotationType, Publication};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Errors that can occur during note import
#[derive(Debug, Error)]
pub enum ImportError {
    /// Invalid annotation format
    #[error("Invalid annotation format: {0}")]
    InvalidFormat(String),

    /// Missing required field
    #[error("Missing required field: {0}")]
    MissingField(String),

    /// Publication not found for linking
    #[error("Publication not found: {0}")]
    PublicationNotFound(String),
}

/// Result type for import operations
pub type ImportResult<T> = Result<T, ImportError>;

/// Options for controlling the import process
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportOptions {
    /// Whether to include the original text of highlights
    pub include_highlight_text: bool,

    /// Whether to include page numbers
    pub include_page_numbers: bool,

    /// Whether to group annotations by type
    pub group_by_type: bool,

    /// Whether to add citation references
    pub add_citations: bool,

    /// Custom header to add before imported content
    pub header: Option<String>,

    /// Format for date/time stamps
    pub date_format: String,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self {
            include_highlight_text: true,
            include_page_numbers: true,
            group_by_type: false,
            add_citations: true,
            header: None,
            date_format: "%Y-%m-%d".to_string(),
        }
    }
}

/// An imported note ready for insertion into a document
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportedNote {
    /// The text content of the note
    pub content: String,

    /// Source annotation type
    pub annotation_type: AnnotationType,

    /// Page number in the source PDF
    pub page: Option<u32>,

    /// Source publication if known
    pub source_publication: Option<Publication>,

    /// Citation key if available
    pub citation_key: Option<String>,

    /// Original annotation ID for reference
    pub annotation_id: Option<String>,
}

impl ImportedNote {
    /// Create a new imported note from an annotation
    pub fn from_annotation(annotation: &Annotation) -> Self {
        // Use selected_text for highlights, content for notes
        let content = annotation
            .selected_text
            .clone()
            .or_else(|| annotation.content.clone())
            .unwrap_or_default();

        Self {
            content,
            annotation_type: annotation.annotation_type.clone(),
            page: Some(annotation.page_number),
            source_publication: None,
            citation_key: None,
            annotation_id: Some(annotation.id.clone()),
        }
    }

    /// Format the note for document insertion
    pub fn format(&self, options: &ImportOptions) -> String {
        let mut parts = Vec::new();

        // Add content
        if !self.content.is_empty() {
            match self.annotation_type {
                AnnotationType::Highlight => {
                    if options.include_highlight_text {
                        parts.push(format!("> {}", self.content));
                    }
                }
                AnnotationType::Note => {
                    parts.push(self.content.clone());
                }
                AnnotationType::Underline => {
                    if options.include_highlight_text {
                        parts.push(format!("_{}_", self.content));
                    }
                }
                _ => {
                    parts.push(self.content.clone());
                }
            }
        }

        // Add page reference
        if options.include_page_numbers {
            if let Some(page) = self.page {
                parts.push(format!("(p. {})", page));
            }
        }

        // Add citation
        if options.add_citations {
            if let Some(ref key) = self.citation_key {
                parts.push(format!("[@{}]", key));
            }
        }

        parts.join(" ")
    }
}

/// Importer for converting annotations to document content
#[derive(Debug, Default)]
pub struct NoteImporter {
    /// Default options for imports
    default_options: ImportOptions,
}

impl NoteImporter {
    /// Create a new note importer with default options
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a new note importer with custom options
    pub fn with_options(options: ImportOptions) -> Self {
        Self {
            default_options: options,
        }
    }

    /// Import a single annotation
    pub fn import_annotation(&self, annotation: &Annotation) -> ImportResult<ImportedNote> {
        Ok(ImportedNote::from_annotation(annotation))
    }

    /// Import multiple annotations
    pub fn import_annotations(&self, annotations: &[Annotation]) -> ImportResult<Vec<ImportedNote>> {
        annotations.iter().map(|a| self.import_annotation(a)).collect()
    }

    /// Import annotations and format as a single document section
    pub fn import_as_section(
        &self,
        annotations: &[Annotation],
        options: Option<&ImportOptions>,
    ) -> ImportResult<String> {
        let opts = options.unwrap_or(&self.default_options);
        let notes = self.import_annotations(annotations)?;

        let mut output = String::new();

        // Add header if specified
        if let Some(ref header) = opts.header {
            output.push_str(header);
            output.push_str("\n\n");
        }

        if opts.group_by_type {
            // Group by annotation type
            let mut highlights = Vec::new();
            let mut notes_list = Vec::new();
            let mut other = Vec::new();

            for note in &notes {
                match note.annotation_type {
                    AnnotationType::Highlight => highlights.push(note),
                    AnnotationType::Note => notes_list.push(note),
                    _ => other.push(note),
                }
            }

            if !highlights.is_empty() {
                output.push_str("## Highlights\n\n");
                for note in highlights {
                    output.push_str(&note.format(opts));
                    output.push_str("\n\n");
                }
            }

            if !notes_list.is_empty() {
                output.push_str("## Notes\n\n");
                for note in notes_list {
                    output.push_str(&note.format(opts));
                    output.push_str("\n\n");
                }
            }

            if !other.is_empty() {
                output.push_str("## Other Annotations\n\n");
                for note in other {
                    output.push_str(&note.format(opts));
                    output.push_str("\n\n");
                }
            }
        } else {
            // Sequential order
            for note in &notes {
                output.push_str(&note.format(opts));
                output.push_str("\n\n");
            }
        }

        Ok(output.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_domain::{AnnotationColor, Rect};

    fn sample_highlight() -> Annotation {
        Annotation {
            id: "test-id".to_string(),
            publication_id: "pub-123".to_string(),
            page_number: 42,
            annotation_type: AnnotationType::Highlight,
            rects: vec![Rect::new(0.0, 0.0, 100.0, 20.0)],
            color: AnnotationColor::yellow(),
            content: None,
            selected_text: Some("Important finding about X".to_string()),
            created_at: "2024-01-01T00:00:00Z".to_string(),
            modified_at: "2024-01-01T00:00:00Z".to_string(),
            author: None,
        }
    }

    #[test]
    fn test_import_annotation() {
        let importer = NoteImporter::new();
        let annotation = sample_highlight();
        let note = importer.import_annotation(&annotation).unwrap();

        assert_eq!(note.content, "Important finding about X");
        assert_eq!(note.page, Some(42));
    }

    #[test]
    fn test_format_note() {
        let note = ImportedNote {
            content: "Test content".to_string(),
            annotation_type: AnnotationType::Highlight,
            page: Some(10),
            source_publication: None,
            citation_key: Some("smith2023".to_string()),
            annotation_id: None,
        };

        let options = ImportOptions::default();
        let formatted = note.format(&options);

        assert!(formatted.contains("> Test content"));
        assert!(formatted.contains("(p. 10)"));
        assert!(formatted.contains("[@smith2023]"));
    }
}
