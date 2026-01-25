# Rust Migration Phase 3: Full-Text Search, PDF Extraction, Semantic Search & Annotations

You are implementing Phase 3 of the Rust core expansion for imbib. Phases 1-2 (domain models, source plugins, query parsing) should already be complete. This phase adds powerful search capabilities using the Rust ecosystem.

## Project Context

**imbib** is a cross-platform (macOS/iOS) scientific publication manager with a future web app. The Rust core now handles domain models, parsing, and source plugins.

**Phase 3 Goals:**
1. **Full-text search** with Tantivy (replace Spotlight/PDFKit search)
2. **PDF text extraction** with pdfium-render (cross-platform, WASM-compatible)
3. **Semantic search** with fastembed (find similar papers by meaning)
4. **Annotation storage** in Rust (cross-platform sync)

**Key Requirement:** All implementations must work in WASM for the future web app.

---

## New Dependencies

**Update `imbib-core/Cargo.toml`:**

```toml
[dependencies]
# Existing dependencies...
uniffi = { version = "0.28", features = ["tokio"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
uuid = { version = "1", features = ["v4"] }
regex = "1.10"
lazy_static = "1.4"
thiserror = "1.0"
tokio = { version = "1", features = ["rt", "macros"], optional = true }

# NEW: Phase 3 dependencies
tantivy = "0.22"
fastembed = { version = "4", optional = true }
chrono = { version = "0.4", features = ["serde"] }

[target.'cfg(not(target_arch = "wasm32"))'.dependencies]
pdfium-render = "0.8"
reqwest = { version = "0.12", features = ["json"], optional = true }

[target.'cfg(target_arch = "wasm32")'.dependencies]
pdfium-render = { version = "0.8", features = ["wasm"] }

[features]
default = ["native"]
native = ["uniffi", "tokio", "reqwest", "fastembed"]
wasm = []
embeddings = ["fastembed"]  # Optional: semantic search requires ~100MB model
```

---

## Phase 3.1: Tantivy Full-Text Search Index

Create a comprehensive search index that replaces platform-specific search.

**Create directory:** `imbib-core/src/search/`

**Create:** `imbib-core/src/search/mod.rs`

```rust
//! Full-text search with Tantivy
//!
//! Provides unified search across:
//! - Publication metadata (title, authors, abstract)
//! - PDF full text
//! - Notes and annotations
//!
//! Works on native platforms and WASM.

pub mod index;
pub mod query;
pub mod schema;
pub mod snippets;

#[cfg(feature = "embeddings")]
pub mod semantic;

pub use index::*;
pub use query::*;
pub use schema::*;
pub use snippets::*;

#[cfg(feature = "embeddings")]
pub use semantic::*;
```

**Create:** `imbib-core/src/search/schema.rs`

```rust
//! Tantivy schema definition for publication search

use tantivy::schema::{
    Schema, SchemaBuilder, FAST, INDEXED, STORED, STRING, TEXT,
    TextFieldIndexing, TextOptions, IndexRecordOption,
};

/// Field names for the search index
pub mod fields {
    pub const ID: &str = "id";
    pub const CITE_KEY: &str = "cite_key";
    pub const TITLE: &str = "title";
    pub const AUTHORS: &str = "authors";
    pub const ABSTRACT: &str = "abstract";
    pub const FULL_TEXT: &str = "full_text";
    pub const YEAR: &str = "year";
    pub const JOURNAL: &str = "journal";
    pub const TAGS: &str = "tags";
    pub const NOTES: &str = "notes";
    pub const DOI: &str = "doi";
    pub const ARXIV_ID: &str = "arxiv_id";
    pub const LIBRARY_ID: &str = "library_id";
}

/// Build the Tantivy schema for publications
pub fn build_schema() -> Schema {
    let mut schema_builder = SchemaBuilder::new();

    // Stored fields (returned in results)
    schema_builder.add_text_field(fields::ID, STRING | STORED);
    schema_builder.add_text_field(fields::CITE_KEY, STRING | STORED);

    // Full-text searchable with positions (for phrase queries and highlighting)
    let text_options = TextOptions::default()
        .set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("en_stem")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions)
        )
        .set_stored();

    schema_builder.add_text_field(fields::TITLE, text_options.clone());
    schema_builder.add_text_field(fields::AUTHORS, text_options.clone());
    schema_builder.add_text_field(fields::ABSTRACT, text_options.clone());

    // Full text - indexed but not stored (too large)
    let fulltext_options = TextOptions::default()
        .set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("en_stem")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions)
        );
    schema_builder.add_text_field(fields::FULL_TEXT, fulltext_options);

    // Faceted/filterable fields
    schema_builder.add_u64_field(fields::YEAR, INDEXED | STORED | FAST);
    schema_builder.add_text_field(fields::JOURNAL, TEXT | STORED);
    schema_builder.add_text_field(fields::TAGS, TEXT | STORED);
    schema_builder.add_text_field(fields::NOTES, text_options);

    // Identifier fields (exact match)
    schema_builder.add_text_field(fields::DOI, STRING | STORED);
    schema_builder.add_text_field(fields::ARXIV_ID, STRING | STORED);
    schema_builder.add_text_field(fields::LIBRARY_ID, STRING | STORED);

    schema_builder.build()
}

/// Tantivy tokenizer configuration
pub fn configure_tokenizers(index: &tantivy::Index) {
    let tokenizer_manager = index.tokenizers();

    // English stemming tokenizer
    tokenizer_manager.register(
        "en_stem",
        tantivy::tokenizer::TextAnalyzer::builder(
            tantivy::tokenizer::SimpleTokenizer::default()
        )
        .filter(tantivy::tokenizer::RemoveLongFilter::limit(40))
        .filter(tantivy::tokenizer::LowerCaser)
        .filter(tantivy::tokenizer::Stemmer::new(tantivy::tokenizer::Language::English))
        .build()
    );
}
```

**Create:** `imbib-core/src/search/index.rs`

