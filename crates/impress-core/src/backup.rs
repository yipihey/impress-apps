//! Consistent snapshot backup and restore for the shared graph store.
//!
//! The impress suite keeps one SQLite database (WAL mode, `busy_timeout`
//! 5000ms) open by up to three processes at once — imbib, imprint and impel
//! all hold live connections, and the sync engine writes from a background
//! queue. Copying that file with `cp`/`FileManager` is therefore *never*
//! correct: the copy misses whatever sits in the `-wal` sidecar and can tear
//! mid-transaction.
//!
//! Two SQLite primitives give a consistent snapshot of a live database, and
//! this module is built on both:
//!
//! - **`VACUUM INTO`** (snapshot) takes a read transaction over the current
//!   committed state and writes a fresh, defragmented database file. Writers
//!   may continue; the output reflects the instant the read transaction
//!   began, never a torn mix.
//! - **The online backup API** (restore) copies a source file *into a live
//!   destination connection*. This is what makes restore safe: we never swap
//!   files under processes that already hold handles to the database — SQLite
//!   performs the page copy under its own locking and bumps the change
//!   counter, so sibling processes see a coherent new database rather than a
//!   yanked inode.
//!
//! A backup is thus a plain SQLite file, openable with `sqlite3` on any
//! machine with no impress software installed at all (requirement: portable).
//! A small JSON sidecar (`<name>.json`) records provenance and counts so the
//! UI, the HTTP API and MCP agents can list backups without opening each one.
//!
//! ## Sync interaction (ADR-0020)
//!
//! Restoring rewinds every row — including its HLC `logical_clock`. Because
//! merge is whole-record LWW over that clock (ADR-0020 D3/D9), restored rows
//! are *older* than anything a peer changed since, so a synced store will
//! happily overwrite the restore with remote state. Restore therefore clears
//! the sync outbox, per-record engine state and pending references by default
//! (`RestoreOptions::clear_sync_state`), so a restore never pushes a rewound
//! library at other devices. The caller is still expected to disable sync
//! before restoring; the UI and HTTP layers say so.

use std::path::{Path, PathBuf};

use chrono::Utc;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
// NOTE: `sha2::Digest` is imported inside `sha256_file` rather than at module
// scope — its `Digest::new` would otherwise shadow the inherent `Item::new` /
// `ItemQuery::new` in this module's tests via `use super::*`.

use crate::sqlite_store::SqliteItemStore;
use crate::store::StoreError;

/// Manifest format version. Bump when fields change meaning.
pub const BACKUP_FORMAT_VERSION: u32 = 1;

/// Extension of the snapshot itself (a plain SQLite database).
pub const BACKUP_EXTENSION: &str = "impressbackup";

/// Tables a file must contain to be considered an impress graph store.
const REQUIRED_TABLES: [&str; 3] = ["items", "item_references", "store_metadata"];

/// Sync bookkeeping tables cleared after a restore (see module docs).
const SYNC_STATE_TABLES: [&str; 3] = ["sync_outbox", "sync_record_state", "sync_pending_refs"];

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

/// Per-schema row count, e.g. `("publication@1.0.0", 4213)`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SchemaCount {
    pub schema_ref: String,
    pub count: i64,
}

/// Provenance and content summary of one backup, written next to the
/// snapshot as `<name>.json` and recomputed on demand by [`inspect_backup`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackupManifest {
    /// Manifest schema version ([`BACKUP_FORMAT_VERSION`]).
    pub format_version: u32,
    /// Epoch milliseconds the snapshot was taken.
    pub created_at_ms: i64,
    /// Application that took it ("imbib", "imprint", …).
    pub app: String,
    /// Application version string, as supplied by the caller.
    pub app_version: String,
    /// Version of the `impress-core` crate that wrote the snapshot.
    pub core_version: String,
    /// `PRAGMA user_version` of the source database.
    pub schema_version: i64,
    /// `store_metadata.origin_id` — which device/store this came from.
    pub origin_id: String,
    /// Optional human label ("before big import").
    pub label: Option<String>,
    /// Rows in `items` (including operation history).
    pub item_count: i64,
    /// Rows in `items` excluding operation rows — the user-visible content.
    pub content_item_count: i64,
    /// Rows in `item_references`.
    pub reference_count: i64,
    /// Rows in `item_tags`.
    pub tag_count: i64,
    /// Rows in `tombstones` (0 when the table is absent).
    pub tombstone_count: i64,
    /// Per-schema breakdown of non-operation items, descending by count.
    pub counts_by_schema: Vec<SchemaCount>,
    /// Size of the snapshot file in bytes.
    pub byte_size: i64,
    /// SHA-256 of the snapshot file, hex. Lets a restore prove the file has
    /// not been altered since it was written.
    pub sha256: String,
}

