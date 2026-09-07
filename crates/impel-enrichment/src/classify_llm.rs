//! LLM-backed [`Classifier`] over the Rust AI registry (ADR-0029).
//!
//! Prompt-JSON + parse: the prompt demands a bare JSON array and parsing
//! salvages the first `[...]` block. The target comes from the registry
//! (`AiRegistry::daemon_target`): `IMPEL_LLM_PROVIDER` + `IMPEL_LLM_MODEL`
//! (kept for one release) beat the `agent.classify` task-category
//! assignment; with neither, callers keep the heuristic tier. Background
//! tiers deliberately do not inherit the interactive suite selection, so a
//! cloud model picked for chat never creates daemon spend silently.
//!
//! Determinism note: temperature is pinned to 0.0 so `prompt_hash`
//! reproducibility (ADR-0005 §5) is as meaningful as the provider allows.

use std::sync::Arc;

use async_trait::async_trait;
use impress_ai::blocking::complete_text_sync;
use impress_ai::{AiRegistry, ResolveTarget};

use crate::classify::{Classification, Classifier};

/// The task category whose primary model runs this tier.
pub const CATEGORY: &str = "agent.classify";

pub struct LlmClassifier {
    registry: Arc<AiRegistry>,
    target: ResolveTarget,
    model_id: String,
}

impl LlmClassifier {
    pub fn new(registry: Arc<AiRegistry>, target: ResolveTarget) -> Self {
        let model_id = registry.describe_target(&target);
        Self {
            registry,
            target,
            model_id,
        }
    }

    /// Build from the registry's daemon target for [`CATEGORY`]; `None`
    /// when unconfigured (callers fall back to the heuristic classifier).
    pub fn from_registry(registry: Arc<AiRegistry>) -> Option<Self> {
        let target = registry.daemon_target(CATEGORY)?;
        Some(Self::new(registry, target))
    }

    fn prompt(title: &str, abstract_text: &str) -> String {
        format!(
            "You are a research-paper classifier for an astronomy-centric \
             bibliography. Given the paper below, propose up to 4 tags in the \
             namespaces ai/topic/* and ai/methods/* (lowercase, slash-separated, \
             e.g. ai/topic/cosmology, ai/methods/simulation), each with a \
             confidence in [0,1].\n\
             Respond with ONLY a JSON array, no prose, of the form:\n\
             [{{\"tag\": \"ai/topic/…\", \"confidence\": 0.8}}]\n\
             If no tag fits, respond with [].\n\n\
             Title: {title}\n\nAbstract: {abstract_text}"
        )
    }

    /// Parse the model's reply: strict parse first, then salvage the
    /// first `[...]` block. Invalid entries are dropped; confidences are
    /// clamped to [0,1]; tags outside the ai/ namespaces are discarded.
    pub(crate) fn parse_reply(reply: &str) -> Vec<Classification> {
        #[derive(serde::Deserialize)]
        struct Row {
            tag: String,
            confidence: f64,
        }
        let attempt = |s: &str| -> Option<Vec<Row>> { serde_json::from_str(s).ok() };
        let rows = attempt(reply.trim()).or_else(|| {
            let start = reply.find('[')?;
            let end = reply.rfind(']')?;
            if end <= start {
                return None;
            }
            attempt(&reply[start..=end])
        });
        rows.unwrap_or_default()
            .into_iter()
            .filter(|r| r.tag.starts_with("ai/topic/") || r.tag.starts_with("ai/methods/"))
            .map(|r| Classification {
                tag: r.tag,
                confidence: r.confidence.clamp(0.0, 1.0),
            })
            .collect()
    }
}

#[async_trait]
impl Classifier for LlmClassifier {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    async fn classify(&self, title: &str, abstract_text: &str) -> Vec<Classification> {
        let registry = Arc::clone(&self.registry);
        let target = self.target.clone();
        let prompt = Self::prompt(title, abstract_text);
        // The registry call blocks on its own runtime; hop off the async worker.
        let reply = tokio::task::spawn_blocking(move || {
            complete_text_sync(&registry, &target, None, &prompt, 512, Some(0.0))
        })
        .await
        .ok()
        .and_then(|r| r.ok());
        match reply {
            Some((_, text)) => Self::parse_reply(&text),
            None => vec![], // provider failure → no proposals (executor completes)
        }
    }
}
