//! Help documentation search module
//!
//! Provides full-text search over help documentation with:
//! - Tantivy-based indexing
//! - Snippet extraction with term highlighting
//! - Platform-aware filtering (iOS, macOS, both)

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, RwLock};
use tantivy::{
    collector::TopDocs,
    query::QueryParser,
    schema::{Field, Schema, Value, STORED, TEXT},
    Index, IndexReader, IndexWriter, ReloadPolicy, TantivyDocument, Term,
};
use thiserror::Error;

/// Platform for help documentation filtering
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum HelpPlatform {
    /// iOS-only feature
    IOS,
    /// macOS-only feature
    MacOS,
    /// Available on both platforms
    Both,
}

impl HelpPlatform {
    fn as_str(&self) -> &'static str {
        match self {
            HelpPlatform::IOS => "ios",
            HelpPlatform::MacOS => "macos",
            HelpPlatform::Both => "both",
        }
    }

    fn from_str(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "ios" => HelpPlatform::IOS,
            "macos" => HelpPlatform::MacOS,
            _ => HelpPlatform::Both,
        }
    }
}

/// Error type for help search operations
#[derive(Error, Debug, uniffi::Error)]
pub enum HelpSearchError {
    #[error("Index error: {0}")]
    IndexError(String),
    #[error("Query error: {0}")]
    QueryError(String),
    #[error("IO error: {0}")]
    IoError(String),
    #[error("Invalid handle")]
    InvalidHandle,
}

impl From<std::io::Error> for HelpSearchError {
    fn from(e: std::io::Error) -> Self {
        HelpSearchError::IoError(e.to_string())
    }
}

impl From<tantivy::TantivyError> for HelpSearchError {
    fn from(e: tantivy::TantivyError) -> Self {
        HelpSearchError::IndexError(e.to_string())
    }
}

impl From<tantivy::query::QueryParserError> for HelpSearchError {
    fn from(e: tantivy::query::QueryParserError) -> Self {
        HelpSearchError::QueryError(e.to_string())
    }
}

/// A help document to be indexed
#[derive(uniffi::Record, Clone, Debug)]
pub struct HelpDocument {
    /// Unique document identifier (e.g., "features/siri-shortcuts")
    pub id: String,
    /// Document title
    pub title: String,
    /// Document body/content (markdown)
    pub body: String,
    /// Search keywords
    pub keywords: Vec<String>,
    /// Target platform
    pub platform: HelpPlatform,
    /// Category for grouping
    pub category: String,
}

/// A search result from the help index
#[derive(uniffi::Record, Clone, Debug)]
pub struct HelpSearchResult {
    /// Document identifier
    pub id: String,
    /// Document title
    pub title: String,
    /// Snippet with highlighted terms (using <mark> tags)
    pub snippet: String,
    /// Relevance score (0.0 to 1.0)
    pub relevance_score: f32,
    /// Target platform
    pub platform: HelpPlatform,
    /// Category
    pub category: String,
}

/// Schema field names for help documents
mod fields {
    pub const ID: &str = "id";
    pub const TITLE: &str = "title";
    pub const BODY: &str = "body";
    pub const KEYWORDS: &str = "keywords";
    pub const PLATFORM: &str = "platform";
    pub const CATEGORY: &str = "category";
}

/// Build the schema for help documents
fn build_help_schema() -> Schema {
    let mut schema_builder = Schema::builder();

    schema_builder.add_text_field(fields::ID, STORED);
    schema_builder.add_text_field(fields::TITLE, TEXT | STORED);
    schema_builder.add_text_field(fields::BODY, TEXT | STORED);
    schema_builder.add_text_field(fields::KEYWORDS, TEXT | STORED);
    schema_builder.add_text_field(fields::PLATFORM, STORED);
    schema_builder.add_text_field(fields::CATEGORY, STORED);

    schema_builder.build()
}

