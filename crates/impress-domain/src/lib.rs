//! Academic domain types shared between imbib and imprint
//!
//! This crate provides the canonical domain models for academic publication management:
//! - Publication: A scientific paper, book, thesis, etc.
//! - Author: Researcher with name, ORCID, affiliation
//! - Identifiers: DOI, arXiv, ISBN, etc.
//! - Annotation: PDF highlights, notes, drawings
//! - LinkedFile: PDF and attachment references
//! - Collection, Tag, Library: Organization structures
//! - Enrichment: Citation counts, open access status

pub mod annotation;
pub mod author;
pub mod collection;
pub mod enrichment;
pub mod identifiers;
pub mod library;
pub mod linked_file;
pub mod manuscript;
pub mod publication;
pub mod search_result;
pub mod tag;
pub mod validation;

pub use annotation::*;
pub use author::*;
pub use collection::*;
pub use enrichment::*;
pub use identifiers::*;
pub use library::*;
pub use linked_file::*;
pub use manuscript::*;
pub use publication::*;
pub use search_result::*;
pub use tag::*;
pub use validation::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
