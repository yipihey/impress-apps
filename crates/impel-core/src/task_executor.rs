//! `TaskExecutor` — the ADR-0005 §7 execution contract (ADR-0015 D5).
//!
//! Replaces the earlier synchronous string-in/string-out stub (which had
//! no implementors). One refinement over the ADR's literal signature:
//! `execute` returns [`ExecutionOutcome`] instead of `()`, because the
//! §8 `AwaitHumanResponse` checkpoint needs a way for an executor to say
//! "I opened a review and am suspending" that `Ok(())` cannot express.
//! The scheduler treats `Suspended` by leaving the task `running`
//! (ADR-0005 §8) and re-invoking `execute` after the review resolves —
//! executors re-derive their state from the graph on resume (ADR-0005
//! "Mitigations": re-run task setup rather than serialize executor state).

use async_trait::async_trait;

use impress_core::item::Item;

use crate::task_store::TaskStoreApi;

/// What an executor's run concluded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutionOutcome {
    /// Work finished; the scheduler transitions the task to `done`.
    Complete,
    /// A `review-request` was opened (via `TaskStoreApi::open_review`);
    /// the scheduler leaves the task `running` and re-executes after the
    /// review's `resolution` is set.
    Suspended,
}

/// Execution failure, split by retryability (ADR-0005 §7).
#[derive(Debug, thiserror::Error)]
pub enum TaskError {
    /// Transient — the scheduler may retry (`running → pending` reset,
    /// visible in the operation history as the retry ledger).
    #[error("retryable: {0}")]
    Retryable(String),
    /// Permanent — no retry; the task fails immediately.
    #[error("permanent: {0}")]
    Permanent(String),
    /// Store access failed while executing.
    #[error(transparent)]
    Store(#[from] crate::task_store::TaskStoreError),
}

/// Trait implemented by each task type handler in impel (ADR-0005 §7).
#[async_trait]
pub trait TaskExecutor: Send + Sync {
    /// The `task_kind` this executor handles (matched against the task
    /// item's `task_kind` payload field, falling back to `title`).
    fn task_kind(&self) -> &str;

    /// Execute the task. Output items are written via `store`; the
    /// executor must NOT transition task state — that is the scheduler's
    /// job (ADR-0005 §7).
    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError>;

    /// Maximum retry attempts before the failure escalates
    /// (`OperationIntent::Escalation`).
    fn max_retries(&self) -> u32 {
        3
    }

    /// Whether `error` is worth retrying. Default: retry `Retryable` only.
    fn is_retryable(&self, error: &TaskError) -> bool {
        matches!(error, TaskError::Retryable(_))
    }
}
