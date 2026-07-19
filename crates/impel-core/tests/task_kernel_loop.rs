//! Integration tests for the ADR-0015 task kernel: the full ADR-0005 §6
//! loop — spawn → DAG gating → acquire → execute → provenance → retry /
//! escalation / suspension — against a real (in-memory) SQLite item store.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use impel_core::{
    create_task_dag, AgentRunRecord, ExecutionOutcome, ReviewRequest, Scheduler, SchedulerConfig,
    TaskError, TaskExecutor, TaskSpec, TaskStoreApi,
};
use impress_core::item::{ActorKind, Item, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::reference::EdgeType;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::task::TaskState;

// ── helpers ────────────────────────────────────────────────────────────

fn store() -> Arc<SqliteItemStore> {
    Arc::new(SqliteItemStore::open_in_memory().expect("in-memory store"))
}

fn scheduler(store: Arc<SqliteItemStore>) -> Scheduler {
    Scheduler::new(store, SchedulerConfig {
        actor: "impel-test".into(),
        batch: 16,
        start_delay: std::time::Duration::ZERO,
        poll_interval: std::time::Duration::ZERO,
    })
}

fn state_of(store: &SqliteItemStore, id: impress_core::item::ItemId) -> TaskState {
    let item = TaskStoreApi::get_item(store, id).unwrap().unwrap();
    match item.payload.get("state") {
        Some(Value::String(s)) => TaskState::parse(s).expect("canonical state"),
        other => panic!("no state: {other:?}"),
    }
}

/// Values written by `SetPayload("state", …)` operation items on `id`,
/// oldest first. Operation items encode their type in payload:
/// `op_type = "set_payload"`, `op_data = {field, value}`.
fn state_op_values(store: &SqliteItemStore, id: impress_core::item::ItemId) -> Vec<String> {
    store
        .operations_for(id, None)
        .unwrap()
        .iter()
        .filter_map(|op| {
            if !matches!(op.payload.get("op_type"), Some(Value::String(t)) if t == "set_payload") {
                return None;
            }
            match op.payload.get("op_data") {
                Some(Value::Object(m)) => match (m.get("field"), m.get("value")) {
                    (Some(Value::String(f)), Some(Value::String(v))) if f == "state" => {
                        Some(v.clone())
                    }
                    _ => None,
                },
                _ => None,
            }
        })
        .collect()
}

/// Executor whose per-invocation behavior is scripted.
enum Step {
    Complete,
    RetryableFail,
    PermanentFail,
    /// Open a review and suspend.
    Suspend(&'static str),
}

struct Scripted {
    kind: &'static str,
    script: Mutex<Vec<Step>>, // popped front-to-back
    calls: AtomicUsize,
    record_run: bool,
}

impl Scripted {
    fn new(kind: &'static str, script: Vec<Step>) -> Arc<Self> {
        Arc::new(Self {
            kind,
            script: Mutex::new(script),
            calls: AtomicUsize::new(0),
            record_run: false,
        })
    }
    fn with_agent_run(kind: &'static str, script: Vec<Step>) -> Arc<Self> {
        Arc::new(Self {
            kind,
            script: Mutex::new(script),
            calls: AtomicUsize::new(0),
            record_run: true,
        })
    }
}

#[async_trait]
impl TaskExecutor for Scripted {
    fn task_kind(&self) -> &str {
        self.kind
    }
    fn max_retries(&self) -> u32 {
        2
    }
    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.record_run {
            store.record_agent_run(
                task.id,
                AgentRunRecord {
                    agent_id: "scripted".into(),
                    model: "none".into(),
                    prompt_hash: "deadbeef".into(),
                    result_summary: Some("scripted run".into()),
                    token_count: Some(0),
                    duration_ms: Some(1),
                },
            )?;
        }
        let step = self.script.lock().unwrap().pop();
        match step {
            Some(Step::Complete) | None => Ok(ExecutionOutcome::Complete),
            Some(Step::RetryableFail) => Err(TaskError::Retryable("net down".into())),
            Some(Step::PermanentFail) => Err(TaskError::Permanent("bad schema".into())),
            Some(Step::Suspend(q)) => {
                store.open_review(
                    task.id,
                    ReviewRequest {
                        question: q.into(),
                        context: None,
                    },
                    "scripted",
                )?;
                Ok(ExecutionOutcome::Suspended)
            }
        }
    }
}

fn two_task_dag() -> Vec<TaskSpec> {
    vec![
        TaskSpec {
            kind: "alpha".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        },
        TaskSpec {
            kind: "beta".into(),
            description: None,
            depends_on: vec![0],
            operates_on: None,
            output_schema: None,
        },
    ]
}

// ── tests ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn dag_gates_downstream_until_dependency_done() {
    let s = store();
    let ids = create_task_dag(s.as_ref(), &two_task_dag(), "spawner").unwrap();

    let mut sched = scheduler(s.clone());
    sched.register(Scripted::new("alpha", vec![Step::Complete]));
    sched.register(Scripted::new("beta", vec![Step::Complete]));

    // Pass 1: only alpha is ready (beta's DependsOn target not done).
    let r1 = sched.run_once().await.unwrap();
    assert_eq!(r1.acquired, 1, "only alpha acquirable: {r1:?}");
    assert_eq!(state_of(&s, ids[0]), TaskState::Done);
    assert_eq!(state_of(&s, ids[1]), TaskState::Pending);

    // Pass 2: beta unblocked.
    let r2 = sched.run_once().await.unwrap();
    assert_eq!(r2.acquired, 1);
    assert_eq!(state_of(&s, ids[1]), TaskState::Done);
}

