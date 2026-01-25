//! Publication domain model

use super::{Author, Identifiers, LinkedFile};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A publication (paper, book, thesis, etc.)
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Publication {
    pub id: String,
    pub cite_key: String,
    pub entry_type: String,
    pub title: String,
    pub year: Option<i32>,
    pub month: Option<String>,
    pub authors: Vec<Author>,
    pub editors: Vec<Author>,

    // Standard BibTeX fields
    pub journal: Option<String>,
    pub booktitle: Option<String>,
    pub publisher: Option<String>,
    pub volume: Option<String>,
    pub number: Option<String>,
    pub pages: Option<String>,
    pub edition: Option<String>,
    pub series: Option<String>,
    pub address: Option<String>,
    pub chapter: Option<String>,
    pub howpublished: Option<String>,
    pub institution: Option<String>,
    pub organization: Option<String>,
    pub school: Option<String>,
    pub note: Option<String>,

    // Extended fields
    pub abstract_text: Option<String>,
    pub keywords: Vec<String>,
    pub url: Option<String>,
    pub eprint: Option<String>,
    pub primary_class: Option<String>,
    pub archive_prefix: Option<String>,

    // Identifiers
    pub identifiers: Identifiers,

    // Additional fields (catch-all for non-standard BibTeX fields)
    pub extra_fields: HashMap<String, String>,

    // Linked files
    pub linked_files: Vec<LinkedFile>,

    // Organization
    pub tags: Vec<String>,
    pub collections: Vec<String>,
    pub library_id: Option<String>,

    // Metadata
    pub created_at: Option<String>,  // ISO 8601
    pub modified_at: Option<String>, // ISO 8601
    pub source_id: Option<String>,   // Original source (arxiv, crossref, etc.)

    // Enrichment data
    pub citation_count: Option<i32>,
    pub reference_count: Option<i32>,
    pub enrichment_source: Option<String>,
    pub enrichment_date: Option<String>,

    // Original format preservation
    pub raw_bibtex: Option<String>,
    pub raw_ris: Option<String>,
}

impl Publication {
    /// Create a new publication with required fields
    pub fn new(cite_key: String, entry_type: String, title: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            cite_key,
            entry_type,
            title,
            year: None,
            month: None,
            authors: Vec::new(),
            editors: Vec::new(),
            journal: None,
            booktitle: None,
            publisher: None,
            volume: None,
            number: None,
            pages: None,
            edition: None,
            series: None,
            address: None,
            chapter: None,
            howpublished: None,
            institution: None,
            organization: None,
            school: None,
            note: None,
            abstract_text: None,
            keywords: Vec::new(),
            url: None,
            eprint: None,
            primary_class: None,
            archive_prefix: None,
            identifiers: Identifiers::default(),
            extra_fields: HashMap::new(),
            linked_files: Vec::new(),
            tags: Vec::new(),
            collections: Vec::new(),
            library_id: None,
            created_at: None,
            modified_at: None,
            source_id: None,
            citation_count: None,
            reference_count: None,
            enrichment_source: None,
            enrichment_date: None,
            raw_bibtex: None,
            raw_ris: None,
        }
    }

    /// Get a field value by name (case-insensitive)
    pub fn get_field(&self, name: &str) -> Option<String> {
        match name.to_lowercase().as_str() {
            "title" => Some(self.title.clone()),
            "year" => self.year.map(|y| y.to_string()),
            "month" => self.month.clone(),
            "journal" => self.journal.clone(),
            "booktitle" => self.booktitle.clone(),
            "publisher" => self.publisher.clone(),
            "volume" => self.volume.clone(),
            "number" => self.number.clone(),
            "pages" => self.pages.clone(),
            "edition" => self.edition.clone(),
            "series" => self.series.clone(),
            "address" => self.address.clone(),
            "chapter" => self.chapter.clone(),
            "howpublished" => self.howpublished.clone(),
            "institution" => self.institution.clone(),
            "organization" => self.organization.clone(),
            "school" => self.school.clone(),
            "note" => self.note.clone(),
            "abstract" => self.abstract_text.clone(),
            "url" => self.url.clone(),
            "eprint" => self.eprint.clone(),
            "primaryclass" => self.primary_class.clone(),
            "archiveprefix" => self.archive_prefix.clone(),
            "doi" => self.identifiers.doi.clone(),
            "arxiv" | "arxiv_id" => self.identifiers.arxiv_id.clone(),
            "pmid" => self.identifiers.pmid.clone(),
            "bibcode" => self.identifiers.bibcode.clone(),
            "isbn" => self.identifiers.isbn.clone(),
            "issn" => self.identifiers.issn.clone(),
            _ => self.extra_fields.get(name).cloned(),
        }
    }

    /// Set a field value by name (case-insensitive)
    pub fn set_field(&mut self, name: &str, value: String) {
        match name.to_lowercase().as_str() {
            "title" => self.title = value,
            "year" => self.year = value.parse().ok(),
            "month" => self.month = Some(value),
            "journal" => self.journal = Some(value),
            "booktitle" => self.booktitle = Some(value),
            "publisher" => self.publisher = Some(value),
            "volume" => self.volume = Some(value),
            "number" => self.number = Some(value),
            "pages" => self.pages = Some(value),
            "edition" => self.edition = Some(value),
            "series" => self.series = Some(value),
            "address" => self.address = Some(value),
            "chapter" => self.chapter = Some(value),
            "howpublished" => self.howpublished = Some(value),
            "institution" => self.institution = Some(value),
            "organization" => self.organization = Some(value),
            "school" => self.school = Some(value),
            "note" => self.note = Some(value),
            "abstract" => self.abstract_text = Some(value),
            "url" => self.url = Some(value),
            "eprint" => self.eprint = Some(value),
            "primaryclass" => self.primary_class = Some(value),
            "archiveprefix" => self.archive_prefix = Some(value),
            "doi" => self.identifiers.doi = Some(value),
            "arxiv" | "arxiv_id" => self.identifiers.arxiv_id = Some(value),
            "pmid" => self.identifiers.pmid = Some(value),
            "bibcode" => self.identifiers.bibcode = Some(value),
            "isbn" => self.identifiers.isbn = Some(value),
            "issn" => self.identifiers.issn = Some(value),
            _ => {
                self.extra_fields.insert(name.to_string(), value);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_publication_new() {
        let pub_ = Publication::new(
            "einstein1905".to_string(),
            "article".to_string(),
            "On the Electrodynamics of Moving Bodies".to_string(),
        );
        assert_eq!(pub_.cite_key, "einstein1905");
        assert_eq!(pub_.entry_type, "article");
        assert!(pub_.authors.is_empty());
    }

    #[test]
    fn test_get_set_field() {
        let mut pub_ = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Test".to_string(),
        );

        pub_.set_field("journal", "Nature".to_string());
        assert_eq!(pub_.get_field("journal"), Some("Nature".to_string()));

        pub_.set_field("doi", "10.1234/test".to_string());
        assert_eq!(pub_.identifiers.doi, Some("10.1234/test".to_string()));

        pub_.set_field("custom_field", "custom_value".to_string());
        assert_eq!(
            pub_.get_field("custom_field"),
            Some("custom_value".to_string())
        );
    }
}
