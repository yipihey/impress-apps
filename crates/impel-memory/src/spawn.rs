//! The spawner: at most one open task of each memory kind, ever (ADR-0028 D8).
//!
//! [`plan_memory_tasks`] runs once per `impel-taskd` pass, next to the
//! enrichment and throughline scans. It writes task items **directly** rather
//! than through `create_task_dag`, for the same reason `impress_ai::AiStore`
//! does: a `TaskSpec` has no params channel, and both of these tasks *are*
//! their params — a cursor, a window.
//!
//! # Why the dedup is state-based and keyed by kind
//!
//! `impel-taskd`'s `already_spawned` asks "does ANY task point at this item?"
//! — once-ever semantics, right for enrichment (one entry is enriched once) and
//! catastrophically wrong here: these two tasks are *recurring sweeps* with no
//! per-item target at all, so an `already_spawned`-shaped guard would spawn one
//! task on the first pass and never spawn another. The guard that fits is
//! `has_open_sync_task`'s: look for a NON-TERMINAL task of this kind, and let
//! the completed chain accumulate as the watermark D8 reads.
//!
//! # Why a failed task cools off
//!
//! Nothing here clears an error. If the sidecar path is unwritable or the model
//! cannot load, the next pass would spawn an identical task, fail it
//! identically, and do so every `--poll` seconds — a failure loop that writes
//! more rows than the work would have. One hour of quiet after a failure makes
//! the retry deliberate; the kernel's own retry ladder already covers the
//! transient case inside a single task.

use std::collections::BTreeMap;

