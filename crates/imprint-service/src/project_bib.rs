//! The `BibliographyResolver` port over the shared store (ADR-0030 D7):
//! imbib's `imbib/bibliography-entry` rows answer cite keys with their own
//! `raw_bibtex` when they hold it, otherwise with their metadata fields
//! (which the engine synthesises into an entry and flags).
//!
//! Collection membership is what imbib writes: `Contains` references on the
//! collection item; library membership is the row's parent.

use std::collections::BTreeMap;
use std::sync::Arc;

use impress_core::item::{Item, Value};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::EdgeType;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use imprint_core::project::{BibliographyResolver, ResolvedEntry};

/// THE publication ref imbib writes (see `schema-refs.json`: reading the bare
/// `bibliography-entry` is the iOS-citation-picker bug).
const ENTRY_SCHEMA: &str = "imbib/bibliography-entry";

pub struct StoreBibliographyResolver {
    store: Arc<SqliteItemStore>,
}

impl StoreBibliographyResolver {
    pub fn new(store: Arc<SqliteItemStore>) -> Self {
        Self { store }
    }

    fn entry_of(item: &Item) -> ResolvedEntry {
        let p = &item.payload;
        if let Some(Value::String(raw)) = p.get("raw_bibtex") {
            if !raw.trim().is_empty() {
                return ResolvedEntry::Raw(raw.clone());
            }
        }
        let mut fields: BTreeMap<String, String> = BTreeMap::new();
        let string = |key: &str| match p.get(key) {
            Some(Value::String(s)) if !s.trim().is_empty() => Some(s.clone()),
            _ => None,
        };
        if let Some(t) = string("title") {
            fields.insert("title".into(), t);
        }
        if let Some(Value::Array(authors)) = p.get("authors") {
            let names: Vec<String> = authors
                .iter()
                .filter_map(|a| match a {
                    Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
                    _ => None,
                })
                .collect();
            if !names.is_empty() {
                fields.insert("author".into(), names.join(" and "));
            }
        }
        match p.get("year") {
            Some(Value::Int(y)) => {
                fields.insert("year".into(), y.to_string());
            }
            Some(Value::String(y)) if !y.trim().is_empty() => {
                fields.insert("year".into(), y.trim().to_string());
            }
            _ => {}
        }
        for (key, out) in [
            ("journal", "journal"),
            ("venue", "booktitle"),
            ("doi", "doi"),
            ("url", "url"),
            ("arxiv_id", "eprint"),
            ("bibcode", "adsurl"),
            ("abstract", "abstract"),
            ("keywords", "keywords"),
            ("volume", "volume"),
            ("number", "number"),
            ("pages", "pages"),
            ("publisher", "publisher"),
        ] {
            if let Some(v) = string(key) {
                fields.entry(out.into()).or_insert(v);
            }
        }
        if fields.contains_key("eprint") {
            fields
                .entry("archiveprefix".into())
                .or_insert_with(|| "arXiv".into());
        }
        ResolvedEntry::Fields {
            entry_type: string("entry_type").unwrap_or_else(|| "misc".into()),
            fields,
        }
    }

    fn key_of(item: &Item) -> Option<String> {
        match item.payload.get("cite_key") {
            Some(Value::String(k)) if !k.trim().is_empty() => Some(k.clone()),
            _ => None,
        }
    }
}

impl BibliographyResolver for StoreBibliographyResolver {
    fn entry_for_key(&self, key: &str) -> Option<ResolvedEntry> {
        let q = ItemQuery {
            schema: Some(ENTRY_SCHEMA.into()),
            predicates: vec![Predicate::Eq("cite_key".into(), Value::String(key.into()))],
            limit: Some(1),
            include_tags: false,
            include_references: false,
            ..ItemQuery::default()
        };
        self.store.query(&q).ok()?.first().map(Self::entry_of)
    }

    fn keys_in_collection(&self, _library_id: &str, collection_id: &str) -> Vec<String> {
        let Ok(id) = collection_id.parse() else {
            return Vec::new();
        };
        let Ok(Some(collection)) = self.store.get(id) else {
            return Vec::new();
        };
        let mut keys = Vec::new();
        for reference in &collection.references {
            if reference.edge_type != EdgeType::Contains {
                continue;
            }
            if let Ok(Some(member)) = self.store.get(reference.target) {
                if member.schema == ENTRY_SCHEMA {
                    if let Some(k) = Self::key_of(&member) {
                        keys.push(k);
                    }
                }
            }
        }
        keys.sort();
        keys.dedup();
        keys
    }

    fn keys_in_library(&self, library_id: &str) -> Vec<String> {
        let Ok(id) = library_id.parse() else {
            return Vec::new();
        };
        let q = ItemQuery {
            schema: Some(ENTRY_SCHEMA.into()),
            predicates: vec![Predicate::HasParent(id)],
            include_tags: false,
            include_references: false,
            ..ItemQuery::default()
        };
        let mut keys: Vec<String> = self
            .store
            .query(&q)
            .unwrap_or_default()
            .iter()
            .filter_map(Self::key_of)
            .collect();
        keys.sort();
        keys.dedup();
        keys
    }
}
