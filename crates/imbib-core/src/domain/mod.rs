//! Domain models for imbib
//!
//! These are the canonical representations of all entities, shared across
//! native apps (via UniFFI), web (via WASM), and server (native Rust).
//!
//! This module defines types with UniFFI attributes for FFI export.

// Local modules with uniffi attributes
mod author;
mod collection;
mod enrichment;
mod identifiers;
mod library;
mod linked_file;
mod publication;
mod search_result;
mod tag;
mod validation;

// Re-export all types from local modules
pub use author::{parse_author_string, Author};
pub use collection::Collection;
pub use enrichment::{
    AuthorStats, EnrichmentCapability, EnrichmentData, EnrichmentPriority, OpenAccessStatus,
};
pub use identifiers::Identifiers;
pub use library::Library;
pub use linked_file::{FileStorageType, LinkedFile};
pub use publication::{
    publication_from_bibtex, publication_to_bibtex, publication_to_bibtex_string, Publication,
};
pub use search_result::{PdfLink, PdfLinkType, SearchResult, Source};
pub use tag::Tag;
pub use validation::{is_valid, validate_publication, ValidationError, ValidationSeverity};
