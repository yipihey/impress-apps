use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::Tool => "tool",
        }
    }
}

/// Content already resolved for an inference endpoint.
///
/// Durable messages never store data URLs/base64. They point to
/// `content-blob@1.0.0` items; `AiStore::prepare_request` resolves those bytes
/// immediately before a model call.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ModelContentPart {
    Text { text: String },
    ImageUrl { image_url: ImageUrl },
    InputAudio { input_audio: InputAudio },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImageUrl {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InputAudio {
    pub data: String,
    pub format: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelMessage {
    pub role: Role,
    pub content: Vec<ModelContentPart>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ModelToolCall>,
}

impl ModelMessage {
    pub fn text(role: Role, text: impl Into<String>) -> Self {
        Self {
            role,
            content: vec![ModelContentPart::Text { text: text.into() }],
            name: None,
            tool_call_id: None,
            tool_calls: vec![],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ToolPolicy {
    /// Stable capability ids such as `scix`, `impress-mcp`, and `web`.
    pub enabled: Vec<String>,
}

impl ToolPolicy {
    pub fn normalized(mut self) -> Self {
        self.enabled.retain(|tool| !tool.trim().is_empty());
        self.enabled.sort();
        self.enabled.dedup();
        self
    }

    pub fn allows(&self, capability: &str) -> bool {
        self.enabled.iter().any(|value| value == capability)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ModelMessage>,
    #[serde(default = "default_temperature")]
    pub temperature: f32,
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u32,
    #[serde(default)]
    pub thinking: bool,
    #[serde(default)]
    pub tools: Vec<ToolDefinition>,
    #[serde(default)]
    pub tool_policy: ToolPolicy,
}

impl ChatRequest {
    pub fn validate(&self) -> crate::Result<()> {
        if self.model.trim().is_empty() || self.model.len() > 300 {
            return Err(crate::Error::Invalid("choose a valid model".into()));
        }
        if self.messages.is_empty() || self.messages.len() > 200 {
            return Err(crate::Error::Invalid(
                "provide between 1 and 200 messages".into(),
            ));
        }
        if !(0.0..=2.0).contains(&self.temperature) {
            return Err(crate::Error::Invalid(
                "temperature must be between 0 and 2".into(),
            ));
        }
        if !(1..=131_072).contains(&self.max_tokens) {
            return Err(crate::Error::Invalid(
                "max tokens must be between 1 and 131072".into(),
            ));
        }
        if self.tools.len() > 128 {
            return Err(crate::Error::Invalid(
                "a request may expose at most 128 tools".into(),
            ));
        }
        Ok(())
    }
}

fn default_temperature() -> f32 {
    0.2
}

fn default_max_tokens() -> u32 {
    2048
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelSummary {
    pub id: String,
    #[serde(default)]
    pub loaded: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_context_window: Option<u64>,
    #[serde(default)]
    pub modalities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamEvent {
    Token {
        text: String,
    },
    Reasoning {
        text: String,
    },
    ToolCallDelta {
        index: u32,
        id: Option<String>,
        name: Option<String>,
        arguments: String,
    },
    Usage {
        usage: serde_json::Value,
    },
    Error {
        error: String,
    },
    Done {
        finish_reason: Option<String>,
    },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct CompletionRecord {
    pub content: String,
    pub reasoning: String,
    pub usage: Option<serde_json::Value>,
    pub finish_reason: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolInvocationRecord {
    pub tool: String,
    pub provider: String,
    pub arguments: BTreeMap<String, impress_core::Value>,
    pub result: Option<BTreeMap<String, impress_core::Value>>,
    pub result_summary: Option<String>,
    pub error: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredAttachment {
    pub item_id: Uuid,
    pub mime_type: String,
    pub sha256: String,
    pub file_name: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_policy_is_stable_and_deduplicated() {
        let policy = ToolPolicy {
            enabled: vec!["scix".into(), "web".into(), "scix".into(), "".into()],
        }
        .normalized();
        assert_eq!(policy.enabled, ["scix", "web"]);
        assert!(policy.allows("scix"));
        assert!(!policy.allows("impress-mcp"));
    }

    #[test]
    fn multimodal_message_serializes_as_openai_content_parts() {
        let message = ModelMessage {
            role: Role::User,
            content: vec![
                ModelContentPart::Text {
                    text: "inspect".into(),
                },
                ModelContentPart::ImageUrl {
                    image_url: ImageUrl {
                        url: "data:image/png;base64,AAAA".into(),
                        detail: Some("high".into()),
                    },
                },
            ],
            name: None,
            tool_call_id: None,
            tool_calls: vec![],
        };
        let json = serde_json::to_value(message).unwrap();
        assert_eq!(json["content"][1]["type"], "image_url");
    }
}
