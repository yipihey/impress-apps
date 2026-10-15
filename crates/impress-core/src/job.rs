//! Jobs: a long-running verb on the task kernel (ADR-0034 D6).
//!
//! A `long_running` verb answers in milliseconds with a handle — the id of a
//! `task@1.0.0` row — and does its work afterwards, wherever it runs (the
//! verb's own process, or a daemon). This module is the store half of that
//! convention, and it is pure kernel: no runtime, no executor, no verb.
//!
//! * **The handle** is an ordinary task row, created already `running` and
//!   `assigned_to` its runner, so the scheduler (which acquires `pending`
//!   rows and resumes `running` rows assigned to *itself*) never touches
//!   it. Its `verb` and `args` say what started it.
//! * **Progress** is a per-task ring of `task-event@1.0.0` rows — the
//!   surface event ring's shape (`impress-surface-service`'s store: a
//!   gap-free `seq` derived into the row id, a bounded ring, pruning by
//!   `seq` bound), lifted here so a job and a surface are read the same way
//!   (cursor from the rows read, `gap` when the ring was pruned past it).
//! * **Cancel** is a flag on the row (`cancel_requested`). The kernel never
//!   interrupts a thread: the executor polls [`cancel_requested`] and moves
//!   the task `running → cancelled` itself, which ADR-0005 §2 already
//!   allows. `job_cancel` therefore always returns at once.
//! * **The result** is the verb's own JSON, stored on the row when the job
//!   finishes (`result`), beside the terminal state.
//!
//! The scheduler's own executors need none of this: their tasks stay the
//! kernel's, and `cancel_requested` is honoured on their resume pass too.
//!
//! The helpers are koine's (`koine_tasks::job`, koine
//! docs/plan-koine-ai-tasks.md Q-D4), written against the store port. These
//! keep the `&SqliteItemStore` signatures every caller in this workspace
//! uses; `finish_job`'s batch is SQLite's own transaction
//! (`AttributedStore::apply_operation_batch`). The tests below run them over
//! SQLite.

use crate::item::ItemId;
use crate::sqlite_store::SqliteItemStore;
use crate::task::TaskState;

pub use koine_tasks::job::{
    cursor_after, event_row_id, field, inline_runner_name, job_row_of, EventRow, JobError, JobRow,
    Result, EVENT_RING_CAPACITY,
};

/// See [`koine_tasks::job::create_job`].
pub fn create_job(
    store: &SqliteItemStore,
    verb: &str,
    args: &serde_json::Value,
    runner: &str,
    author: &str,
) -> Result<ItemId> {
    koine_tasks::job::create_job(store, verb, args, runner, author)
}

/// See [`koine_tasks::job::get_job`].
pub fn get_job(store: &SqliteItemStore, id: ItemId) -> Result<JobRow> {
    koine_tasks::job::get_job(store, id)
}

/// See [`koine_tasks::job::request_cancel`].
pub fn request_cancel(store: &SqliteItemStore, id: ItemId, actor: &str) -> Result<TaskState> {
    koine_tasks::job::request_cancel(store, id, actor)
}

/// See [`koine_tasks::job::cancel_requested`].
pub fn cancel_requested(store: &SqliteItemStore, id: ItemId) -> Result<bool> {
    koine_tasks::job::cancel_requested(store, id)
}

/// See [`koine_tasks::job::finish_job`].
pub fn finish_job(
    store: &SqliteItemStore,
    id: ItemId,
    to: TaskState,
    result: &serde_json::Value,
    error: Option<&str>,
    actor: &str,
) -> Result<()> {
    koine_tasks::job::finish_job(store, id, to, result, error, actor)
}

/// See [`koine_tasks::job::append_event`].
pub fn append_event(
    store: &SqliteItemStore,
    task: ItemId,
    name: &str,
    payload: &serde_json::Value,
    author: &str,
) -> Result<u64> {
    koine_tasks::job::append_event(store, task, name, payload, author)
}

/// See [`koine_tasks::job::events_after`].
pub fn events_after(
    store: &SqliteItemStore,
    task: ItemId,
    after: u64,
    limit: usize,
) -> Result<Vec<EventRow>> {
    koine_tasks::job::events_after(store, task, after, limit)
}

/// See [`koine_tasks::job::max_seq`].
pub fn max_seq(store: &SqliteItemStore, task: ItemId) -> Result<u64> {
    koine_tasks::job::max_seq(store, task)
}

