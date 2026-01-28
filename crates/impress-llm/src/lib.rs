//! Impress LLM - Extended LLM provider support for impress apps
//!
//! This crate provides access to additional LLM providers through the graniet/llm library,
//! complementing the native Swift providers in ImpressAI.
//!
//! # Supported Providers
//!
//! - **Groq**: Ultra-fast inference with LPU technology
//! - **Phind**: Code-optimized AI with fast responses
//! - **Mistral**: European AI with strong multilingual capabilities
//! - **Cohere**: Enterprise-focused AI with strong RAG capabilities
//! - **DeepSeek**: Affordable AI with strong reasoning
//! - **xAI (Grok)**: Real-time knowledge from xAI
//! - **HuggingFace**: Access to thousands of open-source models
//!
//! # Features
//!
//! - `uniffi`: Enable FFI bindings for Swift/Kotlin (required for iOS/macOS)
//! - `native`: Full native build with UniFFI
//!
//! # Architecture
//!
//! The crate is designed to be called from Swift through UniFFI. All operations
//! are blocking (synchronous) and should be called from a background thread.
//! The Swift layer wraps these calls in `Task.detached` for async behavior.
//!
//! # Memory Management
//!
//! The crate provides memory scopes for conversation persistence:
//! - Create a memory scope with `create_memory_scope`
//! - Add messages with `add_message_to_memory`
//! - Complete with context using `complete_with_context`
//! - Export/import for persistence with `export_memory`/`import_memory`

pub mod provider;
pub mod types;

pub use provider::*;
pub use types::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

// ============================================================================
// UniFFI Exports - Provider Management
// ============================================================================

/// List all available providers
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn list_providers() -> Vec<ProviderInfo> {
    provider::get_providers()
}

/// List models for a specific provider
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn list_models(provider_id: String) -> Vec<ModelInfo> {
    provider::get_models(&provider_id)
}

/// Get provider info by ID
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_provider(provider_id: String) -> Option<ProviderInfo> {
    provider::get_providers()
        .into_iter()
        .find(|p| p.id == provider_id)
}

// ============================================================================
// UniFFI Exports - Completion
// ============================================================================

/// Execute a completion request
///
/// This is a blocking operation and should be called from a background thread.
/// The Swift layer should wrap this in `Task.detached`.
///
/// # Arguments
/// * `request` - The completion request containing provider, model, messages, etc.
///
/// # Returns
/// The completion response or an error
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn complete(request: LLMRequest) -> Result<LLMResponse, LLMError> {
    provider::complete_sync(&request)
}

// ============================================================================
// UniFFI Exports - Memory Management
// ============================================================================

/// Create a new memory scope for conversation persistence
///
/// # Arguments
/// * `scope_id` - Optional ID for the scope (auto-generated if not provided)
/// * `scope` - Type of scope (Document, Project, or Global)
///
/// # Returns
/// A handle to the memory scope
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn create_memory_scope(scope_id: Option<String>, scope: MemoryScope) -> MemoryHandle {
    provider::create_memory(scope_id, scope)
}

/// Add a message to a memory scope
///
/// # Arguments
/// * `handle` - The memory scope handle
/// * `message` - The message to add
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn add_message_to_memory(handle: MemoryHandle, message: LLMMessage) -> Result<(), LLMError> {
    provider::add_to_memory(&handle, message)
}

/// Get all messages from a memory scope
///
/// # Arguments
/// * `handle` - The memory scope handle
///
/// # Returns
/// All messages in the scope
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_messages_from_memory(handle: MemoryHandle) -> Result<Vec<LLMMessage>, LLMError> {
    provider::get_memory_messages(&handle)
}

/// Execute a completion with memory context
///
/// This automatically includes previous messages from the memory scope
/// and adds the new exchange to memory.
///
/// # Arguments
/// * `handle` - The memory scope handle
/// * `request` - The completion request (messages here are appended to memory context)
///
/// # Returns
/// The completion response
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn complete_with_context(
    handle: MemoryHandle,
    request: LLMRequest,
) -> Result<LLMResponse, LLMError> {
    provider::complete_with_memory(&handle, &request)
}

/// Export memory state for persistence
///
/// Use this to save memory to disk or Core Data.
///
/// # Arguments
/// * `handle` - The memory scope handle
///
/// # Returns
/// The serializable memory state
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn export_memory(handle: MemoryHandle) -> Result<MemoryState, LLMError> {
    provider::export_memory(&handle)
}

/// Import memory state from persistence
///
/// Use this to restore memory from disk or Core Data.
///
/// # Arguments
/// * `id` - The ID for the memory scope
/// * `state` - The memory state to import
///
/// # Returns
/// A handle to the restored memory scope
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn import_memory(id: String, state: MemoryState) -> MemoryHandle {
    provider::import_memory(id, state)
}

/// Clear all messages from a memory scope
///
/// # Arguments
/// * `handle` - The memory scope handle
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn clear_memory(handle: MemoryHandle) -> Result<(), LLMError> {
    provider::clear_memory(&handle)
}

// ============================================================================
// UniFFI Exports - Utilities
// ============================================================================

/// Hello from impress-llm - verify FFI is working
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn hello_from_impress_llm() -> String {
    "Hello from impress-llm (Rust)!".to_string()
}

/// Get the version of the impress-llm crate
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_impress_llm_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_list_providers() {
        let providers = list_providers();
        assert!(!providers.is_empty());

        // Check that priority providers are present
        let groq = providers.iter().find(|p| p.id == "groq");
        assert!(groq.is_some());
        assert!(groq.unwrap().requires_api_key);

        let phind = providers.iter().find(|p| p.id == "phind");
        assert!(phind.is_some());
    }

    #[test]
    fn test_list_models() {
        let models = list_models("groq".to_string());
        assert!(!models.is_empty());

        // Check default model exists
        assert!(models.iter().any(|m| m.is_default));
    }

    #[test]
    fn test_get_provider() {
        let provider = get_provider("groq".to_string());
        assert!(provider.is_some());
        assert_eq!(provider.unwrap().name, "Groq");

        let unknown = get_provider("unknown".to_string());
        assert!(unknown.is_none());
    }
}
