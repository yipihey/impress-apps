//! `keyword-tag` — ADR-0005 §9's classification stage, and the live
//! demonstration of the `AwaitHumanResponse` checkpoint (ADR-0015 D4/D6).
//!
//! Policy is PER PROPOSAL, with a capacity model (the earlier all-or-
//! nothing gate held every confident tag hostage to the weakest proposal
//! and opened a human review for essentially every paper — 1,018 of them
//! were pending, unreviewed, when this was rewritten):
//!
//! - `confidence ≥ threshold` → applied immediately as `AddTag`
//!   operations (Durable — tags are research record, `ai/`-namespaced and
//!   individually revertible, which is the undo story).
//! - `review_floor ≤ confidence < threshold` (the borderline band, floor
//!   = 0.7·threshold) → a `review-request` listing ONLY the band, with
//!   per-tag confidences; the task suspends.
//! - below the floor → dropped silently, like imbib's own auto-tagger.
//!
//! On resume, an `"approved"` resolution applies the tags recorded in the
//! review; anything else (`rejected`, `expired`) completes without them.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use impel_core::{
    AgentRunRecord, ExecutionOutcome, ReviewRequest, TaskError, TaskExecutor, TaskStoreApi,
};
use impress_core::item::{ActorKind, Item, ItemId, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::reference::EdgeType;
use sha2::{Digest, Sha256};

use crate::classify::Classifier;
use crate::KIND_KEYWORD_TAG;

pub struct KeywordTagExecutor {
    classifier: Arc<dyn Classifier>,
    /// Proposals below this minimum confidence trigger a review.
    confidence_threshold: f64,
    actor: String,
}

impl KeywordTagExecutor {
    pub fn new(classifier: Arc<dyn Classifier>, confidence_threshold: f64) -> Self {
        Self {
            classifier,
            confidence_threshold,
            actor: "impel/keyword-tag".into(),
        }
    }

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

    fn apply_tags(
        &self,
        publication: ItemId,
        tags: &[String],
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError> {
        for tag in tags {
            store.apply(OperationSpec {
                target_id: publication,
                op_type: OperationType::AddTag(tag.clone()),
                intent: OperationIntent::Routine,
                reason: Some("enrichment: keyword-tag".into()),
                batch_id: None,
                author: self.actor.clone(),
                author_kind: ActorKind::Agent,
                retention: RetentionTier::Durable,
            })?;
        }
        Ok(())
    }

    /// Tags recorded in a review item's `context_proposed_tags`.
    fn proposed_tags(review: &Item) -> Vec<String> {
        match review.payload.get("context_proposed_tags") {
            Some(Value::Array(a)) => a
                .iter()
                .filter_map(|v| match v {
                    Value::String(s) => Some(s.clone()),
                    _ => None,
                })
                .collect(),
            _ => vec![],
        }
    }
}

#[async_trait]
impl TaskExecutor for KeywordTagExecutor {
    fn task_kind(&self) -> &str {
        KIND_KEYWORD_TAG
    }

    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        let started = Instant::now();
        let publication = Self::target_of(task, store)?;

        // ── Resume path: a resolved review decides for us ──────────────
        let (unresolved, resolved) = store.reviews_for(task.id)?;
        if !unresolved.is_empty() {
            // Scheduler shouldn't call us here, but be safe: still waiting.
            return Ok(ExecutionOutcome::Suspended);
        }
        if let Some(review) = resolved.first() {
            let approved = matches!(review.payload.get("resolution"),
                                    Some(Value::String(r)) if r == "approved");
            if approved {
                let tags = Self::proposed_tags(review);
                self.apply_tags(publication.id, &tags, store)?;
            }
            return Ok(ExecutionOutcome::Complete);
        }

        // ── First run: classify ────────────────────────────────────────
        let title = match publication.payload.get("title") {
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        let abstract_text = match publication.payload.get("abstract_text") {
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        if title.is_empty() && abstract_text.is_empty() {
            return Ok(ExecutionOutcome::Complete); // nothing to classify
        }

        let proposals = self.classifier.classify(&title, &abstract_text).await;

        // Reproducibility record regardless of branch.
        let mut hasher = Sha256::new();
        hasher.update(title.as_bytes());
        hasher.update(abstract_text.as_bytes());
        store.record_agent_run(
            task.id,
            AgentRunRecord {
                agent_id: self.actor.clone(),
                model: self.classifier.model_id().into(),
                prompt_hash: format!("{:x}", hasher.finalize()),
                result_summary: Some(format!("{} tag proposal(s)", proposals.len())),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
            },
        )?;

        if proposals.is_empty() {
            return Ok(ExecutionOutcome::Complete);
        }

        // ── Per-proposal policy: apply / review-band / drop ────────────
        let review_floor = self.confidence_threshold * 0.7;
        let mut applied: Vec<String> = Vec::new();
        let mut band: Vec<(String, f64)> = Vec::new();
        for p in &proposals {
            if p.confidence >= self.confidence_threshold {
                applied.push(p.tag.clone());
            } else if p.confidence >= review_floor {
                band.push((p.tag.clone(), p.confidence));
            }
            // Below the floor: dropped — weak evidence is not worth a
            // human decision at library scale.
        }
        if !applied.is_empty() {
            self.apply_tags(publication.id, &applied, store)?;
        }
        if band.is_empty() {
            return Ok(ExecutionOutcome::Complete);
        }

        // ── Borderline band → the human checkpoint (ADR-0005 §8) ───────
        let mut context = BTreeMap::new();
        context.insert(
            "proposed_tags".to_string(),
            Value::Array(band.iter().map(|(t, _)| Value::String(t.clone())).collect()),
        );
        context.insert(
            "confidences".to_string(),
            Value::Array(band.iter().map(|(_, c)| Value::Float(*c)).collect()),
        );
        if !applied.is_empty() {
            context.insert(
                "applied_tags".to_string(),
                Value::Array(applied.iter().cloned().map(Value::String).collect()),
            );
        }
        context.insert(
            "min_confidence".to_string(),
            Value::Float(band.iter().map(|(_, c)| *c).fold(f64::INFINITY, f64::min)),
        );
        store.open_review(
            task.id,
            ReviewRequest {
                question: format!(
                    "Apply {} borderline tag(s) to \"{}\"? Confidence {:.2}–{:.2}.",
                    band.len(),
                    if title.is_empty() {
                        "(untitled)"
                    } else {
                        &title
                    },
                    review_floor,
                    self.confidence_threshold
                ),
                context: Some(context),
            },
            &self.actor,
        )?;
        Ok(ExecutionOutcome::Suspended)
    }

    fn max_retries(&self) -> u32 {
        2
    }
}
