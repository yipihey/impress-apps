//! `impress.memory.consolidate` — terminal agent-runs into durable episodes
//! (ADR-0028 D7).
//!
//! v1 is the **deterministic tier only**: no model is involved. Each terminal
//! `agent-run@1.0.0` in the window becomes one structural
//! `memory/episode@1.0.0` — what ran, under which model, how it ended — and
//! every draft goes through the D6 dedup gate, which is what makes the executor
//! safe to replay: consolidating an overlapping window *confirms* the existing
//! episodes instead of duplicating them.
//!
//! # Which agent-runs count as terminal
//!
//! The two writers of `agent-run@1.0.0` disagree about `payload.status`, and
//! the disagreement is load-bearing:
//!
//! * `impress_ai::AiStore` writes inference runs with an explicit lifecycle:
//!   `"running"` → `"completed"` / `"failed"`.
//! * `impel_core::TaskStoreApi::record_agent_run` — the kernel path every
//!   executor in this daemon uses, including both of ours — writes **no status
//!   field at all**. Its rows are terminal by construction: the run item is
//!   created once, after the work, and never updated.
//!
//! So the filter is subtractive: exclude `"running"` and `"failed"`, and treat
//! an ABSENT status as terminal. Requiring `status == "completed"` would look
//! more careful and would silently skip every kernel-written run — which is to
//! say, everything this daemon produces.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use impel_core::{
    AgentRunRecord, ExecutionOutcome, TaskError, TaskExecutor, TaskStoreApi, AGENT_RUN_SCHEMA,
};
use impress_core::item::{ActorKind, Item, ItemId, Value};
use impress_core::memory_ops::{
    self, GateOutcome, MemoryDraft, MemoryKind, GATE_CONFIRM_THRESHOLD,
};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::reference::EdgeType;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use sha2::{Digest, Sha256};

/// Dispatch key: the `task_kind` payload field the scheduler matches on.
pub const KIND_CONSOLIDATE: &str = "impress.memory.consolidate";

/// `agent_id` stamped on this executor's `agent-run@1.0.0` provenance rows —
/// and the marker that keeps consolidation from consolidating itself. Each
/// pass writes one run; without this filter, the next window would distil an
/// episode about it, whose own run the window after would distil again, forever.
pub const CONSOLIDATE_AGENT_ID: &str = "impel-memory/consolidate";

/// Envelope author on every episode this executor writes.
pub const CONSOLIDATE_AUTHOR: &str = "impel-memory";

/// `model` stamped on the provenance run. The tier is the model here: naming it
/// makes "was this window distilled by the deterministic tier or the LLM one?"
/// answerable from the run alone, which matters the moment the LLM tier lands.
pub const DETERMINISTIC_MODEL: &str = "deterministic-v1";

/// Source runs examined per task.
///
/// A cap rather than a page: one task is a bounded unit of work, and a window
/// that overflows it says so in the run summary instead of silently dropping
/// the tail. The window arithmetic in [`crate::plan_memory_tasks`] (24 h) keeps
/// normal operation far below this.
pub const MAX_SOURCE_RUNS: usize = 512;

/// `source_kind` payload value this v1 understands.
pub const SOURCE_KIND_AGENT_RUNS: &str = "agent-runs";

/// One window of consolidation.
pub struct MemoryConsolidationExecutor {
    store: Arc<SqliteItemStore>,
    actor: String,
    gate_threshold: f32,
}

impl MemoryConsolidationExecutor {
    pub fn new(store: Arc<SqliteItemStore>) -> Self {
        Self {
            store,
            actor: CONSOLIDATE_AGENT_ID.to_string(),
            gate_threshold: GATE_CONFIRM_THRESHOLD,
        }
    }

    /// Override the D6 dedup threshold. Tests pin it; production takes the
    /// kernel default, which is where the decision belongs.
    pub fn with_gate_threshold(mut self, threshold: f32) -> Self {
        self.gate_threshold = threshold;
        self
    }

