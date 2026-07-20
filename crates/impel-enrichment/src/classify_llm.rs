//! LLM-backed [`Classifier`] via `impress-llm` (ADR-0015 D6 follow-up).
//!
//! Prompt-JSON + parse: `impress-llm` has no structured-output mode, so
//! the prompt demands a bare JSON array and parsing salvages the first
//! `[...]` block. Configuration comes from the environment (the daemon's
//! convention — no keychain in headless contexts):
//!
//! - `IMPEL_LLM_PROVIDER` — e.g. `groq`, `mistral`, `deepseek`
//! - `IMPEL_LLM_MODEL`    — provider-specific model id
//! - `IMPEL_LLM_API_KEY`  — the key, passed per-request
//!
//! Determinism note: temperature is pinned to 0.0 so `prompt_hash`
//! reproducibility (ADR-0005 §5) is as meaningful as the provider allows.

use async_trait::async_trait;
use impress_llm::{complete_sync, LLMMessage, LLMRequest, LLMRole};

use crate::classify::{Classification, Classifier};

pub struct LlmClassifier {
    provider: String,
    model: String,
    api_key: String,
    model_id: String,
}

impl LlmClassifier {
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
    /// (callers fall back to the heuristic classifier).
    pub fn from_env() -> Option<Self> {
        let provider = std::env::var("IMPEL_LLM_PROVIDER").ok()?;
        let model = std::env::var("IMPEL_LLM_MODEL").ok()?;
        let api_key = std::env::var("IMPEL_LLM_API_KEY").ok()?;
        Some(Self::new(provider, model, api_key))
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
        let request = LLMRequest {
            provider: self.provider.clone(),
            model: self.model.clone(),
            messages: vec![LLMMessage {
                role: LLMRole::User,
                content: Self::prompt(title, abstract_text),
            }],
            max_tokens: Some(512),
            temperature: Some(0.0),
            top_p: None,
            api_key: self.api_key.clone(),
        };
        // impress-llm is blocking by design; hop off the async worker.
        let reply = tokio::task::spawn_blocking(move || complete_sync(&request))
            .await
            .ok()
            .and_then(|r| r.ok());
        match reply {
            Some(response) => Self::parse_reply(&response.content),
            None => vec![], // provider failure → no proposals (executor completes)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_clean_json() {
        let out = LlmClassifier::parse_reply(
            r#"[{"tag":"ai/topic/cosmology","confidence":0.9},{"tag":"ai/methods/ml","confidence":0.4}]"#,
        );
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].tag, "ai/topic/cosmology");
    }

    #[test]
    fn salvages_json_from_prose() {
        let out = LlmClassifier::parse_reply(
            "Sure! Here are the tags:\n[{\"tag\":\"ai/methods/simulation\",\"confidence\":0.7}]\nHope that helps.",
        );
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn drops_out_of_namespace_and_clamps() {
        let out = LlmClassifier::parse_reply(
            r#"[{"tag":"random/thing","confidence":0.9},{"tag":"ai/topic/galaxies","confidence":1.7}]"#,
        );
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].confidence, 1.0);
    }

    #[test]
    fn garbage_is_empty() {
        assert!(LlmClassifier::parse_reply("no json here").is_empty());
        assert!(LlmClassifier::parse_reply("[not valid").is_empty());
    }
}
