//! Small UniFFI facade over the provenance-first AI graph kernel.
//!
//! Swift receives JSON only for graph-shaped reads (snapshots/provenance),
//! keeping the FFI surface stable while the item envelope evolves. Mutations
//! use typed records so invalid state is rejected before it reaches SQLite.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_ai::{
    migrate_localmodels, read_worker_status, tool_options_for_policy, AiStore, BlobDescriptor,
    BlobStore, ConversationDraft, FileBlobStore, MessageDraft, ModelSummary, OmlxClient, Role,
    ToolPolicy, WorkerLifecycleState, WorkerStatusSnapshot, WORKER_PROTOCOL_VERSION,
};
use impress_core::item::ActorKind;

use crate::SharedStoreError;

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiConversationDraft {
    pub title: String,
    pub summary: Option<String>,
    pub system_prompt: Option<String>,
    pub provider: String,
    pub model: String,
    pub temperature: f64,
    pub max_tokens: u32,
    pub thinking: bool,
    pub web_access: bool,
    pub enabled_tools: Vec<String>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiQueuedTurn {
    pub conversation_id: String,
    pub message_id: String,
    pub task_id: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiAttachment {
    pub item_id: String,
    pub mime_type: String,
    pub sha256: String,
    pub file_name: Option<String>,
}

/// Device-local byte availability. This is deliberately never written into
/// the synced item payload: one offline phone must not mark a Mac's bytes
/// unavailable for the whole graph.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiBlobAvailability {
    pub sha256: String,
    pub byte_length: u64,
    pub state: String,
    pub local_path: Option<String>,
    pub error: Option<String>,
}

/// Display-ready list row shaped by the Rust core.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiConversationRow {
    pub id: String,
    pub title: String,
    pub summary: Option<String>,
    pub state: String,
    pub provider: String,
    pub model: String,
    pub created_at_ms: i64,
    pub modified_at_ms: i64,
    pub last_activity_at_ms: i64,
    pub message_count: u32,
    pub pending_task_count: u32,
    pub enabled_tools: Vec<String>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiAttachmentRow {
    pub id: String,
    pub mime_type: String,
    pub file_name: Option<String>,
    pub byte_length: u64,
    pub sha256: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiWebSourceRow {
    pub id: String,
    pub title: String,
    pub url: String,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiToolInvocationRow {
    pub id: String,
    pub tool: String,
    pub provider: String,
    pub state: String,
    pub result_summary: Option<String>,
    pub error: Option<String>,
    pub duration_ms: Option<u64>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiMessageRow {
    pub id: String,
    pub role: String,
    pub body: String,
    pub format: String,
    pub sender: String,
    pub status: String,
    pub sequence: i64,
    pub created_at_ms: i64,
    pub reasoning: Option<String>,
    pub model: Option<String>,
    pub in_response_to_id: Option<String>,
    pub produced_by_run_id: Option<String>,
    pub attachments: Vec<AiAttachmentRow>,
    pub sources: Vec<AiWebSourceRow>,
    pub tool_invocations: Vec<AiToolInvocationRow>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiTaskRow {
    pub id: String,
    pub title: String,
    pub state: String,
    pub created_at_ms: i64,
    pub run_id: Option<String>,
    pub response_message_id: Option<String>,
    pub preview_text: Option<String>,
    pub preview_complete: bool,
    pub error: Option<String>,
}

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiToolOption {
    pub id: String,
    pub label: String,
    pub description: String,
    pub enabled: bool,
}

/// One model advertised by the configured oMLX host. This is deliberately a
/// native projection rather than raw `/v1/models` JSON.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiModelRow {
    pub id: String,
    pub loaded: bool,
    pub max_context_window: Option<u64>,
    pub modalities: Vec<String>,
}

/// Device-local reachability snapshot for an oMLX laptop/server. It is never
/// persisted into the shared graph because different devices can legitimately
/// observe different reachability at the same time.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiModelHostStatus {
    pub endpoint: String,
    pub state: String,
    pub checked_at_ms: i64,
    pub models: Vec<AiModelRow>,
    pub detail: String,
}

/// Device-local health of the Rust task worker that consumes synced AI turns.
/// This projection is read from the worker heartbeat and is never synced.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiWorkerStatus {
    pub state: String,
    pub checked_at_ms: i64,
    pub worker_id: Option<String>,
    pub pid: Option<u32>,
    pub started_at_ms: Option<i64>,
    pub heartbeat_at_ms: Option<i64>,
    pub last_pass_at_ms: Option<i64>,
    pub completed_total: u64,
    pub failed_total: u64,
    pub detail: String,
}

/// One native conversation screen. SwiftUI renders this projection and sends
/// commands back through `SharedAiStore`; it owns no policy derivation.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct AiConversationView {
    pub conversation: AiConversationRow,
    pub messages: Vec<AiMessageRow>,
    pub tasks: Vec<AiTaskRow>,
    pub tool_options: Vec<AiToolOption>,
}

#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedAiStore {
    store: AiStore,
    blobs: FileBlobStore,
    workspace: PathBuf,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedAiStore {
    /// Open the same shared SQLite graph as `SharedStore`, plus the suite CAS.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(
        database_path: String,
        blob_root: String,
        actor: String,
    ) -> Result<Arc<Self>, SharedStoreError> {
        let database_path = PathBuf::from(database_path);
        let workspace = database_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        let store = AiStore::open(&database_path, actor, ActorKind::Human).map_err(ai_error)?;
        let blobs = FileBlobStore::open(blob_root).map_err(ai_error)?;
        Ok(Arc::new(Self {
            store,
            blobs,
            workspace,
        }))
    }

    pub fn create_conversation(
        &self,
        draft: AiConversationDraft,
    ) -> Result<String, SharedStoreError> {
        let temperature = draft.temperature as f32;
        if !temperature.is_finite() {
            return Err(SharedStoreError::InvalidArgument {
                message: "temperature must be finite".into(),
            });
        }
        let id = self
            .store
            .create_conversation(ConversationDraft {
                title: draft.title,
                summary: draft.summary,
                system_prompt: draft.system_prompt,
                provider: draft.provider,
                model: draft.model,
                temperature,
                max_tokens: draft.max_tokens,
                thinking: draft.thinking,
                web_access: draft.web_access,
                tool_policy: ToolPolicy {
                    enabled: draft.enabled_tools,
                },
            })
            .map_err(ai_error)?;
        Ok(id.to_string())
    }

    pub fn list_conversations_json(
        &self,
        include_archived: bool,
    ) -> Result<String, SharedStoreError> {
        let rows = self
            .store
            .list_conversations(include_archived)
            .map_err(ai_error)?;
        serde_json::to_string(&rows).map_err(json_error)
    }

    pub fn conversation_snapshot_json(
        &self,
        conversation_id: String,
    ) -> Result<String, SharedStoreError> {
        let id = parse_id(&conversation_id)?;
        let snapshot = self.store.snapshot(id).map_err(ai_error)?;
        serde_json::to_string(&snapshot).map_err(json_error)
    }

    pub fn conversation_rows(
        &self,
        include_archived: bool,
    ) -> Result<Vec<AiConversationRow>, SharedStoreError> {
        self.store
            .conversation_rows(include_archived)
            .map(|rows| rows.into_iter().map(conversation_row).collect())
            .map_err(ai_error)
    }

    pub fn conversation_view(
        &self,
        conversation_id: String,
    ) -> Result<AiConversationView, SharedStoreError> {
        self.store
            .conversation_view(parse_id(&conversation_id)?)
            .map(conversation_view)
            .map_err(ai_error)
    }

    pub fn tool_options(&self, enabled_tools: Vec<String>) -> Vec<AiToolOption> {
        tool_options_for_policy(&enabled_tools)
            .into_iter()
            .map(tool_option)
            .collect()
    }

    /// Inspect the configured oMLX host through the Rust provider client.
    /// Network failures are normal device-local state and therefore return an
    /// `unreachable` projection; malformed configuration still returns an
    /// argument error.
    pub fn inspect_omlx_host(
        &self,
        endpoint: String,
        api_key: Option<String>,
    ) -> Result<AiModelHostStatus, SharedStoreError> {
        let client = OmlxClient::new(endpoint, api_key.filter(|value| !value.is_empty()))
            .map_err(ai_error)?;
        let canonical_endpoint = client.base_url().to_string();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| SharedStoreError::Storage {
                message: format!("could not start oMLX discovery runtime: {error}"),
            })?;
        let checked_at_ms = chrono::Utc::now().timestamp_millis();

        Ok(match runtime.block_on(client.models()) {
            Ok(models) => model_host_status(canonical_endpoint, checked_at_ms, models),
            Err(error) => AiModelHostStatus {
                endpoint: canonical_endpoint,
                state: "unreachable".into(),
                checked_at_ms,
                models: vec![],
                detail: error.to_string(),
            },
        })
    }

    /// Inspect the device-local model worker heartbeat. Absence and staleness
    /// are normal states: queued graph tasks remain durable and syncable.
    pub fn model_worker_status(&self) -> AiWorkerStatus {
        let checked_at_ms = chrono::Utc::now().timestamp_millis();
        match read_worker_status(&self.workspace) {
            Ok(Some(snapshot)) => worker_status(snapshot, checked_at_ms),
            Ok(None) => unavailable_worker_status(
                checked_at_ms,
                "No Impress model worker has reported from this device",
            ),
            Err(error) => unavailable_worker_status(
                checked_at_ms,
                format!("Could not read the model worker heartbeat: {error}"),
            ),
        }
    }

    pub fn queue_user_turn(
        &self,
        conversation_id: String,
        body: String,
        attachment_ids: Vec<String>,
    ) -> Result<AiQueuedTurn, SharedStoreError> {
        let conversation_id = parse_id(&conversation_id)?;
        let attachment_ids = attachment_ids
            .iter()
            .map(|id| parse_id(id))
            .collect::<Result<Vec<_>, _>>()?;
        let queued = self
            .store
            .queue_user_turn(
                conversation_id,
                MessageDraft {
                    role: Role::User,
                    body,
                    from: "user:local".into(),
                    attachment_ids,
                    in_response_to: None,
                },
            )
            .map_err(ai_error)?;
        Ok(AiQueuedTurn {
            conversation_id: queued.conversation_id.to_string(),
            message_id: queued.message_id.to_string(),
            task_id: queued.task_id.to_string(),
        })
    }

    pub fn set_enabled_tools(
        &self,
        conversation_id: String,
        enabled_tools: Vec<String>,
    ) -> Result<(), SharedStoreError> {
        self.store
            .set_tool_policy(
                parse_id(&conversation_id)?,
                ToolPolicy {
                    enabled: enabled_tools,
                },
            )
            .map_err(ai_error)
    }

    pub fn set_conversation_model(
        &self,
        conversation_id: String,
        model: String,
    ) -> Result<(), SharedStoreError> {
        self.store
            .set_conversation_model(parse_id(&conversation_id)?, model)
            .map_err(ai_error)
    }

    pub fn set_conversation_title(
        &self,
        conversation_id: String,
        title: String,
    ) -> Result<(), SharedStoreError> {
        self.store
            .set_conversation_title(parse_id(&conversation_id)?, title)
            .map_err(ai_error)
    }

    pub fn queue_title_suggestion(
        &self,
        conversation_id: String,
    ) -> Result<String, SharedStoreError> {
        self.store
            .queue_title_suggestion(parse_id(&conversation_id)?)
            .map(|id| id.to_string())
            .map_err(ai_error)
    }

    pub fn task_progress_json(&self, task_id: String) -> Result<String, SharedStoreError> {
        let progress = self
            .store
            .task_progress(parse_id(&task_id)?)
            .map_err(ai_error)?;
        serde_json::to_string(&progress).map_err(json_error)
    }

    pub fn task_state(&self, task_id: String) -> Result<String, SharedStoreError> {
        self.store
            .task_progress(parse_id(&task_id)?)
            .map(|progress| progress.state)
            .map_err(ai_error)
    }

    pub fn run_provenance_json(&self, run_id: String) -> Result<String, SharedStoreError> {
        let provenance = self
            .store
            .run_provenance(parse_id(&run_id)?)
            .map_err(ai_error)?;
        serde_json::to_string(&provenance).map_err(json_error)
    }

    pub fn ingest_blob(
        &self,
        bytes: Vec<u8>,
        mime_type: String,
        file_name: Option<String>,
    ) -> Result<AiAttachment, SharedStoreError> {
        let attachment = self
            .store
            .ingest_blob(&self.blobs, &bytes, mime_type, file_name)
            .map_err(ai_error)?;
        Ok(AiAttachment {
            item_id: attachment.item_id.to_string(),
            mime_type: attachment.mime_type,
            sha256: attachment.sha256,
            file_name: attachment.file_name,
        })
    }

    /// Resolve and verify a content-blob payload to a stable CKAsset path.
    pub fn blob_asset_path(
        &self,
        payload_json: String,
    ) -> Result<Option<String>, SharedStoreError> {
        let descriptor = descriptor_from_payload(&payload_json)?;
        if !self.blobs.contains(&descriptor).map_err(ai_error)? {
            return Ok(None);
        }
        Ok(Some(
            self.blobs
                .verified_path(&descriptor)
                .map_err(ai_error)?
                .to_string_lossy()
                .into_owned(),
        ))
    }

    pub fn blob_availability(
        &self,
        payload_json: String,
    ) -> Result<AiBlobAvailability, SharedStoreError> {
        let descriptor = descriptor_from_payload(&payload_json)?;
        match self.blobs.verified_path(&descriptor) {
            Ok(path) => Ok(AiBlobAvailability {
                sha256: descriptor.sha256,
                byte_length: descriptor.byte_length,
                state: "available".into(),
                local_path: Some(path.to_string_lossy().into_owned()),
                error: None,
            }),
            Err(error) => {
                let missing = !self.blobs.contains(&descriptor).unwrap_or(false);
                Ok(AiBlobAvailability {
                    sha256: descriptor.sha256,
                    byte_length: descriptor.byte_length,
                    state: if missing { "missing" } else { "corrupt" }.into(),
                    local_path: None,
                    error: if missing {
                        None
                    } else {
                        Some(error.to_string())
                    },
                })
            }
        }
    }

    /// Accept a fetched CKAsset only when it matches the graph descriptor.
    pub fn import_blob_asset(
        &self,
        payload_json: String,
        source_path: String,
    ) -> Result<AiBlobAvailability, SharedStoreError> {
        let descriptor = descriptor_from_payload(&payload_json)?;
        let bytes = std::fs::read(source_path).map_err(|error| SharedStoreError::Storage {
            message: error.to_string(),
        })?;
        self.blobs
            .import_expected(&descriptor, &bytes)
            .map_err(ai_error)?;
        self.blob_availability(payload_json)
    }

    /// Import the retired LocalModels DB. The source is read-only; each
    /// conversation and its ledger commit in one transaction.
    pub fn migrate_localmodels_json(
        &self,
        source_database_path: String,
        dry_run: bool,
    ) -> Result<String, SharedStoreError> {
        let report = migrate_localmodels(
            self.store.shared_store(),
            &self.blobs,
            Path::new(&source_database_path),
            dry_run,
        )
        .map_err(ai_error)?;
        serde_json::to_string(&report).map_err(json_error)
    }
}

