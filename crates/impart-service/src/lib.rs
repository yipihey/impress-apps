//! `ImpartService` — impart's research-conversation surface.
//!
//! Same shape as `implore-service`: conversations live in the running app, so
//! the default implementation refuses and `impart-verbs-ffi` installs the
//! native backend that does the work.
//!
//! What impart models is worth stating, because the tool names alone do not
//! convey it: a *research conversation* is a durable thread of thinking —
//! messages, the decisions that came out of them, and the artifacts they
//! produced. It is the record you mine later when writing the manuscript, which
//! is why `record_decision` and `record_artifact` exist separately from
//! `add_message`. A decision buried in a message is lost; a decision recorded
//! is one the bridges can pull into an outline.

use std::sync::Arc;

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
    #[serde(default, alias = "isArchived")]
    pub archived: Option<bool>,
    #[serde(default)]
    pub participants: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default, alias = "parentConversationId")]
    pub parent_conversation_id: Option<String>,
    #[serde(default, alias = "lastActivityAt")]
    pub last_activity_at: Option<String>,
    #[serde(default, alias = "summaryText")]
    pub summary_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages: Option<Vec<ConversationMessageRecord>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub statistics: Option<ConversationStatistics>,
}

/// A message in the detailed conversation read, retaining every field in
/// the former `GET /api/research/conversations/{id}` response.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ConversationMessageRecord {
    pub id: String,
    pub sequence: u32,
    #[serde(alias = "senderRole")]
    pub sender_role: String,
    #[serde(alias = "senderId")]
    pub sender_id: String,
    #[serde(default, alias = "modelUsed")]
    pub model_used: Option<String>,
    #[serde(alias = "contentMarkdown")]
    pub content_markdown: String,
    #[serde(alias = "sentAt")]
    pub sent_at: String,
    #[serde(default, alias = "tokenCount")]
    pub token_count: Option<i64>,
    #[serde(default, alias = "processingDurationMs")]
    pub processing_duration_ms: Option<i64>,
    #[serde(default, alias = "mentionedArtifactURIs")]
    pub mentioned_artifact_uris: Vec<String>,
}

/// Computed statistics returned with a conversation detail read.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ConversationStatistics {
    #[serde(alias = "messageCount")]
    pub message_count: u32,
    #[serde(alias = "humanMessageCount")]
    pub human_message_count: u32,
    #[serde(alias = "counselMessageCount")]
    pub counsel_message_count: u32,
    #[serde(alias = "artifactCount")]
    pub artifact_count: u32,
    #[serde(alias = "paperCount")]
    pub paper_count: u32,
    #[serde(alias = "repositoryCount")]
    pub repository_count: u32,
    #[serde(alias = "totalTokens")]
    pub total_tokens: u64,
    pub duration: f64,
    #[serde(alias = "branchCount")]
    pub branch_count: u32,
}

