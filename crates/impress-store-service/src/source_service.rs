//! Semantic writes and reads for immutable source provenance records.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schemas::{CONTENT_CHUNK_SCHEMA, EXTRACTION_RUN_SCHEMA, SOURCE_CITATION_SCHEMA};
use impress_core::source::{
    ContentChunk, ExtractedTextRegion, ExtractionRun, NormalizedRect, SourceCitation, SourceLocator,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::store::store_instance;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct NormalizedRectInput {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SourceLocatorInput {
    pub page_index: Option<u32>,
    pub page_label: Option<String>,
    pub region: Option<NormalizedRectInput>,
    pub char_start: Option<u64>,
    pub char_end: Option<u64>,
    #[serde(default)]
    pub section_path: Vec<String>,
    pub figure_label: Option<String>,
    pub table_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SourceCitationInput {
    pub id: String,
    pub source_item_id: String,
    pub source_content_hash: String,
    pub extraction_run_id: Option<String>,
    pub locator: SourceLocatorInput,
    pub quote: Option<String>,
    pub quote_hash: Option<String>,
    pub title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ExtractionRunInput {
    pub id: String,
    pub source_item_id: String,
    pub source_content_hash: String,
    pub extractor: String,
    pub extractor_version: String,
    pub profile: String,
    pub started_at: String,
    pub completed_at: Option<String>,
    pub output_content_hash: Option<String>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub produced_item_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContentChunkInput {
    pub id: String,
    pub source_item_id: String,
    pub extraction_run_id: String,
    pub citation_id: Option<String>,
    pub ordinal: u32,
    pub text: String,
    pub content_hash: String,
    pub locator: SourceLocatorInput,
    #[serde(default)]
    pub regions: Vec<ExtractedTextRegionInput>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ExtractedTextRegionInput {
    pub text: String,
    pub confidence: Option<f64>,
    pub region: NormalizedRectInput,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SourceRecordResult {
    pub ok: bool,
    pub id: String,
    pub record: Option<serde_json::Value>,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContentChunkSearchHit {
    pub chunk_id: String,
    pub citation_id: Option<String>,
    pub source_item_id: String,
    /// Display title resolved from the source asset when available.
    pub source_title: Option<String>,
    pub extraction_run_id: String,
    pub page_index: Option<u32>,
    pub page_label: Option<String>,
    pub section_path: Vec<String>,
    pub figure_label: Option<String>,
    pub table_label: Option<String>,
    /// A bounded FTS excerpt. Resolve `citation_id` for the exact source
    /// locator; extracted page text is intentionally not returned wholesale.
    pub excerpt: String,
    /// BM25 rank; lower values are more relevant.
    pub rank: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContentChunkSearchResult {
    pub ok: bool,
    pub hits: Vec<ContentChunkSearchHit>,
    pub message: String,
}

struct PutOptions<'a> {
    source_item_id: Uuid,
    extraction_run_id: Option<Uuid>,
    expected_source_hash: Option<&'a str>,
    indexed_text: Option<&'a str>,
    extra_reference: Option<TypedReference>,
}

#[impress_service]
pub trait SourceService: Send + Sync + 'static {
    /// Store an immutable structured citation after validating source hashes,
    /// page/range/region coordinates, and referenced source/extraction items.
    /// Repeating identical content is a no-op; conflicting content is refused.
    #[impress_method]
    async fn put_citation(&self, citation: SourceCitationInput) -> SourceRecordResult;

    /// Resolve one structured citation by UUID, including exact locator and
    /// immutable source hash.
    #[impress_method]
    async fn get_citation(&self, citation_id: String) -> SourceRecordResult;

    /// Store immutable extractor/OCR identity, input hash, output hash,
    /// warnings, and products for one derivation.
    #[impress_method]
    async fn put_extraction_run(&self, run: ExtractionRunInput) -> SourceRecordResult;

    /// Store one immutable domain-neutral text chunk with source locator and
    /// extraction lineage.
    #[impress_method]
    async fn put_content_chunk(&self, chunk: ContentChunkInput) -> SourceRecordResult;

    /// Resolve one selected search hit. Search stays compact; this operation
    /// returns the complete extracted chunk and its citation link on demand.
    #[impress_method]
    async fn get_content_chunk(&self, chunk_id: String) -> SourceRecordResult;

    /// Search extracted source text while preserving page/figure/table
    /// locators and extraction lineage. An optional source UUID confines the
    /// results to one asset; pass null to search all ingested sources.
    #[impress_method]
    async fn search_content_chunks(
        &self,
        query: String,
        source_item_id: Option<String>,
        limit: u32,
    ) -> ContentChunkSearchResult;
}

#[derive(Clone, Default)]
pub struct DefaultSourceService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultSourceService {
    pub fn new() -> Self {
        Self { store: None }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store.clone().unwrap_or_else(store_instance)
    }

    fn put<T: Serialize>(
        &self,
        id: Uuid,
        schema: &str,
        value: &T,
        options: PutOptions<'_>,
    ) -> SourceRecordResult {
        let json = match serde_json::to_value(value) {
            Ok(json) => json,
            Err(error) => return failed(id, error.to_string()),
        };
        let data: Value = match serde_json::from_value(json.clone()) {
            Ok(data) => data,
            Err(error) => return failed(id, error.to_string()),
        };
        let store = self.store();
        match store.get(id) {
            Ok(Some(existing)) => {
                let existing_json = existing
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok());
                if existing.schema == schema && existing_json.as_ref() == Some(&json) {
                    return SourceRecordResult {
                        ok: true,
                        id: id.to_string(),
                        record: Some(json),
                        message: "Identical immutable record already exists.".into(),
                    };
                }
                return failed(
                    id,
                    "immutable record id already exists with different content",
                );
            }
            Ok(None) => {}
            Err(error) => return failed(id, error.to_string()),
        }
        if !matches!(store.get(options.source_item_id), Ok(Some(_))) {
            return failed(id, "source_item_id does not resolve");
        }
        if let Some(extraction_id) = options.extraction_run_id {
            match store.get(extraction_id) {
                Ok(Some(item)) if item.schema == EXTRACTION_RUN_SCHEMA => {
                    let Some(data) = item.payload.get("data") else {
                        return failed(id, "extraction run has no data payload");
                    };
                    let run: ExtractionRun = match serde_json::to_value(data)
                        .ok()
                        .and_then(|value| serde_json::from_value(value).ok())
                    {
                        Some(run) => run,
                        None => return failed(id, "extraction run data is malformed"),
                    };
                    if run.source_item_id != options.source_item_id {
                        return failed(id, "extraction run belongs to a different source");
                    }
                    if options
                        .expected_source_hash
                        .is_some_and(|expected| expected != run.source_content_hash)
                    {
                        return failed(id, "source_content_hash does not match the extraction run");
                    }
                }
                _ => {
                    return failed(
                        id,
                        "extraction_run_id does not resolve to an extraction run",
                    )
                }
            }
        }
        let mut references = vec![TypedReference {
            target: options.source_item_id,
            edge_type: EdgeType::References,
            metadata: None,
        }];
        if let Some(extraction_id) = options.extraction_run_id {
            references.push(TypedReference {
                target: extraction_id,
                edge_type: EdgeType::DerivedFrom,
                metadata: None,
            });
        }
        if let Some(reference) = options.extra_reference {
            references.push(reference);
        }
        let mut payload = BTreeMap::from([
            ("title".into(), Value::String(schema.into())),
            ("data".into(), data),
        ]);
        if let Some(text) = options.indexed_text {
            payload.insert("body".into(), Value::String(text.into()));
        }
        let now = chrono::Utc::now();
        let item = Item {
            id,
            schema: schema.into(),
            payload,
            created: now,
            modified: now,
            author: "impress-source-service".into(),
            author_kind: ActorKind::System,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: options.extraction_run_id,
            version: Some("1.0.0".into()),
            batch_id: None,
            references,
            parent: Some(options.source_item_id),
        };
        match store.insert(item) {
            Ok(_) => SourceRecordResult {
                ok: true,
                id: id.to_string(),
                record: Some(json),
                message: "Stored immutable source record.".into(),
            },
            Err(error) => failed(id, error.to_string()),
        }
    }
}

#[async_trait::async_trait]
impl SourceService for DefaultSourceService {
    async fn put_citation(&self, input: SourceCitationInput) -> SourceRecordResult {
        let citation = match citation_from_input(input) {
            Ok(citation) => citation,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = citation.validate() {
            return failed(citation.id, error.to_string());
        }
        self.put(
            citation.id,
            SOURCE_CITATION_SCHEMA,
            &citation,
            PutOptions {
                source_item_id: citation.source_item_id,
                extraction_run_id: citation.extraction_run_id,
                expected_source_hash: Some(&citation.source_content_hash),
                indexed_text: None,
                extra_reference: None,
            },
        )
    }

    async fn get_citation(&self, citation_id: String) -> SourceRecordResult {
        let id = match Uuid::parse_str(&citation_id) {
            Ok(id) => id,
            Err(error) => return failed_string(citation_id, error.to_string()),
        };
        match self.store().get(id) {
            Ok(Some(item)) if item.schema == SOURCE_CITATION_SCHEMA => {
                match item
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok())
                {
                    Some(record) => SourceRecordResult {
                        ok: true,
                        id: id.to_string(),
                        record: Some(record),
                        message: "Resolved citation.".into(),
                    },
                    None => failed(id, "citation has no data payload"),
                }
            }
            Ok(Some(_)) => failed(id, "item is not a source citation"),
            Ok(None) => failed(id, "citation not found"),
            Err(error) => failed(id, error.to_string()),
        }
    }

    async fn put_extraction_run(&self, input: ExtractionRunInput) -> SourceRecordResult {
        let run = match extraction_from_input(input) {
            Ok(run) => run,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = run.validate() {
            return failed(run.id, error.to_string());
        }
        self.put(
            run.id,
            EXTRACTION_RUN_SCHEMA,
            &run,
            PutOptions {
                source_item_id: run.source_item_id,
                extraction_run_id: None,
                expected_source_hash: None,
                indexed_text: None,
                extra_reference: None,
            },
        )
    }

    async fn put_content_chunk(&self, input: ContentChunkInput) -> SourceRecordResult {
        let chunk = match chunk_from_input(input) {
            Ok(chunk) => chunk,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = chunk.validate() {
            return failed(chunk.id, error.to_string());
        }
        if let Some(citation_id) = chunk.citation_id {
            let citation = match self.store().get(citation_id) {
                Ok(Some(item)) if item.schema == SOURCE_CITATION_SCHEMA => item
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok())
                    .and_then(|value| serde_json::from_value::<SourceCitation>(value).ok()),
                _ => None,
            };
            let Some(citation) = citation else {
                return failed(
                    chunk.id,
                    "citation_id does not resolve to a source citation",
                );
            };
            if citation.source_item_id != chunk.source_item_id
                || citation.extraction_run_id != Some(chunk.extraction_run_id)
                || citation.locator != chunk.locator
            {
                return failed(
                    chunk.id,
                    "chunk citation must identify the same source, extraction, and locator",
                );
            }
        }
        self.put(
            chunk.id,
            CONTENT_CHUNK_SCHEMA,
            &chunk,
            PutOptions {
                source_item_id: chunk.source_item_id,
                extraction_run_id: Some(chunk.extraction_run_id),
                expected_source_hash: None,
                indexed_text: Some(&chunk.text),
                extra_reference: chunk.citation_id.map(|target| TypedReference {
                    target,
                    edge_type: EdgeType::Cites,
                    metadata: None,
                }),
            },
        )
    }

    async fn get_content_chunk(&self, chunk_id: String) -> SourceRecordResult {
        let id = match Uuid::parse_str(&chunk_id) {
            Ok(id) => id,
            Err(error) => return failed_string(chunk_id, error.to_string()),
        };
        match self.store().get(id) {
            Ok(Some(item)) if item.schema == CONTENT_CHUNK_SCHEMA => match item
                .payload
                .get("data")
                .and_then(|data| serde_json::to_value(data).ok())
            {
                Some(record) => SourceRecordResult {
                    ok: true,
                    id: id.to_string(),
                    record: Some(record),
                    message: "Resolved content chunk.".into(),
                },
                None => failed(id, "content chunk has no data payload"),
            },
            Ok(Some(_)) => failed(id, "item is not a content chunk"),
            Ok(None) => failed(id, "content chunk not found"),
            Err(error) => failed(id, error.to_string()),
        }
    }

    async fn search_content_chunks(
        &self,
        query: String,
        source_item_id: Option<String>,
        limit: u32,
    ) -> ContentChunkSearchResult {
        let source_filter = match source_item_id {
            Some(value) => match Uuid::parse_str(&value) {
                Ok(id) => Some(id),
                Err(error) => {
                    return ContentChunkSearchResult {
                        ok: false,
                        hits: vec![],
                        message: format!("invalid source_item_id: {error}"),
                    }
                }
            },
            None => None,
        };
        let requested = if limit == 0 { 10 } else { limit.min(50) } as usize;
        let store = self.store();
        let candidates = match source_search_candidates(&store, &query, requested) {
            Ok(hits) => hits,
            Err(error) => {
                return ContentChunkSearchResult {
                    ok: false,
                    hits: vec![],
                    message: error.to_string(),
                }
            }
        };
        let mut hits = Vec::with_capacity(requested);
        for candidate in candidates
            .into_iter()
            .filter(|candidate| candidate.schema_ref == CONTENT_CHUNK_SCHEMA)
        {
            let id = match Uuid::parse_str(&candidate.id) {
                Ok(id) => id,
                Err(_) => continue,
            };
            let chunk = match store.get(id) {
                Ok(Some(item)) => item
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok())
                    .and_then(|value| serde_json::from_value::<ContentChunk>(value).ok()),
                _ => None,
            };
            let Some(chunk) = chunk else { continue };
            if source_filter.is_some_and(|source| source != chunk.source_item_id) {
                continue;
            }
            let source_title = store
                .get(chunk.source_item_id)
                .ok()
                .flatten()
                .and_then(|source| match source.payload.get("title") {
                    Some(Value::String(title)) if !title.trim().is_empty() => Some(title.clone()),
                    _ => None,
                });
            hits.push(ContentChunkSearchHit {
                chunk_id: chunk.id.to_string(),
                citation_id: chunk.citation_id.map(|id| id.to_string()),
                source_item_id: chunk.source_item_id.to_string(),
                source_title,
                extraction_run_id: chunk.extraction_run_id.to_string(),
                page_index: chunk.locator.page_index,
                page_label: chunk.locator.page_label,
                section_path: chunk.locator.section_path,
                figure_label: chunk.locator.figure_label,
                table_label: chunk.locator.table_label,
                excerpt: candidate.snippet,
                rank: candidate.rank,
            });
            if hits.len() == requested {
                break;
            }
        }
        ContentChunkSearchResult {
            ok: true,
            message: format!("Found {} source chunk(s).", hits.len()),
            hits,
        }
    }
}

/// Search source pages precisely first, then recover from the verbose natural-
/// language queries models produce by ranking partial term coverage.
///
/// The suite-wide search kernel deliberately ANDs every term because its main
/// caller is a human-driven find box. Source retrieval has a different
/// contract: `1978 California L-Jetronic cold start valve location` must not
/// return nothing merely because the OCR page omits `location`. Exact matches
/// remain first; the fallback counts distinct matching terms, then uses BM25
/// and the item id as deterministic tie-breaks.
fn source_search_candidates(
    store: &SqliteItemStore,
    query: &str,
    requested: usize,
) -> Result<Vec<impress_core::search_ops::SearchHit>, impress_core::store::StoreError> {
    let mut candidates = impress_core::search_ops::search_all(store, query, 200)?
        .into_iter()
        .filter(|candidate| candidate.schema_ref == CONTENT_CHUNK_SCHEMA)
        .collect::<Vec<_>>();
    let mut seen = candidates
        .iter()
        .map(|candidate| candidate.id.clone())
        .collect::<BTreeSet<_>>();
    if candidates.len() >= requested {
        candidates.truncate(requested);
        return Ok(candidates);
    }

    struct PartialMatch {
        matched_terms: usize,
        rank_sum: f64,
        best: impress_core::search_ops::SearchHit,
    }

    let mut partial = BTreeMap::<String, PartialMatch>::new();
    for term in source_query_terms(query) {
        for hit in impress_core::search_ops::search_all(store, &term, 200)?
            .into_iter()
            .filter(|candidate| candidate.schema_ref == CONTENT_CHUNK_SCHEMA)
        {
            if seen.contains(&hit.id) {
                continue;
            }
            partial
                .entry(hit.id.clone())
                .and_modify(|entry| {
                    entry.matched_terms += 1;
                    entry.rank_sum += hit.rank;
                    if hit.rank < entry.best.rank {
                        entry.best = hit.clone();
                    }
                })
                .or_insert(PartialMatch {
                    matched_terms: 1,
                    rank_sum: hit.rank,
                    best: hit,
                });
        }
    }
    let mut partial = partial.into_values().collect::<Vec<_>>();
    partial.sort_by(|left, right| {
        right
            .matched_terms
            .cmp(&left.matched_terms)
            .then_with(|| left.rank_sum.total_cmp(&right.rank_sum))
            .then_with(|| left.best.id.cmp(&right.best.id))
    });
    for entry in partial {
        if candidates.len() == requested {
            break;
        }
        if seen.insert(entry.best.id.clone()) {
            candidates.push(entry.best);
        }
    }
    Ok(candidates)
}

fn source_query_terms(query: &str) -> Vec<String> {
    const INTENT_WORDS: &[&str] = &[
        "about",
        "component",
        "components",
        "find",
        "identification",
        "identify",
        "information",
        "locate",
        "location",
        "manual",
        "system",
        "that",
        "the",
        "this",
        "volkswagen",
        "where",
        "with",
    ];
    let mut terms = query
        .split(|character: char| !character.is_alphanumeric())
        .map(str::to_lowercase)
        .filter(|term| term.len() >= 3 && !INTENT_WORDS.contains(&term.as_str()))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    terms.sort_by_key(|term| std::cmp::Reverse(term.len()));
    terms.truncate(12);
    terms
}

impress_service_impl! {
    service = SourceService,
    impl = DefaultSourceService,
    instance = DefaultSourceService::new,
    methods = [
        put_citation(citation: SourceCitationInput) -> SourceRecordResult,
        get_citation(citation_id: String) -> SourceRecordResult,
        put_extraction_run(run: ExtractionRunInput) -> SourceRecordResult,
        put_content_chunk(chunk: ContentChunkInput) -> SourceRecordResult,
        get_content_chunk(chunk_id: String) -> SourceRecordResult,
        search_content_chunks(query: String, source_item_id: Option<String>, limit: u32) -> ContentChunkSearchResult,
    ],
}

fn locator_from_input(input: SourceLocatorInput) -> Result<SourceLocator, String> {
    let char_range = match (input.char_start, input.char_end) {
        (None, None) => None,
        (Some(start), Some(end)) => Some((start, end)),
        _ => return Err("char_start and char_end must be supplied together".into()),
    };
    let region = input
        .region
        .map(|region| NormalizedRect::new(region.x, region.y, region.width, region.height))
        .transpose()
        .map_err(|error| error.to_string())?;
    Ok(SourceLocator {
        page_index: input.page_index,
        page_label: input.page_label,
        region,
        char_range,
        section_path: input.section_path,
        figure_label: input.figure_label,
        table_label: input.table_label,
    })
}

fn citation_from_input(input: SourceCitationInput) -> Result<SourceCitation, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    Ok(SourceCitation {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        source_content_hash: input.source_content_hash,
        extraction_run_id: input.extraction_run_id.as_deref().map(parse).transpose()?,
        locator: locator_from_input(input.locator).map_err(|error| (id.clone(), error))?,
        quote: input.quote,
        quote_hash: input.quote_hash,
        title: input.title,
    })
}

fn extraction_from_input(input: ExtractionRunInput) -> Result<ExtractionRun, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    Ok(ExtractionRun {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        source_content_hash: input.source_content_hash,
        extractor: input.extractor,
        extractor_version: input.extractor_version,
        profile: input.profile,
        started_at: input.started_at,
        completed_at: input.completed_at,
        output_content_hash: input.output_content_hash,
        warnings: input.warnings,
        produced_item_ids: input
            .produced_item_ids
            .iter()
            .map(|value| parse(value))
            .collect::<Result<Vec<_>, _>>()?,
    })
}

fn chunk_from_input(input: ContentChunkInput) -> Result<ContentChunk, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    Ok(ContentChunk {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        extraction_run_id: parse(&input.extraction_run_id)?,
        citation_id: input.citation_id.as_deref().map(parse).transpose()?,
        ordinal: input.ordinal,
        text: input.text,
        content_hash: input.content_hash,
        locator: locator_from_input(input.locator).map_err(|error| (id.clone(), error))?,
        regions: input
            .regions
            .into_iter()
            .map(|region| {
                Ok(ExtractedTextRegion {
                    text: region.text,
                    confidence: region.confidence,
                    region: NormalizedRect::new(
                        region.region.x,
                        region.region.y,
                        region.region.width,
                        region.region.height,
                    )
                    .map_err(|error| (id.clone(), error.to_string()))?,
                })
            })
            .collect::<Result<Vec<_>, (String, String)>>()?,
    })
}

fn failed(id: Uuid, message: impl Into<String>) -> SourceRecordResult {
    failed_string(id.to_string(), message)
}

fn failed_string(id: String, message: impl Into<String>) -> SourceRecordResult {
    SourceRecordResult {
        ok: false,
        id,
        record: None,
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item_named, test_store};

    const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const OTHER_HASH: &str = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

    #[tokio::test]
    async fn citation_put_is_idempotent_and_conflicts_are_refused() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let input = SourceCitationInput {
            id: Uuid::new_v4().to_string(),
            source_item_id: source,
            source_content_hash: HASH.into(),
            extraction_run_id: None,
            locator: SourceLocatorInput {
                page_index: Some(0),
                page_label: Some("1".into()),
                region: None,
                char_start: None,
                char_end: None,
                section_path: vec![],
                figure_label: None,
                table_label: None,
            },
            quote: Some("Fixture excerpt".into()),
            quote_hash: Some(impress_core::source::normalized_text_hash(
                "Fixture excerpt",
            )),
            title: Some("Manual".into()),
        };
        assert!(service.put_citation(input.clone()).await.ok);
        assert!(service.put_citation(input.clone()).await.ok);
        let mut changed = input;
        changed.quote = Some("Different".into());
        assert!(!service.put_citation(changed).await.ok);
    }

    #[tokio::test]
    async fn citation_and_extraction_run_must_name_the_same_source_bytes() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.clone(),
                    source_content_hash: HASH.into(),
                    extractor: "fixture-ocr".into(),
                    extractor_version: "1".into(),
                    profile: "layout".into(),
                    started_at: "2026-08-05T12:00:00Z".into(),
                    completed_at: None,
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        let result = service
            .put_citation(SourceCitationInput {
                id: Uuid::new_v4().to_string(),
                source_item_id: source,
                source_content_hash: OTHER_HASH.into(),
                extraction_run_id: Some(run_id),
                locator: SourceLocatorInput {
                    page_index: Some(0),
                    page_label: None,
                    region: None,
                    char_start: None,
                    char_end: None,
                    section_path: vec![],
                    figure_label: None,
                    table_label: None,
                },
                quote: None,
                quote_hash: None,
                title: None,
            })
            .await;
        assert!(!result.ok);
        assert!(result.message.contains("does not match"));
    }

    #[tokio::test]
    async fn content_chunks_are_full_text_searchable_with_page_provenance() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.clone(),
                    source_content_hash: HASH.into(),
                    extractor: "fixture-ocr".into(),
                    extractor_version: "1".into(),
                    profile: "layout".into(),
                    started_at: "2026-08-05T12:00:00Z".into(),
                    completed_at: None,
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        let text = "Synthetic airflow meter diagnostic fixture";
        assert!(
            service
                .put_content_chunk(ContentChunkInput {
                    id: Uuid::new_v4().to_string(),
                    source_item_id: source.clone(),
                    extraction_run_id: run_id,
                    citation_id: None,
                    ordinal: 0,
                    text: text.into(),
                    content_hash: impress_core::source::normalized_text_hash(text),
                    locator: SourceLocatorInput {
                        page_index: Some(7),
                        page_label: Some("8".into()),
                        region: None,
                        char_start: None,
                        char_end: None,
                        section_path: vec!["Synthetic test".into()],
                        figure_label: None,
                        table_label: None,
                    },
                    regions: vec![ExtractedTextRegionInput {
                        text: "Synthetic airflow meter diagnostic fixture".into(),
                        confidence: Some(0.95),
                        region: NormalizedRectInput {
                            x: 0.1,
                            y: 0.2,
                            width: 0.6,
                            height: 0.1,
                        },
                    }],
                })
                .await
                .ok
        );
        let result = service
            .search_content_chunks("airflow diagnostic".into(), Some(source), 5)
            .await;
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.hits.len(), 1);
        assert_eq!(result.hits[0].page_index, Some(7));
        assert_eq!(result.hits[0].source_title.as_deref(), Some("Manual"));
        assert!(result.hits[0].excerpt.contains("airflow"));
        let resolved = service
            .get_content_chunk(result.hits[0].chunk_id.clone())
            .await;
        assert!(resolved.ok, "{}", resolved.message);
        let record = resolved.record.unwrap();
        assert_eq!(record["text"], text);
        assert_eq!(record["regions"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn source_search_recovers_from_verbose_intent_terms() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.clone(),
                    source_content_hash: HASH.into(),
                    extractor: "fixture-ocr".into(),
                    extractor_version: "1".into(),
                    profile: "layout".into(),
                    started_at: "2026-08-05T12:00:00Z".into(),
                    completed_at: None,
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        let text = "The L-Jetronic cold start valve is controlled by the thermo-time switch.";
        assert!(
            service
                .put_content_chunk(ContentChunkInput {
                    id: Uuid::new_v4().to_string(),
                    source_item_id: source,
                    extraction_run_id: run_id,
                    citation_id: None,
                    ordinal: 0,
                    text: text.into(),
                    content_hash: impress_core::source::normalized_text_hash(text),
                    locator: SourceLocatorInput {
                        page_index: Some(10),
                        page_label: Some("11".into()),
                        region: None,
                        char_start: None,
                        char_end: None,
                        section_path: vec![],
                        figure_label: None,
                        table_label: None,
                    },
                    regions: vec![],
                })
                .await
                .ok
        );

        let result = service
            .search_content_chunks(
                "1978 California L-Jetronic cold start valve location identification".into(),
                None,
                5,
            )
            .await;
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.hits.len(), 1);
        assert_eq!(result.hits[0].page_label.as_deref(), Some("11"));
    }
}
