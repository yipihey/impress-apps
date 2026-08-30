//! ADR-0028 D7 — the two memory executors and their spawner, end to end
//! against a real (in-memory) item store and a real sidecar on disk.
//!
//! **No test here constructs a `SemanticSearch`.** Doing so downloads a ~100MB
//! ONNX model on first run, which has no place in a unit test; the
//! `TextEmbedder` seam exists precisely so the mechanics this crate owns —
//! candidate selection, the keyset cursor, the deterministic vector ids, the
//! sidecar write, the cursor advance — are provable without one.
//!
//! Run with: `cargo test -p impel-memory`

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use impel_core::{
    ExecutionOutcome, Scheduler, SchedulerConfig, TaskError, TaskExecutor, TaskStoreApi,
    AGENT_RUN_SCHEMA, TASK_SCHEMA,
};
use impel_memory::consolidate::{CONSOLIDATE_AGENT_ID, SOURCE_KIND_AGENT_RUNS};
use impel_memory::embed::KIND_EMBED;
use impel_memory::spawn::{FAILED_COOLOFF_MS, WINDOW_LAG_MS, WINDOW_MS};
use impel_memory::{
    plan_memory_tasks, vector_id, EmbedBackfillExecutor, EmbedderProvider,
    MemoryConsolidationExecutor, MemoryPlanConfig, TextEmbedder, KIND_CONSOLIDATE,
    SOURCE_TYPE_CHUNK, SOURCE_TYPE_MEMORY,
};
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::memory_ops::{self, MemoryKind, RecallOptions};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::EdgeType;
use impress_core::schemas::source::CONTENT_CHUNK_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
use impress_core::task::TaskState;
use impress_embeddings::EmbeddingStore;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

fn store() -> Arc<SqliteItemStore> {
    Arc::new(SqliteItemStore::open_in_memory().expect("in-memory store"))
}

fn sidecar() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("embeddings.sqlite");
    (dir, path.to_string_lossy().into_owned())
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// A deterministic stand-in for fastembed. Records what it was asked to embed
/// so a test can assert the *text assembly*, which is the half of the embed
/// path that fails silently: a wrong vector still looks like a vector.
struct StubEmbedder {
    model: String,
    seen: Arc<Mutex<Vec<String>>>,
}

impl TextEmbedder for StubEmbedder {
    fn model_id(&self) -> &str {
        &self.model
    }
    fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        self.seen
            .lock()
            .expect("seen lock")
            .extend(texts.iter().cloned());
        Ok(texts
            .iter()
            .map(|t| vec![t.len() as f32, t.chars().count() as f32, 1.0])
            .collect())
    }
}

struct StubProvider {
    model: String,
    seen: Arc<Mutex<Vec<String>>>,
    /// When set, `embedder_for` fails with this message — the "model host is
    /// down" path.
    fail_with: Option<String>,
}

impl StubProvider {
    fn new(model: &str) -> Self {
        Self {
            model: model.into(),
            seen: Arc::new(Mutex::new(Vec::new())),
            fail_with: None,
        }
    }
}

impl EmbedderProvider for StubProvider {
    fn embedder_for(&self, _model: &str) -> Result<Arc<dyn TextEmbedder>, String> {
        if let Some(message) = &self.fail_with {
            return Err(message.clone());
        }
        Ok(Arc::new(StubEmbedder {
            model: self.model.clone(),
            seen: self.seen.clone(),
        }))
    }
}

const STUB_MODEL: &str = "stub/test-v1";

fn bare_item(schema: &str, payload: BTreeMap<String, Value>) -> Item {
    let now = chrono::Utc::now();
    Item {
        id: Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: "test".into(),
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
        references: vec![],
        parent: None,
    }
}

fn seed_memory(store: &SqliteItemStore, kind: MemoryKind, title: &str, body: &str) -> ItemId {
    let draft = impress_core::memory_ops::MemoryDraft::new(
        kind,
        title,
        body,
        "test-human",
        ActorKind::Human,
    );
    memory_ops::insert_memory_item(store, &draft).expect("seed memory")
}

fn seed_chunk(store: &SqliteItemStore, body: &str) -> ItemId {
    let mut payload = BTreeMap::new();
    payload.insert(
        "title".into(),
        Value::String(CONTENT_CHUNK_SCHEMA.to_string()),
    );
    payload.insert("body".into(), Value::String(body.into()));
    ItemStore::insert(store, bare_item(CONTENT_CHUNK_SCHEMA, payload)).expect("seed chunk")
}

