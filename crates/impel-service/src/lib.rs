//! `ImpelService` — the task kernel's answer to "what are you doing, and
//! why did that fail?".
//!
//! impel was the one facet of the suite with **no** `#[impress_service]`
//! surface: every other app exposes its capability through the codegen
//! pipeline, while impel's scheduler could only be inspected by reading a
//! 35 MB log file. That gap had teeth. ADR-0005 §3 has been stamping
//! retry-exhausted failures with `OperationIntent::Escalation` since the
//! kernel shipped, and nothing anywhere queried them — the escalation
//! stream wrote into `/dev/null`. When the 2026-09 fixes were deployed the
//! daemon cancelled 830 tasks stranded behind failed dependencies and
//! permanently failed 409 orphans in its first pass, and the only way that
//! became knowable was a human tailing stderr.
//!
//! So these verbs are deliberately the READ paths first — status, failures,
//! the review queue — plus the two writes a human actually needs from a
//! surface that is not the GUI: resolving a review and cancelling a task.
//!
//! Not here, on purpose: **retry**. `failed` is terminal in the ADR-0005 §2
//! transition table, so "retry" cannot be a state move; it has to respawn a
//! fresh DAG for the subject, which is the spawn rules' job and wants its
//! own design (the enrichment guard already respawns after a 24 h cooloff).
//! A verb that quietly resurrected a terminal task would put the kernel's
//! own invariant in the hands of every caller.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use impel_core::{TaskStoreApi, REVIEW_REQUEST_SCHEMA, TASK_SCHEMA};
use impress_core::item::{ActorKind, Item, Value};
use impress_core::job;
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::reference::EdgeType;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_core::task::TaskState;
use impress_service_core::refusal::Refusal;
use impress_service_core::wire::{wire_version, WIRE_VERSION};
use impress_store_service::job as runner;

use impress_service_core::async_trait;
// `impress_method` is a path-only attribute on trait methods; the service
// macro strips it, so the symbol is structurally "unused" — the import must
// still resolve when the macro expands.
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

// ── Reports ─────────────────────────────────────────────────────────────────

/// How many tasks sit in each lifecycle state.
///
/// Two vocabularies share `task@1.0.0`: the kernel writes
/// `pending`/`running`/`done`, impel's GRDB bridge mirrors rows spelled
/// `queued`/`completed`. Counting one spelling silently under-reports the
/// other population, so each bucket sums both.
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TaskStateCounts {
    pub pending: u64,
    pub running: u64,
    pub done: u64,
    pub failed: u64,
    pub cancelled: u64,
}

/// Worker liveness, read from the daemon's status file beside the store.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WorkerReport {
    /// `starting` | `settling` | `ready` | `stopping` | `failed`.
    pub state: String,
    pub pid: u32,
    /// False when the heartbeat is older than the protocol's staleness
    /// window — the daemon is wedged, crashed, or was never started.
    pub is_fresh: bool,
    pub seconds_since_heartbeat: i64,
    pub last_error: Option<String>,
    /// Cumulative counters since this worker started.
    pub acquired_total: u64,
    pub completed_total: u64,
    pub failed_total: u64,
    pub retried_total: u64,
    pub resumed_total: u64,
    pub deferred_total: u64,
    pub adopted_total: u64,
    pub cancelled_total: u64,
    /// CURRENT suspended backlog (a gauge, not a running sum).
    pub suspended_now: u64,
}

/// Everything the scheduler knows about itself in one answer.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SchedulerStatusReport {
    pub tasks: TaskStateCounts,
    /// Tasks by `task_kind`, most numerous first.
    pub by_kind: Vec<KindCount>,
    /// Unresolved `review-request` items — work blocked on a human.
    pub pending_reviews: u64,
    /// Age in days of the OLDEST unresolved review; `null` when none.
    pub oldest_review_age_days: Option<i64>,
    /// `null` when the daemon has never written a status file (not
    /// installed), which is different from "installed but stale".
    pub worker: Option<WorkerReport>,
    /// Human-readable summary of the above.
    pub summary: String,
}

/// What a retention sweep of finished task rows would reclaim.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RetentionReport {
    /// The age window the counts were taken against, in days.
    pub window_days: u32,
    /// Finished tasks older than the window.
    pub sweepable_tasks: u64,
    /// Their review checkpoints, which are deleted with them.
    pub sweepable_reviews: u64,
    /// Operations targeting those tasks. Deleted by cascade, so they never
    /// appear in a sweep's own count — and they are usually most of what a
    /// sweep actually reclaims.
    pub cascading_operations: u64,
    /// Everything the three lines above add up to.
    pub total_reclaimable: u64,
    /// Finished but still inside the window.
    pub retained_terminal_tasks: u64,
    /// Unfinished, so never sweepable at any age.
    pub live_tasks: u64,
    /// Whether ai-server is actually configured to sweep, and what it would
    /// take to change that.
    pub sweeping: String,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct KindCount {
    pub task_kind: String,
    pub count: u64,
}

/// One terminally-failed task, with the reason it failed.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct FailedTaskReport {
    pub id: String,
    pub task_kind: String,
    /// The `error` payload the scheduler recorded.
    pub error: Option<String>,
    /// Title of the item the task operated on, when it still exists —
    /// `null` for an orphan whose subject was deleted, which is itself the
    /// most common reason a task fails permanently.
    pub subject: Option<String>,
    /// Which SpawnRule created it (`spawned_by`), when recorded.
    pub spawned_by: Option<String>,
    pub attempts: i64,
    pub failed_at: String,
}

/// One unresolved human checkpoint.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PendingReviewReport {
    /// Review id — pass to `resolve-review`.
    pub id: String,
    /// The task suspended on this review.
    pub task_id: Option<String>,
    pub question: String,
    /// `context_proposed_tags`, when the review carries a tag proposal.
    pub proposed_tags: Vec<String>,
    pub age_days: i64,
    pub created: String,
}

/// Outcome of a state-changing verb.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ActionReport {
    pub ok: bool,
    pub message: String,
}

// ── Jobs (ADR-0034 D6) ──────────────────────────────────────────────────────

/// A job as its `task@1.0.0` row says it is.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct JobStatusReport {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub message: String,
    pub id: String,
    /// The qualified verb that started it (empty for a kernel task).
    pub kind: String,
    /// `pending | running | done | failed | cancelled`.
    pub state: String,
    /// True once `job_cancel` was called on a running job and the executor
    /// has not yet stopped.
    pub cancel_requested: bool,
    /// Where it ran: `inline:<pid>@<host>` or the daemon's actor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<String>,
    /// The error a failed job recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// True when `job_result` has something to answer.
    pub has_result: bool,
    pub created: String,
    pub modified: String,
    #[serde(default = "wire_version")]
    pub wire_version: u32,
}

/// One progress event, as `surface_events` shapes its own.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct JobEventDto {
    pub seq: u64,
    pub name: String,
    pub payload: serde_json::Value,
    pub at: String,
}

/// Events past a cursor, with the cursor to pass next.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct JobEventsResult {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub message: String,
    pub events: Vec<JobEventDto>,
    /// The last event's `seq`, or the cursor passed in when nothing came.
    pub next_seq: u64,
    /// The ring was pruned past the cursor: events between it and the first
    /// one here are gone.
    pub gap: bool,
    /// The job's state at the time of the read.
    pub state: String,
    #[serde(default = "wire_version")]
    pub wire_version: u32,
}

