//! Owned AI graph fixtures. Implore examples require a native host and are Tier B.

use std::path::Path;
use std::sync::Arc;

use impress_core::item::{ItemId, Value as ItemValue};
use impress_core::query::ItemQuery;
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::Value;

const PREFIX: &str = "65000000-0000-4000-8000-0000000000";

fn id(suffix: &str) -> String {
    format!("{PREFIX}{suffix}")
}

fn uuid(suffix: &str) -> Result<ItemId, String> {
    ItemId::parse_str(&id(suffix)).map_err(|e| e.to_string())
}

pub async fn prepare(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    _root: &Path,
) -> Result<(), String> {
    prepare_graph(verb, store)?;
    match (verb, example) {
        ("impress-ai-service_list-conversations", "scratch-conversation-list") => {
            conversation(store, "01", "G3 listed conversation")?;
        }
        ("impress-ai-service_get-conversation", "scratch-conversation-detail") => {
            conversation(store, "02", "G3 detailed conversation")?;
        }
        ("impress-ai-service_create-conversation", "start-research-conversation") => {
            for row in store
                .query(&ItemQuery {
                    schema: Some(refs::CONVERSATION),
                    ..Default::default()
                })
                .map_err(|e| e.to_string())?
            {
                if row.payload.get("title")
                    == Some(&ItemValue::String("G3 literature review".into()))
                {
                    store.delete(row.id).map_err(|e| e.to_string())?;
                }
            }
        }
        _ => {}
    }
    Ok(())
}