fn conversation_row(row: impress_ai::AiConversationRow) -> AiConversationRow {
    AiConversationRow {
        id: row.id.to_string(),
        title: row.title,
        summary: row.summary,
        state: row.state,
        provider: row.provider,
        model: row.model,
        created_at_ms: row.created_at_ms,
        modified_at_ms: row.modified_at_ms,
        last_activity_at_ms: row.last_activity_at_ms,
        message_count: row.message_count,
        pending_task_count: row.pending_task_count,
        enabled_tools: row.enabled_tools,
    }
}

fn attachment_row(row: impress_ai::AiAttachmentRow) -> AiAttachmentRow {
    AiAttachmentRow {
        id: row.id.to_string(),
        mime_type: row.mime_type,
        file_name: row.file_name,
        byte_length: row.byte_length,
        sha256: row.sha256,
    }
}

fn source_row(row: impress_ai::AiWebSourceRow) -> AiWebSourceRow {
    AiWebSourceRow {
        id: row.id.to_string(),
        title: row.title,
        url: row.url,
    }
}

fn tool_invocation_row(row: impress_ai::AiToolInvocationRow) -> AiToolInvocationRow {
    AiToolInvocationRow {
        id: row.id.to_string(),
        tool: row.tool,
        provider: row.provider,
        state: row.state,
        result_summary: row.result_summary,
        error: row.error,
        duration_ms: row.duration_ms,
    }
}