    /// The provenance run this task already produced, if any.
    ///
    /// `record_agent_run` writes the edge in BOTH directions (run —ProducedBy→
    /// task, and task —ProducedBy→ run), so either side answers the question.
    /// Both are checked because the two are separate writes: a crash between
    /// them leaves exactly one, and a replay that consulted only the missing
    /// side would redo the whole window.
    fn existing_run(&self, task: &Item) -> Result<Option<ItemId>, TaskError> {
        for reference in &task.references {
            if reference.edge_type != EdgeType::ProducedBy {
                continue;
            }
            match ItemStore::get(self.store.as_ref(), reference.target) {
                Ok(Some(item)) if item.schema == AGENT_RUN_SCHEMA => return Ok(Some(item.id)),
                Ok(_) => {}
                Err(e) => return Err(TaskError::Retryable(format!("load run reference: {e}"))),
            }
        }
        let runs = ItemStore::query(
            self.store.as_ref(),
            &ItemQuery {
                schema: Some(AGENT_RUN_SCHEMA.into()),
                predicates: vec![Predicate::HasReference(EdgeType::ProducedBy, task.id)],
                limit: Some(1),
                include_tags: false,
                include_references: false,
                ..Default::default()
            },
        )
        .map_err(|e| TaskError::Retryable(format!("query existing run: {e}")))?;
        Ok(runs.first().map(|item| item.id))
    }

    /// Terminal agent-runs modified within `[start, end)`, oldest first.
    fn source_runs(&self, start_ms: i64, end_ms: i64) -> Result<Vec<Item>, TaskError> {
        let runs = ItemStore::query(
            self.store.as_ref(),
            &ItemQuery {
                schema: Some(AGENT_RUN_SCHEMA.into()),
                predicates: vec![
                    Predicate::Gte("modified".into(), Value::Int(start_ms)),
                    Predicate::Lt("modified".into(), Value::Int(end_ms)),
                ],
                sort: vec![SortDescriptor {
                    field: "modified".into(),
                    ascending: true,
                }],
                // +1 so a full page is distinguishable from a window that
                // exactly filled the cap — the summary can then say it
                // truncated rather than guessing.
                limit: Some(MAX_SOURCE_RUNS + 1),
                include_tags: false,
                ..Default::default()
            },
        )
        .map_err(|e| TaskError::Retryable(format!("scan agent runs: {e}")))?;
        // Post-filter in Rust rather than SQL: `status` is absent on the rows
        // that matter most (see the module docs), and "absent OR not in (...)"
        // is clearer here than in a json_extract predicate.
        Ok(runs.into_iter().filter(is_consolidatable).collect())
    }
}

#[async_trait]
impl TaskExecutor for MemoryConsolidationExecutor {
    fn task_kind(&self) -> &str {
        KIND_CONSOLIDATE
    }

    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        let started = Instant::now();

        // Idempotency FIRST, before any scan or write: the scheduler's resume
        // pass re-executes a task a crash left `running`, and a window already
        // distilled must not be distilled twice.
        if self.existing_run(task)?.is_some() {
            return Ok(ExecutionOutcome::Complete);
        }

        let source_kind = payload_string(task, "source_kind")
            .unwrap_or_else(|| SOURCE_KIND_AGENT_RUNS.to_string());
        if source_kind != SOURCE_KIND_AGENT_RUNS {
            // A structural absence: this build has no handler for that source.
            // Retrying cannot grow one.
            return Err(TaskError::Permanent(format!(
                "unsupported source_kind {source_kind:?} (v1 consolidates {SOURCE_KIND_AGENT_RUNS:?})"
            )));
        }
        let window_start = payload_i64(task, "window_start_ms")
            .ok_or_else(|| TaskError::Permanent("task has no window_start_ms".into()))?;
        let window_end = payload_i64(task, "window_end_ms")
            .ok_or_else(|| TaskError::Permanent("task has no window_end_ms".into()))?;

        let mut runs = self.source_runs(window_start, window_end)?;
        let truncated = runs.len() > MAX_SOURCE_RUNS;
        runs.truncate(MAX_SOURCE_RUNS);

        // ── Distil, then gate. Neither step writes. ────────────────────────
        // `gate_fts` is a pure read, so every decision can be made before the
        // provenance run exists — which is what lets the run's `result_summary`
        // carry the real insert/confirm counts instead of a plan.
        let mut drafts: Vec<(MemoryDraft, GateOutcome)> = Vec::with_capacity(runs.len());
        for run in &runs {
            let draft = self.episode_draft(run);
            let outcome = memory_ops::gate_fts(self.store.as_ref(), &draft, self.gate_threshold)
                .map_err(|e| TaskError::Retryable(format!("dedup gate: {e}")))?;
            drafts.push((draft, outcome));
        }
        let to_insert = drafts
            .iter()
            .filter(|(_, outcome)| matches!(outcome, GateOutcome::Insert))
            .count();
        let to_confirm = drafts.len() - to_insert;

