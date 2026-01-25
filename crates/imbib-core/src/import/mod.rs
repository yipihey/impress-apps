//! Import pipelines for various formats

#[cfg(feature = "native")]
pub use crate::conversions::validate_publication;
use crate::conversions::bibtex_entry_to_publication;
pub use crate::domain::{Publication, ValidationSeverity};
use crate::ris::RISEntry;
use thiserror::Error;

/// Import error type
#[derive(uniffi::Error, Error, Debug)]
pub enum ImportError {
    #[error("Parse error: {message}")]
    ParseError { message: String },
    #[error("Invalid format: {message}")]
    InvalidFormat { message: String },
    #[error("Empty input")]
    EmptyInput,
}

/// Detected import format
#[derive(uniffi::Enum, Clone, Debug)]
pub enum ImportFormat {
    BibTeX,
    RIS,
    Auto,
}

/// Result of an import operation
#[derive(uniffi::Record, Clone, Debug)]
pub struct ImportResult {
    pub publications: Vec<Publication>,
    pub warnings: Vec<String>,
    pub errors: Vec<String>,
}

pub(crate) fn detect_format_internal(content: String) -> ImportFormat {
    let trimmed = content.trim();

    // BibTeX starts with @
    if trimmed.starts_with('@') {
        return ImportFormat::BibTeX;
    }

    // RIS starts with TY  -
    if trimmed.starts_with("TY  -") || trimmed.contains("\nTY  -") {
        return ImportFormat::RIS;
    }

    // Try to detect by content patterns
    if trimmed.contains("@article")
        || trimmed.contains("@book")
        || trimmed.contains("@inproceedings")
        || trimmed.contains("@misc")
    {
        return ImportFormat::BibTeX;
    }

    if trimmed.contains("ER  -") || trimmed.contains("AU  -") {
        return ImportFormat::RIS;
    }

    ImportFormat::Auto
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn detect_format(content: String) -> ImportFormat {
    detect_format_internal(content)
}

pub(crate) fn import_bibtex_internal(content: String) -> Result<ImportResult, ImportError> {
    if content.trim().is_empty() {
        return Err(ImportError::EmptyInput);
    }

    let parse_result = crate::bibtex_parse(content).map_err(|e| ImportError::ParseError {
        message: e.to_string(),
    })?;

    let mut publications = Vec::new();
    let mut warnings = Vec::new();

    for entry in parse_result.entries {
        let pub_ = bibtex_entry_to_publication(entry);

        // Collect warnings for incomplete entries
        let validation = validate_publication(&pub_);
        for err in validation {
            if matches!(err.severity, ValidationSeverity::Warning) {
                warnings.push(format!(
                    "{}: {} - {}",
                    pub_.cite_key, err.field, err.message
                ));
            }
        }

        publications.push(pub_);
    }

    // Include parse errors as warnings
    let errors: Vec<String> = parse_result
        .errors
        .iter()
        .map(|e| format!("Line {}: {}", e.line, e.message))
        .collect();

    Ok(ImportResult {
        publications,
        warnings,
        errors,
    })
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn import_bibtex(content: String) -> Result<ImportResult, ImportError> {
    import_bibtex_internal(content)
}

pub(crate) fn import_ris_internal(content: String) -> Result<ImportResult, ImportError> {
    if content.trim().is_empty() {
        return Err(ImportError::EmptyInput);
    }

    let ris_entries: Vec<RISEntry> =
        crate::ris_parse(content).map_err(|e| ImportError::ParseError {
            message: e.to_string(),
        })?;

    let mut publications = Vec::new();
    let mut warnings = Vec::new();

    for ris_entry in ris_entries {
        // Convert RIS to BibTeX first, then to Publication
        let bibtex_entry = crate::ris_to_bibtex(ris_entry.clone());
        let mut pub_ = bibtex_entry_to_publication(bibtex_entry);
        pub_.raw_ris = ris_entry.raw_ris;

        let validation = validate_publication(&pub_);
        for err in validation {
            if matches!(err.severity, ValidationSeverity::Warning) {
                warnings.push(format!(
                    "{}: {} - {}",
                    pub_.cite_key, err.field, err.message
                ));
            }
        }

        publications.push(pub_);
    }

    Ok(ImportResult {
        publications,
        warnings,
        errors: Vec::new(),
    })
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn import_ris(content: String) -> Result<ImportResult, ImportError> {
    import_ris_internal(content)
}

pub(crate) fn import_auto_internal(content: String) -> Result<ImportResult, ImportError> {
    match detect_format(content.clone()) {
        ImportFormat::BibTeX => import_bibtex(content),
        ImportFormat::RIS => import_ris(content),
        ImportFormat::Auto => {
            // Try BibTeX first, then RIS
            import_bibtex(content.clone()).or_else(|_| import_ris(content))
        }
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn import_auto(content: String) -> Result<ImportResult, ImportError> {
    import_auto_internal(content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_format_bibtex() {
        let bibtex = "@article{Test2024, title = {Test}}";
        assert!(matches!(
            detect_format(bibtex.to_string()),
            ImportFormat::BibTeX
        ));
    }

    #[test]
    fn test_detect_format_ris() {
        let ris = "TY  - JOUR\nTI  - Test\nER  - ";
        assert!(matches!(detect_format(ris.to_string()), ImportFormat::RIS));
    }

    #[test]
    fn test_import_bibtex() {
        let bibtex = r#"@article{Smith2024,
            author = {John Smith},
            title = {A Great Paper},
            year = {2024},
            journal = {Nature}
        }"#;
        let result = import_bibtex(bibtex.to_string()).unwrap();
        assert_eq!(result.publications.len(), 1);
        assert_eq!(result.publications[0].cite_key, "Smith2024");
    }

    #[test]
    fn test_import_bibtex_empty() {
        let result = import_bibtex("".to_string());
        assert!(matches!(result, Err(ImportError::EmptyInput)));
    }

    #[test]
    fn test_import_auto_bibtex() {
        let bibtex = "@book{Test2024, title = {Test Book}}";
        let result = import_auto(bibtex.to_string()).unwrap();
        assert_eq!(result.publications.len(), 1);
    }
}
