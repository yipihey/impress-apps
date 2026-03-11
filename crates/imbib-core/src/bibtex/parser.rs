//! BibTeX parser — delegates to the canonical `impress_bibtex` (→ `im-bibtex`) crate.
//!
//! Local type definitions are kept for UniFFI compatibility; all parsing logic
//! lives in `im-bibtex` and is accessed via the `impress_bibtex` wrapper.

use std::collections::HashMap;

use super::entry::BibTeXEntry;

/// Parse error information
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BibTeXParseError {
    pub line: u32,
    pub column: u32,
    pub message: String,
}

/// Result of parsing a BibTeX file
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BibTeXParseResult {
    pub entries: Vec<BibTeXEntry>,
    pub preambles: Vec<String>,
    pub strings: HashMap<String, String>,
    pub errors: Vec<BibTeXParseError>,
}

/// Error type for parsing failures
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
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

// ── Conversions from impress_bibtex types ───────────────────────────────────

impl From<impress_bibtex::BibTeXParseError> for BibTeXParseError {
    fn from(e: impress_bibtex::BibTeXParseError) -> Self {
        Self {
            line: e.line,
            column: e.column,
            message: e.message,
        }
    }
}

impl From<impress_bibtex::BibTeXParseResult> for BibTeXParseResult {
    fn from(r: impress_bibtex::BibTeXParseResult) -> Self {
        Self {
            entries: r.entries.into_iter().map(Into::into).collect(),
            preambles: r.preambles,
            strings: r.strings,
            errors: r.errors.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<impress_bibtex::ParseError> for ParseError {
    fn from(e: impress_bibtex::ParseError) -> Self {
        match e {
            impress_bibtex::ParseError::InvalidSyntax => Self::InvalidSyntax,
            impress_bibtex::ParseError::UnexpectedToken => Self::UnexpectedToken,
            impress_bibtex::ParseError::MissingField => Self::MissingField,
            impress_bibtex::ParseError::InvalidEntryType => Self::InvalidEntryType,
            impress_bibtex::ParseError::EncodingError => Self::EncodingError,
        }
    }
}

// ── Parsing (delegates to impress_bibtex → im-bibtex) ──────────────────────

pub(crate) fn parse_internal(input: String) -> Result<BibTeXParseResult, ParseError> {
    impress_bibtex::parse(input)
        .map(Into::into)
        .map_err(Into::into)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse(input: String) -> Result<BibTeXParseResult, ParseError> {
    parse_internal(input)
}

pub(crate) fn parse_entry_internal(input: String) -> Result<BibTeXEntry, ParseError> {
    impress_bibtex::parse_entry(input)
        .map(Into::into)
        .map_err(Into::into)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_entry(input: String) -> Result<BibTeXEntry, ParseError> {
    parse_entry_internal(input)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bibtex::entry::BibTeXEntryType;

    #[test]
    fn test_parse_simple_entry() {
        let input = r#"
@article{Smith2024,
    author = {John Smith},
    title = {A Great Paper},
    year = {2024},
    journal = {Nature},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.errors.len(), 0);

        let entry = &result.entries[0];
        assert_eq!(entry.cite_key, "Smith2024");
        assert_eq!(entry.entry_type, BibTeXEntryType::Article);
        assert_eq!(entry.author(), Some("John Smith"));
        assert_eq!(entry.title(), Some("A Great Paper"));
        assert_eq!(entry.year(), Some("2024"));
    }

    #[test]
    fn test_parse_quoted_values() {
        let input = r#"
@article{Test2024,
    author = "Jane Doe",
    title = "Testing \"Quotes\"",
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].author(), Some("Jane Doe"));
    }

    #[test]
    fn test_parse_nested_braces() {
        let input = r#"
@article{Test2024,
    title = {A {B}ook about {LaTeX}},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].title(), Some("A {B}ook about {LaTeX}"));
    }

    #[test]
    fn test_parse_string_definitions() {
        let input = r#"
@string{nature = "Nature"}
@article{Test2024,
    journal = nature,
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.strings.get("nature"), Some(&"Nature".to_string()));
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].journal(), Some("Nature"));
    }

    #[test]
    fn test_parse_concatenation() {
        let input = r#"
@string{jan = "January"}
@article{Test2024,
    month = jan # " 15",
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].get_field("month"), Some("January 15"));
    }

    #[test]
    fn test_parse_multiple_entries() {
        let input = r#"
@article{First2024,
    title = {First Paper},
}

@book{Second2024,
    title = {Second Book},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 2);
        assert_eq!(result.entries[0].cite_key, "First2024");
        assert_eq!(result.entries[1].cite_key, "Second2024");
        assert_eq!(result.entries[0].entry_type, BibTeXEntryType::Article);
        assert_eq!(result.entries[1].entry_type, BibTeXEntryType::Book);
    }

    #[test]
    fn test_parse_preamble() {
        let input = r#"
@preamble{"This is a preamble"}
@article{Test2024,
    title = {Test},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.preambles.len(), 1);
        assert_eq!(result.preambles[0], "This is a preamble");
    }

    #[test]
    fn test_parse_cite_key_with_ampersand() {
        // ADS uses & in cite keys (e.g., "Smith&Jones2024")
        let input = r#"
@article{Smith&Jones2024,
    title = {Collaboration Paper},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].cite_key, "Smith&Jones2024");
    }
}
