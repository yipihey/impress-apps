//! Isolated prerequisites for collection and document G3 examples.

use std::path::Path;
use std::sync::Arc;

use impress_core::collection_migration;
use impress_core::collection_ops::{self, GENERIC_COLLECTION, MANUSCRIPT_COLLECTION};
use impress_core::item::Item;
use impress_core::schema::refs;
use impress_core::schemas::watched_folder::{WATCHED_FILE_SCHEMA, WATCHED_FOLDER_SCHEMA};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_core::watched_folder_ops::{watched_file_id, watched_folder_id};
use impress_store_service::docs_import_service::document_id;
use serde_json::{json, Value};

const PREFIX: &str = "59000000-0000-4000-8000-0000000000";

fn id(suffix: &str) -> String {
    format!("{PREFIX}{suffix}")
}

pub async fn prepare(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    let watch = root.join("documents/watch");
    let import = root.join("documents/import");
    match (verb, example) {
        ("collection-service_tree", "figure-folder") => {
            collection(store, "01", "G3 figures", refs::FIGURE_COLLECTION, None)?;
        }
        ("collection-service_rename", "rename-folder") => {
            collection(store, "02", "G3 notes", refs::COLLECTION, None)?;
        }
        ("collection-service_reparent", "nest-folder") => {
            collection(store, "04", "G3 parent", refs::COLLECTION, None)?;
            collection(store, "03", "G3 child", refs::COLLECTION, None)?;
        }
        ("collection-service_reorder", "position-folder") => {
            collection(store, "05", "G3 position", refs::COLLECTION, None)?;
        }
        ("collection-service_delete", "delete-empty-folder") => {
            collection(store, "06", "G3 disposable", refs::COLLECTION, None)?;
        }
        ("collection-service_add-members", "file-manuscript") => {
            collection(store, "07", "G3 file target", refs::COLLECTION, None)?;
            manuscript(store, "20", "G3 manuscript", "Content.")?;
        }
        ("collection-service_remove-members", "unfile-manuscript") => {
            collection(store, "08", "G3 remove target", refs::COLLECTION, None)?;
            manuscript(store, "21", "G3 manuscript", "Content.")?;
            file_member(store, "08", "21")?;
        }
        ("collection-service_member-counts", "one-member") => {
            collection(store, "09", "G3 counted target", refs::COLLECTION, None)?;
            manuscript(store, "22", "G3 manuscript", "Content.")?;
            file_member(store, "09", "22")?;
        }
        ("collection-service_migrate", "preview-convergence") => {
            collection(
                store,
                "10",
                "G3 legacy folder",
                refs::MANUSCRIPT_COLLECTION,
                None,
            )?;
        }
        ("collection-service_rollback", "restore-legacy-folders") => {
            collection(
                store,
                "11",
                "G3 migrated folder",
                refs::MANUSCRIPT_COLLECTION,
                None,
            )?;
            collection_migration::migrate_collections(store, false).map_err(|e| e.to_string())?;
        }
        ("docs-import-service_import-directory", "import-one-markdown") => {
            reset_uuid(store, document_id("G3 imported notes", "note.md"))?;
            std::fs::create_dir_all(&import).map_err(|e| e.to_string())?;
            std::fs::write(
                import.join("note.md"),
                "# G3 imported note\n\nA real imported body.\n",
            )
            .map_err(|e| e.to_string())?;
        }
        ("docs-import-service_prune-empty-manuscripts", "preview-empty-shell") => {
            collection(
                store,
                "41",
                "G3 empty shells",
                refs::MANUSCRIPT_COLLECTION,
                None,
            )?;
            manuscript(store, "40", "G3 placeholder", "")?;
            let member = id("40");
            collection_ops::add_members(store, &MANUSCRIPT_COLLECTION, &id("41"), &[member])
                .map_err(|e| e.to_string())?;
        }
        ("docs-import-service_add-watched-folder", "watch-manuscripts") => {
            std::fs::create_dir_all(&watch).map_err(|e| e.to_string())?;
            reset_uuid(
                store,
                watched_folder_id(&watch.to_string_lossy(), "manuscript"),
            )?;
        }
        ("docs-import-service_list-watched-folders", "figure-watch") => {
            folder(store, "30", &watch, "figure", "G3 figure watch")?;
        }
        ("docs-import-service_update-watched-folder", "pause-watch") => {
            folder(store, "31", &watch, "manuscript", "G3 pause watch")?;
        }
        ("docs-import-service_remove-watched-folder", "unwatch-folder") => {
            folder(store, "32", &watch, "manuscript", "G3 unwatch")?;
        }
        ("docs-import-service_import-discovered", "discover-markdown") => {
            std::fs::create_dir_all(&watch).map_err(|e| e.to_string())?;
            std::fs::write(watch.join("new.md"), "# G3 discovered\n\nContent.\n")
                .map_err(|e| e.to_string())?;
            folder(store, "33", &watch, "manuscript", "G3 discovery")?;
            reset_uuid(
                store,
                watched_file_id(&id("33"), &watch.join("new.md").to_string_lossy()),
            )?;
        }
        ("docs-import-service_finish-watched-scan", "mark-vanished-file") => {
            std::fs::create_dir_all(&watch).map_err(|e| e.to_string())?;
            let vanished = watch.join("vanished.bib");
            if vanished.exists() {
                std::fs::remove_file(&vanished).map_err(|e| e.to_string())?;
            }
            folder(store, "34", &watch, "publication", "G3 scan")?;
            watched_file(store, "35", "34", &vanished, "publication")?;
        }
        ("docs-import-service_record-produced-rows", "attribute-produced-row") => {
            folder(store, "37", &watch, "manuscript", "G3 attribution")?;
            watched_file(store, "36", "37", &watch.join("produced.md"), "manuscript")?;
            manuscript(store, "38", "G3 produced row", "Content.")?;
        }
        ("docs-import-service_list-watched-files", "one-watched-file") => {
            folder(store, "39", &watch, "manuscript", "G3 list")?;
            watched_file(store, "3a", "39", &watch.join("listed.md"), "manuscript")?;
        }
        _ => {}
    }
    Ok(())
}

