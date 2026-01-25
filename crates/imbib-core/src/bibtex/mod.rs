//! BibTeX parsing and formatting module
//!
//! This module provides a complete BibTeX parser and formatter that maintains
//! round-trip fidelity with the original BibTeX content.
//!
//! This module re-exports types and functions from the `academic-bibtex` crate.

// Re-export everything from academic-bibtex
pub use impress_bibtex::{
    format_entries, format_entry, parse, parse_entry, BibTeXEntry, BibTeXEntryType, BibTeXField,
    BibTeXParseError, BibTeXParseResult, ParseError,
};

// Re-export LaTeX and journal macro functions
pub use impress_bibtex::{expand_journal_macro, get_all_journal_macro_names, is_journal_macro};
pub use impress_bibtex::decode_latex;

// Re-export Bdsk-File codec functions (for BibDesk compatibility)
pub use impress_bibtex::{
    bdsk_file_create_fields, bdsk_file_decode, bdsk_file_encode, bdsk_file_extract_all,
};

// Keep the parser module public for backwards compatibility
pub mod parser {
    pub use impress_bibtex::parser::*;
}