/// A chunk whose text lives only in `payload.data.text` — the structured shape,
/// written when the source service had no `indexed_text` to mirror into `body`.
fn seed_chunk_data_only(store: &SqliteItemStore, text: &str) -> ItemId {
    let mut data = BTreeMap::new();
    data.insert("text".to_string(), Value::String(text.into()));
    let mut payload = BTreeMap::new();
    payload.insert(
        "title".into(),
        Value::String(CONTENT_CHUNK_SCHEMA.to_string()),
    );
    payload.insert("data".into(), Value::Object(data));
    ItemStore::insert(store, bare_item(CONTENT_CHUNK_SCHEMA, payload)).expect("seed chunk")
}

fn insert_task(store: &SqliteItemStore, payload: BTreeMap<String, Value>) -> ItemId {
    ItemStore::insert(store, bare_item(TASK_SCHEMA, payload)).expect("insert task")
}

fn embed_task(
    store: &SqliteItemStore,
    cursor_created_ms: i64,
    cursor_id: &str,
    sidecar_path: &str,
) -> ItemId {
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Backfill".into()));
    payload.insert("task_kind".into(), Value::String(KIND_EMBED.into()));
    payload.insert("state".into(), Value::String("pending".into()));
    payload.insert("cursor_created_ms".into(), Value::Int(cursor_created_ms));
    payload.insert("cursor_id".into(), Value::String(cursor_id.into()));
    payload.insert("batch_limit".into(), Value::Int(64));
    payload.insert("model".into(), Value::String(STUB_MODEL.into()));
    payload.insert(
        "sidecar_path".into(),
        Value::String(sidecar_path.to_string()),
    );
    insert_task(store, payload)
}

fn consolidate_task(store: &SqliteItemStore, start_ms: i64, end_ms: i64) -> ItemId {
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Consolidate".into()));
    payload.insert("task_kind".into(), Value::String(KIND_CONSOLIDATE.into()));
    payload.insert("state".into(), Value::String("pending".into()));
    payload.insert("window_start_ms".into(), Value::Int(start_ms));
    payload.insert("window_end_ms".into(), Value::Int(end_ms));
    payload.insert(
        "source_kind".into(),
        Value::String(SOURCE_KIND_AGENT_RUNS.into()),
    );
    insert_task(store, payload)
}

/// An `agent-run@1.0.0` written the way one of the two real writers writes it.
/// `status: None` is the kernel shape (`record_agent_run` writes no status);
/// `Some("completed")` / `Some("running")` are `AiStore`'s.
fn seed_run(
    store: &SqliteItemStore,
    agent_id: &str,
    model: &str,
    summary: &str,
    status: Option<&str>,
) -> ItemId {
    seed_run_at(store, agent_id, model, summary, status, now_ms())
}

/// Back-dated variant. `modified` is what the consolidation window filters on,
/// so a test that must exclude rows written *during* its own pass has to place
/// its fixtures in the past deliberately.
fn seed_run_at(
    store: &SqliteItemStore,
    agent_id: &str,
    model: &str,
    summary: &str,
    status: Option<&str>,
    modified_ms: i64,
) -> ItemId {
    let mut payload = BTreeMap::new();
    payload.insert("agent_id".into(), Value::String(agent_id.into()));
    payload.insert("model".into(), Value::String(model.into()));
    payload.insert("prompt_hash".into(), Value::String("deadbeef".into()));
    payload.insert("result_summary".into(), Value::String(summary.into()));
    payload.insert("token_count".into(), Value::Int(42));
    if let Some(status) = status {
        payload.insert("status".into(), Value::String(status.into()));
    }
    let mut item = bare_item(AGENT_RUN_SCHEMA, payload);
    let at = chrono::DateTime::from_timestamp_millis(modified_ms).expect("timestamp");
    item.created = at;
    item.modified = at;
    ItemStore::insert(store, item).expect("seed run")
}

fn fetch(store: &SqliteItemStore, id: ItemId) -> Item {
    ItemStore::get(store, id).expect("get").expect("present")
}

