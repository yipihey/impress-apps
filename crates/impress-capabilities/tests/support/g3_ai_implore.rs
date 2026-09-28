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
