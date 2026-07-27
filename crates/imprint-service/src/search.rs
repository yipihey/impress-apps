//! Cross-document full-text search over manuscript sections.
//!
//! Port of `apps/imprint/Packages/ImprintCore/Sources/ImprintCore/
//! ManuscriptSearchService.swift`, but built on tantivy (BM25, stemming,
//! prefix matching) so it shares the same library as imbib's publication
//! search rather than the hand-rolled inverted-index the Swift version uses.
//!
//! The index is single-process: a `ManuscriptSearchIndex` owns an in-memory
//! tantivy index. Callers refresh it from the section store on whatever
//! cadence makes sense for them — in-app this will be event-driven; for the
//! CLI/MCP entry points it is one-shot.

use std::path::Path;
use std::sync::Mutex;

use tantivy::{
    collector::TopDocs,
    query::QueryParser,
    schema::{
        Field, IndexRecordOption, Schema, SchemaBuilder, TextFieldIndexing, TextOptions, FAST,
        STORED, STRING,
    },
    Index, IndexReader, IndexWriter, ReloadPolicy, TantivyDocument, Term,
};

use crate::error::ServiceError;
use crate::sections::{SectionRecord, SectionStore};

mod fields {
    pub const ITEM_ID: &str = "item_id";
    pub const DOCUMENT_ID: &str = "document_id";
    pub const SECTION_KEY: &str = "section_key";
    pub const TITLE: &str = "title";
    pub const BODY: &str = "body";
    pub const SECTION_TYPE: &str = "section_type";
    pub const ORDER_INDEX: &str = "order_index";
}

fn build_schema() -> Schema {
    let mut b = SchemaBuilder::new();
    b.add_text_field(fields::ITEM_ID, STRING | STORED);
    b.add_text_field(fields::DOCUMENT_ID, STRING | STORED);
    b.add_text_field(fields::SECTION_KEY, STRING | STORED);
    let text_opts = TextOptions::default()
        .set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("en_stem")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions),
        )
        .set_stored();
    b.add_text_field(fields::TITLE, text_opts.clone());
    b.add_text_field(fields::BODY, text_opts);
    b.add_text_field(fields::SECTION_TYPE, STRING | STORED);
    b.add_i64_field(fields::ORDER_INDEX, STORED | FAST);
    b.build()
}

fn configure_tokenizers(index: &Index) {
    let mgr = index.tokenizers();
    mgr.register(
        "en_stem",
        tantivy::tokenizer::TextAnalyzer::builder(tantivy::tokenizer::SimpleTokenizer::default())
            .filter(tantivy::tokenizer::RemoveLongFilter::limit(40))
            .filter(tantivy::tokenizer::LowerCaser)
            .filter(tantivy::tokenizer::Stemmer::new(
                tantivy::tokenizer::Language::English,
            ))
            .build(),
    );
}

/// A single hit returned by `search`.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub item_id: String,
    pub document_id: String,
    pub section_key: String,
    pub title: String,
    pub section_type: Option<String>,
    pub score: f32,
    /// Short excerpt centred on the first match, like the Swift service.
    pub excerpt: Option<String>,
}

/// Tantivy-backed manuscript section search.
pub struct ManuscriptSearchIndex {
    index: Index,
    reader: IndexReader,
    writer: Mutex<IndexWriter>,
    fields: FieldHandles,
}

#[derive(Clone)]
struct FieldHandles {
    item_id: Field,
    document_id: Field,
    section_key: Field,
    title: Field,
    body: Field,
    section_type: Field,
    order_index: Field,
}

impl FieldHandles {
    fn from(schema: &Schema) -> Self {
        Self {
            item_id: schema.get_field(fields::ITEM_ID).unwrap(),
            document_id: schema.get_field(fields::DOCUMENT_ID).unwrap(),
            section_key: schema.get_field(fields::SECTION_KEY).unwrap(),
            title: schema.get_field(fields::TITLE).unwrap(),
            body: schema.get_field(fields::BODY).unwrap(),
            section_type: schema.get_field(fields::SECTION_TYPE).unwrap(),
            order_index: schema.get_field(fields::ORDER_INDEX).unwrap(),
        }
    }
}

impl ManuscriptSearchIndex {
    /// Create or open an on-disk index.
    pub fn open(path: &Path) -> Result<Self, ServiceError> {
        let schema = build_schema();
        let index = if path.exists() {
            Index::open_in_dir(path)?
        } else {
            std::fs::create_dir_all(path).map_err(|source| ServiceError::BlobIo {
                path: path.to_path_buf(),
                source,
            })?;
            Index::create_in_dir(path, schema.clone())?
        };
        configure_tokenizers(&index);
        Self::finish(index, schema)
    }