```rust
//! Search index management

use crate::domain::Publication;
use super::schema::{self, fields, build_schema, configure_tokenizers};
use tantivy::{
    Index, IndexWriter, IndexReader, ReloadPolicy,
    doc, Term,
    collector::TopDocs,
    query::{QueryParser, BooleanQuery, TermQuery, Occur},
    schema::Field,
    TantivyDocument,
};
use std::path::Path;
use std::sync::Arc;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SearchIndexError {
    #[error("Index error: {0}")]
    IndexError(String),
    #[error("Query error: {0}")]
    QueryError(String),
    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),
}

impl From<tantivy::TantivyError> for SearchIndexError {
    fn from(e: tantivy::TantivyError) -> Self {
        SearchIndexError::IndexError(e.to_string())
    }
}

impl From<tantivy::query::QueryParserError> for SearchIndexError {
    fn from(e: tantivy::query::QueryParserError) -> Self {
        SearchIndexError::QueryError(e.to_string())
    }
}

/// Search index for publications
pub struct SearchIndex {
    index: Index,
    reader: IndexReader,
    schema: tantivy::schema::Schema,
    // Field handles for quick access
    id_field: Field,
    cite_key_field: Field,
    title_field: Field,
    authors_field: Field,
    abstract_field: Field,
    full_text_field: Field,
    year_field: Field,
    journal_field: Field,
    tags_field: Field,
    notes_field: Field,
    doi_field: Field,
    arxiv_id_field: Field,
    library_id_field: Field,
}

impl SearchIndex {
    /// Create or open an index at the given path
    pub fn open(path: &Path) -> Result<Self, SearchIndexError> {
        let schema = build_schema();

        let index = if path.exists() {
            Index::open_in_dir(path)?
        } else {
            std::fs::create_dir_all(path)?;
            Index::create_in_dir(path, schema.clone())?
        };

        configure_tokenizers(&index);

        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::OnCommitWithDelay)
            .try_into()?;

        Ok(Self {
            id_field: schema.get_field(fields::ID).unwrap(),
            cite_key_field: schema.get_field(fields::CITE_KEY).unwrap(),
            title_field: schema.get_field(fields::TITLE).unwrap(),
            authors_field: schema.get_field(fields::AUTHORS).unwrap(),
            abstract_field: schema.get_field(fields::ABSTRACT).unwrap(),
            full_text_field: schema.get_field(fields::FULL_TEXT).unwrap(),
            year_field: schema.get_field(fields::YEAR).unwrap(),
            journal_field: schema.get_field(fields::JOURNAL).unwrap(),
            tags_field: schema.get_field(fields::TAGS).unwrap(),
            notes_field: schema.get_field(fields::NOTES).unwrap(),
            doi_field: schema.get_field(fields::DOI).unwrap(),
            arxiv_id_field: schema.get_field(fields::ARXIV_ID).unwrap(),
            library_id_field: schema.get_field(fields::LIBRARY_ID).unwrap(),
            index,
            reader,
            schema,
        })
    }

    /// Create an in-memory index (for testing or WASM)
    pub fn in_memory() -> Result<Self, SearchIndexError> {
        let schema = build_schema();
        let index = Index::create_in_ram(schema.clone());

        configure_tokenizers(&index);

        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        Ok(Self {
            id_field: schema.get_field(fields::ID).unwrap(),
            cite_key_field: schema.get_field(fields::CITE_KEY).unwrap(),
            title_field: schema.get_field(fields::TITLE).unwrap(),
            authors_field: schema.get_field(fields::AUTHORS).unwrap(),
            abstract_field: schema.get_field(fields::ABSTRACT).unwrap(),
            full_text_field: schema.get_field(fields::FULL_TEXT).unwrap(),
            year_field: schema.get_field(fields::YEAR).unwrap(),
            journal_field: schema.get_field(fields::JOURNAL).unwrap(),
            tags_field: schema.get_field(fields::TAGS).unwrap(),
            notes_field: schema.get_field(fields::NOTES).unwrap(),
            doi_field: schema.get_field(fields::DOI).unwrap(),
            arxiv_id_field: schema.get_field(fields::ARXIV_ID).unwrap(),
            library_id_field: schema.get_field(fields::LIBRARY_ID).unwrap(),
            index,
            reader,
            schema,
        })
    }

    /// Get an index writer
    pub fn writer(&self, heap_size: usize) -> Result<IndexWriter, SearchIndexError> {
        Ok(self.index.writer(heap_size)?)
    }

    /// Index a publication
    pub fn index_publication(
        &self,
        writer: &mut IndexWriter,
        publication: &Publication,
        full_text: Option<&str>,
    ) -> Result<(), SearchIndexError> {
        // Delete existing document first
        writer.delete_term(Term::from_field_text(self.id_field, &publication.id));

        let mut doc = TantivyDocument::new();

        doc.add_text(self.id_field, &publication.id);
        doc.add_text(self.cite_key_field, &publication.cite_key);
        doc.add_text(self.title_field, &publication.title);

        // Combine author names
        let authors_text = publication.authors
            .iter()
            .map(|a| a.display_name())
            .collect::<Vec<_>>()
            .join(", ");
        doc.add_text(self.authors_field, &authors_text);

        if let Some(abstract_text) = &publication.abstract_text {
            doc.add_text(self.abstract_field, abstract_text);
        }

        if let Some(text) = full_text {
            doc.add_text(self.full_text_field, text);
        }

        if let Some(year) = publication.year {
            doc.add_u64(self.year_field, year as u64);
        }

        if let Some(journal) = &publication.journal {
            doc.add_text(self.journal_field, journal);
        }

        // Index tags
        for tag in &publication.tags {
            doc.add_text(self.tags_field, tag);
        }

        // Index notes
        if let Some(note) = &publication.note {
            doc.add_text(self.notes_field, note);
        }

        // Identifiers
        if let Some(doi) = &publication.identifiers.doi {
            doc.add_text(self.doi_field, doi);
        }
        if let Some(arxiv_id) = &publication.identifiers.arxiv_id {
            doc.add_text(self.arxiv_id_field, arxiv_id);
        }
        if let Some(library_id) = &publication.library_id {
            doc.add_text(self.library_id_field, library_id);
        }

        writer.add_document(doc)?;
        Ok(())
    }

    /// Delete a publication from the index
    pub fn delete_publication(
        &self,
        writer: &mut IndexWriter,
        publication_id: &str,
    ) -> Result<(), SearchIndexError> {
        writer.delete_term(Term::from_field_text(self.id_field, publication_id));
        Ok(())
    }

    /// Commit changes and reload reader
    pub fn commit(&self, writer: &mut IndexWriter) -> Result<(), SearchIndexError> {
        writer.commit()?;
        self.reader.reload()?;
        Ok(())
    }

    /// Search publications
    pub fn search(
        &self,
        query_str: &str,
        limit: usize,
        library_id: Option<&str>,
    ) -> Result<Vec<SearchHit>, SearchIndexError> {
        let searcher = self.reader.searcher();

        // Build query parser for multiple fields
        let query_parser = QueryParser::for_index(
            &self.index,
            vec![
                self.title_field,
                self.authors_field,
                self.abstract_field,
                self.full_text_field,
                self.notes_field,
            ],
        );

        let text_query = query_parser.parse_query(query_str)?;

        // Optionally filter by library
        let final_query = if let Some(lib_id) = library_id {
            let lib_query = TermQuery::new(
                Term::from_field_text(self.library_id_field, lib_id),
                tantivy::schema::IndexRecordOption::Basic,
            );
            BooleanQuery::new(vec![
                (Occur::Must, Box::new(text_query)),
                (Occur::Must, Box::new(lib_query)),
            ])
        } else {
            BooleanQuery::new(vec![(Occur::Must, Box::new(text_query))])
        };

        let top_docs = searcher.search(&final_query, &TopDocs::with_limit(limit))?;

        let mut results = Vec::new();
        for (score, doc_address) in top_docs {
            let doc: TantivyDocument = searcher.doc(doc_address)?;

            let id = doc.get_first(self.id_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let cite_key = doc.get_first(self.cite_key_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let title = doc.get_first(self.title_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            results.push(SearchHit {
                id,
                cite_key,
                title,
                score,
                snippet: None, // Snippets computed separately
            });
        }

        Ok(results)
    }

    /// Search with snippet extraction
    pub fn search_with_snippets(
        &self,
        query_str: &str,
        limit: usize,
        library_id: Option<&str>,
    ) -> Result<Vec<SearchHit>, SearchIndexError> {
        let mut results = self.search(query_str, limit, library_id)?;

        // TODO: Generate snippets using Tantivy's snippet generator
        // For now, snippets are computed client-side

        Ok(results)
    }
}

/// A search result hit
#[derive(uniffi::Record, Clone, Debug)]
pub struct SearchHit {
    pub id: String,
    pub cite_key: String,
    pub title: String,
    pub score: f32,
    pub snippet: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Publication, Author};

    #[test]
    fn test_index_and_search() {
        let index = SearchIndex::in_memory().unwrap();
        let mut writer = index.writer(50_000_000).unwrap();

        let mut pub1 = Publication::new(
            "einstein1905".to_string(),
            "article".to_string(),
            "On the Electrodynamics of Moving Bodies".to_string(),
        );
        pub1.year = Some(1905);
        pub1.authors.push(Author::new("Einstein".to_string()).with_given_name("Albert"));
        pub1.abstract_text = Some("The theory of special relativity...".to_string());

        index.index_publication(&mut writer, &pub1, Some("This paper introduces special relativity")).unwrap();
        index.commit(&mut writer).unwrap();

        let results = index.search("relativity", 10, None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].cite_key, "einstein1905");
    }

    #[test]
    fn test_full_text_search() {
        let index = SearchIndex::in_memory().unwrap();
        let mut writer = index.writer(50_000_000).unwrap();

        let pub1 = Publication::new(
            "test2020".to_string(),
            "article".to_string(),
            "A Paper About Cats".to_string(),
        );

        // Index with full text that contains "quantum" but title doesn't
        index.index_publication(
            &mut writer,
            &pub1,
            Some("This paper discusses quantum mechanics and feline behavior")
        ).unwrap();
        index.commit(&mut writer).unwrap();

        // Should find via full text
        let results = index.search("quantum", 10, None).unwrap();
        assert_eq!(results.len(), 1);
    }
}
```