fn message_row(row: impress_ai::AiMessageRow) -> AiMessageRow {
    AiMessageRow {
        id: row.id.to_string(),
        role: row.role,
        body: row.body,
        format: row.format,
        sender: row.sender,
        status: row.status,
        sequence: row.sequence,
        created_at_ms: row.created_at_ms,
        reasoning: row.reasoning,
        model: row.model,
        in_response_to_id: row.in_response_to_id.map(|id| id.to_string()),
        produced_by_run_id: row.produced_by_run_id.map(|id| id.to_string()),
        attachments: row.attachments.into_iter().map(attachment_row).collect(),
        sources: row.sources.into_iter().map(source_row).collect(),
        tool_invocations: row
            .tool_invocations
            .into_iter()
            .map(tool_invocation_row)
            .collect(),
    }
}

fn task_row(row: impress_ai::AiTaskRow) -> AiTaskRow {
    AiTaskRow {
        id: row.id.to_string(),
        title: row.title,
        state: row.state,
        created_at_ms: row.created_at_ms,
        run_id: row.run_id.map(|id| id.to_string()),
        response_message_id: row.response_message_id.map(|id| id.to_string()),
        preview_text: row.preview_text,
        preview_complete: row.preview_complete,
        error: row.error,
    }
}

fn tool_option(row: impress_ai::AiToolOption) -> AiToolOption {
    AiToolOption {
        id: row.id,
        label: row.label,
        description: row.description,
        enabled: row.enabled,
    }
}

