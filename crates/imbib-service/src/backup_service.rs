//! `ImbibBackupService` — whole-store snapshots and restore.
//!
//! Ported from the TypeScript MCP server's five `imbib_*_backup` tools as part
//! of retiring it (see `docs/mcp-migration-ledger.md`).
//!
//! # Why restore is not implemented here
//!
//! Create, list, inspect and delete are safe against the store directly: they
//! read, or they write files beside it. **Restore is not.** Two guarantees live
//! in the Swift `LibraryBackupService`, not in the engine:
//!
//! 1. **The sync guard.** Restore is refused while iCloud sync is on, because
//!    restored rows carry old HLC clocks and a peer's newer copies would win
//!    under ADR-0020 whole-record LWW — the restore would silently undo itself.
//!    That check reads a flag from the app group, which this process cannot see.
//! 2. **Telling the UI.** After a restore every in-memory cache in imbib,
//!    imprint and impel describes rows that no longer exist. The app announces
//!    this; a direct store write cannot.
//!
//! So the default backend refuses `restore_backup` and says to use the running
//! app. The HTTP backend (`imbib-service-http`) forwards to
//! `POST /api/backups/restore`, where both guarantees hold. A destructive
//! operation that is *usually* correct is not good enough for the one tool
//! whose whole job is recovering from data loss.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// Provenance and contents of one backup.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct BackupRecord {
    pub path: String,
    pub filename: String,
    /// When the snapshot was taken, ISO 8601.
    pub created_at: String,
    /// Items excluding operation history — the user-visible content.
    pub content_item_count: i64,
    pub reference_count: i64,
    pub byte_size: i64,
    pub size_string: String,
    pub sha256: String,
    pub label: Option<String>,
}

/// Verdict on a candidate backup file.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct BackupInspection {
    pub path: String,
    pub valid: bool,
    /// Why it was rejected. Empty when valid.
    pub issues: Vec<String>,
    pub record: Option<BackupRecord>,
}

/// What a restore did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RestoreReport {
    pub restored_from: String,
    /// Automatic snapshot of the state that was replaced.
    pub safety_snapshot: Option<String>,
    pub item_count_before: i64,
    pub item_count_after: i64,
    pub cleared_sync_state: bool,
    /// Always true — running apps hold caches for a database that is gone.
    pub requires_relaunch: bool,
    /// Empty on success; the refusal reason otherwise.
    pub error: Option<String>,
}

fn iso(ms: i64) -> String {
    // created_at_ms → ISO 8601 without pulling chrono in for one field.
    let secs = ms / 1000;
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant's civil_from_days. Days since the Unix epoch → (y, m, d).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

impl From<&imbib_core::unified::backup_api::BackupRecordRow> for BackupRecord {
    fn from(r: &imbib_core::unified::backup_api::BackupRecordRow) -> Self {
        let m = &r.manifest;
        let filename = std::path::Path::new(&r.path)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        Self {
            path: r.path.clone(),
            filename,
            created_at: iso(m.created_at_ms),
            content_item_count: m.content_item_count,
            reference_count: m.reference_count,
            byte_size: m.byte_size,
            size_string: human_bytes(m.byte_size),
            sha256: m.sha256.clone(),
            label: m.label.clone(),
        }
    }
}

fn human_bytes(n: i64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1000.0 && i < UNITS.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} bytes")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

#[impress_service]
pub trait ImbibBackupService: Send + Sync + 'static {
    /// Take a consistent snapshot of the whole shared impress store — papers,
    /// tags, collections, manuscripts and annotations — as a single SQLite
    /// file. Safe to run while imbib, imprint and impel are all writing.
    /// Pass an empty directory to use the default backups folder.
    #[impress_method]
    async fn create_backup(&self, directory: String, label: Option<String>) -> Vec<BackupRecord>;

    /// List backups in a directory, newest first. Pass an empty string for the
    /// default backups folder.
    #[impress_method]
    async fn list_backups(&self, directory: String) -> Vec<BackupRecord>;

    /// Validate a backup file without touching the live store: integrity
    /// check, required tables, and a digest match against its manifest.
    #[impress_method]
    async fn inspect_backup(&self, path: String) -> BackupInspection;

    /// Replace the whole library with a backup. **Requires the imbib app to be
    /// running**: it refuses while iCloud sync is on, and it must tell the UI
    /// that every cached row is gone. Both guarantees live in the app.
    #[impress_method]
    async fn restore_backup(&self, path: String) -> RestoreReport;

    /// Delete one backup file and its manifest sidecar.
    #[impress_method]
    async fn delete_backup(&self, path: String) -> bool;
}

