//! Imbib integration adapter for reference management
//!
//! This module provides types and interfaces for integrating with imbib,
//! the academic paper library manager. It enables impel to:
//! - Verify references for validity
//! - Search the academic literature
//! - Generate bibliographies
//!
//! # Integration Patterns
//!
//! There are two primary ways to integrate with imbib:
//!
//! ## 1. Via MCP (Recommended for agents)
//!
//! Agents should use the impress-mcp server which provides HTTP-based access
//! to imbib via tools like `imbib_search_library`, `imbib_get_paper`, etc.
//! This is the primary integration path for agent workflows.
//!
//! ## 2. Direct library calls (for native integration)
//!
//! For native macOS/iOS integration, the adapter can be connected to imbib-core
//! directly via Swift interop. This provides lower latency but requires the
//! app to be running in the same process.
//!
//! # Example Agent Workflow
//!
//! ```text
//! 1. Agent creates an escalation asking for paper recommendations
//! 2. Human provides search terms
//! 3. Agent uses imbib_search_library to find papers
//! 4. Agent uses imbib_get_paper to get full details
//! 5. Agent records findings via impart_record_artifact
//! ```

use serde::{Deserialize, Serialize};

use crate::error::Result;

/// Result of verifying a reference
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct VerificationResult {
    /// Whether the reference is valid
    pub is_valid: bool,
    /// Confidence score (0.0-1.0)
    pub confidence: f64,
    /// Any issues found
    pub issues: Vec<String>,
    /// Suggested corrections
    pub suggestions: Vec<String>,
}

/// A search result from literature search
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SearchResult {
    /// Title of the work
    pub title: String,
    /// Authors
    pub authors: Vec<String>,
    /// Year of publication
    pub year: Option<i32>,
    /// DOI if available
    pub doi: Option<String>,
    /// arXiv ID if available
    pub arxiv_id: Option<String>,
    /// Abstract or summary
    pub abstract_text: Option<String>,
    /// Relevance score
    pub relevance: f64,
}

/// A reference for citation
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Reference {
    /// Citation key (e.g., "Smith2024")
    pub key: String,
    /// BibTeX entry type (article, book, etc.)
    pub entry_type: String,
    /// Title
    pub title: String,
    /// Authors
    pub authors: Vec<String>,
    /// Year
    pub year: Option<i32>,
    /// Journal or publisher
    pub venue: Option<String>,
    /// DOI
    pub doi: Option<String>,
    /// Full BibTeX string
    pub bibtex: String,
}

/// Adapter for imbib-core integration
pub struct ImbibAdapter {
    // In a full implementation, this would hold a connection
    // to imbib-core or its database
    _private: (),
}

impl ImbibAdapter {
    /// Create a new adapter
    pub fn new() -> Self {
        Self { _private: () }
    }

    /// Verify a reference for validity
    pub fn verify_reference(&self, reference: &Reference) -> Result<VerificationResult> {
        // TODO: Integrate with imbib-core for actual verification
        // For now, return a placeholder result

        let mut issues = Vec::new();
        let mut suggestions = Vec::new();
        let mut confidence: f64 = 1.0;

        // Basic validation
        if reference.title.is_empty() {
            issues.push("Missing title".to_string());
            confidence -= 0.3;
        }

        if reference.authors.is_empty() {
            issues.push("Missing authors".to_string());
            confidence -= 0.2;
        }

        if reference.year.is_none() {
            issues.push("Missing year".to_string());
            suggestions.push("Add publication year".to_string());
            confidence -= 0.1;
        }

        if reference.doi.is_none() && reference.key.contains("arXiv") {
            suggestions.push("Consider adding DOI if published".to_string());
        }

        Ok(VerificationResult {
            is_valid: issues.is_empty(),
            confidence: confidence.max(0.0),
            issues,
            suggestions,
        })
    }

    /// Search for literature
    pub fn search(&self, query: &str, max_results: usize) -> Result<Vec<SearchResult>> {
        // TODO: Integrate with imbib-core search functionality
        // This would connect to ADS, arXiv, CrossRef, etc.

        // For now, return empty results
        Ok(Vec::new())
    }

    /// Check if a reference exists in the library
    pub fn exists(&self, key: &str) -> Result<bool> {
        // TODO: Check imbib database
        Ok(false)
    }

    /// Get a reference by key
    pub fn get_reference(&self, key: &str) -> Result<Option<Reference>> {
        // TODO: Retrieve from imbib database
        Ok(None)
    }

    /// Generate a bibliography for a set of citation keys
    pub fn generate_bibliography(
        &self,
        keys: &[String],
        style: BibliographyStyle,
    ) -> Result<String> {
        // TODO: Use imbib-core to generate formatted bibliography
        Ok(String::new())
    }

    /// Import references from BibTeX
    pub fn import_bibtex(&self, bibtex: &str) -> Result<Vec<Reference>> {
        // TODO: Parse BibTeX and create Reference objects
        Ok(Vec::new())
    }
}

impl Default for ImbibAdapter {
    fn default() -> Self {
        Self::new()
    }
}

/// Bibliography formatting style
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum BibliographyStyle {
    /// American Psychological Association
    Apa,
    /// Modern Language Association
    Mla,
    /// Chicago Manual of Style
    Chicago,
    /// IEEE style
    Ieee,
    /// Nature journal style
    Nature,
    /// Raw BibTeX
    Bibtex,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_adapter_creation() {
        let adapter = ImbibAdapter::new();
        // Just verify it creates successfully
    }

    #[test]
    fn test_verify_valid_reference() {
        let adapter = ImbibAdapter::new();
        let reference = Reference {
            key: "Smith2024".to_string(),
            entry_type: "article".to_string(),
            title: "A Great Paper".to_string(),
            authors: vec!["John Smith".to_string()],
            year: Some(2024),
            venue: Some("Nature".to_string()),
            doi: Some("10.1234/example".to_string()),
            bibtex: String::new(),
        };

        let result = adapter.verify_reference(&reference).unwrap();
        assert!(result.is_valid);
        assert!(result.confidence > 0.9);
    }

    #[test]
    fn test_verify_incomplete_reference() {
        let adapter = ImbibAdapter::new();
        let reference = Reference {
            key: "Unknown".to_string(),
            entry_type: "article".to_string(),
            title: String::new(), // Missing title
            authors: Vec::new(),  // Missing authors
            year: None,
            venue: None,
            doi: None,
            bibtex: String::new(),
        };

        let result = adapter.verify_reference(&reference).unwrap();
        assert!(!result.is_valid);
        assert!(!result.issues.is_empty());
    }
}
