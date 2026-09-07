//! `ImbibEinkService` — mirroring papers to an e-ink tablet over its USB
//! interface and pulling the annotated copies back.
//!
//! Store-direct: every verb works with imbib closed, against the shared
//! store and the tablet at `base_url`. The one thing only the running app
//! can do is fetch a missing PDF from a publisher — rows that need one wait
//! in `awaiting_source` and `eink_awaiting_source` lists them.

use std::sync::Arc;

use imbib_core::eink;
use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::MutationResult;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkDeviceRecord {
    pub id: String,
    pub name: String,
    pub transport: String,
    pub base_url: String,
    /// `all` or `individual`.
    pub mirror_mode: String,
    pub root_folder_name: String,
    pub mirror_collections: bool,
    pub include_library_level: bool,
    pub include_inbox: bool,
    pub folder_strategy: String,
    pub upload_format: String,
    pub auto_fetch_source: bool,
    pub import_annotated_pdf: bool,
    pub import_rmdoc: bool,
    pub import_highlights: bool,
    pub import_ink: bool,
    pub import_typed_text: bool,
    pub run_ocr: bool,
    pub auto_import_on_connect: bool,
    pub enabled: bool,
    pub last_sync_at_ms: Option<i64>,
    pub last_seen_at_ms: Option<i64>,
    pub last_error: Option<String>,
}

impl From<&eink::EinkDeviceRow> for EinkDeviceRecord {
    fn from(r: &eink::EinkDeviceRow) -> Self {
        Self {
            id: r.id.clone(),
            name: r.name.clone(),
            transport: r.transport.clone(),
            base_url: r.base_url.clone(),
            mirror_mode: r.mirror_mode.clone(),
            root_folder_name: r.root_folder_name.clone(),
            mirror_collections: r.mirror_collections,
            include_library_level: r.include_library_level,
            include_inbox: r.include_inbox,
            folder_strategy: r.folder_strategy.clone(),
            upload_format: r.upload_format.clone(),
            auto_fetch_source: r.auto_fetch_source,
            import_annotated_pdf: r.import_annotated_pdf,
            import_rmdoc: r.import_rmdoc,
            import_highlights: r.import_highlights,
            import_ink: r.import_ink,
            import_typed_text: r.import_typed_text,
            run_ocr: r.run_ocr,
            auto_import_on_connect: r.auto_import_on_connect,
            enabled: r.enabled,
            last_sync_at_ms: r.last_sync_at_ms,
            last_seen_at_ms: r.last_seen_at_ms,
            last_error: r.last_error.clone(),
        }
    }
}

/// Fields to set on a device; every one is optional so a call changes only
/// what it names. `id` absent = create a device.
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkDeviceInput {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub base_url: Option<String>,
    /// `all` (every paper with a PDF/ePUB) or `individual` (marked papers).
    #[serde(default)]
    pub mirror_mode: Option<String>,
    #[serde(default)]
    pub root_folder_name: Option<String>,
    #[serde(default)]
    pub mirror_collections: Option<bool>,
    #[serde(default)]
    pub include_library_level: Option<bool>,
    #[serde(default)]
    pub include_inbox: Option<bool>,
    /// `rmdoc` (exact names) or `pdf` (bare file, shown as `<name>.pdf`).
    #[serde(default)]
    pub upload_format: Option<String>,
    #[serde(default)]
    pub auto_fetch_source: Option<bool>,
    #[serde(default)]
    pub import_annotated_pdf: Option<bool>,
    #[serde(default)]
    pub import_rmdoc: Option<bool>,
    #[serde(default)]
    pub import_highlights: Option<bool>,
    #[serde(default)]
    pub import_ink: Option<bool>,
    #[serde(default)]
    pub import_typed_text: Option<bool>,
    #[serde(default)]
    pub run_ocr: Option<bool>,
    #[serde(default)]
    pub auto_import_on_connect: Option<bool>,
    #[serde(default)]
    pub enabled: Option<bool>,
}