**Create:** `imbib-core/src/search/snippets.rs`

```rust
//! Search result snippet generation

use regex::Regex;
use lazy_static::lazy_static;

lazy_static! {
    static ref WORD_BOUNDARY: Regex = Regex::new(r"\b").unwrap();
}

/// Extract a snippet around query terms
#[uniffi::export]
pub fn extract_snippet(
    text: &str,
    query_terms: &[String],
    context_chars: usize,
) -> Option<String> {
    let text_lower = text.to_lowercase();

    // Find first matching term
    let mut best_pos: Option<usize> = None;
    for term in query_terms {
        if let Some(pos) = text_lower.find(&term.to_lowercase()) {
            if best_pos.is_none() || pos < best_pos.unwrap() {
                best_pos = Some(pos);
            }
        }
    }

    let pos = best_pos?;

    // Calculate snippet boundaries
    let start = if pos > context_chars {
        // Find word boundary
        let search_start = pos - context_chars;
        text[search_start..pos]
            .rfind(char::is_whitespace)
            .map(|p| search_start + p + 1)
            .unwrap_or(search_start)
    } else {
        0
    };

    let end = if pos + context_chars < text.len() {
        let search_end = pos + context_chars;
        text[pos..search_end]
            .find(char::is_whitespace)
            .map(|p| pos + p)
            .unwrap_or(search_end)
    } else {
        text.len()
    };

    let mut snippet = String::new();

    if start > 0 {
        snippet.push_str("…");
    }

    snippet.push_str(text[start..end].trim());

    if end < text.len() {
        snippet.push_str("…");
    }

    Some(snippet)
}

/// Highlight query terms in text
#[uniffi::export]
pub fn highlight_terms(
    text: &str,
    query_terms: &[String],
    highlight_start: &str,
    highlight_end: &str,
) -> String {
    let mut result = text.to_string();

    for term in query_terms {
        let term_lower = term.to_lowercase();
        let mut offset = 0;

        while let Some(pos) = result[offset..].to_lowercase().find(&term_lower) {
            let absolute_pos = offset + pos;
            let term_len = term.len();

            // Preserve original case
            let original = &result[absolute_pos..absolute_pos + term_len];
            let highlighted = format!("{}{}{}", highlight_start, original, highlight_end);

            result.replace_range(absolute_pos..absolute_pos + term_len, &highlighted);

            offset = absolute_pos + highlighted.len();
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_snippet() {
        let text = "This is a long text about quantum mechanics and special relativity theory.";
        let terms = vec!["quantum".to_string()];

        let snippet = extract_snippet(text, &terms, 20).unwrap();
        assert!(snippet.contains("quantum"));
    }

    #[test]
    fn test_highlight_terms() {
        let text = "The quantum theory explains quantum mechanics.";
        let terms = vec!["quantum".to_string()];

        let highlighted = highlight_terms(text, &terms, "<b>", "</b>");
        assert!(highlighted.contains("<b>quantum</b>"));
        assert_eq!(highlighted.matches("<b>").count(), 2);
    }
}
```

**Checkpoint:** Run `cargo build && cargo test`

---

## Phase 3.2: PDF Text Extraction with pdfium-render

**Create directory:** `imbib-core/src/pdf/`

**Create:** `imbib-core/src/pdf/mod.rs`

```rust
//! PDF processing with pdfium-render
//!
//! Provides:
//! - Text extraction for search indexing
//! - Thumbnail generation
//! - Page count and metadata

pub mod extract;
pub mod thumbnails;
pub mod metadata;

pub use extract::*;
pub use thumbnails::*;
pub use metadata::*;
```

**Create:** `imbib-core/src/pdf/extract.rs`