fn collection(
    store: &SqliteItemStore,
    suffix: &str,
    name: &str,
    schema: impress_core::SchemaRef,
    parent: Option<&str>,
) -> Result<(), String> {
    let mut payload = json!({"name": name, "sort_order": 0});
    if schema == refs::COLLECTION {
        payload["kind_scope"] = json!("any");
    }
    put(store, &id(suffix), schema, payload, parent)
}

fn manuscript(
    store: &SqliteItemStore,
    suffix: &str,
    title: &str,
    body: &str,
) -> Result<(), String> {
    put(
        store,
        &id(suffix),
        refs::MANUSCRIPT,
        json!({"title":title,"body_content":body,"format":"markdown"}),
        None,
    )
}

fn folder(
    store: &SqliteItemStore,
    suffix: &str,
    path: &Path,
    kind: &str,
    name: &str,
) -> Result<(), String> {
    put(
        store,
        &id(suffix),
        WATCHED_FOLDER_SCHEMA,
        json!({"path":path.to_string_lossy(),"kind_scope":kind,"display_name":name,
            "enabled":true,"recursive":false}),
        None,
    )
}

fn watched_file(
    store: &SqliteItemStore,
    suffix: &str,
    folder_suffix: &str,
    path: &Path,
    kind: &str,
) -> Result<(), String> {
    put(
        store,
        &id(suffix),
        WATCHED_FILE_SCHEMA,
        json!({"watched_folder_id":id(folder_suffix),"path":path.to_string_lossy(),
            "content_hash":"g3-fixture","state":"present","kind_scope":kind,
            "size_bytes":0,"first_seen_at":"2026-09-28T00:00:00Z",
            "last_seen_at":"2026-09-28T00:00:00Z"}),
        Some(&id(folder_suffix)),
    )
}

