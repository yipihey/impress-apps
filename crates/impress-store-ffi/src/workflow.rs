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
//! module's first file-backed store open — close enough to "the app
//! started" that a workflow never runs early, which is the rule's only
//! promise (a slightly late anchor only makes the guard stricter, never
//! looser).

use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

use impress_core::item::ActorKind;
use impress_workflow::spec::{Author, Guards, Review, Trigger, WorkflowSpec, WorkflowState};
use impress_workflow_service::WorkflowEngine;

use crate::SharedStore;

/// impel-taskd's own default (`main.rs`'s `--start-delay`) — the one number
/// with one owner (plan § Workflows).
const START_DELAY_MS: i64 = 90_000;

/// The first migrated background service (plan W3, D-R10): imbib's inbox /
/// feed retention sweep, ported from the deleted Swift
/// `RetentionCleanupService`. Seeded here — the in-app host's tick call site
/// — rather than agent-proposed, so it starts `enabled` (D-R6's
/// `Proposed`/review gate is for agent-authored workflows; a system-seeded
/// one skips it, same as a person writing it by hand). Runs daily, same
/// cadence as the Swift service's once-per-launch schedule; the 90s
/// `not_before_startup_s` is `START_DELAY_MS` above, restated as seconds so
/// the guard reads directly off the stored row rather than assuming this
/// module's constant.
fn imbib_retention_cleanup_workflow() -> WorkflowSpec {
    WorkflowSpec {
        wire_version: 1,
        name: "imbib.retention-cleanup".into(),
        description: "Remove inbox and feed papers past their retention window \
            (imbib.retention.* settings); starred papers are never removed."
            .into(),
        state: WorkflowState::Enabled,
        author: Author {
            kind: "system".into(),
            name: Some("w3-retention-migration".into()),
        },
        trigger: Trigger::Schedule {
            every: "24h".into(),
            at: None,
        },
        guards: Guards {
            not_before_startup_s: Some(START_DELAY_MS as u64 / 1000),
            ..Default::default()
        },
        params: vec![],
        sources: BTreeMap::new(),
        steps: vec![impress_surface::spec::Action::Call {
            verb: "imbib-library-service_retention-cleanup".into(),
            args: serde_json::json!({}),
            into: None,
            each: None,
        }],
        review: Review { required: false },
    }
}

/// Inserts [`imbib_retention_cleanup_workflow`] once, the first time a tick
/// runs against a workspace that does not have it yet (matched by `name` —
/// a workflow is user-editable after creation, so this never overwrites a
/// row that already exists, even a disabled one). A seed failure (a corrupt
/// store, a read-only workspace) is logged to stderr and never blocks the
/// tick that triggered it.
fn ensure_system_workflows_seeded(
    store: &std::sync::Arc<impress_core::sqlite_store::SqliteItemStore>,
) {
    if impress_service_core::VerbDescriptor::find("imbib-library-service_retention-cleanup")
        .is_none()
    {
        return; // A kit-only host cannot execute a domain workflow.
    }
    let already_seeded = match impress_workflow_service::store::list(store) {
        Ok(rows) => rows
            .iter()
            .any(|r| r.spec.name == "imbib.retention-cleanup"),
        Err(e) => {
            eprintln!("[impress-store-ffi] workflow seed: could not list existing rows: {e}");
            return;
        }
    };
    if already_seeded {
        return;
    }
    if let Err(e) = impress_workflow_service::store::insert(
        store,
        &imbib_retention_cleanup_workflow(),
        ActorKind::System,
    ) {
        tracing::error!(target: "workflow", %e, "could not seed imbib.retention-cleanup");
    } else {
        tracing::info!(target: "workflow", "seeded imbib.retention-cleanup");
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Anchor the read-only startup clock when the app opens its store.
/// Waiting until the first delayed tick would impose a second 90-second gate.
pub(crate) fn start() {
    let _ = engine();
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
        let core = self.core();
        ensure_system_workflows_seeded(&core);
        let mut engine = engine().lock().unwrap_or_else(|poison| poison.into_inner());
        engine
            .run_once(&core, now_ms(), &workspace)
            .into_iter()
            .filter_map(|outcome| {
                if let Some(error) = outcome.error {
                    tracing::error!(target: "workflow", workflow = %outcome.name, %error, "workflow failed");
                    None
                } else {
                    tracing::info!(target: "workflow", workflow = %outcome.name, calls = outcome.calls, "workflow saved");
                    Some(outcome.workflow_id)
                }
            })
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
