//! Generated management surface for the provenance-first Impress AI core.
//!
//! This crate contains no second implementation of AI behavior. Each method
//! delegates to [`impress_ai::AiStore`] over the same shared item store used by
//! every Impress app. `#[impress_service]` projects the trait into MCP, the
//! `impress` CLI, and impel's generated tool inventory together.

use std::sync::{Arc, OnceLock};

use impress_ai::{
    AiStore, ConversationDraft, ConversationSnapshot, InferenceProvider, MessageDraft,
    ModelSummary, OmlxClient, RunProvenance, TaskProgress, ToolPolicy,
};
use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelsResult {
    pub models: Vec<ModelSummary>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationsResult {
    pub conversations: Vec<impress_core::Item>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationResult {
    pub conversation: Option<ConversationSnapshot>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationMutationResult {
    pub success: bool,
    pub conversation_id: Option<Uuid>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueuedMessageResult {
    pub success: bool,
    pub conversation_id: Option<Uuid>,
    pub message_id: Option<Uuid>,
    pub task_id: Option<Uuid>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskStatusResult {
    pub task: Option<TaskProgress>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvenanceResult {
    pub provenance: Option<RunProvenance>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiHealthResult {
    /// False when the daemon is unreachable (fields then default to zero).
    pub daemon_reachable: bool,
    pub db_bytes: u64,
    pub wal_bytes: u64,
    pub wal_budget_bytes: u64,
    pub freelist_pages: u64,
    /// Whether the daemon held the maintenance lease on its last cycle.
    pub lease_owner: bool,
    pub last_checkpoint_ms: Option<i64>,
    pub last_compaction_ms: Option<i64>,
    pub last_demotion_count: Option<u64>,
    pub last_vacuum_ms: Option<i64>,
    /// Operations minted in the trailing 24 h (churn-rate telemetry).
    pub ops_last_24h: Option<u64>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingLinkResult {
    /// Single-use link against the loopback origin. When the Mac is fronted
    /// by an HTTPS proxy (tailscale serve), replace the origin and keep the
    /// fragment — the ticket rides in `#pair=` so it never enters logs.
    pub url_local: Option<String>,
    pub ticket: Option<String>,
    pub expires_in_secs: u32,
    pub error: Option<String>,
}

#[impress_service]
pub trait ImpressAiService: Send + Sync + 'static {
    /// List models reachable through the configured inference provider,
    /// including load state, context limit, and advertised modalities.
    #[impress_method]
    async fn list_models(&self) -> ModelsResult;

    /// List durable AI conversations from the shared Impress item graph.
    #[impress_method]
    async fn list_conversations(&self, include_archived: bool) -> ConversationsResult;

    /// Read a conversation with its ordered messages and pending durable
    /// response tasks.
    #[impress_method]
    async fn get_conversation(&self, conversation_id: String) -> ConversationResult;

    /// Create a durable conversation. Enabled tools are stable capability ids
    /// such as `scix`, `impress-mcp`, and `web`.
    #[impress_method]
    #[allow(clippy::too_many_arguments)]
    async fn create_conversation(
        &self,
        title: String,
        model: String,
        provider: Option<String>,
        system_prompt: Option<String>,
        temperature: f32,
        max_tokens: u32,
        thinking: bool,
        web_access: bool,
        enabled_tools: Vec<String>,
    ) -> ConversationMutationResult;

    /// Atomically append a user message and queue its offline-capable response
    /// task. Attachment ids must already identify content-blob items.
    #[impress_method]
    async fn queue_message(
        &self,
        conversation_id: String,
        body: String,
        attachment_ids: Vec<String>,
    ) -> QueuedMessageResult;

    /// Replace the conversation's enabled tool-capability policy.
    #[impress_method]
    async fn set_enabled_tools(
        &self,
        conversation_id: String,
        enabled_tools: Vec<String>,
    ) -> ConversationMutationResult;

    /// Read durable scheduler/run progress for a queued response task.
    #[impress_method]
    async fn task_status(&self, task_id: String) -> TaskStatusResult;

    /// Return the latest model run lineage for a response task: canonical
    /// inputs, tool invocations, and attributed outputs.
    #[impress_method]
    async fn task_provenance(&self, task_id: String) -> ProvenanceResult;

    /// Return complete lineage for a specific agent-run item.
    #[impress_method]
    async fn run_provenance(&self, run_id: String) -> ProvenanceResult;

    /// Store-hygiene health from the AI daemon: db/WAL/freelist sizes, the
    /// maintenance lease, last verb outcomes, and the trailing-24h op rate.
    /// `daemon_reachable: false` (never an error) when it isn't running.
    #[impress_method]
    async fn ai_health(&self) -> AiHealthResult;

    /// Mint a single-use browser pairing link for the AI daemon (15-minute
    /// expiry). Requires the local keychain bearer (`com.impress.ai-http`),
    /// so this works on the Mac that runs the daemon, not remotely.
    #[impress_method]
    async fn mint_pairing_link(&self) -> PairingLinkResult;
}

#[derive(Clone)]
pub struct DefaultImpressAiService {
    ai: Arc<AiStore>,
    provider: Option<Arc<dyn InferenceProvider>>,
    provider_error: Option<String>,
}

impl DefaultImpressAiService {
    pub fn with_components(ai: Arc<AiStore>, provider: Arc<dyn InferenceProvider>) -> Self {
        Self {
            ai,
            provider: Some(provider),
            provider_error: None,
        }
    }

    fn shared() -> Self {
        let ai = Arc::new(AiStore::from_store(
            impress_store_service::store_instance(),
            "agent:impress-ai-service",
        ));
        let url = std::env::var("IMPRESS_OMLX_URL")
            .unwrap_or_else(|_| impress_ai::omlx::DEFAULT_URL.into());
        match OmlxClient::with_endpoint_id(
            url,
            std::env::var("IMPRESS_OMLX_API_KEY").ok(),
            "local-omlx",
        ) {
            Ok(provider) => Self::with_components(ai, Arc::new(provider)),
            Err(error) => Self {
                ai,
                provider: None,
                provider_error: Some(error.to_string()),
            },
        }
    }
}

fn parse_id(value: &str, kind: &str) -> Result<Uuid, String> {
    Uuid::parse_str(value).map_err(|error| format!("invalid {kind} id '{value}': {error}"))
}

fn parse_ids(values: Vec<String>, kind: &str) -> Result<Vec<Uuid>, String> {
    values
        .into_iter()
        .map(|value| parse_id(&value, kind))
        .collect()
}

#[async_trait::async_trait]
impl ImpressAiService for DefaultImpressAiService {
    async fn list_models(&self) -> ModelsResult {
        let Some(provider) = &self.provider else {
            return ModelsResult {
                models: vec![],
                error: self.provider_error.clone(),
            };
        };
        match provider.models().await {
            Ok(models) => ModelsResult {
                models,
                error: None,
            },
            Err(error) => ModelsResult {
                models: vec![],
                error: Some(error.to_string()),
            },
        }
    }

    async fn list_conversations(&self, include_archived: bool) -> ConversationsResult {
        match self.ai.list_conversations(include_archived) {
            Ok(conversations) => ConversationsResult {
                conversations,
                error: None,
            },
            Err(error) => ConversationsResult {
                conversations: vec![],
                error: Some(error.to_string()),
            },
        }
    }

    async fn get_conversation(&self, conversation_id: String) -> ConversationResult {
        let result = parse_id(&conversation_id, "conversation")
            .and_then(|id| self.ai.snapshot(id).map_err(|error| error.to_string()));
        match result {
            Ok(conversation) => ConversationResult {
                conversation: Some(conversation),
                error: None,
            },
            Err(error) => ConversationResult {
                conversation: None,
                error: Some(error),
            },
        }
    }

    async fn create_conversation(
        &self,
        title: String,
        model: String,
        provider: Option<String>,
        system_prompt: Option<String>,
        temperature: f32,
        max_tokens: u32,
        thinking: bool,
        web_access: bool,
        enabled_tools: Vec<String>,
    ) -> ConversationMutationResult {
        let defaults = ConversationDraft::default();
        let result = self.ai.create_conversation(ConversationDraft {
            title,
            summary: None,
            system_prompt: system_prompt.or(defaults.system_prompt),
            provider: provider.unwrap_or_else(|| "omlx".into()),
            model,
            temperature,
            max_tokens,
            thinking,
            web_access,
            tool_policy: ToolPolicy {
                enabled: enabled_tools,
            },
        });
        match result {
            Ok(id) => ConversationMutationResult {
                success: true,
                conversation_id: Some(id),
                error: None,
            },
            Err(error) => ConversationMutationResult {
                success: false,
                conversation_id: None,
                error: Some(error.to_string()),
            },
        }
    }

    async fn queue_message(
        &self,
        conversation_id: String,
        body: String,
        attachment_ids: Vec<String>,
    ) -> QueuedMessageResult {
        let result = parse_id(&conversation_id, "conversation").and_then(|conversation_id| {
            let attachment_ids = parse_ids(attachment_ids, "attachment")?;
            let mut draft = MessageDraft::user(body);
            draft.attachment_ids = attachment_ids;
            self.ai
                .queue_user_turn(conversation_id, draft)
                .map_err(|error| error.to_string())
        });
        match result {
            Ok(queued) => QueuedMessageResult {
                success: true,
                conversation_id: Some(queued.conversation_id),
                message_id: Some(queued.message_id),
                task_id: Some(queued.task_id),
                error: None,
            },
            Err(error) => QueuedMessageResult {
                success: false,
                conversation_id: None,
                message_id: None,
                task_id: None,
                error: Some(error),
            },
        }
    }

    async fn set_enabled_tools(
        &self,
        conversation_id: String,
        enabled_tools: Vec<String>,
    ) -> ConversationMutationResult {
        let result = parse_id(&conversation_id, "conversation").and_then(|id| {
            self.ai
                .set_tool_policy(
                    id,
                    ToolPolicy {
                        enabled: enabled_tools,
                    },
                )
                .map(|()| id)
                .map_err(|error| error.to_string())
        });
        match result {
            Ok(id) => ConversationMutationResult {
                success: true,
                conversation_id: Some(id),
                error: None,
            },
            Err(error) => ConversationMutationResult {
                success: false,
                conversation_id: None,
                error: Some(error),
            },
        }
    }

    async fn task_status(&self, task_id: String) -> TaskStatusResult {
        let result = parse_id(&task_id, "task")
            .and_then(|id| self.ai.task_progress(id).map_err(|error| error.to_string()));
        match result {
            Ok(task) => TaskStatusResult {
                task: Some(task),
                error: None,
            },
            Err(error) => TaskStatusResult {
                task: None,
                error: Some(error),
            },
        }
    }

    async fn task_provenance(&self, task_id: String) -> ProvenanceResult {
        let result = parse_id(&task_id, "task").and_then(|id| {
            self.ai
                .task_provenance(id)
                .map_err(|error| error.to_string())
        });
        match result {
            Ok(provenance) => ProvenanceResult {
                provenance,
                error: None,
            },
            Err(error) => ProvenanceResult {
                provenance: None,
                error: Some(error),
            },
        }
    }

    async fn run_provenance(&self, run_id: String) -> ProvenanceResult {
        let result = parse_id(&run_id, "run").and_then(|id| {
            self.ai
                .run_provenance(id)
                .map_err(|error| error.to_string())
        });
        match result {
            Ok(provenance) => ProvenanceResult {
                provenance: Some(provenance),
                error: None,
            },
            Err(error) => ProvenanceResult {
                provenance: None,
                error: Some(error),
            },
        }
    }

    async fn ai_health(&self) -> AiHealthResult {
        let unreachable = |error: Option<String>| AiHealthResult {
            daemon_reachable: false,
            db_bytes: 0,
            wal_bytes: 0,
            wal_budget_bytes: 0,
            freelist_pages: 0,
            lease_owner: false,
            last_checkpoint_ms: None,
            last_compaction_ms: None,
            last_demotion_count: None,
            last_vacuum_ms: None,
            ops_last_24h: None,
            error,
        };
        let response = match reqwest::Client::new()
            .get(format!("http://127.0.0.1:{AI_DAEMON_PORT}/api/health"))
            .timeout(std::time::Duration::from_secs(3))
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => response,
            Ok(response) => {
                return unreachable(Some(format!("daemon health HTTP {}", response.status())))
            }
            Err(_) => return unreachable(None),
        };
        let body: serde_json::Value = match response.json().await {
            Ok(body) => body,
            Err(error) => return unreachable(Some(format!("health body: {error}"))),
        };
        let maintenance = &body["maintenance"];
        AiHealthResult {
            daemon_reachable: true,
            db_bytes: body["db_bytes"].as_u64().unwrap_or(0),
            wal_bytes: body["wal_bytes"].as_u64().unwrap_or(0),
            wal_budget_bytes: body["wal_budget_bytes"].as_u64().unwrap_or(0),
            freelist_pages: body["freelist_pages"].as_u64().unwrap_or(0),
            lease_owner: maintenance["lease_owner"].as_bool().unwrap_or(false),
            last_checkpoint_ms: maintenance["last_checkpoint_ms"].as_i64(),
            last_compaction_ms: maintenance["last_compaction_ms"].as_i64(),
            last_demotion_count: maintenance["last_demotion_count"].as_u64(),
            last_vacuum_ms: maintenance["last_vacuum_ms"].as_i64(),
            ops_last_24h: body["ops_last_24h"].as_u64(),
            error: None,
        }
    }

    async fn mint_pairing_link(&self) -> PairingLinkResult {
        let fail = |error: String| PairingLinkResult {
            url_local: None,
            ticket: None,
            expires_in_secs: 0,
            error: Some(error),
        };
        let bearer = match ai_daemon_bearer().await {
            Ok(bearer) => bearer,
            Err(error) => return fail(error),
        };
        let response = match reqwest::Client::new()
            .post(format!(
                "http://127.0.0.1:{AI_DAEMON_PORT}/api/pairing-tickets"
            ))
            .bearer_auth(bearer)
            .timeout(std::time::Duration::from_secs(5))
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => response,
            Ok(response) => return fail(format!("daemon returned HTTP {}", response.status())),
            Err(error) => return fail(format!("daemon unreachable: {error}")),
        };
        let body: serde_json::Value = match response.json().await {
            Ok(body) => body,
            Err(error) => return fail(format!("ticket body: {error}")),
        };
        let Some(ticket) = body["ticket"].as_str().map(str::to_owned) else {
            return fail("daemon response carried no ticket".into());
        };
        PairingLinkResult {
            url_local: Some(format!("http://127.0.0.1:{AI_DAEMON_PORT}/#pair={ticket}")),
            ticket: Some(ticket),
            expires_in_secs: 15 * 60,
            error: None,
        }
    }
}

/// The daemon's port (`SiblingApp.Services.impressAIPort` on the Swift side).
const AI_DAEMON_PORT: u16 = 8787;

/// The daemon bearer from the login keychain (`com.impress.ai-http`) — the
/// same item `run.sh` resolves at daemon launch. macOS-only by nature.
async fn ai_daemon_bearer() -> Result<String, String> {
    let output = tokio::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-w", "-s", "com.impress.ai-http"])
        .output()
        .await
        .map_err(|error| format!("keychain lookup failed to run: {error}"))?;
    if !output.status.success() {
        return Err("keychain item com.impress.ai-http not found (is the daemon set up?)".into());
    }
    let bearer = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if bearer.len() < 24 {
        return Err("keychain bearer looks malformed".into());
    }
    Ok(bearer)
}

fn service_instance() -> Arc<DefaultImpressAiService> {
    static SERVICE: OnceLock<Arc<DefaultImpressAiService>> = OnceLock::new();
    SERVICE
        .get_or_init(|| Arc::new(DefaultImpressAiService::shared()))
        .clone()
}

impress_service_impl! {
    service = ImpressAiService,
    impl = DefaultImpressAiService,
    instance = || service_instance(),
    methods = [
        list_models() -> ModelsResult,
        list_conversations(include_archived: bool) -> ConversationsResult,
        get_conversation(conversation_id: String) -> ConversationResult,
        create_conversation(
            title: String,
            model: String,
            provider: Option<String>,
            system_prompt: Option<String>,
            temperature: f32,
            max_tokens: u32,
            thinking: bool,
            web_access: bool,
            enabled_tools: Vec<String>
        ) -> ConversationMutationResult,
        queue_message(
            conversation_id: String,
            body: String,
            attachment_ids: Vec<String>
        ) -> QueuedMessageResult,
        set_enabled_tools(
            conversation_id: String,
            enabled_tools: Vec<String>
        ) -> ConversationMutationResult,
        task_status(task_id: String) -> TaskStatusResult,
        task_provenance(task_id: String) -> ProvenanceResult,
        run_provenance(run_id: String) -> ProvenanceResult,
        ai_health() -> AiHealthResult,
        mint_pairing_link() -> PairingLinkResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::ActorKind;
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    #[test]
    fn all_methods_reach_both_generated_inventories() {
        let mcp: Vec<&str> = McpToolDescriptor::iter().map(|item| item.name).collect();
        let cli: Vec<&str> = CliSubcommand::iter().map(|item| item.name).collect();
        for (mcp_name, cli_name) in [
            ("impress-ai-service_list-models", "list-models"),
            (
                "impress-ai-service_list-conversations",
                "list-conversations",
            ),
            ("impress-ai-service_get-conversation", "get-conversation"),
            (
                "impress-ai-service_create-conversation",
                "create-conversation",
            ),
            ("impress-ai-service_queue-message", "queue-message"),
            ("impress-ai-service_set-enabled-tools", "set-enabled-tools"),
            ("impress-ai-service_task-status", "task-status"),
            ("impress-ai-service_task-provenance", "task-provenance"),
            ("impress-ai-service_run-provenance", "run-provenance"),
            ("impress-ai-service_ai-health", "ai-health"),
            ("impress-ai-service_mint-pairing-link", "mint-pairing-link"),
        ] {
            assert!(mcp.contains(&mcp_name), "missing {mcp_name}");
            assert!(cli.contains(&cli_name), "missing {cli_name}");
        }
    }

    #[tokio::test]
    async fn queue_and_status_share_the_canonical_graph() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test:service",
                ActorKind::Human,
            )
            .unwrap(),
        );
        let provider = Arc::new(OmlxClient::new("http://127.0.0.1:8000", None).unwrap());
        let service = DefaultImpressAiService::with_components(ai, provider);
        let created = service
            .create_conversation(
                "Research".into(),
                "local-model".into(),
                None,
                None,
                0.2,
                2048,
                false,
                false,
                vec!["scix".into()],
            )
            .await;
        let conversation_id = created.conversation_id.unwrap();
        let queued = service
            .queue_message(conversation_id.to_string(), "Find papers".into(), vec![])
            .await;
        assert!(queued.success);
        let status = service
            .task_status(queued.task_id.unwrap().to_string())
            .await;
        assert_eq!(status.task.unwrap().state, "pending");
        assert_eq!(
            service
                .get_conversation(conversation_id.to_string())
                .await
                .conversation
                .unwrap()
                .messages
                .len(),
            1
        );
    }
}