fn put(
    store: &SqliteItemStore,
    item_id: &str,
    schema: impress_core::SchemaRef,
    payload: Value,
    parent: Option<&str>,
) -> Result<(), String> {
    let uuid = item_id
        .parse()
        .map_err(|e| format!("fixture UUID {item_id}: {e}"))?;
    reset_uuid(store, uuid)?;
    let item: Item = serde_json::from_value(json!({
        "id":item_id,"schema":schema,"payload":payload,
        "created":"2026-09-28T00:00:00Z","modified":"2026-09-28T00:00:00Z",
        "author":"g3-documents-fixture","author_kind":"System","logical_clock":0,
        "origin":null,"canonical_id":null,"tags":[],"flag":null,
        "is_read":false,"is_starred":false,"priority":"normal","visibility":"private",
        "message_type":null,"produced_by":null,"version":"1.0.0",
        "batch_id":null,"references":[],"parent":parent
    }))
    .map_err(|e| format!("fixture item {item_id}: {e}"))?;
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn reset_uuid(store: &SqliteItemStore, uuid: impress_core::item::ItemId) -> Result<(), String> {
    if store.get(uuid).map_err(|e| e.to_string())?.is_some() {
        store.delete(uuid).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn file_member(
    store: &SqliteItemStore,
    collection_suffix: &str,
    item_suffix: &str,
) -> Result<(), String> {
    collection_ops::add_members(
        store,
        &GENERIC_COLLECTION,
        &id(collection_suffix),
        &[id(item_suffix)],
    )
    .map_err(|e| e.to_string())?;
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
        ("collection-service_delete", "delete-empty-folder")
        | ("docs-import-service_remove-watched-folder", "unwatch-folder") => {
            let suffix = if verb.starts_with("collection-") {
                "06"
            } else {
                "32"
            };
            if load(store, &id(suffix))?.is_some() {
                return Err(format!("{} was not deleted", id(suffix)));
            }
        }
        ("collection-service_add-members", "file-manuscript") => {
            let counts = collection_ops::member_counts(store, &GENERIC_COLLECTION, &[id("07")])
                .map_err(|e| e.to_string())?;
            if counts != [1] {
                return Err("member was not filed".into());
            }
        }
        ("collection-service_remove-members", "unfile-manuscript") => {
            let counts = collection_ops::member_counts(store, &GENERIC_COLLECTION, &[id("08")])
                .map_err(|e| e.to_string())?;
            if counts != [0] || load(store, &id("21"))?.is_none() {
                return Err("unfile did not preserve the manuscript".into());
            }
        }
        ("docs-import-service_import-directory", "import-one-markdown") => {
            let doc_id = result["documents"][0]["id"]
                .as_str()
                .ok_or("missing imported ID")?;
            let item = load(store, doc_id)?.ok_or("imported manuscript missing from store")?;
            if item.schema != refs::MANUSCRIPT {
                return Err("imported row is not a manuscript".into());
            }
        }
        ("docs-import-service_prune-empty-manuscripts", "preview-empty-shell") => {
            if load(store, &id("40"))?.is_none() {
                return Err("dry run deleted the shell".into());
            }
        }
        ("docs-import-service_finish-watched-scan", "mark-vanished-file") => {
            let file = load(store, &id("35"))?.ok_or("watched file missing")?;
            if file.payload.get("state")
                != Some(&impress_core::item::Value::String("missing".into()))
            {
                return Err("vanished file was not marked missing".into());
            }
        }
        _ => {}
    }
    Ok(())
}

fn load(store: &SqliteItemStore, item_id: &str) -> Result<Option<Item>, String> {
    let uuid = item_id
        .parse()
        .map_err(|e| format!("result UUID {item_id}: {e}"))?;
    store.get(uuid).map_err(|e| e.to_string())
}
