//! UniFFI surface over the Rust AI provider registry (ADR-0029).
//!
//! Swift sees typed records — never raw JSON — and reaches every provider
//! through one object. Discovery, health and non-streaming completion are
//! synchronous calls driven on a runtime this crate owns; streaming is an
//! async pull handle so a Swift actor can await tokens without blocking a
//! thread and can cancel deterministically.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use futures_util::StreamExt;
use impress_ai::categories;
use impress_ai::credentials::InMemoryCredentials;
use impress_ai::preferences::{AiPreferences, CategoryAssignment, LegacyPreferences, ModelRef};
use impress_ai::provider::ProviderHealth;
use impress_ai::registry::{AiRegistry, ResolveTarget, ResolvedTarget};
use impress_ai::types::{
    ChatRequest, ImageUrl, ModelContentPart, ModelKind, ModelMessage, ModelSource, ModelSummary,
    ModelToolCall, ResponseFormat, Role, StreamEvent, ToolDefinition,
};
use impress_ai::{catalogue, omlx_control, Completion, Error as AiCoreError};

/// One runtime for every FFI-driven inference call in the process. Two
/// workers: one can stream while another discovers or checks health.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("impress-ai-ffi")
            .enable_all()
            .build()
            .expect("build the impress-ai FFI runtime")
    })
}

// ─── Errors ──────────────────────────────────────────────────────────────

/// One case per `impress_ai::Error` family. New AI verbs return this rather
/// than widening `SharedStoreError`, whose Swift `catch` arms are already
/// spread across the apps.
#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, Clone, thiserror::Error)]
pub enum AiError {
    #[error("{message}")]
    NotConfigured { message: String },
    #[error("{provider} rejected the credentials: {message}")]
    Unauthorized { provider: String, message: String },
    #[error("{provider} is unreachable: {message}")]
    Unreachable { provider: String, message: String },
    #[error("{provider} is rate limited")]
    RateLimited {
        provider: String,
        retry_after_secs: Option<u64>,
    },
    #[error("{provider} failed: {message}")]
    Provider {
        provider: String,
        status: Option<u16>,
        message: String,
    },
    #[error("{message}")]
    Invalid { message: String },
    #[error("{provider} executes outside the Rust runtime")]
    ForeignExecutor { provider: String },
    #[error("{bundle_id} must be launched by the host application")]
    HostLaunchRequired { bundle_id: String },
    #[error("cancelled")]
    Cancelled,
    #[error("{message}")]
    Storage { message: String },
}

impl From<AiCoreError> for AiError {
    fn from(error: AiCoreError) -> Self {
        match error {
            AiCoreError::NotConfigured { provider, message } => Self::NotConfigured {
                message: format!("{provider}: {message}"),
            },
            AiCoreError::Unauthorized { provider, message } => {
                Self::Unauthorized { provider, message }
            }
            AiCoreError::Unreachable { provider, message } => {
                Self::Unreachable { provider, message }
            }
            AiCoreError::RateLimited {
                provider,
                retry_after_secs,
            } => Self::RateLimited {
                provider,
                retry_after_secs,
            },
            AiCoreError::Provider {
                provider,
                status,
                message,
            } => Self::Provider {
                provider,
                status,
                message,
            },
            AiCoreError::Invalid(message) | AiCoreError::UnsupportedContent(message) => {
                Self::Invalid { message }
            }
            AiCoreError::ForeignExecutor(provider) => Self::ForeignExecutor { provider },
            AiCoreError::HostLaunchRequired { bundle_id } => Self::HostLaunchRequired { bundle_id },
            AiCoreError::Omlx(message) => Self::Unreachable {
                provider: catalogue::OMLX_ID.into(),
                message,
            },
            AiCoreError::Http(error) => Self::Unreachable {
                provider: "ai".into(),
                message: error.to_string(),
            },
            other => Self::Storage {
                message: other.to_string(),
            },
        }
    }
}

