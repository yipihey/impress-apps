//! Scratch fixtures for the first alphabetical half of ImbibLibraryService.

use std::path::Path;
use std::sync::Arc;

use impress_core::collection_ops::{self, IMBIB_COLLECTION};
use impress_core::item::{FlagState, ItemId, Value as ItemValue};
use impress_core::query::ItemQuery;
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::Value;

const PREFIX: &str = "5c000000-0000-4000-8000-0000000000";

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
    root: &Path,
) -> Result<(), String> {
    match (verb, example) {
        ("imbib-library-service_count-publications", "count-scratch-paper") => {
            library(store, "52", "G3 count library", false, false)?;
            paper(store, "53", "52", "G3Count2026", "G3 counted paper", None)?;
        }
        ("imbib-library-service_count-unread", "count-unread-in-library") => {
            library(store, "50", "G3 unread library", false, false)?;
            paper_with_status(store, "54", "50", false, false, None)?;
            paper_with_status(store, "55", "50", true, false, None)?;
        }
        ("imbib-library-service_count-starred", "count-starred-in-library") => {
            library(store, "51", "G3 starred library", false, false)?;
            paper_with_status(store, "56", "51", false, true, None)?;
            paper_with_status(store, "57", "51", false, false, None)?;
        }
        ("imbib-library-service_count-flagged", "count-blue-flags") => {
            library(store, "58", "G3 flagged library", false, false)?;
            paper_with_status(store, "59", "58", false, false, Some("g3-blue"))?;
            paper_with_status(store, "5a", "58", false, false, Some("red"))?;
        }
        ("imbib-library-service_create-library", "new-project-library") => {
            reset_matching(
                store,
                refs::IMBIB_LIBRARY,
                "name",
                "G3 reading project",
                None,
            )?;
        }
        ("imbib-library-service_delete-library-undoable", "remove-empty-library") => {
            library(store, "0a", "G3 disposable library", false, false)?;
        }
        ("imbib-library-service_get-default-library", "project-default") => {
            library(store, "0b", "G3 default library", true, false)?;
        }
        ("imbib-library-service_get-inbox-library", "inbox-library") => {
            library(store, "0c", "G3 Inbox", false, true)?;
        }
        ("imbib-library-service_create-collection", "manual-collection") => {
            reset_matching(store, refs::IMBIB_COLLECTION, "name", "G3 methods", None)?;
            library(store, "10", "G3 collection library", false, false)?;
        }
        ("imbib-library-service_add-to-collection", "file-paper") => {
            library(store, "0d", "G3 filing library", false, false)?;
            collection(store, "11", "G3 papers", "0d")?;
            paper(store, "12", "0d", "G3File2026", "G3 filed paper", None)?;
        }
        ("imbib-library-service_get-publication", "paper-summary") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(
                store,
                "20",
                "1f",
                "G3Spectra2026",
                "G3 stellar spectra",
                None,
            )?;
        }
        ("imbib-library-service_get-publication-detail", "paper-metadata") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(store, "21", "1f", "G3Detail2026", "G3 paper detail", None)?;
        }
        ("imbib-library-service_delete-publications-undoable", "delete-scratch-paper") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(
                store,
                "22",
                "1f",
                "G3Delete2026",
                "G3 disposable paper",
                None,
            )?;
        }
        ("imbib-library-service_duplicate-publications", "copy-paper-to-project") => {
            reset_matching(
                store,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                "cite_key",
                "G3Copy2026",
                Some(uuid("24")?),
            )?;
            library(store, "26", "G3 source library", false, false)?;
            library(store, "24", "G3 destination library", false, false)?;
            paper(store, "23", "26", "G3Copy2026", "G3 paper to copy", None)?;
        }
        ("imbib-library-service_deduplicate-library", "merge-same-doi") => {
            library(store, "25", "G3 dedup library", false, false)?;
            paper(
                store,
                "27",
                "25",
                "G3DuplicateA",
                "G3 first paper",
                Some("10.5555/g3-same"),
            )?;
            paper(
                store,
                "28",
                "25",
                "G3DuplicateB",
                "G3 second paper",
                Some("10.5555/g3-same"),
            )?;
        }
        ("imbib-library-service_dismiss-paper", "dismiss-known-doi") => {
            reset_matching(
                store,
                refs::IMBIB_DISMISSED_PAPER,
                "doi",
                "10.5555/g3-dismiss",
                None,
            )?;
        }
        ("imbib-library-service_create-muted-item", "mute-keyword") => {
            reset_matching(
                store,
                refs::IMBIB_MUTED_ITEM,
                "value",
                "G3 irrelevant topic",
                None,
            )?;
        }
        ("imbib-library-service_import-bibtex", "import-one-entry") => {
            reset_matching(
                store,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                "cite_key",
                "G3Imported2026",
                None,
            )?;
            library(store, "30", "G3 BibTeX library", false, false)?;
        }
        ("imbib-library-service_export-bibtex", "export-cite-key") => {
            library(store, "31", "G3 export library", false, false)?;
            paper(store, "33", "31", "G3Export2026", "G3 exported paper", None)?;
        }
        ("imbib-library-service_export-all-bibtex", "export-project-library") => {
            library(store, "31", "G3 export library", false, false)?;
            paper(
                store,
                "32",
                "31",
                "G3AllExport2026",
                "G3 all-export paper",
                None,
            )?;
        }
        ("imbib-library-service_count-pdfs", "one-pdf") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(store, "40", "1f", "G3Pdf2026", "G3 PDF paper", None)?;
            linked_file(store, "42", "40", "counted.pdf", true)?;
        }
        ("imbib-library-service_add-linked-file", "link-local-pdf") => {
            reset_matching(
                store,
                refs::IMBIB_LINKED_FILE,
                "filename",
                "paper.pdf",
                Some(uuid("41")?),
            )?;
            library(store, "1f", "G3 paper library", false, false)?;
            paper(store, "41", "1f", "G3Link2026", "G3 linked paper", None)?;
            let dir = root.join("library");
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            std::fs::write(dir.join("paper.pdf"), b"%PDF-1.4\nG3test")
                .map_err(|e| e.to_string())?;
        }
        _ => {}
    }
    Ok(())
}

