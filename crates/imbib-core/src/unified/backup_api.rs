//! UniFFI surface for library backup and restore.
//!
//! All logic lives in `impress_core::backup` — this file is a thin mirror that
//! turns its types into `uniffi::Record`s and its `StoreError`s into
//! `StoreApiError`s. Swift, the HTTP automation API and the MCP tools all go
//! through here, so there is exactly one implementation of "take a consistent
//! snapshot" in the suite.
//!
//! See `impress_core::backup` for why `VACUUM INTO` (snapshot) and the online
//! backup API (restore) are used instead of copying files, and for the
//! ADR-0020 sync caveat that restore rewinds HLC clocks.

use std::path::{Path, PathBuf};

use impress_core::backup;

use super::store_api::{ImbibStore, StoreApiError};

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

/// Rows of one schema inside a backup, e.g. `publication@1.0.0 → 4213`.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct BackupSchemaCount {
    pub schema_ref: String,
    pub count: i64,
}

/// Provenance and contents of one backup file.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct BackupManifestRow {
    pub format_version: u32,
    /// Epoch milliseconds.
    pub created_at_ms: i64,
    pub app: String,
    pub app_version: String,
    pub core_version: String,
    pub schema_version: i64,
    pub origin_id: String,
    pub label: Option<String>,
    pub item_count: i64,
    /// Items excluding operation history — what the user thinks of as content.
    pub content_item_count: i64,
    pub reference_count: i64,
    pub tag_count: i64,
    pub tombstone_count: i64,
    pub counts_by_schema: Vec<BackupSchemaCount>,
    pub byte_size: i64,
    pub sha256: String,
}

/// One backup on disk.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct BackupRecordRow {
    pub path: String,
    pub manifest_path: Option<String>,
    pub manifest: BackupManifestRow,
}

/// Verdict on a candidate backup file.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct BackupInspectionRow {
    pub path: String,
    pub valid: bool,
    /// Why it was rejected. Empty when `valid`.
    pub issues: Vec<String>,
    pub manifest: Option<BackupManifestRow>,
}

/// What a restore did.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct RestoreReportRow {
    pub restored_from: String,
    /// Automatic snapshot of the state that was replaced.
    pub safety_snapshot: Option<String>,
    pub item_count_before: i64,
    pub item_count_after: i64,
    pub cleared_sync_state: bool,
    /// Always true — every running app now holds caches for a database that
    /// no longer exists.
    pub requires_relaunch: bool,
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

impl From<backup::SchemaCount> for BackupSchemaCount {
    fn from(c: backup::SchemaCount) -> Self {
        Self {
            schema_ref: c.schema_ref,
            count: c.count,
        }
    }
}

impl From<backup::BackupManifest> for BackupManifestRow {
    fn from(m: backup::BackupManifest) -> Self {
        Self {
            format_version: m.format_version,
            created_at_ms: m.created_at_ms,
            app: m.app,
            app_version: m.app_version,
            core_version: m.core_version,
            schema_version: m.schema_version,
            origin_id: m.origin_id,
            label: m.label,
            item_count: m.item_count,
            content_item_count: m.content_item_count,
            reference_count: m.reference_count,
            tag_count: m.tag_count,
            tombstone_count: m.tombstone_count,
            counts_by_schema: m.counts_by_schema.into_iter().map(Into::into).collect(),
            byte_size: m.byte_size,
            sha256: m.sha256,
        }
    }
}

impl From<backup::BackupRecord> for BackupRecordRow {
    fn from(r: backup::BackupRecord) -> Self {
        Self {
            path: r.path,
            manifest_path: r.manifest_path,
            manifest: r.manifest.into(),
        }
    }
}

impl From<backup::BackupInspection> for BackupInspectionRow {
    fn from(i: backup::BackupInspection) -> Self {
        Self {
            path: i.path,
            valid: i.valid,
            issues: i.issues,
            manifest: i.manifest.map(Into::into),
        }
    }
}

impl From<backup::RestoreReport> for RestoreReportRow {
    fn from(r: backup::RestoreReport) -> Self {
        Self {
            restored_from: r.restored_from,
            safety_snapshot: r.safety_snapshot,
            item_count_before: r.item_count_before,
            item_count_after: r.item_count_after,
            cleared_sync_state: r.cleared_sync_state,
            requires_relaunch: r.requires_relaunch,
        }
    }
}