/// A snapshot on disk: where it is plus what is in it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackupRecord {
    /// Absolute path of the SQLite snapshot.
    pub path: String,
    /// Absolute path of the JSON manifest sidecar, when present.
    pub manifest_path: Option<String>,
    pub manifest: BackupManifest,
}

/// Result of validating a candidate backup file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackupInspection {
    pub path: String,
    /// True only when the file opens, passes `PRAGMA integrity_check`, holds
    /// every required table, and (when a sidecar exists) matches its digest.
    pub valid: bool,
    /// Human-readable reasons the file was rejected. Empty when `valid`.
    pub issues: Vec<String>,
    /// Recomputed from the file itself. `None` when it could not be read at
    /// all (missing/truncated beyond recognition).
    pub manifest: Option<BackupManifest>,
}

/// Knobs for [`SqliteItemStore::restore_from`].
#[derive(Debug, Clone)]
pub struct RestoreOptions {
    /// Directory for the automatic pre-restore snapshot of current state.
    /// `None` skips it — only sensible in tests.
    pub safety_snapshot_dir: Option<PathBuf>,
    /// Clear `sync_outbox` / `sync_record_state` / `sync_pending_refs` after
    /// the restore so rewound rows are not pushed to other devices.
    pub clear_sync_state: bool,
    /// App name recorded in the safety snapshot's manifest.
    pub app: String,
    /// App version recorded in the safety snapshot's manifest.
    pub app_version: String,
}

impl Default for RestoreOptions {
    fn default() -> Self {
        Self {
            safety_snapshot_dir: None,
            clear_sync_state: true,
            app: "impress".into(),
            app_version: "unknown".into(),
        }
    }
}

/// How hard [`inspect_backup_with`] works.
///
/// `Full` walks every page (`integrity_check`) and rehashes the file — the
/// right gate immediately before a restore, but seconds of work on a
/// multi-hundred-megabyte snapshot. `Quick` opens the file, confirms it holds
/// the expected tables, and trusts the sidecar manifest for counts and digest.
/// Listing a folder must use `Quick`: at `Full` the Settings pane would spend
/// N × several seconds hashing files just to draw a list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InspectDepth {
    Quick,
    Full,
}

/// Outcome of a restore.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RestoreReport {
    /// Snapshot that was restored.
    pub restored_from: String,
    /// Pre-restore snapshot of the state that was replaced, if taken.
    pub safety_snapshot: Option<String>,
    /// `items` rows before the restore.
    pub item_count_before: i64,
    /// `items` rows after — should equal the backup's `item_count`.
    pub item_count_after: i64,
    /// Whether sync bookkeeping was cleared.
    pub cleared_sync_state: bool,
    /// Always true: in-memory caches in every running app now describe a
    /// database that no longer exists. Relaunch is the honest instruction.
    pub requires_relaunch: bool,
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