        let mut summary = format!(
            "{} episode(s) from {} run(s) ({to_insert} inserted, {to_confirm} confirmed)",
            drafts.len(),
            runs.len()
        );
        if truncated {
            summary.push_str(&format!(
                "; window truncated at {MAX_SOURCE_RUNS} runs — a follow-up window is needed"
            ));
        }

        let run_id = store.record_agent_run(
            task.id,
            AgentRunRecord {
                agent_id: self.actor.clone(),
                model: DETERMINISTIC_MODEL.into(),
                prompt_hash: window_hash(window_start, window_end, &runs),
                result_summary: Some(summary),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
            },
        )?;

        for (mut draft, outcome) in drafts {
            match outcome {
                GateOutcome::Insert => {
                    // The consolidation's OWN run is the episode's producer;
                    // the source run is its evidence. Set here rather than in
                    // `episode_draft` because the run id does not exist until
                    // the counts it summarises are known.
                    draft.agent_run_ref = Some(run_id.to_string());
                    memory_ops::insert_memory_item(self.store.as_ref(), &draft)
                        .map_err(|e| TaskError::Retryable(format!("insert episode: {e}")))?;
                }
                GateOutcome::Confirm(existing) => {
                    memory_ops::confirm(
                        self.store.as_ref(),
                        existing,
                        CONSOLIDATE_AUTHOR,
                        ActorKind::Agent,
                    )
                    .map_err(|e| TaskError::Retryable(format!("confirm episode: {e}")))?;
                }
            }
        }

        for run in &runs {
            store.add_edge(run_id, run.id, EdgeType::DerivedFrom, &self.actor)?;
        }

        Ok(ExecutionOutcome::Complete)
    }

    fn max_retries(&self) -> u32 {
        2
    }

    /// Same reasoning as the embed executor: `TaskError::Store` is almost
    /// always `SQLITE_BUSY` on a file four processes share, and the trait
    /// default would turn a moment of contention into a permanently skipped
    /// window that no later pass revisits.
    fn is_retryable(&self, error: &TaskError) -> bool {
        matches!(error, TaskError::Retryable(_) | TaskError::Store(_))
    }
}

