//! Owned-store fixtures for artifact, annotation, and comment examples.
//! Each example prepares only its own fixed rows before effects observation.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::Value;

const PREFIX: &str = "60000000-0000-4000-8000-0000000000";

fn id(suffix: &str) -> Result<ItemId, String> {
    format!("{PREFIX}{suffix}")
        .parse()
        .map_err(|e| format!("fixture id: {e}"))
}

fn row(
    suffix: &str,
    schema: impress_core::SchemaRef,
    parent: Option<&str>,
) -> Result<Item, String> {
    let now = SystemTime::now().into();
    Ok(Item {
        id: id(suffix)?,
        schema,
        payload: BTreeMap::new(),
        created: now,
        modified: now,
        author: "system:g3-artifact-fixture".into(),
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
        parent: parent.map(id).transpose()?,
    })
}

fn insert_once(store: &SqliteItemStore, item: Item) -> Result<(), String> {
    if store.get(item.id).map_err(|e| e.to_string())?.is_none() {
        store.insert(item).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn reset(store: &SqliteItemStore, suffix: &str) -> Result<(), String> {
    let item_id = id(suffix)?;
    if store.get(item_id).map_err(|e| e.to_string())?.is_some() {
        store.delete(item_id).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn artifact(
    store: &SqliteItemStore,
    suffix: &str,
    schema: impress_core::SchemaRef,
    title: &str,
) -> Result<(), String> {
    let mut item = row(suffix, schema, None)?;
    item.payload
        .insert("title".into(), ItemValue::String(title.into()));
    insert_once(store, item)
}

fn paper(store: &SqliteItemStore, suffix: &str) -> Result<(), String> {
    let mut item = row(suffix, refs::IMBIB_BIBLIOGRAPHY_ENTRY, None)?;
    item.payload.insert(
        "title".into(),
        ItemValue::String("G3 paper for artifacts".into()),
    );
    item.payload.insert(
        "cite_key".into(),
        ItemValue::String(format!("G3Paper{suffix}")),
    );
    item.payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    insert_once(store, item)
}

fn linked_file(store: &SqliteItemStore, suffix: &str) -> Result<(), String> {
    paper(store, "20")?;
    let mut item = row(suffix, refs::IMBIB_LINKED_FILE, Some("20"))?;
    item.payload
        .insert("file_name".into(), ItemValue::String("scratch.pdf".into()));
    item.payload.insert(
        "file_mime_type".into(),
        ItemValue::String("application/pdf".into()),
    );
    insert_once(store, item)
}

fn annotation(store: &SqliteItemStore) -> Result<(), String> {
    linked_file(store, "21")?;
    let mut item = row("22", refs::IMBIB_ANNOTATION, Some("21"))?;
    item.payload.insert(
        "annotation_type".into(),
        ItemValue::String("highlight".into()),
    );
    item.payload.insert("page_number".into(), ItemValue::Int(2));
    item.payload.insert(
        "selected_text".into(),
        ItemValue::String("Measured spectra".into()),
    );
    insert_once(store, item)
}

fn comment(store: &SqliteItemStore, suffix: &str, parent: &str, text: &str) -> Result<(), String> {
    let mut item = row(suffix, refs::IMBIB_COMMENT, Some(parent))?;
    item.payload
        .insert("text".into(), ItemValue::String(text.into()));
    if suffix == "32" {
        item.logical_clock = 2;
    }
    insert_once(store, item)
}

/// Seed the precise prerequisite for one verb. The prefix is disjoint from
/// every other G3 family and all rows stay in the caller's scratch database.
pub async fn prepare(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _root: &Path,
) -> Result<(), String> {
    match verb {
        "imbib-artifacts-service_list-artifacts" | "imbib-artifacts-service_get-artifact" => {
            artifact(store, "01", refs::IMPRESS_ARTIFACT_NOTE, "G3 artifact note")?
        }
        "imbib-artifacts-service_search-artifacts" | "imbib-artifacts-service_count-artifacts" => {
            artifact(
                store,
                "03",
                refs::IMPRESS_ARTIFACT_DATASET,
                "G3-artifact-needle dataset",
            )?
        }
        "imbib-artifacts-service_update-artifact" => {
            reset(store, "02")?;
            artifact(
                store,
                "02",
                refs::IMPRESS_ARTIFACT_NOTE,
                "G3 original artifact note",
            )?;
        }
        "imbib-artifacts-service_delete-artifact" => artifact(
            store,
            "04",
            refs::IMPRESS_ARTIFACT_NOTE,
            "G3 disposable artifact note",
        )?,
        "imbib-artifacts-service_link-artifact-to-publication" => {
            reset(store, "05")?;
            artifact(
                store,
                "05",
                refs::IMPRESS_ARTIFACT_DATASET,
                "G3 linked dataset",
            )?;
            paper(store, "20")?;
        }
        "imbib-artifacts-service_get-artifact-relations" => {
            paper(store, "20")?;
            let mut item = row("06", refs::IMPRESS_ARTIFACT_DATASET, None)?;
            item.payload.insert(
                "title".into(),
                ItemValue::String("G3 related dataset".into()),
            );
            item.references.push(TypedReference {
                target: id("20")?,
                edge_type: EdgeType::RelatesTo,
                metadata: None,
            });
            insert_once(store, item)?;
        }
        "imbib-annotations-service_list-annotations"
        | "imbib-annotations-service_count-annotations" => annotation(store)?,
        "imbib-annotations-service_create-annotation" => linked_file(store, "23")?,
        "imbib-annotations-service_list-comments-for-item" => {
            artifact(
                store,
                "40",
                refs::IMPRESS_ARTIFACT_NOTE,
                "G3 commented artifact",
            )?;
            comment(store, "31", "40", "Check the method.")?;
        }
        "imbib-annotations-service_list-comments" => {
            paper(store, "20")?;
            comment(store, "30", "20", "Compare the spectra.")?;
        }
        "imbib-annotations-service_list-comments-since" => {
            artifact(
                store,
                "41",
                refs::IMPRESS_ARTIFACT_NOTE,
                "G3 later artifact",
            )?;
            comment(store, "32", "41", "The later observation.")?;
        }
        "imbib-annotations-service_create-comment" => paper(store, "24")?,
        "imbib-annotations-service_create-comment-on-item" => artifact(
            store,
            "42",
            refs::IMPRESS_ARTIFACT_NOTE,
            "G3 comment target",
        )?,
        "imbib-annotations-service_update-comment" => {
            artifact(
                store,
                "43",
                refs::IMPRESS_ARTIFACT_NOTE,
                "G3 revision target",
            )?;
            reset(store, "33")?;
            comment(store, "33", "43", "The first interpretation.")?;
        }
        _ => {}
    }
    Ok(())
}

/// Verify persisted mutations and fixture-specific reads outside the effects spy.
pub fn verify(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
) -> Result<(), String> {
    let contains_id = |suffix: &str| -> Result<(), String> {
        let wanted = id(suffix)?.to_string();
        if !result.as_array().is_some_and(|rows| {
            rows.iter()
                .any(|row| row["id"].as_str() == Some(wanted.as_str()))
        }) {
            return Err(format!("{verb} omitted scratch row {wanted}"));
        }
        Ok(())
    };
    match verb {
        "imbib-artifacts-service_list-artifacts" => contains_id("01")?,
        "imbib-artifacts-service_search-artifacts" => contains_id("03")?,
        "imbib-artifacts-service_get-artifact" => {
            if result["id"].as_str() != Some(id("01")?.to_string().as_str()) {
                return Err("artifact get returned the wrong row".into());
            }
        }
        "imbib-artifacts-service_count-artifacts" => {
            if result.as_u64().unwrap_or(0) < 1 {
                return Err("artifact count omitted the dataset".into());
            }
        }
        "imbib-artifacts-service_create-artifact"
        | "imbib-annotations-service_create-annotation"
        | "imbib-annotations-service_create-comment"
        | "imbib-annotations-service_create-comment-on-item" => {
            let new_id = result["id"]
                .as_str()
                .ok_or_else(|| format!("{verb} returned no id"))?
                .parse::<ItemId>()
                .map_err(|e| e.to_string())?;
            if store.get(new_id).map_err(|e| e.to_string())?.is_none() {
                return Err(format!("{verb} did not persist {new_id}"));
            }
        }
        "imbib-artifacts-service_update-artifact" => {
            let item = store
                .get(id("02")?)
                .map_err(|e| e.to_string())?
                .ok_or("artifact missing")?;
            if item.payload.get("title")
                != Some(&ItemValue::String("G3 revised artifact note".into()))
            {
                return Err("artifact rename did not persist".into());
            }
        }
        "imbib-artifacts-service_delete-artifact" => {
            if store.get(id("04")?).map_err(|e| e.to_string())?.is_some() {
                return Err("artifact still exists after delete".into());
            }
        }
        "imbib-artifacts-service_link-artifact-to-publication" => {
            let item = store
                .get(id("05")?)
                .map_err(|e| e.to_string())?
                .ok_or("linked artifact missing")?;
            if !item.references.iter().any(|edge| {
                edge.target == id("20").expect("fixed fixture id")
                    && edge.edge_type == EdgeType::RelatesTo
            }) {
                return Err("artifact relation was not persisted".into());
            }
        }
        "imbib-artifacts-service_get-artifact-relations" => {
            if !result.as_array().is_some_and(|rows| {
                rows.iter().any(|row| {
                    row["target_id"].as_str()
                        == Some(id("20").expect("fixed fixture id").to_string().as_str())
                })
            }) {
                return Err("artifact relations omitted the paper".into());
            }
        }
        "imbib-annotations-service_list-annotations" => contains_id("22")?,
        "imbib-annotations-service_count-annotations" => {
            if result.as_u64() != Some(1) {
                return Err(format!("expected one scratch annotation, got {result}"));
            }
        }
        "imbib-annotations-service_list-comments-for-item" => contains_id("31")?,
        "imbib-annotations-service_list-comments" => contains_id("30")?,
        "imbib-annotations-service_list-comments-since" => contains_id("32")?,
        "imbib-annotations-service_update-comment" => {
            let item = store
                .get(id("33")?)
                .map_err(|e| e.to_string())?
                .ok_or("comment missing")?;
            if item.payload.get("text")
                != Some(&ItemValue::String("The revised interpretation.".into()))
            {
                return Err("comment revision did not persist".into());
            }
        }
        _ => {}
    }
    Ok(())
}