/// The same, from a long-poll.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct JobWaitResult {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub message: String,
    pub events: Vec<JobEventDto>,
    pub next_seq: u64,
    /// Nothing landed before the deadline; the cursor stands. False when
    /// the job is terminal, which also returns at once.
    pub timed_out: bool,
    pub gap: bool,
    pub state: String,
    /// The job is `done`, `failed` or `cancelled`: stop waiting and read
    /// `job_result`.
    pub finished: bool,
    #[serde(default = "wire_version")]
    pub wire_version: u32,
}

/// What `job_cancel` did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct JobCancelReport {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub message: String,
    /// `cancelled` when the task had not started; `running` when the flag
    /// was set and the executor will stop at its next check.
    pub state: String,
    #[serde(default = "wire_version")]
    pub wire_version: u32,
}

/// The verb's own result, once the job finished.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct JobResultReport {
    /// True when the job is `done` (and its result, if it carries `ok`, says
    /// so). A running job answers `ok: false`, code `not-ready`.
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub message: String,
    pub state: String,
    /// The verb's result exactly as a synchronous call would have answered
    /// it; `null` while running.
    pub result: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default = "wire_version")]
    pub wire_version: u32,
}

/// `job_result` on a job that is still running.
pub const CODE_NOT_READY: &str = "not-ready";

// ── Service ─────────────────────────────────────────────────────────────────

#[impress_service]
pub trait ImpelService: Send + Sync + 'static {
    /// What the impel task scheduler is doing right now: task counts per
    /// lifecycle state and per kind, how much work is blocked on a human,
    /// how old the oldest such block is, and whether the daemon behind it
    /// is actually alive (heartbeat freshness, not just "installed").
    ///
    /// Start here when impel "seems stuck" — a large `pending_reviews`
    /// with a live worker means the queue is waiting on you, while a stale
    /// worker means nothing is running at all.
    #[impress_method(effects(reads = ["task@1.0.0", "review-request@1.0.0"]))]
    #[impress_example(name = "scratch_scheduler_backlog", args = r#"{}"#)]
    async fn scheduler_status(&self) -> SchedulerStatusReport;

    /// Terminally-failed tasks, newest first, each with the recorded error
    /// and the subject it was working on. This is the triage feed ADR-0005
    /// §3 promised: retry-exhausted failures are stamped with an escalation
    /// intent that, until this verb, nothing ever read.
    ///
    /// `limit` 0 means the default (50).
    #[impress_method(effects(reads = ["task@1.0.0"]))]
    #[impress_example(name = "scratch_failed_task", args = r#"{"limit":5}"#)]
    async fn list_failed_tasks(&self, limit: i64) -> Vec<FailedTaskReport>;

    /// The human review queue: unresolved checkpoints, oldest first,
    /// because the oldest are the ones a capacity-bounded queue is about to
    /// expire. Walks the WHOLE population — a newest-N page silently hides
    /// exactly the reviews that most need answering.
    ///
    /// `limit` 0 means the default (50).
    #[impress_method(effects(reads = ["review-request@1.0.0"]))]
    #[impress_example(name = "scratch_review_queue", args = r#"{"limit":5}"#)]
    async fn list_pending_reviews(&self, limit: i64) -> Vec<PendingReviewReport>;

    /// Answer one review checkpoint. `resolution` is `approved` (apply the
    /// proposal) or `rejected` (complete without it) — any other value is
    /// refused rather than written, because the executors compare this
    /// string exactly and an unrecognised one completes the task while
    /// silently applying nothing.
    ///
    /// The suspended task resumes on the scheduler's next pass.
    #[impress_method(safety = mutating, effects(reads = ["review-request@1.0.0", "task@1.0.0"], writes = ["review-request@1.0.0", "task@1.0.0"]))]
    #[impress_example(
        name = "approve_scratch_review",
        args = r#"{"review_id":"5d000000-0000-4000-8000-000000000005","resolution":"approved"}"#,
        expect = r#"{"ok":true}"#
    )]
    async fn resolve_review(&self, review_id: String, resolution: String) -> ActionReport;

    /// Cancel a task that has not started, and every pending task
    /// downstream of it (ADR-0005 §4 forward propagation). A `running` task
    /// gets `cancel_requested` set instead (ADR-0034 D6): the executor
    /// polls it and moves the task to `cancelled` at its next check — the
    /// kernel never interrupts a thread — so this answers at once and
    /// `job_status` shows when it stopped. Refuses a terminal one, since
    /// `done`/`failed`/`cancelled` admit no transition.
    #[impress_method(safety = destructive, effects(reads = ["task@1.0.0"], writes = ["task@1.0.0"]))]
    #[impress_example(
        name = "cancel_scratch_pending_task",
        args = r#"{"task_id":"5d000000-0000-4000-8000-000000000007"}"#,
        expect = r#"{"ok":true}"#
    )]
    async fn cancel_task(&self, task_id: String) -> ActionReport;

    /// A job's row: state, whether a cancel is pending, where it ran, and
    /// whether `job_result` has anything yet. A job is the handle a
    /// long-running verb answered with (`{ok, job: {id, kind, state}}`);
    /// any `task@1.0.0` id works, a kernel task answering with an empty
    /// `kind`.
    #[impress_method]
    #[impress_example(
        name = "scratch_done_job_status",
        args = r#"{"id":"5d000000-0000-4000-8000-000000000008"}"#,
        expect = r#"{"ok":true,"id":"5d000000-0000-4000-8000-000000000008","kind":"smart-search-service_classify-search-input","state":"done","has_result":true}"#
    )]
    async fn job_status(&self, id: String) -> JobStatusReport;

    /// The job's progress events past `after_seq` (0 = from the start),
    /// oldest first, with `next_seq` to pass next time and `gap` when the
    /// ring (200 events) was pruned past the cursor. `limit` 0 = all.
    #[impress_method]
    #[impress_example(
        name = "scratch_job_progress",
        args = r#"{"id":"5d000000-0000-4000-8000-000000000009","after_seq":0,"limit":5}"#,
        expect = r#"{"ok":true,"next_seq":1,"gap":false,"events":[{"seq":1,"name":"indexed","payload":{"papers":3}}]}"#
    )]
    async fn job_events(
        &self,
        id: String,
        after_seq: Option<u64>,
        limit: Option<u32>,
    ) -> JobEventsResult;

    /// Long-poll for the next event past `after_seq`, up to `timeout_ms`
    /// (at most 55000): returns as soon as one lands, at once when the job
    /// has already finished (`finished: true` — read `job_result`), or on
    /// timeout with `timed_out: true` and the cursor unchanged. The loop an
    /// agent runs is `job_wait` from `next_seq` until `finished`.
    #[impress_method]
    #[impress_example(
        name = "scratch_finished_job_wait",
        args = r#"{"id":"5d000000-0000-4000-8000-00000000000a","after_seq":0,"timeout_ms":100}"#,
        expect = r#"{"ok":true,"state":"done","finished":true,"timed_out":false}"#
    )]
    async fn job_wait(&self, id: String, after_seq: Option<u64>, timeout_ms: u64) -> JobWaitResult;

    /// Ask a job to stop. Sets `cancel_requested` on a running job — the
    /// executor stops at its next check and the row goes `cancelled`, which
    /// `job_wait` reports as `finished` — or cancels a job that has not
    /// started outright. Returns at once; idempotent.
    #[impress_method(safety = destructive, effects(reads = ["task@1.0.0"], writes = ["task@1.0.0"]))]
    #[impress_example(
        name = "cancel_scratch_pending_job",
        args = r#"{"id":"5d000000-0000-4000-8000-00000000000b"}"#,
        expect = r#"{"ok":true,"state":"cancelled"}"#
    )]
    async fn job_cancel(&self, id: String) -> JobCancelReport;

    /// The verb's own result, exactly as a synchronous call would have
    /// answered it, once the job is `done` (or what it had when it failed
    /// or was cancelled). `not-ready` while it runs.
    #[impress_method]
    #[impress_example(
        name = "scratch_job_result",
        args = r#"{"id":"5d000000-0000-4000-8000-00000000000c"}"#,
        expect = r#"{"ok":true,"state":"done","result":{"ok":true,"answer":42}}"#
    )]
    async fn job_result(&self, id: String) -> JobResultReport;

    /// How much of the store is finished task bookkeeping, and how much a
    /// retention sweep would reclaim (ADR-0006).
    ///
    /// Read-only — it never deletes anything. The sweep itself belongs to
    /// ai-server's maintenance cadence and is off unless
    /// `IMPRESS_TASK_RETENTION_DAYS` is set, because it destroys history
    /// that cannot be reconstructed: the operations recording a task's
    /// state transitions cascade with it, and the agent-run it produced
    /// survives but can no longer name the task it ran for.
    ///
    /// `window_days` 0 means the default (90).
    #[impress_method(effects(reads = ["task@1.0.0", "review-request@1.0.0", "core/operation"]))]
    #[impress_example(
        name = "scratch_retention_preview",
        args = r#"{"window_days":30}"#,
        expect = r#"{"window_days":30}"#
    )]
    async fn retention_status(&self, window_days: i64) -> RetentionReport;
}

