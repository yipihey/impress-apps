//! Owned SQLite fixtures for imbib search, SciX mirrors, and local e-ink rows.
//! The Tier B tablet examples require a separately owned device endpoint and
//! are deliberately never prepared or executed by the headless catalogue.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::query::ItemQuery;
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::Value;

const PREFIX: &str = "63000000-0000-4000-8000-0000000000";

fn id(suffix: &str) -> Result<ItemId, String> {
    format!("{PREFIX}{suffix}")
        .parse()
        .map_err(|error| format!("search/device fixture id: {error}"))
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
        author: "system:g3-search-device-fixture".into(),
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

fn reset(store: &SqliteItemStore, suffix: &str) -> Result<(), String> {
    let item_id = id(suffix)?;
    if store
        .get(item_id)
        .map_err(|error| error.to_string())?
        .is_some()
    {
        store.delete(item_id).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn insert_once(store: &SqliteItemStore, item: Item) -> Result<(), String> {
    if store
        .get(item.id)
        .map_err(|error| error.to_string())?
        .is_none()
    {
        store.insert(item).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn library(store: &SqliteItemStore) -> Result<(), String> {
    let mut item = row("01", refs::IMBIB_LIBRARY, None)?;
    item.payload
        .insert("name".into(), ItemValue::String("G3 search library".into()));
    insert_once(store, item)
}

fn paper(store: &SqliteItemStore, suffix: &str) -> Result<(), String> {
    library(store)?;
    let parent = if suffix == "08" {
        let mut extra = row("0a", refs::IMBIB_LIBRARY, None)?;
        extra.payload.insert(
            "name".into(),
            ItemValue::String("G3 tablet-only library".into()),
        );
        insert_once(store, extra)?;
        "0a"
    } else {
        "01"
    };
    let mut item = row(suffix, refs::IMBIB_BIBLIOGRAPHY_ENTRY, Some(parent))?;
    item.payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    item.payload.insert(
        "title".into(),
        ItemValue::String("G3 search spectra".into()),
    );
    item.payload.insert(
        "cite_key".into(),
        ItemValue::String(format!("G3Search2026{suffix}")),
    );
    if suffix == "02" {
        item.payload
            .insert("cite_key".into(), ItemValue::String("G3Search2026".into()));
        item.payload
            .insert("doi".into(), ItemValue::String("10.6300/g3-search".into()));
        item.payload
            .insert("arxiv_id".into(), ItemValue::String("2609.06300".into()));
        item.payload
            .insert("bibcode".into(), ItemValue::String("2026G3...6300S".into()));
    }
    insert_once(store, item)
}

fn smart_search(store: &SqliteItemStore) -> Result<(), String> {
    library(store)?;
    let mut item = row("03", refs::IMBIB_SMART_SEARCH, Some("01"))?;
    item.payload
        .insert("name".into(), ItemValue::String("G3 saved spectra".into()));
    item.payload
        .insert("query".into(), ItemValue::String("spectra".into()));
    item.payload
        .insert("max_results".into(), ItemValue::Int(25));
    insert_once(store, item)
}

fn scix(store: &SqliteItemStore, linked: bool) -> Result<(), String> {
    paper(store, "02")?;
    reset(store, "04")?;
    let mut item = row("04", refs::IMBIB_SCIX_LIBRARY, None)?;
    item.payload.insert(
        "remote_id".into(),
        ItemValue::String("g3-remote-existing".into()),
    );
    item.payload.insert(
        "name".into(),
        ItemValue::String("G3 existing SciX list".into()),
    );
    item.payload
        .insert("permission_level".into(), ItemValue::String("owner".into()));
    item.payload
        .insert("is_public".into(), ItemValue::Bool(false));
    if linked {
        item.references.push(TypedReference {
            target: id("02")?,
            edge_type: EdgeType::Contains,
            metadata: None,
        });
    }
    store.insert(item).map_err(|error| error.to_string())?;
    Ok(())
}

fn device(store: &SqliteItemStore, suffix: &str) -> Result<(), String> {
    reset(store, suffix)?;
    let name = if suffix == "06" {
        "G3 removable tablet"
    } else {
        "G3 reading tablet"
    };
    // The e-ink store supplies all other configuration defaults when reading
    // this row. No headless example connects to the loopback URL.
    let mut item = row(suffix, refs::IMBIB_EINK_DEVICE, None)?;
    item.payload
        .insert("name".into(), ItemValue::String(name.into()));
    item.payload.insert(
        "base_url".into(),
        ItemValue::String("http://127.0.0.1:65534".into()),
    );
    item.payload
        .insert("mirror_mode".into(), ItemValue::String("individual".into()));
    item.payload.insert("enabled".into(), ItemValue::Bool(true));
    store.insert(item).map_err(|error| error.to_string())?;
    Ok(())
}

fn mirror(store: &SqliteItemStore, suffix: &str, device_suffix: &str) -> Result<(), String> {
    paper(store, "02")?;
    reset(store, suffix)?;
    let mut item = row(suffix, refs::IMBIB_EINK_MIRROR, Some("02"))?;
    item.payload.insert(
        "device_id".into(),
        ItemValue::String(id(device_suffix)?.to_string()),
    );
    item.payload
        .insert("state".into(), ItemValue::String("awaiting_source".into()));
    item.payload.insert("marked".into(), ItemValue::Bool(true));
    item.payload.insert("attempts".into(), ItemValue::Int(0));
    store.insert(item).map_err(|error| error.to_string())?;
    Ok(())
}

fn clear_mark_paper_mirrors(store: &SqliteItemStore) -> Result<(), String> {
    let rows = store
        .query(&ItemQuery {
            schema: Some(refs::IMBIB_EINK_MIRROR),
            ..Default::default()
        })
        .map_err(|error| error.to_string())?;
    for item in rows.into_iter().filter(|row| row.parent == id("08").ok()) {
        store.delete(item.id).map_err(|error| error.to_string())?;
    }
    Ok(())
}

/// Called before each example, outside the effects spy. Every mutation starts
/// from its own fixed prerequisite, regardless of catalogue order.
pub async fn prepare(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    if verb.starts_with("imbib-search-service_")
        || verb.starts_with("imbib-scix-service_")
        || verb.starts_with("imbib-eink-service_")
    {
        std::fs::create_dir_all(root.join("search-devices"))
            .map_err(|error| format!("create owned search/device fixture directory: {error}"))?;
    }
    prepare_annotations(verb, store, root)?;
    match verb {
        "imbib-search-service_find-by-cite-key"
        | "imbib-search-service_resolve-cite-key"
        | "imbib-search-service_find-by-doi"
        | "imbib-search-service_find-by-arxiv"
        | "imbib-search-service_find-by-bibcode"
        | "imbib-search-service_find-by-identifiers-batch"
        | "imbib-search-service_full-text-search" => paper(store, "02")?,
        "imbib-search-service_list-smart-searches" | "imbib-search-service_get-smart-search" => {
            smart_search(store)?
        }
        "imbib-search-service_create-smart-search" => library(store)?,
        "imbib-scix-service_list-scix-libraries"
        | "imbib-scix-service_get-scix-library"
        | "imbib-scix-service_add-to-scix-library" => scix(store, false)?,
        "imbib-scix-service_remove-from-scix-library"
        | "imbib-scix-service_query-scix-library-publications"
        | "imbib-scix-service_count-scix-library-publications" => scix(store, true)?,
        "imbib-eink-service_eink-status" | "imbib-eink-service_eink-devices" => {
            device(store, "05")?
        }
        "imbib-eink-service_eink-configure-device" => reset(store, "06")?,
        "imbib-eink-service_eink-remove-device" => {
            device(store, "06")?;
            mirror(store, "09", "06")?;
        }
        "imbib-eink-service_eink-mark" => {
            device(store, "05")?;
            paper(store, "08")?;
            clear_mark_paper_mirrors(store)?;
        }
        "imbib-eink-service_eink-note-source-error"
        | "imbib-eink-service_eink-unmark"
        | "imbib-eink-service_eink-resend"
        | "imbib-eink-service_eink-list-mirrored"
        | "imbib-eink-service_eink-awaiting-source" => {
            device(store, "05")?;
            mirror(store, "07", "05")?;
        }
        _ => {}
    }
    Ok(())
}

fn contains_result_id(result: &Value, field: &str, suffix: &str) -> Result<(), String> {
    let wanted = id(suffix)?.to_string();
    if result.as_array().is_some_and(|rows| {
        rows.iter()
            .any(|row| row[field].as_str() == Some(wanted.as_str()))
    }) {
        Ok(())
    } else {
        Err(format!("result omitted seeded {field}={wanted}"))
    }
}

/// Check the precise result and persisted state after the real verb returns.
pub fn verify(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
) -> Result<(), String> {
    verify_annotations(verb, store, result)?;
    match verb {
        "imbib-search-service_find-by-cite-key"
        | "imbib-search-service_get-smart-search"
        | "imbib-scix-service_get-scix-library" => {
            let suffix = if verb.contains("smart-search") {
                "03"
            } else if verb.contains("scix") {
                "04"
            } else {
                "02"
            };
            if result["id"].as_str() != Some(id(suffix)?.to_string().as_str()) {
                return Err(format!("{verb} returned the wrong scratch row"));
            }
        }
        "imbib-search-service_resolve-cite-key" => {
            if result["publication"]["id"].as_str() != Some(id("02")?.to_string().as_str()) {
                return Err("cite-key resolution did not identify the scratch paper".into());
            }
        }
        "imbib-search-service_find-by-doi"
        | "imbib-search-service_find-by-arxiv"
        | "imbib-search-service_find-by-bibcode"
        | "imbib-search-service_find-by-identifiers-batch"
        | "imbib-search-service_full-text-search"
        | "imbib-scix-service_query-scix-library-publications" => {
            contains_result_id(result, "id", "02")?
        }
        "imbib-search-service_list-smart-searches" => contains_result_id(result, "id", "03")?,
        "imbib-search-service_create-smart-search" | "imbib-scix-service_create-scix-library" => {
            let row_id = result["id"]
                .as_str()
                .ok_or_else(|| format!("{verb} returned no id"))?
                .parse::<ItemId>()
                .map_err(|error| error.to_string())?;
            if store
                .get(row_id)
                .map_err(|error| error.to_string())?
                .is_none()
            {
                return Err(format!("{verb} did not persist {row_id}"));
            }
        }
        "imbib-scix-service_list-scix-libraries" => contains_result_id(result, "id", "04")?,
        "imbib-scix-service_add-to-scix-library"
        | "imbib-scix-service_remove-from-scix-library" => {
            let row = store
                .get(id("04")?)
                .map_err(|error| error.to_string())?
                .ok_or("SciX mirror missing")?;
            let linked = row.references.iter().any(|edge| {
                edge.target == id("02").expect("fixture id") && edge.edge_type == EdgeType::Contains
            });
            if linked != verb.contains("add-to") {
                return Err(format!("{verb} membership did not change"));
            }
        }
        "imbib-eink-service_eink-status" => contains_result_id(&result["devices"], "id", "05")?,
        "imbib-eink-service_eink-devices" => contains_result_id(result, "id", "05")?,
        "imbib-eink-service_eink-configure-device" => {
            if store
                .get(id("06")?)
                .map_err(|error| error.to_string())?
                .is_none()
            {
                return Err("configured tablet did not persist".into());
            }
        }
        "imbib-eink-service_eink-remove-device" => {
            if store
                .get(id("06")?)
                .map_err(|error| error.to_string())?
                .is_some()
                || store
                    .get(id("09")?)
                    .map_err(|error| error.to_string())?
                    .is_some()
            {
                return Err("removed tablet or its mirror still exists".into());
            }
        }
        "imbib-eink-service_eink-mark" => {
            let rows = store
                .query(&ItemQuery {
                    schema: Some(refs::IMBIB_EINK_MIRROR),
                    ..Default::default()
                })
                .map_err(|error| error.to_string())?;
            if !rows.iter().any(|row| {
                row.parent == Some(id("08").expect("fixture id"))
                    && row.payload.get("device_id")
                        == Some(&ItemValue::String(
                            id("05").expect("fixture id").to_string(),
                        ))
                    && row.payload.get("state")
                        == Some(&ItemValue::String("awaiting_source".into()))
            }) {
                return Err("marked paper did not persist an awaiting-source mirror".into());
            }
        }
        "imbib-eink-service_eink-unmark" => {
            if store
                .get(id("07")?)
                .map_err(|error| error.to_string())?
                .is_some()
            {
                return Err("unmarked pending mirror was not removed".into());
            }
        }
        "imbib-eink-service_eink-resend" => {
            let row = store
                .get(id("07")?)
                .map_err(|error| error.to_string())?
                .ok_or("resend mirror missing")?;
            if row.payload.get("resend") != Some(&ItemValue::Bool(true)) {
                return Err("resend flag was not saved".into());
            }
        }
        "imbib-eink-service_eink-list-mirrored" => contains_result_id(result, "id", "07")?,
        "imbib-eink-service_eink-awaiting-source" => contains_result_id(result, "mirror_id", "07")?,
        _ => {}
    }
    Ok(())
}

fn annotation_id(number: u8) -> ItemId {
    format!("6b000000-0000-4000-8000-{number:012}")
        .parse()
        .expect("fixture UUID")
}
fn prepare_annotations(verb: &str, store: &SqliteItemStore, root: &Path) -> Result<(), String> {
    let method = verb.strip_prefix("imbib-eink-service_eink-").unwrap_or("");
    if !matches!(
        method,
        "list-annotations" | "search-annotations" | "pending-ocr" | "complete-ocr" | "append-notes"
    ) {
        return Ok(());
    }
    for (number, schema, parent) in [
        (1, refs::IMBIB_BIBLIOGRAPHY_ENTRY, None),
        (2, refs::IMBIB_LINKED_FILE, Some(annotation_id(1))),
        (3, refs::IMBIB_ANNOTATION, Some(annotation_id(2))),
    ] {
        if store
            .get(annotation_id(number))
            .map_err(|e| e.to_string())?
            .is_some()
        {
            store
                .delete(annotation_id(number))
                .map_err(|e| e.to_string())?;
        }
        let mut item = super::seed_item(annotation_id(number), schema.as_str(), parent);
        item.payload
            .insert("title".into(), ItemValue::String("G3 tablet paper".into()));
        if number == 3 {
            let ink = matches!(method, "pending-ocr" | "complete-ocr");
            item.payload
                .insert("source".into(), ItemValue::String("remarkable".into()));
            item.payload.insert(
                "annotation_type".into(),
                ItemValue::String(if ink { "ink" } else { "highlight" }.into()),
            );
            item.payload.insert("page_number".into(), ItemValue::Int(1));
            item.payload.insert(
                "selected_text".into(),
                ItemValue::String("G3 tablet highlight".into()),
            );
            item.payload.insert(
                "source_remote_id".into(),
                ItemValue::String("g3-owned-notebook".into()),
            );
            item.payload
                .insert("imported_at_ms".into(), ItemValue::Int(1000));
            let path = root.join("search-devices/ink.png");
            std::fs::write(&path, include_bytes!("g3-ink.png")).map_err(|e| e.to_string())?;
            item.payload.insert(
                "image_path".into(),
                ItemValue::String(path.to_string_lossy().into_owned()),
            );
        }
        store.insert(item).map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn verify_annotations(verb: &str, store: &SqliteItemStore, result: &Value) -> Result<(), String> {
    match verb.strip_prefix("imbib-eink-service_eink-").unwrap_or("") {
        "complete-ocr" => {
            let row = store
                .get(annotation_id(3))
                .map_err(|e| e.to_string())?
                .ok_or("ink missing")?;
            if row.payload.get("contents")
                != Some(&ItemValue::String("Recognized owned ink".into()))
                || row.payload.get("ocr_confidence") != Some(&ItemValue::Float(0.95))
            {
                return Err("OCR text/confidence not saved".into());
            }
        }
        "append-notes" => {
            let row = store
                .get(annotation_id(1))
                .map_err(|e| e.to_string())?
                .ok_or("paper missing")?;
            if !matches!(row.payload.get("note"), Some(ItemValue::String(note)) if note.contains("G3 tablet highlight"))
            {
                return Err("tablet note not appended".into());
            }
        }
        "note-source-error" => {
            let row = store
                .get(id("07")?)
                .map_err(|e| e.to_string())?
                .ok_or("mirror missing")?;
            if result["ok"] != true
                || !format!("{:?}", row.payload).contains("Owned source is offline")
            {
                return Err("source error not retained".into());
            }
        }
        _ => {}
    }
    Ok(())
}
