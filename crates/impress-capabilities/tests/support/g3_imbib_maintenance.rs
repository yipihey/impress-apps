//! Owned backup and undo fixtures for Imbib maintenance examples.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::item::{ItemId, Value as ItemValue};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::ItemQuery;
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::Value;

const PREFIX: &str = "61000000-0000-4000-8000-0000000000";

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
        ("imbib-backup-service_create-backup", "snapshot-scratch-library") => {
            empty_dir(&root.join("maintenance/create"))?;
        }
        ("imbib-backup-service_list-backups", "list-scratch-backups") => {
            snapshot(store, root, "list", "seed.impressbackup")?;
        }
        ("imbib-backup-service_inspect-backup", "inspect-scratch-backup") => {
            snapshot(store, root, "inspect", "check.impressbackup")?;
        }
        ("imbib-backup-service_delete-backup", "delete-scratch-backup") => {
            snapshot(store, root, "delete", "remove.impressbackup")?;
        }
        ("imbib-backup-service_prune-backups", "prune-scratch-backups") => {
            let dir = root.join("maintenance/prune");
            empty_dir(&dir)?;
            for name in ["first.impressbackup", "second.impressbackup"] {
                store
                    .snapshot_to(&dir.join(name), "imbib", "G3 example", None)
                    .map_err(|e| e.to_string())?;
            }
        }
        ("imbib-undo-service_recent-undo-groups", "scratch-history") => {
            seed_operation(store, "06", "07")?;
        }
        ("imbib-undo-service_undo-operation", "selected-history-operation") => {
            seed_operation(store, "09", "08")?;
        }
        ("imbib-undo-service_undo-batch", "undo-scratch-batch") => {
            seed_operation(store, "04", "05")?;
        }
        _ => {}
    }
    Ok(())
}

/// Resolve only the operation-token used by this helper's undo example.
/// The seeded operation has a generated UUID, so a literal UUID would be a
/// fabricated missing-ID test rather than an executable undo example.
pub fn resolve_args(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    mut args: Value,
) -> Result<Value, String> {
    if (verb, example)
        != (
            "imbib-undo-service_undo-operation",
            "selected-history-operation",
        )
    {
        return Ok(args);
    }
    if args["operation_id"] != "{{fixture.undo_operation_id}}" {
        return Err("undo example lost its fixture operation token".into());
    }
    let op = operation_for_batch(store, &id("08"), &id("09"))?
        .ok_or("seeded undo operation was not found")?;
    args["operation_id"] = Value::String(op.id.to_string());
    Ok(args)
}

pub fn verify(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    match (verb, example) {
        ("imbib-backup-service_create-backup", "snapshot-scratch-library") => {
            let rows = result.as_array().ok_or("backup result is not a list")?;
            if rows.len() != 1 || rows[0]["label"] != "G3 backup" {
                return Err("snapshot result omitted its label".into());
            }
            let path = rows[0]["path"].as_str().ok_or("snapshot path missing")?;
            let owned = Path::new(
                args["directory"]
                    .as_str()
                    .ok_or("backup directory missing")?,
            );
            if !Path::new(path).starts_with(&owned) || !Path::new(path).is_file() {
                return Err("snapshot was not written to the owned backup directory".into());
            }
        }
        ("imbib-backup-service_list-backups", "list-scratch-backups") => {
            require_backup(result, "seed.impressbackup")?;
        }
        ("imbib-backup-service_inspect-backup", "inspect-scratch-backup") => {
            if result["path"] != args["path"] || result["valid"] != true {
                return Err("owned backup did not pass inspection".into());
            }
        }
        ("imbib-backup-service_delete-backup", "delete-scratch-backup") => {
            if Path::new(args["path"].as_str().ok_or("delete path missing")?).exists() {
                return Err("owned backup survived deletion".into());
            }
        }
        ("imbib-backup-service_prune-backups", "prune-scratch-backups") => {
            let removed = result.as_array().ok_or("prune result is not a list")?;
            if removed.len() != 2
                || ["first.impressbackup", "second.impressbackup"]
                    .iter()
                    .any(|name| {
                        Path::new(args["directory"].as_str().unwrap_or(""))
                            .join(name)
                            .exists()
                    })
            {
                return Err("prune did not remove both owned snapshots".into());
            }
        }
        ("imbib-undo-service_recent-undo-groups", "scratch-history") => {
            let rows = result.as_array().ok_or("undo history is not a list")?;
            if !rows
                .iter()
                .any(|row| row["batch_id"] == id("07") && row["operation_count"] == 1)
            {
                return Err("seeded undo group was omitted from history".into());
            }
        }
        ("imbib-undo-service_undo-operation", "selected-history-operation") => {
            let target = operation_for_batch(store, &id("08"), &id("09"))?
                .ok_or("seeded undo operation vanished")?;
            if args["operation_id"] != target.id.to_string() || !restored_name(store, "09")? {
                return Err("selected scratch operation was not reversed".into());
            }
        }
        ("imbib-undo-service_undo-batch", "undo-scratch-batch") => {
            if !restored_name(store, "04")? {
                return Err("scratch batch did not restore its prior value".into());
            }
        }
        _ => {}
    }
    Ok(())
}

