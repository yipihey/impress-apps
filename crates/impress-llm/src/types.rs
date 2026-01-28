//! Type definitions for the impress-llm FFI interface
//!
//! These types are designed to be simple and map cleanly across the Rust-Swift boundary.

use std::collections::HashMap;

/// Message role in a conversation
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LLMRole {
    System,
    User,
    Assistant,
}

/// A single message in a conversation
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct LLMMessage {
    /// Role of the message sender
    pub role: LLMRole,
    /// Text content of the message
    pub content: String,
}

/// Request to complete a conversation
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct LLMRequest {
    /// Provider identifier (e.g., "groq", "phind", "mistral")
    pub provider: String,
    /// Model identifier (e.g., "llama-3.3-70b-versatile")
    pub model: String,
    /// Conversation messages
    pub messages: Vec<LLMMessage>,
    /// Maximum tokens to generate (optional)
    pub max_tokens: Option<u32>,
    /// Temperature for sampling (0.0-2.0, optional)
    pub temperature: Option<f32>,
    /// Top-p nucleus sampling (optional)
    pub top_p: Option<f32>,
    /// API key for the provider
    pub api_key: String,
}

/// Response from a completion request
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct LLMResponse {
    /// Generated content
    pub content: String,
    /// Number of tokens used in completion
    pub tokens_used: Option<u32>,
    /// Reason for completion ending
    pub finish_reason: String,
    /// Model that generated the response
    pub model: String,
}

/// Information about a supported provider
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ProviderInfo {
    /// Unique identifier for the provider
    pub id: String,
    /// Display name
    pub name: String,
    /// Description of the provider
    pub description: String,
    /// URL to get API keys
    pub registration_url: Option<String>,
    /// Whether the provider requires an API key
    pub requires_api_key: bool,
    /// Default model for this provider
    pub default_model: String,
    /// Category: "cloud", "local", or "aggregator"
    pub category: String,
}

/// Information about a model
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ModelInfo {
    /// Model identifier
    pub id: String,
    /// Display name
    pub name: String,
    /// Description
    pub description: Option<String>,
    /// Maximum context window in tokens
    pub context_window: Option<u32>,
    /// Maximum output tokens
    pub max_output_tokens: Option<u32>,
    /// Whether this is the default model for the provider
    pub is_default: bool,
}

/// Error types for LLM operations
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[derive(Debug, thiserror::Error)]
pub enum LLMError {
    #[error("Provider not found: {provider}")]
    ProviderNotFound { provider: String },

    #[error("Model not found: {model}")]
    ModelNotFound { model: String },

    #[error("Invalid API key")]
    InvalidApiKey,

    #[error("Rate limited: retry after {retry_after_seconds:?} seconds")]
    RateLimited { retry_after_seconds: Option<u32> },

    #[error("Network error: {message}")]
    NetworkError { message: String },

    #[error("API error: {message}")]
    ApiError { message: String },

    #[error("Invalid request: {message}")]
    InvalidRequest { message: String },

    #[error("Content filtered: {message}")]
    ContentFiltered { message: String },

    #[error("Context length exceeded: {message}")]
    ContextLengthExceeded { message: String },

    #[error("Unknown error: {message}")]
    Unknown { message: String },
}

// ============================================================================
// Memory Management Types
// ============================================================================

/// Handle to a conversation memory scope
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct MemoryHandle {
    /// Unique identifier for this memory scope
    pub id: String,
    /// Optional scope name (e.g., document ID)
    pub scope_name: Option<String>,
}

/// Memory scope for organizing conversations
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryScope {
    /// Per-document memory
    Document,
    /// Per-project/collection memory
    Project,
    /// Global user memory
    Global,
}

/// Serialized memory state for persistence
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct MemoryState {
    /// Serialized messages
    pub messages: Vec<LLMMessage>,
    /// Metadata about the memory
    pub metadata: HashMap<String, String>,
    /// Scope of this memory
    pub scope: MemoryScope,
    /// Timestamp when last updated (Unix timestamp)
    pub last_updated: i64,
}

// ============================================================================
// Streaming Types (for future use)
// ============================================================================

/// A chunk from streaming response
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct StreamChunk {
    /// Delta content for this chunk
    pub delta: String,
    /// Whether this is the final chunk
    pub is_final: bool,
    /// Finish reason if final
    pub finish_reason: Option<String>,
}