impl SqliteItemStore {
    /// Write a consistent snapshot of this store to `dest` via `VACUUM INTO`.
    ///
    /// `dest` must not already exist — a backup never overwrites a backup.
    /// Returns the record describing the file that was written; the JSON
    /// sidecar is written alongside it.
    pub fn snapshot_to(
        &self,
        dest: &Path,
        app: &str,
        app_version: &str,
        label: Option<String>,
    ) -> Result<BackupRecord, StoreError> {
        if dest.exists() {
            return Err(StoreError::Storage(format!(
                "backup destination already exists: {}",
                dest.display()
            )));
        }
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| StoreError::Storage(format!("create backup dir: {}", e)))?;
        }

        {
            let conn = self
                .conn
                .lock()
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            // VACUUM INTO refuses to run inside a transaction, and cannot be
            // parameterised on every SQLite build — quote the path instead.
            let sql = format!("VACUUM INTO {}", quote_sql_literal(&dest.to_string_lossy()));
            conn.execute_batch(&sql).map_err(|e| {
                // Leave no half-written file behind for the caller to trip on.
                let _ = std::fs::remove_file(dest);
                StoreError::Storage(format!("VACUUM INTO: {}", e))
            })?;
        }

        // Summarise the snapshot itself, not the live store: the manifest
        // must describe the bytes on disk.
        let manifest = read_manifest_from_file(dest, app, app_version, label)?;
        let manifest_path = manifest_path_for(dest);
        write_manifest(&manifest_path, &manifest)?;

        Ok(BackupRecord {
            path: dest.to_string_lossy().into_owned(),
            manifest_path: Some(manifest_path.to_string_lossy().into_owned()),
            manifest,
        })
    }

    /// Snapshot into `dir` with a generated timestamped filename.
    pub fn snapshot_into_dir(
        &self,
        dir: &Path,
        app: &str,
        app_version: &str,
        label: Option<String>,
        prefix: &str,
    ) -> Result<BackupRecord, StoreError> {
        std::fs::create_dir_all(dir)
            .map_err(|e| StoreError::Storage(format!("create backup dir: {}", e)))?;
        let dest = unique_backup_path(dir, prefix);
        self.snapshot_to(&dest, app, app_version, label)
    }

    // -----------------------------------------------------------------------
    // Restore
    // -----------------------------------------------------------------------

    /// Replace the contents of this store with the snapshot at `src`.
    ///
    /// Order of operations, all-or-nothing by construction:
    /// 1. Validate `src` fully ([`inspect_backup`]). A truncated or corrupt
    ///    file is rejected here, before anything is touched.
    /// 2. Take a safety snapshot of current state (unless disabled).
    /// 3. Copy `src` into the live connection with SQLite's online backup
    ///    API. Sibling processes keep their handles; SQLite does the locking.
    /// 4. Clear sync bookkeeping (see module docs) unless disabled.
    pub fn restore_from(
        &self,
        src: &Path,
        options: &RestoreOptions,
    ) -> Result<RestoreReport, StoreError> {
        let inspection = inspect_backup(src)?;
        if !inspection.valid {
            return Err(StoreError::Storage(format!(
                "refusing to restore invalid backup {}: {}",
                src.display(),
                inspection.issues.join("; ")
            )));
        }

        let item_count_before = self.count_rows("items")?;

        let safety_snapshot = match &options.safety_snapshot_dir {
            Some(dir) => Some(
                self.snapshot_into_dir(
                    dir,
                    &options.app,
                    &options.app_version,
                    Some("automatic pre-restore snapshot".into()),
                    "pre-restore",
                )?
                .path,
            ),
            None => None,
        };

        {
            let mut conn = self
                .conn
                .lock()
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            conn.restore(
                rusqlite::DatabaseName::Main,
                src,
                None::<fn(rusqlite::backup::Progress)>,
            )
            .map_err(|e| StoreError::Storage(format!("restore backup: {}", e)))?;

            if options.clear_sync_state {
                for table in SYNC_STATE_TABLES {
                    if table_exists(&conn, table)? {
                        conn.execute(&format!("DELETE FROM {}", table), [])
                            .map_err(|e| StoreError::Storage(format!("clear {}: {}", table, e)))?;
                    }
                }
            }
        }

        let item_count_after = self.count_rows("items")?;

        Ok(RestoreReport {
            restored_from: src.to_string_lossy().into_owned(),
            safety_snapshot,
            item_count_before,
            item_count_after,
            cleared_sync_state: options.clear_sync_state,
            requires_relaunch: true,
        })
    }

    fn count_rows(&self, table: &str) -> Result<i64, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        count_table(&conn, table)
    }
}

// ---------------------------------------------------------------------------
// Inspection / listing (free functions — no live store required)
// ---------------------------------------------------------------------------

/// Validate a candidate backup file without touching any live store.
///
/// Never returns `Err` for a merely *bad* file — a bad file is a valid
/// answer with `valid == false` and reasons in `issues`. `Err` is reserved
/// for the path being unreadable as a filesystem entry.
pub fn inspect_backup(path: &Path) -> Result<BackupInspection, StoreError> {
    inspect_backup_with(path, InspectDepth::Full)
}