```rust
//! PDF text extraction for search indexing

use pdfium_render::prelude::*;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum PdfError {
    #[error("Failed to load PDF: {0}")]
    LoadError(String),
    #[error("Failed to extract text: {0}")]
    ExtractionError(String),
    #[error("Pdfium not available")]
    PdfiumNotAvailable,
}

impl From<PdfiumError> for PdfError {
    fn from(e: PdfiumError) -> Self {
        PdfError::LoadError(e.to_string())
    }
}

/// Result of PDF text extraction
#[derive(uniffi::Record, Clone, Debug)]
pub struct PdfTextResult {
    pub full_text: String,
    pub page_count: u32,
    pub pages: Vec<PageText>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct PageText {
    pub page_number: u32,
    pub text: String,
    pub char_count: u32,
}

/// Extract all text from a PDF
#[cfg(not(target_arch = "wasm32"))]
pub fn extract_pdf_text(pdf_bytes: &[u8]) -> Result<PdfTextResult, PdfError> {
    let pdfium = Pdfium::default();
    extract_with_pdfium(&pdfium, pdf_bytes)
}

/// Extract text from PDF (WASM version)
#[cfg(target_arch = "wasm32")]
pub fn extract_pdf_text(pdf_bytes: &[u8]) -> Result<PdfTextResult, PdfError> {
    // In WASM, Pdfium must be initialized with bindings
    let bindings = Pdfium::bind_to_system()
        .map_err(|e| PdfError::PdfiumNotAvailable)?;
    let pdfium = Pdfium::new(bindings);
    extract_with_pdfium(&pdfium, pdf_bytes)
}

fn extract_with_pdfium(pdfium: &Pdfium, pdf_bytes: &[u8]) -> Result<PdfTextResult, PdfError> {
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let page_count = document.pages().len() as u32;
    let mut pages = Vec::with_capacity(page_count as usize);
    let mut full_text = String::new();

    for (i, page) in document.pages().iter().enumerate() {
        let text = page.text()
            .map_err(|e| PdfError::ExtractionError(e.to_string()))?;

        let page_text = text.all();
        let char_count = page_text.chars().count() as u32;

        pages.push(PageText {
            page_number: (i + 1) as u32,
            text: page_text.clone(),
            char_count,
        });

        if !full_text.is_empty() {
            full_text.push('\n');
        }
        full_text.push_str(&page_text);
    }

    Ok(PdfTextResult {
        full_text,
        page_count,
        pages,
    })
}

/// Extract text from a specific page range
pub fn extract_page_range(
    pdf_bytes: &[u8],
    start_page: u32,
    end_page: u32,
) -> Result<String, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let mut text = String::new();

    for i in start_page..=end_page {
        if let Some(page) = document.pages().get((i - 1) as u16).ok() {
            let page_text = page.text()
                .map_err(|e| PdfError::ExtractionError(e.to_string()))?;
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&page_text.all());
        }
    }

    Ok(text)
}

/// Search for text within a PDF and return positions
#[derive(uniffi::Record, Clone, Debug)]
pub struct TextMatch {
    pub page_number: u32,
    pub text: String,
    pub char_index: u32,
}

pub fn search_in_pdf(
    pdf_bytes: &[u8],
    query: &str,
    max_results: usize,
) -> Result<Vec<TextMatch>, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let query_lower = query.to_lowercase();
    let mut matches = Vec::new();

    for (page_idx, page) in document.pages().iter().enumerate() {
        let text = page.text()
            .map_err(|e| PdfError::ExtractionError(e.to_string()))?;

        let page_text = text.all();
        let page_lower = page_text.to_lowercase();

        let mut search_start = 0;
        while let Some(pos) = page_lower[search_start..].find(&query_lower) {
            let absolute_pos = search_start + pos;

            // Extract context around match
            let context_start = absolute_pos.saturating_sub(50);
            let context_end = (absolute_pos + query.len() + 50).min(page_text.len());

            let mut context = String::new();
            if context_start > 0 {
                context.push_str("…");
            }
            context.push_str(&page_text[context_start..context_end]);
            if context_end < page_text.len() {
                context.push_str("…");
            }

            matches.push(TextMatch {
                page_number: (page_idx + 1) as u32,
                text: context,
                char_index: absolute_pos as u32,
            });

            if matches.len() >= max_results {
                return Ok(matches);
            }

            search_start = absolute_pos + query.len();
        }
    }

    Ok(matches)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: Tests require actual PDF files
    // In CI, use sample PDFs in test resources

    #[test]
    fn test_extract_empty_returns_error() {
        let result = extract_pdf_text(&[]);
        assert!(result.is_err());
    }
}
```

**Create:** `imbib-core/src/pdf/metadata.rs`

```rust
//! PDF metadata extraction

use pdfium_render::prelude::*;
use super::extract::PdfError;

/// PDF document metadata
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct PdfMetadata {
    pub title: Option<String>,
    pub author: Option<String>,
    pub subject: Option<String>,
    pub keywords: Option<String>,
    pub creator: Option<String>,
    pub producer: Option<String>,
    pub creation_date: Option<String>,
    pub modification_date: Option<String>,
    pub page_count: u32,
}

/// Extract metadata from a PDF
pub fn extract_pdf_metadata(pdf_bytes: &[u8]) -> Result<PdfMetadata, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let metadata = document.metadata();

    Ok(PdfMetadata {
        title: metadata.title(),
        author: metadata.author(),
        subject: metadata.subject(),
        keywords: metadata.keywords(),
        creator: metadata.creator(),
        producer: metadata.producer(),
        creation_date: metadata.creation_date().map(|d| d.to_string()),
        modification_date: metadata.modification_date().map(|d| d.to_string()),
        page_count: document.pages().len() as u32,
    })
}

/// Get page dimensions
#[derive(uniffi::Record, Clone, Debug)]
pub struct PageDimensions {
    pub width: f32,
    pub height: f32,
}

pub fn get_page_dimensions(pdf_bytes: &[u8], page_number: u32) -> Result<PageDimensions, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let page = document.pages()
        .get((page_number - 1) as u16)
        .map_err(|e| PdfError::LoadError(format!("Page {} not found: {}", page_number, e)))?;

    Ok(PageDimensions {
        width: page.width().value,
        height: page.height().value,
    })
}
```

**Create:** `imbib-core/src/pdf/thumbnails.rs`

```rust
//! PDF thumbnail generation

use pdfium_render::prelude::*;
use super::extract::PdfError;

/// Thumbnail configuration
#[derive(uniffi::Record, Clone, Debug)]
pub struct ThumbnailConfig {
    pub width: u32,
    pub height: u32,
    pub page_number: u32,
}

impl Default for ThumbnailConfig {
    fn default() -> Self {
        Self {
            width: 200,
            height: 280,
            page_number: 1,
        }
    }
}

/// Generate a thumbnail for a PDF page
///
/// Returns RGBA pixel data
pub fn generate_thumbnail(
    pdf_bytes: &[u8],
    config: &ThumbnailConfig,
) -> Result<Vec<u8>, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let page = document.pages()
        .get((config.page_number - 1) as u16)
        .map_err(|e| PdfError::LoadError(format!("Page not found: {}", e)))?;

    // Calculate scale to fit within dimensions while preserving aspect ratio
    let page_width = page.width().value;
    let page_height = page.height().value;

    let scale_x = config.width as f32 / page_width;
    let scale_y = config.height as f32 / page_height;
    let scale = scale_x.min(scale_y);

    let render_width = (page_width * scale) as i32;
    let render_height = (page_height * scale) as i32;

    let render_config = PdfRenderConfig::new()
        .set_target_width(render_width)
        .set_target_height(render_height)
        .render_form_data(false)
        .render_annotations(false);

    let bitmap = page.render_with_config(&render_config)
        .map_err(|e| PdfError::ExtractionError(format!("Render failed: {}", e)))?;

    // Convert to RGBA bytes
    Ok(bitmap.as_rgba_bytes().to_vec())
}

/// Generate thumbnails for multiple pages
pub fn generate_thumbnails(
    pdf_bytes: &[u8],
    pages: &[u32],
    width: u32,
    height: u32,
) -> Result<Vec<(u32, Vec<u8>)>, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let mut results = Vec::new();

    for &page_num in pages {
        let config = ThumbnailConfig {
            width,
            height,
            page_number: page_num,
        };

        if let Ok(thumbnail) = generate_thumbnail_from_doc(&document, &config) {
            results.push((page_num, thumbnail));
        }
    }

    Ok(results)
}

fn generate_thumbnail_from_doc(
    document: &PdfDocument,
    config: &ThumbnailConfig,
) -> Result<Vec<u8>, PdfError> {
    let page = document.pages()
        .get((config.page_number - 1) as u16)
        .map_err(|e| PdfError::LoadError(format!("Page not found: {}", e)))?;

    let page_width = page.width().value;
    let page_height = page.height().value;

    let scale_x = config.width as f32 / page_width;
    let scale_y = config.height as f32 / page_height;
    let scale = scale_x.min(scale_y);

    let render_width = (page_width * scale) as i32;
    let render_height = (page_height * scale) as i32;

    let render_config = PdfRenderConfig::new()
        .set_target_width(render_width)
        .set_target_height(render_height)
        .render_form_data(false)
        .render_annotations(false);

    let bitmap = page.render_with_config(&render_config)
        .map_err(|e| PdfError::ExtractionError(format!("Render failed: {}", e)))?;

    Ok(bitmap.as_rgba_bytes().to_vec())
}
```