impl MemoryConsolidationExecutor {
    /// One structural episode from one agent-run. No model, no interpretation —
    /// only fields the run actually carries.
    fn episode_draft(&self, run: &Item) -> MemoryDraft {
        let agent_id = payload_string(run, "agent_id").filter(|s| !s.trim().is_empty());
        let model = payload_string(run, "model").filter(|s| !s.trim().is_empty());
        let task = self.linked_task(run);
        let task_kind = task
            .as_ref()
            .and_then(|t| payload_string(t, "task_kind"))
            .filter(|s| !s.trim().is_empty());
        let task_title = task
            .as_ref()
            .and_then(|t| payload_string(t, "title"))
            .filter(|s| !s.trim().is_empty());

        let subject = agent_id
            .clone()
            .or_else(|| task_title.clone())
            .unwrap_or_else(|| "unattributed run".to_string());
        let title = match &model {
            Some(model) => format!("Episode: {subject} ({model})"),
            None => format!("Episode: {subject}"),
        };

        let status = payload_string(run, "status");
        let outcome = match status.as_deref() {
            Some("completed") => "completed",
            _ => "terminal",
        };

        let mut lines: Vec<String> = Vec::new();
        if let Some(kind) = &task_kind {
            lines.push(format!("Task kind: {kind}."));
        }
        if let Some(title) = &task_title {
            lines.push(format!("Task: {title}."));
        }
        if let Some(agent) = &agent_id {
            lines.push(format!("Agent: {agent}."));
        }
        if let Some(model) = &model {
            lines.push(format!("Model: {model}."));
        }
        if let Some(summary) =
            payload_string(run, "result_summary").filter(|s| !s.trim().is_empty())
        {
            lines.push(format!("Result: {summary}."));
        }
        if let Some(tokens) = payload_i64(run, "token_count") {
            lines.push(format!("Tokens: {tokens}."));
        }
        if let Some(duration) = payload_i64(run, "duration_ms") {
            lines.push(format!("Duration: {duration} ms."));
        }
        if let Some(finish) = payload_string(run, "finish_reason").filter(|s| !s.trim().is_empty())
        {
            lines.push(format!("Finish reason: {finish}."));
        }
        lines.push(format!("Outcome: {outcome}."));
        // `insert_memory_item` rejects an empty body, and `lines` is never
        // empty (the outcome line is unconditional) — so this cannot produce a
        // draft the kernel will refuse.
        let body = lines.join(" ");

        let mut extra: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        extra.insert(
            "outcome".into(),
            serde_json::Value::String(outcome.to_string()),
        );
        if let Some(kind) = task_kind {
            extra.insert("task_kind".into(), serde_json::Value::String(kind));
        }
        extra.insert(
            "approach".into(),
            serde_json::Value::String(DETERMINISTIC_MODEL.to_string()),
        );

        MemoryDraft {
            kind: MemoryKind::Episode,
            title,
            body,
            claim_type: None,
            confidence: None,
            subject_refs: Vec::new(),
            evidence_refs: vec![run.id.to_string()],
            agent_id,
            // Filled in by `execute` once the provenance run exists.
            agent_run_ref: None,
            author: CONSOLIDATE_AUTHOR.into(),
            author_kind: ActorKind::Agent,
            // The idempotency seam: a replay of this window derives the same
            // UUIDv5 and `insert_memory_item` returns the existing row without
            // touching it. The `v1` suffix is the distillation recipe's version
            // — when the recipe changes, the key changes and the new episode
            // supersedes rather than silently rewriting history.
            deterministic_key: Some(format!("consolidate:{}:{}", run.id, "v1")),
            extra,
        }
    }

    /// The task an agent-run was produced for, best-effort.
    ///
    /// Best-effort by design: `record_agent_run` writes the edge, but a run
    /// mirrored in from another writer may not, and a missing task must cost a
    /// field on the episode rather than the episode itself.
    fn linked_task(&self, run: &Item) -> Option<Item> {
        for reference in &run.references {
            if reference.edge_type != EdgeType::ProducedBy {
                continue;
            }
            if let Ok(Some(item)) = ItemStore::get(self.store.as_ref(), reference.target) {
                if item.schema == impel_core::TASK_SCHEMA {
                    return Some(item);
                }
            }
        }
        None
    }
}

/// Whether a run is terminal, and not one of ours. See the module docs.
fn is_consolidatable(run: &Item) -> bool {
    if matches!(run.payload.get("status"), Some(Value::String(s)) if s == "running" || s == "failed")
    {
        return false;
    }
    !matches!(run.payload.get("agent_id"),
              Some(Value::String(agent)) if agent == CONSOLIDATE_AGENT_ID)
}

/// Reproducibility stamp: the window bounds plus the exact source runs consumed.
/// Two runs of the same window over the same data hash the same; a window that
/// gained a row does not.
fn window_hash(start_ms: i64, end_ms: i64, runs: &[Item]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("consolidate:{start_ms}:{end_ms}").as_bytes());
    for run in runs {
        hasher.update(b":");
        hasher.update(run.id.to_string().as_bytes());
    }
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

/// Payload keys a spawner writes onto an `impress.memory.consolidate` task.
pub(crate) fn consolidate_task_payload(
    window_start_ms: i64,
    window_end_ms: i64,
) -> BTreeMap<String, Value> {
    let mut payload = BTreeMap::new();
    payload.insert(
        "title".into(),
        Value::String("Consolidate agent runs into episodes".into()),
    );
    payload.insert("task_kind".into(), Value::String(KIND_CONSOLIDATE.into()));
    payload.insert(
        "state".into(),
        Value::String(impress_core::task::TaskState::Pending.as_str().into()),
    );
    payload.insert("source_app".into(), Value::String("impel-memory".into()));
    payload.insert("window_start_ms".into(), Value::Int(window_start_ms));
    payload.insert("window_end_ms".into(), Value::Int(window_end_ms));
    payload.insert(
        "source_kind".into(),
        Value::String(SOURCE_KIND_AGENT_RUNS.into()),
    );
    payload
}
