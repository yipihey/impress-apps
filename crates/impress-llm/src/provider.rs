//! Provider implementations wrapping graniet/llm backends
//!
//! This module provides the bridge between our FFI types and the graniet/llm library.

use crate::types::*;
use llm::builder::{LLMBackend, LLMBuilder};
use llm::chat::ChatMessage;
use llm::error::LLMError as LLMLibError;
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::runtime::Runtime;
use uuid::Uuid;

// ============================================================================
// Tokio Runtime for blocking calls
// ============================================================================

/// Get or create a tokio runtime for executing async calls
fn get_runtime() -> &'static Runtime {
    static RUNTIME: std::sync::OnceLock<Runtime> = std::sync::OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().expect("Failed to create tokio runtime"))
}

// ============================================================================
// Provider Registry
// ============================================================================

/// Get information about all supported providers
pub fn get_providers() -> Vec<ProviderInfo> {
    vec![
        ProviderInfo {
            id: "groq".to_string(),
            name: "Groq".to_string(),
            description: "Ultra-fast inference with LPU technology. Excellent for interactive use."
                .to_string(),
            registration_url: Some("https://console.groq.com/keys".to_string()),
            requires_api_key: true,
            default_model: "llama-3.3-70b-versatile".to_string(),
            category: "cloud".to_string(),
        },
        ProviderInfo {
            id: "phind".to_string(),
            name: "Phind".to_string(),
            description: "Code-optimized AI with fast responses. Great for programming tasks."
                .to_string(),
            registration_url: Some("https://www.phind.com/api".to_string()),
            requires_api_key: true,
            default_model: "Phind-70B".to_string(),
            category: "cloud".to_string(),
        },
        ProviderInfo {
            id: "mistral".to_string(),
            name: "Mistral AI".to_string(),
            description: "European AI with strong multilingual capabilities.".to_string(),
            registration_url: Some("https://console.mistral.ai/api-keys/".to_string()),
            requires_api_key: true,
            default_model: "mistral-large-latest".to_string(),
            category: "cloud".to_string(),
        },
        ProviderInfo {
            id: "cohere".to_string(),
            name: "Cohere".to_string(),
            description: "Enterprise-focused AI with strong RAG capabilities.".to_string(),
            registration_url: Some("https://dashboard.cohere.com/api-keys".to_string()),
            requires_api_key: true,
            default_model: "command-r-plus".to_string(),
            category: "cloud".to_string(),
        },
        ProviderInfo {
            id: "deepseek".to_string(),
            name: "DeepSeek".to_string(),
            description: "Affordable AI with strong reasoning capabilities.".to_string(),
            registration_url: Some("https://platform.deepseek.com/api_keys".to_string()),
            requires_api_key: true,
            default_model: "deepseek-chat".to_string(),
            category: "cloud".to_string(),
        },
        ProviderInfo {
            id: "xai".to_string(),
            name: "xAI (Grok)".to_string(),
            description: "Grok models from xAI with real-time knowledge.".to_string(),
            registration_url: Some("https://console.x.ai/".to_string()),
            requires_api_key: true,
            default_model: "grok-beta".to_string(),
            category: "cloud".to_string(),
        },
        ProviderInfo {
            id: "huggingface".to_string(),
            name: "HuggingFace Inference".to_string(),
            description: "Access to thousands of open-source models.".to_string(),
            registration_url: Some("https://huggingface.co/settings/tokens".to_string()),
            requires_api_key: true,
            default_model: "meta-llama/Meta-Llama-3-8B-Instruct".to_string(),
            category: "cloud".to_string(),
        },
    ]
}

