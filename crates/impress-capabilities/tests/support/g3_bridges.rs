//! Isolated shared-store and imprint-section fixtures for bridge examples.
//!
//! The external Tier B examples deliberately do not execute in this module;
//! their app-owned records must be supplied by an isolated native host.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use imprint_service::{SectionMetadata, SectionStore};
use serde_json::Value;

const PREFIX: &str = "5f000000-0000-4000-8000-0000000000";
const CITE_KEY: &str = "G3Bridge2026";
const BODY: &str = "The method uses spectra.";

fn id(suffix: &str) -> Result<ItemId, String> {
    format!("{PREFIX}{suffix}")
        .parse()
        .map_err(|error| format!("bridge fixture id: {error}"))
}

fn item(id: ItemId, schema: impress_core::SchemaRef, parent: Option<ItemId>) -> Item {
    let now = SystemTime::now().into();
    Item {
        id,
        schema,
        payload: BTreeMap::new(),
        created: now,
        modified: now,
        author: "system:g3-bridge-fixture".into(),
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
        parent,
    }
}

fn insert_once(store: &SqliteItemStore, row: Item) -> Result<(), String> {
    if store
        .get(row.id)
        .map_err(|error| error.to_string())?
        .is_none()
    {
        store.insert(row).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn seed_citation(store: &SqliteItemStore, root: &Path) -> Result<(), String> {
    let library_id = id("01")?;
    let mut library = item(library_id, refs::IMBIB_LIBRARY, None);
    library
        .payload
        .insert("name".into(), ItemValue::String("G3 bridge library".into()));
    library
        .payload
        .insert("is_default".into(), ItemValue::Bool(false));
    library
        .payload
        .insert("is_inbox".into(), ItemValue::Bool(false));
    library
        .payload
        .insert("is_system".into(), ItemValue::Bool(false));
    insert_once(store, library)?;

    let mut paper = item(id("02")?, refs::IMBIB_BIBLIOGRAPHY_ENTRY, Some(library_id));
    paper
        .payload
        .insert("cite_key".into(), ItemValue::String(CITE_KEY.into()));
    paper
        .payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    paper.payload.insert(
        "title".into(),
        ItemValue::String("G3 bridge methods".into()),
    );
    paper.payload.insert("year".into(), ItemValue::Int(2026));
    insert_once(store, paper)?;

    // The default imprint manuscript service opens this exact owned workspace.
    // Seed through its real SectionStore API so section IDs and payloads match.
    let sections = SectionStore::open(root.join("imprint")).map_err(|error| error.to_string())?;
    sections
        .put_section(
            id("10")?,
            "methods",
            BODY,
            SectionMetadata {
                title: Some("Methods".into()),
                section_type: Some("methods".into()),
                order_index: Some(0),
            },
        )
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn seed_artifacts(store: &SqliteItemStore) -> Result<(), String> {
    let mut source = item(id("20")?, refs::IMPRESS_ARTIFACT_GENERAL, None);
    source.payload.insert(
        "title".into(),
        ItemValue::String("G3-bridge-needle source".into()),
    );
    source.references.push(TypedReference {
        target: id("21")?,
        edge_type: EdgeType::RelatesTo,
        metadata: None,
    });
    let mut note = item(id("21")?, refs::IMPRESS_ARTIFACT_GENERAL, None);
    note.payload
        .insert("title".into(), ItemValue::String("G3 related note".into()));
    // Insert the target first so both endpoints exist when the edge is indexed.
    insert_once(store, note)?;
    insert_once(store, source)?;
    Ok(())
}

/// Prepare only the fixture needed by this headless example before effects
/// observation starts. Repeated calls are safe; citation prep restores its
/// nonempty section body before the mutation example.
pub async fn prepare(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    match verb {
        "impress-bridges-service_cite-in-section" => seed_citation(store, root)?,
        "impress-bridges-service_get-item"
        | "impress-bridges-service_get-related"
        | "impress-bridges-service_search-all"
        | "impress-bridges-service_resolve-artifact" => seed_artifacts(store)?,
        _ => {}
    }
    Ok(())
}

/// Assert the bridge actually read or changed the seeded records. Called
/// outside the spy window so verification queries are not credited to verbs.
pub fn verify(
    verb: &str,
    _example: &str,
    _store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
    root: &Path,
) -> Result<(), String> {
    match verb {
        "impress-bridges-service_cite-in-section" => {
            if result["ok"].as_bool() != Some(true) {
                return Err(format!("citation did not succeed: {result}"));
            }
            let sections = SectionStore::open(root.join("imprint")).map_err(|e| e.to_string())?;
            let section = sections
                .get_section(id("10")?, "methods")
                .map_err(|e| e.to_string())?
                .ok_or("methods section missing")?;
            if section.body != format!("{BODY} @{CITE_KEY}") {
                return Err(format!(
                    "citation not persisted in section: {}",
                    section.body
                ));
            }
        }
        "impress-bridges-service_search-all" | "impress-bridges-service_get-related" => {
            let wanted = if verb.ends_with("search-all") {
                id("20")?
            } else {
                id("21")?
            };
            if !result.as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|row| row["id"].as_str() == Some(wanted.to_string().as_str()))
            }) {
                return Err(format!("{verb} omitted scratch item {wanted}"));
            }
        }
        "impress-bridges-service_get-item" | "impress-bridges-service_resolve-artifact" => {
            if result["id"].as_str() != Some(id("20")?.to_string().as_str()) {
                return Err(format!("{verb} did not resolve the scratch artifact"));
            }
        }
        "impress-bridges-service_extract-papers-from-text" => {
            if result.as_array().is_none_or(|rows| rows.len() != 2) {
                return Err("text extraction did not identify both papers".into());
            }
        }
        _ => {}
    }
    Ok(())
}
