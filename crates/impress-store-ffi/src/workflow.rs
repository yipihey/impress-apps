//! The in-app host for W2's trigger engine (plan-self-reflective-layer.md
//! § Workflows, "Who runs it"): `workflow_tick()` is a thin UniFFI export —
//! one engine tick, called by the app on its own timer — exactly the peer
//! of `impel-taskd`'s fourth spawn rule, both driving
//! `impress_workflow_service::WorkflowEngine`. This crate translates, it
//! never decides anything about a workflow (the division `layout.rs` and
//! `surface.rs` already draw for their own trees).
//!
//! **One engine per process**, not per `SharedStore`: an app opens exactly
//! one live store, and the engine's `start_delay` anchor
//! (`WorkflowEngine::new`'s `started_at_ms`) is stamped once, at this
//! module's first `workflow_tick()` call — close enough to "the app
//! started" that a workflow never runs early, which is the rule's only
//! promise (a slightly late anchor only makes the guard stricter, never
//! looser).

use std::sync::{Mutex, OnceLock};

use impress_workflow_service::WorkflowEngine;

use crate::SharedStore;

/// impel-taskd's own default (`main.rs`'s `--start-delay`) — the one number
/// with one owner (plan § Workflows).
const START_DELAY_MS: i64 = 90_000;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn engine() -> &'static Mutex<WorkflowEngine> {
    static ENGINE: OnceLock<Mutex<WorkflowEngine>> = OnceLock::new();
    ENGINE.get_or_init(|| Mutex::new(WorkflowEngine::new(now_ms(), START_DELAY_MS)))
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedStore {
    /// One tick of W2's trigger engine: resolves `store`/`job`/`call`
    /// signals since the last tick, runs every `enabled` workflow that
    /// fired (through the pipeline, as `System("workflow:<id>")`), and
    /// returns the ids of the workflows that ran. Returns nothing (and
    /// touches no lease) for an in-memory store — there is no workspace
    /// directory to lease against, which only tests open.
    ///
    /// The app calls this on a timer (e.g. every 5–15s); nothing in this
    /// crate schedules that call itself — see CLAUDE.md "Background
    /// Services Must Defer Startup Work" for why the engine, not the
    /// timer, is what enforces the startup delay.
    pub fn workflow_tick(&self) -> Vec<String> {
        let Some(workspace) = self.blob_root_parent() else {
            return Vec::new();
        };
        let mut engine = engine().lock().unwrap_or_else(|poison| poison.into_inner());
        engine
            .run_once(&self.core(), now_ms(), &workspace)
            .into_iter()
            .map(|outcome| outcome.workflow_id)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use crate::SharedStore;

    /// An in-memory store has no workspace to lease against — the tick must
    /// return cleanly (never panic) rather than assume a workspace exists.
    #[test]
    fn tick_on_an_in_memory_store_is_a_no_op() {
        let store = SharedStore::open_in_memory().expect("open");
        assert!(store.workflow_tick().is_empty());
    }

    /// A file-backed store with no workflow rows ticks cleanly too.
    #[test]
    fn tick_on_a_fresh_workspace_with_no_workflows_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        let store = SharedStore::open(dir.path().join("impress.sqlite").display().to_string())
            .expect("open");
        assert!(store.workflow_tick().is_empty());
    }
}