#[derive(Clone)]
pub struct DefaultImbibBackupService {
    store: Arc<ImbibStore>,
}

impl DefaultImbibBackupService {
    pub fn new(store: Arc<ImbibStore>) -> Self {
        Self { store }
    }
}

fn log(m: &str, e: impl std::fmt::Display) {
    eprintln!("[imbib-backup-service] {m}: {e}");
}

/// Default backups directory, matching the Swift `LibraryBackupService`.
fn default_directory() -> String {
    dirs::home_dir()
        .map(|h| {
            h.join("Library/Application Support/imbib/Backups")
                .to_string_lossy()
                .into_owned()
        })
        .unwrap_or_default()
}

fn resolve_dir(directory: String) -> String {
    if directory.trim().is_empty() {
        default_directory()
    } else {
        directory
    }
}

const APP_VERSION: &str = concat!("impress-mcp ", env!("CARGO_PKG_VERSION"));

#[async_trait::async_trait]
impl ImbibBackupService for DefaultImbibBackupService {
    async fn create_backup(&self, directory: String, label: Option<String>) -> Vec<BackupRecord> {
        match self
            .store
            .create_backup(resolve_dir(directory), APP_VERSION.into(), label)
        {
            Ok(row) => vec![BackupRecord::from(&row)],
            Err(e) => {
                log("create_backup", e);
                vec![]
            }
        }
    }

    async fn list_backups(&self, directory: String) -> Vec<BackupRecord> {
        self.store
            .list_backups(resolve_dir(directory))
            .map(|rows| rows.iter().map(BackupRecord::from).collect())
            .unwrap_or_else(|e| {
                log("list_backups", e);
                vec![]
            })
    }

    async fn inspect_backup(&self, path: String) -> BackupInspection {
        match self.store.inspect_backup(path.clone()) {
            Ok(row) => BackupInspection {
                path: row.path,
                valid: row.valid,
                issues: row.issues,
                record: None,
            },
            Err(e) => {
                log("inspect_backup", &e);
                BackupInspection {
                    path,
                    valid: false,
                    issues: vec![e.to_string()],
                    record: None,
                }
            }
        }
    }

    async fn restore_backup(&self, path: String) -> RestoreReport {
        // See the module docs: the sync guard and the UI notification both live
        // in the app, and neither can be honoured from here.
        RestoreReport {
            restored_from: path,
            safety_snapshot: None,
            item_count_before: 0,
            item_count_after: 0,
            cleared_sync_state: false,
            requires_relaunch: true,
            error: Some(
                "Restore requires the imbib app to be running: it must refuse while \
                 iCloud sync is on, and it must tell the UI that every cached row is \
                 gone. Open imbib and try again."
                    .into(),
            ),
        }
    }

    async fn delete_backup(&self, path: String) -> bool {
        self.store.delete_backup(path).unwrap_or_else(|e| {
            log("delete_backup", e);
            false
        })
    }
}

impress_service_impl! {
    service = ImbibBackupService,
    impl = DefaultImbibBackupService,
    instance = || crate::backend::backup_service_instance(),
    methods = [
        create_backup(directory: String, label: Option<String>) -> Vec<BackupRecord>,
        list_backups(directory: String) -> Vec<BackupRecord>,
        inspect_backup(path: String) -> BackupInspection,
        restore_backup(path: String) -> RestoreReport,
        delete_backup(path: String) -> bool,
    ],
}
