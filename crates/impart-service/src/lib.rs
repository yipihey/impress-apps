//! `ImpartService` — impart's research-conversation surface.
//!
//! Same shape as `implore-service`: conversations live in the running app, so
//! the default implementation refuses and `impart-service-http` does the work.
//!
//! What impart models is worth stating, because the tool names alone do not
//! convey it: a *research conversation* is a durable thread of thinking —
//! messages, the decisions that came out of them, and the artifacts they
//! produced. It is the record you mine later when writing the manuscript, which
//! is why `record_decision` and `record_artifact` exist separately from
//! `add_message`. A decision buried in a message is lost; a decision recorded
//! is one the bridges can pull into an outline.

use std::sync::{Arc, OnceLock};

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// A research conversation: a durable thread, not a chat log.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ConversationRecord {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default, alias = "messageCount")]
    pub message_count: Option<i64>,
    #[serde(default, alias = "createdAt")]
    pub created_at: Option<String>,
    #[serde(default, alias = "updatedAt")]
    pub updated_at: Option<String>,
    #[serde(default)]
    pub archived: Option<bool>,
}

/// One message in a conversation.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MessageRecord {
    pub id: String,
    #[serde(default)]
    pub role: Option<String>,
    #[serde(default)]
    pub content: String,
    #[serde(default, alias = "createdAt")]
    pub created_at: Option<String>,
}

/// One line from impart's in-memory log store.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LogEntry {
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub level: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub message: String,
}

/// Free-form app state, returned verbatim.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AppStatus {
    pub running: bool,
    pub detail: String,
}

#[impress_service]
pub trait ImpartService: Send + Sync + 'static {
    /// Whether impart is running, and its version and port.
    #[impress_method]
    async fn status(&self) -> AppStatus;

    /// Recent lines from impart's in-memory log store.
    #[impress_method]
    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry>;

    /// Research conversations, most recently updated first. START HERE: every
    /// other conversation tool takes an id from this list.
    #[impress_method]
    async fn list_conversations(
        &self,
        limit: u32,
        include_archived: bool,
    ) -> Vec<ConversationRecord>;

    /// One conversation with its messages.
    #[impress_method]
    async fn get_conversation(&self, conversation_id: String) -> Option<ConversationRecord>;

    /// Start a new research conversation.
    #[impress_method]
    async fn create_conversation(
        &self,
        title: String,
        summary: Option<String>,
    ) -> Option<ConversationRecord>;

    /// Edit a conversation's title or summary.
    #[impress_method]
    async fn update_conversation(
        &self,
        conversation_id: String,
        title: Option<String>,
        summary: Option<String>,
    ) -> bool;

    /// Append a message to a conversation. `role` is the speaker
    /// (`user`, `assistant`, a collaborator's name).
    #[impress_method]
    async fn add_message(
        &self,
        conversation_id: String,
        content: String,
        role: Option<String>,
    ) -> Option<MessageRecord>;

    /// Record a DECISION reached in a conversation, separately from the
    /// messages that led to it. Do this whenever the discussion settles
    /// something: a decision left inside a message is invisible to the tools
    /// that later assemble an outline or a methods section from the thread.
    #[impress_method]
    async fn record_decision(
        &self,
        conversation_id: String,
        decision: String,
        rationale: Option<String>,
    ) -> bool;

    /// Record an artifact a conversation produced — a figure, a dataset, a
    /// draft. Links the thinking to the thing it made.
    #[impress_method]
    async fn record_artifact(
        &self,
        conversation_id: String,
        title: String,
        kind: Option<String>,
        reference: Option<String>,
    ) -> bool;

    /// Branch a conversation from a point, to explore an alternative without
    /// losing the original thread.
    #[impress_method]
    async fn branch_conversation(
        &self,
        conversation_id: String,
        title: String,
    ) -> Option<ConversationRecord>;
}

// ---------------------------------------------------------------------------
// Default (refusing) implementation
// ---------------------------------------------------------------------------

