//! BibTeX parsing and formatting for the impress suite
//!
//! Thin wrapper around [`im_bibtex`] that adds UniFFI bindings for Swift/Kotlin FFI.
//! All parsing, formatting, and decoding logic lives in the published `im-bibtex` crate;
//! this crate re-exports equivalent types annotated with UniFFI derives and provides
//! `_ffi` entry points for the binding generator.

mod types;

pub use types::{BibTeXEntry, BibTeXEntryType, BibTeXField};
pub use types::{BibTeXParseError, BibTeXParseResult, ParseError};

use std::collections::HashMap;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

// ── Parsing ──────────────────────────────────────────────────────────────────

/// Parse a BibTeX string
pub fn parse(input: String) -> Result<BibTeXParseResult, ParseError> {
    im_bibtex::parse(input).map(Into::into).map_err(Into::into)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn parse_ffi(input: String) -> Result<BibTeXParseResult, ParseError> {
    parse(input)
}

/// Parse a single BibTeX entry
pub fn parse_entry(input: String) -> Result<BibTeXEntry, ParseError> {
    im_bibtex::parse_entry(input)
        .map(Into::into)
        .map_err(Into::into)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn parse_entry_ffi(input: String) -> Result<BibTeXEntry, ParseError> {
    parse_entry(input)
}

// ── Formatting ───────────────────────────────────────────────────────────────

/// Format a single BibTeX entry to string
pub fn format_entry(entry: BibTeXEntry) -> String {
    im_bibtex::format_entry(entry.into())
}

/// Format multiple entries to a single BibTeX string
pub fn format_entries(entries: Vec<BibTeXEntry>) -> String {
    im_bibtex::format_entries(entries.into_iter().map(Into::into).collect())
}

// ── LaTeX decoding ───────────────────────────────────────────────────────────

/// Decode LaTeX special characters to Unicode
pub fn decode_latex(input: String) -> String {
    im_bibtex::decode_latex(input)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn decode_latex_ffi(input: String) -> String {
    decode_latex(input)
}

// ── Journal macros ───────────────────────────────────────────────────────────

/// Expand a journal macro to its full name
pub fn expand_journal_macro(value: String) -> String {
    im_bibtex::expand_journal_macro(value)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn expand_journal_macro_ffi(value: String) -> String {
    expand_journal_macro(value)
}

/// Check if a value is a journal macro
pub fn is_journal_macro(value: String) -> bool {
    im_bibtex::is_journal_macro(value)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn is_journal_macro_ffi(value: String) -> bool {
    is_journal_macro(value)
}

/// Get all journal macro names
pub fn get_all_journal_macro_names() -> Vec<String> {
    im_bibtex::get_all_journal_macro_names()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_all_journal_macro_names_ffi() -> Vec<String> {
    get_all_journal_macro_names()
}

// ── BibDesk file references ──────────────────────────────────────────────────

/// Decode a Bdsk-File-* field value to extract the relative path
pub fn bdsk_file_decode(value: String) -> Option<String> {
    im_bibtex::bdsk_file_decode(value)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn bdsk_file_decode_ffi(value: String) -> Option<String> {
    bdsk_file_decode(value)
}

/// Encode a relative path as a Bdsk-File field value
pub fn bdsk_file_encode(relative_path: String) -> Option<String> {
    im_bibtex::bdsk_file_encode(relative_path)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn bdsk_file_encode_ffi(relative_path: String) -> Option<String> {
    bdsk_file_encode(relative_path)
}

/// Extract all Bdsk-File paths from a fields map
pub fn bdsk_file_extract_all(fields: HashMap<String, String>) -> Vec<String> {
    im_bibtex::bdsk_file_extract_all(fields)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn bdsk_file_extract_all_ffi(fields: HashMap<String, String>) -> Vec<String> {
    bdsk_file_extract_all(fields)
}

/// Create Bdsk-File fields from a list of paths
pub fn bdsk_file_create_fields(paths: Vec<String>) -> HashMap<String, String> {
    im_bibtex::bdsk_file_create_fields(paths)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn bdsk_file_create_fields_ffi(paths: Vec<String>) -> HashMap<String, String> {
    bdsk_file_create_fields(paths)
}
