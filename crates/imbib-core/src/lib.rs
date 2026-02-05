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

// Flagging and tagging (Phase 3)
pub mod input_mode;
pub mod filter;

pub use input_mode::InputMode;
pub use filter::ReadState;
#[cfg(feature = "native")]
pub use filter::ParsedFilter;

// Phase 3: Full-text search, PDF extraction, and annotations
pub mod annotations;
#[cfg(not(target_arch = "wasm32"))]
pub mod pdf;
pub mod recommendation;

// Re-export main types for convenience
// Re-export types (not functions that are wrapped for FFI)
pub use bibtex::{
    BibTeXEntry, BibTeXEntryType, BibTeXField, BibTeXParseError, BibTeXParseResult, ParseError,
};
pub use deduplication::{DeduplicationMatch, DuplicateGroup};
pub use domain::{
    Author, AuthorStats, Collection, EnrichmentCapability, EnrichmentData, EnrichmentPriority,
    FileStorageType, Identifiers, Library, LinkedFile, OpenAccessStatus, PdfLink, PdfLinkType,
    Publication, SearchResult, Source, Tag, ValidationError, ValidationSeverity,
};
pub use error::FfiError;

// PaperStub is defined in sources/ads.rs
pub use export::{ExportFormat, ExportOptions};
pub use filename::FilenameOptions;
pub use identifiers::{
    CiteKeyFormatValidation, EnrichmentSource, ExtractedIdentifier, IdentifierType,
    PreferredIdentifier,
};
pub use import::{ImportError, ImportFormat, ImportResult};
pub use merge::{Conflict, MergeResult, MergeStrategy};
pub use ris::{RISEntry, RISTag, RISType};
pub use search::{ADSDatabase, QueryLogic};
#[cfg(feature = "native")]
pub use search::{AnnIndex, AnnIndexConfig, AnnIndexItem, AnnSimilarityResult};
#[cfg(not(target_arch = "wasm32"))]
pub use search::{HelpDocument, HelpPlatform, HelpSearchError, HelpSearchIndex, HelpSearchResult};
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
    HeuristicConfidence, HeuristicExtractedFields, PageDimensions, PageText, PdfError,
    PdfMetadata, PdfTextResult, TextMatch, ThumbnailConfig,
};
pub use search::snippets::{extract_snippet, highlight_terms};

pub use recommendation::{
    FeatureType, FeatureVector, LibraryContext, MutedItems, ProfileData, PublicationFeatureInput,
};

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

// Note: BibTeX FFI functions (decode_latex, expand_journal_macro, etc.) are exported
// directly from bibtex module submodules with #[uniffi::export]

// Note: Identifier FFI functions (generate_cite_key, extract_dois, etc.) are exported
// directly from identifiers module submodules with #[uniffi::export]

// Note: Domain FFI functions (parse_author_string, enrichment_*_display_name, etc.)
// are exported directly from domain module submodules with #[uniffi::export]

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