fn payload_i64(item: &Item, field: &str) -> Option<i64> {
    match item.payload.get(field) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

fn payload_string(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn count_schema(store: &SqliteItemStore, schema: &str) -> usize {
    ItemStore::query(
        store,
        &ItemQuery {
            schema: Some(schema.to_string()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        },
    )
    .expect("query")
    .len()
}

/// Drive one task through the executor exactly as the scheduler would: fetch
/// the current item (references included), execute, done.
async fn run_task(
    executor: &dyn TaskExecutor,
    store: &Arc<SqliteItemStore>,
    task_id: ItemId,
) -> Result<ExecutionOutcome, TaskError> {
    let task = fetch(store, task_id);
    executor
        .execute(&task, store.as_ref() as &dyn TaskStoreApi)
        .await
}

// ---------------------------------------------------------------------------
// Embed backfill
// ---------------------------------------------------------------------------

#[tokio::test]
async fn embed_writes_one_vector_per_row_with_the_right_model_and_source_type() {
    let store = store();
    let (_dir, path) = sidecar();
    let provider = Arc::new(StubProvider::new(STUB_MODEL));
    let seen = provider.seen.clone();

    let claim = seed_memory(
        &store,
        MemoryKind::Claim,
        "Flux units",
        "The column is in mJy.",
    );
    let chunk = seed_chunk(&store, "A paragraph of extracted PDF text.");
    let data_chunk = seed_chunk_data_only(&store, "Structured chunk text.");

    let executor = EmbedBackfillExecutor::with_provider(store.clone(), provider);
    let task = embed_task(&store, 0, "", &path);
    assert_eq!(
        run_task(&executor, &store, task).await.expect("execute"),
        ExecutionOutcome::Complete
    );

    let sidecar = EmbeddingStore::open(&path).expect("open sidecar");
    assert_eq!(sidecar.vector_count().expect("count"), 3);

    let by_type = |t: &str| {
        sidecar
            .load_vectors_by_type_and_model(t, STUB_MODEL)
            .expect("load")
    };
    let memory_vectors = by_type(SOURCE_TYPE_MEMORY);
    assert_eq!(memory_vectors.len(), 1);
    assert_eq!(memory_vectors[0].source_id, claim.to_string());
    assert_eq!(
        memory_vectors[0].id,
        vector_id(&claim.to_string(), STUB_MODEL).to_string(),
        "the sidecar id must be the pure function of (source_id, model)"
    );

    let chunk_vectors = by_type(SOURCE_TYPE_CHUNK);
    assert_eq!(chunk_vectors.len(), 2);
    let chunk_sources: Vec<String> = chunk_vectors.iter().map(|v| v.source_id.clone()).collect();
    assert!(chunk_sources.contains(&chunk.to_string()));
    assert!(chunk_sources.contains(&data_chunk.to_string()));

    // The text assembly itself: memory rows embed title + body, chunks embed
    // their text — from `body`, or from `data.text` when `body` is absent.
    let seen = seen.lock().expect("seen").clone();
    assert!(seen.contains(&"Flux units\nThe column is in mJy.".to_string()));
    assert!(seen.contains(&"A paragraph of extracted PDF text.".to_string()));
    assert!(seen.contains(&"Structured chunk text.".to_string()));
}

/// Crash replay: the scheduler re-executes a task left `running`, and the
/// deterministic vector id is what makes that an UPSERT rather than a
/// duplicate population.
#[tokio::test]
async fn re_executing_the_same_task_upserts_rather_than_duplicating() {
    let store = store();
    let (_dir, path) = sidecar();
    let executor = EmbedBackfillExecutor::with_provider(
        store.clone(),
        Arc::new(StubProvider::new(STUB_MODEL)),
    );

    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    seed_memory(&store, MemoryKind::Episode, "Two", "Second body.");

    let task = embed_task(&store, 0, "", &path);
    run_task(&executor, &store, task).await.expect("first");
    let after_first = EmbeddingStore::open(&path)
        .expect("open")
        .vector_count()
        .expect("count");

    run_task(&executor, &store, task).await.expect("replay");
    let after_replay = EmbeddingStore::open(&path)
        .expect("open")
        .vector_count()
        .expect("count");

    assert_eq!(after_first, 2);
    assert_eq!(after_replay, after_first, "replay must not add rows");
}

#[tokio::test]
async fn the_cursor_advances_on_the_task_payload_and_the_next_window_is_empty() {
    let store = store();
    let (_dir, path) = sidecar();
    let executor = EmbedBackfillExecutor::with_provider(
        store.clone(),
        Arc::new(StubProvider::new(STUB_MODEL)),
    );

    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    seed_memory(&store, MemoryKind::Claim, "Two", "Second body.");

    let first = embed_task(&store, 0, "", &path);
    run_task(&executor, &store, first).await.expect("execute");
    let first = fetch(&store, first);
    assert_eq!(payload_i64(&first, "embedded_count"), Some(2));
    let cursor_created = payload_i64(&first, "cursor_end_created_ms").expect("cursor_end_created");
    let cursor_id = payload_string(&first, "cursor_end_id").expect("cursor_end_id");
    assert!(!cursor_id.is_empty());

    // Continuing from where the first task stopped must find nothing: that is
    // what "the cursor reached the end" means operationally.
    let second = embed_task(&store, cursor_created, &cursor_id, &path);
    run_task(&executor, &store, second).await.expect("execute");
    let second = fetch(&store, second);
    assert_eq!(payload_i64(&second, "embedded_count"), Some(0));
    assert_eq!(
        payload_i64(&second, "cursor_end_created_ms"),
        Some(cursor_created),
        "an empty window leaves the cursor exactly where it was"
    );
    assert_eq!(payload_string(&second, "cursor_end_id"), Some(cursor_id));
}

/// An empty window must not pay a model load to discover it has nothing to do —
/// on a caught-up store that is the common case, once per poll, forever.
#[tokio::test]
async fn an_empty_window_never_asks_for_an_embedder() {
    let store = store();
    let (_dir, path) = sidecar();
    let mut provider = StubProvider::new(STUB_MODEL);
    provider.fail_with = Some("the model must not be requested".into());
    let executor = EmbedBackfillExecutor::with_provider(store.clone(), Arc::new(provider));

    let task = embed_task(&store, 0, "", &path);
    assert_eq!(
        run_task(&executor, &store, task).await.expect("execute"),
        ExecutionOutcome::Complete
    );
    assert_eq!(payload_i64(&fetch(&store, task), "embedded_count"), Some(0));
}

/// Rows with nothing to embed are a data condition, not a failure — and the
/// cursor must still pass them, or the backfill parks behind them forever.
#[tokio::test]
async fn rows_without_text_are_skipped_but_the_cursor_passes_them() {
    let store = store();
    let (_dir, path) = sidecar();
    let executor = EmbedBackfillExecutor::with_provider(
        store.clone(),
        Arc::new(StubProvider::new(STUB_MODEL)),
    );

    // A memory-schema row with no title and no body. `insert_memory_item`
    // would refuse to write this; a foreign writer or a sync merge can.
    let empty = ItemStore::insert(
        &*store,
        bare_item(MemoryKind::Claim.schema_ref(), BTreeMap::new()),
    )
    .expect("insert empty");

    let task = embed_task(&store, 0, "", &path);
    assert_eq!(
        run_task(&executor, &store, task).await.expect("execute"),
        ExecutionOutcome::Complete
    );
    let task = fetch(&store, task);
    assert_eq!(payload_i64(&task, "embedded_count"), Some(0));
    assert_eq!(
        payload_string(&task, "cursor_end_id"),
        Some(empty.to_string()),
        "the cursor advances past a textless row rather than parking on it"
    );
}

/// The model host being unreachable is transient; the task must retry, not fail.
#[tokio::test]
async fn an_unavailable_model_is_retryable() {
    let store = store();
    let (_dir, path) = sidecar();
    let mut provider = StubProvider::new(STUB_MODEL);
    provider.fail_with = Some("connection refused".into());
    let executor = EmbedBackfillExecutor::with_provider(store.clone(), Arc::new(provider));

    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    let task = embed_task(&store, 0, "", &path);
    let error = run_task(&executor, &store, task)
        .await
        .expect_err("must fail");
    assert!(matches!(error, TaskError::Retryable(_)), "got {error:?}");
    assert!(executor.is_retryable(&error));
}

/// The `is_retryable` override, both executors. The trait default retries
/// `Retryable` only, so a `SQLITE_BUSY` — which arrives as `TaskError::Store` —
/// would fail the task permanently and leave the cursor/window behind forever.
#[test]
fn store_errors_are_retryable_on_both_executors() {
    let store = store();
    let busy = || {
        TaskError::Store(impel_core::TaskStoreError::Store(StoreError::Storage(
            "database is locked".into(),
        )))
    };
    let permanent = TaskError::Permanent("no".into());

    let embed = EmbedBackfillExecutor::with_provider(
        store.clone(),
        Arc::new(StubProvider::new(STUB_MODEL)),
    );
    let consolidate = MemoryConsolidationExecutor::new(store.clone());

    for executor in [
        &embed as &dyn TaskExecutor,
        &consolidate as &dyn TaskExecutor,
    ] {
        assert!(
            executor.is_retryable(&busy()),
            "{}: a store error must retry",
            executor.task_kind()
        );
        assert!(
            executor.is_retryable(&TaskError::Retryable("x".into())),
            "{}: the default behavior must survive the override",
            executor.task_kind()
        );
        assert!(
            !executor.is_retryable(&permanent),
            "{}: permanent stays permanent",
            executor.task_kind()
        );
    }
}

// ---------------------------------------------------------------------------
// Consolidation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn consolidation_distils_terminal_runs_and_skips_running_ones() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());
    let start = now_ms() - 60_000;

    let completed = seed_run(
        &store,
        "impel/keyword-tag",
        "heuristic-v1",
        "3 tag proposal(s)",
        Some("completed"),
    );
    // The kernel shape: `record_agent_run` writes NO status field, and its rows
    // are terminal by construction. A `status == "completed"` filter would skip
    // every one of them.
    let kernel = seed_run(
        &store,
        "impel/metadata-resolve",
        "arxiv",
        "resolved 7 field(s) from arXiv",
        None,
    );
    let running = seed_run(
        &store,
        "impress-ai/inference",
        "local-omlx",
        "streaming",
        Some("running"),
    );

    let task = consolidate_task(&store, start, now_ms() + 60_000);
    assert_eq!(
        run_task(&executor, &store, task).await.expect("execute"),
        ExecutionOutcome::Complete
    );

    let episodes = ItemStore::query(
        &*store,
        &ItemQuery {
            schema: Some(MemoryKind::Episode.schema_ref().to_string()),
            include_tags: false,
            ..Default::default()
        },
    )
    .expect("query episodes");
    assert_eq!(episodes.len(), 2, "one episode per terminal run, no more");

    let evidence: Vec<String> = episodes
        .iter()
        .flat_map(|e| match e.payload.get("evidence_refs") {
            Some(Value::Array(values)) => values
                .iter()
                .filter_map(|v| match v {
                    Value::String(s) => Some(s.clone()),
                    _ => None,
                })
                .collect::<Vec<_>>(),
            _ => vec![],
        })
        .collect();
    assert!(evidence.contains(&completed.to_string().to_lowercase()));
    assert!(evidence.contains(&kernel.to_string().to_lowercase()));
    assert!(
        !evidence.contains(&running.to_string().to_lowercase()),
        "a run still in flight is not history yet"
    );

    // Recall-able through the kernel, not merely present as rows.
    let recalled = memory_ops::recall(
        &store,
        "metadata-resolve",
        &RecallOptions {
            kinds: vec![MemoryKind::Episode],
            ..Default::default()
        },
    )
    .expect("recall");
    assert!(
        recalled.iter().any(|e| e.body.contains("arxiv")),
        "the distilled episode must come back from recall: {recalled:?}"
    );
}

/// The episode carries the `task_kind` of the work the run performed — the one
/// field that makes "how did this kind of task go last time?" a query rather
/// than a re-read. It is a best-effort graph walk (run —ProducedBy→ task), so
/// it needs a run written the way the kernel actually writes one.
#[tokio::test]
async fn an_episode_carries_the_task_kind_of_the_run_it_distils() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());

    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Resolve metadata".into()));
    payload.insert("task_kind".into(), Value::String("metadata-resolve".into()));
    payload.insert("state".into(), Value::String("pending".into()));
    let source_task = insert_task(&store, payload);
    TaskStoreApi::record_agent_run(
        &*store,
        source_task,
        impel_core::AgentRunRecord {
            agent_id: "impel/metadata-resolve".into(),
            model: "arxiv".into(),
            prompt_hash: "abc".into(),
            result_summary: Some("resolved 7 field(s)".into()),
            token_count: None,
            duration_ms: Some(120),
        },
    )
    .expect("record run");

    let task = consolidate_task(&store, now_ms() - 60_000, now_ms() + 60_000);
    run_task(&executor, &store, task).await.expect("execute");

    let episodes = ItemStore::query(
        &*store,
        &ItemQuery {
            schema: Some(MemoryKind::Episode.schema_ref().to_string()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        },
    )
    .expect("query");
    assert_eq!(episodes.len(), 1);
    let episode = &episodes[0];
    assert_eq!(
        payload_string(episode, "task_kind").as_deref(),
        Some("metadata-resolve"),
        "the run's task must be resolved through its ProducedBy edge"
    );
    assert_eq!(
        payload_string(episode, "outcome").as_deref(),
        Some("terminal")
    );
    let body = payload_string(episode, "body").expect("body");
    assert!(body.contains("Task kind: metadata-resolve."), "{body}");
    assert!(body.contains("Task: Resolve metadata."), "{body}");
    assert!(body.contains("Duration: 120 ms."), "{body}");
}

#[tokio::test]
async fn provenance_is_one_run_with_derived_from_edges_to_every_source() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());
    let sources = [
        seed_run(&store, "agent/a", "m1", "did a thing", None),
        seed_run(
            &store,
            "agent/b",
            "m2",
            "did another thing",
            Some("completed"),
        ),
    ];

    let task = consolidate_task(&store, now_ms() - 60_000, now_ms() + 60_000);
    run_task(&executor, &store, task).await.expect("execute");

    let runs = ItemStore::query(
        &*store,
        &ItemQuery {
            schema: Some(AGENT_RUN_SCHEMA.to_string()),
            predicates: vec![Predicate::Eq(
                "payload.agent_id".into(),
                Value::String(CONSOLIDATE_AGENT_ID.into()),
            )],
            include_tags: false,
            ..Default::default()
        },
    )
    .expect("query runs");
    assert_eq!(runs.len(), 1, "exactly one provenance run per execution");
    let run = &runs[0];

    let derived: Vec<ItemId> = run
        .references
        .iter()
        .filter(|r| r.edge_type == EdgeType::DerivedFrom)
        .map(|r| r.target)
        .collect();
    for source in sources {
        assert!(
            derived.contains(&source),
            "every consumed run gets a DerivedFrom edge"
        );
    }

    let summary = payload_string(run, "result_summary").expect("summary");
    assert!(
        summary.contains("2 episode(s) from 2 run(s)") && summary.contains("2 inserted"),
        "the summary must carry the real counts: {summary}"
    );

    // Every episode points back at that run, via payload AND the ProducedBy
    // edge `insert_memory_item` mirrors it into.
    let episodes = ItemStore::query(
        &*store,
        &ItemQuery {
            schema: Some(MemoryKind::Episode.schema_ref().to_string()),
            include_tags: false,
            ..Default::default()
        },
    )
    .expect("query episodes");
    assert_eq!(episodes.len(), 2);
    for episode in &episodes {
        assert_eq!(
            payload_string(episode, "agent_run_ref"),
            Some(run.id.to_string())
        );
        assert!(episode
            .references
            .iter()
            .any(|r| r.edge_type == EdgeType::ProducedBy && r.target == run.id));
    }
}