**Checkpoint:** Run `cargo build && cargo test`

---

## Phase 3.3: Semantic Search with Embeddings

**Create:** `imbib-core/src/search/semantic.rs`

```rust
//! Semantic search using text embeddings
//!
//! Enables "find similar papers" functionality by computing
//! vector embeddings and using cosine similarity.

use fastembed::{TextEmbedding, InitOptions, EmbeddingModel};
use std::sync::Arc;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum EmbeddingError {
    #[error("Model initialization failed: {0}")]
    InitError(String),
    #[error("Embedding generation failed: {0}")]
    EmbeddingFailed(String),
    #[error("Invalid input: {0}")]
    InvalidInput(String),
}

/// Embedding vector for a publication
#[derive(uniffi::Record, Clone, Debug)]
pub struct PublicationEmbedding {
    pub publication_id: String,
    pub vector: Vec<f32>,
    pub model: String,
}

/// Semantic search engine
pub struct SemanticSearch {
    model: TextEmbedding,
    model_name: String,
}

impl SemanticSearch {
    /// Initialize with the default model (all-MiniLM-L6-v2)
    pub fn new() -> Result<Self, EmbeddingError> {
        Self::with_model(EmbeddingModel::AllMiniLML6V2)
    }

    /// Initialize with a specific model
    pub fn with_model(model: EmbeddingModel) -> Result<Self, EmbeddingError> {
        let model_name = format!("{:?}", model);

        let text_embedding = TextEmbedding::try_new(InitOptions {
            model_name: model,
            show_download_progress: true,
            ..Default::default()
        }).map_err(|e| EmbeddingError::InitError(e.to_string()))?;

        Ok(Self {
            model: text_embedding,
            model_name,
        })
    }

    /// Generate embedding for a publication
    ///
    /// Combines title, authors, and abstract for best results
    pub fn embed_publication(
        &self,
        publication_id: &str,
        title: &str,
        authors: &[String],
        abstract_text: Option<&str>,
    ) -> Result<PublicationEmbedding, EmbeddingError> {
        // Combine fields into a single text
        let mut text = title.to_string();

        if !authors.is_empty() {
            text.push_str(". Authors: ");
            text.push_str(&authors.join(", "));
        }

        if let Some(abstract_str) = abstract_text {
            text.push_str(". ");
            // Truncate abstract if too long (model has token limit)
            let truncated = if abstract_str.len() > 1000 {
                &abstract_str[..1000]
            } else {
                abstract_str
            };
            text.push_str(truncated);
        }

        let embeddings = self.model.embed(vec![text], None)
            .map_err(|e| EmbeddingError::EmbeddingFailed(e.to_string()))?;

        let vector = embeddings.into_iter().next()
            .ok_or_else(|| EmbeddingError::EmbeddingFailed("No embedding returned".to_string()))?;

        Ok(PublicationEmbedding {
            publication_id: publication_id.to_string(),
            vector,
            model: self.model_name.clone(),
        })
    }

    /// Generate embeddings for multiple publications
    pub fn embed_publications(
        &self,
        publications: Vec<(String, String, Vec<String>, Option<String>)>,
    ) -> Result<Vec<PublicationEmbedding>, EmbeddingError> {
        let texts: Vec<String> = publications.iter()
            .map(|(_, title, authors, abstract_text)| {
                let mut text = title.clone();
                if !authors.is_empty() {
                    text.push_str(". Authors: ");
                    text.push_str(&authors.join(", "));
                }
                if let Some(abs) = abstract_text {
                    text.push_str(". ");
                    let truncated = if abs.len() > 1000 { &abs[..1000] } else { abs };
                    text.push_str(truncated);
                }
                text
            })
            .collect();

        let embeddings = self.model.embed(texts, None)
            .map_err(|e| EmbeddingError::EmbeddingFailed(e.to_string()))?;

        Ok(publications.into_iter()
            .zip(embeddings.into_iter())
            .map(|((id, _, _, _), vector)| PublicationEmbedding {
                publication_id: id,
                vector,
                model: self.model_name.clone(),
            })
            .collect())
    }

    /// Embed a search query
    pub fn embed_query(&self, query: &str) -> Result<Vec<f32>, EmbeddingError> {
        let embeddings = self.model.embed(vec![query.to_string()], None)
            .map_err(|e| EmbeddingError::EmbeddingFailed(e.to_string()))?;

        embeddings.into_iter().next()
            .ok_or_else(|| EmbeddingError::EmbeddingFailed("No embedding returned".to_string()))
    }
}

/// Compute cosine similarity between two vectors
#[uniffi::export]
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }

    let dot_product: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();

    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }

    dot_product / (norm_a * norm_b)
}

/// Find most similar publications by embedding
#[uniffi::export]
pub fn find_similar(
    query_embedding: &[f32],
    candidate_embeddings: Vec<PublicationEmbedding>,
    top_k: usize,
) -> Vec<SimilarityResult> {
    let mut results: Vec<SimilarityResult> = candidate_embeddings.into_iter()
        .map(|emb| {
            let similarity = cosine_similarity(query_embedding, &emb.vector);
            SimilarityResult {
                publication_id: emb.publication_id,
                similarity,
            }
        })
        .collect();

    // Sort by similarity descending
    results.sort_by(|a, b| b.similarity.partial_cmp(&a.similarity).unwrap_or(std::cmp::Ordering::Equal));

    results.truncate(top_k);
    results
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SimilarityResult {
    pub publication_id: String,
    pub similarity: f32,
}

/// Embedding storage format for persistence
#[derive(uniffi::Record, Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct StoredEmbedding {
    pub publication_id: String,
    pub vector: Vec<f32>,
    pub model: String,
    pub created_at: String,
}

impl From<PublicationEmbedding> for StoredEmbedding {
    fn from(emb: PublicationEmbedding) -> Self {
        Self {
            publication_id: emb.publication_id,
            vector: emb.vector,
            model: emb.model,
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cosine_similarity() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &b) - 1.0).abs() < 0.001);

        let c = vec![0.0, 1.0, 0.0];
        assert!(cosine_similarity(&a, &c).abs() < 0.001);
    }

    #[test]
    fn test_find_similar() {
        let query = vec![1.0, 0.0, 0.0];
        let candidates = vec![
            PublicationEmbedding {
                publication_id: "a".to_string(),
                vector: vec![0.9, 0.1, 0.0],
                model: "test".to_string(),
            },
            PublicationEmbedding {
                publication_id: "b".to_string(),
                vector: vec![0.0, 1.0, 0.0],
                model: "test".to_string(),
            },
        ];

        let results = find_similar(&query, candidates, 2);
        assert_eq!(results[0].publication_id, "a");
        assert!(results[0].similarity > results[1].similarity);
    }
}
```