/// Get models available for a specific provider
pub fn get_models(provider: &str) -> Vec<ModelInfo> {
    match provider {
        "groq" => vec![
            ModelInfo {
                id: "llama-3.3-70b-versatile".to_string(),
                name: "Llama 3.3 70B Versatile".to_string(),
                description: Some(
                    "Latest Llama model, excellent all-around performance".to_string(),
                ),
                context_window: Some(128_000),
                max_output_tokens: Some(32_768),
                is_default: true,
            },
            ModelInfo {
                id: "llama-3.1-70b-versatile".to_string(),
                name: "Llama 3.1 70B Versatile".to_string(),
                description: Some("Previous generation Llama, very capable".to_string()),
                context_window: Some(128_000),
                max_output_tokens: Some(32_768),
                is_default: false,
            },
            ModelInfo {
                id: "llama-3.1-8b-instant".to_string(),
                name: "Llama 3.1 8B Instant".to_string(),
                description: Some("Smaller, faster model for quick tasks".to_string()),
                context_window: Some(128_000),
                max_output_tokens: Some(8_192),
                is_default: false,
            },
            ModelInfo {
                id: "mixtral-8x7b-32768".to_string(),
                name: "Mixtral 8x7B".to_string(),
                description: Some("Mixture of experts model, fast and efficient".to_string()),
                context_window: Some(32_768),
                max_output_tokens: Some(32_768),
                is_default: false,
            },
            ModelInfo {
                id: "gemma2-9b-it".to_string(),
                name: "Gemma 2 9B".to_string(),
                description: Some("Google's efficient open model".to_string()),
                context_window: Some(8_192),
                max_output_tokens: Some(8_192),
                is_default: false,
            },
        ],
        "phind" => vec![ModelInfo {
            id: "Phind-70B".to_string(),
            name: "Phind 70B".to_string(),
            description: Some("Code-optimized model, excellent for programming".to_string()),
            context_window: Some(32_000),
            max_output_tokens: Some(4_096),
            is_default: true,
        }],
        "mistral" => vec![
            ModelInfo {
                id: "mistral-large-latest".to_string(),
                name: "Mistral Large".to_string(),
                description: Some("Most capable Mistral model".to_string()),
                context_window: Some(128_000),
                max_output_tokens: Some(128_000),
                is_default: true,
            },
            ModelInfo {
                id: "mistral-medium-latest".to_string(),
                name: "Mistral Medium".to_string(),
                description: Some("Balanced performance and cost".to_string()),
                context_window: Some(32_000),
                max_output_tokens: Some(32_000),
                is_default: false,
            },
            ModelInfo {
                id: "mistral-small-latest".to_string(),
                name: "Mistral Small".to_string(),
                description: Some("Fast and efficient".to_string()),
                context_window: Some(32_000),
                max_output_tokens: Some(32_000),
                is_default: false,
            },
            ModelInfo {
                id: "codestral-latest".to_string(),
                name: "Codestral".to_string(),
                description: Some("Specialized for code generation".to_string()),
                context_window: Some(32_000),
                max_output_tokens: Some(32_000),
                is_default: false,
            },
        ],
        "cohere" => vec![
            ModelInfo {
                id: "command-r-plus".to_string(),
                name: "Command R+".to_string(),
                description: Some(
                    "Most capable Cohere model, excellent for complex tasks".to_string(),
                ),
                context_window: Some(128_000),
                max_output_tokens: Some(4_096),
                is_default: true,
            },
            ModelInfo {
                id: "command-r".to_string(),
                name: "Command R".to_string(),
                description: Some("Balanced model for general use".to_string()),
                context_window: Some(128_000),
                max_output_tokens: Some(4_096),
                is_default: false,
            },
            ModelInfo {
                id: "command".to_string(),
                name: "Command".to_string(),
                description: Some("Fast model for simple tasks".to_string()),
                context_window: Some(4_096),
                max_output_tokens: Some(4_096),
                is_default: false,
            },
        ],
        "deepseek" => vec![
            ModelInfo {
                id: "deepseek-chat".to_string(),
                name: "DeepSeek Chat".to_string(),
                description: Some("General-purpose chat model".to_string()),
                context_window: Some(64_000),
                max_output_tokens: Some(4_096),
                is_default: true,
            },
            ModelInfo {
                id: "deepseek-coder".to_string(),
                name: "DeepSeek Coder".to_string(),
                description: Some("Specialized for code generation".to_string()),
                context_window: Some(64_000),
                max_output_tokens: Some(4_096),
                is_default: false,
            },
            ModelInfo {
                id: "deepseek-reasoner".to_string(),
                name: "DeepSeek Reasoner".to_string(),
                description: Some("Advanced reasoning capabilities (R1)".to_string()),
                context_window: Some(64_000),
                max_output_tokens: Some(8_192),
                is_default: false,
            },
        ],
        "xai" => vec![
            ModelInfo {
                id: "grok-beta".to_string(),
                name: "Grok Beta".to_string(),
                description: Some("xAI's flagship model".to_string()),
                context_window: Some(128_000),
                max_output_tokens: Some(4_096),
                is_default: true,
            },
            ModelInfo {
                id: "grok-2-1212".to_string(),
                name: "Grok 2".to_string(),
                description: Some("Latest Grok model".to_string()),
                context_window: Some(128_000),
                max_output_tokens: Some(4_096),
                is_default: false,
            },
        ],
        "huggingface" => vec![
            ModelInfo {
                id: "meta-llama/Meta-Llama-3-8B-Instruct".to_string(),
                name: "Llama 3 8B Instruct".to_string(),
                description: Some("Meta's instruction-tuned Llama".to_string()),
                context_window: Some(8_192),
                max_output_tokens: Some(4_096),
                is_default: true,
            },
            ModelInfo {
                id: "mistralai/Mistral-7B-Instruct-v0.3".to_string(),
                name: "Mistral 7B Instruct".to_string(),
                description: Some("Efficient instruction model".to_string()),
                context_window: Some(32_768),
                max_output_tokens: Some(4_096),
                is_default: false,
            },
        ],
        _ => vec![],
    }
}

