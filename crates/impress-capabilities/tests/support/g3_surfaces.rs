//! A different surface row per example; no dependency on inventory order.
use impress_core::{
    item::{ActorKind, ItemId},
    sqlite_store::SqliteItemStore,
    store::ItemStore,
};
use impress_layout_service::{DefaultLayoutService, LayoutService};
use impress_surface_service::SurfaceStore;
use serde_json::{json, Value};
use std::{path::Path, sync::Arc};

const HOST: &str = "g3-surface-examples";
fn id(number: usize) -> ItemId {
    format!("66000000-0000-4000-8000-{number:012}")
        .parse()
        .expect("fixture UUID")
}
fn number(method: &str) -> Option<usize> {
    [
        "validate",
        "create",
        "update",
        "get",
        "delete",
        "show",
        "render",
        "state-get",
        "state-set",
        "dispatch",
        "events",
        "wait",
        "list",
    ]
    .iter()
    .position(|name| *name == method)
    .map(|index| index + 1)
}

pub async fn prepare(
    verb: &str,
    _: &str,
    store: &Arc<SqliteItemStore>,
    _: &Path,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("impress-surface-service_surface-") else {
        return Ok(());
    };
    let Some(number) = number(method) else {
        return Ok(());
    };
    if matches!(method, "create" | "validate") {
        return Ok(());
    }
    let surfaces = SurfaceStore::new(store.clone());
    if surfaces
        .get(id(number))
        .map_err(|e| e.to_string())?
        .is_some()
    {
        surfaces.delete(id(number)).map_err(|e| e.to_string())?;
    }
    let spec = serde_json::from_value(json!({"surface":"1.0","name":"G3 surface","state":{"message":"ready"},"root":{"column":[{"text":"{{state.message}}","id":"message"},{"button":{"label":"Set message","on_click":[{"set":{"path":"state.message","value":"done"}},{"emit":{"name":"changed","payload":{"message":"{{state.message}}"}}}]},"id":"set-message"}]}})).map_err(|e| e.to_string())?;
    let row = surfaces
        .create(&spec, None, &[], ActorKind::System)
        .map_err(|e| e.to_string())?;
    let mut item = store
        .get(row.id)
        .map_err(|e| e.to_string())?
        .ok_or("surface insert missing")?;
    store.delete(row.id).map_err(|e| e.to_string())?;
    item.id = id(number);
    store.insert(item).map_err(|e| e.to_string())?;
    if matches!(method, "delete" | "events" | "wait") {
        surfaces
            .set_state(
                id(number),
                HOST,
                &json!({"message":"seeded"}),
                ActorKind::System,
            )
            .map_err(|e| e.to_string())?;
        surfaces
            .append_event(
                id(number),
                HOST,
                "changed",
                &json!({"message":"seeded"}),
                ActorKind::System,
            )
            .map_err(|e| e.to_string())?;
    }
    if method == "show" {
        let result = DefaultLayoutService::new()
            .get_layout("impress".into(), Some("g3-surface-show".into()))
            .await;
        if !result.ok {
            return Err(result.message);
        }
    }
    Ok(())
}

pub fn verify(
    verb: &str,
    _: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("impress-surface-service_surface-") else {
        return Ok(());
    };
    if result["ok"] != true {
        return Err(format!("surface refused: {result}"));
    }
    let surfaces = SurfaceStore::new(store.clone());
    match method {
        "create" | "get" | "update" => {
            let row_id = result["id"]
                .as_str()
                .ok_or("missing surface id")?
                .parse()
                .map_err(|e| format!("surface id: {e}"))?;
            let row = surfaces
                .get(row_id)
                .map_err(|e| e.to_string())?
                .ok_or("surface not persisted")?;
            if result["spec"] != serde_json::to_value(&row.spec).map_err(|e| e.to_string())?
                || result["revision"] != row.revision
            {
                return Err("surface result differs from stored spec/revision".into());
            }
        }
        "delete" => {
            let row_id = id(number(method).unwrap());
            if surfaces.get(row_id).map_err(|e| e.to_string())?.is_some()
                || surfaces
                    .get_state(row_id, HOST)
                    .map_err(|e| e.to_string())?
                    .is_some()
                || !surfaces
                    .events_after(row_id, HOST, 0, 200)
                    .map_err(|e| e.to_string())?
                    .is_empty()
            {
                return Err("deleted surface retained state or events".into());
            }
        }
        "state-set" | "dispatch" => {
            let row_id = args["id"]
                .as_str()
                .ok_or("surface argument id")?
                .parse()
                .map_err(|e| format!("surface argument id: {e}"))?;
            let state = surfaces
                .get_state(row_id, HOST)
                .map_err(|e| e.to_string())?
                .ok_or("surface state not persisted")?;
            let expected = if method == "dispatch" {
                "done"
            } else {
                "revised"
            };
            if state["message"] != expected {
                return Err(format!("surface state differs: {state}"));
            }
            if method == "dispatch"
                && !surfaces
                    .events_after(row_id, HOST, 0, 200)
                    .map_err(|e| e.to_string())?
                    .iter()
                    .any(|event| event.name == "changed" && event.payload["message"] == "done")
            {
                return Err("dispatch did not persist emitted event".into());
            }
        }
        "show" => {
            let loaded = impress_layout_service::store::LayoutStore::new(store.clone())
                .load_live("impress", "g3-surface-show", ActorKind::System)
                .map_err(|e| e.to_string())?;
            let tree = serde_json::to_value(&loaded.layout).map_err(|e| e.to_string())?;
            if result["tile"].as_u64().is_none()
                || !tree
                    .to_string()
                    .contains(args["id"].as_str().ok_or("surface argument id")?)
            {
                return Err("surface-show did not persist its surface pane".into());
            }
        }
        "render" => {
            if !result["tree"].to_string().contains("ready") {
                return Err("render omitted resolved state text".into());
            }
        }
        "list" => {
            if !result["surfaces"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|row| row["id"] == id(13).to_string()))
            {
                return Err("seeded surface missing from list".into());
            }
        }
        _ => {}
    }
    Ok(())
}
