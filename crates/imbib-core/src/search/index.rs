//! Search index management

use super::schema::{build_schema, configure_tokenizers, fields};
use crate::domain::Publication;
use std::path::Path;
use tantivy::{
    collector::TopDocs,
    query::{BooleanQuery, Occur, QueryParser, TermQuery},
    schema::{Field, Value},
    Index, IndexReader, IndexWriter, ReloadPolicy, TantivyDocument, Term,
};
use thiserror::Error;

#[derive(Error, Debug, uniffi::Error)]
pub enum SearchIndexError {
    #[error("Index error: {0}")]
    IndexError(String),
    #[error("Query error: {0}")]
    QueryError(String),
    #[error("IO error: {0}")]
    IoError(String),
}

impl From<std::io::Error> for SearchIndexError {
    fn from(e: std::io::Error) -> Self {
        SearchIndexError::IoError(e.to_string())
    }
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
    #[allow(dead_code)]
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
            id_field: schema.get_field(fields::ID).expect("schema missing 'id' field"),
            cite_key_field: schema.get_field(fields::CITE_KEY).expect("schema missing 'cite_key' field"),
            title_field: schema.get_field(fields::TITLE).expect("schema missing 'title' field"),
            authors_field: schema.get_field(fields::AUTHORS).expect("schema missing 'authors' field"),
            abstract_field: schema.get_field(fields::ABSTRACT).expect("schema missing 'abstract' field"),
            full_text_field: schema.get_field(fields::FULL_TEXT).expect("schema missing 'full_text' field"),
            year_field: schema.get_field(fields::YEAR).expect("schema missing 'year' field"),
            journal_field: schema.get_field(fields::JOURNAL).expect("schema missing 'journal' field"),
            tags_field: schema.get_field(fields::TAGS).expect("schema missing 'tags' field"),
            notes_field: schema.get_field(fields::NOTES).expect("schema missing 'notes' field"),
            doi_field: schema.get_field(fields::DOI).expect("schema missing 'doi' field"),
            arxiv_id_field: schema.get_field(fields::ARXIV_ID).expect("schema missing 'arxiv_id' field"),
            library_id_field: schema.get_field(fields::LIBRARY_ID).expect("schema missing 'library_id' field"),
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
            id_field: schema.get_field(fields::ID).expect("schema missing 'id' field"),
            cite_key_field: schema.get_field(fields::CITE_KEY).expect("schema missing 'cite_key' field"),
            title_field: schema.get_field(fields::TITLE).expect("schema missing 'title' field"),
            authors_field: schema.get_field(fields::AUTHORS).expect("schema missing 'authors' field"),
            abstract_field: schema.get_field(fields::ABSTRACT).expect("schema missing 'abstract' field"),
            full_text_field: schema.get_field(fields::FULL_TEXT).expect("schema missing 'full_text' field"),
            year_field: schema.get_field(fields::YEAR).expect("schema missing 'year' field"),
            journal_field: schema.get_field(fields::JOURNAL).expect("schema missing 'journal' field"),
            tags_field: schema.get_field(fields::TAGS).expect("schema missing 'tags' field"),
            notes_field: schema.get_field(fields::NOTES).expect("schema missing 'notes' field"),
            doi_field: schema.get_field(fields::DOI).expect("schema missing 'doi' field"),
            arxiv_id_field: schema.get_field(fields::ARXIV_ID).expect("schema missing 'arxiv_id' field"),
            library_id_field: schema.get_field(fields::LIBRARY_ID).expect("schema missing 'library_id' field"),
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
        let authors_text = publication
            .authors
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
        let final_query: Box<dyn tantivy::query::Query> = if let Some(lib_id) = library_id {
            let lib_query = TermQuery::new(
                Term::from_field_text(self.library_id_field, lib_id),
                tantivy::schema::IndexRecordOption::Basic,
            );
            Box::new(BooleanQuery::new(vec![
                (Occur::Must, Box::new(text_query)),
                (Occur::Must, Box::new(lib_query)),
            ]))
        } else {
            Box::new(text_query)
        };

        let top_docs = searcher.search(&*final_query, &TopDocs::with_limit(limit))?;

