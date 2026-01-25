//! Domain models for imbib
//!
//! These are the canonical representations of all entities, shared across
//! native apps (via UniFFI), web (via WASM), and server (native Rust).
//!
//! This module re-exports types from the `academic-domain` crate.

// Re-export everything from academic-domain
pub use impress_domain::{
    Author, AuthorStats, Collection, EnrichmentCapability, EnrichmentData, EnrichmentPriority,
    FileStorageType, Identifiers, Library, LinkedFile, OpenAccessStatus, PdfLink, PdfLinkType,
    Publication, SearchResult, Source, Tag, ValidationError, ValidationSeverity,
};

// Re-export submodules for backwards compatibility
pub mod author {
    pub use impress_domain::author::*;
}

pub mod collection {
    pub use impress_domain::collection::*;
}

pub mod enrichment {
    pub use impress_domain::enrichment::*;
}

pub mod identifiers {
    pub use impress_domain::identifiers::*;
}

pub mod library {
    pub use impress_domain::library::*;
}

pub mod linked_file {
    pub use impress_domain::linked_file::*;
}

pub mod publication {
    pub use impress_domain::publication::*;
}

pub mod search_result {
    pub use impress_domain::search_result::*;
}

pub mod tag {
    pub use impress_domain::tag::*;
}

pub mod validation {
    pub use impress_domain::validation::*;
}
