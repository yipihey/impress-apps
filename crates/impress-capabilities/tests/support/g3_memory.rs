//! Scratch-store records for the memory service's G3 examples. Each ID-based
//! example starts with a real memory row; the service under test never creates
//! its own prerequisite through another production verb.

use std::path::Path;
use std::sync::Arc;

use impress_core::item::Item;
use impress_core::schemas::MEMORY_CLAIM_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::{json, Value};

const RECALL_ID: &str = "58000000-0000-4000-8000-000000000001";
const BRIEF_ID: &str = "58000000-0000-4000-8000-000000000002";
const CONFIRM_ID: &str = "58000000-0000-4000-8000-000000000003";
const SUPERSEDE_ID: &str = "58000000-0000-4000-8000-000000000004";
const FORGET_ID: &str = "58000000-0000-4000-8000-000000000005";
const RECALL_SUBJECT: &str = "58000000-0000-4000-8000-000000000009";
const BRIEF_SUBJECT: &str = "58000000-0000-4000-8000-00000000000a";

pub async fn prepare(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    _root: &Path,
) -> Result<(), String> {
    match (verb, example) {
        ("memory-service_recall", "subject-scoped-aperture") => seed(
            store,
            RECALL_ID,
            "G3 aperture radius",
            "The G3 aperture radius is five pixels.",
            Some(RECALL_SUBJECT),
        ),
        ("memory-service_memory-brief", "topic-brief") => seed(
            store,
            BRIEF_ID,
            "G3 aperture correction",
            "The G3 aperture correction uses local sky subtraction.",
            Some(BRIEF_SUBJECT),
        ),
        ("memory-service_confirm-claim", "confirm-observation") => seed(
            store,
            CONFIRM_ID,
            "G3 observation",
            "The G3 detector gain is two electrons per count.",
            None,
        ),
        ("memory-service_supersede-claim", "correct-flux-unit") => seed(
            store,
            SUPERSEDE_ID,
            "G3 old flux unit",
            "G3 fluxes are measured in janskys.",
            None,
        ),
        ("memory-service_forget", "withhold-private-note") => seed(
            store,
            FORGET_ID,
            "G3 private note",
            "This G3 private note should be withheld from recall.",
            None,
        ),
        _ => Ok(()),
    }
}

fn seed(
    store: &SqliteItemStore,
    id: &str,
    title: &str,
    body: &str,
    subject: Option<&str>,
) -> Result<(), String> {
    let id_value = id.parse().map_err(|e| format!("fixture UUID {id}: {e}"))?;
    if store.get(id_value).map_err(|e| e.to_string())?.is_some() {
        // A repeated run starts from the same precondition. These reserved
        // IDs are only used by this scratch fixture.
        store.delete(id_value).map_err(|e| e.to_string())?;
    }
    let mut payload = json!({"title": title, "body": body, "claim_type": "fact"});
    if let Some(subject) = subject {
        payload["subject_refs"] = json!([subject]);
    }
    let item: Item = serde_json::from_value(json!({
        "id": id,
        "schema": MEMORY_CLAIM_SCHEMA,
        "payload": payload,
        "created": "2026-09-28T00:00:00Z",
        "modified": "2026-09-28T00:00:00Z",
        "author": "g3-memory-fixture",
        "author_kind": "System",
        "logical_clock": 0,
        "origin": null,
        "canonical_id": null,
        "tags": [],
        "flag": null,
        "is_read": false,
        "is_starred": false,
        "priority": "normal",
        "visibility": "private",
        "message_type": null,
        "produced_by": null,
        "version": "1.0.0",
        "batch_id": null,
        "references": [],
        "parent": null
    }))
    .map_err(|e| format!("fixture item {id}: {e}"))?;
    store.insert(item).map_err(|e| e.to_string())?;
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
        ("memory-service_remember", "new-claim") => {
            let id = result["claim_id"].as_str().ok_or("missing new claim ID")?;
            let item = load(store, id)?;
            if item.schema != MEMORY_CLAIM_SCHEMA
                || item.payload.get("body")
                    != Some(&impress_core::item::Value::String(
                        "G3 calibration fluxes use millijanskys.".into(),
                    ))
            {
                return Err("new claim was not persisted with its body".into());
            }
        }
        ("memory-service_confirm-claim", "confirm-observation") => {
            let item = load(store, CONFIRM_ID)?;
            if item.payload.get("confirmations") != Some(&impress_core::item::Value::Int(1)) {
                return Err("confirmation count did not increase to one".into());
            }
        }
        ("memory-service_supersede-claim", "correct-flux-unit") => {
            let new_id = result["new_id"].as_str().ok_or("missing replacement ID")?;
            if new_id == SUPERSEDE_ID {
                return Err("replacement reused the superseded ID".into());
            }
            let replacement = load(store, new_id)?;
            load(store, SUPERSEDE_ID)?;
            if replacement.schema != MEMORY_CLAIM_SCHEMA
                || replacement.payload.get("body")
                    != Some(&impress_core::item::Value::String(
                        "G3 fluxes are measured in millijanskys.".into(),
                    ))
            {
                return Err("replacement claim was not persisted".into());
            }
        }
        ("memory-service_forget", "withhold-private-note") => {
            let item = load(store, FORGET_ID)?;
            if item.payload.get("no_recall") != Some(&impress_core::item::Value::Bool(true)) {
                return Err("memory was not withheld from recall".into());
            }
        }
        _ => {}
    }
    Ok(())
}

fn load(store: &SqliteItemStore, id: &str) -> Result<Item, String> {
    let id_value = id.parse().map_err(|e| format!("result UUID {id}: {e}"))?;
    store
        .get(id_value)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("memory item {id} was not found"))
}
