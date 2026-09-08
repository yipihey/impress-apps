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

use crate::classify::{Classification, Classifier};
use crate::KIND_KEYWORD_TAG;

pub struct KeywordTagExecutor {
    classifier: Arc<dyn Classifier>,
    /// Consulted only when [`Self::classifier`] returns `Err` — it could not
    /// reach a verdict, as opposed to reaching the verdict "no tags".
    ///
    /// `None` (the default) makes such a failure a retryable task error, which
    /// is the right answer when there is nothing else to ask. With a fallback
    /// wired in, the run records the FALLBACK's `model`/`executor_kind` and
    /// says so in its summary: a degraded result must never be filed under the
    /// name of the classifier that did not answer.
    fallback: Option<Arc<dyn Classifier>>,
    /// Proposals below this minimum confidence trigger a review.
    confidence_threshold: f64,
    actor: String,
}

impl KeywordTagExecutor {
    pub fn new(classifier: Arc<dyn Classifier>, confidence_threshold: f64) -> Self {
        Self {
            classifier,
            fallback: None,
            confidence_threshold,
            actor: "impel/keyword-tag".into(),
        }
    }

    /// Wire a second classifier to consult when the first cannot answer.
    /// Mirrors `impel_throughline::LlmDrafter`'s per-call degradation to
    /// `TemplateDrafter`, except that here the degradation is recorded rather
    /// than invisible.
    pub fn with_fallback(mut self, fallback: Option<Arc<dyn Classifier>>) -> Self {
        self.fallback = fallback;
        self
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

    /// Ask the classifier, degrading to the fallback if it cannot answer.
    ///
    /// Returns the proposals alongside the classifier that actually produced
    /// them, so the run record names the right one.
    async fn propose(
        &self,
        title: &str,
        abstract_text: &str,
    ) -> Result<(Vec<Classification>, &dyn Classifier, Option<String>), TaskError> {
        let primary = self.classifier.classify(title, abstract_text).await;
        match (primary, self.fallback.as_ref()) {
            (Ok(proposals), _) => Ok((proposals, self.classifier.as_ref(), None)),
            (Err(reason), Some(fallback)) => {
                let proposals = fallback
                    .classify(title, abstract_text)
                    .await
                    // Both silent is nothing left to try, and the kernel's
                    // backoff is a better answer than an empty tag set.
                    .map_err(|second| {
                        TaskError::Retryable(format!(
                            "{} unavailable ({reason}); fallback {} also failed ({second})",
                            self.classifier.model_id(),
                            fallback.model_id()
                        ))
                    })?;
                Ok((
                    proposals,
                    fallback.as_ref(),
                    Some(format!(
                        "{} unavailable: {reason}",
                        self.classifier.model_id()
                    )),
                ))
            }
            // No fallback: retry rather than record a verdict nobody reached.
            // ADR-0005 §9's ladder then escalates if the outage outlasts it.
            (Err(reason), None) => Err(TaskError::Retryable(reason)),
        }
    }

    /// Canonicalize proposed tag paths and collapse the collisions that
    /// canonicalization creates.
    ///
    /// A model asked for `ai/topic/*` answers `ai/topic/Dark Energy` about as
    /// often as `ai/topic/dark-energy`, and the store treats those as two
    /// unrelated tags — so an LLM-classified library grows a shadow tag tree
    /// that no filter, count or sidebar node ever joins back up. Every tag the
    /// suite writes goes through `normalize_tag_path`; this is the one place
    /// proposals enter, so it is the one place that has to.
    ///
    /// Two proposals can normalize to the same path; the higher confidence
    /// wins, since the policy below is a threshold test.
    fn normalize(proposals: Vec<Classification>) -> Vec<Classification> {
        let mut out: Vec<Classification> = Vec::with_capacity(proposals.len());
        for mut proposal in proposals {
            proposal.tag = impress_tags::normalize_tag_path(&proposal.tag);
            // Normalization can empty a path entirely ("///", "  ").
            if proposal.tag.is_empty() {
                continue;
            }
            match out.iter_mut().find(|kept| kept.tag == proposal.tag) {
                Some(kept) => kept.confidence = kept.confidence.max(proposal.confidence),
                None => out.push(proposal),
            }
        }
        out
    }

    /// One sentence naming what this run actually decided, for the run
    /// record's `result_summary` (the string every task surface shows).
    fn outcome_summary(applied: &[String], band: &[(String, f64)], dropped: usize) -> String {
        let mut parts: Vec<String> = Vec::new();
        if !applied.is_empty() {
            parts.push(format!("applied {}", applied.join(", ")));
        }
        if !band.is_empty() {
            let listed = band
                .iter()
                .map(|(tag, confidence)| format!("{tag} ({confidence:.2})"))
                .collect::<Vec<_>>()
                .join(", ");
            parts.push(format!("review opened for {listed}"));
        }
        if dropped > 0 {
            parts.push(format!("{dropped} below the review floor"));
        }
        if parts.is_empty() {
            return "no tags proposed".into();
        }
        parts.join("; ")
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

        let (proposals, classifier, degraded) = self.propose(&title, &abstract_text).await?;
        let proposals = Self::normalize(proposals);

        // ── Per-proposal policy: apply / review-band / drop ────────────
        let review_floor = self.confidence_threshold * 0.7;
        let mut applied: Vec<String> = Vec::new();
        let mut band: Vec<(String, f64)> = Vec::new();
        let mut dropped = 0_usize;
        for p in &proposals {
            if p.confidence >= self.confidence_threshold {
                applied.push(p.tag.clone());
            } else if p.confidence >= review_floor {
                band.push((p.tag.clone(), p.confidence));
            } else {
                // Weak evidence is not worth a human decision at library
                // scale — but it IS worth saying so in the run record.
                dropped += 1;
            }
        }

        // Reproducibility record regardless of branch. The summary names
        // the OUTCOME — which tags, at what confidence — because "3 tag
        // proposal(s)" told a reader the count of a decision they could
        // not see and left the actual result discoverable only by diffing
        // the paper's tags.
        let mut hasher = Sha256::new();
        hasher.update(title.as_bytes());
        hasher.update(abstract_text.as_bytes());
        let mut summary = Self::outcome_summary(&applied, &band, dropped);
        if let Some(note) = degraded {
            summary.push_str(&format!(" [{note}]"));
        }
        store.record_agent_run(
            task.id,
            AgentRunRecord {
                agent_id: self.actor.clone(),
                model: classifier.model_id().into(),
                prompt_hash: format!("{:x}", hasher.finalize()),
                result_summary: Some(summary),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
                executor_kind: Some(classifier.executor_kind().into()),
            },
        )?;

        if proposals.is_empty() {
            return Ok(ExecutionOutcome::Complete);
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