**Checkpoint:** Run `cargo build --features embeddings && cargo test --features embeddings`

---

## Phase 3.4: Annotation Storage

**Create directory:** `imbib-core/src/annotations/`

**Create:** `imbib-core/src/annotations/mod.rs`

```rust
//! Cross-platform annotation storage
//!
//! Annotations are stored as JSON-serializable structs that can:
//! - Sync via CloudKit (native) or any backend (web)
//! - Be rendered differently per platform
//! - Support undo/redo operations

pub mod types;
pub mod storage;
pub mod operations;

pub use types::*;
pub use storage::*;
pub use operations::*;
```

**Create:** `imbib-core/src/annotations/types.rs`

```rust
//! Annotation type definitions

use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};

/// A rectangle on a PDF page (in PDF coordinates)
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self { x, y, width, height }
    }

    pub fn contains_point(&self, x: f32, y: f32) -> bool {
        x >= self.x && x <= self.x + self.width &&
        y >= self.y && y <= self.y + self.height
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < other.x + other.width &&
        self.x + self.width > other.x &&
        self.y < other.y + other.height &&
        self.y + self.height > other.y
    }
}

/// Point on a page
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

/// Color in RGBA format
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub fn yellow() -> Self {
        Self { r: 255, g: 255, b: 0, a: 128 }
    }

    pub fn green() -> Self {
        Self { r: 0, g: 255, b: 0, a: 128 }
    }

    pub fn red() -> Self {
        Self { r: 255, g: 0, b: 0, a: 128 }
    }

    pub fn blue() -> Self {
        Self { r: 0, g: 0, b: 255, a: 128 }
    }

    pub fn to_hex(&self) -> String {
        format!("#{:02x}{:02x}{:02x}{:02x}", self.r, self.g, self.b, self.a)
    }

    pub fn from_hex(hex: &str) -> Option<Self> {
        let hex = hex.trim_start_matches('#');
        if hex.len() == 6 {
            let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
            let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
            let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
            Some(Self { r, g, b, a: 255 })
        } else if hex.len() == 8 {
            let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
            let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
            let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
            let a = u8::from_str_radix(&hex[6..8], 16).ok()?;
            Some(Self { r, g, b, a })
        } else {
            None
        }
    }
}

/// Annotation type
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum AnnotationType {
    Highlight,
    Underline,
    StrikeOut,
    Squiggly,
    Note,
    FreeText,
    Drawing,
    Link,
}

/// A single annotation on a PDF page
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct Annotation {
    pub id: String,
    pub publication_id: String,
    pub page_number: u32,
    pub annotation_type: AnnotationType,
    pub rects: Vec<Rect>,  // Multiple rects for multi-line highlights
    pub color: Color,
    pub content: Option<String>,  // Note text or link URL
    pub selected_text: Option<String>,  // Text that was highlighted
    pub created_at: String,
    pub modified_at: String,
    pub author: Option<String>,
}

impl Annotation {
    pub fn new_highlight(
        publication_id: String,
        page_number: u32,
        rects: Vec<Rect>,
        selected_text: Option<String>,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            annotation_type: AnnotationType::Highlight,
            rects,
            color: Color::yellow(),
            content: None,
            selected_text,
            created_at: now.clone(),
            modified_at: now,
            author: None,
        }
    }

    pub fn new_note(
        publication_id: String,
        page_number: u32,
        position: Rect,
        content: String,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            annotation_type: AnnotationType::Note,
            rects: vec![position],
            color: Color::yellow(),
            content: Some(content),
            selected_text: None,
            created_at: now.clone(),
            modified_at: now,
            author: None,
        }
    }

    pub fn new_freetext(
        publication_id: String,
        page_number: u32,
        rect: Rect,
        text: String,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            annotation_type: AnnotationType::FreeText,
            rects: vec![rect],
            color: Color { r: 0, g: 0, b: 0, a: 255 },
            content: Some(text),
            selected_text: None,
            created_at: now.clone(),
            modified_at: now,
            author: None,
        }
    }

    pub fn update_content(&mut self, content: String) {
        self.content = Some(content);
        self.modified_at = Utc::now().to_rfc3339();
    }

    pub fn update_color(&mut self, color: Color) {
        self.color = color;
        self.modified_at = Utc::now().to_rfc3339();
    }
}

/// Drawing stroke for freehand annotations
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct DrawingStroke {
    pub points: Vec<Point>,
    pub color: Color,
    pub width: f32,
}

/// Drawing annotation (multiple strokes)
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct DrawingAnnotation {
    pub id: String,
    pub publication_id: String,
    pub page_number: u32,
    pub strokes: Vec<DrawingStroke>,
    pub created_at: String,
    pub modified_at: String,
}

impl DrawingAnnotation {
    pub fn new(publication_id: String, page_number: u32) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            publication_id,
            page_number,
            strokes: Vec::new(),
            created_at: now.clone(),
            modified_at: now,
        }
    }

    pub fn add_stroke(&mut self, stroke: DrawingStroke) {
        self.strokes.push(stroke);
        self.modified_at = Utc::now().to_rfc3339();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rect_contains() {
        let rect = Rect::new(10.0, 10.0, 100.0, 50.0);
        assert!(rect.contains_point(50.0, 30.0));
        assert!(!rect.contains_point(5.0, 30.0));
    }

    #[test]
    fn test_color_hex() {
        let color = Color::yellow();
        let hex = color.to_hex();
        let parsed = Color::from_hex(&hex).unwrap();
        assert_eq!(color, parsed);
    }
}
```

**Create:** `imbib-core/src/annotations/storage.rs`

