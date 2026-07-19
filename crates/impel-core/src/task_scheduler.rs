//! The impel task scheduler — ADR-0005 §6's execution loop (ADR-0015 D5).
//!
//! Responsibilities (and nothing more): acquire ready tasks, dispatch to
//! the registered [`TaskExecutor`], drive every state transition through
//! the kernel's validated path, manage retry with escalation on
//! exhaustion, and honor `AwaitHumanResponse` suspensions. Executors
//! never transition state; impress-core never sees execution concerns.
//!
//! Startup guard: callers construct with [`SchedulerConfig::start_delay`]
//! ≥ 90 s in app contexts (CLAUDE.md invariant — background services must
//! not mutate during launch settling). `run_once` itself is undelayed so
//! tests and CLIs can drive the loop directly.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use impress_core::item::{Item, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::task::TaskState;

use crate::task_executor::{ExecutionOutcome, TaskError, TaskExecutor};
use crate::task_store::{TaskStoreApi, TaskStoreError};

/// Scheduler tuning.
#[derive(Debug, Clone)]
pub struct SchedulerConfig {
    /// Actor id written as `assigned_to` and as operation author.
    pub actor: String,
    /// Max tasks acquired per `run_once` pass.
    pub batch: usize,
    /// Delay before the first pass of `run` (the 90-second guard).
    pub start_delay: Duration,
    /// Polling interval between passes of `run`.
    pub poll_interval: Duration,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            actor: "impel".into(),
            batch: 8,
            start_delay: Duration::from_secs(90),
            poll_interval: Duration::from_secs(5),
        }
    }
}

/// Summary of one scheduler pass (for logs/tests).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PassReport {
    pub acquired: usize,
    pub completed: usize,
    pub suspended: usize,
    pub resumed: usize,
    pub retried: usize,
    pub failed: usize,
}

pub struct Scheduler {
    store: Arc<dyn TaskStoreApi>,
    executors: HashMap<String, Arc<dyn TaskExecutor>>,
    config: SchedulerConfig,
}

impl Scheduler {
    pub fn new(store: Arc<dyn TaskStoreApi>, config: SchedulerConfig) -> Self {
        Self {
            store,
            executors: HashMap::new(),
            config,
        }
    }

    /// Register an executor for its `task_kind`. Last registration wins.
    pub fn register(&mut self, executor: Arc<dyn TaskExecutor>) {
        self.executors
            .insert(executor.task_kind().to_string(), executor);
    }

    /// One full pass: resume suspended tasks whose reviews resolved, then
    /// acquire + execute ready tasks. Returns what happened.
    pub async fn run_once(&self) -> Result<PassReport, TaskStoreError> {
        let mut report = PassReport::default();

        // ── Resume pass: running tasks assigned to us ──────────────────
        // A running task with an unresolved review is suspended — skip.
        // With all reviews resolved (or none, i.e. a crash left it
        // running), re-execute: executors re-derive state from the graph.
        for task in self.store.running_tasks(&self.config.actor)? {
            let (unresolved, resolved) = self.store.reviews_for(task.id)?;
            if !unresolved.is_empty() {
                report.suspended += 1;
                continue;
            }
            if !resolved.is_empty() {
                report.resumed += 1;
            }
            self.execute_and_finalize(&task, &mut report).await?;
        }

        // ── Acquire pass ───────────────────────────────────────────────
        for task in self.store.ready_tasks(self.config.batch)? {
            self.acquire(&task)?;
            report.acquired += 1;
            // Re-fetch: acquire wrote state/assigned_to/attempts.
            let task = self
                .store
                .get_item(task.id)?
                .ok_or(TaskStoreError::TaskNotFound(task.id))?;
            self.execute_and_finalize(&task, &mut report).await?;
        }
        Ok(report)
    }