// ── Implementation ──────────────────────────────────────────────────────────

pub struct DefaultImpelService {
    store: Option<Arc<SqliteItemStore>>,
}

impl Default for DefaultImpelService {
    fn default() -> Self {
        Self::new()
    }
}

impl DefaultImpelService {
    pub fn new() -> Self {
        Self { store: None }
    }

    /// Inject a store (tests, embedding hosts).
    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store
            .clone()
            .unwrap_or_else(impress_store_service::store::store_instance)
    }

    /// The workspace directory holding the daemon's status file — the
    /// store's own parent, resolved the same way impel-taskd resolves it so
    /// the two cannot disagree about where the file lives.
    fn workspace() -> PathBuf {
        let path = std::env::var_os("IMPRESS_STORE_PATH")
            .filter(|p| !p.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                dirs::home_dir().unwrap_or_default().join(
                    "Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite",
                )
            });
        path.parent().map(PathBuf::from).unwrap_or_default()
    }

    /// The daemon's status file, read ONLY when this service is using the
    /// process-wide store.
    ///
    /// The file lives in the app-group container, and an UNENTITLED process
    /// blocks forever in `open()` on that path — a kernel-level hang, not an
    /// error (it is why the Swift unit suite diverts SharedContainer under
    /// test). The MCP server is signed with the group entitlement so
    /// production reads it fine; an injected store means a test or an
    /// embedded host, which has no business touching that path at all.
    fn worker_report(&self, store_is_fallback: bool) -> Option<WorkerReport> {
        if self.store.is_some() {
            return None;
        }
        // If the process-wide store could not be opened, this process
        // cannot reach the app-group container at all — and attempting the
        // status file anyway is not a slow failure but an unbounded one:
        // an unentitled process blocks in open() forever, with no error to
        // time out. The store's own bounded open is the probe; its verdict
        // decides this read.
        if store_is_fallback {
            return None;
        }
        let status = impress_ai::read_worker_status(Self::workspace())
            .ok()
            .flatten()?;
        let now = chrono::Utc::now().timestamp_millis();
        Some(WorkerReport {
            state: format!("{:?}", status.state).to_lowercase(),
            pid: status.pid,
            is_fresh: status.is_fresh_at(now),
            seconds_since_heartbeat: (now - status.heartbeat_at_ms) / 1000,
            last_error: status.last_error.clone(),
            acquired_total: status.acquired_total,
            completed_total: status.completed_total,
            failed_total: status.failed_total,
            retried_total: status.retried_total,
            resumed_total: status.resumed_total,
            deferred_total: status.deferred_total,
            adopted_total: status.adopted_total,
            cancelled_total: status.cancelled_total,
            suspended_now: status.suspended_total,
        })
    }

    fn count_state(store: &SqliteItemStore, spellings: &[&str]) -> u64 {
        spellings
            .iter()
            .map(|state| {
                let q = ItemQuery {
                    schema: Some(TASK_SCHEMA),
                    predicates: vec![Predicate::Eq(
                        "payload.state".into(),
                        Value::String((*state).into()),
                    )],
                    include_tags: false,
                    include_references: false,
                    ..Default::default()
                };
                ItemStore::count(store, &q).unwrap_or(0) as u64
            })
            .sum()
    }

    fn payload_string(item: &Item, field: &str) -> Option<String> {
        match item.payload.get(field) {
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            _ => None,
        }
    }

    /// Title of the item a task `OperatesOn`, when that item still exists.
    fn subject_title(store: &SqliteItemStore, task: &Item) -> Option<String> {
        let target = task
            .references
            .iter()
            .find(|r| r.edge_type == EdgeType::OperatesOn)
            .map(|r| r.target)?;
        let item = ItemStore::get(store, target).ok().flatten()?;
        Self::payload_string(&item, "title")
    }

    /// Unresolved reviews, oldest first.
    fn unresolved_reviews(store: &SqliteItemStore) -> Vec<Item> {
        let q = ItemQuery {
            schema: Some(REVIEW_REQUEST_SCHEMA),
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            include_tags: false,
            include_references: true,
            ..Default::default()
        };
        ItemStore::query(store, &q)
            .unwrap_or_default()
            .into_iter()
            .filter(|r| Self::payload_string(r, "resolution").is_none())
            .collect()
    }

    fn days_since(then_ms: i64) -> i64 {
        (chrono::Utc::now().timestamp_millis() - then_ms) / 86_400_000
    }
}

