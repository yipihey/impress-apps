//! The tablet's rendition of a paper (handwriting drawn in) as a second
//! linked file on the publication, replaced in place on every import.

use std::path::{Path, PathBuf};

use impress_core::item::Value;
use impress_core::store::{FieldMutation, ItemStore};

use super::super::paths;
use crate::unified::conversion::linked_file_variant_to_item;
use crate::unified::store_api::{parse_uuid, ImbibStore, StoreApiError};

pub const ROLE_ANNOTATED: &str = "eink-annotated";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VariantOutcome {
    pub linked_file_id: String,
    pub sha256: String,
    pub relative_path: String,
    pub replaced: bool,
}

/// Where the variant lives: beside the primary file, under `Papers/`.
pub fn variant_filename(primary_filename: &str) -> String {
    let stem = primary_filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .filter(|s| !s.is_empty())
        .unwrap_or(primary_filename);
    format!("{stem} (reMarkable).pdf")
}

/// Copy the rendered PDF into the library and record (or refresh) the
/// `eink-annotated` linked file for `remote_id`.
#[allow(clippy::too_many_arguments)]
pub fn upsert_annotated_variant(
    store: &ImbibStore,
    publication_id: &str,
    library_dir: &Path,
    primary_filename: &str,
    rendered_pdf: &Path,
    device_id: &str,
    remote_id: &str,
    remote_modified_ms: i64,
) -> Result<VariantOutcome, StoreApiError> {
    let pub_uuid = parse_uuid(publication_id)?;
    let filename = variant_filename(primary_filename);
    let papers_dir = library_dir.join("Papers");
    std::fs::create_dir_all(&papers_dir).map_err(|e| StoreApiError::Storage(e.to_string()))?;
    let destination = papers_dir.join(&filename);
    let temp = papers_dir.join(format!(".{filename}.tmp"));
    std::fs::copy(rendered_pdf, &temp).map_err(|e| StoreApiError::Storage(e.to_string()))?;
    std::fs::rename(&temp, &destination).map_err(|e| StoreApiError::Storage(e.to_string()))?;
    let sha256 =
        paths::sha256_file(&destination).map_err(|e| StoreApiError::Storage(e.to_string()))?;
    let size = std::fs::metadata(&destination)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    // Relative to the library folder when it is one of the known roots;
    // absolute otherwise, so any process can resolve it.
    let relative_path = paths::relative_or_absolute(library_dir, &destination);

    let existing = store
        .list_linked_files(publication_id.to_string())?
        .into_iter()
        .find(|f| {
            f.role.as_deref() == Some(ROLE_ANNOTATED)
                && f.source_remote_id.as_deref() == Some(remote_id)
        });
    match existing {
        Some(row) => {
            let uuid = parse_uuid(&row.id)?;
            store.store.update(
                uuid,
                vec![
                    FieldMutation::SetPayload("sha256".into(), Value::String(sha256.clone())),
                    FieldMutation::SetPayload("file_size".into(), Value::Int(size)),
                    FieldMutation::SetPayload(
                        "relative_path".into(),
                        Value::String(relative_path.clone()),
                    ),
                    FieldMutation::SetPayload("filename".into(), Value::String(filename.clone())),
                    FieldMutation::SetPayload("is_locally_materialized".into(), Value::Bool(true)),
                    FieldMutation::SetPayload(
                        "source_remote_modified_ms".into(),
                        Value::Int(remote_modified_ms),
                    ),
                ],
            )?;
            Ok(VariantOutcome {
                linked_file_id: row.id,
                sha256,
                relative_path,
                replaced: true,
            })
        }
        None => {
            let item = linked_file_variant_to_item(
                pub_uuid,
                &filename,
                &relative_path,
                size,
                Some(&sha256),
                ROLE_ANNOTATED,
                "reMarkable — annotated",
                device_id,
                remote_id,
                Some(remote_modified_ms),
            );
            let id = item.id.to_string();
            store.store.insert(item)?;
            Ok(VariantOutcome {
                linked_file_id: id,
                sha256,
                relative_path,
                replaced: false,
            })
        }
    }
}

#[allow(dead_code)]
pub fn variant_path(library_dir: &Path, primary_filename: &str) -> PathBuf {
    library_dir
        .join("Papers")
        .join(variant_filename(primary_filename))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_variant_sits_beside_the_primary_under_its_own_name() {
        assert_eq!(
            variant_filename("Abel_2002_First_star.pdf"),
            "Abel_2002_First_star (reMarkable).pdf"
        );
        assert_eq!(variant_filename("noext"), "noext (reMarkable).pdf");
    }
}
