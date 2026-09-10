//! `SharedStore`'s face on manuscript projects (ADR-0030): the file rows,
//! the one-read snapshot, and the build rows — for the Swift chassis
//! (`ManuscriptStoreAdapter`) and imprint's Files panel. Thin delegation to
//! `impress_core::manuscript_project`, which owns every rule; the engine
//! (`imprint-core::project`) runs on the app side over what these return.

use std::path::PathBuf;

use impress_core::blobs::BlobStore;
use impress_core::item::ItemId;
use impress_core::manuscript_project::{self as mp, Author, ManuscriptBuildRow, ManuscriptFileRow};

use crate::{SharedStore, SharedStoreError};

/// One file row.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedProjectFile {
    pub id: String,
    pub path: String,
    /// chapter | bibliography | figure | figure-source | data | style | aux | supplement | output
    pub role: String,
    /// text | binary
    pub kind: String,
    pub format: Option<String>,
    /// Inline text; `None` when the bytes are in the blob store.
    pub content: Option<String>,
    pub in_blob_store: bool,
    pub content_hash: String,
    pub size: i64,
    pub mime_type: Option<String>,
    pub derived_from: Option<String>,
    pub derived_from_hash: Option<String>,
    pub build_json: Option<String>,
    pub bib_source_json: Option<String>,
    pub external_path: Option<String>,
    pub modified_ms: Option<i64>,
}

impl From<ManuscriptFileRow> for SharedProjectFile {
    fn from(r: ManuscriptFileRow) -> Self {
        Self {
            id: r.id.to_string(),
            path: r.path,
            role: r.role,
            kind: r.kind,
            format: r.format,
            in_blob_store: r.blob_ref.is_some(),
            content: r.content,
            content_hash: r.content_hash,
            size: r.size,
            mime_type: r.mime_type,
            derived_from: r.derived_from,
            derived_from_hash: r.derived_from_hash,
            build_json: r.build_json,
            bib_source_json: r.bib_source_json,
            external_path: r.external_path,
            modified_ms: r.modified_ms,
        }
    }
}

/// The project in one read: the entry (from the manuscript row) and every
/// file row. A manuscript with no file rows is a one-file project.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedProjectSnapshot {
    pub manuscript_id: String,
    pub title: String,
    pub format: String,
    pub entry_path: String,
    pub entry_text: String,
    pub entry_hash: String,
    pub project_version: i64,
    pub targets_json: Option<String>,
    pub working_copy_path: Option<String>,
    pub files: Vec<SharedProjectFile>,
    /// The stamp `project_version`-aware readers compare builds against.
    pub input_stamp: String,
}

/// One explicit build (ADR-0030 D8).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedManuscriptBuild {
    pub id: String,
    pub manuscript_id: String,
    pub target_id: String,
    pub engine: String,
    pub status: String,
    pub input_stamp: String,
    pub started_ms: i64,
    pub finished_ms: Option<i64>,
    pub duration_ms: Option<i64>,
    pub outputs_json: Option<String>,
    pub diagnostics_json: Option<String>,
    pub steps_json: Option<String>,
    pub allow_shell: bool,
    pub message: Option<String>,
    pub created_ms: i64,
}

impl From<ManuscriptBuildRow> for SharedManuscriptBuild {
    fn from(b: ManuscriptBuildRow) -> Self {
        Self {
            id: b.id.to_string(),
            manuscript_id: b.manuscript_id.to_string(),
            target_id: b.record.target_id,
            engine: b.record.engine,
            status: b.record.status,
            input_stamp: b.record.input_stamp,
            started_ms: b.record.started_ms,
            finished_ms: b.record.finished_ms,
            duration_ms: b.record.duration_ms,
            outputs_json: b.record.outputs_json,
            diagnostics_json: b.record.diagnostics_json,
            steps_json: b.record.steps_json,
            allow_shell: b.record.allow_shell,
            message: b.record.message,
            created_ms: b.created_ms,
        }
    }
}

fn parse_id(id: &str) -> Result<ItemId, SharedStoreError> {
    id.trim()
        .parse()
        .map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })
}