#[async_trait::async_trait]
impl ImpelService for DefaultImpelService {
    async fn scheduler_status(&self) -> SchedulerStatusReport {
        let store = self.store();
        let tasks = TaskStateCounts {
            pending: Self::count_state(&store, &["pending", "queued"]),
            running: Self::count_state(&store, &["running"]),
            done: Self::count_state(&store, &["done", "completed"]),
            failed: Self::count_state(&store, &["failed"]),
            cancelled: Self::count_state(&store, &["cancelled"]),
        };

        // Kind histogram: one scan, counted in memory — there is no index
        // on payload.task_kind and a per-kind count query would be N scans
        // of the same rows.
        let all = ItemStore::query(
            &*store,
            &ItemQuery {
                schema: Some(TASK_SCHEMA),
                include_tags: false,
                include_references: false,
                ..Default::default()
            },
        )
        .unwrap_or_default();
        let mut kinds: BTreeMap<String, u64> = BTreeMap::new();
        for task in &all {
            let kind = Self::payload_string(task, "task_kind").unwrap_or_else(|| "(none)".into());
            *kinds.entry(kind).or_default() += 1;
        }
        let mut by_kind: Vec<KindCount> = kinds
            .into_iter()
            .map(|(task_kind, count)| KindCount { task_kind, count })
            .collect();
        by_kind.sort_by(|a, b| b.count.cmp(&a.count).then(a.task_kind.cmp(&b.task_kind)));

        let reviews = Self::unresolved_reviews(&store);
        let oldest_review_age_days = reviews
            .first()
            .map(|r| Self::days_since(r.created.timestamp_millis()));

        // Ask the store first, then ask whether that store is the empty
        // fallback — the order the store service documents.
        let store_is_fallback =
            self.store.is_none() && impress_store_service::store::store_is_fallback();
        let worker = self.worker_report(store_is_fallback);

        // An unopenable store answers every query with zero rows, which
        // reads exactly like a healthy, idle system. Say which it is.
        if store_is_fallback {
            return SchedulerStatusReport {
                tasks,
                by_kind,
                pending_reviews: reviews.len() as u64,
                oldest_review_age_days,
                worker,
                summary: "STORE UNAVAILABLE — could not open the shared store (busy, or this \
                          process lacks the app-group entitlement), so every count below is 0 \
                          because nothing could be read, NOT because nothing is there."
                    .into(),
            };
        }

        let summary = match &worker {
            Some(w) if !w.is_fresh => format!(
                "Worker is STALE ({}s since heartbeat) — nothing is running. {} pending, {} blocked on review.",
                w.seconds_since_heartbeat, tasks.pending, reviews.len()
            ),
            Some(_) => format!(
                "{} pending, {} running, {} blocked on {} unanswered review(s), {} failed.",
                tasks.pending,
                tasks.running,
                tasks.running.min(reviews.len() as u64),
                reviews.len(),
                tasks.failed
            ),
            None => format!(
                "No worker status file — impel-taskd is not installed or has never run. {} pending, {} failed.",
                tasks.pending, tasks.failed
            ),
        };

        SchedulerStatusReport {
            tasks,
            by_kind,
            pending_reviews: reviews.len() as u64,
            oldest_review_age_days,
            worker,
            summary,
        }
    }

    async fn list_failed_tasks(&self, limit: i64) -> Vec<FailedTaskReport> {
        let store = self.store();
        let cap = if limit <= 0 { 50 } else { limit as usize };
        let q = ItemQuery {
            schema: Some(TASK_SCHEMA),
            predicates: vec![Predicate::Eq(
                "payload.state".into(),
                Value::String("failed".into()),
            )],
            sort: vec![SortDescriptor {
                field: "modified".into(),
                ascending: false,
            }],
            limit: Some(cap),
            include_tags: false,
            include_references: true,
            ..Default::default()
        };
        ItemStore::query(&*store, &q)
            .unwrap_or_default()
            .into_iter()
            .map(|task| FailedTaskReport {
                id: task.id.to_string(),
                task_kind: Self::payload_string(&task, "task_kind").unwrap_or_default(),
                error: Self::payload_string(&task, "error"),
                subject: Self::subject_title(&store, &task),
                spawned_by: Self::payload_string(&task, "spawned_by"),
                attempts: match task.payload.get("attempts") {
                    Some(Value::Int(n)) => *n,
                    _ => 0,
                },
                failed_at: task.modified.to_rfc3339(),
            })
            .collect()
    }

    async fn list_pending_reviews(&self, limit: i64) -> Vec<PendingReviewReport> {
        let store = self.store();
        let cap = if limit <= 0 { 50 } else { limit as usize };
        Self::unresolved_reviews(&store)
            .into_iter()
            .take(cap)
            .map(|review| {
                let task_id = review
                    .references
                    .iter()
                    .find(|r| r.edge_type == EdgeType::OperatesOn)
                    .map(|r| r.target.to_string());
                let proposed_tags = match review.payload.get("context_proposed_tags") {
                    Some(Value::Array(a)) => a
                        .iter()
                        .filter_map(|v| match v {
                            Value::String(s) => Some(s.clone()),
                            _ => None,
                        })
                        .collect(),
                    _ => vec![],
                };
                PendingReviewReport {
                    id: review.id.to_string(),
                    task_id,
                    question: Self::payload_string(&review, "question").unwrap_or_default(),
                    proposed_tags,
                    age_days: Self::days_since(review.created.timestamp_millis()),
                    created: review.created.to_rfc3339(),
                }
            })
            .collect()
    }