/// A second task over the same window must add nothing. Both defences are live
/// here: the D6 gate confirms the near-identical body, and the deterministic
/// key would resolve to the same row even if it did not.
#[tokio::test]
async fn a_second_pass_over_the_same_window_adds_no_episodes() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());
    seed_run(&store, "agent/a", "m1", "did a thing", None);
    seed_run(
        &store,
        "agent/b",
        "m2",
        "did another thing",
        Some("completed"),
    );

    let start = now_ms() - 60_000;
    let end = now_ms() + 60_000;

    let first = consolidate_task(&store, start, end);
    run_task(&executor, &store, first).await.expect("first");
    let after_first = count_schema(&store, MemoryKind::Episode.schema_ref());

    let second = consolidate_task(&store, start, end);
    run_task(&executor, &store, second).await.expect("second");
    let after_second = count_schema(&store, MemoryKind::Episode.schema_ref());

    assert_eq!(after_first, 2);
    assert_eq!(
        after_second, after_first,
        "replay must not duplicate memory"
    );

    // And the second pass did not consolidate the FIRST pass's own run — that
    // feedback loop would grow one episode per window forever.
    let self_episodes = ItemStore::query(
        &*store,
        &ItemQuery {
            schema: Some(MemoryKind::Episode.schema_ref().to_string()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        },
    )
    .expect("query")
    .into_iter()
    .filter(|e| payload_string(e, "agent_id").as_deref() == Some(CONSOLIDATE_AGENT_ID))
    .count();
    assert_eq!(self_episodes, 0);
}