use impel_core::{TaskStoreApi, TaskStoreError, TASK_SCHEMA};
use impress_core::item::{ActorId, ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_core::task::TaskState;
use uuid::Uuid;

use crate::consolidate::{consolidate_task_payload, KIND_CONSOLIDATE};
use crate::embed::{embed_task_payload, DEFAULT_BATCH_LIMIT, KIND_EMBED};

/// Env gate for the embed backfill: `1`/`true` registers and plans it.
pub const EMBED_ENV: &str = "IMPRESS_MEMORY_EMBED";

/// Env gate for consolidation: `1`/`true` registers and plans it.
pub const CONSOLIDATE_ENV: &str = "IMPRESS_MEMORY_CONSOLIDATE";

/// Optional override for the embed model id.
pub const EMBED_MODEL_ENV: &str = "IMPRESS_MEMORY_EMBED_MODEL";

/// Consolidation window length, and the first-run look-back for both kinds.
pub const WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

/// How far behind `now` a consolidation window must end.
///
/// The scan filters on `modified`, and an agent-run written moments ago may
/// still be settling (`AiStore` flips `running` → `completed` in a second
/// write). Ending the window a minute back means a run is judged after its
/// lifecycle has finished, not during it.
pub const WINDOW_LAG_MS: i64 = 60_000;

/// Quiet period after a failed task of a kind, before another is spawned.
pub const FAILED_COOLOFF_MS: i64 = 60 * 60 * 1000;

/// Envelope author on the task items this spawner writes.
pub const SPAWN_AUTHOR: &str = "impel-memory";

/// What to plan, and how.
#[derive(Debug, Clone)]
pub struct MemoryPlanConfig {
    pub embed_enabled: bool,
    pub consolidate_enabled: bool,
    /// Rows per embed task.
    pub batch_limit: i64,
    /// Model id written into the embed task, and filtered by on read.
    pub model: String,
    /// Sidecar override; `None` leaves the executor's own default in force.
    pub sidecar_path: Option<String>,
}

impl Default for MemoryPlanConfig {
    fn default() -> Self {
        Self {
            // Off unless asked. A deploy of this crate is inert until the env
            // gates are flipped (ADR-0028 D7).
            embed_enabled: false,
            consolidate_enabled: false,
            batch_limit: DEFAULT_BATCH_LIMIT,
            model: impress_embeddings::semantic::FASTEMBED_MODEL_ID.to_string(),
            sidecar_path: None,
        }
    }
}

impl MemoryPlanConfig {
    /// The daemon's configuration: both gates off unless their env says on.
    pub fn from_env() -> Self {
        let mut config = Self {
            embed_enabled: env_gate_on(EMBED_ENV),
            consolidate_enabled: env_gate_on(CONSOLIDATE_ENV),
            ..Self::default()
        };
        if let Ok(model) = std::env::var(EMBED_MODEL_ENV) {
            if !model.trim().is_empty() {
                config.model = model;
            }
        }
        if let Ok(path) = std::env::var(crate::embed::EMBEDDINGS_PATH_ENV) {
            if !path.trim().is_empty() {
                config.sidecar_path = Some(path);
            }
        }
        config
    }
}

/// Whether an env var reads as on. Absent, empty, `0` and anything unrecognised
/// are off — a gate that guesses is not a gate.
pub fn env_gate_on(name: &str) -> bool {
    match std::env::var(name) {
        Ok(value) => matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true"),
        Err(_) => false,
    }
}

/// Plan this pass. Returns the ids of any tasks created — usually none.
pub fn plan_memory_tasks(
    store: &SqliteItemStore,
    now_ms: i64,
    config: &MemoryPlanConfig,
) -> Result<Vec<ItemId>, TaskStoreError> {
    let mut created = Vec::new();
    if config.embed_enabled {
        if let Some(id) = plan_embed(store, now_ms, config)? {
            created.push(id);
        }
    }
    if config.consolidate_enabled {
        if let Some(id) = plan_consolidate(store, now_ms)? {
            created.push(id);
        }
    }
    Ok(created)
}

fn plan_embed(
    store: &SqliteItemStore,
    now_ms: i64,
    config: &MemoryPlanConfig,
) -> Result<Option<ItemId>, TaskStoreError> {
    if has_open_task(store, KIND_EMBED)? || in_failure_cooloff(store, KIND_EMBED, now_ms)? {
        return Ok(None);
    }
    let (cursor_created_ms, cursor_id) = match newest_done_task(store, KIND_EMBED)? {
        Some(task) => (
            payload_i64(&task, "cursor_end_created_ms").unwrap_or(now_ms - WINDOW_MS),
            payload_string(&task, "cursor_end_id").unwrap_or_default(),
        ),
        // First run looks back one window rather than to the start of time:
        // a full-library backfill is a deliberate act, not something a daemon
        // starts on its own the first time it is switched on.
        None => (now_ms - WINDOW_MS, String::new()),
    };
    if !has_candidate_after(store, cursor_created_ms, &cursor_id)? {
        return Ok(None);
    }
    let payload = embed_task_payload(
        cursor_created_ms,
        &cursor_id,
        config.batch_limit,
        &config.model,
        config.sidecar_path.as_deref(),
    );
    Ok(Some(TaskStoreApi::create_item(store, task_item(payload))?))
}

fn plan_consolidate(
    store: &SqliteItemStore,
    now_ms: i64,
) -> Result<Option<ItemId>, TaskStoreError> {
    if has_open_task(store, KIND_CONSOLIDATE)?
        || in_failure_cooloff(store, KIND_CONSOLIDATE, now_ms)?
    {
        return Ok(None);
    }
    let start = match newest_done_task(store, KIND_CONSOLIDATE)? {
        Some(task) => {
            let last_end = payload_i64(&task, "window_end_ms").unwrap_or(now_ms - WINDOW_MS);
            // One window per day. Without this the daemon would spawn a
            // minute-wide window every poll interval and consolidate the same
            // near-empty slice of time forever.
            if last_end > now_ms - WINDOW_MS {
                return Ok(None);
            }
            last_end
        }
        None => now_ms - WINDOW_MS,
    };
    let end = (now_ms - WINDOW_LAG_MS).min(start + WINDOW_MS);
    if end <= start {
        return Ok(None);
    }
    Ok(Some(TaskStoreApi::create_item(
        store,
        task_item(consolidate_task_payload(start, end)),
    )?))
}

// ---------------------------------------------------------------------------
// Store reads
// ---------------------------------------------------------------------------

/// A non-terminal task of this kind — the concurrency gate and the debounce.
fn has_open_task(store: &SqliteItemStore, kind: &str) -> Result<bool, TaskStoreError> {
    let open = ItemStore::query(
        store,
        &ItemQuery {
            schema: Some(TASK_SCHEMA.into()),
            predicates: vec![
                Predicate::Eq("payload.task_kind".into(), Value::String(kind.into())),
                Predicate::In(
                    "payload.state".into(),
                    vec![
                        Value::String(TaskState::Pending.as_str().into()),
                        // `ready_tasks` dispatches `pending` OR `queued`, so a
                        // `queued` row is genuinely open work and must gate too.
                        Value::String("queued".into()),
                        Value::String(TaskState::Running.as_str().into()),
                    ],
                ),
            ],
            limit: Some(1),
            include_tags: false,
            include_references: false,
            ..Default::default()
        },
    )?;
    Ok(!open.is_empty())
}

/// Whether the most recently touched task of this kind failed within the
/// cooloff.
fn in_failure_cooloff(
    store: &SqliteItemStore,
    kind: &str,
    now_ms: i64,
) -> Result<bool, TaskStoreError> {
    let Some(newest) = newest_task(store, kind, None)? else {
        return Ok(false);
    };
    let failed = matches!(newest.payload.get("state"),
                          Some(Value::String(s)) if s == TaskState::Failed.as_str());
    Ok(failed && now_ms - newest.modified.timestamp_millis() < FAILED_COOLOFF_MS)
}

fn newest_done_task(store: &SqliteItemStore, kind: &str) -> Result<Option<Item>, TaskStoreError> {
    newest_task(store, kind, Some(TaskState::Done.as_str()))
}

/// The newest task of `kind`, optionally restricted to one state.
///
/// Ordered by `modified`, not `created`: the chain advances by state
/// transitions, and the task that most recently *finished* is the one whose
/// cursor is furthest along — a task created earlier can complete later after a
/// retry.
fn newest_task(
    store: &SqliteItemStore,
    kind: &str,
    state: Option<&str>,
) -> Result<Option<Item>, TaskStoreError> {
    let mut predicates = vec![Predicate::Eq(
        "payload.task_kind".into(),
        Value::String(kind.into()),
    )];
    if let Some(state) = state {
        predicates.push(Predicate::Eq(
            "payload.state".into(),
            Value::String(state.into()),
        ));
    }
    let items = ItemStore::query(
        store,
        &ItemQuery {
            schema: Some(TASK_SCHEMA.into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "modified".into(),
                ascending: false,
            }],
            limit: Some(1),
            include_tags: false,
            include_references: false,
            ..Default::default()
        },
    )?;
    Ok(items.into_iter().next())
}