    /// The production loop: waits `start_delay`, then polls forever.
    pub async fn run(&self) -> Result<(), TaskStoreError> {
        tokio::time::sleep(self.config.start_delay).await;
        loop {
            let _ = self.run_once().await?;
            tokio::time::sleep(self.config.poll_interval).await;
        }
    }

    // ── internals ──────────────────────────────────────────────────────

    fn acquire(&self, task: &Item) -> Result<(), TaskStoreError> {
        self.store
            .transition(task.id, TaskState::Running, &self.config.actor, None)?;
        // assigned_to + attempts ride along as sibling operations.
        let attempts = payload_i64(task, "attempts").unwrap_or(0) + 1;
        for (field, value) in [
            (
                "assigned_to",
                Value::String(self.config.actor.clone()),
            ),
            ("attempts", Value::Int(attempts)),
        ] {
            self.store.apply(OperationSpec {
                target_id: task.id,
                op_type: OperationType::SetPayload(field.into(), value),
                intent: OperationIntent::Routine,
                reason: None,
                batch_id: None,
                author: self.config.actor.clone(),
                author_kind: impress_core::item::ActorKind::Agent,
                retention: RetentionTier::Compactable,
            })?;
        }
        Ok(())
    }

    async fn execute_and_finalize(
        &self,
        task: &Item,
        report: &mut PassReport,
    ) -> Result<(), TaskStoreError> {
        let kind = task_kind(task);
        let Some(executor) = self.executors.get(&kind) else {
            // No executor for this kind: not our task — leave it running?
            // No: a task WE acquired but cannot run is a permanent failure
            // with escalation (misconfiguration needs human eyes).
            self.store.transition(
                task.id,
                TaskState::Failed,
                &self.config.actor,
                Some(OperationIntent::Escalation),
            )?;
            self.set_error(task.id, &format!("no executor registered for '{kind}'"))?;
            report.failed += 1;
            return Ok(());
        };

        match executor.execute(task, self.store.as_ref()).await {
            Ok(ExecutionOutcome::Complete) => {
                self.store
                    .transition(task.id, TaskState::Done, &self.config.actor, None)?;
                report.completed += 1;
            }
            Ok(ExecutionOutcome::Suspended) => {
                // Stays running; the review item is the suspension record.
                report.suspended += 1;
            }
            Err(err) => {
                let attempts = payload_i64(task, "attempts").unwrap_or(1) as u32;
                if executor.is_retryable(&err) && attempts <= executor.max_retries() {
                    // Retry: running → pending reset, visible in the op
                    // history as the retry ledger (ADR-0005 §2).
                    self.store.transition(
                        task.id,
                        TaskState::Pending,
                        &self.config.actor,
                        None,
                    )?;
                    report.retried += 1;
                } else {
                    let intent = if executor.is_retryable(&err) {
                        // Retries exhausted → escalate (ADR-0005 §3).
                        Some(OperationIntent::Escalation)
                    } else {
                        None // transition_op defaults → Anomaly for failed
                    };
                    self.store.transition(
                        task.id,
                        TaskState::Failed,
                        &self.config.actor,
                        intent,
                    )?;
                    self.set_error(task.id, &err.to_string())?;
                    report.failed += 1;
                }
            }
        }
        Ok(())
    }

    fn set_error(&self, task_id: impress_core::item::ItemId, msg: &str) -> Result<(), TaskStoreError> {
        self.store.apply(OperationSpec {
            target_id: task_id,
            op_type: OperationType::SetPayload("error".into(), Value::String(msg.into())),
            intent: OperationIntent::Anomaly,
            reason: None,
            batch_id: None,
            author: self.config.actor.clone(),
            author_kind: impress_core::item::ActorKind::Agent,
            retention: RetentionTier::Durable,
        })?;
        Ok(())
    }
}

fn task_kind(task: &Item) -> String {
    match task.payload.get("task_kind") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => match task.payload.get("title") {
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        },
    }
}

fn payload_i64(task: &Item, field: &str) -> Option<i64> {
    match task.payload.get(field) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}
