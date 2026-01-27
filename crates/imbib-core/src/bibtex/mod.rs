//! BibTeX parsing and formatting module
//!
//! This module provides a complete BibTeX parser and formatter that maintains
//! round-trip fidelity with the original BibTeX content.
//!
//! All types are defined locally with UniFFI attributes for FFI export.

// Local modules with uniffi attributes
mod bdsk_file;
mod entry;
mod formatter;
mod journal_macros;
mod latex_decoder;
pub mod parser;

// Re-export entry types
pub use entry::{BibTeXEntry, BibTeXEntryType, BibTeXField};

// Re-export parser types and functions
pub use parser::{parse, parse_entry, BibTeXParseError, BibTeXParseResult, ParseError};

// Re-export formatter functions
pub use formatter::{format_entries, format_entry};

// Re-export LaTeX and journal macro functions
pub use journal_macros::{expand_journal_macro, get_all_journal_macro_names, is_journal_macro};
pub use latex_decoder::decode_latex;

// Re-export Bdsk-File codec functions (for BibDesk compatibility)
pub use bdsk_file::{
    bdsk_file_create_fields, bdsk_file_decode, bdsk_file_encode, bdsk_file_extract_all,
};
