//! `EnrichmentSpawnRule` — bibliography-entry items trigger the pipeline
//! DAG (ADR-0005 §9/§10, ADR-0015 D6).
//!
//! Current slice: `metadata-resolve ← keyword-tag`. The full §9 DAG adds
//! `abstract-extract` between them (PDF-text fallback) plus
//! `recommendation-score` and `digest-generate` — follow-up executors
//! that slot into this rule without structural change.

use async_trait::async_trait;
use impress_core::item::Item;

use impel_core::{SpawnError, SpawnRule, TaskSpec, TaskStoreApi};

use crate::{BIBLIOGRAPHY_ENTRY_SCHEMA, KIND_KEYWORD_TAG, KIND_METADATA_RESOLVE};

pub struct EnrichmentSpawnRule;

#[async_trait]
impl SpawnRule for EnrichmentSpawnRule {
    fn trigger_schema(&self) -> &str {
        BIBLIOGRAPHY_ENTRY_SCHEMA
    }

    async fn spawn(
        &self,
        trigger: &Item,
        _store: &dyn TaskStoreApi,
    ) -> Result<Vec<TaskSpec>, SpawnError> {
        Ok(vec![
            TaskSpec {
                kind: KIND_METADATA_RESOLVE.into(),
                description: Some("Resolve metadata from external sources".into()),
                depends_on: vec![],
                operates_on: Some(trigger.id),
                output_schema: None,
            },
            TaskSpec {
                kind: KIND_KEYWORD_TAG.into(),
                description: Some("Propose classification tags".into()),
                depends_on: vec![0],
                operates_on: Some(trigger.id),
                output_schema: None,
            },
        ])
    }
}
