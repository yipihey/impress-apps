//! RIS (Research Information Systems) format parsing and formatting
//!
//! This module provides parsing and formatting for the RIS citation format,
//! as well as bidirectional conversion between RIS and BibTeX.

mod converter;
mod entry;
mod formatter;
mod parser;

#[cfg(feature = "native")]
pub use converter::{from_bibtex, to_bibtex};
pub use entry::{RISEntry, RISTag, RISType};
pub use formatter::format_entry;
pub use parser::parse;
