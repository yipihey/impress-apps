//! Per-example impel fixtures in the caller's scratch store.
//!
//! No task daemon or executor is started. Every mutating example has its own
//! fixed task/review so inventory order cannot turn a later call into a no-op.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::job;
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::{json, Value};

const PREFIX: &str = "5d000000-0000-4000-8000-0000000000";
const JOB_VERB: &str = "smart-search-service_classify-search-input";

fn id(suffix: &str) -> Result<ItemId, String> {
    format!("{PREFIX}{suffix}")
        .parse()
        .map_err(|e| format!("fixture id: {e}"))
}

fn item(id: ItemId, schema: impress_core::SchemaRef) -> Item {
    let now = SystemTime::now().into();
    Item {
        id,
        schema,
        payload: BTreeMap::new(),
        created: now,
        modified: now,
        author: "system:g3-job-fixture".into(),
        author_kind: ActorKind::System,
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
        references: vec![],
        parent: None,
    }
}

fn task(store: &SqliteItemStore, suffix: &str, state: &str, kind: &str) -> Result<ItemId, String> {
    let task_id = id(suffix)?;
    if store.get(task_id).map_err(|e| e.to_string())?.is_none() {
        let mut row = item(task_id, impress_core::schema::refs::TASK);
        row.payload = BTreeMap::from([
            ("title".into(), ItemValue::String(format!("G3 {kind}"))),
            ("state".into(), ItemValue::String(state.into())),
            ("task_kind".into(), ItemValue::String(kind.into())),
            ("attempts".into(), ItemValue::Int(1)),
            ("verb".into(), ItemValue::String(JOB_VERB.into())),
            (
                "runner".into(),
                ItemValue::String("fixture:headless".into()),
            ),
            ("cancel_requested".into(), ItemValue::Bool(false)),
        ]);
        if state == "done" {
            row.payload.insert(
                "result".into(),
                ItemValue::String(json!({"ok":true,"answer":42}).to_string()),
            );
        }
        if state == "failed" {
            row.payload.insert(
                "error".into(),
                ItemValue::String("source was removed".into()),
            );
            row.payload
                .insert("spawned_by".into(), ItemValue::String("g3-fixture".into()));
        }
        store.insert(row).map_err(|e| e.to_string())?;
    }
    Ok(task_id)
}

fn review(store: &SqliteItemStore, suffix: &str, task_id: ItemId) -> Result<ItemId, String> {
    let review_id = id(suffix)?;
    if store.get(review_id).map_err(|e| e.to_string())?.is_none() {
        let mut row = item(review_id, impress_core::schema::refs::REVIEW_REQUEST);
        row.payload.insert(
            "question".into(),
            ItemValue::String("Approve the proposed tags?".into()),
        );
        row.payload.insert(
            "context_proposed_tags".into(),
            ItemValue::Array(vec![ItemValue::String("reviewed".into())]),
        );
        row.references.push(TypedReference {
            target: task_id,
            edge_type: EdgeType::OperatesOn,
            metadata: None,
        });
        store.insert(row).map_err(|e| e.to_string())?;
    }
    Ok(review_id)
}

/// Seed exactly the row needed by one example, before the effects spy starts.
pub async fn prepare(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _root: &Path,
) -> Result<(), String> {
    match verb {
        "impel-service_scheduler-status" => {
            task(store, "01", "pending", "g3-backlog")?;
        }
        "impel-service_list-failed-tasks" => {
            task(store, "02", "failed", "g3-failed")?;
        }
        "impel-service_list-pending-reviews" => {
            let task_id = task(store, "03", "pending", "g3-review")?;
            review(store, "04", task_id)?;
        }
        "impel-service_resolve-review" => {
            let task_id = task(store, "06", "pending", "g3-approval")?;
            review(store, "05", task_id)?;
        }
        "impel-service_cancel-task" => {
            task(store, "07", "pending", "g3-cancel")?;
        }
        "impel-service_job-status" => {
            task(store, "08", "done", JOB_VERB)?;
        }
        "impel-service_job-events" => {
            let task_id = task(store, "09", "running", JOB_VERB)?;
            if job::events_after(store, task_id, 0, 0)
                .map_err(|e| e.to_string())?
                .is_empty()
            {
                job::append_event(
                    store,
                    task_id,
                    "indexed",
                    &json!({"papers":3}),
                    "g3-fixture",
                )
                .map_err(|e| e.to_string())?;
            }
        }
        "impel-service_job-wait" => {
            task(store, "0a", "done", JOB_VERB)?;
        }
        "impel-service_job-cancel" => {
            task(store, "0b", "pending", JOB_VERB)?;
        }
        "impel-service_job-result" => {
            task(store, "0c", "done", JOB_VERB)?;
        }
        "impel-service_retention-status" => {
            // A live scratch task makes the preview meaningful without
            // asserting a global count influenced by other example families.
            task(store, "0d", "pending", "g3-retained")?;
        }
        _ => {}
    }
    Ok(())
}

/// Verify IDs and persisted state outside the spy window; counts can include
/// independent examples already executed in the same process.
pub fn verify(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
) -> Result<(), String> {
    let has_id = |suffix: &str| {
        let wanted = id(suffix).map(|id| id.to_string())?;
        result
            .as_array()
            .is_some_and(|rows| {
                rows.iter()
                    .any(|row| row["id"].as_str() == Some(wanted.as_str()))
            })
            .then_some(())
            .ok_or_else(|| format!("{verb} omitted scratch id {wanted}"))
    };
    match verb {
        "impel-service_scheduler-status" => {
            if result["tasks"]["pending"].as_u64().unwrap_or(0) < 1
                || !result["by_kind"]
                    .as_array()
                    .is_some_and(|rows| rows.iter().any(|row| row["task_kind"] == "g3-backlog"))
            {
                return Err("scheduler status omitted the scratch backlog".into());
            }
        }
        "impel-service_list-failed-tasks" => {
            has_id("02")?;
        }
        "impel-service_list-pending-reviews" => {
            has_id("04")?;
        }
        "impel-service_resolve-review" => {
            let row = store
                .get(id("05")?)
                .map_err(|e| e.to_string())?
                .ok_or("review missing")?;
            if row.payload.get("resolution") != Some(&ItemValue::String("approved".into())) {
                return Err("review approval did not persist".into());
            }
        }
        "impel-service_cancel-task" | "impel-service_job-cancel" => {
            let suffix = if verb.ends_with("cancel-task") {
                "07"
            } else {
                "0b"
            };
            let row = store
                .get(id(suffix)?)
                .map_err(|e| e.to_string())?
                .ok_or("task missing")?;
            if row.payload.get("state") != Some(&ItemValue::String("cancelled".into())) {
                return Err(format!("{verb} did not persist cancellation"));
            }
        }
        "impel-service_job-status"
        | "impel-service_job-events"
        | "impel-service_job-wait"
        | "impel-service_job-result" => {
            if result["ok"].as_bool() != Some(true) {
                return Err(format!("{verb} failed: {result}"));
            }
        }
        "impel-service_retention-status" => {
            if result["live_tasks"].as_u64().unwrap_or(0) < 1 {
                return Err("retention preview omitted the live scratch task".into());
            }
        }
        _ => {}
    }
    Ok(())
}