    /// Create a new in-memory index. Useful for tests and for short-lived CLI
    /// invocations that don't want to manage on-disk state.
    pub fn in_memory() -> Result<Self, ServiceError> {
        let schema = build_schema();
        let index = Index::create_in_ram(schema.clone());
        configure_tokenizers(&index);
        Self::finish(index, schema)
    }

    fn finish(index: Index, schema: Schema) -> Result<Self, ServiceError> {
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        let writer = index.writer(50_000_000)?;
        let fields = FieldHandles::from(&schema);
        Ok(Self {
            index,
            reader,
            writer: Mutex::new(writer),
            fields,
        })
    }

    /// Index (or re-index) a single section. Existing documents with the same
    /// `item_id` are removed first so this is idempotent.
    pub fn index_section(&self, section: &SectionRecord) -> Result<(), ServiceError> {
        let writer = self
            .writer
            .lock()
            .map_err(|_| ServiceError::Search("writer poisoned".into()))?;
        let id_term = Term::from_field_text(self.fields.item_id, &section.item_id.to_string());
        writer.delete_term(id_term);

        let mut doc = TantivyDocument::new();
        doc.add_text(self.fields.item_id, section.item_id.to_string());
        doc.add_text(self.fields.document_id, section.document_id.to_string());
        doc.add_text(self.fields.section_key, &section.section_key);
        doc.add_text(self.fields.title, &section.title);
        doc.add_text(self.fields.body, &section.body);
        if let Some(ty) = &section.section_type {
            doc.add_text(self.fields.section_type, ty);
        }
        if let Some(order) = section.order_index {
            doc.add_i64(self.fields.order_index, order);
        }
        writer.add_document(doc)?;
        Ok(())
    }

    /// Drop a section from the index.
    pub fn remove_section(&self, item_id: uuid::Uuid) -> Result<(), ServiceError> {
        let writer = self
            .writer
            .lock()
            .map_err(|_| ServiceError::Search("writer poisoned".into()))?;
        let id_term = Term::from_field_text(self.fields.item_id, &item_id.to_string());
        writer.delete_term(id_term);
        Ok(())
    }

    /// Commit pending writes and refresh the reader so subsequent `search()`
    /// calls observe them.
    pub fn commit(&self) -> Result<(), ServiceError> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| ServiceError::Search("writer poisoned".into()))?;
        writer.commit()?;
        self.reader.reload()?;
        Ok(())
    }

    /// Replace the entire index with the contents of `store`.
    pub fn rebuild_from(&self, store: &SectionStore) -> Result<usize, ServiceError> {
        // Delete-all is the cleanest reset that doesn't require recreating
        // the tantivy directory.
        {
            let writer = self
                .writer
                .lock()
                .map_err(|_| ServiceError::Search("writer poisoned".into()))?;
            writer.delete_all_documents()?;
        }
        let sections = store.list_all_sections(0)?;
        let count = sections.len();
        for section in &sections {
            self.index_section(section)?;
        }
        self.commit()?;
        Ok(count)
    }

    /// Run a search. Matches the Swift contract: case-insensitive, AND
    /// semantics across whitespace-separated terms.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, ServiceError> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let searcher = self.reader.searcher();
        let mut parser =
            QueryParser::for_index(&self.index, vec![self.fields.title, self.fields.body]);
        parser.set_conjunction_by_default();

        // Match the Swift adapter's prefix-on-last-token behaviour so typing
        // "gevolutio" still finds "gevolution".
        let effective = if query.contains(|c: char| "+-\"*~^:(){}[]".contains(c)) {
            query.to_string()
        } else if let Some(last_space) = query.rfind(' ') {
            format!("{} {}*", &query[..last_space], &query[last_space + 1..])
        } else {
            format!("{}*", query)
        };

        let parsed = parser.parse_query(&effective)?;
        let top = searcher.search(&parsed, &TopDocs::with_limit(limit.max(1)))?;

        let query_terms: Vec<String> = query
            .split_whitespace()
            .filter(|w| w.len() >= 2)
            .map(|w| w.to_lowercase())
            .collect();

        let mut hits = Vec::with_capacity(top.len());
        for (score, addr) in top {
            let doc: TantivyDocument = searcher.doc(addr)?;
            let item_id = string_field(&doc, self.fields.item_id);
            let document_id = string_field(&doc, self.fields.document_id);
            let section_key = string_field(&doc, self.fields.section_key);
            let title = string_field(&doc, self.fields.title);
            let section_type = nonempty(string_field(&doc, self.fields.section_type));
            let body = string_field(&doc, self.fields.body);
            let excerpt = make_excerpt(&body, &query_terms).or_else(|| {
                if title.is_empty() {
                    None
                } else {
                    Some(title.chars().take(140).collect())
                }
            });
            hits.push(SearchHit {
                item_id,
                document_id,
                section_key,
                title,
                section_type,
                score,
                excerpt,
            });
        }
        Ok(hits)
    }
}