/// Whether at least one embeddable row sits past the cursor.
///
/// `LIMIT 1` on the same keyset predicate the executor scans with: the point is
/// to avoid spawning a task whose only work is to discover it has none, and to
/// do that for the cost of one index probe per pass.
fn has_candidate_after(
    store: &SqliteItemStore,
    cursor_created_ms: i64,
    cursor_id: &str,
) -> Result<bool, TaskStoreError> {
    let schemas = crate::embed::embeddable_schemas();
    let sql = "SELECT 1 FROM items
               WHERE schema_ref IN (?1, ?2, ?3, ?4)
                 AND (created > ?5 OR (created = ?5 AND id > ?6))
               ORDER BY created ASC, id ASC
               LIMIT 1";
    let rows: Vec<i64> = store.query_raw(
        sql,
        &[
            &schemas[0],
            &schemas[1],
            &schemas[2],
            &schemas[3],
            &cursor_created_ms,
            &cursor_id,
        ],
        |row| row.get(0),
    )?;
    Ok(!rows.is_empty())
}

// ---------------------------------------------------------------------------
// Item construction
// ---------------------------------------------------------------------------

fn task_item(payload: BTreeMap<String, Value>) -> Item {
    let now = chrono::Utc::now();
    Item {
        id: Uuid::new_v4(),
        schema: TASK_SCHEMA.into(),
        payload,
        created: now,
        modified: now,
        author: ActorId::from(SPAWN_AUTHOR),
        author_kind: ActorKind::Agent,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        // No `OperatesOn` target: these are sweeps over a window, not work on
        // one item. That absence is also what keeps `impel-taskd`'s
        // `already_spawned` from ever seeing them.
        references: vec![],
        parent: None,
    }
}

fn payload_i64(item: &Item, field: &str) -> Option<i64> {
    match item.payload.get(field) {
        Some(Value::Int(i)) => Some(*i),
        Some(Value::Float(f)) => Some(*f as i64),
        _ => None,
    }
}

fn payload_string(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}
