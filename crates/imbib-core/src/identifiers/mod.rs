//! Identifier extraction and validation module
//!
//! Provides functions for extracting and validating:
//! - DOIs (Digital Object Identifiers)
//! - arXiv IDs
//! - ISBNs (International Standard Book Numbers)
//! - Cite key generation
//! - Cross-source identifier resolution
//!
//! This module re-exports types and functions from the `academic-identifiers` crate.

// Re-export all types and functions from academic-identifiers
pub use impress_identifiers::{
    // Cite key functions
    generate_cite_key,
    generate_unique_cite_key,
    make_cite_key_unique,
    sanitize_cite_key,
    // Extractor types and functions
    extract_all,
    extract_arxiv_ids,
    extract_dois,
    extract_isbns,
    ExtractedIdentifier,
    // Resolver types and functions
    can_resolve_to_source,
    enrichment_source_display_name,
    identifier_display_name,
    identifier_url,
    identifier_url_prefix,
    preferred_identifier_for_source,
    resolve_arxiv_to_semantic_scholar,
    resolve_doi_to_semantic_scholar,
    resolve_pmid_to_semantic_scholar,
    supported_identifiers_for_source,
    EnrichmentSource,
    IdentifierType,
    PreferredIdentifier,
    // Validator functions
    is_valid_arxiv_id,
    is_valid_doi,
    is_valid_isbn,
    normalize_doi,
};

// Re-export submodules for backwards compatibility
pub mod cite_key {
    pub use impress_identifiers::cite_key::*;
}

pub mod extractors {
    pub use impress_identifiers::extractors::*;
}

pub mod resolver {
    pub use impress_identifiers::resolver::*;
}

pub mod validators {
    pub use impress_identifiers::validators::*;
}