impl From<EinkDeviceInput> for eink::EinkDeviceConfigInput {
    fn from(i: EinkDeviceInput) -> Self {
        Self {
            id: i.id,
            name: i.name,
            transport: None,
            base_url: i.base_url,
            mirror_mode: i.mirror_mode,
            root_folder_name: i.root_folder_name,
            mirror_collections: i.mirror_collections,
            include_library_level: i.include_library_level,
            include_inbox: i.include_inbox,
            folder_strategy: None,
            upload_format: i.upload_format,
            auto_fetch_source: i.auto_fetch_source,
            import_annotated_pdf: i.import_annotated_pdf,
            import_rmdoc: i.import_rmdoc,
            import_highlights: i.import_highlights,
            import_ink: i.import_ink,
            import_typed_text: i.import_typed_text,
            run_ocr: i.run_ocr,
            auto_import_on_connect: i.auto_import_on_connect,
            enabled: i.enabled,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkMirrorRecord {
    pub id: String,
    pub publication_id: String,
    pub device_id: String,
    pub marked: bool,
    /// `queued`, `awaiting_source`, `awaiting_folder`, `uploaded`, `stale`,
    /// `removed_on_device`, `failed`, `superseded` or `unmarked`.
    pub state: String,
    pub remote_id: Option<String>,
    pub remote_name: Option<String>,
    pub remote_path: Option<String>,
    pub uploaded_at_ms: Option<i64>,
    pub remote_modified_ms: Option<i64>,
    pub imported_modified_ms: Option<i64>,
    pub annotated_file_id: Option<String>,
    pub last_error: Option<String>,
    pub attempts: i64,
    pub has_new_annotations: bool,
}

impl From<&eink::EinkMirrorRow> for EinkMirrorRecord {
    fn from(r: &eink::EinkMirrorRow) -> Self {
        Self {
            id: r.id.clone(),
            publication_id: r.publication_id.clone(),
            device_id: r.device_id.clone(),
            marked: r.marked,
            state: r.state.clone(),
            remote_id: r.remote_id.clone(),
            remote_name: r.remote_name.clone(),
            remote_path: r.remote_path.clone(),
            uploaded_at_ms: r.uploaded_at_ms,
            remote_modified_ms: r.remote_modified_ms,
            imported_modified_ms: r.imported_modified_ms,
            annotated_file_id: r.annotated_file_id.clone(),
            last_error: r.last_error.clone(),
            attempts: r.attempts,
            has_new_annotations: r.has_new_annotations(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkCountsRecord {
    pub queued: u32,
    pub awaiting_source: u32,
    pub awaiting_folder: u32,
    pub uploaded: u32,
    pub stale: u32,
    pub removed_on_device: u32,
    pub failed: u32,
    pub unmarked: u32,
    pub new_annotations: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkStatusRecord {
    pub ok: bool,
    pub devices: Vec<EinkDeviceRecord>,
    /// The device whose marks appear on list rows (individual mode), if any.
    pub marker_device_id: Option<String>,
    pub default_device_id: Option<String>,
    pub counts: EinkCountsRecord,
    pub last_sync_at_ms: Option<i64>,
    pub last_error: Option<String>,
    /// Publications still carrying the retired `_remarkable_*` payload keys.
    pub legacy_marker_rows: u32,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkMarkResult {
    pub ok: bool,
    pub device_id: String,
    pub changed: Vec<String>,
    pub unchanged: Vec<String>,
    /// Marked papers with no PDF/ePUB on this Mac: only the running imbib
    /// app can fetch one; they wait in `awaiting_source` until then.
    pub awaiting_source: Vec<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkAwaitingSourceRecord {
    pub mirror_id: String,
    pub publication_id: String,
    pub cite_key: String,
    pub title: String,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkFolderNeedRecord {
    /// e.g. `imbib/Library/Cosmology` — create these on the tablet, parents first.
    pub path: String,
    pub publications: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkSyncRecord {
    pub ok: bool,
    pub device_id: String,
    pub reachable: bool,
    pub dry_run: bool,
    pub to_upload: u32,
    pub awaiting_source: u32,
    pub awaiting_folder: u32,
    pub stale: u32,
    pub removed: u32,
    pub to_import: u32,
    pub unchanged: u32,
    pub skipped_no_source: u32,
    pub skipped_scope: u32,
    pub uploaded: Vec<String>,
    pub failed: Vec<String>,
    pub folder_checklist: Vec<EinkFolderNeedRecord>,
    pub imported: Vec<String>,
    pub pending_imports: u32,
    pub trace: Vec<String>,
    pub duration_ms: i64,
    pub error: Option<String>,
}

impl From<eink::EinkSyncReport> for EinkSyncRecord {
    fn from(r: eink::EinkSyncReport) -> Self {
        Self {
            ok: true,
            device_id: r.device_id,
            reachable: r.reachable,
            dry_run: r.dry_run,
            to_upload: r.summary.to_upload,
            awaiting_source: r.summary.awaiting_source,
            awaiting_folder: r.summary.awaiting_folder,
            stale: r.summary.stale,
            removed: r.summary.removed,
            to_import: r.summary.to_import,
            unchanged: r.summary.unchanged,
            skipped_no_source: r.summary.skipped_no_source,
            skipped_scope: r.summary.skipped_scope,
            uploaded: r.uploaded,
            failed: r.failed,
            folder_checklist: r
                .folder_needs
                .iter()
                .map(|n| EinkFolderNeedRecord {
                    path: n.display(),
                    publications: n.publications,
                })
                .collect(),
            imported: r.imports.iter().map(|i| i.publication_id.clone()).collect(),
            pending_imports: r.pending_imports,
            trace: r.trace,
            duration_ms: r.duration_ms,
            error: None,
        }
    }
}

#[impress_service]
pub trait ImbibEinkService: Send + Sync + 'static {
    /// Devices, counts (queued / on tablet / awaiting PDF / awaiting folder /
    /// stale / failed), which device puts markers on list rows, last sync.
    /// Start here before marking or syncing.
    #[impress_method]
    async fn eink_status(&self) -> EinkStatusRecord;
    /// Every configured e-ink device.
    #[impress_method]
    async fn eink_devices(&self) -> Vec<EinkDeviceRecord>;
    /// Create a device (no `id`) or change fields on one. Mode `individual`
    /// mirrors only marked papers and shows a marker in the list;
    /// `all` mirrors every paper that has a PDF/ePUB and shows no marker.
    #[impress_method]
    async fn eink_configure_device(&self, input: EinkDeviceInput) -> Option<EinkDeviceRecord>;
    /// Remove a device and its mirror rows (the tablet is untouched).
    #[impress_method]
    async fn eink_remove_device(&self, device_id: String) -> MutationResult;
    /// Mark papers to be mirrored (individual mode). Papers without a local
    /// PDF/ePUB are reported in `awaiting_source`; the running imbib app
    /// fetches those, then the next sync sends them.
    #[impress_method]
    async fn eink_mark(
        &self,
        publication_ids: Vec<String>,
        device_id: Option<String>,
    ) -> EinkMarkResult;
    /// Stop mirroring papers. A copy already on the tablet stays there
    /// (nothing can delete over USB) and imbib stops touching it.
    #[impress_method]
    async fn eink_unmark(
        &self,
        publication_ids: Vec<String>,
        device_id: Option<String>,
    ) -> EinkMarkResult;
    /// Ask for mirror rows to be sent again (a stale copy, one removed on
    /// the tablet). The next sync uploads a fresh copy.
    #[impress_method]
    async fn eink_resend(&self, mirror_ids: Vec<String>) -> MutationResult;
    /// Mirror rows for a device, optionally filtered by state.
    #[impress_method]
    async fn eink_list_mirrored(
        &self,
        device_id: Option<String>,
        state: Option<String>,
    ) -> Vec<EinkMirrorRecord>;
    /// Marked papers that still need their PDF/ePUB fetched.
    #[impress_method]
    async fn eink_awaiting_source(
        &self,
        device_id: Option<String>,
    ) -> Vec<EinkAwaitingSourceRecord>;
    /// A two-second probe: is the tablet plugged in with its USB web
    /// interface on?
    #[impress_method]
    async fn eink_reachable(&self, device_id: Option<String>) -> bool;
    /// Dry run: list the tablet and report what a sync would do, including
    /// the folders the user must create on the tablet. Writes nothing.
    #[impress_method]
    async fn eink_plan(&self, device_id: Option<String>) -> EinkSyncRecord;
    /// Sync now: upload queued papers into `imbib/<Library>/<Collection>`
    /// folders that exist on the tablet, record what changed there, and
    /// (with `import`) pull changed documents back. Needs the tablet plugged
    /// in; safe to repeat.
    #[impress_method]
    async fn eink_sync(&self, device_id: Option<String>, import: bool) -> EinkSyncRecord;
    /// The folders to create on the tablet by hand, parents first (the USB
    /// interface cannot create folders).
    #[impress_method]
    async fn eink_folder_checklist(&self, device_id: Option<String>) -> Vec<EinkFolderNeedRecord>;
}

pub struct DefaultImbibEinkService {
    store: Arc<ImbibStore>,
}

impl DefaultImbibEinkService {
    pub fn new(store: Arc<ImbibStore>) -> Self {
        Self { store }
    }
}

fn log(m: &str, e: impl std::fmt::Display) {
    eprintln!("[imbib-eink-service] {m}: {e}");
}

/// Run a blocking engine call off the async executor.
async fn blocking<T, F>(name: &'static str, f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, imbib_core::unified::store_api::StoreApiError> + Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => {
            log(name, &error);
            Err(error.to_string())
        }
        Err(error) => {
            log(name, &error);
            Err(error.to_string())
        }
    }
}

#[async_trait::async_trait]
impl ImbibEinkService for DefaultImbibEinkService {
    async fn eink_status(&self) -> EinkStatusRecord {
        match self.store.eink_status() {
            Ok(status) => EinkStatusRecord {
                ok: true,
                devices: status.devices.iter().map(EinkDeviceRecord::from).collect(),
                marker_device_id: status.marker_device_id,
                default_device_id: status.default_device_id,
                counts: EinkCountsRecord {
                    queued: status.counts.queued,
                    awaiting_source: status.counts.awaiting_source,
                    awaiting_folder: status.counts.awaiting_folder,
                    uploaded: status.counts.uploaded,
                    stale: status.counts.stale,
                    removed_on_device: status.counts.removed_on_device,
                    failed: status.counts.failed,
                    unmarked: status.counts.unmarked,
                    new_annotations: status.counts.new_annotations,
                },
                last_sync_at_ms: status.last_sync_at_ms,
                last_error: status.last_error,
                legacy_marker_rows: status.legacy_marker_rows,
                error: None,
            },
            Err(e) => {
                log("eink_status", &e);
                EinkStatusRecord {
                    error: Some(e.to_string()),
                    ..Default::default()
                }
            }
        }
    }

    async fn eink_devices(&self) -> Vec<EinkDeviceRecord> {
        self.store
            .eink_devices()
            .map(|rows| rows.iter().map(EinkDeviceRecord::from).collect())
            .unwrap_or_else(|e| {
                log("eink_devices", e);
                vec![]
            })
    }

    async fn eink_configure_device(&self, input: EinkDeviceInput) -> Option<EinkDeviceRecord> {
        self.store
            .eink_configure_device(input.into())
            .map(|row| EinkDeviceRecord::from(&row))
            .map_err(|e| log("eink_configure_device", e))
            .ok()
    }

    async fn eink_remove_device(&self, device_id: String) -> MutationResult {
        match self.store.eink_remove_device(device_id) {
            Ok(count) => MutationResult {
                affected_count: count,
                ok: true,
            },
            Err(e) => {
                log("eink_remove_device", e);
                MutationResult {
                    affected_count: 0,
                    ok: false,
                }
            }
        }
    }

    async fn eink_mark(
        &self,
        publication_ids: Vec<String>,
        device_id: Option<String>,
    ) -> EinkMarkResult {
        match self.store.eink_mark(device_id, publication_ids) {
            Ok(outcome) => EinkMarkResult {
                ok: true,
                device_id: outcome.device_id,
                changed: outcome.changed,
                unchanged: outcome.unchanged,
                awaiting_source: outcome.awaiting_source,
                error: None,
            },
            Err(e) => {
                log("eink_mark", &e);
                EinkMarkResult {
                    error: Some(e.to_string()),
                    ..Default::default()
                }
            }
        }
    }

    async fn eink_unmark(
        &self,
        publication_ids: Vec<String>,
        device_id: Option<String>,
    ) -> EinkMarkResult {
        match self.store.eink_unmark(device_id, publication_ids) {
            Ok(outcome) => EinkMarkResult {
                ok: true,
                device_id: outcome.device_id,
                changed: outcome.changed,
                unchanged: outcome.unchanged,
                awaiting_source: outcome.awaiting_source,
                error: None,
            },
            Err(e) => {
                log("eink_unmark", &e);
                EinkMarkResult {
                    error: Some(e.to_string()),
                    ..Default::default()
                }
            }
        }
    }

    async fn eink_resend(&self, mirror_ids: Vec<String>) -> MutationResult {
        match self.store.eink_resend(mirror_ids) {
            Ok(count) => MutationResult {
                affected_count: count,
                ok: true,
            },
            Err(e) => {
                log("eink_resend", e);
                MutationResult {
                    affected_count: 0,
                    ok: false,
                }
            }
        }
    }

    async fn eink_list_mirrored(
        &self,
        device_id: Option<String>,
        state: Option<String>,
    ) -> Vec<EinkMirrorRecord> {
        self.store
            .eink_list_mirrored(device_id, state)
            .map(|rows| rows.iter().map(EinkMirrorRecord::from).collect())
            .unwrap_or_else(|e| {
                log("eink_list_mirrored", e);
                vec![]
            })
    }

    async fn eink_awaiting_source(
        &self,
        device_id: Option<String>,
    ) -> Vec<EinkAwaitingSourceRecord> {
        self.store
            .eink_awaiting_source(device_id)
            .map(|rows| {
                rows.into_iter()
                    .map(|r| EinkAwaitingSourceRecord {
                        mirror_id: r.mirror_id,
                        publication_id: r.publication_id,
                        cite_key: r.cite_key,
                        title: r.title,
                        doi: r.doi,
                        arxiv_id: r.arxiv_id,
                        url: r.url,
                    })
                    .collect()
            })
            .unwrap_or_else(|e| {
                log("eink_awaiting_source", e);
                vec![]
            })
    }

    async fn eink_reachable(&self, device_id: Option<String>) -> bool {
        let store = Arc::clone(&self.store);
        blocking("eink_reachable", move || store.eink_reachable(device_id))
            .await
            .unwrap_or(false)
    }

    async fn eink_plan(&self, device_id: Option<String>) -> EinkSyncRecord {
        let store = Arc::clone(&self.store);
        match blocking("eink_plan", move || store.eink_plan(device_id)).await {
            Ok(report) => report.into(),
            Err(error) => EinkSyncRecord {
                error: Some(error),
                ..Default::default()
            },
        }
    }

    async fn eink_sync(&self, device_id: Option<String>, import: bool) -> EinkSyncRecord {
        let store = Arc::clone(&self.store);
        match blocking("eink_sync", move || store.eink_sync(device_id, import)).await {
            Ok(report) => report.into(),
            Err(error) => EinkSyncRecord {
                error: Some(error),
                ..Default::default()
            },
        }
    }

    async fn eink_folder_checklist(&self, device_id: Option<String>) -> Vec<EinkFolderNeedRecord> {
        let store = Arc::clone(&self.store);
        blocking("eink_folder_checklist", move || {
            store.eink_folder_checklist(device_id)
        })
        .await
        .map(|needs| {
            needs
                .iter()
                .map(|n| EinkFolderNeedRecord {
                    path: n.display(),
                    publications: n.publications,
                })
                .collect()
        })
        .unwrap_or_default()
    }
}

impress_service_impl! {
    service = ImbibEinkService,
    impl = DefaultImbibEinkService,
    instance = || crate::backend::eink_service_instance(),
    methods = [
        eink_status() -> EinkStatusRecord,
        eink_devices() -> Vec<EinkDeviceRecord>,
        eink_configure_device(input: EinkDeviceInput) -> Option<EinkDeviceRecord>,
        eink_remove_device(device_id: String) -> MutationResult,
        eink_mark(publication_ids: Vec<String>, device_id: Option<String>) -> EinkMarkResult,
        eink_unmark(publication_ids: Vec<String>, device_id: Option<String>) -> EinkMarkResult,
        eink_resend(mirror_ids: Vec<String>) -> MutationResult,
        eink_list_mirrored(device_id: Option<String>, state: Option<String>) -> Vec<EinkMirrorRecord>,
        eink_awaiting_source(device_id: Option<String>) -> Vec<EinkAwaitingSourceRecord>,
        eink_reachable(device_id: Option<String>) -> bool,
        eink_plan(device_id: Option<String>) -> EinkSyncRecord,
        eink_sync(device_id: Option<String>, import: bool) -> EinkSyncRecord,
        eink_folder_checklist(device_id: Option<String>) -> Vec<EinkFolderNeedRecord>,
    ],
}

#[cfg(test)]
mod tests {
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    /// Every verb reaches both generated inventories under the names the
    /// docs and the Swift automation layer use.
    #[test]
    fn all_methods_reach_both_generated_inventories() {
        let mcp: Vec<&str> = McpToolDescriptor::iter().map(|item| item.name).collect();
        let cli: Vec<&str> = CliSubcommand::iter().map(|item| item.name).collect();
        for verb in [
            "eink-status",
            "eink-devices",
            "eink-configure-device",
            "eink-remove-device",
            "eink-mark",
            "eink-unmark",
            "eink-resend",
            "eink-list-mirrored",
            "eink-awaiting-source",
            "eink-reachable",
            "eink-plan",
            "eink-sync",
            "eink-folder-checklist",
        ] {
            let mcp_name = format!("imbib-eink-service_{verb}");
            assert!(mcp.contains(&mcp_name.as_str()), "missing {mcp_name}");
            assert!(cli.contains(&verb), "missing CLI {verb}");
        }
    }

    #[test]
    fn eink_tools_describe_themselves() {
        for tool in McpToolDescriptor::iter().filter(|t| t.name.starts_with("imbib-eink-service_"))
        {
            assert!(
                !tool.description.trim().is_empty() && !tool.description.starts_with("Invoke "),
                "{} needs a real description",
                tool.name
            );
        }
    }
}
