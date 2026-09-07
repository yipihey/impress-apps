//! `TaskStoreApi` — the impress-core/impel boundary (ADR-0005 §6, ADR-0015 D5).
//!
//! impel touches the item graph exclusively through this facade. It is
//! object-safe so executors receive `&dyn TaskStoreApi` and tests can
//! substitute fakes; the production implementation wraps
//! [`impress_core::sqlite_store::SqliteItemStore`].

use std::collections::BTreeMap;

use chrono::Utc;
use impress_core::item::{ActorId, ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
use impress_core::task::{transition_op, TaskState, TaskTransitionError};
use uuid::Uuid;

/// Schema refs the kernel reads/writes. Canonical per ADR-0005, and since WP
/// C4 the ONLY spellings of these two kinds in the suite: the `impel/…`
/// mirrors ADR-0015 D5 deprecated are deleted, the bare forms impress-core
/// registered are gone, and both constants are re-exported from the single
/// definition next to `ready_tasks` rather than re-typed here. A literal copy
/// is exactly how the spellings diverged in the first place.
pub use impress_core::schemas::task::{AGENT_RUN_SCHEMA, TASK_SCHEMA};

/// Still local: `review-request@1.0.0` is written and read only by impel and
/// is registered nowhere (see `tests/schema_ref_manifest.rs`).
pub const REVIEW_REQUEST_SCHEMA: &str = "review-request@1.0.0";

/// Errors crossing the store boundary.
#[derive(Debug, thiserror::Error)]
pub enum TaskStoreError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Transition(#[from] TaskTransitionError),
    #[error("task {0} not found")]
    TaskNotFound(ItemId),
}

/// Provenance record for one agent/tool invocation (ADR-0005 §5).
#[derive(Debug, Clone)]
pub struct AgentRunRecord {
    pub agent_id: String,
    pub model: String,
    pub prompt_hash: String,
    pub result_summary: Option<String>,
    pub token_count: Option<i64>,
    pub duration_ms: Option<i64>,
}

/// A human-review checkpoint request (ADR-0005 §8 `AwaitHumanResponse`).
#[derive(Debug, Clone)]
pub struct ReviewRequest {
    /// The question the human must answer.
    pub question: String,
    /// Optional structured context (proposal payload, confidence, …).
    pub context: Option<BTreeMap<String, Value>>,
}

/// The store facade impel schedules and executes against.
pub trait TaskStoreApi: Send + Sync {
    fn create_item(&self, item: Item) -> Result<ItemId, TaskStoreError>;
    fn get_item(&self, id: ItemId) -> Result<Option<Item>, TaskStoreError>;
    fn apply(&self, spec: OperationSpec) -> Result<ItemId, TaskStoreError>;

    /// Add a typed edge on `source` pointing at `target`, as an operation
    /// item (attributed provenance, like every other kernel write).
    fn add_edge(
        &self,
        source: ItemId,
        target: ItemId,
        edge: EdgeType,
        author: &str,
    ) -> Result<(), TaskStoreError>;

    /// Pending tasks whose `DependsOn` targets are all `done` (ADR-0005 §4).
    fn ready_tasks(&self, limit: usize) -> Result<Vec<Item>, TaskStoreError>;

    /// Validated state transition; writes the `SetPayload("state", …)`
    /// operation item (ADR-0015 D1). The ONLY way task state moves.
    fn transition(
        &self,
        task_id: ItemId,
        to: TaskState,
        actor: &str,
        intent: Option<OperationIntent>,
    ) -> Result<(), TaskStoreError>;

    /// Record an agent invocation and link `task —ProducedBy→ run`.
    fn record_agent_run(
        &self,
        task_id: ItemId,
        run: AgentRunRecord,
    ) -> Result<ItemId, TaskStoreError>;

    /// Open a review checkpoint: creates a `review-request@1.0.0` item
    /// linked `review —OperatesOn→ task`. The task stays `running` until
    /// the review's `resolution` payload field is set.
    fn open_review(
        &self,
        task_id: ItemId,
        request: ReviewRequest,
        author: &str,
    ) -> Result<ItemId, TaskStoreError>;

    /// The task's review items, newest first: `(unresolved, resolved)`.
    fn reviews_for(&self, task_id: ItemId) -> Result<(Vec<Item>, Vec<Item>), TaskStoreError>;

    /// Tasks currently `running` (used for suspension recovery on restart).
    fn running_tasks(&self, assigned_to: &str) -> Result<Vec<Item>, TaskStoreError>;

    /// Apply several operations atomically (one transaction, one batch id).
    /// A crash or a sibling-writer BUSY timeout either applies ALL of them
    /// or NONE — the primitive `acquire_task` needs so a task can never be
    /// stranded `running` with no `assigned_to`.
    fn apply_batch(&self, specs: Vec<OperationSpec>) -> Result<(), TaskStoreError>;

    /// Atomically acquire `task`: transition → `running`, stamp
    /// `assigned_to` and the incremented `attempts` — one transaction.
    fn acquire_task(&self, task: &Item, actor: &str) -> Result<(), TaskStoreError>;

    /// Target task ids of every UNRESOLVED review-request in the store —
    /// the suspension set, derived in ONE query per pass instead of one
    /// `reviews_for` per running task (the old shape cost ~1,019 queries
    /// per 5s pass at the live backlog).
    fn unresolved_review_targets(
        &self,
    ) -> Result<std::collections::HashSet<ItemId>, TaskStoreError>;

    /// `running` tasks with NO assignee — the wedge a non-atomic acquire
    /// used to strand (invisible to both `ready_tasks` and
    /// `running_tasks`). The scheduler adopts them back to `pending`.
    fn orphaned_running_tasks(&self) -> Result<Vec<Item>, TaskStoreError>;

    /// Tasks that declare `DependsOn → task_id` (direct dependents), for
    /// failure/cancellation propagation (ADR-0005 §4).
    fn dependents_of(&self, task_id: ItemId) -> Result<Vec<Item>, TaskStoreError>;
}

/// Build a bare item envelope for kernel-created items.
fn kernel_item(
    schema: &str,
    payload: BTreeMap<String, Value>,
    author: &str,
    references: Vec<TypedReference>,
) -> Item {
    Item {
        id: Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: ActorId::from(author),
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
        references,
        parent: None,
    }
}

impl TaskStoreApi for SqliteItemStore {
    fn create_item(&self, item: Item) -> Result<ItemId, TaskStoreError> {
        Ok(ItemStore::insert(self, item)?)
    }

    fn get_item(&self, id: ItemId) -> Result<Option<Item>, TaskStoreError> {
        Ok(ItemStore::get(self, id)?)
    }

    fn apply(&self, spec: OperationSpec) -> Result<ItemId, TaskStoreError> {
        Ok(SqliteItemStore::apply_operation(self, spec)?)
    }

    fn add_edge(
        &self,
        source: ItemId,
        target: ItemId,
        edge: EdgeType,
        author: &str,
    ) -> Result<(), TaskStoreError> {
        let spec = OperationSpec {
            target_id: source,
            op_type: OperationType::AddReference(TypedReference {
                target,
                edge_type: edge,
                metadata: None,
            }),
            intent: OperationIntent::Routine,
            reason: None,
            batch_id: None,
            author: ActorId::from(author),
            author_kind: ActorKind::Agent,
            retention: RetentionTier::Durable,
        };
        SqliteItemStore::apply_operation(self, spec)?;
        Ok(())
    }

    fn ready_tasks(&self, limit: usize) -> Result<Vec<Item>, TaskStoreError> {
        // Store-native single-SQL readiness (ADR-0015 D2).
        Ok(SqliteItemStore::ready_tasks(self, limit)?)
    }

    fn transition(
        &self,
        task_id: ItemId,
        to: TaskState,
        actor: &str,
        intent: Option<OperationIntent>,
    ) -> Result<(), TaskStoreError> {
        let task = ItemStore::get(self, task_id)?.ok_or(TaskStoreError::TaskNotFound(task_id))?;
        let spec = transition_op(&task, to, ActorId::from(actor), ActorKind::Agent, intent)?;
        SqliteItemStore::apply_operation(self, spec)?;
        Ok(())
    }

    fn record_agent_run(
        &self,
        task_id: ItemId,
        run: AgentRunRecord,
    ) -> Result<ItemId, TaskStoreError> {
        let mut payload = BTreeMap::new();
        payload.insert("agent_id".into(), Value::String(run.agent_id));
        payload.insert("model".into(), Value::String(run.model));
        payload.insert("prompt_hash".into(), Value::String(run.prompt_hash));
        if let Some(s) = run.result_summary {
            payload.insert("result_summary".into(), Value::String(s));
        }
        if let Some(t) = run.token_count {
            payload.insert("token_count".into(), Value::Int(t));
        }
        if let Some(d) = run.duration_ms {
            payload.insert("duration_ms".into(), Value::Int(d));
        }
        // The run knows which task triggered it…
        let run_item = kernel_item(
            AGENT_RUN_SCHEMA,
            payload,
            "impel",
            vec![TypedReference {
                target: task_id,
                edge_type: EdgeType::ProducedBy,
                metadata: None,
            }],
        );
        let run_id = ItemStore::insert(self, run_item)?;
        // …and the task points at the run for provenance (ADR-0005 §5).
        self.add_edge(task_id, run_id, EdgeType::ProducedBy, "impel")?;
        Ok(run_id)
    }

    fn open_review(
        &self,
        task_id: ItemId,
        request: ReviewRequest,
        author: &str,
    ) -> Result<ItemId, TaskStoreError> {
        let mut payload = BTreeMap::new();
        payload.insert("question".into(), Value::String(request.question));
        if let Some(ctx) = request.context {
            for (k, v) in ctx {
                payload.insert(format!("context_{k}"), v);
            }
        }
        let review = kernel_item(
            REVIEW_REQUEST_SCHEMA,
            payload,
            author,
            vec![TypedReference {
                target: task_id,
                edge_type: EdgeType::OperatesOn,
                metadata: None,
            }],
        );
        Ok(ItemStore::insert(self, review)?)
    }

    fn reviews_for(&self, task_id: ItemId) -> Result<(Vec<Item>, Vec<Item>), TaskStoreError> {
        let q = ItemQuery {
            schema: Some(REVIEW_REQUEST_SCHEMA.into()),
            predicates: vec![Predicate::HasReference(EdgeType::OperatesOn, task_id)],
            // Newest first, for real — the doc promised it while the query
            // had no ORDER BY, so `resolved.first()` picked an arbitrary
            // review whenever a task had several.
            sort: vec![impress_core::query::SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let mut unresolved = Vec::new();
        let mut resolved = Vec::new();
        for item in ItemStore::query(self, &q)? {
            match item.payload.get("resolution") {
                Some(Value::String(s)) if !s.is_empty() => resolved.push(item),
                _ => unresolved.push(item),
            }
        }
        Ok((unresolved, resolved))
    }

    fn running_tasks(&self, assigned_to: &str) -> Result<Vec<Item>, TaskStoreError> {
        let q = ItemQuery {
            schema: Some(TASK_SCHEMA.into()),
            predicates: vec![
                Predicate::Eq(
                    "payload.state".into(),
                    Value::String(TaskState::Running.as_str().into()),
                ),
                Predicate::Eq(
                    "payload.assigned_to".into(),
                    Value::String(assigned_to.into()),
                ),
            ],
            // Executors re-find their subject via references; tags are
            // never read on the scheduler path.
            include_tags: false,
            ..Default::default()
        };
        Ok(ItemStore::query(self, &q)?)
    }

    fn apply_batch(&self, specs: Vec<OperationSpec>) -> Result<(), TaskStoreError> {
        SqliteItemStore::apply_operation_batch(self, specs)?;
        Ok(())
    }

    fn acquire_task(&self, task: &Item, actor: &str) -> Result<(), TaskStoreError> {
        let transition = transition_op(
            task,
            TaskState::Running,
            ActorId::from(actor),
            ActorKind::Agent,
            None,
        )?;
        let attempts = match task.payload.get("attempts") {
            Some(Value::Int(i)) => *i,
            _ => 0,
        } + 1;
        let sibling = |field: &str, value: Value| OperationSpec {
            target_id: task.id,
            op_type: OperationType::SetPayload(field.into(), value),
            intent: OperationIntent::Routine,
            reason: None,
            batch_id: None,
            author: ActorId::from(actor),
            author_kind: ActorKind::Agent,
            retention: RetentionTier::Compactable,
        };
        self.apply_batch(vec![
            transition,
            sibling("assigned_to", Value::String(actor.into())),
            sibling("attempts", Value::Int(attempts)),
        ])
    }

    fn unresolved_review_targets(
        &self,
    ) -> Result<std::collections::HashSet<ItemId>, TaskStoreError> {
        let q = ItemQuery {
            schema: Some(REVIEW_REQUEST_SCHEMA.into()),
            include_tags: false,
            // References ARE the payload here: the OperatesOn edge names
            // the suspended task.
            include_references: true,
            ..Default::default()
        };
        let mut targets = std::collections::HashSet::new();
        for review in ItemStore::query(self, &q)? {
            let resolved = matches!(review.payload.get("resolution"),
                                    Some(Value::String(s)) if !s.is_empty());
            if resolved {
                continue;
            }
            for r in &review.references {
                if r.edge_type == EdgeType::OperatesOn {
                    targets.insert(r.target);
                }
            }
        }
        Ok(targets)
    }

    fn orphaned_running_tasks(&self) -> Result<Vec<Item>, TaskStoreError> {
        let q = ItemQuery {
            schema: Some(TASK_SCHEMA.into()),
            predicates: vec![Predicate::Eq(
                "payload.state".into(),
                Value::String(TaskState::Running.as_str().into()),
            )],
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        Ok(ItemStore::query(self, &q)?
            .into_iter()
            .filter(|t| {
                !matches!(t.payload.get("assigned_to"),
                          Some(Value::String(s)) if !s.is_empty())
            })
            .collect())
    }

    fn dependents_of(&self, task_id: ItemId) -> Result<Vec<Item>, TaskStoreError> {
        let q = ItemQuery {
            schema: Some(TASK_SCHEMA.into()),
            predicates: vec![Predicate::HasReference(EdgeType::DependsOn, task_id)],
            include_tags: false,
            include_references: true,
            ..Default::default()
        };
        Ok(ItemStore::query(self, &q)?)
    }
}
