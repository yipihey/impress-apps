//! Provenance-first AI infrastructure for the Impress suite.
//!
//! This crate is the integration successor to the standalone LocalModels
//! core. It keeps transport-neutral oMLX request/stream handling, but uses the
//! shared `impress-core` item graph as the only conversation authority.

pub mod blob;
pub mod catalogue;
pub mod error;
pub mod executor;
pub mod migration;
pub mod omlx;
pub mod presentation;
pub mod provider;
pub mod providers;
pub mod research;
pub mod secret;
pub mod sse;
pub mod store;
pub mod tools;
pub mod types;
pub mod worker;

pub use blob::{BlobDescriptor, BlobStore, FileBlobStore};
pub use catalogue::{ProviderDescriptor, CATALOGUE};
pub use error::{Error, Result};
pub use executor::{AiTaskExecutor, AiTitleTaskExecutor, OmlxTaskExecutor};
pub use migration::{migrate_localmodels, LocalModelsMigrationReport};
pub use omlx::{EventStream, OmlxClient};
pub use presentation::{
    tool_options_for_policy, AiAttachmentRow, AiConversationRow, AiConversationView, AiMessageRow,
    AiTaskRow, AiToolInvocationRow, AiToolOption, AiWebSourceRow,
};
pub use provider::{collect_stream, Completion, HealthState, InferenceProvider, ProviderHealth};
pub use providers::{AnthropicClient, OpenAiCompatibleClient};
pub use research::{ResearchContext, ResearchContextProvider, ResearchSource, WebResearchProvider};
pub use secret::Secret;
pub use store::{
    AiStore, ConversationDraft, ConversationSnapshot, MessageDraft, PreparedTurn, QueuedTurn,
    RunProvenance, TaskProgress, INFERENCE_TASK_KIND, TITLE_SUGGESTION_TASK_KIND,
};
pub use tools::{PendingToolCall, ToolAdapter};
pub use types::*;
pub use worker::{
    read_worker_status, write_worker_status, WorkerLease, WorkerLifecycleState,
    WorkerStatusSnapshot, WORKER_HEARTBEAT_INTERVAL_SECS, WORKER_PROTOCOL_VERSION,
    WORKER_STALE_AFTER_SECS,
};