/// Help search index
pub struct HelpSearchIndex {
    index: Index,
    reader: IndexReader,
    schema: Schema,
    id_field: Field,
    title_field: Field,
    body_field: Field,
    keywords_field: Field,
    platform_field: Field,
    category_field: Field,
}

impl HelpSearchIndex {
    /// Create or open an index at the given path
    pub fn open(path: &Path) -> Result<Self, HelpSearchError> {
        let schema = build_help_schema();

        let index = if path.exists() {
            Index::open_in_dir(path)?
        } else {
            std::fs::create_dir_all(path)?;
            Index::create_in_dir(path, schema.clone())?
        };

        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::OnCommitWithDelay)
            .try_into()?;

        Ok(Self {
            id_field: schema
                .get_field(fields::ID)
                .expect("schema missing 'id' field"),
            title_field: schema
                .get_field(fields::TITLE)
                .expect("schema missing 'title' field"),
            body_field: schema
                .get_field(fields::BODY)
                .expect("schema missing 'body' field"),
            keywords_field: schema
                .get_field(fields::KEYWORDS)
                .expect("schema missing 'keywords' field"),
            platform_field: schema
                .get_field(fields::PLATFORM)
                .expect("schema missing 'platform' field"),
            category_field: schema
                .get_field(fields::CATEGORY)
                .expect("schema missing 'category' field"),
            index,
            reader,
            schema,
        })
    }

    /// Create an in-memory index
    pub fn in_memory() -> Result<Self, HelpSearchError> {
        let schema = build_help_schema();
        let index = Index::create_in_ram(schema.clone());

        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;

        Ok(Self {
            id_field: schema
                .get_field(fields::ID)
                .expect("schema missing 'id' field"),
            title_field: schema
                .get_field(fields::TITLE)
                .expect("schema missing 'title' field"),
            body_field: schema
                .get_field(fields::BODY)
                .expect("schema missing 'body' field"),
            keywords_field: schema
                .get_field(fields::KEYWORDS)
                .expect("schema missing 'keywords' field"),
            platform_field: schema
                .get_field(fields::PLATFORM)
                .expect("schema missing 'platform' field"),
            category_field: schema
                .get_field(fields::CATEGORY)
                .expect("schema missing 'category' field"),
            index,
            reader,
            schema,
        })
    }

    /// Get a writer for the index
    pub fn writer(&self, heap_size: usize) -> Result<IndexWriter, HelpSearchError> {
        Ok(self.index.writer(heap_size)?)
    }

    /// Index a help document
    pub fn index_document(
        &self,
        writer: &mut IndexWriter,
        doc: &HelpDocument,
    ) -> Result<(), HelpSearchError> {
        // Delete existing document first
        writer.delete_term(Term::from_field_text(self.id_field, &doc.id));

        let mut tantivy_doc = TantivyDocument::new();

        tantivy_doc.add_text(self.id_field, &doc.id);
        tantivy_doc.add_text(self.title_field, &doc.title);
        tantivy_doc.add_text(self.body_field, &doc.body);
        tantivy_doc.add_text(self.keywords_field, doc.keywords.join(" "));
        tantivy_doc.add_text(self.platform_field, doc.platform.as_str());
        tantivy_doc.add_text(self.category_field, &doc.category);

        writer.add_document(tantivy_doc)?;
        Ok(())
    }

    /// Commit changes
    pub fn commit(&self, writer: &mut IndexWriter) -> Result<(), HelpSearchError> {
        writer.commit()?;
        self.reader.reload()?;
        Ok(())
    }

    /// Search help documents
    pub fn search(
        &self,
        query_str: &str,
        limit: usize,
        platform_filter: Option<HelpPlatform>,
    ) -> Result<Vec<HelpSearchResult>, HelpSearchError> {
        if query_str.trim().is_empty() {
            return Ok(Vec::new());
        }

        let searcher = self.reader.searcher();

        // Parse query for title, body, and keywords
        let query_parser = QueryParser::for_index(
            &self.index,
            vec![self.title_field, self.body_field, self.keywords_field],
        );

        let query = query_parser.parse_query(query_str)?;

        let top_docs = searcher.search(&query, &TopDocs::with_limit(limit * 2))?;

        // Extract query terms for highlighting
        let query_terms: Vec<String> = query_str
            .split_whitespace()
            .map(|s| s.to_lowercase())
            .collect();

        let mut results = Vec::new();
        let max_score = top_docs.first().map(|(s, _)| *s).unwrap_or(1.0);

        for (score, doc_address) in top_docs {
            let doc: TantivyDocument = searcher.doc(doc_address)?;

            let platform_str = doc
                .get_first(self.platform_field)
                .and_then(|v| v.as_str())
                .unwrap_or("both");
            let platform = HelpPlatform::from_str(platform_str);

            // Apply platform filter
            if let Some(filter) = platform_filter {
                if platform != HelpPlatform::Both && platform != filter {
                    continue;
                }
            }

            let id = doc
                .get_first(self.id_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let title = doc
                .get_first(self.title_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let body = doc
                .get_first(self.body_field)
                .and_then(|v| v.as_str())
                .unwrap_or("");

            let category = doc
                .get_first(self.category_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            // Generate snippet with highlighting
            let snippet = generate_highlighted_snippet(body, &query_terms, 150);

            // Normalize score to 0-1 range
            let relevance_score = if max_score > 0.0 {
                score / max_score
            } else {
                0.0
            };

            results.push(HelpSearchResult {
                id,
                title,
                snippet,
                relevance_score,
                platform,
                category,
            });

            if results.len() >= limit {
                break;
            }
        }

        Ok(results)
    }
}

/// Generate a snippet with highlighted terms
fn generate_highlighted_snippet(text: &str, query_terms: &[String], max_length: usize) -> String {
    // Find the best position to start the snippet
    let text_lower = text.to_lowercase();
    let mut best_pos: Option<usize> = None;

    for term in query_terms {
        if let Some(pos) = text_lower.find(term) {
            if best_pos.is_none() || pos < best_pos.unwrap() {
                best_pos = Some(pos);
            }
        }
    }

    let start_pos = best_pos.unwrap_or(0);

    // Calculate snippet boundaries
    let context_before = max_length / 3;
    let start = if start_pos > context_before {
        // Find word boundary
        let search_start = start_pos - context_before;
        text[search_start..start_pos]
            .rfind(char::is_whitespace)
            .map(|p| search_start + p + 1)
            .unwrap_or(search_start)
    } else {
        0
    };

    let end = (start + max_length).min(text.len());
    let end = text[start..end]
        .rfind(char::is_whitespace)
        .map(|p| start + p)
        .unwrap_or(end);

    let mut snippet = String::new();

    if start > 0 {
        snippet.push_str("...");
    }

    // Extract snippet and highlight terms
    let snippet_text = text[start..end].trim();
    let highlighted = highlight_terms_in_text(snippet_text, query_terms);
    snippet.push_str(&highlighted);

    if end < text.len() {
        snippet.push_str("...");
    }

    snippet
}

/// Highlight query terms using <mark> tags
fn highlight_terms_in_text(text: &str, query_terms: &[String]) -> String {
    let mut result = text.to_string();

    for term in query_terms {
        let term_lower = term.to_lowercase();
        let mut offset = 0;

        while let Some(pos) = result[offset..].to_lowercase().find(&term_lower) {
            let absolute_pos = offset + pos;
            let term_len = term.len();

            if absolute_pos + term_len <= result.len() {
                let original = &result[absolute_pos..absolute_pos + term_len];
                let highlighted = format!("<mark>{}</mark>", original);

                result.replace_range(absolute_pos..absolute_pos + term_len, &highlighted);
                offset = absolute_pos + highlighted.len();
            } else {
                break;
            }
        }
    }

    result
}

// ===== UniFFI Handle-Based API =====

lazy_static::lazy_static! {
    static ref HELP_INDEX_REGISTRY: RwLock<HashMap<u64, Arc<HelpIndexHandle>>> = RwLock::new(HashMap::new());
    static ref HELP_HANDLE_COUNTER: Mutex<u64> = Mutex::new(0);
}

struct HelpIndexHandle {
    index: HelpSearchIndex,
    writer: Mutex<Option<IndexWriter>>,
}

/// Create a new help search index at the given path
#[uniffi::export]
pub fn help_index_create(path: String) -> Result<u64, HelpSearchError> {
    let index = HelpSearchIndex::open(Path::new(&path))?;
    let writer = index.writer(15_000_000)?; // 15MB heap

    let handle = HelpIndexHandle {
        index,
        writer: Mutex::new(Some(writer)),
    };

    let mut counter = HELP_HANDLE_COUNTER.lock().unwrap();
    *counter += 1;
    let handle_id = *counter;

    let mut registry = HELP_INDEX_REGISTRY.write().unwrap();
    registry.insert(handle_id, Arc::new(handle));

    Ok(handle_id)
}

/// Create an in-memory help search index
#[uniffi::export]
pub fn help_index_create_in_memory() -> Result<u64, HelpSearchError> {
    let index = HelpSearchIndex::in_memory()?;
    let writer = index.writer(15_000_000)?;

    let handle = HelpIndexHandle {
        index,
        writer: Mutex::new(Some(writer)),
    };

    let mut counter = HELP_HANDLE_COUNTER.lock().unwrap();
    *counter += 1;
    let handle_id = *counter;

    let mut registry = HELP_INDEX_REGISTRY.write().unwrap();
    registry.insert(handle_id, Arc::new(handle));

    Ok(handle_id)
}

/// Add a help document to the index
#[uniffi::export]
pub fn help_index_add_document(
    handle_id: u64,
    document: HelpDocument,
) -> Result<(), HelpSearchError> {
    let registry = HELP_INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or(HelpSearchError::InvalidHandle)?
        .clone();

    let mut writer_guard = handle.writer.lock().unwrap();
    let writer = writer_guard.as_mut().ok_or(HelpSearchError::IndexError(
        "Writer not available".to_string(),
    ))?;

    handle.index.index_document(writer, &document)
}

/// Commit pending changes
#[uniffi::export]
pub fn help_index_commit(handle_id: u64) -> Result<(), HelpSearchError> {
    let registry = HELP_INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or(HelpSearchError::InvalidHandle)?
        .clone();

    let mut writer_guard = handle.writer.lock().unwrap();
    let writer = writer_guard.as_mut().ok_or(HelpSearchError::IndexError(
        "Writer not available".to_string(),
    ))?;

    handle.index.commit(writer)
}

/// Search the help index
#[uniffi::export]
pub fn help_index_search(
    handle_id: u64,
    query: String,
    limit: u32,
    platform: Option<HelpPlatform>,
) -> Result<Vec<HelpSearchResult>, HelpSearchError> {
    let registry = HELP_INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or(HelpSearchError::InvalidHandle)?
        .clone();

    handle.index.search(&query, limit as usize, platform)
}

/// Close and release a help index handle
#[uniffi::export]
pub fn help_index_close(handle_id: u64) -> Result<(), HelpSearchError> {
    let mut registry = HELP_INDEX_REGISTRY.write().unwrap();
    registry.remove(&handle_id);
    Ok(())
}

/// Get the number of active help index handles
#[uniffi::export]
pub fn help_index_handle_count() -> u32 {
    let registry = HELP_INDEX_REGISTRY.read().unwrap();
    registry.len() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_index_and_search_help() {
        let index = HelpSearchIndex::in_memory().unwrap();
        let mut writer = index.writer(15_000_000).unwrap();

        let doc = HelpDocument {
            id: "features/siri-shortcuts".to_string(),
            title: "Siri Shortcuts".to_string(),
            body: "imbib integrates with Apple's Shortcuts app and Siri, allowing you to automate paper management with voice commands.".to_string(),
            keywords: vec!["siri".to_string(), "shortcuts".to_string(), "automation".to_string(), "voice".to_string()],
            platform: HelpPlatform::Both,
            category: "features".to_string(),
        };

        index.index_document(&mut writer, &doc).unwrap();
        index.commit(&mut writer).unwrap();

        let results = index.search("siri", 10, None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "features/siri-shortcuts");
        assert!(results[0].snippet.contains("<mark>"));
    }

    #[test]
    fn test_platform_filtering() {
        let index = HelpSearchIndex::in_memory().unwrap();
        let mut writer = index.writer(15_000_000).unwrap();

        let ios_doc = HelpDocument {
            id: "features/widgets".to_string(),
            title: "Widgets".to_string(),
            body: "Home screen widgets for quick access.".to_string(),
            keywords: vec!["widgets".to_string()],
            platform: HelpPlatform::IOS,
            category: "features".to_string(),
        };

        let macos_doc = HelpDocument {
            id: "features/command-palette".to_string(),
            title: "Command Palette".to_string(),
            body: "Quick command access with keyboard.".to_string(),
            keywords: vec!["command".to_string(), "palette".to_string()],
            platform: HelpPlatform::MacOS,
            category: "features".to_string(),
        };

        index.index_document(&mut writer, &ios_doc).unwrap();
        index.index_document(&mut writer, &macos_doc).unwrap();
        index.commit(&mut writer).unwrap();

        // Search without filter - should find both
        let all_results = index.search("widgets OR command", 10, None).unwrap();
        assert_eq!(all_results.len(), 2);

        // Search with iOS filter
        let ios_results = index
            .search("widgets OR command", 10, Some(HelpPlatform::IOS))
            .unwrap();
        assert_eq!(ios_results.len(), 1);
        assert_eq!(ios_results[0].id, "features/widgets");

        // Search with macOS filter
        let macos_results = index
            .search("widgets OR command", 10, Some(HelpPlatform::MacOS))
            .unwrap();
        assert_eq!(macos_results.len(), 1);
        assert_eq!(macos_results[0].id, "features/command-palette");
    }

    #[test]
    fn test_highlighting() {
        let text = "This is a test about quantum mechanics and quantum physics.";
        let terms = vec!["quantum".to_string()];
        let highlighted = highlight_terms_in_text(text, &terms);

        assert!(highlighted.contains("<mark>quantum</mark>"));
        assert_eq!(highlighted.matches("<mark>").count(), 2);
    }

    #[test]
    fn test_snippet_generation() {
        let long_text = "Lorem ipsum dolor sit amet. The quantum mechanics topic is discussed here. More text follows after the relevant section.";
        let terms = vec!["quantum".to_string()];

        let snippet = generate_highlighted_snippet(long_text, &terms, 80);
        assert!(snippet.contains("<mark>quantum</mark>"));
        assert!(snippet.len() <= 100); // Some margin for ellipsis and marks
    }

    #[test]
    fn test_empty_query() {
        let index = HelpSearchIndex::in_memory().unwrap();
        let mut writer = index.writer(15_000_000).unwrap();

        let doc = HelpDocument {
            id: "test".to_string(),
            title: "Test".to_string(),
            body: "Test body".to_string(),
            keywords: vec![],
            platform: HelpPlatform::Both,
            category: "test".to_string(),
        };

        index.index_document(&mut writer, &doc).unwrap();
        index.commit(&mut writer).unwrap();

        let results = index.search("", 10, None).unwrap();
        assert!(results.is_empty());

        let results = index.search("   ", 10, None).unwrap();
        assert!(results.is_empty());
    }
}