fn human(author: &str) -> Author {
    let name = author.trim();
    Author::human(if name.is_empty() { "user:local" } else { name })
}

impl SharedStore {
    /// The workspace CAS next to the database (`<workspace>/content`), or a
    /// per-process scratch directory for an in-memory store.
    pub(crate) fn blobs(&self) -> BlobStore {
        match &self.blob_root {
            Some(root) => BlobStore::new(root.clone()),
            None => BlobStore::new(
                std::env::temp_dir()
                    .join("impress-shared-store-blobs")
                    .join(std::process::id().to_string()),
            ),
        }
    }
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedStore {
    /// Where this store keeps content-addressed bytes (`None` in memory).
    pub fn manuscript_project_blob_root(&self) -> Option<String> {
        self.blob_root
            .as_ref()
            .map(|p: &PathBuf| p.display().to_string())
    }

    /// The project in one read (ADR-0030 D1).
    pub fn manuscript_project_snapshot(
        &self,
        manuscript_id: String,
    ) -> Result<SharedProjectSnapshot, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        let snapshot = mp::load_project(&self.inner, id)?;
        let input_stamp = snapshot.input_stamp("main");
        Ok(SharedProjectSnapshot {
            manuscript_id: snapshot.manuscript_id.to_string(),
            title: snapshot.title,
            format: snapshot.format,
            entry_path: snapshot.entry_path,
            entry_text: snapshot.entry_text,
            entry_hash: snapshot.entry_hash,
            project_version: snapshot.project_version,
            targets_json: snapshot.targets_json,
            working_copy_path: snapshot.working_copy_path,
            files: snapshot.files.into_iter().map(Into::into).collect(),
            input_stamp,
        })
    }