/// Validate a candidate backup file at the requested depth.
pub fn inspect_backup_with(
    path: &Path,
    depth: InspectDepth,
) -> Result<BackupInspection, StoreError> {
    let path_string = path.to_string_lossy().into_owned();
    let mut issues = Vec::new();

    if !path.exists() {
        return Ok(BackupInspection {
            path: path_string,
            valid: false,
            issues: vec!["file does not exist".into()],
            manifest: None,
        });
    }

    let conn = match Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(c) => c,
        Err(e) => {
            return Ok(BackupInspection {
                path: path_string,
                valid: false,
                issues: vec![format!("not a readable SQLite database: {}", e)],
                manifest: None,
            })
        }
    };

    // `integrity_check` walks every page; a truncated file fails here even
    // though `open` succeeded (SQLite opens lazily). Skipped at Quick depth —
    // the required-table probe below still catches a file that is not a store.
    if depth == InspectDepth::Full {
        match conn.query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0)) {
            Ok(result) if result == "ok" => {}
            Ok(result) => issues.push(format!("integrity_check: {}", result)),
            Err(e) => issues.push(format!("integrity_check failed: {}", e)),
        }
    }

    for table in REQUIRED_TABLES {
        match table_exists(&conn, table) {
            Ok(true) => {}
            Ok(false) => issues.push(format!("missing table `{}`", table)),
            Err(e) => issues.push(format!("could not read schema: {}", e)),
        }
    }

    if !issues.is_empty() {
        return Ok(BackupInspection {
            path: path_string,
            valid: false,
            issues,
            manifest: None,
        });
    }

    // Prefer the sidecar for provenance (app/version/label/created-at) but
    // always recompute the counts and digest from the file.
    let sidecar = read_sidecar(&manifest_path_for(path));
    let (app, app_version, label, created_at_ms) = match &sidecar {
        Some(m) => (
            m.app.clone(),
            m.app_version.clone(),
            m.label.clone(),
            Some(m.created_at_ms),
        ),
        None => ("unknown".into(), "unknown".into(), None, None),
    };

    let mut manifest = summarize(
        &conn,
        path,
        &app,
        &app_version,
        label,
        depth == InspectDepth::Full,
    )?;
    if let Some(ms) = created_at_ms {
        manifest.created_at_ms = ms;
    }

    match (&sidecar, depth) {
        (Some(recorded), InspectDepth::Full) => {
            if recorded.sha256 != manifest.sha256 {
                issues.push(
                    "file digest does not match its manifest — the backup was modified after it was written"
                        .into(),
                );
            }
        }
        (Some(recorded), InspectDepth::Quick) => {
            // Not verified at this depth; report what the sidecar attests to
            // rather than an empty string, and let the pre-restore Full pass
            // be the one that can call it a lie.
            manifest.sha256 = recorded.sha256.clone();
        }
        (None, _) => {}
    }

    Ok(BackupInspection {
        path: path_string,
        valid: issues.is_empty(),
        issues,
        manifest: Some(manifest),
    })
}

/// List every valid backup in `dir`, newest first.
///
/// Files that fail validation are skipped, not surfaced as errors — a
/// listing must never fail because one stray file in the folder is junk.
pub fn list_backups(dir: &Path) -> Result<Vec<BackupRecord>, StoreError> {
    let mut out = Vec::new();
    if !dir.exists() {
        return Ok(out);
    }
    let entries = std::fs::read_dir(dir)
        .map_err(|e| StoreError::Storage(format!("read backup dir: {}", e)))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some(BACKUP_EXTENSION) {
            continue;
        }
        // Quick: listing a folder must not rehash hundreds of megabytes per
        // entry. The pre-restore gate re-checks at Full depth.
        let Ok(inspection) = inspect_backup_with(&path, InspectDepth::Quick) else {
            continue;
        };
        let (true, Some(manifest)) = (inspection.valid, inspection.manifest) else {
            continue;
        };
        let manifest_path = manifest_path_for(&path);
        out.push(BackupRecord {
            path: path.to_string_lossy().into_owned(),
            manifest_path: manifest_path
                .exists()
                .then(|| manifest_path.to_string_lossy().into_owned()),
            manifest,
        });
    }
    out.sort_by_key(|b| std::cmp::Reverse(b.manifest.created_at_ms));
    Ok(out)
}

