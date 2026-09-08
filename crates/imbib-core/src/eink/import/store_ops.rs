//! Store verbs for what came back from the tablet: the rows an import
//! wrote, the OCR jobs still open, and appending to Notes.

use chrono::Utc;
use impress_core::item::Value;
use impress_core::query::{ItemQuery, Predicate};
use impress_core::store::{FieldMutation, ItemStore};

use super::super::paths;
use super::notes_merge::{self, NoteEntry};
use super::reconcile::SOURCE_REMARKABLE;
use crate::unified::shaped_queries::{item_to_annotation_row, AnnotationRow};
use crate::unified::store_api::{parse_uuid, ImbibStore, StoreApiError};

/// An ink row waiting for handwriting recognition.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkOcrJob {
    pub annotation_id: String,
    pub publication_id: String,
    pub linked_file_id: String,
    pub page_number: i32,
    /// Absolute path of the rendered strokes.
    pub image_path: String,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Every row an e-ink import wrote for a publication, across its files,
    /// in page order.
    pub fn eink_annotations_for_publication(
        &self,
        publication_id: String,
    ) -> Result<Vec<AnnotationRow>, StoreApiError> {
        let mut rows = Vec::new();
        for file in self.list_linked_files(publication_id)? {
            rows.extend(
                self.list_annotations(file.id, None)?
                    .into_iter()
                    .filter(|row| row.source.as_deref() == Some(SOURCE_REMARKABLE)),
            );
        }
        rows.sort_by(|a, b| {
            a.page_number
                .cmp(&b.page_number)
                .then(a.date_created.cmp(&b.date_created))
        });
        Ok(rows)
    }

    /// Ink rows with a rendered image and no OCR result yet — for the
    /// Vision pass on the Swift side. `publication_id: None` = everywhere.
    pub fn eink_pending_ocr(
        &self,
        publication_id: Option<String>,
    ) -> Result<Vec<EinkOcrJob>, StoreApiError> {
        let rows: Vec<AnnotationRow> = match &publication_id {
            Some(id) => self.eink_annotations_for_publication(id.clone())?,
            None => {
                let q = ItemQuery {
                    schema: Some("imbib/annotation".into()),
                    predicates: vec![
                        Predicate::Eq("source".into(), Value::String(SOURCE_REMARKABLE.into())),
                        Predicate::Eq("annotation_type".into(), Value::String("ink".into())),
                    ],
                    include_tags: false,
                    include_references: false,
                    ..Default::default()
                };
                self.store
                    .query(&q)?
                    .iter()
                    .map(item_to_annotation_row)
                    .collect()
            }
        };
        let home = paths::user_home();
        let mut jobs = Vec::new();
        for row in rows {
            if row.annotation_type != "ink" || row.ocr_confidence.is_some() {
                continue;
            }
            let Some(relative) = row.image_path.clone() else {
                continue;
            };
            let Some((publication_id, library_id)) =
                self.eink_owner_of_file(&row.linked_file_id)?
            else {
                continue;
            };
            let absolute = if relative.starts_with('/') {
                std::path::PathBuf::from(&relative)
            } else {
                match (&home, &library_id) {
                    (Some(home), Some(library)) => {
                        paths::library_dir_for_write(library, home).join(&relative)
                    }
                    _ => continue,
                }
            };
            if !absolute.is_file() {
                continue;
            }
            jobs.push(EinkOcrJob {
                annotation_id: row.id,
                publication_id,
                linked_file_id: row.linked_file_id,
                page_number: row.page_number,
                image_path: absolute.display().to_string(),
            });
        }
        Ok(jobs)
    }

    /// Highlights, typed text and OCR text an e-ink import wrote, whose
    /// text contains `query` (case-insensitive substring), newest first.
    /// `limit` 0 = 100.
    pub fn eink_search_annotations(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<AnnotationRow>, StoreApiError> {
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return Ok(Vec::new());
        }
        let q = ItemQuery {
            schema: Some("imbib/annotation".into()),
            predicates: vec![Predicate::Eq(
                "source".into(),
                Value::String(SOURCE_REMARKABLE.into()),
            )],
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let mut rows: Vec<AnnotationRow> = self
            .store
            .query(&q)?
            .iter()
            .map(item_to_annotation_row)
            .filter(|row| {
                row.selected_text
                    .as_deref()
                    .map(|t| t.to_lowercase().contains(&needle))
                    .unwrap_or(false)
                    || row
                        .contents
                        .as_deref()
                        .map(|t| t.to_lowercase().contains(&needle))
                        .unwrap_or(false)
            })
            .collect();
        rows.sort_by_key(|row| std::cmp::Reverse(row.date_modified));
        let limit = if limit == 0 { 100 } else { limit as usize };
        rows.truncate(limit);
        Ok(rows)
    }

    /// Record an OCR result. `text: None` with a confidence still closes
    /// the job (nothing legible), so it is not retried forever.
    pub fn eink_complete_ocr(
        &self,
        annotation_id: String,
        text: Option<String>,
        confidence: f64,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&annotation_id)?;
        let mut mutations = vec![FieldMutation::SetPayload(
            "ocr_confidence".into(),
            Value::Float(confidence),
        )];
        match text.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
            Some(text) => mutations.push(FieldMutation::SetPayload(
                "contents".into(),
                Value::String(text),
            )),
            None => mutations.push(FieldMutation::RemovePayload("contents".into())),
        }
        Ok(self.store.update(uuid, mutations)?)
    }

    /// Append the imported highlights and notes to the paper's Notes as one
    /// dated block. Returns false when that tablet snapshot was already
    /// appended (unless `force`).
    pub fn eink_append_notes(
        &self,
        publication_id: String,
        force: bool,
    ) -> Result<bool, StoreApiError> {
        let rows = self.eink_annotations_for_publication(publication_id.clone())?;
        if rows.is_empty() {
            return Ok(false);
        }
        let remote_id = rows
            .iter()
            .filter_map(|r| r.source_remote_id.clone())
            .next()
            .unwrap_or_else(|| "tablet".into());
        let imported_ms = rows
            .iter()
            .filter_map(|r| r.imported_at_ms)
            .max()
            .unwrap_or(0);
        let pub_uuid = parse_uuid(&publication_id)?;
        let Some(item) = self.store.get(pub_uuid)? else {
            return Err(StoreApiError::NotFound(publication_id));
        };
        let raw = match item.payload.get("note") {
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        if !force && notes_merge::already_appended(&raw, &remote_id, imported_ms) {
            return Ok(false);
        }
        let entries: Vec<NoteEntry> = rows
            .iter()
            .filter_map(|row| {
                let text = row
                    .selected_text
                    .clone()
                    .filter(|t| !t.trim().is_empty())
                    .or_else(|| row.contents.clone().filter(|t| !t.trim().is_empty()))?;
                Some(NoteEntry {
                    page_number: Some(i64::from(row.page_number)),
                    kind: row.annotation_type.clone(),
                    text,
                    ocr_confidence: row.ocr_confidence,
                })
            })
            .collect();
        if entries.is_empty() {
            return Ok(false);
        }
        let date = Utc::now().format("%Y-%m-%d").to_string();
        let block = notes_merge::build_block(&date, &remote_id, imported_ms, &entries);
        let merged = notes_merge::append_to_note(&raw, &block);
        self.update_field(publication_id, "note".into(), Some(merged))?;
        Ok(true)
    }
}

impl ImbibStore {
    /// (publication id, library id) for a linked file.
    fn eink_owner_of_file(
        &self,
        linked_file_id: &str,
    ) -> Result<Option<(String, Option<String>)>, StoreApiError> {
        let file_uuid = parse_uuid(linked_file_id)?;
        let Some(file) = self.store.get(file_uuid)? else {
            return Ok(None);
        };
        let Some(pub_uuid) = file.parent else {
            return Ok(None);
        };
        let library = self
            .store
            .get(pub_uuid)?
            .and_then(|item| item.parent.map(|p| p.to_string()));
        Ok(Some((pub_uuid.to_string(), library)))
    }
}