fn empty_dir(dir: &Path) -> Result<(), String> {
    if dir.exists() {
        std::fs::remove_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())
}

fn snapshot(
    store: &SqliteItemStore,
    root: &Path,
    folder: &str,
    name: &str,
) -> Result<PathBuf, String> {
    let dir = root.join("maintenance").join(folder);
    empty_dir(&dir)?;
    let path = dir.join(name);
    store
        .snapshot_to(&path, "imbib", "G3 example", None)
        .map_err(|e| e.to_string())?;
    Ok(path)
}

fn seed_operation(
    store: &SqliteItemStore,
    target_suffix: &str,
    batch_suffix: &str,
) -> Result<(), String> {
    let target = uuid(target_suffix)?;
    let batch = id(batch_suffix);
    for row in store
        .query(&ItemQuery {
            schema: Some(refs::CORE_OPERATION),
            ..Default::default()
        })
        .map_err(|e| e.to_string())?
    {
        if row.batch_id.as_deref() == Some(batch.as_str()) {
            store.delete(row.id).map_err(|e| e.to_string())?;
        }
    }
    if store.get(target).map_err(|e| e.to_string())?.is_some() {
        store.delete(target).map_err(|e| e.to_string())?;
    }
    let mut item = super::seed_item(target, refs::IMBIB_LIBRARY.as_str(), None);
    item.payload
        .insert("name".into(), ItemValue::String("Before G3 undo".into()));
    item.payload
        .insert("is_default".into(), ItemValue::Bool(false));
    item.payload
        .insert("is_inbox".into(), ItemValue::Bool(false));
    store.insert(item).map_err(|e| e.to_string())?;
    store
        .apply_operation(OperationSpec {
            target_id: target,
            op_type: OperationType::SetPayload(
                "name".into(),
                ItemValue::String("After G3 undo".into()),
            ),
            intent: OperationIntent::Routine,
            reason: Some("G3 example".into()),
            batch_id: Some(batch),
            author: "system:g3-fixture".into(),
            author_kind: impress_core::item::ActorKind::System,
            retention: RetentionTier::Durable,
        })
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn operation_for_batch(
    store: &SqliteItemStore,
    batch_id: &str,
    target_id: &str,
) -> Result<Option<impress_core::item::Item>, String> {
    let rows = store
        .query(&ItemQuery {
            schema: Some(refs::CORE_OPERATION),
            ..Default::default()
        })
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().find(|row| {
        row.batch_id.as_deref() == Some(batch_id)
            && row.payload.get("target_id") == Some(&ItemValue::String(target_id.into()))
    }))
}

fn restored_name(store: &SqliteItemStore, suffix: &str) -> Result<bool, String> {
    let row = store
        .get(uuid(suffix)?)
        .map_err(|e| e.to_string())?
        .ok_or("undo target disappeared")?;
    Ok(row.payload.get("name") == Some(&ItemValue::String("Before G3 undo".into())))
}

fn require_backup(result: &Value, filename: &str) -> Result<(), String> {
    let rows = result.as_array().ok_or("backup listing is not a list")?;
    if rows.iter().any(|row| row["filename"] == filename) {
        Ok(())
    } else {
        Err(format!("backup listing omitted {filename}"))
    }
}
