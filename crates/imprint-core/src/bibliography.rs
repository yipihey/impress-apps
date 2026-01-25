//! Bibliography and citation tracking for academic documents
//!
//! This module manages the bibliography associated with an imprint document,
//! tracking which publications are cited and maintaining the connection to
//! the full publication metadata from `academic-domain`.
//!
//! # Features
//!
//! - **Citation tracking**: Track which publications are cited in a document
//! - **Bibliography generation**: Generate formatted bibliographies in various styles
//! - **Publication linking**: Link citations to full publication records
//! - **Import/export**: Import from and export to BibTeX format
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::bibliography::Bibliography;
//! use impress_domain::Publication;
//!
//! let mut bib = Bibliography::new();
//! bib.add_publication(publication);
//! let entries = bib.entries();
//! ```

use impress_domain::Publication;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

/// Errors that can occur during bibliography operations
#[derive(Debug, Error)]
pub enum BibliographyError {
    /// Citation key not found
    #[error("Citation key not found: {0}")]
    KeyNotFound(String),

    /// Duplicate citation key
    #[error("Duplicate citation key: {0}")]
    DuplicateKey(String),

    /// Invalid BibTeX format
    #[error("Invalid BibTeX: {0}")]
    InvalidBibtex(String),
}

/// Result type for bibliography operations
pub type BibliographyResult<T> = Result<T, BibliographyError>;

/// A bibliography entry linking a citation key to a publication
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BibliographyEntry {
    /// The citation key (e.g., "smith2023")
    pub key: String,
    /// The full publication record
    pub publication: Publication,
    /// Number of times this entry is cited in the document
    pub citation_count: usize,
    /// Positions in the document where this entry is cited
    pub citation_positions: Vec<usize>,
}

impl BibliographyEntry {
    /// Create a new bibliography entry
    pub fn new(key: impl Into<String>, publication: Publication) -> Self {
        Self {
            key: key.into(),
            publication,
            citation_count: 0,
            citation_positions: Vec::new(),
        }
    }

    /// Record a citation at the given position
    pub fn add_citation(&mut self, position: usize) {
        self.citation_count += 1;
        self.citation_positions.push(position);
        self.citation_positions.sort_unstable();
    }

    /// Remove a citation at the given position
    pub fn remove_citation(&mut self, position: usize) {
        if let Some(idx) = self.citation_positions.iter().position(|&p| p == position) {
            self.citation_positions.remove(idx);
            self.citation_count = self.citation_count.saturating_sub(1);
        }
    }
}

/// A document bibliography containing all cited publications
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Bibliography {
    /// Entries indexed by citation key
    entries: HashMap<String, BibliographyEntry>,
}

impl Bibliography {
    /// Create a new empty bibliography
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a publication to the bibliography
    ///
    /// Returns the assigned citation key
    pub fn add_publication(&mut self, publication: Publication) -> BibliographyResult<String> {
        let key = self.generate_key(&publication);
        if self.entries.contains_key(&key) {
            return Err(BibliographyError::DuplicateKey(key));
        }

        self.entries
            .insert(key.clone(), BibliographyEntry::new(&key, publication));
        Ok(key)
    }

    /// Add a publication with a specific citation key
    pub fn add_with_key(
        &mut self,
        key: impl Into<String>,
        publication: Publication,
    ) -> BibliographyResult<()> {
        let key = key.into();
        if self.entries.contains_key(&key) {
            return Err(BibliographyError::DuplicateKey(key));
        }

        self.entries
            .insert(key.clone(), BibliographyEntry::new(key, publication));
        Ok(())
    }

    /// Get an entry by citation key
    pub fn get(&self, key: &str) -> Option<&BibliographyEntry> {
        self.entries.get(key)
    }

    /// Get a mutable entry by citation key
    pub fn get_mut(&mut self, key: &str) -> Option<&mut BibliographyEntry> {
        self.entries.get_mut(key)
    }

    /// Remove an entry by citation key
    pub fn remove(&mut self, key: &str) -> Option<BibliographyEntry> {
        self.entries.remove(key)
    }

    /// Check if a citation key exists
    pub fn contains(&self, key: &str) -> bool {
        self.entries.contains_key(key)
    }

    /// Get all bibliography entries
    pub fn entries(&self) -> impl Iterator<Item = &BibliographyEntry> {
        self.entries.values()
    }

    /// Get the number of entries
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Check if the bibliography is empty
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Record a citation at a position in the document
    pub fn cite(&mut self, key: &str, position: usize) -> BibliographyResult<()> {
        let entry = self
            .entries
            .get_mut(key)
            .ok_or_else(|| BibliographyError::KeyNotFound(key.to_string()))?;
        entry.add_citation(position);
        Ok(())
    }

    /// Get all citation keys sorted alphabetically
    pub fn keys(&self) -> Vec<&str> {
        let mut keys: Vec<_> = self.entries.keys().map(String::as_str).collect();
        keys.sort_unstable();
        keys
    }

    /// Generate a citation key for a publication
    fn generate_key(&self, publication: &Publication) -> String {
        // Use first author's last name + year
        let author_part = publication
            .authors
            .first()
            .map(|a| {
                a.family_name
                    .chars()
                    .filter(|c| c.is_alphanumeric())
                    .collect::<String>()
                    .to_lowercase()
            })
            .unwrap_or_else(|| "unknown".to_string());

        let year_part = publication
            .year
            .map(|y| y.to_string())
            .unwrap_or_else(|| "nd".to_string());

        let base_key = format!("{}{}", author_part, year_part);

        // Ensure uniqueness by appending a letter if needed
        if !self.entries.contains_key(&base_key) {
            return base_key;
        }

        for suffix in 'a'..='z' {
            let candidate = format!("{}{}", base_key, suffix);
            if !self.entries.contains_key(&candidate) {
                return candidate;
            }
        }

        // Fallback: append a number
        let mut counter = 1;
        loop {
            let candidate = format!("{}_{}", base_key, counter);
            if !self.entries.contains_key(&candidate) {
                return candidate;
            }
            counter += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_domain::Author;

    fn sample_publication() -> Publication {
        let mut pub1 = Publication::new(
            "smith2023".to_string(),
            "article".to_string(),
            "A Study of Studies".to_string(),
        );
        pub1.year = Some(2023);
        pub1.authors = vec![Author::new("Smith".to_string()).with_given_name("John")];
        pub1
    }

    #[test]
    fn test_add_publication() {
        let mut bib = Bibliography::new();
        let key = bib.add_publication(sample_publication()).unwrap();
        assert_eq!(key, "smith2023");
        assert!(bib.contains("smith2023"));
    }

    #[test]
    fn test_duplicate_key_suffix() {
        let mut bib = Bibliography::new();
        bib.add_publication(sample_publication()).unwrap();
        let key2 = bib.add_publication(sample_publication()).unwrap();
        assert_eq!(key2, "smith2023a");
    }
}