/// The scheduler's resume pass re-executes a task a crash left `running`. The
/// short-circuit is what keeps that from re-distilling a window — and it must
/// hold from the reverse edge alone, since the two edges `record_agent_run`
/// writes are separate writes and a crash can leave only one.
#[tokio::test]
async fn a_task_that_already_has_its_run_short_circuits() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());
    seed_run(&store, "agent/a", "m1", "did a thing", None);

    let task_id = consolidate_task(&store, now_ms() - 60_000, now_ms() + 60_000);
    let stale = fetch(&store, task_id); // captured BEFORE the run edge exists
    run_task(&executor, &store, task_id).await.expect("first");

    let runs_after_first = count_schema(&store, AGENT_RUN_SCHEMA);
    // Re-execute with the STALE item: its own `references` carry no ProducedBy
    // edge, so only the reverse lookup can save us.
    assert_eq!(
        executor
            .execute(&stale, store.as_ref() as &dyn TaskStoreApi)
            .await
            .expect("replay"),
        ExecutionOutcome::Complete
    );
    assert_eq!(
        count_schema(&store, AGENT_RUN_SCHEMA),
        runs_after_first,
        "a short-circuited replay writes no second provenance run"
    );
}

#[tokio::test]
async fn an_empty_window_still_records_a_run() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());
    let task = consolidate_task(&store, now_ms() - 120_000, now_ms() - 60_000);
    assert_eq!(
        run_task(&executor, &store, task).await.expect("execute"),
        ExecutionOutcome::Complete
    );
    assert_eq!(count_schema(&store, MemoryKind::Episode.schema_ref()), 0);
    assert_eq!(
        count_schema(&store, AGENT_RUN_SCHEMA),
        1,
        "an empty window is still a window that was examined"
    );
}