fn model_row(model: ModelSummary) -> AiModelRow {
    AiModelRow {
        id: model.id,
        loaded: model.loaded,
        max_context_window: model.max_context_window,
        modalities: model.modalities,
    }
}

fn model_host_status(
    endpoint: String,
    checked_at_ms: i64,
    models: Vec<ModelSummary>,
) -> AiModelHostStatus {
    let model_count = models.len();
    AiModelHostStatus {
        endpoint,
        state: if model_count == 0 { "empty" } else { "ready" }.into(),
        checked_at_ms,
        models: models.into_iter().map(model_row).collect(),
        detail: if model_count == 0 {
            "Host reachable; no models reported".into()
        } else {
            let noun = if model_count == 1 { "model" } else { "models" };
            format!("Host reachable; {model_count} {noun} available")
        },
    }
}

fn unavailable_worker_status(checked_at_ms: i64, detail: impl Into<String>) -> AiWorkerStatus {
    AiWorkerStatus {
        state: "unavailable".into(),
        checked_at_ms,
        worker_id: None,
        pid: None,
        started_at_ms: None,
        heartbeat_at_ms: None,
        last_pass_at_ms: None,
        completed_total: 0,
        failed_total: 0,
        detail: detail.into(),
    }
}

fn worker_status(snapshot: WorkerStatusSnapshot, checked_at_ms: i64) -> AiWorkerStatus {
    let (state, detail) = if snapshot.protocol_version != WORKER_PROTOCOL_VERSION {
        (
            "incompatible",
            format!(
                "Worker protocol {} is incompatible with this app (expected {})",
                snapshot.protocol_version, WORKER_PROTOCOL_VERSION
            ),
        )
    } else if !snapshot.is_fresh_at(checked_at_ms) {
        (
            "stale",
            "The model worker stopped reporting; queued turns remain safe".into(),
        )
    } else {
        match snapshot.state {
            WorkerLifecycleState::Starting => {
                ("starting", "The Impress model worker is starting".into())
            }
            WorkerLifecycleState::Settling => (
                "settling",
                "Worker online; waiting for the startup-settling guard".into(),
            ),
            WorkerLifecycleState::Ready => {
                ("ready", "Worker ready to consume queued model turns".into())
            }
            WorkerLifecycleState::Stopping => {
                ("stopping", "The Impress model worker is stopping".into())
            }
            WorkerLifecycleState::Failed => (
                "failed",
                snapshot
                    .last_error
                    .clone()
                    .unwrap_or_else(|| "The Impress model worker failed".into()),
            ),
        }
    };

    AiWorkerStatus {
        state: state.into(),
        checked_at_ms,
        worker_id: Some(snapshot.worker_id),
        pid: Some(snapshot.pid),
        started_at_ms: Some(snapshot.started_at_ms),
        heartbeat_at_ms: Some(snapshot.heartbeat_at_ms),
        last_pass_at_ms: snapshot.last_pass_at_ms,
        completed_total: snapshot.completed_total,
        failed_total: snapshot.failed_total,
        detail,
    }
}