    async fn resolve_review(&self, review_id: String, resolution: String) -> ActionReport {
        // Exact-match vocabulary: the executors compare this string
        // literally, so an unrecognised value would complete the task while
        // applying nothing — a silent no-op wearing the shape of a decision.
        if resolution != "approved" && resolution != "rejected" {
            return ActionReport {
                ok: false,
                message: format!(
                    "resolution must be \"approved\" or \"rejected\", got {resolution:?}"
                ),
            };
        }
        let Ok(id) = review_id.parse::<uuid::Uuid>() else {
            return ActionReport {
                ok: false,
                message: format!("not a valid item id: {review_id}"),
            };
        };
        let store = self.store();
        let Ok(Some(review)) = ItemStore::get(&*store, id) else {
            return ActionReport {
                ok: false,
                message: format!("no item {review_id}"),
            };
        };
        if review.schema != REVIEW_REQUEST_SCHEMA {
            return ActionReport {
                ok: false,
                message: format!("{review_id} is a {}, not a review", review.schema.as_str()),
            };
        }
        if Self::payload_string(&review, "resolution").is_some() {
            return ActionReport {
                ok: false,
                message: format!("review {review_id} is already resolved"),
            };
        }

        let author = format!("human:{}", whoami_or_unknown());
        let write = |field: &str, value: &str| OperationSpec {
            target_id: id,
            op_type: OperationType::SetPayload(field.into(), Value::String(value.into())),
            intent: OperationIntent::Editorial,
            reason: Some("resolved via impel-service".into()),
            batch_id: None,
            author: author.clone(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        };
        match store.apply_operation_batch(vec![
            write("resolution", &resolution),
            write("resolved_by", &author),
        ]) {
            Ok(_) => ActionReport {
                ok: true,
                message: format!(
                    "review {review_id} resolved {resolution}; the suspended task resumes on the next scheduler pass"
                ),
            },
            Err(error) => ActionReport {
                ok: false,
                message: format!("write failed: {error}"),
            },
        }
    }

    async fn cancel_task(&self, task_id: String) -> ActionReport {
        let Ok(id) = task_id.parse::<uuid::Uuid>() else {
            return ActionReport {
                ok: false,
                message: format!("not a valid item id: {task_id}"),
            };
        };
        let store = self.store();
        let Ok(Some(task)) = ItemStore::get(&*store, id) else {
            return ActionReport {
                ok: false,
                message: format!("no item {task_id}"),
            };
        };
        if task.schema != TASK_SCHEMA {
            return ActionReport {
                ok: false,
                message: format!("{task_id} is a {}, not a task", task.schema.as_str()),
            };
        }
        let state = Self::payload_string(&task, "state")
            .and_then(|s| TaskState::parse_compat(&s))
            .unwrap_or(TaskState::Pending);
        let actor = "impel-service";
        match state {
            TaskState::Running => {
                // ADR-0034 D6: a running task is asked, not interrupted.
                return match impress_core::job::request_cancel(&store, id, actor) {
                    Ok(_) => ActionReport {
                        ok: true,
                        message: format!(
                            "task {task_id} is running; cancel requested — the executor stops at \
                             its next check and the task becomes cancelled (watch job_status)"
                        ),
                    },
                    Err(error) => ActionReport {
                        ok: false,
                        message: format!("cancel request failed: {error}"),
                    },
                };
            }
            s if s.is_terminal() => {
                return ActionReport {
                    ok: false,
                    message: format!("task {task_id} is already {s}"),
                }
            }
            _ => {}
        }

        if let Err(error) = TaskStoreApi::transition(&*store, id, TaskState::Cancelled, actor, None)
        {
            return ActionReport {
                ok: false,
                message: format!("transition failed: {error}"),
            };
        }

        // ADR-0005 §4: cancellation propagates forward, or the dependents
        // sit `pending` behind a target that can never be done — the same
        // zombie class the 2026-09 startup heal had to sweep up.
        let mut cancelled_downstream = 0_usize;
        let mut frontier = vec![id];
        let mut seen = std::collections::HashSet::new();
        while let Some(upstream) = frontier.pop() {
            if !seen.insert(upstream) {
                continue;
            }
            let Ok(dependents) = TaskStoreApi::dependents_of(&*store, upstream) else {
                continue;
            };
            for dependent in dependents {
                let is_pending = Self::payload_string(&dependent, "state")
                    .and_then(|s| TaskState::parse_compat(&s))
                    == Some(TaskState::Pending);
                if is_pending
                    && TaskStoreApi::transition(
                        &*store,
                        dependent.id,
                        TaskState::Cancelled,
                        actor,
                        None,
                    )
                    .is_ok()
                {
                    cancelled_downstream += 1;
                }
                frontier.push(dependent.id);
            }
        }

        ActionReport {
            ok: true,
            message: if cancelled_downstream == 0 {
                format!("task {task_id} cancelled")
            } else {
                format!("task {task_id} cancelled, with {cancelled_downstream} dependent(s)")
            },
        }
    }

    async fn retention_status(&self, window_days: i64) -> RetentionReport {
        let window = if window_days <= 0 {
            DEFAULT_RETENTION_WINDOW_DAYS
        } else {
            window_days.min(u32::MAX as i64) as u32
        };
        let store = self.store();
        // Same honesty rule as `scheduler_status`: an unopenable store
        // answers every count with 0, which reads exactly like a store with
        // no backlog.
        let store_is_fallback =
            self.store.is_none() && impress_store_service::store::store_is_fallback();
        if store_is_fallback {
            return RetentionReport {
                window_days: window,
                sweepable_tasks: 0,
                sweepable_reviews: 0,
                cascading_operations: 0,
                total_reclaimable: 0,
                retained_terminal_tasks: 0,
                live_tasks: 0,
                sweeping: "unknown".into(),
                summary: "STORE UNAVAILABLE — could not open the shared store, so every count \
                          below is 0 because nothing could be read, NOT because nothing is there."
                    .into(),
            };
        }
        let report = match store.task_retention_report(window) {
            Ok(report) => report,
            Err(error) => {
                return RetentionReport {
                    window_days: window,
                    sweepable_tasks: 0,
                    sweepable_reviews: 0,
                    cascading_operations: 0,
                    total_reclaimable: 0,
                    retained_terminal_tasks: 0,
                    live_tasks: 0,
                    sweeping: "unknown".into(),
                    summary: format!("retention report failed: {error}"),
                }
            }
        };
        // The env var is ai-server's, and this process is usually a different
        // one — so report what is set HERE and say so, rather than claiming
        // to know the daemon's configuration.
        let configured = std::env::var(TASK_RETENTION_ENV)
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|days| *days > 0);
        let sweeping = match configured {
            Some(days) => format!("on in this process: {TASK_RETENTION_ENV}={days}"),
            None => format!(
                "off in this process ({TASK_RETENTION_ENV} unset); ai-server sweeps only if it \
                 is set in the daemon's own environment"
            ),
        };
        let summary = if report.sweepable_tasks == 0 {
            format!(
                "Nothing older than {window}d to reclaim. {} live task(s), {} finished within \
                 the window.",
                report.live_tasks, report.retained_terminal_tasks
            )
        } else {
            format!(
                "{} finished task(s) and {} review(s) older than {window}d — {} rows reclaimable \
                 once cascading operations are counted. {} live, {} finished within the window.",
                report.sweepable_tasks,
                report.sweepable_reviews,
                report.total_reclaimable(),
                report.live_tasks,
                report.retained_terminal_tasks,
            )
        };
        RetentionReport {
            window_days: report.window_days,
            sweepable_tasks: report.sweepable_tasks,
            sweepable_reviews: report.sweepable_reviews,
            cascading_operations: report.cascading_operations,
            total_reclaimable: report.total_reclaimable(),
            retained_terminal_tasks: report.retained_terminal_tasks,
            live_tasks: report.live_tasks,
            sweeping,
            summary,
        }
    }

    async fn job_status(&self, id: String) -> JobStatusReport {
        let refused = |r: Refusal| JobStatusReport {
            ok: false,
            code: Some(r.code),
            message: r.message,
            id: id.clone(),
            kind: String::new(),
            state: String::new(),
            cancel_requested: false,
            runner: None,
            error: None,
            has_result: false,
            created: String::new(),
            modified: String::new(),
            wire_version: WIRE_VERSION,
        };
        let job_id = match parse_job_id(&id) {
            Ok(j) => j,
            Err(r) => return refused(r),
        };
        match job::get_job(&self.store(), job_id) {
            Ok(row) => JobStatusReport {
                ok: true,
                code: None,
                message: job_message(&row),
                id,
                kind: row.verb,
                state: row.state.as_str().into(),
                cancel_requested: row.cancel_requested,
                runner: row.runner,
                error: row.error,
                has_result: row.result_json.is_some(),
                created: row.created.to_rfc3339(),
                modified: row.modified.to_rfc3339(),
                wire_version: WIRE_VERSION,
            },
            Err(e) => refused(job_refusal(e)),
        }
    }