        let mut results = Vec::new();
        for (score, doc_address) in top_docs {
            let doc: TantivyDocument = searcher.doc(doc_address)?;

            let id = doc
                .get_first(self.id_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let cite_key = doc
                .get_first(self.cite_key_field)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let title = doc
                .get_first(self.title_field)
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
        let results = self.search(query_str, limit, library_id)?;
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

// ===== UniFFI Handle-Based API =====
// This provides a stateful API for Swift/Kotlin to manage search indices

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};

lazy_static::lazy_static! {
    /// Global registry of search index handles
    static ref INDEX_REGISTRY: RwLock<HashMap<u64, Arc<IndexHandle>>> = RwLock::new(HashMap::new());
    /// Counter for generating unique handles
    static ref HANDLE_COUNTER: Mutex<u64> = Mutex::new(0);
}

struct IndexHandle {
    index: SearchIndex,
    writer: Mutex<Option<IndexWriter>>,
}

/// Create a new search index at the given path
/// Returns a handle ID for subsequent operations
#[uniffi::export]
pub fn search_index_create(path: String) -> Result<u64, SearchIndexError> {
    let index = SearchIndex::open(std::path::Path::new(&path))?;
    let writer = index.writer(50_000_000)?;

    let handle = IndexHandle {
        index,
        writer: Mutex::new(Some(writer)),
    };

    let mut counter = HANDLE_COUNTER.lock().unwrap();
    *counter += 1;
    let handle_id = *counter;

    let mut registry = INDEX_REGISTRY.write().unwrap();
    registry.insert(handle_id, Arc::new(handle));

    Ok(handle_id)
}

/// Create an in-memory search index (for testing)
/// Returns a handle ID for subsequent operations
#[uniffi::export]
pub fn search_index_create_in_memory() -> Result<u64, SearchIndexError> {
    let index = SearchIndex::in_memory()?;
    let writer = index.writer(50_000_000)?;

    let handle = IndexHandle {
        index,
        writer: Mutex::new(Some(writer)),
    };

    let mut counter = HANDLE_COUNTER.lock().unwrap();
    *counter += 1;
    let handle_id = *counter;

    let mut registry = INDEX_REGISTRY.write().unwrap();
    registry.insert(handle_id, Arc::new(handle));

    Ok(handle_id)
}

/// Add a publication to the search index
#[uniffi::export]
pub fn search_index_add(
    handle_id: u64,
    publication: Publication,
    full_text: Option<String>,
) -> Result<(), SearchIndexError> {
    let registry = INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or_else(|| SearchIndexError::IndexError("Invalid handle".to_string()))?
        .clone();

    let mut writer_guard = handle.writer.lock().unwrap();
    let writer = writer_guard
        .as_mut()
        .ok_or_else(|| SearchIndexError::IndexError("Writer not available".to_string()))?;

    handle
        .index
        .index_publication(writer, &publication, full_text.as_deref())
}

/// Delete a publication from the search index
#[uniffi::export]
pub fn search_index_delete(handle_id: u64, publication_id: String) -> Result<(), SearchIndexError> {
    let registry = INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or_else(|| SearchIndexError::IndexError("Invalid handle".to_string()))?
        .clone();

    let mut writer_guard = handle.writer.lock().unwrap();
    let writer = writer_guard
        .as_mut()
        .ok_or_else(|| SearchIndexError::IndexError("Writer not available".to_string()))?;

    handle.index.delete_publication(writer, &publication_id)
}

/// Commit pending changes to the search index
#[uniffi::export]
pub fn search_index_commit(handle_id: u64) -> Result<(), SearchIndexError> {
    let registry = INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or_else(|| SearchIndexError::IndexError("Invalid handle".to_string()))?
        .clone();

    let mut writer_guard = handle.writer.lock().unwrap();
    let writer = writer_guard
        .as_mut()
        .ok_or_else(|| SearchIndexError::IndexError("Writer not available".to_string()))?;

    handle.index.commit(writer)
}

/// Search the index
#[uniffi::export]
pub fn search_index_search(
    handle_id: u64,
    query: String,
    limit: u32,
    library_id: Option<String>,
) -> Result<Vec<SearchHit>, SearchIndexError> {
    let registry = INDEX_REGISTRY.read().unwrap();
    let handle = registry
        .get(&handle_id)
        .ok_or_else(|| SearchIndexError::IndexError("Invalid handle".to_string()))?
        .clone();

    handle
        .index
        .search(&query, limit as usize, library_id.as_deref())
}

/// Close and release a search index handle
#[uniffi::export]
pub fn search_index_close(handle_id: u64) -> Result<(), SearchIndexError> {
    let mut registry = INDEX_REGISTRY.write().unwrap();
    registry.remove(&handle_id);
    Ok(())
}

/// Get the number of active index handles (for debugging)
#[uniffi::export]
pub fn search_index_handle_count() -> u32 {
    let registry = INDEX_REGISTRY.read().unwrap();
    registry.len() as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Author;

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
        pub1.authors
            .push(Author::new("Einstein".to_string()).with_given_name("Albert"));
        pub1.abstract_text = Some("The theory of special relativity...".to_string());

        index
            .index_publication(
                &mut writer,
                &pub1,
                Some("This paper introduces special relativity"),
            )
            .unwrap();
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
        index
            .index_publication(
                &mut writer,
                &pub1,
                Some("This paper discusses quantum mechanics and feline behavior"),
            )
            .unwrap();
        index.commit(&mut writer).unwrap();

        // Should find via full text
        let results = index.search("quantum", 10, None).unwrap();
        assert_eq!(results.len(), 1);
    }
}
