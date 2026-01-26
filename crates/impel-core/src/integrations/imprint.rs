//! Imprint integration adapter for document management
//!
//! Provides access to imprint-core functionality for:
//! - Document creation
//! - Collaborative editing (CRDT-based)
//! - Export to various formats

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{IntegrationError, Result};

/// Handle to a document in imprint
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DocumentHandle {
    /// Document ID
    pub id: String,
    /// Document title
    pub title: String,
    /// Path to the document file
    pub path: String,
}

/// Status of a document
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DocumentStatus {
    /// Document handle
    pub handle: DocumentHandle,
    /// Current state
    pub state: DocumentState,
    /// Word count
    pub word_count: usize,
    /// Number of citations
    pub citation_count: usize,
    /// Number of figures
    pub figure_count: usize,
    /// Last modified timestamp
    pub last_modified: String,
    /// List of contributors
    pub contributors: Vec<String>,
}

/// State of a document
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum DocumentState {
    /// Document is being drafted
    Draft,
    /// Document is under review
    Review,
    /// Document is finalized
    Final,
    /// Document is published
    Published,
}

/// Request to create a new document
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CreateDocumentRequest {
    /// Document title
    pub title: String,
    /// Document template to use
    pub template: DocumentTemplate,
    /// Initial content (Typst or Markdown)
    pub initial_content: Option<String>,
    /// Parent directory path
    pub directory: String,
}

/// Document template options
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum DocumentTemplate {
    /// Blank document
    Blank,
    /// Research paper template
    ResearchPaper,
    /// Technical report template
    TechnicalReport,
    /// Thesis chapter template
    ThesisChapter,
    /// Conference paper template
    ConferencePaper,
    /// Journal article template
    JournalArticle,
}

/// Export format options
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ExportFormat {
    /// PDF output
    Pdf,
    /// LaTeX source
    Latex,
    /// Typst source
    Typst,
    /// HTML
    Html,
    /// Markdown
    Markdown,
    /// Word document (DOCX)
    Docx,
}

/// An edit operation for a document
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DocumentEdit {
    /// Position in the document
    pub position: usize,
    /// Text to delete (if any)
    pub delete_count: usize,
    /// Text to insert (if any)
    pub insert_text: String,
    /// Editor identifier
    pub editor_id: String,
}

/// A change notification from a document
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DocumentChange {
    /// Document handle
    pub handle: DocumentHandle,
    /// Type of change
    pub change_type: ChangeType,
    /// Description of the change
    pub description: String,
    /// Editor who made the change
    pub editor_id: Option<String>,
}

/// Type of document change
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ChangeType {
    /// Content was modified
    ContentModified,
    /// Citation was added
    CitationAdded,
    /// Citation was removed
    CitationRemoved,
    /// Figure was added
    FigureAdded,
    /// Figure was removed
    FigureRemoved,
    /// Document state changed
    StateChanged,
    /// Document was exported
    Exported,
}

/// Adapter for imprint-core integration
pub struct ImprintAdapter {
    /// Base directory for documents
    base_directory: String,
}

impl ImprintAdapter {
    /// Create a new adapter
    pub fn new(base_directory: String) -> Self {
        Self { base_directory }
    }

    /// Create a new document
    pub fn create_document(&self, request: CreateDocumentRequest) -> Result<DocumentHandle> {
        // TODO: Integrate with imprint-core to create document
        // This would:
        // 1. Create the Typst file with template
        // 2. Initialize CRDT state
        // 3. Return handle

        let id = Uuid::new_v4().to_string();
        let filename = sanitize_filename(&request.title);
        let path = format!("{}/{}/{}.typ", self.base_directory, request.directory, filename);

        Ok(DocumentHandle {
            id,
            title: request.title,
            path,
        })
    }

    /// Get the status of a document
    pub fn document_status(&self, id: &str) -> Result<Option<DocumentStatus>> {
        // TODO: Read document and compute status
        Ok(None)
    }

    /// Apply an edit to a document
    pub fn apply_edit(&self, handle: &DocumentHandle, edit: DocumentEdit) -> Result<()> {
        // TODO: Apply edit via imprint-core CRDT
        // This would merge the edit into the Automerge document
        Ok(())
    }

    /// Export a document to the specified format
    pub fn export(&self, id: &str, format: ExportFormat) -> Result<Vec<u8>> {
        // TODO: Use imprint-core render module

        match format {
            ExportFormat::Pdf => {
                // Would call compile_typst_to_pdf
                Ok(Vec::new())
            }
            ExportFormat::Latex => {
                // Would use latex conversion
                Ok(Vec::new())
            }
            ExportFormat::Typst => {
                // Return raw Typst source
                Ok(Vec::new())
            }
            _ => Ok(Vec::new()),
        }
    }

    /// Get the document content
    pub fn get_content(&self, id: &str) -> Result<String> {
        // TODO: Read document content
        Ok(String::new())
    }

    /// Insert a citation into a document
    pub fn insert_citation(
        &self,
        handle: &DocumentHandle,
        position: usize,
        citation_key: &str,
    ) -> Result<()> {
        // TODO: Insert citation via imprint-core
        // Would format as @citation_key in Typst
        Ok(())
    }

    /// Insert a figure into a document
    pub fn insert_figure(
        &self,
        handle: &DocumentHandle,
        position: usize,
        figure_path: &str,
        caption: &str,
    ) -> Result<()> {
        // TODO: Insert figure via imprint-core
        Ok(())
    }
}

impl Default for ImprintAdapter {
    fn default() -> Self {
        Self::new(".".to_string())
    }
}

/// Sanitize a string for use as a filename
fn sanitize_filename(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else if c.is_whitespace() {
                '-'
            } else {
                '_'
            }
        })
        .collect::<String>()
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_adapter_creation() {
        let adapter = ImprintAdapter::new("/tmp/papers".to_string());
        // Just verify it creates successfully
    }

    #[test]
    fn test_create_document() {
        let adapter = ImprintAdapter::new("/tmp/papers".to_string());
        let request = CreateDocumentRequest {
            title: "My Research Paper".to_string(),
            template: DocumentTemplate::ResearchPaper,
            initial_content: None,
            directory: "drafts".to_string(),
        };

        let handle = adapter.create_document(request).unwrap();
        assert_eq!(handle.title, "My Research Paper");
        assert!(handle.path.contains("my-research-paper"));
    }

    #[test]
    fn test_sanitize_filename() {
        assert_eq!(
            sanitize_filename("My Paper: A Study"),
            "my-paper_-a-study"
        );
        assert_eq!(sanitize_filename("Test123"), "test123");
    }
}