    async fn job_events(
        &self,
        id: String,
        after_seq: Option<u64>,
        limit: Option<u32>,
    ) -> JobEventsResult {
        let after_seq = after_seq.unwrap_or(0);
        let refused = |r: Refusal| JobEventsResult {
            ok: false,
            code: Some(r.code),
            message: r.message,
            events: vec![],
            next_seq: after_seq,
            gap: false,
            state: String::new(),
            wire_version: WIRE_VERSION,
        };
        let job_id = match parse_job_id(&id) {
            Ok(j) => j,
            Err(r) => return refused(r),
        };
        let store = self.store();
        let row = match job::get_job(&store, job_id) {
            Ok(row) => row,
            Err(e) => return refused(job_refusal(e)),
        };
        match job::events_after(&store, job_id, after_seq, limit.unwrap_or(0) as usize) {
            Ok(rows) => {
                let (next_seq, gap) = job::cursor_after(&rows, after_seq);
                JobEventsResult {
                    ok: true,
                    code: None,
                    message: events_message(rows.len(), gap),
                    events: rows.iter().map(event_dto).collect(),
                    next_seq,
                    gap,
                    state: row.state.as_str().into(),
                    wire_version: WIRE_VERSION,
                }
            }
            Err(e) => refused(job_refusal(e)),
        }
    }

    async fn job_wait(&self, id: String, after_seq: Option<u64>, timeout_ms: u64) -> JobWaitResult {
        let after_seq = after_seq.unwrap_or(0);
        let refused = |r: Refusal| JobWaitResult {
            ok: false,
            code: Some(r.code),
            message: r.message,
            events: vec![],
            next_seq: after_seq,
            timed_out: false,
            gap: false,
            state: String::new(),
            finished: false,
            wire_version: WIRE_VERSION,
        };
        let job_id = match parse_job_id(&id) {
            Ok(j) => j,
            Err(r) => return refused(r),
        };
        let store = self.store();
        match runner::wait(
            &store,
            job_id,
            after_seq,
            std::time::Duration::from_millis(timeout_ms),
        )
        .await
        {
            Ok(w) => {
                let finished = w.job.state.is_terminal();
                let message = if w.timed_out {
                    "timed out; nothing new".to_string()
                } else if w.events.is_empty() {
                    format!(
                        "job is {}; nothing past the cursor — read job_result",
                        w.job.state
                    )
                } else {
                    events_message(w.events.len(), w.gap)
                };
                JobWaitResult {
                    ok: true,
                    code: None,
                    message,
                    events: w.events.iter().map(event_dto).collect(),
                    next_seq: w.next_seq,
                    timed_out: w.timed_out,
                    gap: w.gap,
                    state: w.job.state.as_str().into(),
                    finished,
                    wire_version: WIRE_VERSION,
                }
            }
            Err(e) => refused(job_refusal(e)),
        }
    }

    async fn job_cancel(&self, id: String) -> JobCancelReport {
        let refused = |r: Refusal| JobCancelReport {
            ok: false,
            code: Some(r.code),
            message: r.message,
            state: String::new(),
            wire_version: WIRE_VERSION,
        };
        let job_id = match parse_job_id(&id) {
            Ok(j) => j,
            Err(r) => return refused(r),
        };
        match job::request_cancel(&self.store(), job_id, "impel-service") {
            Ok(TaskState::Running) => JobCancelReport {
                ok: true,
                code: None,
                message: format!(
                    "cancel requested for job {id}; it stops at its next check — job_wait reports \
                     finished once the row is cancelled"
                ),
                state: TaskState::Running.as_str().into(),
                wire_version: WIRE_VERSION,
            },
            Ok(state) => JobCancelReport {
                ok: true,
                code: None,
                message: format!("job {id} cancelled before it started"),
                state: state.as_str().into(),
                wire_version: WIRE_VERSION,
            },
            Err(e) => refused(job_refusal(e)),
        }
    }

    async fn job_result(&self, id: String) -> JobResultReport {
        let refused = |r: Refusal| JobResultReport {
            ok: false,
            code: Some(r.code),
            message: r.message,
            state: String::new(),
            result: serde_json::Value::Null,
            error: None,
            wire_version: WIRE_VERSION,
        };
        let job_id = match parse_job_id(&id) {
            Ok(j) => j,
            Err(r) => return refused(r),
        };
        let row = match job::get_job(&self.store(), job_id) {
            Ok(row) => row,
            Err(e) => return refused(job_refusal(e)),
        };
        if !row.state.is_terminal() {
            return JobResultReport {
                ok: false,
                code: Some(CODE_NOT_READY.into()),
                message: format!("job {id} is {}; job_wait for it to finish", row.state),
                state: row.state.as_str().into(),
                result: serde_json::Value::Null,
                error: None,
                wire_version: WIRE_VERSION,
            };
        }
        let result = runner::result_of(&row).unwrap_or(serde_json::Value::Null);
        let result_ok = result
            .get("ok")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(true);
        JobResultReport {
            ok: row.state == TaskState::Done && result_ok,
            code: None,
            message: match row.state {
                TaskState::Done => format!("job {id} done"),
                other => format!("job {id} {other}"),
            },
            state: row.state.as_str().into(),
            result,
            error: row.error,
            wire_version: WIRE_VERSION,
        }
    }
}

fn parse_job_id(id: &str) -> Result<uuid::Uuid, Refusal> {
    id.parse::<uuid::Uuid>()
        .map_err(|_| Refusal::invalid_argument(format!("not a valid job id: {id}")))
}

fn job_refusal(e: job::JobError) -> Refusal {
    match e {
        job::JobError::NotFound(id) => Refusal::not_found(format!("no job {id}")),
        job::JobError::NotATask(id, kind) => {
            Refusal::invalid_argument(format!("{id} is a {kind}, not a task"))
        }
        job::JobError::Transition(t) => Refusal::conflict(t.to_string()),
        other => Refusal::store(other),
    }
}

fn job_message(row: &job::JobRow) -> String {
    match (row.state, row.cancel_requested) {
        (TaskState::Running, true) => "running; cancel requested".into(),
        (state, _) => state.as_str().into(),
    }
}

fn events_message(count: usize, gap: bool) -> String {
    if gap {
        format!("{count} event(s); older events past your cursor were pruned from the ring")
    } else {
        format!("{count} event(s)")
    }
}

fn event_dto(row: &job::EventRow) -> JobEventDto {
    JobEventDto {
        seq: row.seq,
        name: row.name.clone(),
        payload: serde_json::from_str(&row.payload_json).unwrap_or(serde_json::Value::Null),
        at: row.at.clone(),
    }
}

/// Age window `retention_status` reports against when the caller names none.
/// Matches ai-server's own reporting default.
const DEFAULT_RETENTION_WINDOW_DAYS: u32 = 90;

/// The variable ai-server reads to decide whether to sweep at all.
const TASK_RETENTION_ENV: &str = "IMPRESS_TASK_RETENTION_DAYS";

fn whoami_or_unknown() -> String {
    std::env::var("USER").unwrap_or_else(|_| "unknown".into())
}

fn impel_instance() -> DefaultImpelService {
    DefaultImpelService::new()
}

