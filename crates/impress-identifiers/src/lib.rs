//! Identifier extraction and validation for the impress suite
//!
//! Thin wrapper around [`im_identifiers`] that adds UniFFI bindings for Swift/Kotlin FFI.
//! All extraction, validation, and resolution logic lives in the published `im-identifiers`
//! crate; this crate re-exports equivalent types annotated with UniFFI derives.

mod types;

pub use types::{
    EnrichmentSource, ExtractedIdentifier, IdentifierType, PreferredIdentifier,
};

use std::collections::HashMap;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

// ── Extractors ───────────────────────────────────────────────────────────────

/// Extract DOIs from text
pub fn extract_dois(text: String) -> Vec<String> {
    im_identifiers::extract_dois(text)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_dois_ffi(text: String) -> Vec<String> {
    extract_dois(text)
}

/// Extract arXiv IDs from text
pub fn extract_arxiv_ids(text: String) -> Vec<String> {
    im_identifiers::extract_arxiv_ids(text)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_arxiv_ids_ffi(text: String) -> Vec<String> {
    extract_arxiv_ids(text)
}

/// Extract ISBNs from text
pub fn extract_isbns(text: String) -> Vec<String> {
    im_identifiers::extract_isbns(text)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_isbns_ffi(text: String) -> Vec<String> {
    extract_isbns(text)
}

/// Extract all identifiers from text
pub fn extract_all(text: String) -> Vec<ExtractedIdentifier> {
    im_identifiers::extract_all(text)
        .into_iter()
        .map(Into::into)
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_all_ffi(text: String) -> Vec<ExtractedIdentifier> {
    extract_all(text)
}

// ── Validators ───────────────────────────────────────────────────────────────

/// Validate a DOI
pub fn is_valid_doi(doi: String) -> bool {
    im_identifiers::is_valid_doi(doi)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn is_valid_doi_ffi(doi: String) -> bool {
    is_valid_doi(doi)
}

/// Validate an arXiv ID
pub fn is_valid_arxiv_id(arxiv_id: String) -> bool {
    im_identifiers::is_valid_arxiv_id(arxiv_id)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn is_valid_arxiv_id_ffi(arxiv_id: String) -> bool {
    is_valid_arxiv_id(arxiv_id)
}

/// Validate an ISBN (both ISBN-10 and ISBN-13)
pub fn is_valid_isbn(isbn: String) -> bool {
    im_identifiers::is_valid_isbn(isbn)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn is_valid_isbn_ffi(isbn: String) -> bool {
    is_valid_isbn(isbn)
}

/// Normalize a DOI by removing common prefixes and trailing punctuation
pub fn normalize_doi(doi: String) -> String {
    im_identifiers::normalize_doi(doi)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn normalize_doi_ffi(doi: String) -> String {
    normalize_doi(doi)
}

// ── Cite key generation ──────────────────────────────────────────────────────

/// Generate a cite key from author, year, and title
pub fn generate_cite_key(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
) -> String {
    im_identifiers::generate_cite_key(author, year, title)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn generate_cite_key_ffi(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
) -> String {
    generate_cite_key(author, year, title)
}

/// Generate a unique cite key that doesn't conflict with existing keys
pub fn generate_unique_cite_key(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    existing_keys: Vec<String>,
) -> String {
    im_identifiers::generate_unique_cite_key(author, year, title, existing_keys)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn generate_unique_cite_key_ffi(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    existing_keys: Vec<String>,
) -> String {
    generate_unique_cite_key(author, year, title, existing_keys)
}

/// Make a cite key unique by adding suffixes if needed
pub fn make_cite_key_unique(base: String, existing_keys: Vec<String>) -> String {
    im_identifiers::make_cite_key_unique(base, existing_keys)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn make_cite_key_unique_ffi(base: String, existing_keys: Vec<String>) -> String {
    make_cite_key_unique(base, existing_keys)
}

/// Sanitize a cite key by removing invalid characters
pub fn sanitize_cite_key(key: String) -> String {
    im_identifiers::sanitize_cite_key(key)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn sanitize_cite_key_ffi(key: String) -> String {
    sanitize_cite_key(key)
}

// ── Resolver ─────────────────────────────────────────────────────────────────

/// Get the URL prefix for an identifier type
pub fn identifier_url_prefix(id_type: IdentifierType) -> Option<String> {
    im_identifiers::identifier_url_prefix(id_type.into())
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn identifier_url_prefix_ffi(id_type: IdentifierType) -> Option<String> {
    identifier_url_prefix(id_type)
}

/// Get the full URL for an identifier
pub fn identifier_url(id_type: IdentifierType, value: String) -> Option<String> {
    im_identifiers::identifier_url(id_type.into(), value)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn identifier_url_ffi(id_type: IdentifierType, value: String) -> Option<String> {
    identifier_url(id_type, value)
}

/// Get the display name for an identifier type
pub fn identifier_display_name(id_type: IdentifierType) -> String {
    im_identifiers::identifier_display_name(id_type.into())
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn identifier_display_name_ffi(id_type: IdentifierType) -> String {
    identifier_display_name(id_type)
}

/// Get the display name for an enrichment source
pub fn enrichment_source_display_name(source: EnrichmentSource) -> String {
    im_identifiers::enrichment_source_display_name(source.into())
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn enrichment_source_display_name_ffi(source: EnrichmentSource) -> String {
    enrichment_source_display_name(source)
}

/// Check if a set of identifiers can be resolved to a source
pub fn can_resolve_to_source(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> bool {
    im_identifiers::can_resolve_to_source(identifiers, source.into())
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn can_resolve_to_source_ffi(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> bool {
    can_resolve_to_source(identifiers, source)
}

/// Get the preferred identifier for a source from a set of identifiers
pub fn preferred_identifier_for_source(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> Option<PreferredIdentifier> {
    im_identifiers::preferred_identifier_for_source(identifiers, source.into())
        .map(Into::into)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn preferred_identifier_for_source_ffi(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> Option<PreferredIdentifier> {
    preferred_identifier_for_source(identifiers, source)
}

/// Resolve a DOI to a Semantic Scholar paper ID format
pub fn resolve_doi_to_semantic_scholar(doi: String) -> String {
    im_identifiers::resolve_doi_to_semantic_scholar(doi)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn resolve_doi_to_semantic_scholar_ffi(doi: String) -> String {
    resolve_doi_to_semantic_scholar(doi)
}

/// Resolve an arXiv ID to a Semantic Scholar paper ID format
pub fn resolve_arxiv_to_semantic_scholar(arxiv_id: String) -> String {
    im_identifiers::resolve_arxiv_to_semantic_scholar(arxiv_id)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn resolve_arxiv_to_semantic_scholar_ffi(arxiv_id: String) -> String {
    resolve_arxiv_to_semantic_scholar(arxiv_id)
}

/// Resolve a PubMed ID to a Semantic Scholar paper ID format
pub fn resolve_pmid_to_semantic_scholar(pmid: String) -> String {
    im_identifiers::resolve_pmid_to_semantic_scholar(pmid)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn resolve_pmid_to_semantic_scholar_ffi(pmid: String) -> String {
    resolve_pmid_to_semantic_scholar(pmid)
}

/// Get the supported identifier types for a source
pub fn supported_identifiers_for_source(source: EnrichmentSource) -> Vec<String> {
    im_identifiers::supported_identifiers_for_source(source.into())
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn supported_identifiers_for_source_ffi(source: EnrichmentSource) -> Vec<String> {
    supported_identifiers_for_source(source)
}