// ─── Records ─────────────────────────────────────────────────────────────

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiCredentialField {
    pub id: String,
    pub label: String,
    pub secret: bool,
    pub optional: bool,
    pub placeholder: Option<String>,
    pub configured: bool,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiCapabilities {
    pub streaming: bool,
    pub tools: bool,
    pub vision: bool,
    pub json_schema: bool,
    pub thinking: bool,
    pub embeddings: bool,
    pub system_prompt: bool,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiModelInfo {
    pub id: String,
    pub display_name: String,
    /// `llm`, `vlm`, `embedding`, `helper` or `unknown`.
    pub kind: String,
    pub loaded: bool,
    pub is_loading: bool,
    pub max_context_window: Option<u64>,
    pub max_output_tokens: Option<u64>,
    pub modalities: Vec<String>,
    pub is_default: bool,
    pub is_helper: bool,
    pub vision: bool,
    pub tools: Option<bool>,
    pub thinking: Option<bool>,
    pub json_schema: Option<bool>,
    /// `catalogue`, `discovered` or `both`.
    pub source: String,
    pub source_repo: Option<String>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiProviderInfo {
    pub id: String,
    pub display_name: String,
    pub description: String,
    /// `local`, `cloud`, `aggregator` or `native`.
    pub category: String,
    /// `rust` or `foreign` (executed by the host GUI).
    pub host: String,
    pub ready: bool,
    /// `ready`, `empty`, `needs_credentials`, `needs_endpoint`, `unreachable`,
    /// `foreign` or `foreign_unavailable`.
    pub readiness: String,
    pub endpoint: Option<String>,
    pub default_endpoint: Option<String>,
    pub endpoint_editable: bool,
    pub can_auto_start: bool,
    pub registration_url: Option<String>,
    pub icon: String,
    pub credential_fields: Vec<AiCredentialField>,
    pub capabilities: AiCapabilities,
    pub static_models: Vec<AiModelInfo>,
    pub has_dynamic_catalogue: bool,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiProviderHealth {
    pub provider: String,
    pub state: String,
    pub endpoint: Option<String>,
    pub checked_at_ms: i64,
    pub default_model: Option<String>,
    pub model_count: u32,
    pub loaded_count: Option<u32>,
    pub server_version: Option<String>,
    pub memory_in_use_bytes: Option<u64>,
    pub memory_ceiling_bytes: Option<u64>,
    pub detail: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiModelRef {
    pub provider: String,
    pub model: Option<String>,
    pub display_name: Option<String>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiCategoryAssignment {
    pub primary: Option<AiModelRef>,
    pub comparison: Vec<AiModelRef>,
    pub enabled: bool,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiTaskCategoryInfo {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub description: String,
    pub parent_id: Option<String>,
    pub apps: Vec<String>,
    pub supports_comparison: bool,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiCategoryEntry {
    pub category: String,
    pub assignment: AiCategoryAssignment,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiPreferencesRecord {
    pub version: u32,
    pub selected: Option<AiModelRef>,
    pub endpoints: HashMap<String, String>,
    pub auto_start_omlx: bool,
    pub task_categories: Vec<AiCategoryEntry>,
    pub updated_at_ms: i64,
    pub path: String,
    pub migrated_from_shared_defaults: bool,
    /// Models the researcher made available to the suite. Empty means every
    /// model is available, so a device that never curated a list is not left
    /// with empty pickers.
    pub enabled_models: Vec<AiModelRef>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiLegacyPreferences {
    pub selected_provider: Option<String>,
    pub selected_model: Option<String>,
    pub auto_start_omlx: Option<bool>,
    pub task_category_assignments_json: Option<String>,
    pub endpoints: HashMap<String, String>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiLegacyImportResult {
    pub preferences: AiPreferencesRecord,
    /// Human-readable summary of what was imported, remapped and dropped —
    /// the GUI logs it under `ai.migration`.
    pub summary: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiResolvedTarget {
    pub provider: String,
    pub model: String,
    pub endpoint_id: String,
    /// `explicit`, `category`, `selected` or `first_ready`.
    pub origin: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone)]
pub enum AiRole {
    System,
    User,
    Assistant,
    Tool,
}

#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone)]
pub enum AiContentPart {
    Text {
        text: String,
    },
    ImageBase64 {
        data: String,
        media_type: String,
        detail: Option<String>,
    },
    ImageUrl {
        url: String,
        detail: Option<String>,
    },
    ToolUse {
        id: String,
        name: String,
        input_json: String,
    },
    ToolResult {
        tool_use_id: String,
        content: String,
        is_error: bool,
    },
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiChatMessage {
    pub role: AiRole,
    pub content: Vec<AiContentPart>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema_json: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone)]
pub enum AiResponseFormat {
    Text,
    JsonObject,
    JsonSchema {
        name: String,
        schema_json: String,
        strict: bool,
    },
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiChatRequest {
    pub provider: Option<String>,
    pub model: Option<String>,
    pub task_category: Option<String>,
    pub messages: Vec<AiChatMessage>,
    pub system_prompt: Option<String>,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    pub stop_sequences: Vec<String>,
    pub tools: Vec<AiToolSpec>,
    pub response_format: Option<AiResponseFormat>,
    pub thinking: bool,
}

#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiFinishReason {
    Stop,
    Length,
    ToolUse,
    ContentFilter,
    Error,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiChatResponse {
    pub id: String,
    pub target: AiResolvedTarget,
    pub content: Vec<AiContentPart>,
    pub reasoning: Option<String>,
    pub finish_reason: Option<AiFinishReason>,
    pub usage: Option<AiUsage>,
}

#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone)]
pub enum AiStreamEvent {
    Started {
        target: AiResolvedTarget,
    },
    Text {
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
    ToolCall {
        id: String,
        name: String,
        input_json: String,
    },
    Usage {
        usage: AiUsage,
    },
    Done {
        finish_reason: Option<AiFinishReason>,
    },
    Failed {
        error: AiError,
    },
}

// ─── Conversions ─────────────────────────────────────────────────────────

fn model_info(model: ModelSummary) -> AiModelInfo {
    AiModelInfo {
        display_name: model.display_name().to_string(),
        kind: match model.kind {
            ModelKind::Llm => "llm",
            ModelKind::Vlm => "vlm",
            ModelKind::Embedding => "embedding",
            ModelKind::Helper => "helper",
            ModelKind::Unknown => "unknown",
        }
        .into(),
        loaded: model.loaded,
        is_loading: model.is_loading,
        max_context_window: model.max_context_window,
        max_output_tokens: model.max_output_tokens,
        modalities: model.modalities.clone(),
        is_default: model.is_default,
        is_helper: model.is_helper,
        vision: model.supports_vision(),
        tools: model.tools,
        thinking: model.thinking,
        json_schema: model.json_schema,
        source: match model.source {
            ModelSource::Catalogue => "catalogue",
            ModelSource::Discovered => "discovered",
            ModelSource::Both => "both",
        }
        .into(),
        source_repo: model.source_repo.clone(),
        id: model.id,
    }
}

fn provider_info(state: &impress_ai::registry::ProviderState) -> AiProviderInfo {
    let descriptor = state.descriptor;
    AiProviderInfo {
        id: descriptor.id.into(),
        display_name: descriptor.display_name.into(),
        description: descriptor.description.into(),
        category: descriptor.category.label().into(),
        host: descriptor.host.label().into(),
        ready: state.readiness.is_ready(),
        readiness: state.readiness.label().into(),
        endpoint: state.endpoint.clone(),
        default_endpoint: descriptor.default_endpoint.map(str::to_string),
        endpoint_editable: descriptor.endpoint_editable,
        can_auto_start: descriptor.can_auto_start,
        registration_url: descriptor.registration_url.map(str::to_string),
        icon: descriptor.icon.into(),
        credential_fields: descriptor
            .credential_fields
            .iter()
            .map(|field| AiCredentialField {
                id: field.id.into(),
                label: field.label.into(),
                secret: field.secret,
                optional: field.optional,
                placeholder: field.placeholder.map(str::to_string),
                configured: state
                    .credentials
                    .fields
                    .iter()
                    .any(|status| status.field == field.id && status.configured),
            })
            .collect(),
        capabilities: AiCapabilities {
            streaming: descriptor.capabilities.streaming,
            tools: descriptor.capabilities.tools,
            vision: descriptor.capabilities.vision,
            json_schema: descriptor.capabilities.json_schema,
            thinking: descriptor.capabilities.thinking,
            embeddings: descriptor.capabilities.embeddings,
            system_prompt: descriptor.capabilities.system_prompt,
        },
        static_models: descriptor
            .static_summaries()
            .into_iter()
            .map(model_info)
            .collect(),
        has_dynamic_catalogue: descriptor.discovery == catalogue::Discovery::Api,
    }
}

fn health_record(provider: &str, health: ProviderHealth) -> AiProviderHealth {
    AiProviderHealth {
        provider: provider.into(),
        state: health.state.label().into(),
        endpoint: health.endpoint,
        checked_at_ms: health.checked_at_ms,
        default_model: health.default_model,
        model_count: health.model_count,
        loaded_count: health.loaded_count,
        server_version: health.server_version,
        memory_in_use_bytes: health.memory_in_use_bytes,
        memory_ceiling_bytes: health.memory_ceiling_bytes,
        detail: health.detail,
    }
}

fn model_ref(reference: ModelRef) -> AiModelRef {
    AiModelRef {
        provider: reference.provider,
        model: reference.model,
        display_name: reference.display_name,
    }
}

fn model_ref_core(reference: AiModelRef) -> ModelRef {
    ModelRef {
        provider: reference.provider,
        model: reference.model.filter(|model| !model.trim().is_empty()),
        display_name: reference.display_name,
    }
}

fn assignment_record(assignment: CategoryAssignment) -> AiCategoryAssignment {
    AiCategoryAssignment {
        primary: assignment.primary.map(model_ref),
        comparison: assignment.comparison.into_iter().map(model_ref).collect(),
        enabled: assignment.enabled,
    }
}

fn assignment_core(assignment: AiCategoryAssignment) -> CategoryAssignment {
    CategoryAssignment {
        primary: assignment.primary.map(model_ref_core),
        comparison: assignment
            .comparison
            .into_iter()
            .map(model_ref_core)
            .collect(),
        enabled: assignment.enabled,
    }
}

fn preferences_record(preferences: AiPreferences, path: String) -> AiPreferencesRecord {
    AiPreferencesRecord {
        version: preferences.version,
        selected: preferences.selected.map(model_ref),
        endpoints: preferences.endpoints.into_iter().collect(),
        auto_start_omlx: preferences.auto_start_omlx,
        task_categories: preferences
            .task_categories
            .into_iter()
            .map(|(category, assignment)| AiCategoryEntry {
                category,
                assignment: assignment_record(assignment),
            })
            .collect(),
        updated_at_ms: preferences.updated_at_ms,
        path,
        migrated_from_shared_defaults: preferences.migrated_from_shared_defaults,
        enabled_models: preferences
            .enabled_models
            .into_iter()
            .map(model_ref)
            .collect(),
    }
}

fn resolved_record(resolved: ResolvedTarget) -> AiResolvedTarget {
    AiResolvedTarget {
        provider: resolved.provider,
        model: resolved.model,
        endpoint_id: resolved.endpoint_id,
        origin: resolved.origin.label().into(),
    }
}

fn finish_reason(reason: &str) -> AiFinishReason {
    match reason {
        "stop" | "end_turn" => AiFinishReason::Stop,
        "length" | "max_tokens" => AiFinishReason::Length,
        "tool_calls" | "tool_use" => AiFinishReason::ToolUse,
        "content_filter" | "refusal" => AiFinishReason::ContentFilter,
        _ => AiFinishReason::Error,
    }
}

fn usage_record(usage: &serde_json::Value) -> AiUsage {
    AiUsage {
        input_tokens: usage["prompt_tokens"].as_u64().unwrap_or(0),
        output_tokens: usage["completion_tokens"].as_u64().unwrap_or(0),
    }
}

fn parse_json(json: &str, what: &str) -> Result<serde_json::Value, AiError> {
    if json.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    serde_json::from_str(json).map_err(|error| AiError::Invalid {
        message: format!("{what} is not valid JSON: {error}"),
    })
}

fn chat_request(request: AiChatRequest) -> Result<(ResolveTarget, ChatRequest), AiError> {
    let mut messages = Vec::with_capacity(request.messages.len() + 1);
    if let Some(system) = request
        .system_prompt
        .filter(|system| !system.trim().is_empty())
    {
        messages.push(ModelMessage::text(Role::System, system));
    }
    for message in request.messages {
        let role = match message.role {
            AiRole::System => Role::System,
            AiRole::User => Role::User,
            AiRole::Assistant => Role::Assistant,
            AiRole::Tool => Role::Tool,
        };
        let mut content = Vec::new();
        let mut tool_calls = Vec::new();
        let mut tool_call_id = None;
        for part in message.content {
            match part {
                AiContentPart::Text { text } => content.push(ModelContentPart::Text { text }),
                AiContentPart::ImageBase64 {
                    data,
                    media_type,
                    detail,
                } => content.push(ModelContentPart::ImageUrl {
                    image_url: ImageUrl {
                        url: format!("data:{media_type};base64,{data}"),
                        detail,
                    },
                }),
                AiContentPart::ImageUrl { url, detail } => {
                    content.push(ModelContentPart::ImageUrl {
                        image_url: ImageUrl { url, detail },
                    })
                }
                AiContentPart::ToolUse {
                    id,
                    name,
                    input_json,
                } => {
                    parse_json(&input_json, "tool input")?;
                    tool_calls.push(ModelToolCall {
                        id,
                        name,
                        arguments: if input_json.trim().is_empty() {
                            "{}".into()
                        } else {
                            input_json
                        },
                    });
                }
                AiContentPart::ToolResult {
                    tool_use_id,
                    content: result,
                    is_error,
                } => {
                    tool_call_id = Some(tool_use_id);
                    content.push(ModelContentPart::Text {
                        text: if is_error {
                            serde_json::json!({ "error": result }).to_string()
                        } else {
                            result
                        },
                    });
                }
            }
        }
        // A tool result row is a tool message regardless of the role the
        // caller labelled it with.
        let role = if tool_call_id.is_some() {
            Role::Tool
        } else {
            role
        };
        messages.push(ModelMessage {
            role,
            content,
            name: None,
            tool_call_id,
            tool_calls,
        });
    }
    let tools = request
        .tools
        .into_iter()
        .map(|tool| {
            Ok(ToolDefinition {
                name: tool.name,
                description: tool.description,
                input_schema: parse_json(&tool.input_schema_json, "tool schema")?,
            })
        })
        .collect::<Result<Vec<_>, AiError>>()?;
    let response_format = match request.response_format {
        None | Some(AiResponseFormat::Text) => None,
        Some(AiResponseFormat::JsonObject) => Some(ResponseFormat::JsonObject),
        Some(AiResponseFormat::JsonSchema {
            name,
            schema_json,
            strict,
        }) => Some(ResponseFormat::JsonSchema {
            name,
            schema: parse_json(&schema_json, "response schema")?,
            strict,
        }),
    };
    let chat = ChatRequest {
        model: request.model.clone().unwrap_or_default(),
        messages,
        temperature: request.temperature.map(|value| value as f32),
        max_tokens: request.max_tokens.unwrap_or(2048),
        thinking: request.thinking,
        top_p: request.top_p.map(|value| value as f32),
        stop: request.stop_sequences,
        response_format,
        tools,
        tool_policy: Default::default(),
    };
    let target = ResolveTarget {
        provider: request.provider,
        model: request.model,
        category: request.task_category,
    };
    Ok((target, chat))
}

fn completion_response(target: ResolvedTarget, completion: Completion) -> AiChatResponse {
    let mut content = Vec::new();
    if !completion.content.is_empty() {
        content.push(AiContentPart::Text {
            text: completion.content,
        });
    }
    for call in completion.tool_calls {
        content.push(AiContentPart::ToolUse {
            id: call.id,
            name: call.name,
            input_json: call.arguments,
        });
    }
    let finish = completion
        .finish_reason
        .as_deref()
        .map(finish_reason)
        .or_else(|| {
            content
                .iter()
                .any(|part| matches!(part, AiContentPart::ToolUse { .. }))
                .then_some(AiFinishReason::ToolUse)
        });
    AiChatResponse {
        id: uuid::Uuid::new_v4().to_string(),
        target: resolved_record(target),
        content,
        reasoning: (!completion.reasoning.is_empty()).then_some(completion.reasoning),
        finish_reason: finish,
        usage: completion.usage.as_ref().map(usage_record),
    }
}

fn stream_event(event: StreamEvent) -> AiStreamEvent {
    match event {
        StreamEvent::Token { text } => AiStreamEvent::Text { text },
        StreamEvent::Reasoning { text } => AiStreamEvent::Reasoning { text },
        StreamEvent::ToolCallDelta {
            index,
            id,
            name,
            arguments,
        } => AiStreamEvent::ToolCallDelta {
            index,
            id,
            name,
            arguments,
        },
        StreamEvent::Usage { usage } => AiStreamEvent::Usage {
            usage: usage_record(&usage),
        },
        StreamEvent::Done {
            finish_reason: reason,
        } => AiStreamEvent::Done {
            finish_reason: reason.as_deref().map(finish_reason),
        },
        StreamEvent::Error { error } => AiStreamEvent::Failed {
            error: AiError::Provider {
                provider: "stream".into(),
                status: None,
                message: error,
            },
        },
    }
}

// ─── The registry object ─────────────────────────────────────────────────

/// The GUI's handle on the Rust AI registry. One per process is enough; it
/// is cheap to construct and safe to share.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedAiRegistry {
    registry: Arc<AiRegistry>,
    memory: Arc<InMemoryCredentials>,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedAiRegistry {
    /// `workspace_path` is the directory holding `impress.sqlite`
    /// (`SharedWorkspace.workspaceDirectory` in Swift); the preferences file
    /// lives beside it under `ai/`.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(workspace_path: String) -> Result<Arc<Self>, AiError> {
        if workspace_path.trim().is_empty() {
            return Err(AiError::Invalid {
                message: "workspace path must not be empty".into(),
            });
        }
        let memory = InMemoryCredentials::new();
        let registry = AiRegistry::for_app(&workspace_path, memory.clone());
        Ok(Arc::new(Self { registry, memory }))
    }

    pub fn list_providers(&self) -> Vec<AiProviderInfo> {
        let registry = Arc::clone(&self.registry);
        runtime()
            .block_on(async move { registry.provider_states_probed().await })
            .iter()
            .map(provider_info)
            .collect()
    }

    pub fn list_task_categories(&self, app: Option<String>) -> Vec<AiTaskCategoryInfo> {
        categories::TASK_CATEGORIES
            .iter()
            .filter(|category| {
                app.as_deref()
                    .is_none_or(|app| category.is_root() || category.apps.contains(&app))
            })
            .map(|category| AiTaskCategoryInfo {
                id: category.id.into(),
                name: category.name.into(),
                icon: category.icon.into(),
                description: category.description.into(),
                parent_id: category.parent.map(str::to_string),
                apps: category.apps.iter().map(|app| app.to_string()).collect(),
                supports_comparison: category.supports_comparison,
            })
            .collect()
    }

    /// Secret fields the host read from its keychain. Held in memory only;
    /// an empty value clears the field.
    pub fn configure_credentials(&self, provider: String, fields: HashMap<String, String>) {
        self.memory.set_all(&provider, fields);
        self.registry.invalidate_clients(&provider);
    }

    pub fn clear_credentials(&self, provider: String) {
        self.memory.clear(&provider);
        self.registry.invalidate_clients(&provider);
    }

    pub fn set_foreign_provider_available(&self, provider: String, available: bool) {
        self.registry.set_foreign_available(&provider, available);
    }

    pub fn preferences(&self) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self.registry.preferences().load().map_err(storage)?;
        Ok(preferences_record(preferences, self.path()))
    }

    pub fn preferences_changed_since(&self, updated_at_ms: i64) -> bool {
        self.registry.preferences().changed_since(updated_at_ms)
    }

    pub fn select_model(
        &self,
        provider: String,
        model: Option<String>,
    ) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self.registry.select_model(&provider, model)?;
        Ok(preferences_record(preferences, self.path()))
    }

    /// Add or remove one model from the set the suite may use. The
    /// task-category pickers offer exactly this set once it is non-empty.
    pub fn set_model_enabled(
        &self,
        provider: String,
        model: String,
        enabled: bool,
    ) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self
            .registry
            .set_model_enabled(&provider, &model, enabled)?;
        Ok(preferences_record(
            preferences,
            self.registry.preferences().path().display().to_string(),
        ))
    }

    /// Replace the whole set at once.
    pub fn set_enabled_models(
        &self,
        models: Vec<AiModelRef>,
    ) -> Result<AiPreferencesRecord, AiError> {
        let refs = models
            .into_iter()
            .map(|entry| ModelRef {
                provider: entry.provider,
                model: entry.model,
                display_name: entry.display_name,
            })
            .collect();
        let preferences = self.registry.set_enabled_models(refs)?;
        Ok(preferences_record(
            preferences,
            self.registry.preferences().path().display().to_string(),
        ))
    }

    pub fn clear_selection(&self) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self.registry.clear_selection()?;
        Ok(preferences_record(preferences, self.path()))
    }

    pub fn set_provider_endpoint(
        &self,
        provider: String,
        endpoint: Option<String>,
    ) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self.registry.set_provider_endpoint(&provider, endpoint)?;
        Ok(preferences_record(preferences, self.path()))
    }

    pub fn set_auto_start_omlx(&self, enabled: bool) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self.registry.set_auto_start_omlx(enabled)?;
        Ok(preferences_record(preferences, self.path()))
    }

    pub fn set_task_category(
        &self,
        category: String,
        assignment: AiCategoryAssignment,
    ) -> Result<AiPreferencesRecord, AiError> {
        let preferences = self
            .registry
            .set_task_category(&category, assignment_core(assignment))?;
        Ok(preferences_record(preferences, self.path()))
    }

    pub fn import_legacy_preferences(
        &self,
        legacy: AiLegacyPreferences,
    ) -> Result<AiLegacyImportResult, AiError> {
        let legacy = LegacyPreferences {
            selected_provider: legacy.selected_provider,
            selected_model: legacy.selected_model,
            auto_start_omlx: legacy.auto_start_omlx,
            task_category_assignments_json: legacy.task_category_assignments_json,
            endpoints: legacy.endpoints.into_iter().collect(),
        };
        let (preferences, report) = self
            .registry
            .preferences()
            .import_legacy_swift(&legacy)
            .map_err(storage)?;
        Ok(AiLegacyImportResult {
            preferences: preferences_record(preferences, self.path()),
            summary: report.summary(),
        })
    }

    pub fn resolve_target(
        &self,
        provider: Option<String>,
        model: Option<String>,
        category: Option<String>,
    ) -> Result<AiResolvedTarget, AiError> {
        let target = ResolveTarget {
            provider,
            model,
            category,
        };
        let registry = self.registry.clone();
        let resolved =
            runtime().block_on(async move { registry.resolve_with_discovery(&target).await })?;
        Ok(resolved_record(resolved))
    }

    /// Passive discovery for `provider` (or the resolved default), catalogue
    /// merged with the host's live list. Never launches anything.
    pub fn discover_models(&self, provider: Option<String>) -> Result<Vec<AiModelInfo>, AiError> {
        let registry = self.registry.clone();
        let (_, models) = runtime().block_on(async move {
            tokio::time::timeout(
                Duration::from_secs(10),
                registry.models(provider.as_deref()),
            )
            .await
            .map_err(|_| AiCoreError::Unreachable {
                provider: provider.clone().unwrap_or_else(|| "ai".into()),
                message: "model discovery timed out".into(),
            })?
        })?;
        Ok(models.into_iter().map(model_info).collect())
    }

    /// Passive health probe (≤5 s). Never launches anything.
    pub fn provider_health(&self, provider: String) -> AiProviderHealth {
        let registry = self.registry.clone();
        let id = provider.clone();
        let health = runtime().block_on(async move { registry.health(&id).await });
        health_record(&provider, health)
    }

    /// Start the managed oMLX server when the preferences allow and wait for
    /// it. `HostLaunchRequired` means the host must launch oMLX.app and call
    /// again.
    pub fn ensure_omlx_running(&self, timeout_secs: u32) -> Result<AiProviderHealth, AiError> {
        let registry = self.registry.clone();
        let timeout = Duration::from_secs(u64::from(timeout_secs.clamp(1, 600)));
        let health = runtime()
            .block_on(async move { omlx_control::ensure_running(&registry, timeout).await })?;
        Ok(health_record(catalogue::OMLX_ID, health))
    }

    /// Non-streaming completion on the FFI runtime.
    pub fn chat_complete(&self, request: AiChatRequest) -> Result<AiChatResponse, AiError> {
        let (target, chat) = chat_request(request)?;
        let registry = self.registry.clone();
        let (resolved, completion) =
            runtime().block_on(async move { registry.complete(&target, chat).await })?;
        Ok(completion_response(resolved, completion))
    }

    /// Start a streaming completion. The stream's producer runs on the FFI
    /// runtime; the caller pulls events with `next_event()`.
    pub fn chat_stream(&self, request: AiChatRequest) -> Result<Arc<AiChatStream>, AiError> {
        let (target, chat) = chat_request(request)?;
        let registry = self.registry.clone();
        let (resolved, mut upstream) =
            runtime().block_on(async move { registry.stream(&target, chat).await })?;
        let (sender, receiver) = tokio::sync::mpsc::channel(64);
        let started = resolved_record(resolved);
        let announce = started.clone();
        let task = runtime().spawn(async move {
            if sender
                .send(AiStreamEvent::Started { target: announce })
                .await
                .is_err()
            {
                return;
            }
            while let Some(event) = upstream.next().await {
                let event = match event {
                    Ok(event) => stream_event(event),
                    Err(error) => AiStreamEvent::Failed {
                        error: error.into(),
                    },
                };
                let terminal = matches!(event, AiStreamEvent::Failed { .. });
                if sender.send(event).await.is_err() || terminal {
                    return;
                }
            }
        });
        Ok(Arc::new(AiChatStream {
            events: tokio::sync::Mutex::new(receiver),
            task: Mutex::new(Some(task)),
            cancelled: AtomicBool::new(false),
            target: started,
        }))
    }
}

impl SharedAiRegistry {
    fn path(&self) -> String {
        self.registry
            .preferences()
            .path()
            .to_string_lossy()
            .into_owned()
    }

    /// The underlying registry, for in-process Rust callers (tests, hosts
    /// that embed both halves).
    pub fn registry(&self) -> &Arc<AiRegistry> {
        &self.registry
    }
}

fn storage(error: std::io::Error) -> AiError {
    AiError::Storage {
        message: error.to_string(),
    }
}

/// A streaming completion in flight. `next_event` is the first async export
/// in the suite: it only awaits a channel, so no runtime attribute is
/// needed, and a Swift actor can await it without blocking a thread.
/// `cancel()` (or dropping the object) is the cancellation path — the Swift
/// bindings cannot cancel a Rust future themselves.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct AiChatStream {
    events: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<AiStreamEvent>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    cancelled: AtomicBool,
    target: AiResolvedTarget,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl AiChatStream {
    /// The next event, or `None` once the stream has finished, failed or
    /// been cancelled.
    pub async fn next_event(&self) -> Option<AiStreamEvent> {
        if self.cancelled.load(Ordering::SeqCst) {
            return None;
        }
        self.events.lock().await.recv().await
    }

    /// Blocking pull for harnesses without Swift concurrency; `None` after
    /// the stream ends or when `timeout_ms` elapses with nothing to deliver.
    pub fn next_event_blocking(&self, timeout_ms: u64) -> Option<AiStreamEvent> {
        if self.cancelled.load(Ordering::SeqCst) {
            return None;
        }
        runtime().block_on(async {
            let mut events = self.events.lock().await;
            tokio::time::timeout(Duration::from_millis(timeout_ms.max(1)), events.recv())
                .await
                .ok()
                .flatten()
        })
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(task) = self.task.lock().unwrap().take() {
            task.abort();
        }
    }

    pub fn target(&self) -> AiResolvedTarget {
        self.target.clone()
    }
}

impl Drop for AiChatStream {
    fn drop(&mut self) {
        if let Some(task) = self.task.lock().unwrap().take() {
            task.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry(directory: &tempfile::TempDir) -> SharedAiRegistry {
        let registry =
            SharedAiRegistry::open(directory.path().to_string_lossy().into_owned()).unwrap();
        Arc::try_unwrap(registry).unwrap_or_else(|arc| SharedAiRegistry {
            registry: arc.registry.clone(),
            memory: arc.memory.clone(),
        })
    }

    #[test]
    fn providers_preferences_and_categories_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let shared = registry(&directory);
        let providers = shared.list_providers();
        assert_eq!(providers.len(), 8);
        assert_eq!(providers[0].id, "omlx");
        assert!(providers[0].can_auto_start);
        assert_eq!(providers[0].host, "rust");
        let apple = providers
            .iter()
            .find(|provider| provider.id == "apple-on-device")
            .unwrap();
        assert_eq!(apple.host, "foreign");
        assert_eq!(apple.static_models.len(), 1);
        let anthropic = providers
            .iter()
            .find(|provider| provider.id == "anthropic")
            .unwrap();
        assert_eq!(anthropic.readiness, "needs_credentials");
        assert!(!anthropic.credential_fields[0].configured);

        shared.configure_credentials(
            "anthropic".into(),
            HashMap::from([("apiKey".to_string(), "sk-ant-test".to_string())]),
        );
        let anthropic = shared
            .list_providers()
            .into_iter()
            .find(|provider| provider.id == "anthropic")
            .unwrap();
        assert!(anthropic.ready);
        assert!(anthropic.credential_fields[0].configured);

        let preferences = shared.preferences().unwrap();
        assert!(preferences.selected.is_none());
        assert!(preferences.path.ends_with("ai/preferences.json"));
        let selected = shared
            .select_model("anthropic".into(), Some("claude-sonnet-5".into()))
            .unwrap();
        assert_eq!(
            selected.selected.as_ref().unwrap().model.as_deref(),
            Some("claude-sonnet-5")
        );
        assert!(shared.preferences_changed_since(preferences.updated_at_ms));
        assert!(matches!(
            shared.select_model("omlx".into(), Some("MarkItDown".into())),
            Err(AiError::Invalid { .. })
        ));

        let resolved = shared.resolve_target(None, None, None).unwrap();
        assert_eq!(resolved.provider, "anthropic");
        assert_eq!(resolved.model, "claude-sonnet-5");
        assert_eq!(resolved.origin, "selected");

        let updated = shared
            .set_task_category(
                "research.rag".into(),
                AiCategoryAssignment {
                    primary: Some(AiModelRef {
                        provider: "anthropic".into(),
                        model: Some("claude-opus-5".into()),
                        display_name: None,
                    }),
                    comparison: vec![],
                    enabled: true,
                },
            )
            .unwrap();
        assert_eq!(updated.task_categories.len(), 1);
        let categories = shared.list_task_categories(Some("imbib".into()));
        assert!(categories
            .iter()
            .any(|category| category.id == "research.rag"));
        assert!(categories
            .iter()
            .all(|category| category.parent_id.is_none()
                || category.apps.contains(&"imbib".to_string())));

        let imported = shared
            .import_legacy_preferences(AiLegacyPreferences {
                selected_provider: Some("openai-compatible".into()),
                selected_model: Some("MarkItDown".into()),
                auto_start_omlx: None,
                task_category_assignments_json: None,
                endpoints: HashMap::new(),
            })
            .unwrap();
        assert!(imported.preferences.migrated_from_shared_defaults);
        assert_eq!(
            imported.preferences.selected.unwrap().provider,
            "anthropic",
            "existing selection wins"
        );
        assert!(
            imported.summary.contains("no selection") || imported.summary.contains("selection")
        );
        let cleared = shared.clear_selection().unwrap();
        assert!(cleared.selected.is_none());
    }

    #[test]
    fn chat_request_conversion_covers_every_part() {
        let request = AiChatRequest {
            provider: Some("omlx".into()),
            model: Some("m".into()),
            task_category: None,
            messages: vec![
                AiChatMessage {
                    role: AiRole::User,
                    content: vec![
                        AiContentPart::Text {
                            text: "look".into(),
                        },
                        AiContentPart::ImageBase64 {
                            data: "AA==".into(),
                            media_type: "image/png".into(),
                            detail: None,
                        },
                    ],
                },
                AiChatMessage {
                    role: AiRole::Assistant,
                    content: vec![AiContentPart::ToolUse {
                        id: "call-1".into(),
                        name: "scix".into(),
                        input_json: r#"{"q":"stars"}"#.into(),
                    }],
                },
                AiChatMessage {
                    role: AiRole::User,
                    content: vec![AiContentPart::ToolResult {
                        tool_use_id: "call-1".into(),
                        content: "3 papers".into(),
                        is_error: false,
                    }],
                },
            ],
            system_prompt: Some("Be terse.".into()),
            max_tokens: Some(64),
            temperature: Some(0.5),
            top_p: None,
            stop_sequences: vec![],
            tools: vec![AiToolSpec {
                name: "scix".into(),
                description: "search".into(),
                input_schema_json: r#"{"type":"object"}"#.into(),
            }],
            response_format: Some(AiResponseFormat::JsonSchema {
                name: "answer".into(),
                schema_json: r#"{"type":"object"}"#.into(),
                strict: true,
            }),
            thinking: true,
        };
        let (target, chat) = chat_request(request).unwrap();
        assert_eq!(target.provider.as_deref(), Some("omlx"));
        assert_eq!(chat.messages.len(), 4, "system prompt is prepended");
        assert_eq!(chat.messages[0].role, Role::System);
        assert!(
            matches!(&chat.messages[1].content[1], ModelContentPart::ImageUrl { image_url } if image_url.url.starts_with("data:image/png;base64,"))
        );
        assert_eq!(chat.messages[2].tool_calls[0].arguments, r#"{"q":"stars"}"#);
        assert_eq!(chat.messages[3].role, Role::Tool);
        assert_eq!(chat.messages[3].tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(chat.tools[0].name, "scix");
        assert!(matches!(
            chat.response_format,
            Some(ResponseFormat::JsonSchema { strict: true, .. })
        ));
        assert_eq!(chat.temperature, Some(0.5));
        assert!(chat.thinking);
        assert!(matches!(
            chat_request(AiChatRequest {
                provider: None,
                model: None,
                task_category: None,
                messages: vec![],
                system_prompt: None,
                max_tokens: None,
                temperature: None,
                top_p: None,
                stop_sequences: vec![],
                tools: vec![AiToolSpec {
                    name: "x".into(),
                    description: String::new(),
                    input_schema_json: "not json".into(),
                }],
                response_format: None,
                thinking: false,
            }),
            Err(AiError::Invalid { .. })
        ));
    }

    #[test]
    fn stream_and_completion_events_map_onto_records() {
        assert!(matches!(
            stream_event(StreamEvent::Done {
                finish_reason: Some("tool_calls".into())
            }),
            AiStreamEvent::Done {
                finish_reason: Some(AiFinishReason::ToolUse)
            }
        ));
        assert!(matches!(
            stream_event(StreamEvent::Usage {
                usage: serde_json::json!({ "prompt_tokens": 3, "completion_tokens": 4 })
            }),
            AiStreamEvent::Usage {
                usage: AiUsage {
                    input_tokens: 3,
                    output_tokens: 4
                }
            }
        ));
        let response = completion_response(
            ResolvedTarget {
                provider: "omlx".into(),
                model: "m".into(),
                endpoint_id: "local-omlx".into(),
                origin: impress_ai::ResolutionOrigin::Selected,
            },
            Completion {
                content: "Hello".into(),
                reasoning: "hmm".into(),
                tool_calls: vec![impress_ai::PendingToolCall {
                    index: 0,
                    id: "call-1".into(),
                    name: "scix".into(),
                    arguments: "{}".into(),
                }],
                usage: Some(serde_json::json!({ "prompt_tokens": 1, "completion_tokens": 2 })),
                finish_reason: None,
            },
        );
        assert_eq!(response.target.origin, "selected");
        assert_eq!(response.finish_reason, Some(AiFinishReason::ToolUse));
        assert_eq!(response.content.len(), 2);
        assert_eq!(response.reasoning.as_deref(), Some("hmm"));
        assert_eq!(response.usage.unwrap().output_tokens, 2);

        let mapped: AiError = AiCoreError::HostLaunchRequired {
            bundle_id: "app.omlx".into(),
        }
        .into();
        assert!(
            matches!(mapped, AiError::HostLaunchRequired { bundle_id } if bundle_id == "app.omlx")
        );
    }

    #[tokio::test]
    async fn unconfigured_provider_fails_before_any_network_call() {
        let directory = tempfile::tempdir().unwrap();
        let shared = registry(&directory);
        let error = tokio::task::spawn_blocking(move || {
            shared.chat_complete(AiChatRequest {
                provider: Some("google".into()),
                model: None,
                task_category: None,
                messages: vec![AiChatMessage {
                    role: AiRole::User,
                    content: vec![AiContentPart::Text { text: "hi".into() }],
                }],
                system_prompt: None,
                max_tokens: None,
                temperature: None,
                top_p: None,
                stop_sequences: vec![],
                tools: vec![],
                response_format: None,
                thinking: false,
            })
        })
        .await
        .unwrap()
        .unwrap_err();
        assert!(matches!(error, AiError::NotConfigured { .. }), "{error}");
    }
}