#[tokio::test]
async fn state_transitions_are_operation_items() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "alpha".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let mut sched = scheduler(s.clone());
    sched.register(Scripted::new("alpha", vec![Step::Complete]));
    sched.run_once().await.unwrap();

    // The operation stream is the authoritative history (ADR-0005 §3):
    // pending→running and running→done must both appear as SetPayload ops.
    assert_eq!(
        state_op_values(&s, ids[0]),
        vec!["running".to_string(), "done".to_string()]
    );
}

#[tokio::test]
async fn retry_resets_to_pending_then_succeeds() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "flaky".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let mut sched = scheduler(s.clone());
    // Script is popped back-to-front: first call fails, second completes.
    sched.register(Scripted::new("flaky", vec![Step::Complete, Step::RetryableFail]));

    let r1 = sched.run_once().await.unwrap();
    assert_eq!(r1.retried, 1, "{r1:?}");
    assert_eq!(state_of(&s, ids[0]), TaskState::Pending);

    let r2 = sched.run_once().await.unwrap();
    assert_eq!(r2.completed, 1, "{r2:?}");
    assert_eq!(state_of(&s, ids[0]), TaskState::Done);

    // Retry ledger: running→pending reset is in the op history.
    let resets = state_op_values(&s, ids[0])
        .iter()
        .filter(|v| v.as_str() == "pending")
        .count();
    assert_eq!(resets, 1);
}

#[tokio::test]
async fn permanent_failure_fails_immediately_with_error() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "doomed".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let mut sched = scheduler(s.clone());
    sched.register(Scripted::new("doomed", vec![Step::PermanentFail]));

    let r = sched.run_once().await.unwrap();
    assert_eq!(r.failed, 1);
    assert_eq!(state_of(&s, ids[0]), TaskState::Failed);
    let item = TaskStoreApi::get_item(s.as_ref(), ids[0]).unwrap().unwrap();
    assert!(matches!(item.payload.get("error"), Some(Value::String(e)) if e.contains("bad schema")));
}