pub fn verify(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
) -> Result<(), String> {
    verify_graph(verb, store, result)?;
    match (verb, example) {
        ("impress-ai-service_ai-preferences", "scratch-device-preferences") => {
            let expected = impress_store_service::store_path()
                .parent()
                .ok_or("scratch store path has no parent")?
                .join("ai/preferences.json");
            if result["path"] != expected.to_string_lossy().as_ref()
                || result["preferences"].is_null()
                || !result["error"].is_null()
            {
                return Err("AI preferences did not come from scratch workspace".into());
            }
        }
        ("impress-ai-service_select-model", "select-local-model") => {
            if result["preferences"]["selected"]["provider"] != "ollama"
                || result["preferences"]["selected"]["model"] != "llama3.2"
            {
                return Err("scratch model preference was not selected".into());
            }
            require_saved_preference(result, "selected", "provider", "ollama")?;
        }
        ("impress-ai-service_set-provider-endpoint", "set-scratch-endpoint") => {
            if result["preferences"]["endpoints"]["ollama"] != "http://127.0.0.1:11435" {
                return Err("scratch endpoint was not selected".into());
            }
            require_saved_preference(result, "endpoints", "ollama", "http://127.0.0.1:11435")?;
        }
        ("impress-ai-service_list-conversations", "scratch-conversation-list") => {
            let rows = result["conversations"]
                .as_array()
                .ok_or("conversation list missing")?;
            if !rows.iter().any(|row| row["id"] == id("01")) {
                return Err("seeded conversation was omitted".into());
            }
        }
        ("impress-ai-service_get-conversation", "scratch-conversation-detail") => {
            if result["conversation"]["conversation"]["id"] != id("02")
                || !result["conversation"]["messages"].is_array()
                || !result["conversation"]["pending_tasks"].is_array()
            {
                return Err("conversation detail omitted the seeded row or graph lists".into());
            }
        }
        ("impress-ai-service_create-conversation", "start-research-conversation") => {
            let new_id = result["conversation_id"]
                .as_str()
                .ok_or("created conversation ID missing")?;
            let row = store
                .get(ItemId::parse_str(new_id).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?
                .ok_or("created conversation was not persisted")?;
            if row.schema != refs::CONVERSATION
                || row.payload.get("title")
                    != Some(&ItemValue::String("G3 literature review".into()))
            {
                return Err("created conversation did not retain title".into());
            }
        }
        _ => {}
    }
    Ok(())
}

fn conversation(store: &SqliteItemStore, suffix: &str, title: &str) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    if store.get(item_id).map_err(|e| e.to_string())?.is_some() {
        store.delete(item_id).map_err(|e| e.to_string())?;
    }
    let mut item = super::seed_item(item_id, refs::CONVERSATION.as_str(), None);
    item.payload
        .insert("title".into(), ItemValue::String(title.into()));
    item.payload
        .insert("state".into(), ItemValue::String("active".into()));
    item.payload
        .insert("provider".into(), ItemValue::String("ollama".into()));
    item.payload
        .insert("model".into(), ItemValue::String("llama3.2".into()));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn require_saved_preference(
    result: &Value,
    object: &str,
    key: &str,
    expected: &str,
) -> Result<(), String> {
    let path = result["path"].as_str().ok_or("preferences path missing")?;
    let owned = impress_store_service::store_path()
        .parent()
        .ok_or("scratch store path has no parent")?
        .join("ai/preferences.json");
    if Path::new(path) != owned {
        return Err("preferences path left the owned scratch workspace".into());
    }
    let saved: Value = serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if saved[object][key] == expected {
        Ok(())
    } else {
        Err(format!(
            "scratch preferences file did not persist {object}.{key}"
        ))
    }
}

fn graph_id(number: u8) -> ItemId {
    format!("68000000-0000-4000-8000-{number:012}")
        .parse()
        .expect("fixture UUID")
}
fn prepare_graph(verb: &str, store: &Arc<SqliteItemStore>) -> Result<(), String> {
    use impress_core::reference::{EdgeType, TypedReference};
    let method = verb.strip_prefix("impress-ai-service_").unwrap_or("");
    let rows = match method {
        "queue-message" => vec![(1, refs::CONVERSATION)],
        "set-enabled-tools" => vec![(2, refs::CONVERSATION)],
        "task-status" => vec![(3, refs::TASK)],
        "task-provenance" | "run-provenance" => vec![
            (4, refs::TASK),
            (6, refs::AGENT_RUN),
            (7, refs::CHAT_MESSAGE),
        ],
        _ => return Ok(()),
    };
    for (number, schema) in rows {
        if store
            .get(graph_id(number))
            .map_err(|e| e.to_string())?
            .is_some()
        {
            store.delete(graph_id(number)).map_err(|e| e.to_string())?;
        }
        let mut item = super::seed_item(graph_id(number), schema.as_str(), None);
        item.payload.insert(
            "state".into(),
            ItemValue::String(
                if schema == refs::CONVERSATION {
                    "active"
                } else {
                    "pending"
                }
                .into(),
            ),
        );
        item.payload
            .insert("title".into(), ItemValue::String("G3 graph fixture".into()));
        if schema == refs::AGENT_RUN {
            item.references.push(TypedReference {
                target: graph_id(4),
                edge_type: EdgeType::OperatesOn,
                metadata: None,
            });
            item.payload
                .insert("status".into(), ItemValue::String("completed".into()));
        }
        if number == 7 {
            item.produced_by = Some(graph_id(6));
            item.payload
                .insert("body".into(), ItemValue::String("Owned result".into()));
        }
        store.insert(item).map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn verify_graph(verb: &str, store: &Arc<SqliteItemStore>, result: &Value) -> Result<(), String> {
    match verb.strip_prefix("impress-ai-service_").unwrap_or("") {
        "queue-message" => {
            for field in ["message_id", "task_id"] {
                let row_id = result[field]
                    .as_str()
                    .ok_or("queued row id missing")?
                    .parse()
                    .map_err(|e| format!("queued UUID: {e}"))?;
                let row = store
                    .get(row_id)
                    .map_err(|e| e.to_string())?
                    .ok_or("queued row not persisted")?;
                if row.parent != Some(graph_id(1)) {
                    return Err("queued row is outside fixture conversation".into());
                }
            }
        }
        "set-enabled-tools" => {
            let row = store
                .get(graph_id(2))
                .map_err(|e| e.to_string())?
                .ok_or("conversation missing")?;
            if row.payload.get("web_access") != Some(&ItemValue::Bool(true))
                || !format!("{:?}", row.payload.get("enabled_tools")).contains("impress-mcp")
            {
                return Err("tool policy not persisted".into());
            }
        }
        "task-status" => {
            if result["task"]["task_id"] != graph_id(3).to_string() || !result["error"].is_null() {
                return Err("task progress did not read owned task".into());
            }
        }
        "task-provenance" | "run-provenance" => {
            let p = &result["provenance"];
            if p["task"]["id"] != graph_id(4).to_string()
                || p["run"]["id"] != graph_id(6).to_string()
                || !p["outputs"]
                    .as_array()
                    .is_some_and(|rows| rows.iter().any(|row| row["id"] == graph_id(7).to_string()))
            {
                return Err(format!("lineage omitted owned task/run/output: {result}"));
            }
        }
        _ => {}
    }
    Ok(())
}