/// Delete a backup and its sidecar. Returns false when nothing was there.
pub fn delete_backup(path: &Path) -> Result<bool, StoreError> {
    if !path.exists() {
        return Ok(false);
    }
    if path.extension().and_then(|e| e.to_str()) != Some(BACKUP_EXTENSION) {
        return Err(StoreError::Storage(format!(
            "refusing to delete a non-backup file: {}",
            path.display()
        )));
    }
    std::fs::remove_file(path).map_err(|e| StoreError::Storage(format!("delete backup: {}", e)))?;
    let sidecar = manifest_path_for(path);
    if sidecar.exists() {
        let _ = std::fs::remove_file(sidecar);
    }
    Ok(true)
}

/// Delete the oldest backups in `dir` beyond `keep`. Returns removed paths.
pub fn prune_backups(dir: &Path, keep: usize) -> Result<Vec<String>, StoreError> {
    let backups = list_backups(dir)?;
    let mut removed = Vec::new();
    if backups.len() <= keep {
        return Ok(removed);
    }
    for record in backups.into_iter().skip(keep) {
        let path = PathBuf::from(&record.path);
        if delete_backup(&path)? {
            removed.push(record.path);
        }
    }
    Ok(removed)
}

/// Sidecar path for a snapshot: `foo.impressbackup` → `foo.impressbackup.json`.
pub fn manifest_path_for(backup: &Path) -> PathBuf {
    let mut s = backup.as_os_str().to_os_string();
    s.push(".json");
    PathBuf::from(s)
}

/// A collision-free timestamped path inside `dir`.
pub fn unique_backup_path(dir: &Path, prefix: &str) -> PathBuf {
    let stamp = Utc::now().format("%Y%m%d-%H%M%S");
    let mut candidate = dir.join(format!("{}-{}.{}", prefix, stamp, BACKUP_EXTENSION));
    let mut n = 2;
    while candidate.exists() {
        candidate = dir.join(format!("{}-{}-{}.{}", prefix, stamp, n, BACKUP_EXTENSION));
        n += 1;
    }
    candidate
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn write_manifest(path: &Path, manifest: &BackupManifest) -> Result<(), StoreError> {
    let json = serde_json::to_string_pretty(manifest)
        .map_err(|e| StoreError::Storage(format!("encode manifest: {}", e)))?;
    std::fs::write(path, json).map_err(|e| StoreError::Storage(format!("write manifest: {}", e)))
}

fn read_sidecar(path: &Path) -> Option<BackupManifest> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

fn read_manifest_from_file(
    path: &Path,
    app: &str,
    app_version: &str,
    label: Option<String>,
) -> Result<BackupManifest, StoreError> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| StoreError::Storage(format!("open snapshot: {}", e)))?;
    summarize(&conn, path, app, app_version, label, true)
}

fn summarize(
    conn: &Connection,
    path: &Path,
    app: &str,
    app_version: &str,
    label: Option<String>,
    compute_digest: bool,
) -> Result<BackupManifest, StoreError> {
    let item_count = count_table(conn, "items")?;
    let content_item_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM items WHERE op_target_id IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap_or(item_count);
    let reference_count = count_table(conn, "item_references")?;
    let tag_count = if table_exists(conn, "item_tags")? {
        count_table(conn, "item_tags")?
    } else {
        0
    };
    let tombstone_count = if table_exists(conn, "tombstones")? {
        count_table(conn, "tombstones")?
    } else {
        0
    };

    let mut counts_by_schema = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT schema_ref, COUNT(*) FROM items
                 WHERE op_target_id IS NULL
                 GROUP BY schema_ref ORDER BY COUNT(*) DESC",
            )
            .map_err(|e| StoreError::Storage(format!("schema counts: {}", e)))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(SchemaCount {
                    schema_ref: row.get(0)?,
                    count: row.get(1)?,
                })
            })
            .map_err(|e| StoreError::Storage(format!("schema counts: {}", e)))?;
        for row in rows.flatten() {
            counts_by_schema.push(row);
        }
    }

    let origin_id: String = conn
        .query_row(
            "SELECT value FROM store_metadata WHERE key = 'origin_id'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| StoreError::Storage(format!("read origin: {}", e)))?
        .unwrap_or_else(|| "unknown".into());

    let schema_version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap_or(0);

    let byte_size = std::fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);

    Ok(BackupManifest {
        format_version: BACKUP_FORMAT_VERSION,
        created_at_ms: Utc::now().timestamp_millis(),
        app: app.to_string(),
        app_version: app_version.to_string(),
        core_version: env!("CARGO_PKG_VERSION").to_string(),
        schema_version,
        origin_id,
        label,
        item_count,
        content_item_count,
        reference_count,
        tag_count,
        tombstone_count,
        counts_by_schema,
        byte_size,
        sha256: if compute_digest {
            sha256_file(path)?
        } else {
            String::new()
        },
    })
}