/// See [`koine_tasks::job::delete_events`].
pub fn delete_events(store: &SqliteItemStore, task: ItemId) -> Result<usize> {
    koine_tasks::job::delete_events(store, task)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::Value;
    use crate::schemas::task::TASK_EVENT_SCHEMA;
    use crate::store::ItemStore;
    use crate::task::TaskTransitionError;
    use serde_json::json;
    use uuid::Uuid;

    fn store() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().unwrap()
    }

    #[test]
    fn a_job_is_born_running_and_assigned_so_the_scheduler_ignores_it() {
        let s = store();
        let id = create_job(&s, "x-service_slow", &json!({"n": 1}), "inline:1@t", "t").unwrap();
        let row = get_job(&s, id).unwrap();
        assert_eq!(row.state, TaskState::Running);
        assert_eq!(row.verb, "x-service_slow");
        assert_eq!(row.runner.as_deref(), Some("inline:1@t"));
        assert!(!row.cancel_requested);
        // Not selectable by the scheduler: not pending…
        assert!(s.ready_tasks(10).unwrap().is_empty());
        // …and not an orphan (it has an assignee).
        let item = s.get(id).unwrap().unwrap();
        assert!(
            matches!(item.payload.get("assigned_to"), Some(Value::String(a)) if a == "inline:1@t")
        );
    }

    #[test]
    fn events_are_gap_free_and_read_from_a_cursor() {
        let s = store();
        let id = create_job(&s, "v", &json!({}), "r", "t").unwrap();
        assert_eq!(max_seq(&s, id).unwrap(), 0);
        for i in 1..=3 {
            let seq = append_event(&s, id, "step", &json!({"i": i}), "t").unwrap();
            assert_eq!(seq, i);
        }
        let all = events_after(&s, id, 0, 0).unwrap();
        assert_eq!(all.iter().map(|e| e.seq).collect::<Vec<_>>(), [1, 2, 3]);
        assert_eq!(all[1].payload_json, r#"{"i":2}"#);
        assert_eq!(cursor_after(&all, 0), (3, false));
        let rest = events_after(&s, id, 2, 0).unwrap();
        assert_eq!(rest.len(), 1);
        assert_eq!(cursor_after(&rest, 2), (3, false));
        let none = events_after(&s, id, 3, 0).unwrap();
        assert!(none.is_empty());
        assert_eq!(cursor_after(&none, 3), (3, false));
        // Another job's ring is its own.
        let other = create_job(&s, "v", &json!({}), "r", "t").unwrap();
        assert!(events_after(&s, other, 0, 0).unwrap().is_empty());
    }

    #[test]
    fn the_ring_is_pruned_and_a_stale_cursor_reports_the_gap() {
        let s = store();
        let id = create_job(&s, "v", &json!({}), "r", "t").unwrap();
        let total = EVENT_RING_CAPACITY as u64 + 5;
        for _ in 0..total {
            append_event(&s, id, "tick", &json!({}), "t").unwrap();
        }
        let rows = events_after(&s, id, 0, 0).unwrap();
        assert_eq!(rows.len(), EVENT_RING_CAPACITY);
        assert_eq!(rows.first().unwrap().seq, 6);
        assert_eq!(rows.last().unwrap().seq, total);
        // A cursor at 2 lost 3..=5: gap.
        let from_two = events_after(&s, id, 2, 0).unwrap();
        assert_eq!(cursor_after(&from_two, 2), (total, true));
        // A cursor at 5 lost nothing (6 is the next).
        let from_five = events_after(&s, id, 5, 0).unwrap();
        assert_eq!(cursor_after(&from_five, 5), (total, false));
        assert_eq!(delete_events(&s, id).unwrap(), EVENT_RING_CAPACITY);
    }

    #[test]
    fn cancel_is_a_flag_on_a_running_job_and_a_transition_on_a_pending_task() {
        let s = store();
        let id = create_job(&s, "v", &json!({}), "r", "t").unwrap();
        assert!(!cancel_requested(&s, id).unwrap());
        assert_eq!(request_cancel(&s, id, "t").unwrap(), TaskState::Running);
        assert!(cancel_requested(&s, id).unwrap());
        // Idempotent.
        assert_eq!(request_cancel(&s, id, "t").unwrap(), TaskState::Running);
        // The executor finishes it.
        finish_job(
            &s,
            id,
            TaskState::Cancelled,
            &json!({"ok": false}),
            None,
            "t",
        )
        .unwrap();
        let row = get_job(&s, id).unwrap();
        assert_eq!(row.state, TaskState::Cancelled);
        assert_eq!(row.result_json.as_deref(), Some(r#"{"ok":false}"#));
        // Terminal → refused.
        assert!(matches!(
            request_cancel(&s, id, "t"),
            Err(JobError::Transition(TaskTransitionError::Illegal { .. }))
        ));
    }

    #[test]
    fn finish_writes_state_result_and_error_together() {
        let s = store();
        let id = create_job(&s, "v", &json!({}), "r", "t").unwrap();
        finish_job(
            &s,
            id,
            TaskState::Failed,
            &json!({"ok": false, "message": "boom"}),
            Some("boom"),
            "t",
        )
        .unwrap();
        let row = get_job(&s, id).unwrap();
        assert_eq!(row.state, TaskState::Failed);
        assert_eq!(row.error.as_deref(), Some("boom"));
        assert!(row.result_json.unwrap().contains("boom"));
    }

    #[test]
    fn a_non_task_row_is_refused_by_name() {
        let s = store();
        let id = create_job(&s, "v", &json!({}), "r", "t").unwrap();
        append_event(&s, id, "x", &json!({}), "t").unwrap();
        let event = event_row_id(id, 1);
        assert!(
            matches!(get_job(&s, event), Err(JobError::NotATask(_, k)) if k == TASK_EVENT_SCHEMA.as_str())
        );
        assert!(matches!(
            get_job(&s, Uuid::new_v4()),
            Err(JobError::NotFound(_))
        ));
    }
}
