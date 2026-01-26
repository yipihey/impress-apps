//! imbib-core: Cross-platform core library for imbib publication manager
//!
//! This library provides pure Rust implementations of:
//! - BibTeX parsing and formatting
//! - RIS parsing and formatting
//! - Identifier extraction (DOI, arXiv, ISBN)
//! - Deduplication algorithms
//! - Text processing (LaTeX decoding, MathML parsing, author parsing)
//! - Search query building and parsing (ADS, arXiv)
//! - URL scheme automation
//!
//! These implementations are exposed to Swift/Kotlin via UniFFI bindings.

pub mod automation;
pub mod bibtex;
pub mod conversions;
pub mod deduplication;
pub mod domain;
pub mod error;
pub mod export;
pub mod filename;
#[cfg(feature = "native")]
pub mod http;
pub mod identifiers;
pub mod import;
pub mod merge;
pub mod ris;
pub mod search;
#[cfg(feature = "native")]
pub mod sources;
pub mod text;

// Phase 3: Full-text search, PDF extraction, and annotations
pub mod annotations;
#[cfg(not(target_arch = "wasm32"))]
pub mod pdf;

// Re-export main types for convenience
// Re-export types (not functions that are wrapped for FFI)
pub use bibtex::{
    BibTeXEntry, BibTeXEntryType, BibTeXField, BibTeXParseError, BibTeXParseResult, ParseError,
};
pub use error::FfiError;
pub use deduplication::{DeduplicationMatch, DuplicateGroup};
pub use domain::{
    Author, AuthorStats, Collection, EnrichmentCapability, EnrichmentData, EnrichmentPriority,
    FileStorageType, Identifiers, Library, LinkedFile, OpenAccessStatus, PdfLink, PdfLinkType,
    Publication, SearchResult, Source, Tag, ValidationError, ValidationSeverity,
};

// PaperStub is defined in sources/ads.rs
pub use export::{ExportFormat, ExportOptions};
pub use filename::FilenameOptions;
pub use identifiers::ExtractedIdentifier;
pub use import::{ImportError, ImportFormat, ImportResult};
pub use merge::{Conflict, MergeResult, MergeStrategy};
pub use ris::{RISEntry, RISTag, RISType};
pub use search::{ADSDatabase, QueryLogic};
#[cfg(feature = "native")]
pub use search::{AnnIndex, AnnIndexConfig, AnnIndexItem, AnnSimilarityResult};
#[cfg(not(target_arch = "wasm32"))]
pub use search::{SearchHit, SearchIndex, SearchIndexError};
#[cfg(feature = "native")]
pub use sources::ads::PaperStub;

pub use annotations::{
    Annotation, AnnotationColor, AnnotationHistory, AnnotationOperation, AnnotationStorageError,
    AnnotationType, DrawingAnnotation, DrawingStroke, Point, PublicationAnnotations, Rect,
};
#[cfg(not(target_arch = "wasm32"))]
pub use pdf::{
    extract_pdf_text, generate_thumbnail, get_page_count, get_page_dimensions, search_in_pdf,
    PageDimensions, PageText, PdfError, PdfMetadata, PdfTextResult, TextMatch, ThumbnailConfig,
};
pub use search::snippets::{extract_snippet, highlight_terms};

#[cfg(feature = "embeddings")]
pub use search::{
    cosine_similarity, find_similar, PublicationEmbedding, SimilarityResult, StoredEmbedding,
};

// Setup UniFFI - use proc macros only, no UDL file (native only)
#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

/// Returns the version of imbib-core
#[cfg(feature = "native")]
#[uniffi::export]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Hello world function to verify FFI setup
#[cfg(feature = "native")]
#[uniffi::export]
pub fn hello_from_rust() -> String {
    "Hello from imbib-core (Rust)!".to_string()
}

