//! `metadata-resolve` — ADR-0005 §9's first pipeline stage.
//!
//! Fetches metadata for the publication the task `OperatesOn` from each
//! configured source, merges via `imbib-core`'s priority-aware
//! `merge_metadata`, and persists **only** `changed_fields` as attributed
//! `SetPayload` operations (Durable — corrected fields are part of the
//! research record, ADR-0005 §9 retention table).

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
            "authors" => Some(Value::Array(
                merged.authors.iter().cloned().map(Value::String).collect(),
            )),
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

    fn persist_changes(
        &self,
        publication: ItemId,
        merged: &MergeMetadata,
        changed: &[&'static str],
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError> {
        for field in changed {
            let Some(value) = Self::payload_value(merged, field) else {
                continue;
            };
            store.apply(OperationSpec {
                target_id: publication,
                op_type: OperationType::SetPayload((*field).into(), value),
                intent: OperationIntent::Routine,
                reason: Some("enrichment: metadata-resolve".into()),
                batch_id: None,
                author: self.actor.clone(),
                author_kind: ActorKind::Agent,
                // Corrected fields are part of the research record.
                retention: RetentionTier::Durable,
            })?;
        }
        Ok(())
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

        for source in &self.sources {
            match source
                .plugin
                .fetch_by_id(&identifier, source.credentials.as_deref())
                .await
            {
                Ok(m) => {
                    fetched_from.push(source.plugin.id());
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

        self.persist_changes(publication.id, &merged, &all_changed, store)?;

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
                    "resolved via [{}]; {} field(s) updated",
                    fetched_from.join(","),
                    all_changed.len()
                )),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
            },
        )?;

        Ok(ExecutionOutcome::Complete)
    }

    fn max_retries(&self) -> u32 {
        3
    }
}
