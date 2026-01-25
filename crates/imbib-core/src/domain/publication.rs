//! Publication domain model

use super::{parse_author_string, Author, Identifiers, LinkedFile};
use crate::bibtex::{BibTeXEntry, BibTeXEntryType, BibTeXField};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A publication (paper, book, thesis, etc.)
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
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
}

// Conversion from BibTeXEntry
impl From<BibTeXEntry> for Publication {
    fn from(entry: BibTeXEntry) -> Self {
        let title = entry
            .fields
            .iter()
            .find(|f| f.key.to_lowercase() == "title")
            .map(|f| f.value.clone())
            .unwrap_or_default();

        let mut pub_ = Publication::new(
            entry.cite_key.clone(),
            entry.entry_type.as_str().to_string(),
            title,
        );

        // Map all standard fields
        for field in &entry.fields {
            let key = field.key.to_lowercase();
            let value = field.value.clone();

            match key.as_str() {
                "title" => pub_.title = value,
                "year" => pub_.year = value.parse().ok(),
                "month" => pub_.month = Some(value),
                "author" => pub_.authors = parse_author_string(value),
                "editor" => pub_.editors = parse_author_string(value),
                "journal" => pub_.journal = Some(value),
                "booktitle" => pub_.booktitle = Some(value),
                "publisher" => pub_.publisher = Some(value),
                "volume" => pub_.volume = Some(value),
                "number" => pub_.number = Some(value),
                "pages" => pub_.pages = Some(value),
                "edition" => pub_.edition = Some(value),
                "series" => pub_.series = Some(value),
                "address" => pub_.address = Some(value),
                "chapter" => pub_.chapter = Some(value),
                "howpublished" => pub_.howpublished = Some(value),
                "institution" => pub_.institution = Some(value),
                "organization" => pub_.organization = Some(value),
                "school" => pub_.school = Some(value),
                "note" => pub_.note = Some(value),
                "abstract" => pub_.abstract_text = Some(value),
                "keywords" => {
                    pub_.keywords = value.split(',').map(|s| s.trim().to_string()).collect()
                }
                "url" => pub_.url = Some(value),
                "doi" => pub_.identifiers.doi = Some(value),
                "eprint" => {
                    pub_.eprint = Some(value.clone());
                    // Also set as arxiv_id if it looks like one
                    if value.contains('.') || value.contains('/') {
                        pub_.identifiers.arxiv_id = Some(value);
                    }
                }
                "primaryclass" => pub_.primary_class = Some(value),
                "archiveprefix" => pub_.archive_prefix = Some(value),
                "pmid" => pub_.identifiers.pmid = Some(value),
                "bibcode" => pub_.identifiers.bibcode = Some(value),
                "isbn" => pub_.identifiers.isbn = Some(value),
                "issn" => pub_.identifiers.issn = Some(value),
                _ => {
                    pub_.extra_fields.insert(field.key.clone(), value);
                }
            }
        }

        pub_.raw_bibtex = entry.raw_bibtex;
        pub_
    }
}

/// Helper to add a non-empty optional field to the fields vector
fn add_optional_field(fields: &mut Vec<BibTeXField>, key: &str, value: &Option<String>) {
    if let Some(v) = value {
        if !v.is_empty() {
            fields.push(BibTeXField {
                key: key.to_string(),
                value: v.clone(),
            });
        }
    }
}