// ---------------------------------------------------------------------------
// Exported methods
// ---------------------------------------------------------------------------

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Take a consistent snapshot of the whole shared store into `directory`,
    /// naming it `imbib-backup-<timestamp>.impressbackup`.
    ///
    /// Consistent under concurrent writers: other imbib/imprint/impel
    /// processes may write throughout. The result is a plain SQLite database
    /// plus a `.json` manifest sidecar.
    pub fn create_backup(
        &self,
        directory: String,
        app_version: String,
        label: Option<String>,
    ) -> Result<BackupRecordRow, StoreApiError> {
        let record = self.store.snapshot_into_dir(
            Path::new(&directory),
            "imbib",
            &app_version,
            label,
            "imbib-backup",
        )?;
        Ok(record.into())
    }

    /// Snapshot to an exact path (for a Save panel). Fails if it exists.
    pub fn create_backup_at_path(
        &self,
        path: String,
        app_version: String,
        label: Option<String>,
    ) -> Result<BackupRecordRow, StoreApiError> {
        let record = self
            .store
            .snapshot_to(Path::new(&path), "imbib", &app_version, label)?;
        Ok(record.into())
    }

    /// Every valid backup in `directory`, newest first. Junk files are
    /// skipped rather than failing the listing.
    pub fn list_backups(&self, directory: String) -> Result<Vec<BackupRecordRow>, StoreApiError> {
        Ok(backup::list_backups(Path::new(&directory))?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Validate a backup without touching the live store: integrity check,
    /// required tables, and digest match against its manifest.
    pub fn inspect_backup(&self, path: String) -> Result<BackupInspectionRow, StoreApiError> {
        Ok(backup::inspect_backup(Path::new(&path))?.into())
    }

    /// Replace the live store's contents with `path`.
    ///
    /// The backup is validated first, then current state is snapshotted into
    /// `safety_directory`, then the copy runs through SQLite's online backup
    /// API on the live connection. An invalid backup is rejected before
    /// anything is modified.
    ///
    /// **Sync (ADR-0020):** restored rows carry old HLC clocks and will lose
    /// LWW against anything a peer changed since. `clear_sync_state` (pass
    /// true) drops the outbox and per-record engine state so a rewound
    /// library is not pushed at other devices. Callers should still require
    /// the user to turn sync off first.
    pub fn restore_backup(
        &self,
        path: String,
        app_version: String,
        safety_directory: Option<String>,
        clear_sync_state: bool,
    ) -> Result<RestoreReportRow, StoreApiError> {
        let options = backup::RestoreOptions {
            safety_snapshot_dir: safety_directory.map(PathBuf::from),
            clear_sync_state,
            app: "imbib".into(),
            app_version,
        };
        let report = self.store.restore_from(Path::new(&path), &options)?;
        Ok(report.into())
    }

    /// Delete a backup and its manifest. Refuses anything that is not a
    /// `.impressbackup` file.
    pub fn delete_backup(&self, path: String) -> Result<bool, StoreApiError> {
        Ok(backup::delete_backup(Path::new(&path))?)
    }

    /// Keep the `keep` newest backups in `directory`, delete the rest.
    /// Returns the paths removed.
    pub fn prune_backups(
        &self,
        directory: String,
        keep: u32,
    ) -> Result<Vec<String>, StoreApiError> {
        Ok(backup::prune_backups(Path::new(&directory), keep as usize)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "imbib-backup-api-{}-{}-{}",
            name,
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The full agent-facing loop: create → list → inspect → restore →
    /// prune, exactly as the HTTP routes and MCP tools drive it.
    #[test]
    fn backup_lifecycle_through_the_ffi_surface() {
        let dir = tmp_dir("lifecycle");
        let store = ImbibStore::open(dir.join("live.sqlite").to_string_lossy().into_owned())
            .expect("open store");

        let lib = store
            .create_library("Backup Test".into())
            .expect("create library");

        let backups_dir = dir.join("backups").to_string_lossy().into_owned();
        let record = store
            .create_backup(backups_dir.clone(), "test".into(), Some("first".into()))
            .expect("create backup");
        assert!(record.manifest.content_item_count >= 1);
        assert_eq!(record.manifest.app, "imbib");
        assert_eq!(record.manifest.label.as_deref(), Some("first"));

        let listed = store.list_backups(backups_dir.clone()).expect("list");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].path, record.path);

        let inspection = store.inspect_backup(record.path.clone()).expect("inspect");
        assert!(inspection.valid, "issues: {:?}", inspection.issues);

        // Diverge, then restore and confirm the divergence is gone.
        let extra = store
            .create_library("Created After Backup".into())
            .expect("create library");
        assert!(store.get_library(extra.id.clone()).unwrap().is_some());

        let report = store
            .restore_backup(
                record.path.clone(),
                "test".into(),
                Some(dir.join("safety").to_string_lossy().into_owned()),
                true,
            )
            .expect("restore");
        assert!(report.requires_relaunch);
        assert!(report.cleared_sync_state);
        assert!(report.safety_snapshot.is_some());
        assert_eq!(report.item_count_after, record.manifest.item_count);

        // Pre-backup library survives; post-backup library is gone.
        assert!(store.get_library(lib.id.clone()).unwrap().is_some());
        assert!(store.get_library(extra.id.clone()).unwrap().is_none());

        // Prune keeps nothing when asked for zero.
        let removed = store.prune_backups(backups_dir.clone(), 0).expect("prune");
        assert_eq!(removed.len(), 1);
        assert!(store.list_backups(backups_dir).unwrap().is_empty());
    }

    #[test]
    fn restoring_a_corrupt_file_is_refused() {
        let dir = tmp_dir("corrupt");
        let store = ImbibStore::open(dir.join("live.sqlite").to_string_lossy().into_owned())
            .expect("open store");
        store
            .create_library("Keep Me".into())
            .expect("create library");

        let junk = dir.join("junk.impressbackup");
        std::fs::write(&junk, b"not a database").unwrap();

        let inspection = store
            .inspect_backup(junk.to_string_lossy().into_owned())
            .expect("inspect");
        assert!(!inspection.valid);

        let err = store
            .restore_backup(
                junk.to_string_lossy().into_owned(),
                "test".into(),
                None,
                true,
            )
            .expect_err("must refuse");
        assert!(format!("{:?}", err).contains("refusing to restore"));

        // Live store still readable and populated.
        assert_eq!(store.list_libraries().unwrap().len(), 1);
    }
}