/// Page metadata for the most-recent-first conversation index.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ConversationList {
    pub conversations: Vec<ConversationRecord>,
    /// Number of rows in this page (`count` in the HTTP envelope).
    pub count: u32,
    /// Number of matching rows before pagination.
    pub total: u32,
    pub offset: u32,
    pub limit: u32,
    pub include_archived: bool,
    /// Optional case-insensitive title/summary filter.
    pub query: Option<String>,
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
    // G3 Tier B examples require an isolated running impart host with a
    // scratch Core Data conversation 5b...0011 titled "G3 research fixture".
    // Reset it before each example; decision provenance is process-local.
    /// Whether impart is running, and its version and port.
    #[impress_method]
    #[impress_example(
        name = "isolated_app_status",
        tier = "b",
        args = r#"{}"#,
        expect = r#"{"running":true}"#
    )]
    async fn status(&self) -> AppStatus;

    /// Recent lines from impart's in-memory log store.
    #[impress_method]
    #[impress_example(
        name = "recent_research_logs",
        tier = "b",
        args = r#"{"limit":10,"level":"info,warning,error"}"#
    )]
    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry>;

    /// Research conversations, most recently updated first. START HERE: every
    /// other conversation tool takes an id from this list.
    #[impress_method]
    #[impress_example(
        name = "recent_research_threads",
        tier = "b",
        args = r#"{"limit":20,"include_archived":false}"#
    )]
    async fn list_conversations(
        &self,
        limit: u32,
        include_archived: bool,
        offset: Option<u32>,
        query: Option<String>,
    ) -> ConversationList;

    /// One conversation's complete detail, including its ordered messages and
    /// computed statistics.
    #[impress_method]
    #[impress_example(
        name = "read_fixture_thread",
        tier = "b",
        args = r#"{"conversation_id":"5b000000-0000-4000-8000-000000000011"}"#,
        expect = r#"{"id":"5b000000-0000-4000-8000-000000000011","title":"G3 research fixture"}"#
    )]
    async fn get_conversation(&self, conversation_id: String) -> Option<ConversationRecord>;

    /// Start a new research conversation.
    #[impress_method]
    #[impress_example(
        name = "start_research_thread",
        tier = "b",
        args = r#"{"title":"G3 alternative hypothesis","summary":"Compare two interpretations of the fixture evidence."}"#,
        expect = r#"{"title":"G3 alternative hypothesis","summary":"Compare two interpretations of the fixture evidence."}"#
    )]
    async fn create_conversation(
        &self,
        title: String,
        summary: Option<String>,
    ) -> Option<ConversationRecord>;

    /// Edit a conversation's title or summary.
    #[impress_method]
    #[impress_example(
        name = "summarize_fixture_thread",
        tier = "b",
        args = r#"{"conversation_id":"5b000000-0000-4000-8000-000000000011","summary":"The fixture evidence supports a revision."}"#,
        expect = "true"
    )]
    async fn update_conversation(
        &self,
        conversation_id: String,
        title: Option<String>,
        summary: Option<String>,
    ) -> bool;

    /// Append a message to a conversation. `role` is the speaker
    /// (`user`, `assistant`, a collaborator's name).
    #[impress_method]
    #[impress_example(
        name = "append_fixture_observation",
        tier = "b",
        args = r#"{"conversation_id":"5b000000-0000-4000-8000-000000000011","content":"The fixture result needs a second check.","role":"user"}"#,
        expect = r#"{"role":"user","content":"The fixture result needs a second check."}"#
    )]
    async fn add_message(
        &self,
        conversation_id: String,
        content: String,
        role: Option<String>,
    ) -> Option<MessageRecord>;

    /// Record a DECISION reached in a conversation in the running app's
    /// process-local provenance. This is separate from the durable messages
    /// and does not survive an app restart.
    #[impress_method]
    #[impress_example(
        name = "record_fixture_decision",
        tier = "b",
        args = r#"{"conversation_id":"5b000000-0000-4000-8000-000000000011","decision":"Retain the control group.","rationale":"It distinguishes the competing interpretations."}"#,
        expect = "true"
    )]
    async fn record_decision(
        &self,
        conversation_id: String,
        decision: String,
        rationale: Option<String>,
    ) -> bool;

    /// Record an artifact a conversation produced — a figure, a dataset, a
    /// draft. Links the thinking to the thing it made.
    #[impress_method]
    #[impress_example(
        name = "link_fixture_paper",
        tier = "b",
        args = r#"{"conversation_id":"5b000000-0000-4000-8000-000000000011","title":"Fixture paper","kind":"paper","reference":"impress://imbib/papers/g3-fixture"}"#,
        expect = "true"
    )]
    async fn record_artifact(
        &self,
        conversation_id: String,
        title: String,
        kind: Option<String>,
        reference: Option<String>,
    ) -> bool;

    /// Branch a conversation to explore an alternative without losing the
    /// original thread. The current verb links the parent conversation, not
    /// a particular message or branch point.
    #[impress_method]
    #[impress_example(
        name = "branch_fixture_thread",
        tier = "b",
        args = r#"{"conversation_id":"5b000000-0000-4000-8000-000000000011","title":"G3 counter-hypothesis"}"#,
        expect = r#"{"title":"G3 counter-hypothesis"}"#
    )]
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
        limit: u32,
        include_archived: bool,
        offset: Option<u32>,
        query: Option<String>,
    ) -> ConversationList {
        refuse("list_conversations");
        ConversationList {
            conversations: vec![],
            count: 0,
            total: 0,
            offset: offset.unwrap_or(0),
            limit: if limit == 0 { 20 } else { limit.min(1_000) },
            include_archived,
            query,
        }
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

static BACKEND: impress_service_core::BackendSlot<dyn ImpartBackend> =
    impress_service_core::BackendSlot::new();

pub fn register_backend(backend: Box<dyn ImpartBackend>) {
    BACKEND.install(std::sync::Arc::from(backend));
}

/// Uninstall the current backend: dispatch returns to the default
/// implementation — see [`impress_service_core::BackendSlot`].
pub fn clear_backend() {
    BACKEND.clear();
}

pub fn has_custom_backend() -> bool {
    BACKEND.is_installed()
}

pub fn service_instance() -> Arc<dyn ImpartService> {
    match BACKEND.get() {
        Some(b) => b.service(),
        None => Arc::new(DefaultImpartService::new()),
    }
}

impress_service_impl! {
    service = ImpartService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [app("impart")],
    },
    impl = DefaultImpartService,
    instance = service_instance,
    methods = [
        status() -> AppStatus,
        get_logs(
            /// Maximum recent log entries to return.
            limit: u32,
            /// Comma-separated log levels; omit for every level.
            level: Option<String>
        ) -> Vec<LogEntry>,
        list_conversations(
            /// Maximum conversations to return, capped at 1,000.
            limit: u32,
            /// Include archived research conversations when true.
            include_archived: bool,
            /// Number of matching conversations to skip before this page.
            offset: Option<u32>,
            /// Optional case-insensitive title/summary substring filter.
            query: Option<String>
        ) -> ConversationList,
        get_conversation(
            /// UUID of the research conversation to read.
            conversation_id: String
        ) -> Option<ConversationRecord>,
        create_conversation(
            /// Title for the new research conversation.
            title: String,
            /// Optional opening summary of its research question.
            summary: Option<String>
        ) -> Option<ConversationRecord>,
        update_conversation(
            /// UUID of the conversation to edit.
            conversation_id: String,
            /// Replacement title; omit to retain the current title.
            title: Option<String>,
            /// Replacement summary; omit to retain the current summary.
            summary: Option<String>
        ) -> bool,
        add_message(
            /// UUID of the conversation receiving the message.
            conversation_id: String,
            /// Message Markdown to append; kept private in call logs.
            #[impress_private] content: String,
            /// Speaker role or collaborator name; omit for `user`.
            role: Option<String>
        ) -> Option<MessageRecord>,
        record_decision(
            /// UUID of the conversation in which the decision was reached.
            conversation_id: String,
            /// Decision statement retained as process-local provenance.
            decision: String,
            /// Optional reasoning for this decision.
            rationale: Option<String>
        ) -> bool,
        record_artifact(
            /// UUID of the conversation that produced or referenced the artifact.
            conversation_id: String,
            /// Human-readable artifact title.
            title: String,
            /// Artifact type matching the `impress://` URI, such as `paper`.
            kind: Option<String>,
            /// `impress://` artifact URI to attach to the conversation.
            reference: Option<String>
        ) -> bool,
        branch_conversation(
            /// UUID of the parent conversation to branch.
            conversation_id: String,
            /// Title for the new alternative research thread.
            title: String
        ) -> Option<ConversationRecord>,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_detail_reads_legacy_route_fields_without_loss() {
        let record: ConversationRecord = serde_json::from_value(serde_json::json!({
            "id": "5b000000-0000-4000-8000-000000000011",
            "title": "Research",
            "summaryText": "Working summary",
            "participants": ["person@example.org"],
            "createdAt": "2026-09-29T10:00:00Z",
            "lastActivityAt": "2026-09-29T10:05:00Z",
            "isArchived": false,
            "tags": ["analysis"],
            "parentConversationId": "5b000000-0000-4000-8000-000000000010",
            "messages": [{
                "id": "5b000000-0000-4000-8000-000000000012",
                "sequence": 1,
                "senderRole": "human",
                "senderId": "person@example.org",
                "modelUsed": null,
                "contentMarkdown": "Evidence",
                "sentAt": "2026-09-29T10:05:00Z",
                "tokenCount": null,
                "processingDurationMs": null,
                "mentionedArtifactURIs": []
            }],
            "statistics": {
                "messageCount": 1,
                "humanMessageCount": 1,
                "counselMessageCount": 0,
                "artifactCount": 0,
                "paperCount": 0,
                "repositoryCount": 0,
                "totalTokens": 0,
                "duration": 0.0,
                "branchCount": 0
            }
        }))
        .unwrap();
        assert_eq!(record.participants, vec!["person@example.org".to_owned()]);
        assert_eq!(record.tags, vec!["analysis".to_owned()]);
        assert_eq!(record.archived, Some(false));
        assert_eq!(
            record.parent_conversation_id.as_deref(),
            Some("5b000000-0000-4000-8000-000000000010")
        );
        assert_eq!(
            record.last_activity_at.as_deref(),
            Some("2026-09-29T10:05:00Z")
        );
        assert_eq!(record.summary_text, "Working summary");
        let message = &record.messages.as_ref().unwrap()[0];
        assert_eq!(message.sender_role, "human");
        assert_eq!(message.content_markdown, "Evidence");
        assert_eq!(record.statistics.as_ref().unwrap().human_message_count, 1);

        let encoded = serde_json::to_value(record).unwrap();
        assert_eq!(encoded["messages"][0]["sender_role"], "human");
        assert_eq!(encoded["statistics"]["human_message_count"], 1);
    }

    #[test]
    fn conversation_list_carries_page_count_and_filter_metadata() {
        let page = ConversationList {
            conversations: vec![],
            count: 0,
            total: 7,
            offset: 5,
            limit: 10,
            include_archived: true,
            query: Some("evidence".into()),
        };
        let encoded = serde_json::to_value(page).unwrap();
        assert_eq!(encoded["count"], 0);
        assert_eq!(encoded["total"], 7);
        assert_eq!(encoded["offset"], 5);
        assert_eq!(encoded["limit"], 10);
        assert_eq!(encoded["include_archived"], true);
        assert_eq!(encoded["query"], "evidence");
    }
}
