//! Identifier extraction and validation module
//!
//! Provides functions for extracting and validating:
//! - DOIs (Digital Object Identifiers)
//! - arXiv IDs
//! - ISBNs (International Standard Book Numbers)
//! - Cite key generation
//! - Cross-source identifier resolution
//!
//! All types are defined locally with UniFFI attributes for FFI export.

// Local modules with uniffi attributes
mod cite_key;
mod extractors;
mod resolver;
mod validators;

// Re-export cite key functions
pub use cite_key::{
    generate_cite_key, generate_unique_cite_key, make_cite_key_unique, sanitize_cite_key,
};

// Re-export extractor types and functions
pub use extractors::{extract_all, extract_arxiv_ids, extract_dois, extract_isbns, ExtractedIdentifier};

// Re-export resolver types and functions
pub use resolver::{
    can_resolve_to_source, enrichment_source_display_name, identifier_display_name, identifier_url,
    identifier_url_prefix, preferred_identifier_for_source, resolve_arxiv_to_semantic_scholar,
    resolve_doi_to_semantic_scholar, resolve_pmid_to_semantic_scholar,
    supported_identifiers_for_source, EnrichmentSource, IdentifierType, PreferredIdentifier,
};

// Re-export validator functions
pub use validators::{is_valid_arxiv_id, is_valid_doi, is_valid_isbn, normalize_doi};
