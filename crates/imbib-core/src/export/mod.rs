//! Export pipelines for various formats

use crate::bibtex::BibTeXEntry;
use crate::conversions::publication_to_bibtex_entry;
use crate::domain::Publication;

/// Export format options
#[derive(uniffi::Enum, Clone, Debug)]
pub enum ExportFormat {
    BibTeX,
    RIS,
}

/// Options for export
#[derive(uniffi::Record, Clone, Debug)]
pub struct ExportOptions {
    pub include_abstract: bool,
    pub include_keywords: bool,
    pub include_extra_fields: bool,
    pub sort_fields: bool,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            include_abstract: true,
            include_keywords: true,
            include_extra_fields: true,
            sort_fields: false,
        }
    }
}

/// Get default export options
#[cfg(feature = "native")]
#[uniffi::export]
pub fn default_export_options() -> ExportOptions {
    ExportOptions::default()
}

/// Export single publication to BibTeX
#[cfg(feature = "native")]
#[uniffi::export]
pub fn export_bibtex(publication: &Publication, options: &ExportOptions) -> String {
    let entry = filter_entry(publication_to_bibtex_entry(publication), options);
    crate::bibtex_format_entry(entry)
}

/// Export multiple publications to BibTeX
#[cfg(feature = "native")]
#[uniffi::export]
pub fn export_bibtex_multiple(publications: Vec<Publication>, options: &ExportOptions) -> String {
    let entries: Vec<BibTeXEntry> = publications
        .iter()
        .map(|p| filter_entry(publication_to_bibtex_entry(p), options))
        .collect();
    crate::bibtex_format_entries(entries)
}

/// Export single publication to RIS
#[cfg(feature = "native")]
#[uniffi::export]
pub fn export_ris(publication: &Publication) -> String {
    let bibtex_entry = publication_to_bibtex_entry(publication);
    let ris_entry = crate::ris_from_bibtex(bibtex_entry);
    crate::ris_format_entry(ris_entry)
}

/// Export multiple publications to RIS
#[cfg(feature = "native")]
#[uniffi::export]
pub fn export_ris_multiple(publications: Vec<Publication>) -> String {
    publications
        .iter()
        .map(|p| {
            let bibtex_entry = publication_to_bibtex_entry(p);
            let ris_entry = crate::ris_from_bibtex(bibtex_entry);
            crate::ris_format_entry(ris_entry)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn filter_entry(mut entry: BibTeXEntry, options: &ExportOptions) -> BibTeXEntry {
    if !options.include_abstract {
        entry.fields.retain(|f| f.key.to_lowercase() != "abstract");
    }
    if !options.include_keywords {
        entry.fields.retain(|f| f.key.to_lowercase() != "keywords");
    }
    if !options.include_extra_fields {
        // Keep only standard BibTeX fields
        let standard_fields = [
            "author",
            "title",
            "year",
            "month",
            "journal",
            "booktitle",
            "publisher",
            "volume",
            "number",
            "pages",
            "edition",
            "series",
            "address",
            "chapter",
            "howpublished",
            "institution",
            "organization",
            "school",
            "note",
            "abstract",
            "keywords",
            "url",
            "doi",
            "eprint",
            "primaryclass",
            "archiveprefix",
            "pmid",
            "bibcode",
            "isbn",
            "issn",
            "editor",
        ];
        entry
            .fields
            .retain(|f| standard_fields.contains(&f.key.to_lowercase().as_str()));
    }
    if options.sort_fields {
        entry.fields.sort_by(|a, b| a.key.cmp(&b.key));
    }
    entry
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Author;

    #[test]
    fn test_export_bibtex() {
        let mut pub_ = Publication::new(
            "test2024".to_string(),
            "article".to_string(),
            "Test Paper".to_string(),
        );
        pub_.year = Some(2024);
        pub_.authors
            .push(Author::new("Smith".to_string()).with_given_name("John"));

        let options = default_export_options();
        let result = export_bibtex(&pub_, &options);

        assert!(result.contains("@article{test2024"));
        assert!(result.contains("title"));
        assert!(result.contains("Test Paper"));
    }

    #[test]
    fn test_export_bibtex_without_abstract() {
        let mut pub_ = Publication::new(
            "test2024".to_string(),
            "article".to_string(),
            "Test Paper".to_string(),
        );
        pub_.abstract_text = Some("This is an abstract".to_string());

        let options = ExportOptions {
            include_abstract: false,
            ..Default::default()
        };
        let result = export_bibtex(&pub_, &options);

        assert!(!result.contains("abstract"));
    }

    #[test]
    fn test_export_multiple() {
        let pub1 = Publication::new(
            "first2024".to_string(),
            "article".to_string(),
            "First Paper".to_string(),
        );
        let pub2 = Publication::new(
            "second2024".to_string(),
            "book".to_string(),
            "Second Book".to_string(),
        );

        let options = default_export_options();
        let result = export_bibtex_multiple(vec![pub1, pub2], &options);

        assert!(result.contains("first2024"));
        assert!(result.contains("second2024"));
    }

    #[test]
    fn test_export_ris() {
        let mut pub_ = Publication::new(
            "test2024".to_string(),
            "article".to_string(),
            "Test Paper".to_string(),
        );
        pub_.year = Some(2024);

        let result = export_ris(&pub_);

        assert!(result.contains("TY  -"));
        assert!(result.contains("TI  - Test Paper"));
        assert!(result.contains("ER  -"));
    }
}
