//! The task store port for SQLite (koine docs/plan-koine-ai-tasks.md Q-D2).
//!
//! `koine_tasks::TaskStoreApi` is the facade the scheduler and executors run
//! against; this is its SQLite implementation, moved here from `impel-core`
//! when the port moved to koine (an implementation of a koine trait lives
//! with the type). Every method is the port's own `kernel` function except
//! the ready queue, which is SQLite's single statement
//! ([`SqliteItemStore::ready_tasks`], ADR-0015 D2).

use std::collections::HashSet;

use koine_tasks::store::kernel;
use koine_tasks::{AgentRunRecord, ReviewRequest, TaskState, TaskStoreApi, TaskStoreError};

use crate::item::{Item, ItemId};
use crate::operation::{OperationIntent, OperationSpec};
use crate::reference::EdgeType;
use crate::sqlite_store::SqliteItemStore;

impl TaskStoreApi for SqliteItemStore {
    fn create_item(&self, item: Item) -> Result<ItemId, TaskStoreError> {
        kernel::create_item(self, item)
    }

    fn get_item(&self, id: ItemId) -> Result<Option<Item>, TaskStoreError> {
        kernel::get_item(self, id)
    }

    fn apply(&self, spec: OperationSpec) -> Result<ItemId, TaskStoreError> {
        kernel::apply(self, spec)
    }

    fn add_edge(
        &self,
        source: ItemId,
        target: ItemId,
        edge: EdgeType,
        author: &str,
    ) -> Result<(), TaskStoreError> {
        kernel::add_edge(self, source, target, edge, author)
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
        kernel::transition(self, task_id, to, actor, intent)
    }

    fn record_agent_run(
        &self,
        task_id: ItemId,
        run: AgentRunRecord,
    ) -> Result<ItemId, TaskStoreError> {
        kernel::record_agent_run(self, task_id, run)
    }

    fn open_review(
        &self,
        task_id: ItemId,
        request: ReviewRequest,
        author: &str,
    ) -> Result<ItemId, TaskStoreError> {
        kernel::open_review(self, task_id, request, author)
    }

    fn reviews_for(&self, task_id: ItemId) -> Result<(Vec<Item>, Vec<Item>), TaskStoreError> {
        kernel::reviews_for(self, task_id)
    }

    fn running_tasks(&self, assigned_to: &str) -> Result<Vec<Item>, TaskStoreError> {
        kernel::running_tasks(self, assigned_to)
    }

    fn apply_batch(&self, specs: Vec<OperationSpec>) -> Result<(), TaskStoreError> {
        kernel::apply_batch(self, specs)
    }

    fn acquire_task(&self, task: &Item, actor: &str) -> Result<(), TaskStoreError> {
        kernel::acquire_task(self, task, actor)
    }

    fn unresolved_review_targets(&self) -> Result<HashSet<ItemId>, TaskStoreError> {
        kernel::unresolved_review_targets(self)
    }

    fn orphaned_running_tasks(&self) -> Result<Vec<Item>, TaskStoreError> {
        kernel::orphaned_running_tasks(self)
    }

    fn dependents_of(&self, task_id: ItemId) -> Result<Vec<Item>, TaskStoreError> {
        kernel::dependents_of(self, task_id)
    }
}
