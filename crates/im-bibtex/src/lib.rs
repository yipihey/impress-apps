//! # im-bibtex
//!
//! Fast BibTeX parser, formatter, and toolkit.
//!
//! ## Features
//!
//! - **Parsing**: Robust nom-based parser handling `@string`, `@preamble`, `@comment`,
//!   all standard entry types, braced/quoted values, string concatenation, nested braces
//! - **Formatting**: Round-trip BibTeX formatting with configurable output
//! - **LaTeX decoding**: Convert LaTeX accents, symbols, and math to Unicode
//! - **Journal macros**: Expand AASTeX abbreviations (`\apj` → "Astrophysical Journal")
//! - **BibDesk support**: Decode/encode `Bdsk-File-*` fields (base64 binary plist)
//!
//! ## Quick Start
//!
//! ```rust
//! use im_bibtex::{parse, format_entry, decode_latex};
//!
//! // Parse a BibTeX string
//! let result = parse("@article{Smith2024, title = {A Great Paper}, year = {2024}}".into()).unwrap();
//! assert_eq!(result.entries.len(), 1);
//! assert_eq!(result.entries[0].title(), Some("A Great Paper"));
//!
//! // Format an entry back to BibTeX
//! let bibtex = format_entry(result.entries[0].clone());
//! assert!(bibtex.contains("@article{Smith2024,"));
//!
//! // Decode LaTeX to Unicode
//! let clean = decode_latex(r#"Schr\"{o}dinger"#.into());
//! assert_eq!(clean, "Schrödinger");
//! ```

mod bdsk_file;
pub mod entry;
mod formatter;
mod journal_macros;
mod latex_decoder;
pub mod mcp;
pub mod parser;

#[cfg(feature = "python")]
pub mod python;

pub use entry::{BibTeXEntry, BibTeXEntryType, BibTeXField};
pub use formatter::{escape_value, format_complete, format_entries, format_entry};
pub use parser::{parse, parse_entry, BibTeXParseError, BibTeXParseResult, ParseError};

// LaTeX and journal macro functions
pub use journal_macros::{expand_journal_macro, get_all_journal_macro_names, is_journal_macro};
pub use latex_decoder::decode_latex;

// BibDesk file reference codec
pub use bdsk_file::{
    bdsk_file_create_fields, bdsk_file_decode, bdsk_file_encode, bdsk_file_extract_all,
};