// ============================================================================
// Completion Implementation
// ============================================================================

/// Map our provider ID to llm backend
fn get_backend(provider: &str) -> Result<LLMBackend, LLMError> {
    match provider {
        "groq" => Ok(LLMBackend::Groq),
        "phind" => Ok(LLMBackend::Phind),
        "mistral" => Ok(LLMBackend::Mistral),
        "cohere" => Ok(LLMBackend::Cohere),
        "deepseek" => Ok(LLMBackend::DeepSeek),
        "xai" => Ok(LLMBackend::XAI),
        "huggingface" => Ok(LLMBackend::HuggingFace),
        _ => Err(LLMError::ProviderNotFound {
            provider: provider.to_string(),
        }),
    }
}

/// Execute a completion request (blocking wrapper around async)
pub fn complete_sync(request: &LLMRequest) -> Result<LLMResponse, LLMError> {
    let runtime = get_runtime();
    runtime.block_on(complete_async(request))
}

/// Execute a completion request (async)
async fn complete_async(request: &LLMRequest) -> Result<LLMResponse, LLMError> {
    let backend = get_backend(&request.provider)?;

    // Build the LLM client
    let mut builder = LLMBuilder::new()
        .backend(backend)
        .api_key(&request.api_key)
        .model(&request.model);

    // Set optional parameters
    if let Some(max_tokens) = request.max_tokens {
        builder = builder.max_tokens(max_tokens);
    }
    if let Some(temp) = request.temperature {
        builder = builder.temperature(temp);
    }
    if let Some(top_p) = request.top_p {
        builder = builder.top_p(top_p);
    }

    // Build the client
    let llm = builder
        .build()
        .map_err(|e: llm::error::LLMError| LLMError::InvalidRequest {
            message: e.to_string(),
        })?;

    // Convert messages - handle system message specially
    let mut chat_messages = Vec::new();
    let mut system_prompt = None;

    for msg in &request.messages {
        match msg.role {
            LLMRole::System => {
                // graniet/llm doesn't have a system role in ChatMessage,
                // we'll need to prepend it to the first user message
                system_prompt = Some(msg.content.clone());
            }
            LLMRole::User => {
                let content = if let Some(sys) = system_prompt.take() {
                    format!("{}\n\n{}", sys, msg.content)
                } else {
                    msg.content.clone()
                };
                chat_messages.push(ChatMessage::user().content(&content).build());
            }
            LLMRole::Assistant => {
                chat_messages.push(ChatMessage::assistant().content(&msg.content).build());
            }
        }
    }

    // If we only have a system prompt and no user messages, treat it as a user message
    if chat_messages.is_empty() {
        if let Some(sys) = system_prompt {
            chat_messages.push(ChatMessage::user().content(&sys).build());
        }
    }

    // Execute the chat
    let response = llm.chat(&chat_messages).await.map_err(|e: LLMLibError| {
        let err_str = e.to_string().to_lowercase();
        if err_str.contains("rate limit") || err_str.contains("429") {
            LLMError::RateLimited {
                retry_after_seconds: Some(60),
            }
        } else if err_str.contains("unauthorized")
            || err_str.contains("401")
            || err_str.contains("invalid api key")
            || err_str.contains("invalid_api_key")
        {
            LLMError::InvalidApiKey
        } else if err_str.contains("network") || err_str.contains("connection") {
            LLMError::NetworkError {
                message: e.to_string(),
            }
        } else if err_str.contains("context") && err_str.contains("length") {
            LLMError::ContextLengthExceeded {
                message: e.to_string(),
            }
        } else {
            LLMError::ApiError {
                message: e.to_string(),
            }
        }
    })?;

    // Extract the text content
    let content = response.text().unwrap_or_default().to_string();

    // Extract usage info if available
    let tokens_used = response.usage().map(|u| u.total_tokens as u32);

    Ok(LLMResponse {
        content,
        tokens_used,
        finish_reason: "stop".to_string(),
        model: request.model.clone(),
    })
}

// ============================================================================
// Memory Management
// ============================================================================

/// Global memory storage
static MEMORY_STORE: Mutex<Option<MemoryStore>> = Mutex::new(None);

struct MemoryStore {
    memories: HashMap<String, MemoryState>,
}

impl MemoryStore {
    fn new() -> Self {
        Self {
            memories: HashMap::new(),
        }
    }

    fn get_or_init() -> std::sync::MutexGuard<'static, Option<MemoryStore>> {
        let mut store = MEMORY_STORE.lock().unwrap();
        if store.is_none() {
            *store = Some(MemoryStore::new());
        }
        store
    }
}