impress_service_impl! {
    service = ImpelService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: ["task@1.0.0", "task-event@1.0.0"],
        writes: [],
        reach: [],
    },
    impl = DefaultImpelService,
    instance = || impel_instance(),
    methods = [
        scheduler_status() -> SchedulerStatusReport,
        list_failed_tasks(
            /// Maximum failed tasks to return, newest first; zero selects the default of 50.
            limit: i64
        ) -> Vec<FailedTaskReport>,
        list_pending_reviews(
            /// Maximum unresolved checkpoints to return, oldest first; zero selects 50.
            limit: i64
        ) -> Vec<PendingReviewReport>,
        resolve_review(
            /// UUID of an unresolved review-request row.
            review_id: String,
            /// Exactly `approved` or `rejected`; any other answer is refused.
            resolution: String
        ) -> ActionReport,
        cancel_task(
            /// UUID of the task to cancel, including pending downstream tasks.
            task_id: String
        ) -> ActionReport,
        retention_status(
            /// Age cutoff in days for the read-only preview; zero selects 90.
            window_days: i64
        ) -> RetentionReport,
        job_status(
            /// UUID of an ordinary kernel task or long-running verb job.
            id: String
        ) -> JobStatusReport,
        job_events(
            /// UUID of the job whose progress events are needed.
            id: String,
            /// Last seen sequence; null or zero starts at the beginning.
            after_seq: Option<u64>,
            /// Maximum events; null or zero returns all currently retained events.
            limit: Option<u32>
        ) -> JobEventsResult,
        job_wait(
            /// UUID of the job to await.
            id: String,
            /// Last seen event sequence; null or zero starts at the beginning.
            after_seq: Option<u64>,
            /// Wait deadline in milliseconds, capped at 55,000 by the runner.
            timeout_ms: u64
        ) -> JobWaitResult,
        job_cancel(
            /// UUID of a pending or running job to request cancellation for.
            id: String
        ) -> JobCancelReport,
        job_result(
            /// UUID of the finished job whose original verb result is needed.
            id: String
        ) -> JobResultReport,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use impel_core::{create_task_dag, SpawnProvenance, TaskSpec};
    use impress_core::sqlite_store::SqliteItemStore;

    fn service() -> (DefaultImpelService, Arc<SqliteItemStore>) {
        let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
        (DefaultImpelService::with_store(store.clone()), store)
    }

    fn spec(kind: &str, depends_on: Vec<usize>) -> TaskSpec {
        TaskSpec {
            kind: kind.into(),
            description: None,
            depends_on,
            operates_on: None,
            output_schema: None,
        }
    }

    #[tokio::test]
    async fn status_counts_both_state_vocabularies() {
        let (svc, store) = service();
        let ids = create_task_dag(
            store.as_ref(),
            &[
                spec("metadata-resolve", vec![]),
                spec("keyword-tag", vec![0]),
            ],
            "spawner",
        )
        .unwrap();
        // A bridge-mirrored row speaking the OTHER vocabulary.
        TaskStoreApi::apply(
            store.as_ref(),
            OperationSpec {
                target_id: ids[0],
                op_type: OperationType::SetPayload(
                    "state".into(),
                    Value::String("completed".into()),
                ),
                intent: OperationIntent::Routine,
                reason: None,
                batch_id: None,
                author: "bridge".into(),
                author_kind: ActorKind::Agent,
                retention: RetentionTier::Compactable,
            },
        )
        .unwrap();

        let status = svc.scheduler_status().await;
        assert_eq!(
            status.tasks.done, 1,
            "`completed` counts as done: {status:?}"
        );
        assert_eq!(status.tasks.pending, 1);
        assert_eq!(status.by_kind.len(), 2);
        // No worker status file in a temp workspace → the summary says so
        // rather than implying a healthy daemon.
        assert!(status.pending_reviews == 0);
    }

    #[tokio::test]
    async fn failed_tasks_report_their_error_and_rule() {
        let (svc, store) = service();
        let ids = impel_core::create_task_dag_from(
            store.as_ref(),
            &[spec("keyword-tag", vec![])],
            "impel-taskd",
            Some(&SpawnProvenance {
                rule_id: "impel/enrichment-spawn".into(),
                trigger: None,
            }),
        )
        .unwrap();
        TaskStoreApi::transition(store.as_ref(), ids[0], TaskState::Running, "t", None).unwrap();
        TaskStoreApi::transition(store.as_ref(), ids[0], TaskState::Failed, "t", None).unwrap();
        TaskStoreApi::apply(
            store.as_ref(),
            OperationSpec {
                target_id: ids[0],
                op_type: OperationType::SetPayload(
                    "error".into(),
                    Value::String("permanent: no OperatesOn target".into()),
                ),
                intent: OperationIntent::Anomaly,
                reason: None,
                batch_id: None,
                author: "t".into(),
                author_kind: ActorKind::Agent,
                retention: RetentionTier::Durable,
            },
        )
        .unwrap();

        let failed = svc.list_failed_tasks(0).await;
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].task_kind, "keyword-tag");
        assert!(failed[0].error.as_deref().unwrap().contains("OperatesOn"));
        assert_eq!(
            failed[0].spawned_by.as_deref(),
            Some("impel/enrichment-spawn"),
            "the triage feed names what created the task"
        );
    }

    #[tokio::test]
    async fn resolve_review_refuses_an_unrecognised_resolution() {
        let (svc, store) = service();
        let ids = create_task_dag(store.as_ref(), &[spec("keyword-tag", vec![])], "s").unwrap();
        let review = TaskStoreApi::open_review(
            store.as_ref(),
            ids[0],
            impel_core::ReviewRequest {
                question: "Apply 2 tags?".into(),
                context: None,
            },
            "impel/keyword-tag",
        )
        .unwrap();

        // The executors compare this string exactly; anything else would
        // complete the task while applying nothing.
        let bad = svc.resolve_review(review.to_string(), "yes".into()).await;
        assert!(!bad.ok, "{bad:?}");
        assert!(bad.message.contains("approved"));
        let still = svc.list_pending_reviews(0).await;
        assert_eq!(still.len(), 1, "refusal must not write");

        let good = svc
            .resolve_review(review.to_string(), "approved".into())
            .await;
        assert!(good.ok, "{good:?}");
        assert!(svc.list_pending_reviews(0).await.is_empty());

        // Second resolution is refused rather than silently overwriting a
        // human's recorded decision.
        let again = svc
            .resolve_review(review.to_string(), "rejected".into())
            .await;
        assert!(!again.ok);
        assert!(again.message.contains("already resolved"));
    }

    #[tokio::test]
    async fn cancel_propagates_forward_and_refuses_running_or_terminal() {
        let (svc, store) = service();
        let ids = create_task_dag(
            store.as_ref(),
            &[
                spec("metadata-resolve", vec![]),
                spec("keyword-tag", vec![0]),
            ],
            "s",
        )
        .unwrap();

        let report = svc.cancel_task(ids[0].to_string()).await;
        assert!(report.ok, "{report:?}");
        assert!(
            report.message.contains("1 dependent"),
            "downstream cancelled too: {report:?}"
        );
        for id in &ids {
            let item = TaskStoreApi::get_item(store.as_ref(), *id)
                .unwrap()
                .unwrap();
            assert!(matches!(item.payload.get("state"),
                             Some(Value::String(s)) if s == "cancelled"));
        }

        // Already terminal → refused, not re-cancelled.
        let again = svc.cancel_task(ids[0].to_string()).await;
        assert!(!again.ok);
        assert!(again.message.contains("already cancelled"));

        // Running → the flag is set (ADR-0034 D6); the executor stops it.
        let running = create_task_dag(store.as_ref(), &[spec("alpha", vec![])], "s").unwrap();
        TaskStoreApi::transition(store.as_ref(), running[0], TaskState::Running, "t", None)
            .unwrap();
        let busy = svc.cancel_task(running[0].to_string()).await;
        assert!(busy.ok, "{busy:?}");
        assert!(busy.message.contains("cancel requested"));
        let item = TaskStoreApi::get_item(store.as_ref(), running[0])
            .unwrap()
            .unwrap();
        assert!(matches!(item.payload.get("state"), Some(Value::String(s)) if s == "running"));
        assert!(matches!(
            item.payload.get("cancel_requested"),
            Some(Value::Bool(true))
        ));
    }

    /// The job verbs over an inline job: the handle reads as a job, its
    /// events stream past a cursor, a wait returns on the finish, and the
    /// result is the verb's own.
    #[tokio::test]
    async fn job_verbs_follow_an_inline_job_to_its_result() {
        use impress_store_service::job::{start_inline, JobOutcome};
        let (svc, store) = service();
        let handle = start_inline(
            store.clone(),
            "t-service_slow",
            &serde_json::json!({"n": 2}),
            |ctx| async move {
                ctx.progress("step", serde_json::json!({"i": 1}));
                tokio::time::sleep(std::time::Duration::from_millis(30)).await;
                ctx.progress("step", serde_json::json!({"i": 2}));
                JobOutcome::Done(serde_json::json!({"ok": true, "n": 2}))
            },
        );
        let id = handle.job.unwrap().id;

        let early = svc.job_result(id.clone()).await;
        assert!(!early.ok);
        assert_eq!(early.code.as_deref(), Some(CODE_NOT_READY));

        let mut cursor = 0;
        let mut names = vec![];
        loop {
            let w = svc.job_wait(id.clone(), Some(cursor), 5_000).await;
            assert!(w.ok, "{w:?}");
            assert!(!w.timed_out);
            names.extend(w.events.iter().map(|e| e.name.clone()));
            cursor = w.next_seq;
            if w.finished && w.events.is_empty() {
                break;
            }
        }
        assert_eq!(names, ["step", "step", "finished"]);

        let status = svc.job_status(id.clone()).await;
        assert!(status.ok);
        assert_eq!(status.state, "done");
        assert_eq!(status.kind, "t-service_slow");
        assert!(status.has_result);

        let events = svc.job_events(id.clone(), Some(1), None).await;
        assert_eq!(events.events.len(), 2);
        assert_eq!(events.next_seq, 3);
        assert!(!events.gap);

        let result = svc.job_result(id.clone()).await;
        assert!(result.ok, "{result:?}");
        assert_eq!(result.result["n"], 2);

        // A cancel on a finished job is a conflict, not a write.
        let late = svc.job_cancel(id).await;
        assert!(!late.ok);
        assert_eq!(late.code.as_deref(), Some("conflict"));
    }

    #[tokio::test]
    async fn job_cancel_stops_a_running_job_and_wait_reports_it_finished() {
        use impress_store_service::job::{start_inline, JobOutcome};
        let (svc, store) = service();
        let handle = start_inline(
            store.clone(),
            "t-service_loop",
            &serde_json::json!({}),
            |ctx| async move {
                loop {
                    if ctx.cancel_requested() {
                        return JobOutcome::Cancelled(
                            serde_json::json!({"ok": false, "stopped": true}),
                        );
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            },
        );
        let id = handle.job.unwrap().id;
        let cancel = svc.job_cancel(id.clone()).await;
        assert!(cancel.ok, "{cancel:?}");
        assert_eq!(cancel.state, "running");
        let status = svc.job_status(id.clone()).await;
        assert!(status.cancel_requested || status.state == "cancelled");
        let mut cursor = 0;
        let final_state = loop {
            let w = svc.job_wait(id.clone(), Some(cursor), 5_000).await;
            cursor = w.next_seq;
            if w.finished && w.events.is_empty() {
                break w.state;
            }
        };
        assert_eq!(final_state, "cancelled");
        let result = svc.job_result(id).await;
        assert!(!result.ok);
        assert_eq!(result.state, "cancelled");
        assert_eq!(result.result["stopped"], true);
    }

    #[tokio::test]
    async fn job_verbs_refuse_by_name() {
        let (svc, _store) = service();
        let bad = svc.job_status("nope".into()).await;
        assert_eq!(bad.code.as_deref(), Some("invalid-argument"));
        let missing = svc
            .job_wait(uuid::Uuid::new_v4().to_string(), None, 10)
            .await;
        assert_eq!(missing.code.as_deref(), Some("not-found"));
        let missing = svc
            .job_events(uuid::Uuid::new_v4().to_string(), None, None)
            .await;
        assert_eq!(missing.code.as_deref(), Some("not-found"));
    }

    /// A finished task counts as reclaimable only once it is OLDER than the
    /// window, and a live one never does at any age. Both vocabularies count:
    /// a sweep that knew only `done` would leave every bridge-mirrored
    /// `completed` row behind forever, and that is half the backlog.
    #[tokio::test]
    async fn retention_report_separates_old_finished_work_from_live_work() {
        let (svc, store) = service();
        let ids = create_task_dag(
            store.as_ref(),
            &[
                spec("metadata-resolve", vec![]),
                spec("keyword-tag", vec![]),
                spec("impress.memory.embed", vec![]),
            ],
            "spawner",
        )
        .unwrap();
        // Two finished, in the two spellings; one left pending.
        for (id, state) in [(ids[0], "done"), (ids[1], "completed")] {
            TaskStoreApi::apply(
                store.as_ref(),
                OperationSpec {
                    target_id: id,
                    op_type: OperationType::SetPayload("state".into(), Value::String(state.into())),
                    intent: OperationIntent::Routine,
                    reason: None,
                    batch_id: None,
                    author: "test".into(),
                    author_kind: ActorKind::Agent,
                    retention: RetentionTier::Compactable,
                },
            )
            .unwrap();
        }

        // Everything was written moments ago, so a 30-day window reclaims
        // nothing and reports the finished pair as retained.
        let fresh = svc.retention_status(30).await;
        assert_eq!(fresh.sweepable_tasks, 0);
        assert_eq!(fresh.retained_terminal_tasks, 2);
        assert_eq!(fresh.live_tasks, 1);
        assert!(fresh.summary.contains("Nothing older"), "{}", fresh.summary);

        // A zero-day window makes everything already-written old enough.
        let all = svc.retention_status(-1).await;
        assert_eq!(
            all.window_days, DEFAULT_RETENTION_WINDOW_DAYS,
            "0 is the default, not 0 days"
        );
        let report = store.task_retention_report(0).unwrap();
        assert_eq!(report.sweepable_tasks, 2, "both spellings, not just `done`");
        assert_eq!(report.live_tasks, 1);
        assert!(
            report.cascading_operations > 0,
            "the state transitions cascade with their task and must be counted"
        );
        assert_eq!(report.total_reclaimable(), 2 + report.cascading_operations);

        // And the sweep removes exactly the finished pair, leaving the live
        // task alone.
        let removed = store.sweep_terminal_tasks(0, 100).unwrap();
        assert_eq!(removed, 2);
        let after = svc.retention_status(30).await;
        assert_eq!(after.live_tasks, 1);
        assert_eq!(after.retained_terminal_tasks, 0);
        assert!(TaskStoreApi::get_item(store.as_ref(), ids[2])
            .unwrap()
            .is_some());
    }
}
