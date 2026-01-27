//! Citation lookup bridge for imbib-imprint integration
//!
//! This module bridges the gap between imprint's `CitationProvider` trait and
//! imbib's publication database. It provides:
//!
//! - Conversion from `Publication` to `CitationReference` (for cross-app transfer)
//! - A `LocalLibraryCitationProvider` for resolving citations from a local collection
//! - Utilities for creating citation references from search results
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────────┐
//! │                        imprint                                   │
//! │  ┌─────────────────────────────────────────────────────────┐    │
//! │  │   Document    │    Bibliography    │   Citations trait   │    │
//! │  └───────────────┴────────────────────┴─────────────────────┘    │
//! │                              │                                    │
//! │                    citation_lookup.rs (this module)              │
//! │                              │                                    │
//! └──────────────────────────────┼───────────────────────────────────┘
//!                                │
//!                    CrossAppCitationReference
//!                    (impress_domain::CitationReference)
//!                                │
//! ┌──────────────────────────────┼───────────────────────────────────┐
//! │                        imbib                                     │
//! │                              │                                    │
//! │  ┌─────────────────────────────────────────────────────────┐    │
//! │  │   Publications   │   Search Sources   │   Local Library  │    │
//! │  └───────────────────────────────────────────────────────────┘    │
//! └─────────────────────────────────────────────────────────────────┘
//! ```

use std::collections::HashMap;

use impress_domain::{
    Author, CitationMetadata, CitationReference as CrossAppCitationReference, Identifiers,
    Publication,
};

use crate::bibliography::Bibliography;
use crate::citations::{CitationProvider, CitationReference, CitationResult};

// Re-export the cross-app citation reference for convenience
pub use impress_domain::CitationBatch;
pub use impress_domain::CitationReference as CrossAppCitation;

/// Convert a Publication to a cross-app CitationReference
///
/// This creates a `CitationReference` that can be serialized and passed
/// between apps (via URL scheme, pasteboard, or CloudKit).
pub fn publication_to_citation_reference(pub_: &Publication) -> CrossAppCitationReference {
    let bibtex = pub_
        .raw_bibtex
        .clone()
        .unwrap_or_else(|| generate_minimal_bibtex(pub_));

    let metadata = CitationMetadata::new(
        pub_.title.clone(),
        pub_.authors.clone(),
        pub_.entry_type.clone(),
    )
    .with_identifiers(pub_.identifiers.clone());

    let metadata = if let Some(year) = pub_.year {
        metadata.with_year(year)
    } else {
        metadata
    };

    let metadata = if let Some(ref journal) = pub_.journal {
        metadata.with_venue(journal.clone())
    } else if let Some(ref booktitle) = pub_.booktitle {
        metadata.with_venue(booktitle.clone())
    } else {
        metadata
    };

    CrossAppCitationReference::new(pub_.cite_key.clone(), pub_.id.clone(), metadata, bibtex)
}

/// Generate minimal BibTeX from publication fields
fn generate_minimal_bibtex(pub_: &Publication) -> String {
    let mut fields = Vec::new();

    fields.push(format!("  title = {{{}}}", pub_.title));

    if !pub_.authors.is_empty() {
        let authors_str = pub_
            .authors
            .iter()
            .map(|a| a.to_bibtex_format())
            .collect::<Vec<_>>()
            .join(" and ");
        fields.push(format!("  author = {{{}}}", authors_str));
    }

    if let Some(year) = pub_.year {
        fields.push(format!("  year = {{{}}}", year));
    }

    if let Some(ref journal) = pub_.journal {
        fields.push(format!("  journal = {{{}}}", journal));
    }

    if let Some(ref booktitle) = pub_.booktitle {
        fields.push(format!("  booktitle = {{{}}}", booktitle));
    }

    if let Some(ref doi) = pub_.identifiers.doi {
        fields.push(format!("  doi = {{{}}}", doi));
    }

    format!(
        "@{}{{{},\n{}\n}}",
        pub_.entry_type,
        pub_.cite_key,
        fields.join(",\n")
    )
}

/// Convert internal CitationReference to cross-app CitationReference
/// (requires resolving through a provider)
pub fn resolve_to_cross_app_citation(
    reference: &CitationReference,
    provider: &dyn CitationProvider,
) -> CitationResult<Option<CrossAppCitationReference>> {
    match provider.resolve(reference)? {
        Some(pub_) => Ok(Some(publication_to_citation_reference(&pub_))),
        None => Ok(None),
    }
}