/// Create a new memory scope
pub fn create_memory(scope_id: Option<String>, scope: MemoryScope) -> MemoryHandle {
    let id = scope_id.unwrap_or_else(|| Uuid::new_v4().to_string());

    let mut store_guard = MemoryStore::get_or_init();
    let store = store_guard.as_mut().unwrap();

    // Create empty memory state if it doesn't exist
    store
        .memories
        .entry(id.clone())
        .or_insert_with(|| MemoryState {
            messages: vec![],
            metadata: HashMap::new(),
            scope,
            last_updated: chrono::Utc::now().timestamp(),
        });

    MemoryHandle {
        id,
        scope_name: None,
    }
}

/// Add a message to memory
pub fn add_to_memory(handle: &MemoryHandle, message: LLMMessage) -> Result<(), LLMError> {
    let mut store_guard = MemoryStore::get_or_init();
    let store = store_guard.as_mut().unwrap();

    let memory = store
        .memories
        .get_mut(&handle.id)
        .ok_or_else(|| LLMError::Unknown {
            message: format!("Memory scope not found: {}", handle.id),
        })?;

    memory.messages.push(message);
    memory.last_updated = chrono::Utc::now().timestamp();

    Ok(())
}

/// Get all messages from memory
pub fn get_memory_messages(handle: &MemoryHandle) -> Result<Vec<LLMMessage>, LLMError> {
    let store_guard = MemoryStore::get_or_init();
    let store = store_guard.as_ref().unwrap();

    let memory = store
        .memories
        .get(&handle.id)
        .ok_or_else(|| LLMError::Unknown {
            message: format!("Memory scope not found: {}", handle.id),
        })?;

    Ok(memory.messages.clone())
}

/// Export memory state for persistence
pub fn export_memory(handle: &MemoryHandle) -> Result<MemoryState, LLMError> {
    let store_guard = MemoryStore::get_or_init();
    let store = store_guard.as_ref().unwrap();

    let memory = store
        .memories
        .get(&handle.id)
        .ok_or_else(|| LLMError::Unknown {
            message: format!("Memory scope not found: {}", handle.id),
        })?;

    Ok(memory.clone())
}

/// Import memory state from persistence
pub fn import_memory(id: String, state: MemoryState) -> MemoryHandle {
    let mut store_guard = MemoryStore::get_or_init();
    let store = store_guard.as_mut().unwrap();

    store.memories.insert(id.clone(), state);

    MemoryHandle {
        id,
        scope_name: None,
    }
}

/// Clear memory for a scope
pub fn clear_memory(handle: &MemoryHandle) -> Result<(), LLMError> {
    let mut store_guard = MemoryStore::get_or_init();
    let store = store_guard.as_mut().unwrap();

    if let Some(memory) = store.memories.get_mut(&handle.id) {
        memory.messages.clear();
        memory.last_updated = chrono::Utc::now().timestamp();
    }

    Ok(())
}

/// Complete with memory context
pub fn complete_with_memory(
    handle: &MemoryHandle,
    request: &LLMRequest,
) -> Result<LLMResponse, LLMError> {
    // Get existing messages from memory
    let mut messages = get_memory_messages(handle)?;

    // Add new messages from request
    messages.extend(request.messages.clone());

    // Create modified request with full context
    let full_request = LLMRequest {
        messages,
        ..request.clone()
    };

    // Execute completion
    let response = complete_sync(&full_request)?;

    // Add the user's last message and assistant response to memory
    if let Some(last_user_msg) = request.messages.last() {
        add_to_memory(handle, last_user_msg.clone())?;
    }
    add_to_memory(
        handle,
        LLMMessage {
            role: LLMRole::Assistant,
            content: response.content.clone(),
        },
    )?;

    Ok(response)
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_provider_registry() {
        let providers = get_providers();
        assert!(!providers.is_empty());
        assert!(providers.iter().any(|p| p.id == "groq"));
        assert!(providers.iter().any(|p| p.id == "phind"));
    }

    #[test]
    fn test_model_registry() {
        let groq_models = get_models("groq");
        assert!(!groq_models.is_empty());
        assert!(groq_models.iter().any(|m| m.is_default));

        let unknown_models = get_models("unknown_provider");
        assert!(unknown_models.is_empty());
    }

    #[test]
    fn test_backend_mapping() {
        assert!(get_backend("groq").is_ok());
        assert!(get_backend("phind").is_ok());
        assert!(get_backend("unknown").is_err());
    }

    #[test]
    fn test_memory_operations() {
        let handle = create_memory(Some("test-scope".to_string()), MemoryScope::Document);

        let msg = LLMMessage {
            role: LLMRole::User,
            content: "Hello".to_string(),
        };
        add_to_memory(&handle, msg).unwrap();

        let messages = get_memory_messages(&handle).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].content, "Hello");

        clear_memory(&handle).unwrap();
        let messages = get_memory_messages(&handle).unwrap();
        assert!(messages.is_empty());
    }
}
