//! Cross-app citation reference type for imbib-imprint integration
//!
//! CitationReference is designed to be passed between apps (via URL schemes,
//! pasteboard, or CloudKit) to enable citation insertion workflows.

use serde::{Deserialize, Serialize};

use crate::{Author, Identifiers};

/// A citation ready for insertion into a document
///
/// This type is designed to be lightweight and serializable for cross-app
/// communication. It contains enough information to:
/// 1. Display a preview to the user
/// 2. Insert a citation marker (@citeKey in Typst)
/// 3. Add the full BibTeX entry to the bibliography
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CitationReference {
    /// The BibTeX citation key (e.g., "smith2024machine")
    pub cite_key: String,

    /// The publication ID in imbib's database
    pub publication_id: String,

    /// Quick-access metadata for display
    pub metadata: CitationMetadata,

    /// Full BibTeX entry for bibliography insertion
    pub bibtex_entry: String,

    /// Optional formatted citation for preview
    /// (e.g., "Smith et al. (2024)")
    pub formatted_preview: Option<String>,
}

/// Essential metadata for citation preview and display
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CitationMetadata {
    /// Publication title
    pub title: String,

    /// Short author string (e.g., "Smith et al.")
    pub authors_short: String,

    /// Full author list
    pub authors: Vec<Author>,

    /// Publication year
    pub year: Option<i32>,

    /// Entry type (article, book, etc.)
    pub entry_type: String,

    /// Journal or venue name
    pub venue: Option<String>,

    /// Key identifiers
    pub identifiers: Identifiers,
}

impl CitationReference {
    /// Create a new citation reference
    pub fn new(
        cite_key: String,
        publication_id: String,
        metadata: CitationMetadata,
        bibtex_entry: String,
    ) -> Self {
        let formatted_preview = Self::generate_preview(&metadata);
        Self {
            cite_key,
            publication_id,
            metadata,
            bibtex_entry,
            formatted_preview: Some(formatted_preview),
        }
    }

    /// Generate a formatted preview string (e.g., "Smith et al. (2024)")
    fn generate_preview(metadata: &CitationMetadata) -> String {
        let year_str = metadata
            .year
            .map(|y| format!(" ({})", y))
            .unwrap_or_default();
        format!("{}{}", metadata.authors_short, year_str)
    }

    /// Get the Typst citation markup
    pub fn to_typst_citation(&self) -> String {
        format!("@{}", self.cite_key)
    }

    /// Get the LaTeX citation markup
    pub fn to_latex_citation(&self) -> String {
        format!("\\cite{{{}}}", self.cite_key)
    }

    /// Serialize to JSON for cross-app transfer
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Deserialize from JSON
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}

impl CitationMetadata {
    /// Create metadata with minimal required fields
    pub fn new(title: String, authors: Vec<Author>, entry_type: String) -> Self {
        let authors_short = Self::generate_short_authors(&authors);
        Self {
            title,
            authors_short,
            authors,
            year: None,
            entry_type,
            venue: None,
            identifiers: Identifiers::default(),
        }
    }

    /// Generate short author string (e.g., "Smith", "Smith & Jones", "Smith et al.")
    fn generate_short_authors(authors: &[Author]) -> String {
        match authors.len() {
            0 => "Unknown".to_string(),
            1 => authors[0].family_name.clone(),
            2 => format!("{} & {}", authors[0].family_name, authors[1].family_name),
            _ => format!("{} et al.", authors[0].family_name),
        }
    }

    /// Builder: set year
    pub fn with_year(mut self, year: i32) -> Self {
        self.year = Some(year);
        self
    }

    /// Builder: set venue
    pub fn with_venue(mut self, venue: String) -> Self {
        self.venue = Some(venue);
        self
    }

    /// Builder: set identifiers
    pub fn with_identifiers(mut self, identifiers: Identifiers) -> Self {
        self.identifiers = identifiers;
        self
    }
}

/// Multiple citations for batch insertion
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CitationBatch {
    /// The citations to insert
    pub citations: Vec<CitationReference>,

    /// Target document ID (for imprint)
    pub target_document_id: Option<String>,

    /// Target position in document (character offset)
    pub target_position: Option<u64>,
}

impl CitationBatch {
    /// Create a new citation batch
    pub fn new(citations: Vec<CitationReference>) -> Self {
        Self {
            citations,
            target_document_id: None,
            target_position: None,
        }
    }

    /// Builder: set target document
    pub fn with_target_document(mut self, document_id: String) -> Self {
        self.target_document_id = Some(document_id);
        self
    }

    /// Builder: set target position
    pub fn with_target_position(mut self, position: u64) -> Self {
        self.target_position = Some(position);
        self
    }