/// A citation provider backed by a local collection of publications
///
/// This provider stores publications in memory and can be populated from
/// various sources (BibTeX files, imbib library, etc.).
pub struct LocalLibraryCitationProvider {
    name: String,
    /// Publications indexed by cite key
    by_key: HashMap<String, Publication>,
    /// Publications indexed by DOI
    by_doi: HashMap<String, String>, // DOI -> cite_key
    /// Publications indexed by arXiv ID
    by_arxiv: HashMap<String, String>, // arXiv -> cite_key
    /// Publications indexed by UUID
    by_uuid: HashMap<String, String>, // UUID -> cite_key
}

impl LocalLibraryCitationProvider {
    /// Create a new empty local library provider
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            by_key: HashMap::new(),
            by_doi: HashMap::new(),
            by_arxiv: HashMap::new(),
            by_uuid: HashMap::new(),
        }
    }

    /// Create a provider from a list of publications
    pub fn from_publications(name: impl Into<String>, publications: Vec<Publication>) -> Self {
        let mut provider = Self::new(name);
        for pub_ in publications {
            provider.add_publication(pub_);
        }
        provider
    }

    /// Add a publication to the provider
    pub fn add_publication(&mut self, pub_: Publication) {
        let cite_key = pub_.cite_key.clone();

        // Index by identifiers
        if let Some(ref doi) = pub_.identifiers.doi {
            self.by_doi.insert(doi.to_lowercase(), cite_key.clone());
        }
        if let Some(ref arxiv) = pub_.identifiers.arxiv_id {
            self.by_arxiv.insert(arxiv.to_lowercase(), cite_key.clone());
        }
        self.by_uuid.insert(pub_.id.clone(), cite_key.clone());

        // Store by cite key
        self.by_key.insert(cite_key, pub_);
    }

    /// Remove a publication by cite key
    pub fn remove_publication(&mut self, cite_key: &str) -> Option<Publication> {
        if let Some(pub_) = self.by_key.remove(cite_key) {
            // Clean up indices
            if let Some(ref doi) = pub_.identifiers.doi {
                self.by_doi.remove(&doi.to_lowercase());
            }
            if let Some(ref arxiv) = pub_.identifiers.arxiv_id {
                self.by_arxiv.remove(&arxiv.to_lowercase());
            }
            self.by_uuid.remove(&pub_.id);
            Some(pub_)
        } else {
            None
        }
    }

    /// Get a publication by cite key
    pub fn get(&self, cite_key: &str) -> Option<&Publication> {
        self.by_key.get(cite_key)
    }

    /// Get all publications
    pub fn all_publications(&self) -> impl Iterator<Item = &Publication> {
        self.by_key.values()
    }

    /// Count of publications
    pub fn len(&self) -> usize {
        self.by_key.len()
    }

    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.by_key.is_empty()
    }

    /// Clear all publications
    pub fn clear(&mut self) {
        self.by_key.clear();
        self.by_doi.clear();
        self.by_arxiv.clear();
        self.by_uuid.clear();
    }

    /// Sync with a bibliography (add any missing citations)
    pub fn sync_from_bibliography(&mut self, bibliography: &Bibliography) {
        for entry in bibliography.entries() {
            if !self.by_key.contains_key(&entry.key) {
                self.add_publication(entry.publication.clone());
            }
        }
    }
}

impl CitationProvider for LocalLibraryCitationProvider {
    fn resolve(&self, reference: &CitationReference) -> CitationResult<Option<Publication>> {
        let cite_key = match reference {
            CitationReference::Key(key) => Some(key.clone()),
            CitationReference::Doi(doi) => self.by_doi.get(&doi.to_lowercase()).cloned(),
            CitationReference::ArXiv(arxiv) => self.by_arxiv.get(&arxiv.to_lowercase()).cloned(),
            CitationReference::Uuid(uuid) => self.by_uuid.get(uuid).cloned(),
            CitationReference::Isbn(_) | CitationReference::PubMed(_) => {
                // Linear search for ISBN/PMID (less common)
                self.by_key
                    .values()
                    .find(|p| match reference {
                        CitationReference::Isbn(isbn) => {
                            p.identifiers.isbn.as_ref().map(|i| i.to_lowercase())
                                == Some(isbn.to_lowercase())
                        }
                        CitationReference::PubMed(pmid) => {
                            p.identifiers.pmid.as_ref() == Some(pmid)
                        }
                        _ => false,
                    })
                    .map(|p| p.cite_key.clone())
            }
        };

        Ok(cite_key.and_then(|key| self.by_key.get(&key).cloned()))
    }

