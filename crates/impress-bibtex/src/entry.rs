//! BibTeX entry data structures

use std::collections::HashMap;

/// BibTeX entry type
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum BibTeXEntryType {
    Article,
    Book,
    Booklet,
    InBook,
    InCollection,
    InProceedings,
    Manual,
    MastersThesis,
    Misc,
    PhdThesis,
    Proceedings,
    TechReport,
    Unpublished,
    Online,
    Software,
    Dataset,
    Unknown,
}

impl BibTeXEntryType {
    /// Parse an entry type from a string (case-insensitive)
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "article" => Self::Article,
            "book" => Self::Book,
            "booklet" => Self::Booklet,
            "inbook" => Self::InBook,
            "incollection" => Self::InCollection,
            "inproceedings" | "conference" => Self::InProceedings,
            "manual" => Self::Manual,
            "mastersthesis" => Self::MastersThesis,
            "misc" => Self::Misc,
            "phdthesis" => Self::PhdThesis,
            "proceedings" => Self::Proceedings,
            "techreport" => Self::TechReport,
            "unpublished" => Self::Unpublished,
            "online" | "electronic" | "www" => Self::Online,
            "software" => Self::Software,
            "dataset" => Self::Dataset,
            _ => Self::Unknown,
        }
    }

    /// Convert entry type to canonical string
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Article => "article",
            Self::Book => "book",
            Self::Booklet => "booklet",
            Self::InBook => "inbook",
            Self::InCollection => "incollection",
            Self::InProceedings => "inproceedings",
            Self::Manual => "manual",
            Self::MastersThesis => "mastersthesis",
            Self::Misc => "misc",
            Self::PhdThesis => "phdthesis",
            Self::Proceedings => "proceedings",
            Self::TechReport => "techreport",
            Self::Unpublished => "unpublished",
            Self::Online => "online",
            Self::Software => "software",
            Self::Dataset => "dataset",
            Self::Unknown => "misc",
        }
    }
}

/// A single BibTeX field (key-value pair)
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXField {
    pub key: String,
    pub value: String,
}

/// A parsed BibTeX entry
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXEntry {
    pub cite_key: String,
    pub entry_type: BibTeXEntryType,
    pub fields: Vec<BibTeXField>,
    pub raw_bibtex: Option<String>,
}

impl BibTeXEntry {
    /// Create a new BibTeX entry
    pub fn new(cite_key: String, entry_type: BibTeXEntryType) -> Self {
        Self {
            cite_key,
            entry_type,
            fields: Vec::new(),
            raw_bibtex: None,
        }
    }

    /// Add a field to the entry
    pub fn add_field(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.fields.push(BibTeXField {
            key: key.into(),
            value: value.into(),
        });
    }

    /// Get a field value by key (case-insensitive)
    pub fn get_field(&self, key: &str) -> Option<&str> {
        let key_lower = key.to_lowercase();
        self.fields
            .iter()
            .find(|f| f.key.to_lowercase() == key_lower)
            .map(|f| f.value.as_str())
    }

    /// Get all fields as a HashMap for convenient access
    pub fn fields_map(&self) -> HashMap<String, String> {
        self.fields
            .iter()
            .map(|f| (f.key.to_lowercase(), f.value.clone()))
            .collect()
    }

    /// Get the title field
    pub fn title(&self) -> Option<&str> {
        self.get_field("title")
    }

    /// Get the author field
    pub fn author(&self) -> Option<&str> {
        self.get_field("author")
    }

    /// Get the year field
    pub fn year(&self) -> Option<&str> {
        self.get_field("year")
    }

    /// Get the DOI field
    pub fn doi(&self) -> Option<&str> {
        self.get_field("doi")
    }

    /// Get the abstract field
    pub fn abstract_text(&self) -> Option<&str> {
        self.get_field("abstract")
    }

    /// Get the journal field
    pub fn journal(&self) -> Option<&str> {
        self.get_field("journal")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_entry_type_parsing() {
        assert_eq!(
            BibTeXEntryType::from_str("article"),
            BibTeXEntryType::Article
        );
        assert_eq!(
            BibTeXEntryType::from_str("ARTICLE"),
            BibTeXEntryType::Article
        );
        assert_eq!(
            BibTeXEntryType::from_str("Article"),
            BibTeXEntryType::Article
        );
        assert_eq!(
            BibTeXEntryType::from_str("inproceedings"),
            BibTeXEntryType::InProceedings
        );
        assert_eq!(
            BibTeXEntryType::from_str("conference"),
            BibTeXEntryType::InProceedings
        );
        assert_eq!(
            BibTeXEntryType::from_str("unknown_type"),
            BibTeXEntryType::Unknown
        );
    }

    #[test]
    fn test_entry_field_access() {
        let mut entry = BibTeXEntry::new("Smith2024".to_string(), BibTeXEntryType::Article);
        entry.add_field("title", "A Great Paper");
        entry.add_field("Author", "John Smith");
        entry.add_field("YEAR", "2024");

        assert_eq!(entry.title(), Some("A Great Paper"));
        assert_eq!(entry.author(), Some("John Smith"));
        assert_eq!(entry.year(), Some("2024"));
        assert_eq!(entry.doi(), None);
    }
}
