//! Wrapper types mirroring `im_bibtex` with UniFFI derives.

use std::collections::HashMap;

// ── BibTeXEntryType ──────────────────────────────────────────────────────────

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
        im_bibtex::BibTeXEntryType::from_str(s).into()
    }

    /// Convert entry type to canonical string
    pub fn as_str(&self) -> &'static str {
        let inner: im_bibtex::BibTeXEntryType = self.clone().into();
        inner.as_str()
    }
}

macro_rules! bidir_entry_type {
    ($($variant:ident),+ $(,)?) => {
        impl From<im_bibtex::BibTeXEntryType> for BibTeXEntryType {
            fn from(t: im_bibtex::BibTeXEntryType) -> Self {
                match t { $(im_bibtex::BibTeXEntryType::$variant => Self::$variant,)+ }
            }
        }
        impl From<BibTeXEntryType> for im_bibtex::BibTeXEntryType {
            fn from(t: BibTeXEntryType) -> Self {
                match t { $(BibTeXEntryType::$variant => Self::$variant,)+ }
            }
        }
    };
}

bidir_entry_type!(
    Article, Book, Booklet, InBook, InCollection, InProceedings,
    Manual, MastersThesis, Misc, PhdThesis, Proceedings, TechReport,
    Unpublished, Online, Software, Dataset, Unknown,
);

// ── BibTeXField ──────────────────────────────────────────────────────────────

/// A single BibTeX field (key-value pair)
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXField {
    pub key: String,
    pub value: String,
}

impl From<im_bibtex::BibTeXField> for BibTeXField {
    fn from(f: im_bibtex::BibTeXField) -> Self {
        Self {
            key: f.key,
            value: f.value,
        }
    }
}

impl From<BibTeXField> for im_bibtex::BibTeXField {
    fn from(f: BibTeXField) -> Self {
        Self {
            key: f.key,
            value: f.value,
        }
    }
}

// ── BibTeXEntry ──────────────────────────────────────────────────────────────

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

impl From<im_bibtex::BibTeXEntry> for BibTeXEntry {
    fn from(e: im_bibtex::BibTeXEntry) -> Self {
        Self {
            cite_key: e.cite_key,
            entry_type: e.entry_type.into(),
            fields: e.fields.into_iter().map(Into::into).collect(),
            raw_bibtex: e.raw_bibtex,
        }
    }
}

impl From<BibTeXEntry> for im_bibtex::BibTeXEntry {
    fn from(e: BibTeXEntry) -> Self {
        let mut inner = im_bibtex::BibTeXEntry::new(e.cite_key, e.entry_type.into());
        for f in e.fields {
            inner.add_field(f.key, f.value);
        }
        inner.raw_bibtex = e.raw_bibtex;
        inner
    }
}

// ── BibTeXParseError ─────────────────────────────────────────────────────────

/// Parse error information
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXParseError {
    pub line: u32,
    pub column: u32,
    pub message: String,
}

impl From<im_bibtex::BibTeXParseError> for BibTeXParseError {
    fn from(e: im_bibtex::BibTeXParseError) -> Self {
        Self {
            line: e.line,
            column: e.column,
            message: e.message,
        }
    }
}

// ── BibTeXParseResult ────────────────────────────────────────────────────────

/// Result of parsing a BibTeX file
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXParseResult {
    pub entries: Vec<BibTeXEntry>,
    pub preambles: Vec<String>,
    pub strings: HashMap<String, String>,
    pub errors: Vec<BibTeXParseError>,
}

impl From<im_bibtex::BibTeXParseResult> for BibTeXParseResult {
    fn from(r: im_bibtex::BibTeXParseResult) -> Self {
        Self {
            entries: r.entries.into_iter().map(Into::into).collect(),
            preambles: r.preambles,
            strings: r.strings,
            errors: r.errors.into_iter().map(Into::into).collect(),
        }
    }
}

// ── ParseError ───────────────────────────────────────────────────────────────

/// Error type for parsing failures
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
pub enum ParseError {
    #[error("Invalid syntax")]
    InvalidSyntax,
    #[error("Unexpected token")]
    UnexpectedToken,
    #[error("Missing required field")]
    MissingField,
    #[error("Invalid entry type")]
    InvalidEntryType,
    #[error("Encoding error")]
    EncodingError,
}

impl From<im_bibtex::ParseError> for ParseError {
    fn from(e: im_bibtex::ParseError) -> Self {
        match e {
            im_bibtex::ParseError::InvalidSyntax => Self::InvalidSyntax,
            im_bibtex::ParseError::UnexpectedToken => Self::UnexpectedToken,
            im_bibtex::ParseError::MissingField => Self::MissingField,
            im_bibtex::ParseError::InvalidEntryType => Self::InvalidEntryType,
            im_bibtex::ParseError::EncodingError => Self::EncodingError,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_entry_type_roundtrip() {
        for variant in [
            BibTeXEntryType::Article,
            BibTeXEntryType::Book,
            BibTeXEntryType::InProceedings,
            BibTeXEntryType::Unknown,
        ] {
            let inner: im_bibtex::BibTeXEntryType = variant.clone().into();
            let back: BibTeXEntryType = inner.into();
            assert_eq!(variant, back);
        }
    }

    #[test]
    fn test_entry_type_from_str() {
        assert_eq!(BibTeXEntryType::from_str("article"), BibTeXEntryType::Article);
        assert_eq!(BibTeXEntryType::from_str("ARTICLE"), BibTeXEntryType::Article);
        assert_eq!(BibTeXEntryType::from_str("conference"), BibTeXEntryType::InProceedings);
        assert_eq!(BibTeXEntryType::from_str("unknown_type"), BibTeXEntryType::Unknown);
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

    #[test]
    fn test_entry_roundtrip() {
        let mut entry = BibTeXEntry::new("Test2024".to_string(), BibTeXEntryType::Article);
        entry.add_field("title", "Test");
        entry.add_field("year", "2024");

        let inner: im_bibtex::BibTeXEntry = entry.clone().into();
        let back: BibTeXEntry = inner.into();

        assert_eq!(entry.cite_key, back.cite_key);
        assert_eq!(entry.entry_type, back.entry_type);
        assert_eq!(entry.fields.len(), back.fields.len());
    }
}
