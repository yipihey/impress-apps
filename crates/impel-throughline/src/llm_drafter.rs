//! LLM-backed [`ProposalDrafter`] over the Rust AI registry (ADR-0029).
//!
//! The target comes from `AiRegistry::daemon_target("agent.throughline")`:
//! `IMPEL_LLM_PROVIDER` + `IMPEL_LLM_MODEL` (kept for one release) beat the
//! task-category assignment; with neither, callers keep [`TemplateDrafter`].
//!
//! Temperature is pinned to 0.0 so the ADR-0005 §5 `prompt_hash`
//! reproducibility is as meaningful as the provider allows. A provider
//! failure or malformed reply falls back to [`TemplateDrafter`]'s output —
//! the review checkpoint still opens with full drift context.
//!
//! The prompt contract (`draft_prompt::system_contract`) carries the
//! ADR-0016 D6 authority split verbatim; the review gate remains the
//! actual enforcement point.

use std::sync::Arc;

use async_trait::async_trait;
use impress_ai::blocking::complete_text_sync;
use impress_ai::{AiRegistry, ResolveTarget};
use imprint_service::throughline::ThroughlineParagraph;
use imprint_service::SectionRecord;

use crate::draft_prompt::{build_prompt, parse_reply, system_contract};
use crate::{DraftResult, ProposalDrafter, SyncDirection, TemplateDrafter};

/// The task category whose primary model runs this tier.
pub const CATEGORY: &str = "agent.throughline";

pub struct LlmDrafter {
    registry: Arc<AiRegistry>,
    target: ResolveTarget,
    model_id: String,
}

impl LlmDrafter {
    pub fn new(registry: Arc<AiRegistry>, target: ResolveTarget) -> Self {
        let model_id = registry.describe_target(&target);
        Self {
            registry,
            target,
            model_id,
        }
    }

    /// Build from the registry's daemon target for [`CATEGORY`]; `None`
    /// when unconfigured (callers fall back to [`TemplateDrafter`]).
    pub fn from_registry(registry: Arc<AiRegistry>) -> Option<Self> {
        let target = registry.daemon_target(CATEGORY)?;
        Some(Self::new(registry, target))
    }
}

#[async_trait]
impl ProposalDrafter for LlmDrafter {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn executor_kind(&self) -> &str {
        impel_core::EXECUTOR_MODEL
    }

    async fn draft(
        &self,
        direction: &SyncDirection,
        paragraph: &ThroughlineParagraph,
        sections: &[SectionRecord],
    ) -> DraftResult {
        let registry = Arc::clone(&self.registry);
        let target = self.target.clone();
        let prompt = build_prompt(direction, paragraph, sections);
        let system = system_contract().to_string();
        // The registry call blocks on its own runtime; hop off the async worker.
        let reply = tokio::task::spawn_blocking(move || {
            complete_text_sync(&registry, &target, Some(&system), &prompt, 2048, Some(0.0))
        })
        .await
        .ok()
        .and_then(|r| r.ok());
        match reply.and_then(|(_, text)| parse_reply(&text)) {
            Some(draft) => draft,
            None => TemplateDrafter.draft(direction, paragraph, sections).await,
        }
    }
}