```rust
//! Annotation storage and serialization

use super::types::{Annotation, DrawingAnnotation};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum AnnotationStorageError {
    #[error("Serialization error: {0}")]
    SerializationError(String),
    #[error("Annotation not found: {0}")]
    NotFound(String),
}

/// All annotations for a publication
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, Default)]
pub struct PublicationAnnotations {
    pub publication_id: String,
    pub annotations: Vec<Annotation>,
    pub drawings: Vec<DrawingAnnotation>,
    pub version: u32,  // For conflict resolution
    pub modified_at: String,
}

impl PublicationAnnotations {
    pub fn new(publication_id: String) -> Self {
        Self {
            publication_id,
            annotations: Vec::new(),
            drawings: Vec::new(),
            version: 1,
            modified_at: chrono::Utc::now().to_rfc3339(),
        }
    }

    pub fn add_annotation(&mut self, annotation: Annotation) {
        self.annotations.push(annotation);
        self.increment_version();
    }

    pub fn remove_annotation(&mut self, annotation_id: &str) -> Option<Annotation> {
        if let Some(pos) = self.annotations.iter().position(|a| a.id == annotation_id) {
            self.increment_version();
            Some(self.annotations.remove(pos))
        } else {
            None
        }
    }

    pub fn get_annotation(&self, annotation_id: &str) -> Option<&Annotation> {
        self.annotations.iter().find(|a| a.id == annotation_id)
    }

    pub fn get_annotation_mut(&mut self, annotation_id: &str) -> Option<&mut Annotation> {
        self.annotations.iter_mut().find(|a| a.id == annotation_id)
    }

    pub fn annotations_for_page(&self, page_number: u32) -> Vec<&Annotation> {
        self.annotations.iter()
            .filter(|a| a.page_number == page_number)
            .collect()
    }

    pub fn add_drawing(&mut self, drawing: DrawingAnnotation) {
        self.drawings.push(drawing);
        self.increment_version();
    }

    pub fn drawings_for_page(&self, page_number: u32) -> Vec<&DrawingAnnotation> {
        self.drawings.iter()
            .filter(|d| d.page_number == page_number)
            .collect()
    }

    fn increment_version(&mut self) {
        self.version += 1;
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }
}

/// Serialize annotations to JSON
#[uniffi::export]
pub fn serialize_annotations(annotations: &PublicationAnnotations) -> Result<String, AnnotationStorageError> {
    serde_json::to_string(annotations)
        .map_err(|e| AnnotationStorageError::SerializationError(e.to_string()))
}

/// Deserialize annotations from JSON
#[uniffi::export]
pub fn deserialize_annotations(json: &str) -> Result<PublicationAnnotations, AnnotationStorageError> {
    serde_json::from_str(json)
        .map_err(|e| AnnotationStorageError::SerializationError(e.to_string()))
}

/// Merge two annotation sets (for sync conflicts)
///
/// Strategy: Keep all unique annotations, prefer newer versions for conflicts
#[uniffi::export]
pub fn merge_annotations(
    local: &PublicationAnnotations,
    remote: &PublicationAnnotations,
) -> PublicationAnnotations {
    let mut merged = PublicationAnnotations::new(local.publication_id.clone());

    // Build maps by ID
    let local_map: HashMap<&str, &Annotation> = local.annotations.iter()
        .map(|a| (a.id.as_str(), a))
        .collect();

    let remote_map: HashMap<&str, &Annotation> = remote.annotations.iter()
        .map(|a| (a.id.as_str(), a))
        .collect();

    // Merge annotations
    let mut seen_ids = std::collections::HashSet::new();

    for (id, local_ann) in &local_map {
        if let Some(remote_ann) = remote_map.get(id) {
            // Both have it - keep newer
            if local_ann.modified_at >= remote_ann.modified_at {
                merged.annotations.push((*local_ann).clone());
            } else {
                merged.annotations.push((*remote_ann).clone());
            }
        } else {
            // Only local has it
            merged.annotations.push((*local_ann).clone());
        }
        seen_ids.insert(*id);
    }

    // Add remote-only annotations
    for (id, remote_ann) in &remote_map {
        if !seen_ids.contains(id) {
            merged.annotations.push((*remote_ann).clone());
        }
    }

    // Similar merge for drawings
    let local_drawing_map: HashMap<&str, &DrawingAnnotation> = local.drawings.iter()
        .map(|d| (d.id.as_str(), d))
        .collect();

    let remote_drawing_map: HashMap<&str, &DrawingAnnotation> = remote.drawings.iter()
        .map(|d| (d.id.as_str(), d))
        .collect();

    let mut seen_drawing_ids = std::collections::HashSet::new();

    for (id, local_drawing) in &local_drawing_map {
        if let Some(remote_drawing) = remote_drawing_map.get(id) {
            if local_drawing.modified_at >= remote_drawing.modified_at {
                merged.drawings.push((*local_drawing).clone());
            } else {
                merged.drawings.push((*remote_drawing).clone());
            }
        } else {
            merged.drawings.push((*local_drawing).clone());
        }
        seen_drawing_ids.insert(*id);
    }

    for (id, remote_drawing) in &remote_drawing_map {
        if !seen_drawing_ids.contains(id) {
            merged.drawings.push((*remote_drawing).clone());
        }
    }

    merged.version = local.version.max(remote.version) + 1;
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annotations::types::{Rect, Color};

    #[test]
    fn test_serialize_deserialize() {
        let mut annotations = PublicationAnnotations::new("test-pub".to_string());
        annotations.add_annotation(Annotation::new_highlight(
            "test-pub".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 100.0, 20.0)],
            Some("Test text".to_string()),
        ));

        let json = serialize_annotations(&annotations).unwrap();
        let restored = deserialize_annotations(&json).unwrap();

        assert_eq!(restored.annotations.len(), 1);
        assert_eq!(restored.annotations[0].selected_text, Some("Test text".to_string()));
    }

    #[test]
    fn test_merge_annotations() {
        let mut local = PublicationAnnotations::new("test".to_string());
        let mut remote = PublicationAnnotations::new("test".to_string());

        // Local-only annotation
        local.add_annotation(Annotation::new_highlight(
            "test".to_string(), 1, vec![Rect::new(0.0, 0.0, 10.0, 10.0)], None
        ));

        // Remote-only annotation
        remote.add_annotation(Annotation::new_highlight(
            "test".to_string(), 2, vec![Rect::new(0.0, 0.0, 10.0, 10.0)], None
        ));

        let merged = merge_annotations(&local, &remote);
        assert_eq!(merged.annotations.len(), 2);
    }
}
```

**Create:** `imbib-core/src/annotations/operations.rs`