// ===== BibTeX FFI Functions =====
/// These wrap the internal functions with prefixed names to avoid conflicts

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bibtex_parse(input: String) -> Result<BibTeXParseResult, FfiError> {
    bibtex::parse(input).map_err(FfiError::from)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bibtex_parse_entry(input: String) -> Result<BibTeXEntry, FfiError> {
    bibtex::parse_entry(input).map_err(FfiError::from)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bibtex_format_entry(entry: BibTeXEntry) -> String {
    bibtex::format_entry(entry)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bibtex_format_entries(entries: Vec<BibTeXEntry>) -> String {
    bibtex::format_entries(entries)
}

// ===== RIS FFI Functions =====

#[cfg(feature = "native")]
#[uniffi::export]
pub fn ris_parse(input: String) -> Result<Vec<RISEntry>, FfiError> {
    ris::parse(input).map_err(FfiError::from)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn ris_format_entry(entry: RISEntry) -> String {
    ris::format_entry(entry)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn ris_to_bibtex(entry: RISEntry) -> BibTeXEntry {
    ris::to_bibtex(entry)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn ris_from_bibtex(entry: BibTeXEntry) -> RISEntry {
    ris::from_bibtex(entry)
}

// Note: Identifier and deduplication functions are exported directly
// from their modules with #[uniffi::export], so no wrappers needed here.
// They have unique names that don't conflict.

// ===== PDF FFI Functions =====
// These wrap the internal functions with byte slice parameters for UniFFI compatibility

/// Extract all text from a PDF file.
///
/// Returns structured text content with per-page breakdown for search indexing.
#[cfg(all(feature = "native", not(target_arch = "wasm32")))]
#[uniffi::export]
pub fn pdf_extract_text(pdf_bytes: Vec<u8>) -> Result<PdfTextResult, PdfError> {
    pdf::extract_pdf_text(&pdf_bytes)
}

/// Search for text within a PDF and return matches with context.
#[cfg(all(feature = "native", not(target_arch = "wasm32")))]
#[uniffi::export]
pub fn pdf_search(
    pdf_bytes: Vec<u8>,
    query: String,
    max_results: u32,
) -> Result<Vec<TextMatch>, PdfError> {
    pdf::search_in_pdf(&pdf_bytes, &query, max_results as usize)
}

/// Generate a thumbnail for a PDF page.
///
/// Returns RGBA pixel data that can be converted to an image.
/// Default config: 200x280 pixels, page 1.
#[cfg(all(feature = "native", not(target_arch = "wasm32")))]
#[uniffi::export]
pub fn pdf_generate_thumbnail(
    pdf_bytes: Vec<u8>,
    config: ThumbnailConfig,
) -> Result<PdfThumbnail, PdfError> {
    let rgba_bytes = pdf::generate_thumbnail(&pdf_bytes, &config)?;

    // Get actual rendered dimensions (may differ from config due to aspect ratio preservation)
    let metadata = pdf::extract_pdf_metadata(&pdf_bytes)?;
    let page_dims = pdf::get_page_dimensions(&pdf_bytes, config.page_number)?;

    // Calculate actual rendered size (same logic as thumbnails.rs)
    let scale_x = config.width as f32 / page_dims.width;
    let scale_y = config.height as f32 / page_dims.height;
    let scale = scale_x.min(scale_y);
    let actual_width = (page_dims.width * scale) as u32;
    let actual_height = (page_dims.height * scale) as u32;

    Ok(PdfThumbnail {
        rgba_bytes,
        width: actual_width,
        height: actual_height,
        page_count: metadata.page_count,
    })
}

/// Get the number of pages in a PDF.
#[cfg(all(feature = "native", not(target_arch = "wasm32")))]
#[uniffi::export]
pub fn pdf_get_page_count(pdf_bytes: Vec<u8>) -> Result<u32, PdfError> {
    pdf::get_page_count(&pdf_bytes)
}

/// Get dimensions of a specific page.
#[cfg(all(feature = "native", not(target_arch = "wasm32")))]
#[uniffi::export]
pub fn pdf_get_page_dimensions(
    pdf_bytes: Vec<u8>,
    page_number: u32,
) -> Result<PageDimensions, PdfError> {
    pdf::get_page_dimensions(&pdf_bytes, page_number)
}

/// PDF thumbnail result with RGBA pixel data and dimensions.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PdfThumbnail {
    /// Raw RGBA pixel data (4 bytes per pixel: R, G, B, A)
    pub rgba_bytes: Vec<u8>,
    /// Actual rendered width in pixels
    pub width: u32,
    /// Actual rendered height in pixels
    pub height: u32,
    /// Total page count in the PDF
    pub page_count: u32,
}

// ===== BibTeX FFI Functions (without prefix for compatibility) =====

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse(input: String) -> Result<BibTeXParseResult, FfiError> {
    bibtex::parse(input).map_err(FfiError::from)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_entry(input: String) -> Result<BibTeXEntry, FfiError> {
    bibtex::parse_entry(input).map_err(FfiError::from)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn decode_latex(input: String) -> String {
    bibtex::decode_latex(input)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn expand_journal_macro(value: String) -> String {
    bibtex::expand_journal_macro(value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn get_all_journal_macro_names() -> Vec<String> {
    bibtex::get_all_journal_macro_names()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_journal_macro(value: String) -> bool {
    bibtex::is_journal_macro(value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_create_fields(paths: Vec<String>) -> std::collections::HashMap<String, String> {
    impress_bibtex::bdsk_file_create_fields(paths)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_decode(value: String) -> Option<String> {
    impress_bibtex::bdsk_file_decode(value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_encode(relative_path: String) -> Option<String> {
    impress_bibtex::bdsk_file_encode(relative_path)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_extract_all(fields: std::collections::HashMap<String, String>) -> Vec<String> {
    impress_bibtex::bdsk_file_extract_all(fields)
}

// ===== Identifier FFI Functions =====

#[cfg(feature = "native")]
#[uniffi::export]
pub fn generate_cite_key(author: Option<String>, year: Option<String>, title: Option<String>) -> String {
    identifiers::generate_cite_key(author, year, title)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn generate_unique_cite_key(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    existing_keys: Vec<String>,
) -> String {
    identifiers::generate_unique_cite_key(author, year, title, existing_keys)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn make_cite_key_unique(base: String, existing_keys: Vec<String>) -> String {
    identifiers::make_cite_key_unique(base, existing_keys)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn sanitize_cite_key(key: String) -> String {
    identifiers::sanitize_cite_key(key)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_all(text: String) -> Vec<ExtractedIdentifier> {
    identifiers::extract_all(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_arxiv_ids(text: String) -> Vec<String> {
    identifiers::extract_arxiv_ids(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_dois(text: String) -> Vec<String> {
    identifiers::extract_dois(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_isbns(text: String) -> Vec<String> {
    identifiers::extract_isbns(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn can_resolve_to_source(
    identifiers: std::collections::HashMap<String, String>,
    source: identifiers::EnrichmentSource,
) -> bool {
    identifiers::can_resolve_to_source(identifiers, source)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_source_display_name(source: identifiers::EnrichmentSource) -> String {
    identifiers::enrichment_source_display_name(source)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn identifier_display_name(id_type: identifiers::IdentifierType) -> String {
    identifiers::identifier_display_name(id_type)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn identifier_url(id_type: identifiers::IdentifierType, value: String) -> Option<String> {
    identifiers::identifier_url(id_type, value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn identifier_url_prefix(id_type: identifiers::IdentifierType) -> Option<String> {
    identifiers::identifier_url_prefix(id_type)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn preferred_identifier_for_source(
    identifiers: std::collections::HashMap<String, String>,
    source: identifiers::EnrichmentSource,
) -> Option<identifiers::PreferredIdentifier> {
    identifiers::preferred_identifier_for_source(identifiers, source)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn resolve_arxiv_to_semantic_scholar(arxiv_id: String) -> String {
    identifiers::resolve_arxiv_to_semantic_scholar(arxiv_id)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn resolve_doi_to_semantic_scholar(doi: String) -> String {
    identifiers::resolve_doi_to_semantic_scholar(doi)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn resolve_pmid_to_semantic_scholar(pmid: String) -> String {
    identifiers::resolve_pmid_to_semantic_scholar(pmid)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn supported_identifiers_for_source(source: identifiers::EnrichmentSource) -> Vec<String> {
    identifiers::supported_identifiers_for_source(source)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_arxiv_id(arxiv_id: String) -> bool {
    identifiers::is_valid_arxiv_id(arxiv_id)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_doi(doi: String) -> bool {
    identifiers::is_valid_doi(doi)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_isbn(isbn: String) -> bool {
    identifiers::is_valid_isbn(isbn)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_doi(doi: String) -> String {
    identifiers::normalize_doi(doi)
}

// ===== Domain FFI Functions =====

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_capability_display_name(capability: EnrichmentCapability) -> String {
    capability.display_name().to_string()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_data_is_stale(data: EnrichmentData, threshold_days: i32) -> bool {
    data.is_stale(threshold_days)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_priority_display_name(priority: EnrichmentPriority) -> String {
    priority.display_name().to_string()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn open_access_status_display_name(status: OpenAccessStatus) -> String {
    status.display_name().to_string()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_author_string(input: String) -> Vec<Author> {
    impress_domain::parse_author_string(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        assert!(!version().is_empty());
    }

    #[test]
    fn test_hello() {
        assert_eq!(hello_from_rust(), "Hello from imbib-core (Rust)!");
    }

    #[test]
    fn test_bibtex_parse() {
        let input = r#"@article{Smith2024, title = {Test}}"#;
        let result = bibtex_parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
    }
}