#[derive(Clone, Default)]
pub struct DefaultImpartService;

impl DefaultImpartService {
    pub fn new() -> Self {
        Self
    }
}

fn refuse(method: &str) {
    eprintln!("[impart-service] {method}: impart not running; refused");
}

#[async_trait::async_trait]
impl ImpartService for DefaultImpartService {
    async fn status(&self) -> AppStatus {
        AppStatus {
            running: false,
            detail: "impart is not running.".into(),
        }
    }
    async fn get_logs(&self, _limit: u32, _level: Option<String>) -> Vec<LogEntry> {
        refuse("get_logs");
        vec![]
    }
    async fn list_conversations(
        &self,
        _limit: u32,
        _include_archived: bool,
    ) -> Vec<ConversationRecord> {
        refuse("list_conversations");
        vec![]
    }
    async fn get_conversation(&self, _conversation_id: String) -> Option<ConversationRecord> {
        refuse("get_conversation");
        None
    }
    async fn create_conversation(
        &self,
        _title: String,
        _summary: Option<String>,
    ) -> Option<ConversationRecord> {
        refuse("create_conversation");
        None
    }
    async fn update_conversation(
        &self,
        _conversation_id: String,
        _title: Option<String>,
        _summary: Option<String>,
    ) -> bool {
        refuse("update_conversation");
        false
    }
    async fn add_message(
        &self,
        _conversation_id: String,
        _content: String,
        _role: Option<String>,
    ) -> Option<MessageRecord> {
        refuse("add_message");
        None
    }
    async fn record_decision(
        &self,
        _conversation_id: String,
        _decision: String,
        _rationale: Option<String>,
    ) -> bool {
        refuse("record_decision");
        false
    }
    async fn record_artifact(
        &self,
        _conversation_id: String,
        _title: String,
        _kind: Option<String>,
        _reference: Option<String>,
    ) -> bool {
        refuse("record_artifact");
        false
    }
    async fn branch_conversation(
        &self,
        _conversation_id: String,
        _title: String,
    ) -> Option<ConversationRecord> {
        refuse("branch_conversation");
        None
    }
}

// ---------------------------------------------------------------------------
// Pluggable backend
// ---------------------------------------------------------------------------

pub trait ImpartBackend: Send + Sync + 'static {
    fn service(&self) -> Arc<dyn ImpartService>;
}

static BACKEND: OnceLock<Box<dyn ImpartBackend>> = OnceLock::new();

pub fn register_backend(backend: Box<dyn ImpartBackend>) {
    let _ = BACKEND.set(backend);
}

pub fn has_custom_backend() -> bool {
    BACKEND.get().is_some()
}

pub fn service_instance() -> Arc<dyn ImpartService> {
    match BACKEND.get() {
        Some(b) => b.service(),
        None => Arc::new(DefaultImpartService::new()),
    }
}

impress_service_impl! {
    service = ImpartService,
    impl = DefaultImpartService,
    instance = service_instance,
    methods = [
        status() -> AppStatus,
        get_logs(limit: u32, level: Option<String>) -> Vec<LogEntry>,
        list_conversations(limit: u32, include_archived: bool) -> Vec<ConversationRecord>,
        get_conversation(conversation_id: String) -> Option<ConversationRecord>,
        create_conversation(title: String, summary: Option<String>) -> Option<ConversationRecord>,
        update_conversation(
            conversation_id: String,
            title: Option<String>,
            summary: Option<String>
        ) -> bool,
        add_message(
            conversation_id: String,
            content: String,
            role: Option<String>
        ) -> Option<MessageRecord>,
        record_decision(
            conversation_id: String,
            decision: String,
            rationale: Option<String>
        ) -> bool,
        record_artifact(
            conversation_id: String,
            title: String,
            kind: Option<String>,
            reference: Option<String>
        ) -> bool,
        branch_conversation(conversation_id: String, title: String) -> Option<ConversationRecord>,
    ],
}
