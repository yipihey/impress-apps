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
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::reference::EdgeType;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_core::task::TaskState;

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
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskStateCounts {
    pub pending: u64,
    pub running: u64,
    pub done: u64,
    pub failed: u64,
    pub cancelled: u64,
}

/// Worker liveness, read from the daemon's status file beside the store.
#[derive(Debug, Clone, Serialize, Deserialize)]
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
#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KindCount {
    pub task_kind: String,
    pub count: u64,
}

/// One terminally-failed task, with the reason it failed.
#[derive(Debug, Clone, Serialize, Deserialize)]
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
#[derive(Debug, Clone, Serialize, Deserialize)]
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
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionReport {
    pub ok: bool,
    pub message: String,
}

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
    #[impress_method]
    async fn scheduler_status(&self) -> SchedulerStatusReport;

    /// Terminally-failed tasks, newest first, each with the recorded error
    /// and the subject it was working on. This is the triage feed ADR-0005
    /// §3 promised: retry-exhausted failures are stamped with an escalation
    /// intent that, until this verb, nothing ever read.
    ///
    /// `limit` 0 means the default (50).
    #[impress_method]
    async fn list_failed_tasks(&self, limit: i64) -> Vec<FailedTaskReport>;

    /// The human review queue: unresolved checkpoints, oldest first,
    /// because the oldest are the ones a capacity-bounded queue is about to
    /// expire. Walks the WHOLE population — a newest-N page silently hides
    /// exactly the reviews that most need answering.
    ///
    /// `limit` 0 means the default (50).
    #[impress_method]
    async fn list_pending_reviews(&self, limit: i64) -> Vec<PendingReviewReport>;

    /// Answer one review checkpoint. `resolution` is `approved` (apply the
    /// proposal) or `rejected` (complete without it) — any other value is
    /// refused rather than written, because the executors compare this
    /// string exactly and an unrecognised one completes the task while
    /// silently applying nothing.
    ///
    /// The suspended task resumes on the scheduler's next pass.
    #[impress_method]
    async fn resolve_review(&self, review_id: String, resolution: String) -> ActionReport;

    /// Cancel a task that has not started, and every pending task
    /// downstream of it (ADR-0005 §4 forward propagation). Refuses a
    /// `running` task — cancelling work mid-flight needs the executor's
    /// cooperation, which the kernel does not yet have — and refuses a
    /// terminal one, since `done`/`failed`/`cancelled` admit no transition.
    #[impress_method]
    async fn cancel_task(&self, task_id: String) -> ActionReport;
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
                    schema: Some(TASK_SCHEMA.into()),
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
            schema: Some(REVIEW_REQUEST_SCHEMA.into()),
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
                schema: Some(TASK_SCHEMA.into()),
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
            schema: Some(TASK_SCHEMA.into()),
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
        if review.schema.as_str() != REVIEW_REQUEST_SCHEMA {
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
        if task.schema.as_str() != TASK_SCHEMA {
            return ActionReport {
                ok: false,
                message: format!("{task_id} is a {}, not a task", task.schema.as_str()),
            };
        }
        let state = Self::payload_string(&task, "state")
            .and_then(|s| TaskState::parse_compat(&s))
            .unwrap_or(TaskState::Pending);
        match state {
            TaskState::Running => {
                return ActionReport {
                    ok: false,
                    message: format!(
                    "task {task_id} is running; the kernel cannot interrupt an executor mid-flight"
                ),
                }
            }
            s if s.is_terminal() => {
                return ActionReport {
                    ok: false,
                    message: format!("task {task_id} is already {s}"),
                }
            }
            _ => {}
        }

        let actor = "impel-service";
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
}

fn whoami_or_unknown() -> String {
    std::env::var("USER").unwrap_or_else(|_| "unknown".into())
}

fn impel_instance() -> DefaultImpelService {
    DefaultImpelService::new()
}

impress_service_impl! {
    service = ImpelService,
    impl = DefaultImpelService,
    instance = || impel_instance(),
    methods = [
        scheduler_status() -> SchedulerStatusReport,
        list_failed_tasks(limit: i64) -> Vec<FailedTaskReport>,
        list_pending_reviews(limit: i64) -> Vec<PendingReviewReport>,
        resolve_review(review_id: String, resolution: String) -> ActionReport,
        cancel_task(task_id: String) -> ActionReport,
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

        // Running → refused (the kernel cannot interrupt an executor).
        let running = create_task_dag(store.as_ref(), &[spec("alpha", vec![])], "s").unwrap();
        TaskStoreApi::transition(store.as_ref(), running[0], TaskState::Running, "t", None)
            .unwrap();
        let busy = svc.cancel_task(running[0].to_string()).await;
        assert!(!busy.ok);
        assert!(busy.message.contains("running"));
    }
}