#[tokio::test]
async fn retries_exhaust_then_fail() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "hopeless".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let mut sched = scheduler(s.clone());
    // Always retryable-fails; max_retries = 2 → attempts 1,2 retry; attempt 3 fails.
    sched.register(Scripted::new(
        "hopeless",
        vec![Step::RetryableFail, Step::RetryableFail, Step::RetryableFail, Step::RetryableFail],
    ));

    let mut failed = false;
    for _ in 0..5 {
        let r = sched.run_once().await.unwrap();
        if r.failed > 0 {
            failed = true;
            break;
        }
    }
    assert!(failed, "task should eventually fail after retries exhaust");
    assert_eq!(state_of(&s, ids[0]), TaskState::Failed);
}

#[tokio::test]
async fn suspension_waits_for_review_resolution() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "careful".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let mut sched = scheduler(s.clone());
    // First call suspends with a review; the resumed call completes.
    sched.register(Scripted::new(
        "careful",
        vec![Step::Complete, Step::Suspend("keep these tags?")],
    ));

    let r1 = sched.run_once().await.unwrap();
    assert_eq!(r1.suspended, 1, "{r1:?}");
    assert_eq!(state_of(&s, ids[0]), TaskState::Running);

    // Still suspended on the next pass — review unresolved.
    let r2 = sched.run_once().await.unwrap();
    assert_eq!(r2.suspended, 1, "{r2:?}");
    assert_eq!(state_of(&s, ids[0]), TaskState::Running);

    // Human resolves the review (a SetPayload op by a human actor).
    let (unresolved, _) = TaskStoreApi::reviews_for(s.as_ref(), ids[0]).unwrap();
    assert_eq!(unresolved.len(), 1);
    s.apply_operation(OperationSpec {
        target_id: unresolved[0].id,
        op_type: OperationType::SetPayload("resolution".into(), Value::String("approved".into())),
        intent: OperationIntent::Editorial,
        reason: None,
        batch_id: None,
        author: "tom".into(),
        author_kind: ActorKind::Human,
        retention: RetentionTier::Durable,
    })
    .unwrap();

    // Resume pass completes the task.
    let r3 = sched.run_once().await.unwrap();
    assert_eq!(r3.resumed, 1, "{r3:?}");
    assert_eq!(state_of(&s, ids[0]), TaskState::Done);
}

#[tokio::test]
async fn agent_runs_are_recorded_with_provenance_edges() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "tracked".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let mut sched = scheduler(s.clone());
    sched.register(Scripted::with_agent_run("tracked", vec![Step::Complete]));
    sched.run_once().await.unwrap();

    // Task carries a ProducedBy edge to the run item (ADR-0005 §5).
    let task = TaskStoreApi::get_item(s.as_ref(), ids[0]).unwrap().unwrap();
    let run_edges: Vec<_> = task
        .references
        .iter()
        .filter(|r| r.edge_type == EdgeType::ProducedBy)
        .collect();
    assert_eq!(run_edges.len(), 1);
    let run = TaskStoreApi::get_item(s.as_ref(), run_edges[0].target)
        .unwrap()
        .unwrap();
    assert_eq!(run.schema, "agent-run@1.0.0");
    assert!(matches!(run.payload.get("prompt_hash"), Some(Value::String(h)) if h == "deadbeef"));
}

#[tokio::test]
async fn missing_executor_escalates_to_failed() {
    let s = store();
    let ids = create_task_dag(
        s.as_ref(),
        &[TaskSpec {
            kind: "orphan".into(),
            description: None,
            depends_on: vec![],
            operates_on: None,
            output_schema: None,
        }],
        "spawner",
    )
    .unwrap();
    let sched = scheduler(s.clone()); // nothing registered
    let r = sched.run_once().await.unwrap();
    assert_eq!(r.failed, 1);
    assert_eq!(state_of(&s, ids[0]), TaskState::Failed);
    let item = TaskStoreApi::get_item(s.as_ref(), ids[0]).unwrap().unwrap();
    assert!(matches!(item.payload.get("error"), Some(Value::String(e)) if e.contains("no executor")));
}