fn count_table(conn: &Connection, table: &str) -> Result<i64, StoreError> {
    conn.query_row(&format!("SELECT COUNT(*) FROM {}", table), [], |row| {
        row.get(0)
    })
    .map_err(|e| StoreError::Storage(format!("count {}: {}", table, e)))
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool, StoreError> {
    let found: Option<String> = conn
        .query_row(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| StoreError::Storage(format!("sqlite_master: {}", e)))?;
    Ok(found.is_some())
}

fn sha256_file(path: &Path) -> Result<String, StoreError> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut file = std::fs::File::open(path)
        .map_err(|e| StoreError::Storage(format!("open for digest: {}", e)))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|e| StoreError::Storage(format!("read for digest: {}", e)))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Single-quote a string for literal interpolation into SQL.
fn quote_sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
    use crate::query::ItemQuery;
    use crate::store::ItemStore;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn tmp_dir(name: &str) -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "impress-backup-{}-{}-{}",
            name,
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_item(title: &str) -> Item {
        let mut payload = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        Item {
            id: uuid::Uuid::new_v4(),
            schema: "publication@1.0.0".into(),
            payload,
            created: Utc::now(),
            modified: Utc::now(),
            author: "test@example.com".into(),
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
        }
    }

    fn publication_query() -> ItemQuery {
        ItemQuery {
            schema: Some("publication@1.0.0".into()),
            ..ItemQuery::default()
        }
    }

    fn populate(store: &SqliteItemStore, count: usize) -> Vec<ItemId> {
        let mut ids = Vec::new();
        for i in 0..count {
            let item = make_item(&format!("Paper {}", i));
            let id = item.id;
            store.insert(item).unwrap();
            ids.push(id);
        }
        ids
    }

    #[test]
    fn snapshot_round_trips_a_populated_store() {
        let dir = tmp_dir("roundtrip");
        let db = dir.join("live.sqlite");
        let store = SqliteItemStore::open(&db).unwrap();
        populate(&store, 25);

        let record = store
            .snapshot_to(
                &dir.join("b.impressbackup"),
                "imbib",
                "3.0",
                Some("test".into()),
            )
            .unwrap();
        assert_eq!(record.manifest.content_item_count, 25);
        assert_eq!(record.manifest.app, "imbib");
        assert!(record.manifest.byte_size > 0);
        assert!(!record.manifest.sha256.is_empty());
        assert!(PathBuf::from(record.manifest_path.clone().unwrap()).exists());

        // The snapshot is a standalone database that opens as a store.
        let restored = SqliteItemStore::open(&PathBuf::from(&record.path)).unwrap();
        let items = restored.query(&publication_query()).unwrap();
        assert_eq!(items.len(), 25);
    }

    #[test]
    fn restore_reproduces_item_counts() {
        let dir = tmp_dir("restore");
        let db = dir.join("live.sqlite");
        let store = SqliteItemStore::open(&db).unwrap();
        populate(&store, 10);

        let backup = store
            .snapshot_into_dir(&dir.join("backups"), "imbib", "3.0", None, "imbib-backup")
            .unwrap();
        let expected = backup.manifest.item_count;

        // Diverge: add more, then delete some of the originals.
        populate(&store, 7);
        assert!(store.count_rows("items").unwrap() > expected);

        let opts = RestoreOptions {
            safety_snapshot_dir: Some(dir.join("safety")),
            clear_sync_state: true,
            app: "imbib".into(),
            app_version: "3.0".into(),
        };
        let report = store
            .restore_from(&PathBuf::from(&backup.path), &opts)
            .unwrap();

        assert_eq!(report.item_count_after, expected);
        assert!(report.requires_relaunch);
        let safety = report.safety_snapshot.expect("safety snapshot taken");
        assert!(PathBuf::from(&safety).exists());

        // The live store reads back the restored content.
        let items = store.query(&publication_query()).unwrap();
        assert_eq!(items.len(), 10);
    }

    #[test]
    fn restore_clears_sync_bookkeeping() {
        let dir = tmp_dir("syncclear");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        populate(&store, 3);
        let backup = store
            .snapshot_into_dir(&dir.join("backups"), "imbib", "3.0", None, "b")
            .unwrap();
        populate(&store, 3);
        assert!(store.sync_outbox_entries(100).unwrap().len() > 0);

        let opts = RestoreOptions {
            safety_snapshot_dir: None,
            clear_sync_state: true,
            ..RestoreOptions::default()
        };
        store
            .restore_from(&PathBuf::from(&backup.path), &opts)
            .unwrap();
        assert!(store.sync_outbox_entries(100).unwrap().is_empty());
    }

    #[test]
    fn truncated_backup_is_rejected_and_nothing_is_applied() {
        let dir = tmp_dir("truncated");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        populate(&store, 12);
        let backup = store
            .snapshot_into_dir(&dir.join("backups"), "imbib", "3.0", None, "b")
            .unwrap();

        // Chop the file in half — header survives, pages do not.
        let path = PathBuf::from(&backup.path);
        let bytes = std::fs::read(&path).unwrap();
        std::fs::write(&path, &bytes[..bytes.len() / 2]).unwrap();

        let inspection = inspect_backup(&path).unwrap();
        assert!(!inspection.valid, "truncated file must not validate");
        assert!(!inspection.issues.is_empty());

        let before = store.count_rows("items").unwrap();
        let err = store
            .restore_from(&path, &RestoreOptions::default())
            .unwrap_err();
        assert!(format!("{}", err).contains("refusing to restore"));
        // Live store untouched.
        assert_eq!(store.count_rows("items").unwrap(), before);
    }

    #[test]
    fn garbage_file_is_rejected() {
        let dir = tmp_dir("garbage");
        let path = dir.join("junk.impressbackup");
        std::fs::write(&path, b"this is definitely not a database").unwrap();
        let inspection = inspect_backup(&path).unwrap();
        assert!(!inspection.valid);
    }

    #[test]
    fn missing_file_is_rejected() {
        let dir = tmp_dir("missing");
        let inspection = inspect_backup(&dir.join("nope.impressbackup")).unwrap();
        assert!(!inspection.valid);
        assert_eq!(inspection.issues, vec!["file does not exist".to_string()]);
    }

    #[test]
    fn tampered_backup_fails_digest_check() {
        let dir = tmp_dir("tamper");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        populate(&store, 4);
        let backup = store
            .snapshot_into_dir(&dir.join("backups"), "imbib", "3.0", None, "b")
            .unwrap();

        // Add a row directly to the backup: still a valid database, but no
        // longer the bytes the manifest attests to.
        let path = PathBuf::from(&backup.path);
        {
            let copy = SqliteItemStore::open(&path).unwrap();
            populate(&copy, 1);
        }
        let inspection = inspect_backup(&path).unwrap();
        assert!(!inspection.valid);
        assert!(inspection.issues.iter().any(|i| i.contains("digest")));
    }

    #[test]
    fn snapshot_during_concurrent_writes_is_a_valid_database() {
        use std::sync::atomic::AtomicBool;
        use std::sync::Arc;

        let dir = tmp_dir("concurrent");
        let store = Arc::new(SqliteItemStore::open(&dir.join("live.sqlite")).unwrap());
        populate(&store, 50);

        let stop = Arc::new(AtomicBool::new(false));
        let writer_store = Arc::clone(&store);
        let writer_stop = Arc::clone(&stop);
        let writer = std::thread::spawn(move || {
            let mut n = 0;
            while !writer_stop.load(Ordering::SeqCst) {
                let _ = writer_store.insert(make_item(&format!("Concurrent {}", n)));
                n += 1;
            }
            n
        });

        // Take several snapshots while the writer hammers the store.
        let mut records = Vec::new();
        for i in 0..3 {
            records.push(
                store
                    .snapshot_to(
                        &dir.join(format!("snap{}.impressbackup", i)),
                        "imbib",
                        "3.0",
                        None,
                    )
                    .unwrap(),
            );
        }
        stop.store(true, Ordering::SeqCst);
        let written = writer.join().unwrap();
        assert!(written > 0, "writer must have made progress");

        for record in records {
            let inspection = inspect_backup(&PathBuf::from(&record.path)).unwrap();
            assert!(
                inspection.valid,
                "snapshot taken under load must be valid: {:?}",
                inspection.issues
            );
            // And every snapshot holds at least the pre-existing rows.
            assert!(inspection.manifest.unwrap().content_item_count >= 50);
        }
    }

    #[test]
    fn listing_sorts_newest_first_and_skips_junk() {
        let dir = tmp_dir("listing");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        populate(&store, 2);
        let backups = dir.join("backups");

        let first = store
            .snapshot_to(&backups.join("a.impressbackup"), "imbib", "3.0", None)
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        let second = store
            .snapshot_to(&backups.join("b.impressbackup"), "imbib", "3.0", None)
            .unwrap();
        std::fs::write(backups.join("junk.impressbackup"), b"nope").unwrap();
        std::fs::write(backups.join("notes.txt"), b"ignore me").unwrap();

        let listed = list_backups(&backups).unwrap();
        assert_eq!(listed.len(), 2);
        assert!(listed[0].manifest.created_at_ms >= listed[1].manifest.created_at_ms);
        let paths: Vec<_> = listed.iter().map(|r| r.path.clone()).collect();
        assert!(paths.contains(&first.path));
        assert!(paths.contains(&second.path));
    }

    #[test]
    fn snapshot_never_overwrites() {
        let dir = tmp_dir("nooverwrite");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        let dest = dir.join("only.impressbackup");
        store.snapshot_to(&dest, "imbib", "3.0", None).unwrap();
        let err = store.snapshot_to(&dest, "imbib", "3.0", None).unwrap_err();
        assert!(format!("{}", err).contains("already exists"));
    }

    #[test]
    fn prune_keeps_the_newest() {
        let dir = tmp_dir("prune");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        let backups = dir.join("backups");
        for i in 0..4 {
            store
                .snapshot_to(
                    &backups.join(format!("b{}.impressbackup", i)),
                    "imbib",
                    "3.0",
                    None,
                )
                .unwrap();
            std::thread::sleep(std::time::Duration::from_millis(3));
        }
        let removed = prune_backups(&backups, 2).unwrap();
        assert_eq!(removed.len(), 2);
        assert_eq!(list_backups(&backups).unwrap().len(), 2);
    }

    /// Listing must not rehash the files: Quick trusts the sidecar digest and
    /// still rejects anything that is not a store. Restore keeps the Full gate.
    #[test]
    fn quick_inspection_trusts_the_sidecar_but_still_rejects_junk() {
        let dir = tmp_dir("quick");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        populate(&store, 5);
        let backup = store
            .snapshot_to(&dir.join("b.impressbackup"), "imbib", "3.0", None)
            .unwrap();
        let path = PathBuf::from(&backup.path);

        let quick = inspect_backup_with(&path, InspectDepth::Quick).unwrap();
        assert!(quick.valid);
        let manifest = quick.manifest.unwrap();
        assert_eq!(manifest.content_item_count, 5);
        // Reported from the sidecar rather than recomputed, but still correct.
        assert_eq!(manifest.sha256, backup.manifest.sha256);

        let junk = dir.join("junk.impressbackup");
        std::fs::write(&junk, b"not a database at all").unwrap();
        assert!(
            !inspect_backup_with(&junk, InspectDepth::Quick)
                .unwrap()
                .valid
        );
    }

    /// A tampered file passes Quick (no rehash) but must fail the Full gate
    /// that restore runs — this is why restore never uses Quick.
    #[test]
    fn tampering_is_caught_by_the_restore_gate_not_by_listing() {
        let dir = tmp_dir("quicktamper");
        let store = SqliteItemStore::open(&dir.join("live.sqlite")).unwrap();
        populate(&store, 3);
        let backup = store
            .snapshot_to(&dir.join("b.impressbackup"), "imbib", "3.0", None)
            .unwrap();
        let path = PathBuf::from(&backup.path);
        {
            let copy = SqliteItemStore::open(&path).unwrap();
            populate(&copy, 1);
        }
        assert!(
            inspect_backup_with(&path, InspectDepth::Quick)
                .unwrap()
                .valid
        );
        assert!(!inspect_backup(&path).unwrap().valid);
        assert!(store
            .restore_from(&path, &RestoreOptions::default())
            .is_err());
    }

    #[test]
    fn delete_refuses_non_backup_files() {
        let dir = tmp_dir("deleteguard");
        let path = dir.join("precious.sqlite");
        std::fs::write(&path, b"data").unwrap();
        assert!(delete_backup(&path).is_err());
        assert!(path.exists());
    }
}
