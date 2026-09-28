//! Stored workflow examples use an independent document before every call.
use impress_core::{
    item::{ActorKind, ItemId},
    sqlite_store::SqliteItemStore,
    store::ItemStore,
};
use impress_workflow_service::{dto::WorkflowSpecArg, store as workflows};
use serde_json::{json, Value};
use std::{path::Path, sync::Arc};

fn id(suffix: u8) -> ItemId {
    format!("64000000-0000-4000-8000-{suffix:012}")
        .parse()
        .expect("fixture UUID")
}

pub async fn prepare(
    verb: &str,
    _: &str,
    store: &Arc<SqliteItemStore>,
    _: &Path,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("impress-workflow-service_workflow-") else {
        return Ok(());
    };
    let suffix = match method {
        "get" => 1,
        "dry-run" => 2,
        "enable" => 3,
        "disable" => 4,
        "list" => 5,
        _ => return Ok(()),
    };
    let state = if method == "disable" {
        "enabled"
    } else {
        "proposed"
    };
    let spec = WorkflowSpecArg(json!({"wire_version":1,"name":"G3 reviewable workflow","state":state,"author":{"kind":"human"},"trigger":{"manual":{}},"steps":[{"call":{"verb":"triage-service_set-flag","args":{"id":id(11).to_string(),"flag":"{{event.value.flag}}"}}}]})).parse().map_err(|e| e.to_string())?;
    let generated =
        workflows::insert(store, &spec, ActorKind::System).map_err(|e| e.to_string())?;
    let mut item = store
        .get(generated.id)
        .map_err(|e| e.to_string())?
        .ok_or("workflow insert missing")?;
    store.delete(generated.id).map_err(|e| e.to_string())?;
    if store.get(id(suffix)).map_err(|e| e.to_string())?.is_some() {
        store.delete(id(suffix)).map_err(|e| e.to_string())?;
    }
    item.id = id(suffix);
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn verify(
    verb: &str,
    _: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("impress-workflow-service_workflow-") else {
        return Ok(());
    };
    if result["ok"] != true {
        return Err(format!("workflow refused: {result}"));
    }
    match method {
        "create" | "get" | "enable" | "disable" => {
            let row_id = result["id"]
                .as_str()
                .ok_or("missing workflow id")?
                .parse()
                .map_err(|e| format!("workflow UUID: {e}"))?;
            let row = workflows::get(store, row_id)?.ok_or("workflow not persisted")?;
            if result["spec"] != serde_json::to_value(&row.spec).map_err(|e| e.to_string())? {
                return Err("returned workflow differs from store".into());
            }
        }
        "list" => {
            if !result["workflows"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|row| row["id"] == id(5).to_string()))
            {
                return Err("seeded workflow missing from list".into());
            }
        }
        "dry-run" => {
            let row_id = args["id"]
                .as_str()
                .ok_or("missing fixture id")?
                .parse()
                .map_err(|e| format!("fixture id: {e}"))?;
            let row = workflows::get(store, row_id)?.ok_or("dry-run removed workflow")?;
            if row.spec.state.as_str() != "proposed"
                || store.get(id(11)).map_err(|e| e.to_string())?.is_some()
            {
                return Err("dry-run executed or enabled the workflow".into());
            }
        }
        _ => {}
    }
    Ok(())
}