#[tokio::test]
async fn an_unknown_source_kind_is_permanent() {
    let store = store();
    let executor = MemoryConsolidationExecutor::new(store.clone());
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Consolidate".into()));
    payload.insert("task_kind".into(), Value::String(KIND_CONSOLIDATE.into()));
    payload.insert("state".into(), Value::String("pending".into()));
    payload.insert("window_start_ms".into(), Value::Int(0));
    payload.insert("window_end_ms".into(), Value::Int(now_ms()));
    payload.insert("source_kind".into(), Value::String("transcripts".into()));
    let task = insert_task(&store, payload);

    let error = run_task(&executor, &store, task)
        .await
        .expect_err("must fail");
    assert!(matches!(error, TaskError::Permanent(_)), "got {error:?}");
    assert!(!executor.is_retryable(&error));
}

// ---------------------------------------------------------------------------
// The spawner
// ---------------------------------------------------------------------------

fn plan_config(enabled_embed: bool, enabled_consolidate: bool) -> MemoryPlanConfig {
    MemoryPlanConfig {
        embed_enabled: enabled_embed,
        consolidate_enabled: enabled_consolidate,
        model: STUB_MODEL.into(),
        sidecar_path: Some("/dev/null/unused".into()),
        ..MemoryPlanConfig::default()
    }
}