    fn search(&self, query: &str) -> CitationResult<Vec<Publication>> {
        let query_lower = query.to_lowercase();
        let results: Vec<Publication> = self
            .by_key
            .values()
            .filter(|pub_| {
                // Search in title, cite key, and authors
                pub_.title.to_lowercase().contains(&query_lower)
                    || pub_.cite_key.to_lowercase().contains(&query_lower)
                    || pub_.authors.iter().any(|a| {
                        a.family_name.to_lowercase().contains(&query_lower)
                            || a.given_name
                                .as_ref()
                                .map(|g| g.to_lowercase().contains(&query_lower))
                                .unwrap_or(false)
                    })
            })
            .cloned()
            .collect();

        Ok(results)
    }

    fn name(&self) -> &str {
        &self.name
    }
}

/// Builder for creating cross-app citations from various inputs
pub struct CitationBuilder {
    cite_key: String,
    publication_id: String,
    title: String,
    authors: Vec<Author>,
    year: Option<i32>,
    entry_type: String,
    venue: Option<String>,
    identifiers: Identifiers,
    bibtex: Option<String>,
}

impl CitationBuilder {
    /// Start building a citation reference
    pub fn new(cite_key: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            cite_key: cite_key.into(),
            publication_id: uuid::Uuid::new_v4().to_string(),
            title: title.into(),
            authors: Vec::new(),
            year: None,
            entry_type: "misc".to_string(),
            venue: None,
            identifiers: Identifiers::default(),
            bibtex: None,
        }
    }

    /// Set the publication ID
    pub fn publication_id(mut self, id: impl Into<String>) -> Self {
        self.publication_id = id.into();
        self
    }

    /// Add an author by family name
    pub fn author(mut self, family_name: impl Into<String>) -> Self {
        self.authors.push(Author::new(family_name.into()));
        self
    }

    /// Add multiple authors
    pub fn authors(mut self, authors: Vec<Author>) -> Self {
        self.authors = authors;
        self
    }

    /// Set the year
    pub fn year(mut self, year: i32) -> Self {
        self.year = Some(year);
        self
    }

    /// Set the entry type
    pub fn entry_type(mut self, entry_type: impl Into<String>) -> Self {
        self.entry_type = entry_type.into();
        self
    }

    /// Set the venue (journal/booktitle)
    pub fn venue(mut self, venue: impl Into<String>) -> Self {
        self.venue = Some(venue.into());
        self
    }

    /// Set a DOI
    pub fn doi(mut self, doi: impl Into<String>) -> Self {
        self.identifiers.doi = Some(doi.into());
        self
    }

    /// Set an arXiv ID
    pub fn arxiv(mut self, arxiv: impl Into<String>) -> Self {
        self.identifiers.arxiv_id = Some(arxiv.into());
        self
    }

    /// Set full identifiers
    pub fn identifiers(mut self, identifiers: Identifiers) -> Self {
        self.identifiers = identifiers;
        self
    }

    /// Set raw BibTeX
    pub fn bibtex(mut self, bibtex: impl Into<String>) -> Self {
        self.bibtex = Some(bibtex.into());
        self
    }

    /// Build the citation reference
    pub fn build(self) -> CrossAppCitationReference {
        let bibtex = match self.bibtex {
            Some(b) => b,
            None => self.generate_bibtex(),
        };

        let mut metadata = CitationMetadata::new(
            self.title.clone(),
            self.authors.clone(),
            self.entry_type.clone(),
        )
        .with_identifiers(self.identifiers.clone());

        if let Some(year) = self.year {
            metadata = metadata.with_year(year);
        }

        if let Some(venue) = self.venue.clone() {
            metadata = metadata.with_venue(venue);
        }

        CrossAppCitationReference::new(self.cite_key, self.publication_id, metadata, bibtex)
    }

    fn generate_bibtex(&self) -> String {
        let mut fields = Vec::new();

        fields.push(format!("  title = {{{}}}", self.title));

        if !self.authors.is_empty() {
            let authors_str = self
                .authors
                .iter()
                .map(|a| a.to_bibtex_format())
                .collect::<Vec<_>>()
                .join(" and ");
            fields.push(format!("  author = {{{}}}", authors_str));
        }

        if let Some(year) = self.year {
            fields.push(format!("  year = {{{}}}", year));
        }

        if let Some(ref venue) = self.venue {
            let field_name = if self.entry_type == "article" {
                "journal"
            } else {
                "booktitle"
            };
            fields.push(format!("  {} = {{{}}}", field_name, venue));
        }

        if let Some(ref doi) = self.identifiers.doi {
            fields.push(format!("  doi = {{{}}}", doi));
        }

        format!(
            "@{}{{{},\n{}\n}}",
            self.entry_type,
            self.cite_key,
            fields.join(",\n")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_publication() -> Publication {
        let mut pub_ = Publication::new(
            "smith2024machine".to_string(),
            "article".to_string(),
            "Machine Learning for Science".to_string(),
        );
        pub_.year = Some(2024);
        pub_.authors = vec![
            Author::new("Smith".to_string()),
            Author::new("Jones".to_string()),
        ];
        pub_.journal = Some("Nature".to_string());
        pub_.identifiers.doi = Some("10.1234/example".to_string());
        pub_
    }

    #[test]
    fn test_publication_to_citation_reference() {
        let pub_ = sample_publication();
        let citation = publication_to_citation_reference(&pub_);

        assert_eq!(citation.cite_key, "smith2024machine");
        assert_eq!(citation.metadata.title, "Machine Learning for Science");
        assert_eq!(citation.metadata.authors_short, "Smith & Jones");
        assert_eq!(citation.metadata.year, Some(2024));
        assert!(citation.bibtex_entry.contains("smith2024machine"));
    }

    #[test]
    fn test_local_library_provider() {
        let mut provider = LocalLibraryCitationProvider::new("Test Library");
        let pub_ = sample_publication();
        provider.add_publication(pub_.clone());

        // Resolve by key
        let by_key = provider.resolve(&CitationReference::from_key("smith2024machine"));
        assert!(by_key.unwrap().is_some());

        // Resolve by DOI
        let by_doi = provider.resolve(&CitationReference::from_doi("10.1234/example"));
        assert!(by_doi.unwrap().is_some());

        // Search
        let results = provider.search("machine").unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn test_local_library_search() {
        let mut provider = LocalLibraryCitationProvider::new("Test Library");

        let mut pub1 = Publication::new(
            "smith2024".to_string(),
            "article".to_string(),
            "Machine Learning".to_string(),
        );
        pub1.authors = vec![Author::new("Smith".to_string())];

        let mut pub2 = Publication::new(
            "jones2024".to_string(),
            "article".to_string(),
            "Deep Learning".to_string(),
        );
        pub2.authors = vec![Author::new("Jones".to_string())];

        provider.add_publication(pub1);
        provider.add_publication(pub2);

        // Search by title
        let results = provider.search("machine").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].cite_key, "smith2024");

        // Search by author
        let results = provider.search("jones").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].cite_key, "jones2024");

        // Search with no results
        let results = provider.search("quantum").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_citation_builder() {
        let citation = CitationBuilder::new("smith2024", "Machine Learning")
            .author("Smith")
            .author("Jones")
            .year(2024)
            .entry_type("article")
            .venue("Nature")
            .doi("10.1234/example")
            .build();

        assert_eq!(citation.cite_key, "smith2024");
        assert_eq!(citation.metadata.authors_short, "Smith & Jones");
        assert!(citation.bibtex_entry.contains("@article{smith2024"));
        assert!(citation.bibtex_entry.contains("doi = {10.1234/example}"));
    }

    #[test]
    fn test_provider_chain_with_local_library() {
        use crate::citations::CitationProviderChain;

        let mut provider = LocalLibraryCitationProvider::new("Test");
        provider.add_publication(sample_publication());

        let mut chain = CitationProviderChain::new();
        chain.add_provider(provider);

        let result = chain.resolve(&CitationReference::from_key("smith2024machine"));
        assert!(result.unwrap().is_some());
    }

    #[test]
    fn test_remove_publication() {
        let mut provider = LocalLibraryCitationProvider::new("Test");
        provider.add_publication(sample_publication());

        assert_eq!(provider.len(), 1);

        let removed = provider.remove_publication("smith2024machine");
        assert!(removed.is_some());
        assert_eq!(provider.len(), 0);

        // DOI lookup should fail now
        let result = provider.resolve(&CitationReference::from_doi("10.1234/example"));
        assert!(result.unwrap().is_none());
    }
}
