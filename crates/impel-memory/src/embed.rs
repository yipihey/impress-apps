//! `impress.memory.embed` — one bounded window of embedding backfill per task
//! (ADR-0028 D7).
//!
//! The task item carries its own window: a keyset cursor in, the cursor it
//! reached out. That is D8's rule — the watermark lives in the task chain, not
//! in a side table — and it is what lets [`crate::plan_memory_tasks`] compute
//! the next window from nothing but the last completed task.
//!
//! # Why a keyset cursor and not `OFFSET`
//!
//! `idx_items_schema_created` is `(schema_ref, created)`. A
//! `(created, id) > (cursor_created, cursor_id)` predicate rides that index and
//! reads only the rows it returns; `LIMIT n OFFSET k` re-walks every skipped
//! row on every pass, so a backfill over a large library would get
//! quadratically slower exactly as it made progress. The `id` half of the
//! cursor is what makes it correct rather than merely fast: `created` is a
//! millisecond stamp and a bulk import writes hundreds of rows inside one
//! millisecond, so a cursor on `created` alone either re-embeds them forever or
//! skips them entirely, depending on which comparison you pick.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use impel_core::{AgentRunRecord, ExecutionOutcome, TaskError, TaskExecutor, TaskStoreApi};
use impress_core::item::{ActorKind, Item, ItemId, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::schemas::memory::{
    MEMORY_CLAIM_SCHEMA, MEMORY_EPISODE_SCHEMA, MEMORY_INSTRUCTION_SCHEMA,
};
use impress_core::schemas::source::CONTENT_CHUNK_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_embeddings::{EmbeddingStore, StoredVector};
use sha2::{Digest, Sha256};

use crate::{
    vector_id, EmbedderProvider, FastEmbedProvider, SOURCE_TYPE_CHUNK, SOURCE_TYPE_MEMORY,
};

/// Dispatch key: the `task_kind` payload field the scheduler matches on.
pub const KIND_EMBED: &str = "impress.memory.embed";

/// `agent_id` stamped on this executor's `agent-run@1.0.0` provenance rows.
pub const EMBED_AGENT_ID: &str = "impel-memory/embed";

/// Env var overriding the sidecar path for the whole process. A task's
/// `sidecar_path` payload field still wins over it — the task is the more
/// specific instruction, and the tests rely on that ordering.
pub const EMBEDDINGS_PATH_ENV: &str = "IMPRESS_EMBEDDINGS_PATH";

/// Rows embedded per task when the payload does not say.
pub const DEFAULT_BATCH_LIMIT: i64 = 256;

/// Ceiling on `batch_limit`, however large the payload asks for. One task is
/// meant to be a bounded unit of work the scheduler can retry cheaply; a
/// 100 000-row "batch" is a long-running job wearing a task's clothes.
pub const MAX_BATCH_LIMIT: i64 = 4096;

/// The schemas this backfill covers, in the order the ADR names them.
///
/// Consts, never literals: the store matches `schema_ref` by exact equality, so
/// a second spelling here is a silently-empty scan forever (root CLAUDE.md,
/// "Definition of done — schema refs").
pub fn embeddable_schemas() -> [&'static str; 4] {
    [
        CONTENT_CHUNK_SCHEMA,
        MEMORY_CLAIM_SCHEMA,
        MEMORY_EPISODE_SCHEMA,
        MEMORY_INSTRUCTION_SCHEMA,
    ]
}

/// The default sidecar location: the same file `impress-mcp` opens.
///
/// `impress_mcp::default_embeddings_path()` is `dirs::data_dir()/imbib/…` and
/// is private to that binary, so this replicates it rather than importing it —
/// with the env override in front, so a daemon can be pointed elsewhere without
/// a rebuild.
pub fn default_sidecar_path() -> Option<String> {
    if let Ok(path) = std::env::var(EMBEDDINGS_PATH_ENV) {
        if !path.trim().is_empty() {
            return Some(path);
        }
    }
    dirs::data_dir().map(|dir| {
        dir.join("imbib/embeddings.sqlite")
            .to_string_lossy()
            .into_owned()
    })
}

/// One window of embedding work.
pub struct EmbedBackfillExecutor {
    store: Arc<SqliteItemStore>,
    provider: Arc<dyn EmbedderProvider>,
    /// Used when the task payload names no `sidecar_path`. `None` means "ask
    /// [`default_sidecar_path`] at execution time", which is what lets the env
    /// override be read late rather than frozen at construction.
    sidecar_path: Option<String>,
    actor: String,
}

impl EmbedBackfillExecutor {
    /// Production wiring: fastembed behind the seam, default sidecar.
    pub fn new(store: Arc<SqliteItemStore>) -> Self {
        Self::with_provider(store, Arc::new(FastEmbedProvider::new()))
    }

    /// Inject an embedder provider — the test seam, and the hook for a future
    /// on-device or remote embedder.
    pub fn with_provider(store: Arc<SqliteItemStore>, provider: Arc<dyn EmbedderProvider>) -> Self {
        Self {
            store,
            provider,
            sidecar_path: None,
            actor: EMBED_AGENT_ID.to_string(),
        }
    }

    /// Pin the sidecar path for tasks that do not name one.
    pub fn with_sidecar_path(mut self, path: impl Into<String>) -> Self {
        self.sidecar_path = Some(path.into());
        self
    }

    /// Where this task's vectors go: task payload, then constructor, then env
    /// / platform default.
    fn sidecar_for(&self, task: &Item) -> Result<String, TaskError> {
        if let Some(path) = payload_string(task, "sidecar_path") {
            if !path.trim().is_empty() {
                return Ok(path);
            }
        }
        if let Some(path) = &self.sidecar_path {
            return Ok(path.clone());
        }
        default_sidecar_path().ok_or_else(|| {
            // No home/data directory and no override: a machine misconfiguration
            // a retry cannot fix.
            TaskError::Permanent(
                "no embeddings sidecar path: set the task's sidecar_path or \
                 IMPRESS_EMBEDDINGS_PATH"
                    .into(),
            )
        })
    }

    /// Candidate rows strictly after the cursor, in keyset order.
    ///
    /// Returns `(id, created_ms, schema_ref)`; the payload is fetched per row
    /// afterwards. Splitting it that way keeps this query on the covering index
    /// instead of dragging every payload blob through the scan just to discover
    /// which rows have text.
    fn candidates(
        &self,
        cursor_created_ms: i64,
        cursor_id: &str,
        limit: i64,
    ) -> Result<Vec<(ItemId, i64, String)>, TaskError> {
        let schemas = embeddable_schemas();
        let sql = "SELECT id, created, schema_ref FROM items
                   WHERE schema_ref IN (?1, ?2, ?3, ?4)
                     AND (created > ?5 OR (created = ?5 AND id > ?6))
                   ORDER BY created ASC, id ASC
                   LIMIT ?7";
        let rows: Vec<(String, i64, String)> = self
            .store
            .query_raw(
                sql,
                &[
                    &schemas[0],
                    &schemas[1],
                    &schemas[2],
                    &schemas[3],
                    &cursor_created_ms,
                    &cursor_id,
                    &limit,
                ],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|e| TaskError::Retryable(format!("scan candidates: {e}")))?;
        Ok(rows
            .into_iter()
            .filter_map(|(id, created, schema)| {
                uuid::Uuid::parse_str(&id)
                    .ok()
                    .map(|id| (id, created, schema))
            })
            .collect())
    }

    /// Write one payload field on the task item itself.
    ///
    /// Legal, and worth being explicit about: only `state` is scheduler-exclusive
    /// (ADR-0015 D1). Payload is ordinary mutable item data, and going through
    /// `apply` means the cursor advance lands in the operation journal with this
    /// executor's attribution, like every other kernel write.
    fn set_payload(
        &self,
        task_id: ItemId,
        field: &str,
        value: Value,
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError> {
        store.apply(OperationSpec {
            target_id: task_id,
            op_type: OperationType::SetPayload(field.into(), value),
            intent: OperationIntent::Routine,
            reason: None,
            batch_id: None,
            author: self.actor.clone(),
            author_kind: ActorKind::Agent,
            // Compactable: a cursor is bookkeeping, not research record. The
            // NEXT task's cursor supersedes it, and the chain of done tasks is
            // what D8 reads.
            retention: RetentionTier::Compactable,
        })?;
        Ok(())
    }
}

#[async_trait]
impl TaskExecutor for EmbedBackfillExecutor {
    fn task_kind(&self) -> &str {
        KIND_EMBED
    }

    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        let started = Instant::now();
        let cursor_created_ms = payload_i64(task, "cursor_created_ms").unwrap_or(0);
        let cursor_id = payload_string(task, "cursor_id").unwrap_or_default();
        let batch_limit = payload_i64(task, "batch_limit")
            .unwrap_or(DEFAULT_BATCH_LIMIT)
            .clamp(1, MAX_BATCH_LIMIT);
        let requested_model = payload_string(task, "model")
            .filter(|m| !m.trim().is_empty())
            .unwrap_or_else(|| impress_embeddings::semantic::FASTEMBED_MODEL_ID.to_string());
        let sidecar_path = self.sidecar_for(task)?;

        let candidates = self.candidates(cursor_created_ms, &cursor_id, batch_limit)?;

        // Hoisted before the model load: an empty window must not pay a ~100MB
        // model initialization to discover it has nothing to do, and on a caught-
        // up store that is the common case, once per poll interval, forever.
        if candidates.is_empty() {
            self.set_payload(
                task.id,
                "cursor_end_created_ms",
                Value::Int(cursor_created_ms),
                store,
            )?;
            self.set_payload(
                task.id,
                "cursor_end_id",
                Value::String(cursor_id.clone()),
                store,
            )?;
            self.set_payload(task.id, "embedded_count", Value::Int(0), store)?;
            store.record_agent_run(
                task.id,
                AgentRunRecord {
                    agent_id: self.actor.clone(),
                    model: requested_model,
                    prompt_hash: prompt_hash(cursor_created_ms, &cursor_id, batch_limit),
                    result_summary: Some("0 embedded (window empty)".into()),
                    token_count: None,
                    duration_ms: Some(started.elapsed().as_millis() as i64),
                },
            )?;
            return Ok(ExecutionOutcome::Complete);
        }

        // The cursor advances to the last row EXAMINED, not the last row
        // embedded. A window of rows with no text is progress: leaving the
        // cursor behind them would re-examine them on every future pass and the
        // backfill would never reach the rows after them.
        let (last_id, last_created, _) = candidates
            .last()
            .cloned()
            .expect("non-empty checked directly above");

        let mut texts: Vec<String> = Vec::with_capacity(candidates.len());
        let mut targets: Vec<(ItemId, &'static str)> = Vec::with_capacity(candidates.len());
        for (id, _, schema) in &candidates {
            let Some(item) = ItemStore::get(self.store.as_ref(), *id)
                .map_err(|e| TaskError::Retryable(format!("load candidate {id}: {e}")))?
            else {
                // Deleted between the scan and now. Not an error; the cursor
                // moves past it either way.
                continue;
            };
            let (text, source_type) = match embeddable_text(&item, schema) {
                Some(pair) => pair,
                // A data condition, not a failure: a chunk with no text and a
                // memory row with an empty title+body have nothing to embed.
                None => continue,
            };
            texts.push(text);
            targets.push((*id, source_type));
        }

        let mut embedded = 0usize;
        let model_id = if texts.is_empty() {
            requested_model.clone()
        } else {
            let embedder = self
                .provider
                .embedder_for(&requested_model)
                // Transient by default: an unreachable model host or a failed
                // first-run download is exactly what retry is for.
                .map_err(|e| TaskError::Retryable(format!("embedding model unavailable: {e}")))?;
            let vectors = embedder
                .embed_batch(&texts)
                .map_err(|e| TaskError::Retryable(format!("embedding failed: {e}")))?;
            if vectors.len() != texts.len() {
                return Err(TaskError::Retryable(format!(
                    "embedder returned {} vectors for {} texts",
                    vectors.len(),
                    texts.len()
                )));
            }
            let model_id = embedder.model_id().to_string();
            let created_at = chrono::Utc::now().to_rfc3339();
            let stored: Vec<StoredVector> = targets
                .iter()
                .zip(vectors)
                .map(|((id, source_type), vector)| {
                    let source_id = id.to_string();
                    StoredVector {
                        id: vector_id(&source_id, &model_id).to_string(),
                        source_id,
                        source_type: (*source_type).to_string(),
                        vector,
                        model: model_id.clone(),
                        created_at: created_at.clone(),
                    }
                })
                .collect();

            let sidecar = EmbeddingStore::open(&sidecar_path)
                .map_err(|e| TaskError::Retryable(format!("open sidecar {sidecar_path}: {e}")))?;
            embedded = sidecar
                .save_vectors(&stored)
                .map_err(|e| TaskError::Retryable(format!("save vectors: {e}")))?;
            model_id
        };

        self.set_payload(
            task.id,
            "cursor_end_created_ms",
            Value::Int(last_created),
            store,
        )?;
        self.set_payload(
            task.id,
            "cursor_end_id",
            Value::String(last_id.to_string()),
            store,
        )?;
        self.set_payload(
            task.id,
            "embedded_count",
            Value::Int(embedded as i64),
            store,
        )?;

        store.record_agent_run(
            task.id,
            AgentRunRecord {
                agent_id: self.actor.clone(),
                model: model_id,
                prompt_hash: prompt_hash(cursor_created_ms, &cursor_id, batch_limit),
                result_summary: Some(format!(
                    "{embedded} embedded of {} candidate(s)",
                    candidates.len()
                )),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
            },
        )?;
        Ok(ExecutionOutcome::Complete)
    }

    fn max_retries(&self) -> u32 {
        3
    }

    /// `TaskError::Store` is a store access failure — under WAL with three apps
    /// and a sync engine on one file, overwhelmingly `SQLITE_BUSY`. The trait's
    /// default retries `Retryable` only, so without this override a moment of
    /// write contention would fail a backfill window permanently and the cursor
    /// would never advance past it.
    fn is_retryable(&self, error: &TaskError) -> bool {
        matches!(error, TaskError::Retryable(_) | TaskError::Store(_))
    }
}

/// The text to embed for one item, with the sidecar `source_type` it belongs
/// under. `None` when there is nothing to embed.
fn embeddable_text(item: &Item, schema: &str) -> Option<(String, &'static str)> {
    if schema == CONTENT_CHUNK_SCHEMA {
        // `body` is the FTS-indexed copy the source service writes
        // (`indexed_text`); `data.text` is the structured record. Either alone
        // would miss rows written by the other convention.
        let text = payload_string(item, "body")
            .filter(|t| !t.trim().is_empty())
            .or_else(|| chunk_data_text(item))?;
        return Some((text, SOURCE_TYPE_CHUNK));
    }
    let title = payload_string(item, "title").unwrap_or_default();
    let body = payload_string(item, "body").unwrap_or_default();
    let text = format!("{title}\n{body}");
    if text.trim().is_empty() {
        return None;
    }
    Some((text, SOURCE_TYPE_MEMORY))
}

/// `payload.data.text` of a content chunk.
fn chunk_data_text(item: &Item) -> Option<String> {
    match item.payload.get("data") {
        Some(Value::Object(fields)) => match fields.get("text") {
            Some(Value::String(text)) if !text.trim().is_empty() => Some(text.clone()),
            _ => None,
        },
        _ => None,
    }
}

/// Reproducibility stamp for one window. Not a model prompt — there is no
/// prompt — but `agent-run@1.0.0` reserves the field for "what input produced
/// this run", and the window bounds are exactly that.
fn prompt_hash(cursor_created_ms: i64, cursor_id: &str, batch_limit: i64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("embed:{cursor_created_ms}:{cursor_id}:{batch_limit}").as_bytes());
    format!("{:x}", hasher.finalize())
}

fn payload_string(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn payload_i64(item: &Item, field: &str) -> Option<i64> {
    match item.payload.get(field) {
        Some(Value::Int(i)) => Some(*i),
        Some(Value::Float(f)) => Some(*f as i64),
        _ => None,
    }
}

/// Payload keys a spawner writes onto an `impress.memory.embed` task.
pub(crate) fn embed_task_payload(
    cursor_created_ms: i64,
    cursor_id: &str,
    batch_limit: i64,
    model: &str,
    sidecar_path: Option<&str>,
) -> BTreeMap<String, Value> {
    let mut payload = BTreeMap::new();
    payload.insert(
        "title".into(),
        Value::String("Backfill memory embeddings".into()),
    );
    payload.insert("task_kind".into(), Value::String(KIND_EMBED.into()));
    payload.insert(
        "state".into(),
        Value::String(impress_core::task::TaskState::Pending.as_str().into()),
    );
    payload.insert("source_app".into(), Value::String("impel-memory".into()));
    payload.insert("cursor_created_ms".into(), Value::Int(cursor_created_ms));
    payload.insert("cursor_id".into(), Value::String(cursor_id.to_string()));
    payload.insert("batch_limit".into(), Value::Int(batch_limit));
    payload.insert("model".into(), Value::String(model.to_string()));
    if let Some(path) = sidecar_path {
        payload.insert("sidecar_path".into(), Value::String(path.to_string()));
    }
    payload
}