/// Move a task through the kernel's own transitions, so the fixture is a state
/// the scheduler could actually have produced.
fn drive(store: &SqliteItemStore, task: ItemId, to: TaskState) {
    TaskStoreApi::transition(store, task, TaskState::Running, "test", None).expect("running");
    if to != TaskState::Running {
        TaskStoreApi::transition(store, task, to, "test", None).expect("terminal");
    }
}

#[test]
fn nothing_is_planned_while_the_gates_are_off() {
    let store = store();
    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    let planned = plan_memory_tasks(&store, now_ms(), &MemoryPlanConfig::default()).expect("plan");
    assert!(planned.is_empty(), "a deploy is inert until switched on");
}

#[test]
fn the_first_embed_task_looks_back_one_window_from_an_empty_cursor() {
    let store = store();
    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    let now = now_ms();

    let planned = plan_memory_tasks(&store, now, &plan_config(true, false)).expect("plan");
    assert_eq!(planned.len(), 1);
    let task = fetch(&store, planned[0]);
    assert_eq!(
        payload_string(&task, "task_kind").as_deref(),
        Some(KIND_EMBED)
    );
    assert_eq!(
        payload_i64(&task, "cursor_created_ms"),
        Some(now - WINDOW_MS)
    );
    assert_eq!(payload_string(&task, "cursor_id").as_deref(), Some(""));
    assert_eq!(payload_string(&task, "model").as_deref(), Some(STUB_MODEL));
    assert_eq!(payload_string(&task, "state").as_deref(), Some("pending"));
}

#[test]
fn no_embed_task_is_planned_when_nothing_is_past_the_cursor() {
    let store = store();
    let planned = plan_memory_tasks(&store, now_ms(), &plan_config(true, false)).expect("plan");
    assert!(
        planned.is_empty(),
        "a task whose only work is to find no work must not be spawned"
    );
}

#[test]
fn an_open_task_blocks_a_second_spawn_of_the_same_kind() {
    let store = store();
    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    let config = plan_config(true, true);
    let now = now_ms();

    let first = plan_memory_tasks(&store, now, &config).expect("plan");
    assert_eq!(first.len(), 2, "one of each kind");

    let second = plan_memory_tasks(&store, now, &config).expect("plan");
    assert!(second.is_empty(), "pending tasks gate both kinds");

    // `running` gates too — the whole point is one sweep at a time.
    for id in &first {
        drive(&store, *id, TaskState::Running);
    }
    let third = plan_memory_tasks(&store, now, &config).expect("plan");
    assert!(third.is_empty(), "a running sweep gates the next one");
}

#[test]
fn a_failed_task_cools_off_for_an_hour() {
    let store = store();
    seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    let config = plan_config(true, false);
    let now = now_ms();

    let first = plan_memory_tasks(&store, now, &config).expect("plan");
    assert_eq!(first.len(), 1);
    drive(&store, first[0], TaskState::Failed);

    assert!(
        plan_memory_tasks(&store, now, &config)
            .expect("plan")
            .is_empty(),
        "a fresh failure must not be retried on the very next pass"
    );
    let later = plan_memory_tasks(&store, now + FAILED_COOLOFF_MS + 1_000, &config).expect("plan");
    assert_eq!(later.len(), 1, "the cooloff expires");
}