fn reset(store: &SqliteItemStore, item_id: ItemId) -> Result<(), String> {
    if store.get(item_id).map_err(|e| e.to_string())?.is_some() {
        store.delete(item_id).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn reset_matching(
    store: &SqliteItemStore,
    schema: impress_core::SchemaRef,
    field: &str,
    value: &str,
    parent: Option<ItemId>,
) -> Result<(), String> {
    let rows = store
        .query(&ItemQuery {
            schema: Some(schema),
            ..Default::default()
        })
        .map_err(|e| e.to_string())?;
    for row in rows {
        if row.payload.get(field) == Some(&ItemValue::String(value.into()))
            && parent.is_none_or(|id| row.parent == Some(id))
        {
            store.delete(row.id).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn library(
    store: &SqliteItemStore,
    suffix: &str,
    name: &str,
    default: bool,
    inbox: bool,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(item_id, refs::IMBIB_LIBRARY.as_str(), None);
    item.payload
        .insert("name".into(), ItemValue::String(name.into()));
    item.payload
        .insert("is_default".into(), ItemValue::Bool(default));
    item.payload
        .insert("is_inbox".into(), ItemValue::Bool(inbox));
    item.payload
        .insert("is_system".into(), ItemValue::Bool(false));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn collection(
    store: &SqliteItemStore,
    suffix: &str,
    name: &str,
    library_suffix: &str,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_COLLECTION.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload
        .insert("name".into(), ItemValue::String(name.into()));
    item.payload
        .insert("is_smart".into(), ItemValue::Bool(false));
    item.payload.insert("sort_order".into(), ItemValue::Int(0));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn paper(
    store: &SqliteItemStore,
    suffix: &str,
    library_suffix: &str,
    cite_key: &str,
    title: &str,
    doi: Option<&str>,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_BIBLIOGRAPHY_ENTRY.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload
        .insert("cite_key".into(), ItemValue::String(cite_key.into()));
    item.payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    item.payload
        .insert("title".into(), ItemValue::String(title.into()));
    item.payload.insert("year".into(), ItemValue::Int(2026));
    if let Some(doi) = doi {
        item.payload
            .insert("doi".into(), ItemValue::String(doi.into()));
    }
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn paper_with_status(
    store: &SqliteItemStore,
    suffix: &str,
    library_suffix: &str,
    read: bool,
    starred: bool,
    flag: Option<&str>,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_BIBLIOGRAPHY_ENTRY.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload.insert(
        "cite_key".into(),
        ItemValue::String(format!("G3Status{suffix}2026")),
    );
    item.payload.insert(
        "title".into(),
        ItemValue::String(format!("G3 status paper {suffix}")),
    );
    item.payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    item.is_read = read;
    item.is_starred = starred;
    item.flag = flag.map(|color| FlagState {
        color: color.into(),
        style: None,
        length: None,
    });
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn linked_file(
    store: &SqliteItemStore,
    suffix: &str,
    paper_suffix: &str,
    filename: &str,
    pdf: bool,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_LINKED_FILE.as_str(),
        Some(uuid(paper_suffix)?),
    );
    item.payload
        .insert("filename".into(), ItemValue::String(filename.into()));
    item.payload.insert("is_pdf".into(), ItemValue::Bool(pdf));
    item.payload.insert("file_size".into(), ItemValue::Int(15));
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
        ("imbib-library-service_count-publications", "count-scratch-paper") => {
            let count = store
                .count(&ItemQuery {
                    schema: Some(refs::IMBIB_BIBLIOGRAPHY_ENTRY),
                    ..Default::default()
                })
                .map_err(|e| e.to_string())?;
            if count == 0
                || result.as_u64() != Some(count as u64)
                || load(store, &id("53"))?.is_none()
            {
                return Err("scratch paper was omitted from publication count".into());
            }
        }
        ("imbib-library-service_create-library", "new-project-library") => {
            let new_id = result["id"]
                .as_str()
                .ok_or("create-library returned no ID")?;
            let row = load(store, new_id)?.ok_or("new library not persisted")?;
            if row.schema != refs::IMBIB_LIBRARY {
                return Err("new row is not a library".into());
            }
        }
        ("imbib-library-service_delete-library-undoable", "remove-empty-library") => {
            if load(store, &id("0a"))?.is_some() {
                return Err("library survived deletion".into());
            }
        }
        ("imbib-library-service_create-collection", "manual-collection") => {
            let new_id = result["id"]
                .as_str()
                .ok_or("create-collection returned no ID")?;
            let row = load(store, new_id)?.ok_or("new collection not persisted")?;
            // The legacy response currently maps the collection tree parent to
            // `library_id`, so a root collection reports null. The owning
            // library is stored in the envelope parent and checked here.
            if row.schema != refs::IMBIB_COLLECTION || row.parent != Some(uuid("10")?) {
                return Err("collection was not filed in its library".into());
            }
        }
        ("imbib-library-service_add-to-collection", "file-paper") => {
            let members = collection_ops::list_members(store, &IMBIB_COLLECTION, &id("11"))
                .map_err(|e| e.to_string())?;
            if members.len() != 1 || members[0].id != uuid("12")? {
                return Err("paper was not filed into the collection".into());
            }
        }
        ("imbib-library-service_delete-publications-undoable", "delete-scratch-paper") => {
            if load(store, &id("22"))?.is_some() {
                return Err("paper survived deletion".into());
            }
        }
        ("imbib-library-service_duplicate-publications", "copy-paper-to-project") => {
            let copies = result.as_array().ok_or("copy result was not an array")?;
            if copies.len() != 1 {
                return Err("expected one copied paper".into());
            }
            let copy_id = copies[0].as_str().ok_or("copy ID was not a string")?;
            let copy = load(store, copy_id)?.ok_or("copy was not persisted")?;
            if copy.parent != Some(uuid("24")?) || load(store, &id("23"))?.is_none() {
                return Err("copy was not in destination or source vanished".into());
            }
        }
        ("imbib-library-service_deduplicate-library", "merge-same-doi") => {
            let surviving = usize::from(load(store, &id("27"))?.is_some())
                + usize::from(load(store, &id("28"))?.is_some());
            if surviving != 1 {
                return Err("deduplication did not leave exactly one paper".into());
            }
        }
        ("imbib-library-service_import-bibtex", "import-one-entry") => {
            let ids = result.as_array().ok_or("import result was not an array")?;
            if ids.len() != 1 {
                return Err("BibTeX import did not create one paper".into());
            }
            let imported = load(store, ids[0].as_str().ok_or("import ID was not text")?)?
                .ok_or("imported paper not persisted")?;
            if imported.parent != Some(uuid("30")?)
                || imported.schema != refs::IMBIB_BIBLIOGRAPHY_ENTRY
            {
                return Err("BibTeX paper was not saved in the target library".into());
            }
        }
        ("imbib-library-service_export-bibtex", "export-cite-key") => {
            if !result.as_str().unwrap_or("").contains("G3Export2026") {
                return Err("export omitted the requested cite key".into());
            }
        }
        ("imbib-library-service_export-all-bibtex", "export-project-library") => {
            if !result.as_str().unwrap_or("").contains("G3AllExport2026") {
                return Err("export omitted the library's paper".into());
            }
        }
        ("imbib-library-service_add-linked-file", "link-local-pdf") => {
            let file_id = result["id"].as_str().ok_or("linked file ID missing")?;
            let file = load(store, file_id)?.ok_or("linked file not persisted")?;
            if file.schema != refs::IMBIB_LINKED_FILE || file.parent != Some(uuid("41")?) {
                return Err("file was not attached to the paper".into());
            }
        }
        _ => {}
    }
    Ok(())
}

fn load(
    store: &SqliteItemStore,
    item_id: &str,
) -> Result<Option<impress_core::item::Item>, String> {
    let item_id = ItemId::parse_str(item_id).map_err(|e| e.to_string())?;
    store.get(item_id).map_err(|e| e.to_string())
}