fn conversation_view(view: impress_ai::AiConversationView) -> AiConversationView {
    AiConversationView {
        conversation: conversation_row(view.conversation),
        messages: view.messages.into_iter().map(message_row).collect(),
        tasks: view.tasks.into_iter().map(task_row).collect(),
        tool_options: view.tool_options.into_iter().map(tool_option).collect(),
    }
}

fn descriptor_from_payload(payload_json: &str) -> Result<BlobDescriptor, SharedStoreError> {
    let payload: serde_json::Value = serde_json::from_str(payload_json).map_err(json_error)?;
    let required_string = |name: &str| {
        payload
            .get(name)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| SharedStoreError::InvalidArgument {
                message: format!("content-blob payload is missing string '{name}'"),
            })
    };
    let byte_length = payload
        .get("byte_length")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| SharedStoreError::InvalidArgument {
            message: "content-blob payload is missing unsigned 'byte_length'".into(),
        })?;
    Ok(BlobDescriptor {
        sha256: required_string("sha256")?,
        byte_length,
        storage_kind: required_string("storage_kind")?,
        locator: required_string("locator")?,
    })
}

fn parse_id(value: &str) -> Result<uuid::Uuid, SharedStoreError> {
    value
        .parse()
        .map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {value}"),
        })
}

fn ai_error(error: impress_ai::Error) -> SharedStoreError {
    match error {
        impress_ai::Error::Invalid(message) => SharedStoreError::InvalidArgument { message },
        other => SharedStoreError::Storage {
            message: other.to_string(),
        },
    }
}

