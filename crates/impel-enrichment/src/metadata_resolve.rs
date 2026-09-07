//! `metadata-resolve` — ADR-0005 §9's first pipeline stage.
//!
//! Fetches metadata for the publication the task `OperatesOn` from each
//! configured source, merges via `imbib-core`'s priority-aware
//! `merge_metadata`, and persists **only** `changed_fields` as attributed
//! `SetPayload` operations (Durable — corrected fields are part of the
//! research record, ADR-0005 §9 retention table).
//!
//! ## The record outranks the sources (fill-only persistence)
//!
//! `merge_metadata` ranks the stored record `usize::MAX` (it has no
//! source id), so inside the merge every configured source "wins" over
//! it — which is the right way to COMBINE sources, and exactly the wrong
//! thing to WRITE BACK: a user-corrected title would be silently reverted
//! to whatever arXiv serves. Persistence therefore applies descriptive
//! and identifier fields **fill-only**: a field the record already holds
//! non-empty is never overwritten. Volatile fields (`citation_count`) and
//! additive ones (`pdf_urls`, a union) still update freely.
//!
//! ## Authors land where imbib reads them
//!
//! imbib's readers consume `authors_json` (structured) with an
//! `author_text` fallback — never a bare `authors` array. Resolved
//! authors are written to those two keys (fill-only, like every other
//! descriptive field).

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use imbib_core::enrichment::merge::{merge_metadata, PaperMetadata as MergeMetadata};
use imbib_core::enrichment::priority::{EnrichmentSourceId, SourcePriority};
use impel_core::{AgentRunRecord, ExecutionOutcome, TaskError, TaskExecutor, TaskStoreApi};
use impress_core::item::{ActorKind, Item, ItemId, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::reference::EdgeType;
use impress_sources::types::PaperMetadata as SourceMetadata;
use impress_sources::{SourceError, SourcePlugin};
use sha2::{Digest, Sha256};

use crate::KIND_METADATA_RESOLVE;

/// A configured source: the plugin plus its (optional) credentials.
pub struct ConfiguredSource {
    pub plugin: Arc<dyn SourcePlugin>,
    pub credentials: Option<String>,
}

pub struct MetadataResolveExecutor {
    sources: Vec<ConfiguredSource>,
    priority: SourcePriority,
    actor: String,
}

impl MetadataResolveExecutor {
    pub fn new(sources: Vec<ConfiguredSource>, priority: SourcePriority) -> Self {
        Self {
            sources,
            priority,
            actor: "impel/metadata-resolve".into(),
        }
    }

    /// The publication item this task operates on.
    fn target_of(task: &Item, store: &dyn TaskStoreApi) -> Result<Item, TaskError> {
        let target = task
            .references
            .iter()
            .find(|r| r.edge_type == EdgeType::OperatesOn)
            .map(|r| r.target)
            .ok_or_else(|| TaskError::Permanent("task has no OperatesOn target".into()))?;
        store
            .get_item(target)?
            .ok_or_else(|| TaskError::Permanent(format!("target item {target} missing")))
    }

    /// Best fetch identifier from the publication payload.
    fn identifier_of(publication: &Item) -> Option<String> {
        for field in ["doi", "arxiv_id", "bibcode"] {
            if let Some(Value::String(s)) = publication.payload.get(field) {
                if !s.is_empty() {
                    return Some(s.clone());
                }
            }
        }
        None
    }

    fn base_metadata(publication: &Item) -> MergeMetadata {
        let get = |f: &str| match publication.payload.get(f) {
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            _ => None,
        };
        MergeMetadata {
            source: None,
            title: get("title"),
            year: match publication.payload.get("year") {
                Some(Value::Int(y)) => i32::try_from(*y).ok(),
                _ => None,
            },
            authors: match publication.payload.get("authors") {
                Some(Value::Array(a)) => a
                    .iter()
                    .filter_map(|v| match v {
                        Value::String(s) => Some(s.clone()),
                        _ => None,
                    })
                    .collect(),
                _ => vec![],
            },
            abstract_text: get("abstract_text"),
            venue: get("venue"),
            doi: get("doi"),
            arxiv_id: get("arxiv_id"),
            bibcode: get("bibcode"),
            pmid: get("pmid"),
            citation_count: match publication.payload.get("citation_count") {
                Some(Value::Int(c)) => Some(*c),
                _ => None,
            },
            reference_count: None,
            pdf_urls: vec![],
            extras: BTreeMap::new(),
        }
    }

    fn convert(source_id: &str, m: SourceMetadata) -> MergeMetadata {
        MergeMetadata {
            source: Some(EnrichmentSourceId(source_id.to_string())),
            title: (!m.title.is_empty()).then(|| m.title.clone()),
            year: m.year,
            authors: m.authors.iter().map(|a| a.display_name()).collect(),
            abstract_text: m.abstract_text,
            venue: m.venue,
            doi: m.doi,
            arxiv_id: m.arxiv_id,
            bibcode: None,
            pmid: None,
            citation_count: None,
            reference_count: None,
            pdf_urls: m.pdf_url.into_iter().collect(),
            extras: BTreeMap::new(),
        }
    }

    /// `changed_fields` name → payload write.
    fn payload_value(merged: &MergeMetadata, field: &str) -> Option<Value> {
        let s = |o: &Option<String>| o.clone().map(Value::String);
        match field {
            "title" => s(&merged.title),
            "year" => merged.year.map(|y| Value::Int(y as i64)),
            // "authors" is handled by persist_changes directly (it writes
            // author_text/authors_json — the keys imbib actually reads).
            "authors" => None,
            "abstract_text" => s(&merged.abstract_text),
            "venue" => s(&merged.venue),
            "doi" => s(&merged.doi),
            "arxiv_id" => s(&merged.arxiv_id),
            "bibcode" => s(&merged.bibcode),
            "pmid" => s(&merged.pmid),
            "citation_count" => merged.citation_count.map(Value::Int),
            "pdf_urls" => Some(Value::Array(
                merged.pdf_urls.iter().cloned().map(Value::String).collect(),
            )),
            _ => None,
        }
    }

    /// Fields persisted fill-only: never overwrite a non-empty stored
    /// value. Everything descriptive or identifying — a user correction to
    /// any of these must survive every later resolve.
    const FILL_ONLY_FIELDS: &'static [&'static str] = &[
        "title",
        "year",
        "authors",
        "abstract_text",
        "venue",
        "doi",
        "arxiv_id",
        "bibcode",
        "pmid",
    ];

    /// Does the stored record already carry a real value for `field`?
    fn field_present(publication: &Item, field: &str) -> bool {
        let non_empty_str = |key: &str| {
            matches!(publication.payload.get(key),
                     Some(Value::String(s)) if !s.is_empty())
        };
        match field {
            "year" => matches!(publication.payload.get("year"), Some(Value::Int(_))),
            "authors" => {
                // Any of the three author representations counts.
                non_empty_str("author_text")
                    || non_empty_str("authors_json")
                    || matches!(publication.payload.get("authors"),
                                Some(Value::Array(a)) if !a.is_empty())
            }
            _ => non_empty_str(field),
        }
    }

    fn write_field(
        &self,
        publication: ItemId,
        field: &str,
        value: Value,
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError> {
        store.apply(OperationSpec {
            target_id: publication,
            op_type: OperationType::SetPayload(field.into(), value),
            intent: OperationIntent::Routine,
            reason: Some("enrichment: metadata-resolve".into()),
            batch_id: None,
            author: self.actor.clone(),
            author_kind: ActorKind::Agent,
            // Corrected fields are part of the research record.
            retention: RetentionTier::Durable,
        })?;
        Ok(())
    }

    fn persist_changes(
        &self,
        original: &Item,
        merged: &MergeMetadata,
        changed: &[&'static str],
        structured_authors: Option<&[impress_sources::types::Author]>,
        store: &dyn TaskStoreApi,
    ) -> Result<usize, TaskError> {
        let mut written = 0;
        for field in changed {
            if Self::FILL_ONLY_FIELDS.contains(field) && Self::field_present(original, field) {
                continue; // the record's own value wins
            }
            if *field == "authors" {
                // Write the representations imbib reads; the bare
                // `authors` key had no reader anywhere in the suite.
                if merged.authors.is_empty() {
                    continue;
                }
                let (author_text, authors_json) =
                    Self::author_payloads(&merged.authors, structured_authors);
                self.write_field(
                    original.id,
                    "author_text",
                    Value::String(author_text),
                    store,
                )?;
                if let Some(json) = authors_json {
                    self.write_field(original.id, "authors_json", Value::String(json), store)?;
                }
                written += 1;
                continue;
            }
            let Some(value) = Self::payload_value(merged, field) else {
                continue;
            };
            self.write_field(original.id, field, value, store)?;
            written += 1;
        }
        Ok(written)
    }

    /// Build imbib's two author representations. `author_text` follows the
    /// suite convention `Family, Given; Family, Given`; `authors_json` is
    /// the structured array imbib's readers parse, built from the winning
    /// source's structured authors when available.
    fn author_payloads(
        display_names: &[String],
        structured: Option<&[impress_sources::types::Author]>,
    ) -> (String, Option<String>) {
        if let Some(authors) = structured {
            if !authors.is_empty() {
                let text = authors
                    .iter()
                    .map(|a| match &a.given_name {
                        Some(given) if !given.is_empty() => {
                            format!("{}, {}", a.family_name, given)
                        }
                        _ => a.family_name.clone(),
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                let json = serde_json::json!(authors
                    .iter()
                    .map(|a| {
                        serde_json::json!({
                            "id": uuid::Uuid::new_v4().to_string(),
                            "given_name": a.given_name,
                            "family_name": a.family_name,
                            "suffix": null,
                            "orcid": a.orcid,
                            "affiliation": null,
                        })
                    })
                    .collect::<Vec<_>>());
                return (text, Some(json.to_string()));
            }
        }
        (display_names.join("; "), None)
    }
}

#[async_trait]
impl TaskExecutor for MetadataResolveExecutor {
    fn task_kind(&self) -> &str {
        KIND_METADATA_RESOLVE
    }

    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        let started = Instant::now();
        let publication = Self::target_of(task, store)?;
        let Some(identifier) = Self::identifier_of(&publication) else {
            // No identifier is a data condition, not an infrastructure
            // failure — nothing to resolve against; complete as a no-op.
            return Ok(ExecutionOutcome::Complete);
        };

        let mut merged = Self::base_metadata(&publication);
        let mut all_changed: Vec<&'static str> = Vec::new();
        let mut fetched_from: Vec<&str> = Vec::new();
        let mut last_err: Option<SourceError> = None;
        // Structured authors from the highest-priority source that returned
        // any — the basis for `authors_json` when the record has none.
        let mut best_authors: Option<(usize, Vec<impress_sources::types::Author>)> = None;

        for source in &self.sources {
            match source
                .plugin
                .fetch_by_id(&identifier, source.credentials.as_deref())
                .await
            {
                Ok(m) => {
                    fetched_from.push(source.plugin.id());
                    if !m.authors.is_empty() {
                        let rank = self
                            .priority
                            .rank(&EnrichmentSourceId(source.plugin.id().to_string()));
                        if best_authors.as_ref().is_none_or(|(r, _)| rank < *r) {
                            best_authors = Some((rank, m.authors.clone()));
                        }
                    }
                    let incoming = Self::convert(source.plugin.id(), m);
                    let outcome = merge_metadata(merged, incoming, &self.priority);
                    merged = outcome.merged;
                    for f in outcome.changed_fields {
                        if !all_changed.contains(&f) {
                            all_changed.push(f);
                        }
                    }
                }
                Err(e) => last_err = Some(e),
            }
        }

        if fetched_from.is_empty() {
            // Every source failed. Network-ish failures are retryable.
            let msg = last_err
                .map(|e| e.to_string())
                .unwrap_or_else(|| "no sources configured".into());
            return Err(TaskError::Retryable(format!(
                "metadata-resolve: all sources failed: {msg}"
            )));
        }

        // An arXiv-overlay DOI embeds the arXiv id (The Open Journal of
        // Astrophysics mints `10.21105/astro.2106.03528`), but no source
        // reports it as a first-class field, so a record can end up with a
        // DOI and no arXiv id even though the id is right there. Derive it:
        // it is what makes the paper's PDF fetchable from arXiv when the
        // overlay's own hosted PDF endpoint is not usable.
        if merged.arxiv_id.is_none() {
            if let Some(id) = merged
                .doi
                .as_deref()
                .and_then(im_identifiers::fields::arxiv_id_from_doi)
            {
                merged.arxiv_id = Some(id);
                if !all_changed.contains(&"arxiv_id") {
                    all_changed.push("arxiv_id");
                }
            }
        }

        let written = self.persist_changes(
            &publication,
            &merged,
            &all_changed,
            best_authors.as_ref().map(|(_, a)| a.as_slice()),
            store,
        )?;

        // Reproducibility record (ADR-0005 §5): the "prompt" of an API
        // pipeline is the identifier + source set.
        let mut hasher = Sha256::new();
        hasher.update(identifier.as_bytes());
        for s in &fetched_from {
            hasher.update(s.as_bytes());
        }
        store.record_agent_run(
            task.id,
            AgentRunRecord {
                agent_id: self.actor.clone(),
                model: "api-pipeline".into(),
                prompt_hash: format!("{:x}", hasher.finalize()),
                result_summary: Some(format!(
                    "resolved via [{}]; {} field(s) updated ({} preserved)",
                    fetched_from.join(","),
                    written,
                    all_changed.len().saturating_sub(written),
                )),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
            },
        )?;

        Ok(ExecutionOutcome::Complete)
    }

    // With the scheduler's exponential backoff (45s·3^n) this rides out
    // ~30 minutes of network outage before escalating.
    fn max_retries(&self) -> u32 {
        5
    }
}
