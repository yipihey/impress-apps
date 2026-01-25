//! Linked file representation for PDFs and other attachments

use serde::{Deserialize, Serialize};

/// Type of file storage
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum FileStorageType {
    Local,
    ICloud,
    WebDAV,
    S3,
    Url,
}

/// A file linked to a publication (PDF, supplementary material, etc.)
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct LinkedFile {
    pub id: String,
    pub filename: String,
    pub relative_path: Option<String>,
    pub absolute_url: Option<String>,
    pub storage_type: FileStorageType,
    pub mime_type: Option<String>,
    pub file_size: Option<i64>,
    pub checksum: Option<String>,
    pub added_at: Option<String>,
}

impl LinkedFile {
    /// Create a new local file reference
    pub fn new_local(filename: String, relative_path: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            filename,
            relative_path: Some(relative_path),
            absolute_url: None,
            storage_type: FileStorageType::Local,
            mime_type: Some("application/pdf".to_string()),
            file_size: None,
            checksum: None,
            added_at: None,
        }
    }

    /// Create a new URL file reference
    pub fn new_url(filename: String, url: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            filename,
            relative_path: None,
            absolute_url: Some(url),
            storage_type: FileStorageType::Url,
            mime_type: Some("application/pdf".to_string()),
            file_size: None,
            checksum: None,
            added_at: None,
        }
    }

    /// Check if this is a PDF file
    pub fn is_pdf(&self) -> bool {
        self.mime_type
            .as_ref()
            .map(|m| m == "application/pdf")
            .unwrap_or(false)
            || self.filename.to_lowercase().ends_with(".pdf")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_local() {
        let file = LinkedFile::new_local("paper.pdf".to_string(), "papers/paper.pdf".to_string());
        assert_eq!(file.filename, "paper.pdf");
        assert_eq!(file.relative_path, Some("papers/paper.pdf".to_string()));
        assert!(matches!(file.storage_type, FileStorageType::Local));
    }

    #[test]
    fn test_new_url() {
        let file = LinkedFile::new_url(
            "paper.pdf".to_string(),
            "https://arxiv.org/pdf/1234".to_string(),
        );
        assert_eq!(file.filename, "paper.pdf");
        assert_eq!(
            file.absolute_url,
            Some("https://arxiv.org/pdf/1234".to_string())
        );
        assert!(matches!(file.storage_type, FileStorageType::Url));
    }

    #[test]
    fn test_is_pdf() {
        let pdf = LinkedFile::new_local("paper.pdf".to_string(), "paper.pdf".to_string());
        assert!(pdf.is_pdf());

        let mut not_pdf = LinkedFile::new_local("data.csv".to_string(), "data.csv".to_string());
        not_pdf.mime_type = Some("text/csv".to_string());
        assert!(!not_pdf.is_pdf());
    }
}
