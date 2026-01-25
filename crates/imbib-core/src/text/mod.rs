//! Text processing module
//!
//! This module provides text processing utilities for scientific publications:
//! - MathML parsing and Unicode conversion
//! - Scientific text preprocessing
//! - Author name parsing and normalization

mod author_parser;
mod mathml_parser;
mod scientific_parser;

pub use author_parser::{
    extract_first_author_last_name, extract_first_meaningful_word, extract_surname,
    normalize_author_name, split_authors,
};
// Note: sanitize_cite_key is exported from identifiers module
pub use mathml_parser::parse_mathml;
pub use scientific_parser::{
    decode_html_entities, preprocess_scientific_text, replace_greek_letters, strip_font_commands,
    strip_standalone_braces,
};
