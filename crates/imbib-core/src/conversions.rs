//! Conversion functions between domain types and format types
//!
//! This module provides imbib-specific conversions between:
//! - Publication ↔ BibTeXEntry
//!
//! Note: The FFI-exported versions of these functions are in the domain modules
//! (domain/publication.rs and domain/validation.rs).

use crate::bibtex::{BibTeXEntry, BibTeXEntryType, BibTeXField};
use crate::domain::{parse_author_string, Publication};

// ===== BibTeXEntry → Publication =====

/// Convert a BibTeXEntry to a Publication
pub fn bibtex_entry_to_publication(entry: BibTeXEntry) -> Publication {
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

// ===== Publication → BibTeXEntry =====

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

/// Convert a Publication to a BibTeXEntry
pub fn publication_to_bibtex_entry(pub_: &Publication) -> BibTeXEntry {
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

// ===== Internal Functions for use within crate =====

pub(crate) fn publication_from_bibtex_internal(entry: BibTeXEntry) -> Publication {
    bibtex_entry_to_publication(entry)
}

pub(crate) fn publication_to_bibtex_internal(publication: &Publication) -> BibTeXEntry {
    publication_to_bibtex_entry(publication)
}

pub(crate) fn publication_to_bibtex_string_internal(publication: &Publication) -> String {
    let entry = publication_to_bibtex_entry(publication);
    crate::bibtex::format_entry(entry)
}

// Note: FFI-exported versions of these functions are in domain/publication.rs and domain/validation.rs

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Author;

    #[test]
    fn test_bibtex_to_publication() {
        let entry = BibTeXEntry {
            cite_key: "smith2024".to_string(),
            entry_type: BibTeXEntryType::Article,
            fields: vec![
                BibTeXField {
                    key: "title".to_string(),
                    value: "A Great Paper".to_string(),
                },
                BibTeXField {
                    key: "author".to_string(),
                    value: "John Smith".to_string(),
                },
                BibTeXField {
                    key: "year".to_string(),
                    value: "2024".to_string(),
                },
            ],
            raw_bibtex: None,
        };

        let pub_ = bibtex_entry_to_publication(entry);
        assert_eq!(pub_.cite_key, "smith2024");
        assert_eq!(pub_.title, "A Great Paper");
        assert_eq!(pub_.year, Some(2024));
        assert_eq!(pub_.authors.len(), 1);
    }

    #[test]
    fn test_publication_to_bibtex() {
        let mut pub_ = Publication::new(
            "smith2024".to_string(),
            "article".to_string(),
            "A Great Paper".to_string(),
        );
        pub_.year = Some(2024);
        pub_.authors.push(Author::new("Smith".to_string()));

        let entry = publication_to_bibtex_entry(&pub_);
        assert_eq!(entry.cite_key, "smith2024");
        assert_eq!(entry.entry_type, BibTeXEntryType::Article);
        assert!(entry.fields.iter().any(|f| f.key == "title" && f.value == "A Great Paper"));
        assert!(entry.fields.iter().any(|f| f.key == "year" && f.value == "2024"));
    }
}