// Conversion to BibTeXEntry
impl From<&Publication> for BibTeXEntry {
    fn from(pub_: &Publication) -> Self {
        let mut fields = Vec::new();

        fields.push(BibTeXField {
            key: "title".to_string(),
            value: pub_.title.clone(),
        });

        if let Some(year) = pub_.year {
            fields.push(BibTeXField {
                key: "year".to_string(),
                value: year.to_string(),
            });
        }

        if !pub_.authors.is_empty() {
            let author_str = pub_
                .authors
                .iter()
                .map(|a| a.to_bibtex_format())
                .collect::<Vec<_>>()
                .join(" and ");
            fields.push(BibTeXField {
                key: "author".to_string(),
                value: author_str,
            });
        }

        if !pub_.editors.is_empty() {
            let editor_str = pub_
                .editors
                .iter()
                .map(|a| a.to_bibtex_format())
                .collect::<Vec<_>>()
                .join(" and ");
            fields.push(BibTeXField {
                key: "editor".to_string(),
                value: editor_str,
            });
        }

        add_optional_field(&mut fields, "month", &pub_.month);
        add_optional_field(&mut fields, "journal", &pub_.journal);
        add_optional_field(&mut fields, "booktitle", &pub_.booktitle);
        add_optional_field(&mut fields, "publisher", &pub_.publisher);
        add_optional_field(&mut fields, "volume", &pub_.volume);
        add_optional_field(&mut fields, "number", &pub_.number);
        add_optional_field(&mut fields, "pages", &pub_.pages);
        add_optional_field(&mut fields, "edition", &pub_.edition);
        add_optional_field(&mut fields, "series", &pub_.series);
        add_optional_field(&mut fields, "address", &pub_.address);
        add_optional_field(&mut fields, "chapter", &pub_.chapter);
        add_optional_field(&mut fields, "howpublished", &pub_.howpublished);
        add_optional_field(&mut fields, "institution", &pub_.institution);
        add_optional_field(&mut fields, "organization", &pub_.organization);
        add_optional_field(&mut fields, "school", &pub_.school);
        add_optional_field(&mut fields, "note", &pub_.note);
        add_optional_field(&mut fields, "abstract", &pub_.abstract_text);
        add_optional_field(&mut fields, "url", &pub_.url);
        add_optional_field(&mut fields, "eprint", &pub_.eprint);
        add_optional_field(&mut fields, "primaryclass", &pub_.primary_class);
        add_optional_field(&mut fields, "archiveprefix", &pub_.archive_prefix);
        add_optional_field(&mut fields, "doi", &pub_.identifiers.doi);
        add_optional_field(&mut fields, "pmid", &pub_.identifiers.pmid);
        add_optional_field(&mut fields, "bibcode", &pub_.identifiers.bibcode);
        add_optional_field(&mut fields, "isbn", &pub_.identifiers.isbn);
        add_optional_field(&mut fields, "issn", &pub_.identifiers.issn);

        if !pub_.keywords.is_empty() {
            fields.push(BibTeXField {
                key: "keywords".to_string(),
                value: pub_.keywords.join(", "),
            });
        }

        // Add extra fields
        for (key, value) in &pub_.extra_fields {
            fields.push(BibTeXField {
                key: key.clone(),
                value: value.clone(),
            });
        }

        BibTeXEntry {
            cite_key: pub_.cite_key.clone(),
            entry_type: BibTeXEntryType::from_str(&pub_.entry_type),
            fields,
            raw_bibtex: pub_.raw_bibtex.clone(),
        }
    }
}

pub(crate) fn publication_from_bibtex_internal(entry: BibTeXEntry) -> Publication {
    Publication::from(entry)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn publication_from_bibtex(entry: BibTeXEntry) -> Publication {
    publication_from_bibtex_internal(entry)
}

pub(crate) fn publication_to_bibtex_internal(publication: &Publication) -> BibTeXEntry {
    BibTeXEntry::from(publication)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn publication_to_bibtex(publication: &Publication) -> BibTeXEntry {
    publication_to_bibtex_internal(publication)
}

pub(crate) fn publication_to_bibtex_string_internal(publication: &Publication) -> String {
    let entry = BibTeXEntry::from(publication);
    crate::bibtex_format_entry(entry)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn publication_to_bibtex_string(publication: &Publication) -> String {
    publication_to_bibtex_string_internal(publication)
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
    fn test_publication_from_bibtex() {
        let bibtex = r#"@article{Smith2024,
            author = {John Smith and Jane Doe},
            title = {A Great Paper},
            year = {2024},
            journal = {Nature},
            doi = {10.1234/test}
        }"#;
        let parse_result = crate::bibtex_parse(bibtex.to_string()).unwrap();
        let entry = parse_result.entries.into_iter().next().unwrap();
        let pub_ = Publication::from(entry);

        assert_eq!(pub_.cite_key, "Smith2024");
        assert_eq!(pub_.title, "A Great Paper");
        assert_eq!(pub_.year, Some(2024));
        assert_eq!(pub_.journal, Some("Nature".to_string()));
        assert_eq!(pub_.identifiers.doi, Some("10.1234/test".to_string()));
        assert_eq!(pub_.authors.len(), 2);
    }

    #[test]
    fn test_publication_to_bibtex() {
        let mut pub_ = Publication::new(
            "test2024".to_string(),
            "article".to_string(),
            "Test Paper".to_string(),
        );
        pub_.year = Some(2024);
        pub_.authors
            .push(Author::new("Smith".to_string()).with_given_name("John"));
        pub_.journal = Some("Science".to_string());

        let entry = BibTeXEntry::from(&pub_);
        assert_eq!(entry.cite_key, "test2024");
        assert!(entry
            .fields
            .iter()
            .any(|f| f.key == "title" && f.value == "Test Paper"));
        assert!(entry
            .fields
            .iter()
            .any(|f| f.key == "author" && f.value.contains("Smith")));
    }

    #[test]
    fn test_roundtrip() {
        let bibtex = r#"@article{Test2024,
            author = {Smith, John},
            title = {Test Paper},
            year = {2024},
            journal = {Nature}
        }"#;
        let parse_result = crate::bibtex_parse(bibtex.to_string()).unwrap();
        let entry = parse_result.entries.into_iter().next().unwrap();
        let pub_ = Publication::from(entry);
        let entry_back = BibTeXEntry::from(&pub_);

        assert_eq!(entry_back.cite_key, "Test2024");
        assert!(entry_back.fields.iter().any(|f| f.key == "title"));
        assert!(entry_back.fields.iter().any(|f| f.key == "year"));
    }
}