fn string_field(doc: &TantivyDocument, f: Field) -> String {
    use tantivy::schema::Value;
    doc.get_first(f)
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

fn nonempty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Build a ±60-char window around the first matching term, matching the Swift
/// `makeExcerpt` helper.
fn make_excerpt(body: &str, terms: &[String]) -> Option<String> {
    if body.is_empty() {
        return None;
    }
    let lower = body.to_lowercase();
    let mut start_byte: Option<usize> = None;
    for term in terms {
        if let Some(pos) = lower.find(term.as_str()) {
            start_byte = Some(pos);
            break;
        }
    }
    let start_byte = start_byte?;
    // Walk back up to 60 characters from start_byte; walk forward up to 100.
    let prefix_end = char_floor(body, start_byte);
    let window_start = back_chars(body, prefix_end, 60);
    let window_end = forward_chars(body, prefix_end, 100);
    let slice = &body[window_start..window_end];
    let mut out = String::with_capacity(slice.len() + 2);
    if window_start > 0 {
        out.push('…');
    }
    for ch in slice.chars() {
        if ch == '\n' {
            out.push(' ');
        } else {
            out.push(ch);
        }
    }
    if window_end < body.len() {
        out.push('…');
    }
    Some(out)
}

fn char_floor(s: &str, byte_idx: usize) -> usize {
    let mut i = byte_idx;
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

fn back_chars(s: &str, byte_idx: usize, n_chars: usize) -> usize {
    let mut remaining = n_chars;
    let mut idx = byte_idx;
    while remaining > 0 && idx > 0 {
        idx -= 1;
        while idx > 0 && !s.is_char_boundary(idx) {
            idx -= 1;
        }
        remaining -= 1;
    }
    idx
}

fn forward_chars(s: &str, byte_idx: usize, n_chars: usize) -> usize {
    let mut remaining = n_chars;
    let mut idx = byte_idx;
    while remaining > 0 && idx < s.len() {
        idx += 1;
        while idx < s.len() && !s.is_char_boundary(idx) {
            idx += 1;
        }
        remaining -= 1;
    }
    idx
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sections::{SectionMetadata, SectionStore};
    use tempfile::TempDir;
    use uuid::Uuid;

    fn fresh_store() -> (SectionStore, TempDir) {
        let dir = TempDir::new().unwrap();
        let store = SectionStore::open_in_memory(dir.path().join("content")).unwrap();
        (store, dir)
    }

    #[test]
    fn index_and_search_finds_hit() {
        let (store, _dir) = fresh_store();
        let doc = Uuid::new_v4();
        let rec = store
            .put_section(
                doc,
                "intro",
                "The CMB and large-scale structure constrain dark matter halo bias.",
                SectionMetadata {
                    title: Some("Introduction".into()),
                    ..Default::default()
                },
            )
            .unwrap();

        let idx = ManuscriptSearchIndex::in_memory().unwrap();
        idx.index_section(&rec).unwrap();
        idx.commit().unwrap();

        let hits = idx.search("halo bias", 10).unwrap();
        assert_eq!(hits.len(), 1);
        let h = &hits[0];
        assert_eq!(h.item_id, rec.item_id.to_string());
        assert!(h
            .excerpt
            .as_deref()
            .unwrap()
            .to_lowercase()
            .contains("halo"));
    }

    #[test]
    fn rebuild_from_store_indexes_all_sections() {
        let (store, _dir) = fresh_store();
        let doc = Uuid::new_v4();
        for (key, body) in [
            ("a", "alpha quantum"),
            ("b", "beta classical"),
            ("c", "gamma quantum mechanics"),
        ] {
            store
                .put_section(doc, key, body, SectionMetadata::default())
                .unwrap();
        }
        let idx = ManuscriptSearchIndex::in_memory().unwrap();
        let n = idx.rebuild_from(&store).unwrap();
        assert_eq!(n, 3);

        let hits = idx.search("quantum", 10).unwrap();
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn empty_query_returns_no_hits() {
        let idx = ManuscriptSearchIndex::in_memory().unwrap();
        idx.commit().unwrap();
        let hits = idx.search("   ", 10).unwrap();
        assert!(hits.is_empty());
    }
}