    /// Every file row, sorted by path (the entry is not a row).
    pub fn manuscript_project_files(
        &self,
        manuscript_id: String,
    ) -> Result<Vec<SharedProjectFile>, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::list_files(&self.inner, id)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// One file row, if any.
    pub fn manuscript_project_file(
        &self,
        manuscript_id: String,
        path: String,
    ) -> Result<Option<SharedProjectFile>, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::get_file(&self.inner, id, &path)?.map(Into::into))
    }

    /// A file's bytes — inline text or the blob. An absent blob is an error
    /// naming the path rather than an empty file.
    pub fn manuscript_project_file_bytes(
        &self,
        manuscript_id: String,
        path: String,
    ) -> Result<Vec<u8>, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        let row =
            mp::get_file(&self.inner, id, &path)?.ok_or_else(|| SharedStoreError::NotFound {
                message: format!("no file at {path:?}"),
            })?;
        row.bytes(&self.blobs())
            .map_err(|e| SharedStoreError::Storage {
                message: format!("blob read for {path:?}: {e}"),
            })?
            .ok_or_else(|| SharedStoreError::NotFound {
                message: format!("{path:?}: its bytes are not in this workspace's blob store"),
            })
    }

    /// Create or replace a text file. `role` absent = from the extension.
    pub fn manuscript_project_put_text(
        &self,
        manuscript_id: String,
        path: String,
        role: Option<String>,
        text: String,
        author: String,
    ) -> Result<SharedProjectFile, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        let row = mp::put_file(
            &self.inner,
            &self.blobs(),
            id,
            mp::PutFile {
                path: &path,
                role: role.as_deref(),
                bytes: text.as_bytes(),
                kind: Some("text"),
                mime_type: None,
            },
            &human(&author),
        )?;
        Ok(row.into())
    }

    /// Create or replace a file from bytes (binaries; text is inferred when
    /// the bytes are UTF-8 without NUL).
    pub fn manuscript_project_put_bytes(
        &self,
        manuscript_id: String,
        path: String,
        role: Option<String>,
        bytes: Vec<u8>,
        mime_type: Option<String>,
        author: String,
    ) -> Result<SharedProjectFile, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        let row = mp::put_file(
            &self.inner,
            &self.blobs(),
            id,
            mp::PutFile {
                path: &path,
                role: role.as_deref(),
                bytes: &bytes,
                kind: None,
                mime_type: mime_type.as_deref(),
            },
            &human(&author),
        )?;
        Ok(row.into())
    }

    /// Delete a file row. `false` when there was none.
    pub fn manuscript_project_delete_file(
        &self,
        manuscript_id: String,
        path: String,
    ) -> Result<bool, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::delete_file(&self.inner, id, &path)?)
    }

    /// Move / rename a file; outputs that named the old path follow it.
    pub fn manuscript_project_move_file(
        &self,
        manuscript_id: String,
        from: String,
        to: String,
        author: String,
    ) -> Result<SharedProjectFile, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::move_file(&self.inner, id, &from, &to, &human(&author))?.into())
    }

    /// Declare the entry path (the manuscript body's file name).
    pub fn manuscript_project_set_entry(
        &self,
        manuscript_id: String,
        path: String,
        author: String,
    ) -> Result<String, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::set_entry_path(&self.inner, id, &path, &human(&author))?)
    }

    /// Declare the targets (`None` restores the implicit single target).
    pub fn manuscript_project_set_targets(
        &self,
        manuscript_id: String,
        targets_json: Option<String>,
        author: String,
    ) -> Result<(), SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        mp::set_targets(&self.inner, id, targets_json.as_deref(), &human(&author))?;
        Ok(())
    }

    /// Set one settable field on a file row (`role`, `build_json`,
    /// `bib_source_json`, `derived_from`, `derived_from_hash`,
    /// `external_path`, `mime_type`); `None` clears it.
    pub fn manuscript_project_set_file_field(
        &self,
        manuscript_id: String,
        path: String,
        field: String,
        value: Option<String>,
    ) -> Result<SharedProjectFile, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::set_file_field(&self.inner, id, &path, &field, value.as_deref())?.into())
    }

    /// Builds of a manuscript, newest first.
    pub fn manuscript_project_builds(
        &self,
        manuscript_id: String,
        limit: Option<u32>,
    ) -> Result<Vec<SharedManuscriptBuild>, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::list_builds(&self.inner, id, limit.map(|l| l as usize))?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Record a build that is starting (`record_json` is a
    /// `BuildRecord`: target_id, engine, status, input_stamp, started_ms…).
    /// The app builds through `imprint-core`'s engine and records here, so
    /// the CLI, MCP and the app read one history.
    pub fn manuscript_project_record_build(
        &self,
        manuscript_id: String,
        record_json: String,
        author: Option<String>,
    ) -> Result<SharedManuscriptBuild, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        let record: mp::BuildRecord =
            serde_json::from_str(&record_json).map_err(|e| SharedStoreError::InvalidArgument {
                message: format!("record_json: {e}"),
            })?;
        let author = author
            .map(mp::Author::human)
            .unwrap_or_else(|| mp::Author::human("user:local"));
        Ok(mp::record_build(&self.inner, id, &record, &author)?.into())
    }

    /// Finish a recorded build with its outcome (`record_json` as above,
    /// with status, finished_ms, duration_ms, outputs/diagnostics/steps
    /// JSON and message filled in). Keeps the last `BUILD_RETENTION`.
    pub fn manuscript_project_finish_build(
        &self,
        manuscript_id: String,
        build_id: String,
        record_json: String,
    ) -> Result<SharedManuscriptBuild, SharedStoreError> {
        let manuscript = parse_id(&manuscript_id)?;
        let build = parse_id(&build_id)?;
        let record: mp::BuildRecord =
            serde_json::from_str(&record_json).map_err(|e| SharedStoreError::InvalidArgument {
                message: format!("record_json: {e}"),
            })?;
        let row = mp::finish_build(&self.inner, build, &record)?;
        let _ = mp::compact_builds(
            &self.inner,
            manuscript,
            impress_core::schemas::BUILD_RETENTION,
        );
        Ok(row.into())
    }

    /// Mark `output` as made from `source` at `input_hash` (a figure step's
    /// provenance; staleness derives from it).
    pub fn manuscript_project_record_derived(
        &self,
        manuscript_id: String,
        output: String,
        source: String,
        input_hash: String,
    ) -> Result<SharedProjectFile, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::record_derived(&self.inner, id, &output, &source, &input_hash)?.into())
    }

    /// Record where the project is checked out (`working_copy_path`), or
    /// clear it with `None` (ADR-0030 D11).
    pub fn manuscript_project_set_working_copy(
        &self,
        manuscript_id: String,
        path: Option<String>,
        author: Option<String>,
    ) -> Result<(), SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        let author = author
            .map(mp::Author::human)
            .unwrap_or_else(|| mp::Author::human("user:local"));
        mp::set_working_copy_path(&self.inner, id, path.as_deref(), &author)?;
        Ok(())
    }

    /// The newest `ok` build of a target (any target when `None`).
    pub fn manuscript_project_latest_build(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> Result<Option<SharedManuscriptBuild>, SharedStoreError> {
        let id = parse_id(&manuscript_id)?;
        Ok(mp::latest_ok_build(&self.inner, id, target_id.as_deref())?.map(Into::into))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
    use impress_core::store::ItemStore;
    use std::collections::BTreeMap;

    fn manuscript(store: &SharedStore, body: &str) -> String {
        let id = uuid::Uuid::new_v4();
        let mut payload = BTreeMap::new();
        payload.insert("title".into(), Value::String("P".into()));
        payload.insert("format".into(), Value::String("typst".into()));
        payload.insert("status".into(), Value::String("draft".into()));
        payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
        payload.insert("body_content".into(), Value::String(body.into()));
        let now = chrono::Utc::now();
        store
            .inner
            .insert(Item {
                id,
                schema: "manuscript".into(),
                payload,
                created: now,
                modified: now,
                author: "user:test".into(),
                author_kind: ActorKind::Human,
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
                parent: None,
            })
            .unwrap();
        id.to_string()
    }

    #[test]
    fn the_ffi_face_round_trips_text_and_bytes() {
        let store = SharedStore::open_in_memory().unwrap();
        let id = manuscript(&store, "= T");
        let snap = store.manuscript_project_snapshot(id.clone()).unwrap();
        assert_eq!(snap.entry_path, "main.typ");
        assert!(snap.files.is_empty());
        assert_eq!(snap.project_version, 0);

        let row = store
            .manuscript_project_put_text(
                id.clone(),
                "ch/a.typ".into(),
                None,
                "== A".into(),
                "user:test".into(),
            )
            .unwrap();
        assert_eq!(row.role, "chapter");
        assert_eq!(row.content.as_deref(), Some("== A"));
        let png = store
            .manuscript_project_put_bytes(
                id.clone(),
                "f/x.png".into(),
                None,
                b"\x89PNG\0".to_vec(),
                None,
                "user:test".into(),
            )
            .unwrap();
        assert!(png.in_blob_store);
        assert_eq!(
            store
                .manuscript_project_file_bytes(id.clone(), "f/x.png".into())
                .unwrap(),
            b"\x89PNG\0"
        );
        assert_eq!(
            store
                .manuscript_project_file_bytes(id.clone(), "ch/a.typ".into())
                .unwrap(),
            b"== A"
        );
        assert_eq!(store.manuscript_project_files(id.clone()).unwrap().len(), 2);
        let snap = store.manuscript_project_snapshot(id.clone()).unwrap();
        assert_eq!(snap.project_version, 1);
        assert_eq!(snap.files.len(), 2);

        let moved = store
            .manuscript_project_move_file(
                id.clone(),
                "ch/a.typ".into(),
                "ch/b.typ".into(),
                "user:test".into(),
            )
            .unwrap();
        assert_eq!(moved.path, "ch/b.typ");
        assert!(store
            .manuscript_project_delete_file(id.clone(), "ch/b.typ".into())
            .unwrap());
        assert!(!store
            .manuscript_project_delete_file(id.clone(), "ch/b.typ".into())
            .unwrap());
        assert!(store
            .manuscript_project_file(id.clone(), "ch/b.typ".into())
            .unwrap()
            .is_none());
        assert!(store
            .manuscript_project_file_bytes(id.clone(), "nope.typ".into())
            .is_err());
        assert!(store
            .manuscript_project_builds(id, None)
            .unwrap()
            .is_empty());
    }
}
