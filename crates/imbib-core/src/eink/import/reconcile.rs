//! Write drafts into `imbib/annotation` rows on the primary file, updating
//! what exists, inserting what is new, deleting what the tablet no longer
//! has — keyed by the stable ids, so a re-import never duplicates.

use std::collections::HashMap;
use std::path::Path;

use chrono::Utc;
use impress_core::item::Value;
use impress_core::store::{FieldMutation, ItemStore};
use uuid::Uuid;

use super::convert::AnnotationDraft;
use crate::unified::conversion::{annotation_to_item_with_provenance, AnnotationProvenance};
use crate::unified::store_api::{parse_uuid, ImbibStore, StoreApiError};

pub const SOURCE_REMARKABLE: &str = "remarkable";
pub const AUTHOR_REMARKABLE: &str = "reMarkable";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReconcileOutcome {
    pub created: u32,
    pub updated: u32,
    pub deleted: u32,
    pub ink_pending_ocr: u32,
    pub highlights: u32,
    pub typed: u32,
    pub ink_groups: u32,
}

/// Where a draft's PNG goes, relative to the library folder.
pub fn image_relative_path(remote_id: &str, draft: &AnnotationDraft) -> String {
    format!(
        "EInk/{remote_id}/{}-{}.png",
        draft.source_page_id,
        draft.source_item_id.replace(':', "_")
    )
}

fn set(key: &str, value: Option<Value>) -> FieldMutation {
    match value {
        Some(value) => FieldMutation::SetPayload(key.into(), value),
        None => FieldMutation::RemovePayload(key.into()),
    }
}

fn opt_str(value: &Option<String>) -> Option<Value> {
    value.as_ref().map(|s| Value::String(s.clone()))
}

/// Reconcile one document's drafts against the rows it wrote before.
#[allow(clippy::too_many_arguments)]
pub fn reconcile(
    store: &ImbibStore,
    primary_file_id: &str,
    device_id: &str,
    remote_id: &str,
    library_dir: &Path,
    drafts: Vec<AnnotationDraft>,
) -> Result<ReconcileOutcome, StoreApiError> {
    let file_uuid = parse_uuid(primary_file_id)?;
    let now = Utc::now().timestamp_millis();
    let mut outcome = ReconcileOutcome::default();

    let existing: HashMap<Uuid, crate::unified::shaped_queries::AnnotationRow> = store
        .list_annotations(primary_file_id.to_string(), None)?
        .into_iter()
        .filter(|row| {
            row.source.as_deref() == Some(SOURCE_REMARKABLE)
                && row.source_remote_id.as_deref() == Some(remote_id)
        })
        .filter_map(|row| Uuid::parse_str(&row.id).ok().map(|id| (id, row)))
        .collect();

    let mut seen: Vec<Uuid> = Vec::with_capacity(drafts.len());
    for draft in drafts {
        seen.push(draft.id);
        match draft.annotation_type {
            "highlight" => outcome.highlights += 1,
            "note" => outcome.typed += 1,
            "ink" => outcome.ink_groups += 1,
            _ => {}
        }
        let image_path = match &draft.png {
            Some(png) => {
                let relative = image_relative_path(remote_id, &draft);
                let absolute = library_dir.join(&relative);
                if let Some(parent) = absolute.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| StoreApiError::Storage(e.to_string()))?;
                }
                std::fs::write(&absolute, png)
                    .map_err(|e| StoreApiError::Storage(e.to_string()))?;
                Some(super::super::paths::relative_or_absolute(
                    library_dir,
                    &absolute,
                ))
            }
            None => None,
        };
        let bounds_json = draft.bounds.map(|b| b.to_json());

        match existing.get(&draft.id) {
            Some(row) => {
                let mut mutations = vec![
                    set("bounds_json", bounds_json.map(Value::String)),
                    set("color", opt_str(&draft.color)),
                    set("selected_text", opt_str(&draft.selected_text)),
                    set("imported_at_ms", Some(Value::Int(now))),
                    set("image_path", opt_str(&image_path)),
                    set("pen", opt_str(&draft.pen)),
                    set("page_number", Some(Value::Int(draft.page_number))),
                ];
                let strokes_changed =
                    draft.strokes_hash.is_some() && draft.strokes_hash != row.strokes_hash;
                if draft.contents.is_some() {
                    mutations.push(set("contents", opt_str(&draft.contents)));
                } else if strokes_changed {
                    // The handwriting changed: the old OCR text is stale.
                    mutations.push(set("contents", None));
                    mutations.push(set("ocr_confidence", None));
                }
                mutations.push(set("strokes_hash", opt_str(&draft.strokes_hash)));
                store.store.update(draft.id, mutations)?;
                outcome.updated += 1;
                if draft.annotation_type == "ink"
                    && image_path.is_some()
                    && (strokes_changed || row.ocr_confidence.is_none())
                {
                    outcome.ink_pending_ocr += 1;
                }
            }
            None => {
                let provenance = AnnotationProvenance {
                    source: Some(SOURCE_REMARKABLE.into()),
                    source_device_id: Some(device_id.into()),
                    source_remote_id: Some(remote_id.into()),
                    source_page_id: Some(draft.source_page_id.clone()),
                    source_item_id: Some(draft.source_item_id.clone()),
                    image_path: image_path.clone(),
                    pen: draft.pen.clone(),
                    strokes_hash: draft.strokes_hash.clone(),
                    ocr_confidence: None,
                    imported_at_ms: Some(now),
                };
                let item = annotation_to_item_with_provenance(
                    draft.id,
                    file_uuid,
                    draft.annotation_type,
                    draft.page_number,
                    bounds_json.as_deref(),
                    draft.color.as_deref(),
                    draft.contents.as_deref(),
                    draft.selected_text.as_deref(),
                    Some(AUTHOR_REMARKABLE),
                    &provenance,
                );
                store.store.insert(item)?;
                outcome.created += 1;
                if draft.annotation_type == "ink" && image_path.is_some() {
                    outcome.ink_pending_ocr += 1;
                }
            }
        }
    }

    for (id, row) in existing {
        if seen.contains(&id) {
            continue;
        }
        if let Some(relative) = &row.image_path {
            let _ = std::fs::remove_file(library_dir.join(relative));
        }
        store.store.delete(id)?;
        outcome.deleted += 1;
    }
    Ok(outcome)
}
