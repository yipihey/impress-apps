//! The stored `imbib.retention-cleanup` workflow, end to end (plan W3,
//! D-R10): a `schedule` trigger, the engine's 90s `start_delay`, and the
//! `imbib-library-service_retention-cleanup` verb call landing in the call
//! log (`core/verb-call@1.0.0`).
//!
//! Two connections to the same on-disk store, the `sync_outbox_facade.rs`
//! dual-handle pattern: `imbib_service::store_singleton` (what the verb's
//! own handler runs on — the process-wide `ImbibStore` the pipeline dispatch
//! macro resolves) and a raw `SqliteItemStore` (what the workflow engine and
//! the call-log sink write through, via `pipeline::invoke_on`'s per-call
//! store override).

use impress_core::item::ActorKind;
use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_store_service::history_service::{DefaultHistoryService, HistoryService};
use impress_workflow::spec::{
    Action, Author, Guards, Review, Trigger, WorkflowSpec, WorkflowState,
};
use impress_workflow_service::WorkflowEngine;

fn temp_db() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("impress.sqlite");
    (dir, path)
}

fn retention_workflow() -> WorkflowSpec {
    WorkflowSpec {
        wire_version: 1,
        name: "imbib.retention-cleanup".into(),
        description: "test fixture".into(),
        state: WorkflowState::Enabled,
        author: Author {
            kind: "system".into(),
            name: None,
        },
        trigger: Trigger::Schedule {
            every: "24h".into(),
            at: None,
        },
        guards: Guards {
            not_before_startup_s: Some(90),
            ..Default::default()
        },
        params: vec![],
        sources: Default::default(),
        steps: vec![Action::Call {
            verb: "imbib-library-service_retention-cleanup".into(),
            args: serde_json::json!({}),
            into: None,
            each: None,
        }],
        review: Review { required: false },
    }
}

#[test]
fn retention_workflow_runs_once_after_start_delay_and_the_call_lands_in_the_log() {
    let (_dir, path) = temp_db();

    // Both handles the retention verb's own dispatch could reach: the
    // process-wide singleton `imbib-library-service` calls through
    // (`store_singleton::init_imbib_store`), and this test's own handle for
    // setting up fixture data / reading results back afterward.
    imbib_service::store_singleton::init_imbib_store(path.clone())
        .expect("init imbib store singleton");

    let imbib = imbib_service::store_singleton::store_instance();
    let inbox = imbib.create_inbox_library("Inbox".into()).expect("inbox");
    let old_id = imbib
        .import_bibtex("@article{Old2020, title={Old}}".into(), inbox.id.clone())
        .expect("import")
        .remove(0);
    // Read it, so it is removable even without a backdated date under the
    // default `imbib.retention.auto_remove_read = false` — set the setting
    // on so this fixture does not depend on the default's exact value.
    let settings = impress_settings::SettingsStore::open(path.parent().unwrap());
    settings
        .set(
            "imbib.retention.auto_remove_read",
            &serde_json::Value::Bool(true),
        )
        .expect("set auto_remove_read");
    imbib
        .set_read(vec![old_id.clone()], true)
        .expect("set read");

    // The engine's own connection: a fresh workflow row, then ticks.
    let engine_store =
        std::sync::Arc::new(SqliteItemStore::open(&path).expect("open engine handle"));
    impress_workflow_service::store::insert(
        &engine_store,
        &retention_workflow(),
        ActorKind::System,
    )
    .expect("seed workflow row");

    let mut engine = WorkflowEngine::new(0, 90_000);
    let workspace = path.parent().unwrap();

    let outcomes = engine.run_once(&engine_store, 89_999, workspace);
    assert!(
        outcomes.is_empty(),
        "must not run before the 90s start_delay: {outcomes:?}"
    );
    // The paper must still be untouched — no run means no cleanup.
    assert!(imbib.get_publication(old_id.clone()).unwrap().is_some());

    let outcomes = engine.run_once(&engine_store, 90_000, workspace);
    assert_eq!(outcomes.len(), 1, "runs exactly once, right at start_delay");
    assert_eq!(outcomes[0].name, "imbib.retention-cleanup");
    assert_eq!(outcomes[0].calls, 1, "one call: retention_cleanup");
    assert!(outcomes[0].error.is_none(), "{:?}", outcomes[0].error);

    // The verb actually ran: the read paper is gone.
    assert!(imbib.get_publication(old_id.clone()).unwrap().is_none());

    // And its call landed in the log — through the injected store, per
    // `pipeline::invoke_on`'s `store_override`.
    impress_store_service::audit::flush();
    let rows = engine_store
        .query(&ItemQuery {
            schema: Some("core/verb-call@1.0.0".into()),
            ..Default::default()
        })
        .expect("query call log");
    assert!(
        rows.iter().any(|item| {
            matches!(
                item.payload.get("verb"),
                Some(impress_core::item::Value::String(s)) if s.contains("retention-cleanup")
            )
        }),
        "expected a retention-cleanup call row, got {rows:?}"
    );
    let why = impress_service_core::runtime::block_on(
        DefaultHistoryService::with_store(engine_store.clone()).why(old_id),
    );
    assert!(why.ok, "{}", why.message);
    assert!(
        why.entries.iter().any(|entry| {
            entry.operation_id.is_none()
                && entry.call.as_ref().is_some_and(|call| {
                    call.verb == "imbib-library-service_retention-cleanup"
                        && call.caller["kind"] == "system"
                        && call.caller["name"]
                            .as_str()
                            .is_some_and(|name| name.starts_with("workflow:"))
                })
        }),
        "the removed paper must name its workflow run: {why:?}"
    );

    // A second tick before another 24h passes must not run again.
    let outcomes = engine.run_once(&engine_store, 100_000, workspace);
    assert!(outcomes.is_empty(), "not due again inside the 24h interval");
}
