//! BibTeX parsing and formatting
//!
//! This crate provides a complete BibTeX parser and formatter that maintains
//! round-trip fidelity with the original BibTeX content.
//!
//! Features:
//! - Nom-based parser for robust BibTeX parsing
//! - LaTeX special character decoding
//! - Journal macro expansion
//! - BibDesk Bdsk-File field support
//! - Round-trip formatting

mod bdsk_file;
mod entry;
mod formatter;
mod journal_macros;
mod latex_decoder;
pub mod parser;

pub use entry::{BibTeXEntry, BibTeXEntryType, BibTeXField};
pub use formatter::{format_entries, format_entry};
pub use parser::{parse, parse_entry, BibTeXParseError, BibTeXParseResult, ParseError};

// Re-export LaTeX and journal macro functions
pub use journal_macros::{expand_journal_macro, get_all_journal_macro_names, is_journal_macro};
pub use latex_decoder::decode_latex;

// Re-export Bdsk-File codec functions (for BibDesk compatibility)
pub use bdsk_file::{
    bdsk_file_create_fields, bdsk_file_decode, bdsk_file_encode, bdsk_file_extract_all,
};

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
