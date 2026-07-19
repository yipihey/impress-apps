//! `SpawnRule` — item-triggered task DAG creation (ADR-0005 §10).
//!
//! Rules are Rust code in Phase 3 (D22); the trait is the Phase 4+
//! migration boundary for declarative rules.

use std::collections::BTreeMap;

use async_trait::async_trait;
use chrono::Utc;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::task::TaskState;
use uuid::Uuid;

use crate::task_store::{TaskStoreApi, TaskStoreError, TASK_SCHEMA};

/// Specification of one task to create.
#[derive(Debug, Clone)]
pub struct TaskSpec {
    /// Human-readable task name AND the executor dispatch key
    /// (stored as both `title` and `task_kind`).
    pub kind: String,
    pub description: Option<String>,
    /// Indexes into the returned `Vec<TaskSpec>` this task depends on.
    pub depends_on: Vec<usize>,
    /// The item this task operates on (`OperatesOn` edge).
    pub operates_on: Option<ItemId>,
    /// Schema ref of the item a successful run must produce (ADR-0003 D5).
    pub output_schema: Option<String>,
}

/// Spawn failure.
#[derive(Debug, thiserror::Error)]
pub enum SpawnError {
    #[error(transparent)]
    Store(#[from] TaskStoreError),
    #[error("invalid spec: {0}")]
    InvalidSpec(String),
}

/// A rule that reacts to new items by creating task DAGs (ADR-0005 §10).
#[async_trait]
pub trait SpawnRule: Send + Sync {
    /// Schema ref that triggers this rule.
    fn trigger_schema(&self) -> &str;

    /// Given the triggering item, return the task DAG to create.
    /// Empty vec = nothing to spawn for this item.
    async fn spawn(
        &self,
        trigger: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<Vec<TaskSpec>, SpawnError>;
}

/// Materialize a spawn result: create `pending` task items and wire
/// `DependsOn`/`OperatesOn` edges. Returns created task IDs, parallel to
/// the input specs.
pub fn create_task_dag(
    store: &dyn TaskStoreApi,
    specs: &[TaskSpec],
    author: &str,
) -> Result<Vec<ItemId>, SpawnError> {
    // Validate dependency indexes first (must reference earlier or later
    // specs, but always within bounds and acyclic by construction: an
    // index DAG on a finite list can still cycle, so check).
    for (i, spec) in specs.iter().enumerate() {
        for &d in &spec.depends_on {
            if d >= specs.len() {
                return Err(SpawnError::InvalidSpec(format!(
                    "task {i} depends on out-of-range index {d}"
                )));
            }
            if d == i {
                return Err(SpawnError::InvalidSpec(format!("task {i} depends on itself")));
            }
        }
    }
    // Cycle check via DFS coloring.
    fn has_cycle(specs: &[TaskSpec]) -> bool {
        #[derive(Clone, Copy, PartialEq)]
        enum C {
            White,
            Grey,
            Black,
        }
        fn visit(i: usize, specs: &[TaskSpec], color: &mut [C]) -> bool {
            color[i] = C::Grey;
            for &d in &specs[i].depends_on {
                match color[d] {
                    C::Grey => return true,
                    C::White => {
                        if visit(d, specs, color) {
                            return true;
                        }
                    }
                    C::Black => {}
                }
            }
            color[i] = C::Black;
            false
        }
        let mut color = vec![C::White; specs.len()];
        (0..specs.len()).any(|i| color[i] == C::White && visit(i, specs, &mut color))
    }
    if has_cycle(specs) {
        return Err(SpawnError::InvalidSpec("dependency cycle".into()));
    }

    // Create items (references added after all IDs are known).
    let mut ids = Vec::with_capacity(specs.len());
    for spec in specs {
        let mut payload = BTreeMap::new();
        payload.insert("title".into(), Value::String(spec.kind.clone()));
        payload.insert("task_kind".into(), Value::String(spec.kind.clone()));
        payload.insert(
            "state".into(),
            Value::String(TaskState::Pending.as_str().into()),
        );
        if let Some(d) = &spec.description {
            payload.insert("description".into(), Value::String(d.clone()));
        }
        if let Some(o) = &spec.output_schema {
            payload.insert("output_schema".into(), Value::String(o.clone()));
        }
        let mut references = Vec::new();
        if let Some(target) = spec.operates_on {
            references.push(TypedReference {
                target,
                edge_type: EdgeType::OperatesOn,
                metadata: None,
            });
        }
        let item = Item {
            id: Uuid::new_v4(),
            schema: TASK_SCHEMA.into(),
            payload,
            created: Utc::now(),
            modified: Utc::now(),
            author: author.to_string(),
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
        };
        ids.push(store.create_item(item)?);
    }
    // DependsOn edges.
    for (i, spec) in specs.iter().enumerate() {
        for &d in &spec.depends_on {
            store.add_edge(ids[i], ids[d], EdgeType::DependsOn, author)?;
        }
    }
    Ok(ids)
}
