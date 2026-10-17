//! The inline job runner (ADR-0034 D6, plan P4), now koine's
//! (`koine_tasks::inline`, docs/plan-koine-kit-moves.md KM11).
//!
//! A `long_running` verb calls [`start_inline`] with its arguments and the
//! work as a future and gets the `task@1.0.0` handle back in milliseconds;
//! the work reports through its [`JobContext`] and its outcome lands on the
//! row. This module re-exports koine's runner and adds what is this suite's:
//! the refusal when the shared store fell back to memory (a job recorded
//! there vanishes with the process), and [`cli_finish`] against the suite's
//! store. The tests below keep proving the runner over SQLite.

use std::future::Future;
use std::sync::Arc;

use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::job::JobStarted;
use impress_service_core::refusal::Refusal;
use serde_json::Value;

pub use koine_tasks::inline::{
    drain_inline, inline_job_count, result_of, wait, wait_until_done, JobOutcome, Waited,
    CANCEL_POLL_MS, MAX_WAIT_MS, RUNNER_AUTHOR, WAIT_POLL_MS,
};

/// The context a job's body gets, over the suite's store.
pub type JobContext = koine_tasks::inline::JobContext<SqliteItemStore>;

/// Start `body` as an inline job over `store`; see
/// [`koine_tasks::inline::start_inline`]. Refused when `store` is the
/// in-memory stand-in for a shared store that could not be opened.
pub fn start_inline<F, Fut>(
    store: Arc<SqliteItemStore>,
    verb: &str,
    args: &Value,
    body: F,
) -> JobStarted
where
    F: FnOnce(Arc<JobContext>) -> Fut + Send + 'static,
    Fut: Future<Output = JobOutcome> + Send + 'static,
{
    if crate::store::is_fallback_store(&store) {
        return JobStarted::refused(Refusal::store_unavailable(format!(
            "{verb}: the shared store could not be opened, so a job could not be recorded"
        )));
    }
    koine_tasks::inline::start_inline(store, verb, args, body)
}

/// What a CLI does with a verb's answer (`impress-cli`, `imprint-cli`); see
/// [`koine_tasks::inline::cli_finish`]. Reads the suite's store.
pub fn cli_finish(value: Value, wait_and_stream: bool) -> Value {
    let store = crate::store::store_instance();
    koine_tasks::inline::cli_finish(&*store, value, wait_and_stream)
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::ItemId;
    use impress_core::job;
    use impress_core::task::TaskState;
    use serde_json::json;
    use std::time::{Duration, Instant};

    fn store() -> Arc<SqliteItemStore> {
        Arc::new(SqliteItemStore::open_in_memory().unwrap())
    }

    /// The handle comes back before the work does; the work's events and
    /// its result are readable through the kernel; the CLI can drain it.
    #[tokio::test]
    async fn a_job_answers_at_once_and_finishes_behind_the_handle() {
        let store = store();
        let started = Instant::now();
        let handle = start_inline(
            store.clone(),
            "t-service_slow",
            &json!({"n": 3}),
            |ctx| async move {
                for i in 1..=3 {
                    ctx.progress("step", json!({"i": i}));
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                JobOutcome::Done(json!({"ok": true, "n": 3}))
            },
        );
        assert!(handle.ok, "{handle:?}");
        assert!(
            started.elapsed() < Duration::from_millis(50),
            "{:?}",
            started.elapsed()
        );
        let id: ItemId = handle.job.as_ref().unwrap().id.parse().unwrap();

        let w = wait(&*store, id, 0, Duration::from_secs(5)).await.unwrap();
        assert!(!w.timed_out);
        assert_eq!(w.events[0].name, "step");
        let row = wait_until_done(&*store, id, Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!(row.state, TaskState::Done);
        assert_eq!(result_of(&row).unwrap()["n"], 3);
        let all = job::events_after(&store, id, 0, 0).unwrap();
        assert_eq!(all.last().unwrap().name, "finished");
        assert_eq!(all.len(), 4);
        drain_inline().await;
        assert_eq!(inline_job_count(), 0);
    }

    #[tokio::test]
    async fn a_cancel_request_reaches_the_body_and_the_row_says_cancelled() {
        let store = store();
        let handle = start_inline(
            store.clone(),
            "t-service_loop",
            &json!({}),
            |ctx| async move {
                let mut ticks = 0;
                loop {
                    if ctx.cancel_requested() {
                        return JobOutcome::Cancelled(json!({"ok": false, "ticks": ticks}));
                    }
                    ticks += 1;
                    if ticks > 500 {
                        return JobOutcome::Done(json!({"ok": true, "ticks": ticks}));
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            },
        );
        let id: ItemId = handle.job.unwrap().id.parse().unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(
            job::request_cancel(&store, id, "t").unwrap(),
            TaskState::Running
        );
        let row = wait_until_done(&*store, id, Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!(row.state, TaskState::Cancelled);
        assert!(result_of(&row).unwrap()["ticks"].as_u64().unwrap() < 500);
    }

    #[tokio::test]
    async fn a_panicking_body_fails_the_job_instead_of_leaving_it_running() {
        let store = store();
        let handle = start_inline(
            store.clone(),
            "t-service_boom",
            &json!({}),
            |_ctx| async move {
                panic!("boom");
            },
        );
        let id: ItemId = handle.job.unwrap().id.parse().unwrap();
        let row = wait_until_done(&*store, id, Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!(row.state, TaskState::Failed);
        assert!(row.error.unwrap().contains("panicked"));
    }

    #[tokio::test]
    async fn waiting_on_a_finished_job_returns_at_once_with_the_cursor_unchanged() {
        let store = store();
        let handle = start_inline(
            store.clone(),
            "t-service_quick",
            &json!({}),
            |_| async move { JobOutcome::Done(json!({"ok": true})) },
        );
        let id: ItemId = handle.job.unwrap().id.parse().unwrap();
        wait_until_done(&*store, id, Duration::from_secs(5))
            .await
            .unwrap();
        // The terminal row is written before its final event. Wait for that
        // event explicitly before treating max_seq as a fully consumed cursor.
        let finished_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let events = job::events_after(&store, id, 0, 0).unwrap();
            if events.iter().any(|event| event.name == "finished") {
                break;
            }
            assert!(
                Instant::now() < finished_deadline,
                "terminal job never emitted its finished event"
            );
            tokio::task::yield_now().await;
        }
        let last = job::max_seq(&store, id).unwrap();
        let started = Instant::now();
        let w = wait(&*store, id, last, Duration::from_secs(30))
            .await
            .unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!w.timed_out);
        assert!(w.events.is_empty());
        assert_eq!(w.next_seq, last);
        assert_eq!(w.job.state, TaskState::Done);
    }

    #[test]
    fn the_cli_passes_a_plain_result_through() {
        let v = json!({"ok": true, "count": 2});
        assert_eq!(cli_finish(v.clone(), false), v);
        assert_eq!(cli_finish(v.clone(), true), v);
    }
}