```rust
//! Annotation operations (for undo/redo support)

use super::types::{Annotation, Color, Rect};
use serde::{Deserialize, Serialize};

/// An operation that can be undone/redone
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize)]
pub enum AnnotationOperation {
    Add { annotation: Annotation },
    Remove { annotation: Annotation },
    UpdateContent { annotation_id: String, old_content: Option<String>, new_content: Option<String> },
    UpdateColor { annotation_id: String, old_color: Color, new_color: Color },
    Move { annotation_id: String, old_rects: Vec<Rect>, new_rects: Vec<Rect> },
}

impl AnnotationOperation {
    /// Create the inverse operation (for undo)
    pub fn inverse(&self) -> Self {
        match self {
            Self::Add { annotation } => Self::Remove { annotation: annotation.clone() },
            Self::Remove { annotation } => Self::Add { annotation: annotation.clone() },
            Self::UpdateContent { annotation_id, old_content, new_content } => Self::UpdateContent {
                annotation_id: annotation_id.clone(),
                old_content: new_content.clone(),
                new_content: old_content.clone(),
            },
            Self::UpdateColor { annotation_id, old_color, new_color } => Self::UpdateColor {
                annotation_id: annotation_id.clone(),
                old_color: new_color.clone(),
                new_color: old_color.clone(),
            },
            Self::Move { annotation_id, old_rects, new_rects } => Self::Move {
                annotation_id: annotation_id.clone(),
                old_rects: new_rects.clone(),
                new_rects: old_rects.clone(),
            },
        }
    }
}

/// Undo/redo stack for annotation operations
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct AnnotationHistory {
    pub undo_stack: Vec<AnnotationOperation>,
    pub redo_stack: Vec<AnnotationOperation>,
    pub max_size: usize,
}

impl AnnotationHistory {
    pub fn new(max_size: usize) -> Self {
        Self {
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            max_size,
        }
    }

    pub fn push(&mut self, operation: AnnotationOperation) {
        self.undo_stack.push(operation);
        self.redo_stack.clear();  // Clear redo stack on new action

        // Limit stack size
        while self.undo_stack.len() > self.max_size {
            self.undo_stack.remove(0);
        }
    }

    pub fn undo(&mut self) -> Option<AnnotationOperation> {
        if let Some(op) = self.undo_stack.pop() {
            let inverse = op.inverse();
            self.redo_stack.push(op);
            Some(inverse)
        } else {
            None
        }
    }

    pub fn redo(&mut self) -> Option<AnnotationOperation> {
        if let Some(op) = self.redo_stack.pop() {
            self.undo_stack.push(op.clone());
            Some(op)
        } else {
            None
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn clear(&mut self) {
        self.undo_stack.clear();
        self.redo_stack.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_operation_inverse() {
        let annotation = Annotation::new_highlight(
            "test".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            None,
        );

        let add_op = AnnotationOperation::Add { annotation: annotation.clone() };
        let inverse = add_op.inverse();

        match inverse {
            AnnotationOperation::Remove { annotation: removed } => {
                assert_eq!(removed.id, annotation.id);
            }
            _ => panic!("Expected Remove operation"),
        }
    }

    #[test]
    fn test_history_undo_redo() {
        let mut history = AnnotationHistory::new(10);

        let annotation = Annotation::new_highlight(
            "test".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            None,
        );

        history.push(AnnotationOperation::Add { annotation });

        assert!(history.can_undo());
        assert!(!history.can_redo());

        let undo_op = history.undo().unwrap();
        match undo_op {
            AnnotationOperation::Remove { .. } => {}
            _ => panic!("Expected Remove for undo"),
        }

        assert!(!history.can_undo());
        assert!(history.can_redo());
    }
}
```

**Checkpoint:** Run `cargo build && cargo test`

---

## Phase 3.5: Update lib.rs Exports

**Update:** `imbib-core/src/lib.rs`

```rust
//! imbib-core: Cross-platform core library for imbib publication manager

// Existing modules
pub mod domain;
pub mod bibtex;
pub mod ris;
pub mod identifiers;
pub mod deduplication;
pub mod text;
pub mod import;
pub mod export;
pub mod filename;
pub mod merge;
pub mod query;
pub mod automation;

#[cfg(not(target_arch = "wasm32"))]
pub mod http;

#[cfg(not(target_arch = "wasm32"))]
pub mod sources;

// NEW: Phase 3 modules
pub mod search;
pub mod pdf;
pub mod annotations;

// Re-exports
pub use domain::*;
pub use bibtex::*;
pub use ris::*;
pub use identifiers::*;
pub use deduplication::*;
pub use text::*;
pub use import::*;
pub use export::*;
pub use filename::*;
pub use merge::*;
pub use query::*;
pub use automation::*;
pub use search::*;
pub use pdf::*;
pub use annotations::*;

#[cfg(not(target_arch = "wasm32"))]
pub use http::*;

#[cfg(not(target_arch = "wasm32"))]
pub use sources::*;

uniffi::setup_scaffolding!();
```

---

## Phase 3.6: Swift Integration

After Rust builds successfully, regenerate Swift bindings:

```bash
cd imbib-core
cargo build --release --features embeddings

# Generate bindings
cargo run --bin uniffi-bindgen generate \
    --library target/release/libimbib_core.dylib \
    --language swift \
    --out-dir ../ImbibRustCore/Sources/ImbibRustCore/

# Rebuild XCFramework
./build-xcframework.sh
```

**Create Swift wrapper:** `PublicationManagerCore/Sources/PublicationManagerCore/Search/RustSearchService.swift`

```swift
import Foundation
import ImbibRustCore

/// Swift wrapper for Rust search index
public actor RustSearchService {
    private var index: SearchIndex?
    private let indexPath: URL

    public init(indexPath: URL) {
        self.indexPath = indexPath
    }

    public func initialize() throws {
        index = try SearchIndex.open(path: indexPath.path)
    }

    public func indexPublication(_ publication: Publication, fullText: String?) throws {
        guard let index = index else {
            throw SearchError.notInitialized
        }

        var writer = try index.writer(heapSize: 50_000_000)
        try index.indexPublication(writer: &writer, publication: publication, fullText: fullText)
        try index.commit(writer: &writer)
    }

    public func search(query: String, limit: Int = 100, libraryId: String? = nil) throws -> [SearchHit] {
        guard let index = index else {
            throw SearchError.notInitialized
        }

        return try index.search(queryStr: query, limit: UInt(limit), libraryId: libraryId)
    }
}

public enum SearchError: Error {
    case notInitialized
}
```

---

## Final Verification

```bash
# 1. Build Rust with all features
cd imbib-core
cargo build --release --features embeddings
cargo test --features embeddings

# 2. Build without embeddings (lighter)
cargo build --release
cargo test

# 3. Rebuild XCFramework
./build-xcframework.sh

# 4. Build Swift
cd ../PublicationManagerCore
swift build
swift test

# 5. Build apps
cd ..
xcodebuild -scheme imbib -configuration Debug build
xcodebuild -scheme imbib-iOS -configuration Debug build
```

---

## Summary of Phase 3 Additions

| Module | Files | Purpose |
|--------|-------|---------|
| `search::index` | `search/index.rs` | Tantivy index management |
| `search::schema` | `search/schema.rs` | Index field definitions |
| `search::snippets` | `search/snippets.rs` | Result snippet extraction |
| `search::semantic` | `search/semantic.rs` | Embedding-based similarity |
| `pdf::extract` | `pdf/extract.rs` | PDF text extraction |
| `pdf::metadata` | `pdf/metadata.rs` | PDF metadata extraction |
| `pdf::thumbnails` | `pdf/thumbnails.rs` | Thumbnail generation |
| `annotations::types` | `annotations/types.rs` | Annotation data types |
| `annotations::storage` | `annotations/storage.rs` | Serialization & merge |
| `annotations::operations` | `annotations/operations.rs` | Undo/redo support |

---

## Feature Comparison After Phase 3

| Feature | Before (Swift) | After (Rust) | Benefit |
|---------|---------------|--------------|---------|
| Text search | Spotlight (macOS only) | Tantivy | Cross-platform, web-compatible |
| PDF text | PDFKit (Apple only) | pdfium-render | Cross-platform, WASM |
| Similar papers | Not available | fastembed | New capability |
| Annotations | Platform-specific | Unified JSON | Sync anywhere |
| Thumbnails | PDFKit | pdfium-render | Cross-platform |

---

## Optional: Embeddings Model Download

The fastembed model (~22MB for MiniLM) downloads on first use. For production:

1. Bundle model with app, or
2. Download on demand with progress UI, or
3. Make embeddings opt-in feature

The `embeddings` feature flag allows building without this dependency for smaller binaries.