fn json_error(error: serde_json::Error) -> SharedStoreError {
    SharedStoreError::InvalidArgument {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_host_projection_preserves_capabilities() {
        let status = model_host_status(
            "http://127.0.0.1:8000".into(),
            42,
            vec![ModelSummary {
                id: "mlx-community/model".into(),
                loaded: true,
                max_context_window: Some(32_768),
                modalities: vec!["text".into(), "image".into()],
            }],
        );
        assert_eq!(status.state, "ready");
        assert_eq!(status.checked_at_ms, 42);
        assert_eq!(status.models[0].modalities, ["text", "image"]);
        assert!(status.detail.contains("1 model"));
    }

    #[test]
    fn worker_projection_distinguishes_ready_and_stale_heartbeats() {
        let mut snapshot =
            WorkerStatusSnapshot::new("worker-a".into(), 42, 10_000, 5, "local-omlx".into());
        snapshot.state = WorkerLifecycleState::Ready;
        snapshot.completed_total = 7;

        let ready = worker_status(snapshot.clone(), 20_000);
        assert_eq!(ready.state, "ready");
        assert_eq!(ready.completed_total, 7);

        let stale = worker_status(snapshot, 40_001);
        assert_eq!(stale.state, "stale");
        assert!(stale.detail.contains("queued turns remain safe"));
    }
}
