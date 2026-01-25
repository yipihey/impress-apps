//! Citation provider system for flexible reference management
//!
//! This module defines the `CitationProvider` trait and `CitationReference` type
//! for managing citations across different sources (local library, web APIs, etc.).
//!
//! # Features
//!
//! - **Trait-based design**: Implement `CitationProvider` for any citation source
//! - **Citation references**: Lightweight references that can be resolved to full publications
//! - **Async support**: Providers can fetch citations from remote sources
//! - **Caching**: Built-in support for caching resolved citations
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::citations::{CitationProvider, CitationReference};
//!
//! struct LocalLibraryProvider { /* ... */ }
//!
//! impl CitationProvider for LocalLibraryProvider {
//!     fn resolve(&self, reference: &CitationReference) -> Option<Publication> {
//!         // Look up in local library
//!     }
//! }
//! ```

use impress_domain::Publication;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Errors that can occur during citation resolution
#[derive(Debug, Error)]
pub enum CitationError {
    /// Citation not found
    #[error("Citation not found: {0}")]
    NotFound(String),

    /// Provider error
    #[error("Provider error: {0}")]
    ProviderError(String),

    /// Invalid identifier format
    #[error("Invalid identifier: {0}")]
    InvalidIdentifier(String),

    /// Network error (for remote providers)
    #[error("Network error: {0}")]
    NetworkError(String),
}

/// Result type for citation operations
pub type CitationResult<T> = Result<T, CitationError>;

/// A reference to a citation that can be resolved to a full publication
///
/// `CitationReference` represents a lightweight pointer to a publication
/// that can be resolved through a `CitationProvider`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum CitationReference {
    /// Reference by DOI
    Doi(String),

    /// Reference by arXiv ID
    ArXiv(String),

    /// Reference by ISBN
    Isbn(String),

    /// Reference by PubMed ID
    PubMed(String),

    /// Reference by citation key (e.g., "smith2023")
    Key(String),

    /// Reference by internal UUID
    Uuid(String),
}

impl CitationReference {
    /// Create a reference from a DOI
    pub fn from_doi(doi: impl Into<String>) -> Self {
        Self::Doi(doi.into())
    }

    /// Create a reference from a citation key
    pub fn from_key(key: impl Into<String>) -> Self {
        Self::Key(key.into())
    }

    /// Create a reference from an arXiv ID
    pub fn from_arxiv(arxiv: impl Into<String>) -> Self {
        Self::ArXiv(arxiv.into())
    }

    /// Create a reference from an ISBN
    pub fn from_isbn(isbn: impl Into<String>) -> Self {
        Self::Isbn(isbn.into())
    }

    /// Create a reference from a PubMed ID
    pub fn from_pubmed(pmid: impl Into<String>) -> Self {
        Self::PubMed(pmid.into())
    }

    /// Create a reference from an extracted identifier type string
    pub fn from_identifier_type(id_type: &str, value: impl Into<String>) -> Option<Self> {
        let value = value.into();
        match id_type.to_lowercase().as_str() {
            "doi" => Some(Self::Doi(value)),
            "arxiv" => Some(Self::ArXiv(value)),
            "isbn" => Some(Self::Isbn(value)),
            "pmid" | "pubmed" => Some(Self::PubMed(value)),
            _ => None,
        }
    }

    /// Get the reference as a string for display
    pub fn display_string(&self) -> String {
        match self {
            Self::Doi(s) => format!("doi:{}", s),
            Self::ArXiv(s) => format!("arXiv:{}", s),
            Self::Isbn(s) => format!("isbn:{}", s),
            Self::PubMed(s) => format!("pmid:{}", s),
            Self::Key(s) => s.clone(),
            Self::Uuid(s) => format!("uuid:{}", s),
        }
    }

    /// Get the identifier type as a string
    pub fn identifier_type(&self) -> &'static str {
        match self {
            Self::Doi(_) => "doi",
            Self::ArXiv(_) => "arxiv",
            Self::Isbn(_) => "isbn",
            Self::PubMed(_) => "pmid",
            Self::Key(_) => "key",
            Self::Uuid(_) => "uuid",
        }
    }

    /// Get the raw value of the identifier
    pub fn value(&self) -> &str {
        match self {
            Self::Doi(s)
            | Self::ArXiv(s)
            | Self::Isbn(s)
            | Self::PubMed(s)
            | Self::Key(s)
            | Self::Uuid(s) => s,
        }
    }
}

impl std::fmt::Display for CitationReference {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.display_string())
    }
}

/// A provider that can resolve citation references to publications
///
/// Implement this trait to create custom citation sources such as:
/// - Local library databases
/// - Web APIs (CrossRef, Semantic Scholar, etc.)
/// - BibTeX file parsers
/// - Institutional repositories
pub trait CitationProvider: Send + Sync {
    /// Resolve a citation reference to a publication
    ///
    /// Returns `None` if the citation cannot be found or resolved.
    fn resolve(&self, reference: &CitationReference) -> CitationResult<Option<Publication>>;

    /// Search for publications matching a query
    ///
    /// Returns a list of matching publications, which may be empty.
    fn search(&self, query: &str) -> CitationResult<Vec<Publication>> {
        // Default implementation returns empty results
        let _ = query;
        Ok(Vec::new())
    }

    /// Get the provider name for display purposes
    fn name(&self) -> &str;

    /// Check if this provider can potentially resolve the given reference type
    fn supports(&self, reference: &CitationReference) -> bool {
        // Default: support all reference types
        let _ = reference;
        true
    }
}

/// A chain of citation providers that tries each in order
///
/// This allows combining multiple sources (e.g., local library first,
/// then web APIs as fallback).
pub struct CitationProviderChain {
    providers: Vec<Box<dyn CitationProvider>>,
}

impl CitationProviderChain {
    /// Create a new empty provider chain
    pub fn new() -> Self {
        Self {
            providers: Vec::new(),
        }
    }

    /// Add a provider to the chain
    pub fn add_provider(&mut self, provider: impl CitationProvider + 'static) {
        self.providers.push(Box::new(provider));
    }

    /// Resolve a reference, trying each provider in order
    pub fn resolve(&self, reference: &CitationReference) -> CitationResult<Option<Publication>> {
        for provider in &self.providers {
            if provider.supports(reference) {
                if let Ok(Some(pub_)) = provider.resolve(reference) {
                    return Ok(Some(pub_));
                }
            }
        }
        Ok(None)
    }
}

impl Default for CitationProviderChain {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_citation_reference_display() {
        let doi_ref = CitationReference::from_doi("10.1234/example");
        assert_eq!(doi_ref.display_string(), "doi:10.1234/example");

        let key_ref = CitationReference::from_key("smith2023");
        assert_eq!(key_ref.display_string(), "smith2023");
    }

    #[test]
    fn test_citation_reference_equality() {
        let ref1 = CitationReference::from_doi("10.1234/example");
        let ref2 = CitationReference::from_doi("10.1234/example");
        assert_eq!(ref1, ref2);
    }

    #[test]
    fn test_from_identifier_type() {
        let doi = CitationReference::from_identifier_type("doi", "10.1234/test");
        assert!(matches!(doi, Some(CitationReference::Doi(_))));

        let arxiv = CitationReference::from_identifier_type("arxiv", "2301.12345");
        assert!(matches!(arxiv, Some(CitationReference::ArXiv(_))));

        let unknown = CitationReference::from_identifier_type("unknown", "test");
        assert!(unknown.is_none());
    }
}