#[test]
fn the_embed_cursor_chains_through_completed_tasks() {
    let store = store();
    let one = seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    seed_memory(&store, MemoryKind::Claim, "Two", "Second body.");
    let config = plan_config(true, false);
    let now = now_ms();

    let first = plan_memory_tasks(&store, now, &config).expect("plan")[0];
    // Stand in for the executor: record where it stopped, then complete.
    let cursor_created = fetch(&store, one).created.timestamp_millis();
    for (field, value) in [
        ("cursor_end_created_ms", Value::Int(cursor_created)),
        ("cursor_end_id", Value::String(one.to_string())),
    ] {
        TaskStoreApi::apply(
            &*store,
            impress_core::operation::OperationSpec {
                target_id: first,
                op_type: impress_core::operation::OperationType::SetPayload(field.into(), value),
                intent: impress_core::operation::OperationIntent::Routine,
                reason: None,
                batch_id: None,
                author: "test".into(),
                author_kind: ActorKind::Agent,
                retention: impress_core::operation::RetentionTier::Compactable,
            },
        )
        .expect("set cursor");
    }
    drive(&store, first, TaskState::Done);

    let second = plan_memory_tasks(&store, now, &config).expect("plan");
    assert_eq!(second.len(), 1, "there is still a row past the cursor");
    let task = fetch(&store, second[0]);
    assert_eq!(
        payload_i64(&task, "cursor_created_ms"),
        Some(cursor_created)
    );
    assert_eq!(
        payload_string(&task, "cursor_id"),
        Some(one.to_string()),
        "the next window starts exactly where the last completed one stopped"
    );
}

#[test]
fn consolidation_windows_are_contiguous_and_daily() {
    let store = store();
    let config = plan_config(false, true);
    let now = now_ms();

    let first = plan_memory_tasks(&store, now, &config).expect("plan");
    assert_eq!(first.len(), 1);
    let first_task = fetch(&store, first[0]);
    assert_eq!(
        payload_i64(&first_task, "window_start_ms"),
        Some(now - WINDOW_MS)
    );
    assert_eq!(
        payload_i64(&first_task, "window_end_ms"),
        Some(now - WINDOW_LAG_MS),
        "the window ends behind now, so a settling run is judged after it finishes"
    );
    drive(&store, first[0], TaskState::Done);

    assert!(
        plan_memory_tasks(&store, now, &config)
            .expect("plan")
            .is_empty(),
        "one window per day — not one per poll interval"
    );

    let next_day = now + WINDOW_MS;
    let second = plan_memory_tasks(&store, next_day, &config).expect("plan");
    assert_eq!(second.len(), 1);
    let second_task = fetch(&store, second[0]);
    assert_eq!(
        payload_i64(&second_task, "window_start_ms"),
        payload_i64(&first_task, "window_end_ms"),
        "windows abut: no slice of time is examined twice or skipped"
    );
}

// ---------------------------------------------------------------------------
// Through the real scheduler
// ---------------------------------------------------------------------------

/// The executors must work through `Scheduler::run_once`, not merely when
/// called directly: that is where acquire/transition/complete actually happen,
/// and where an executor that transitioned state itself would break.
#[tokio::test]
async fn the_scheduler_drives_both_kinds_to_done() {
    let store = store();
    let (_dir, path) = sidecar();
    let mut scheduler = Scheduler::new(
        store.clone(),
        SchedulerConfig {
            actor: "impel-test".into(),
            batch: 8,
            start_delay: std::time::Duration::ZERO,
            poll_interval: std::time::Duration::ZERO,
        },
    );
    scheduler.register(Arc::new(
        EmbedBackfillExecutor::with_provider(
            store.clone(),
            Arc::new(StubProvider::new(STUB_MODEL)),
        )
        .with_sidecar_path(path.clone()),
    ));
    scheduler.register(Arc::new(MemoryConsolidationExecutor::new(store.clone())));

    let claim = seed_memory(&store, MemoryKind::Claim, "One", "First body.");
    // Back-dated, and the window closes a second before this pass begins. Both
    // executors write rows the *other* one would otherwise pick up — the embed
    // executor's provenance run is a consolidatable agent-run, and a distilled
    // episode is an embeddable memory item — and `ready_tasks` orders by
    // `created` alone, which does not separate two rows written in the same
    // millisecond. Pinning the window is what makes this assertion about the
    // wiring rather than about which task happened to go first.
    let now = now_ms();
    seed_run_at(&store, "agent/a", "m1", "did a thing", None, now - 10_000);
    let embed = embed_task(&store, 0, "", &path);
    let consolidate = consolidate_task(&store, now - 30_000, now - 1_000);

    let report = scheduler.run_once().await.expect("pass");
    assert_eq!(report.acquired, 2);
    assert_eq!(report.completed, 2);
    assert_eq!(report.failed, 0);

    for id in [embed, consolidate] {
        assert_eq!(
            payload_string(&fetch(&store, id), "state").as_deref(),
            Some("done")
        );
    }
    assert!(
        !EmbeddingStore::open(&path)
            .expect("open")
            .get_vectors(&claim.to_string())
            .expect("get vectors")
            .is_empty(),
        "the seeded claim must have been embedded"
    );
    assert_eq!(count_schema(&store, MemoryKind::Episode.schema_ref()), 1);
}