    /// Get all BibTeX entries combined
    pub fn combined_bibtex(&self) -> String {
        self.citations
            .iter()
            .map(|c| c.bibtex_entry.as_str())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    /// Get Typst multi-citation markup
    pub fn to_typst_citation(&self) -> String {
        self.citations
            .iter()
            .map(|c| format!("@{}", c.cite_key))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

// FFI exports
#[cfg(feature = "uniffi")]
mod ffi {
    use super::*;

    /// Create a citation reference from components
    #[uniffi::export]
    pub fn create_citation_reference(
        cite_key: String,
        publication_id: String,
        title: String,
        authors: Vec<Author>,
        year: Option<i32>,
        entry_type: String,
        venue: Option<String>,
        bibtex_entry: String,
    ) -> CitationReference {
        let mut metadata = CitationMetadata::new(title, authors, entry_type);
        if let Some(y) = year {
            metadata = metadata.with_year(y);
        }
        if let Some(v) = venue {
            metadata = metadata.with_venue(v);
        }
        CitationReference::new(cite_key, publication_id, metadata, bibtex_entry)
    }

    /// Convert citation reference to JSON
    #[uniffi::export]
    pub fn citation_reference_to_json(citation: &CitationReference) -> Option<String> {
        citation.to_json().ok()
    }

    /// Parse citation reference from JSON
    #[uniffi::export]
    pub fn citation_reference_from_json(json: String) -> Option<CitationReference> {
        CitationReference::from_json(&json).ok()
    }

    /// Get Typst citation markup
    #[uniffi::export]
    pub fn citation_to_typst(citation: &CitationReference) -> String {
        citation.to_typst_citation()
    }

    /// Get LaTeX citation markup
    #[uniffi::export]
    pub fn citation_to_latex(citation: &CitationReference) -> String {
        citation.to_latex_citation()
    }

    /// Create a citation batch
    #[uniffi::export]
    pub fn create_citation_batch(citations: Vec<CitationReference>) -> CitationBatch {
        CitationBatch::new(citations)
    }

    /// Get combined BibTeX from batch
    #[uniffi::export]
    pub fn citation_batch_combined_bibtex(batch: &CitationBatch) -> String {
        batch.combined_bibtex()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_author() -> Author {
        Author::new("Smith".to_string())
    }

    fn sample_authors() -> Vec<Author> {
        vec![
            Author::new("Smith".to_string()),
            Author::new("Jones".to_string()),
            Author::new("Williams".to_string()),
        ]
    }

    #[test]
    fn test_citation_reference_creation() {
        let metadata = CitationMetadata::new(
            "Machine Learning".to_string(),
            vec![sample_author()],
            "article".to_string(),
        )
        .with_year(2024);

        let citation = CitationReference::new(
            "smith2024machine".to_string(),
            "pub-123".to_string(),
            metadata,
            "@article{smith2024machine, title={Machine Learning}}".to_string(),
        );

        assert_eq!(citation.cite_key, "smith2024machine");
        assert_eq!(citation.formatted_preview, Some("Smith (2024)".to_string()));
    }

    #[test]
    fn test_short_authors_generation() {
        // Single author
        let meta1 = CitationMetadata::new(
            "Title".to_string(),
            vec![Author::new("Smith".to_string())],
            "article".to_string(),
        );
        assert_eq!(meta1.authors_short, "Smith");

        // Two authors
        let meta2 = CitationMetadata::new(
            "Title".to_string(),
            vec![
                Author::new("Smith".to_string()),
                Author::new("Jones".to_string()),
            ],
            "article".to_string(),
        );
        assert_eq!(meta2.authors_short, "Smith & Jones");

        // Three or more authors
        let meta3 = CitationMetadata::new("Title".to_string(), sample_authors(), "article".to_string());
        assert_eq!(meta3.authors_short, "Smith et al.");
    }

    #[test]
    fn test_typst_citation() {
        let metadata = CitationMetadata::new(
            "Title".to_string(),
            vec![sample_author()],
            "article".to_string(),
        );
        let citation = CitationReference::new(
            "smith2024".to_string(),
            "pub-123".to_string(),
            metadata,
            "@article{smith2024}".to_string(),
        );

        assert_eq!(citation.to_typst_citation(), "@smith2024");
    }

    #[test]
    fn test_latex_citation() {
        let metadata = CitationMetadata::new(
            "Title".to_string(),
            vec![sample_author()],
            "article".to_string(),
        );
        let citation = CitationReference::new(
            "smith2024".to_string(),
            "pub-123".to_string(),
            metadata,
            "@article{smith2024}".to_string(),
        );

        assert_eq!(citation.to_latex_citation(), "\\cite{smith2024}");
    }

    #[test]
    fn test_json_roundtrip() {
        let metadata = CitationMetadata::new(
            "Machine Learning".to_string(),
            vec![sample_author()],
            "article".to_string(),
        )
        .with_year(2024);

        let original = CitationReference::new(
            "smith2024".to_string(),
            "pub-123".to_string(),
            metadata,
            "@article{smith2024}".to_string(),
        );

        let json = original.to_json().unwrap();
        let parsed = CitationReference::from_json(&json).unwrap();

        assert_eq!(original, parsed);
    }

    #[test]
    fn test_citation_batch() {
        let metadata1 = CitationMetadata::new(
            "Paper 1".to_string(),
            vec![Author::new("Smith".to_string())],
            "article".to_string(),
        );
        let metadata2 = CitationMetadata::new(
            "Paper 2".to_string(),
            vec![Author::new("Jones".to_string())],
            "article".to_string(),
        );

        let citations = vec![
            CitationReference::new(
                "smith2024".to_string(),
                "pub-1".to_string(),
                metadata1,
                "@article{smith2024}".to_string(),
            ),
            CitationReference::new(
                "jones2024".to_string(),
                "pub-2".to_string(),
                metadata2,
                "@article{jones2024}".to_string(),
            ),
        ];

        let batch = CitationBatch::new(citations).with_target_document("doc-123".to_string());

        assert_eq!(batch.to_typst_citation(), "@smith2024 @jones2024");
        assert_eq!(
            batch.combined_bibtex(),
            "@article{smith2024}\n\n@article{jones2024}"
        );
    }
}
