//! LLM-backed [`ProposalDrafter`] via `impress-llm` (feature `llm`).
//!
//! Configuration mirrors `impel-enrichment::LlmClassifier` — the daemon's
//! env convention, no keychain in headless contexts:
//!
//! - `IMPEL_LLM_PROVIDER` / `IMPEL_LLM_MODEL` / `IMPEL_LLM_API_KEY`
//!
//! Temperature is pinned to 0.0 so the ADR-0005 §5 `prompt_hash`
//! reproducibility is as meaningful as the provider allows. A provider
//! failure or malformed reply falls back to [`TemplateDrafter`]'s output —
//! the review checkpoint still opens with full drift context.
//!
//! The prompt contract (`draft_prompt::system_contract`) carries the
//! ADR-0016 D6 authority split verbatim; the review gate remains the
//! actual enforcement point.

use async_trait::async_trait;
use impress_llm::{complete_sync, LLMMessage, LLMRequest, LLMRole};
use imprint_service::throughline::ThroughlineParagraph;
use imprint_service::SectionRecord;

use crate::draft_prompt::{build_prompt, parse_reply, system_contract};
use crate::{DraftResult, ProposalDrafter, SyncDirection, TemplateDrafter};

pub struct LlmDrafter {
    provider: String,
    model: String,
    api_key: String,
    model_id: String,
}

impl LlmDrafter {
    pub fn new(provider: String, model: String, api_key: String) -> Self {
        let model_id = format!("{provider}/{model}");
        Self {
            provider,
            model,
            api_key,
            model_id,
        }
    }

    /// Build from `IMPEL_LLM_*` env vars; `None` when unconfigured
    /// (callers fall back to [`TemplateDrafter`]).
    pub fn from_env() -> Option<Self> {
        let provider = std::env::var("IMPEL_LLM_PROVIDER").ok()?;
        let model = std::env::var("IMPEL_LLM_MODEL").ok()?;
        let api_key = std::env::var("IMPEL_LLM_API_KEY").ok()?;
        Some(Self::new(provider, model, api_key))
    }
}

#[async_trait]
impl ProposalDrafter for LlmDrafter {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    async fn draft(
        &self,
        direction: &SyncDirection,
        paragraph: &ThroughlineParagraph,
        sections: &[SectionRecord],
    ) -> DraftResult {
        let request = LLMRequest {
            provider: self.provider.clone(),
            model: self.model.clone(),
            messages: vec![
                LLMMessage {
                    role: LLMRole::System,
                    content: system_contract().to_string(),
                },
                LLMMessage {
                    role: LLMRole::User,
                    content: build_prompt(direction, paragraph, sections),
                },
            ],
            max_tokens: Some(2048),
            temperature: Some(0.0),
            top_p: None,
            api_key: self.api_key.clone(),
        };
        // impress-llm is blocking by design; hop off the async worker.
        let reply = tokio::task::spawn_blocking(move || complete_sync(&request))
            .await
            .ok()
            .and_then(|r| r.ok());
        match reply.and_then(|r| parse_reply(&r.content)) {
            Some(draft) => draft,
            None => TemplateDrafter.draft(direction, paragraph, sections).await,
        }
    }
}
