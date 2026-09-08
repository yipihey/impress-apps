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

use crate::annotations_service::AnnotationRecord;
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
    /// When the tablet lacks the exact folder, file the paper in the deepest
    /// one on the path that does exist instead of holding it.
    pub file_in_nearest_folder: bool,
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
            file_in_nearest_folder: r.file_in_nearest_folder,
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
    /// File a paper in the nearest existing folder when the tablet lacks the
    /// exact one (it has no folder API, so the alternative is waiting).
    #[serde(default)]
    pub file_in_nearest_folder: Option<bool>,
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
            file_in_nearest_folder: i.file_in_nearest_folder,
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
    /// Set when the copy sits above where it belongs, because the tablet has
    /// no such folder and no way to be told to make one.
    pub desired_path: Option<String>,
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
            desired_path: r.desired_path.clone(),
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
    /// On the tablet, but above the folder they belong in.
    pub filed_in_nearest: u32,
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

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkUnmatchedRecord {
    pub remote_id: String,
    pub name: String,
    /// `notebook`, `pdf` or `epub`.
    pub kind: String,
    /// Folder names from the top, e.g. `imbib/Library/Cosmology`.
    pub remote_path: String,
    /// Under the device's root folder.
    pub in_imbib_tree: bool,
    /// Resolved from the folder names; `eink-import-document` needs no
    /// library when this is set.
    pub library_id: Option<String>,
    pub collection_id: Option<String>,
    pub modified_ms: i64,
    pub page_count: u32,
}

impl From<eink::EinkUnmatchedDocument> for EinkUnmatchedRecord {
    fn from(d: eink::EinkUnmatchedDocument) -> Self {
        Self {
            remote_id: d.remote_id,
            name: d.name,
            kind: d.kind,
            remote_path: d.remote_path,
            in_imbib_tree: d.in_imbib_tree,
            library_id: d.library_id,
            collection_id: d.collection_id,
            modified_ms: d.modified_ms,
            page_count: d.page_count,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkDocumentImportRecord {
    pub ok: bool,
    pub remote_id: String,
    /// `publication` or `note`.
    pub as_kind: String,
    pub publication_id: Option<String>,
    pub artifact_id: Option<String>,
    /// The bytes matched a file already in the store; that publication
    /// was adopted instead of a new one being created.
    pub adopted_existing: bool,
    pub linked_file_id: Option<String>,
    pub mirror_id: Option<String>,
    pub annotations_created: u32,
    pub annotations_updated: u32,
    pub ink_pending_ocr: u32,
    pub warnings: Vec<String>,
    pub trace: Vec<String>,
    pub error: Option<String>,
}

impl From<eink::EinkDocumentImportOutcome> for EinkDocumentImportRecord {
    fn from(o: eink::EinkDocumentImportOutcome) -> Self {
        Self {
            ok: true,
            remote_id: o.remote_id,
            as_kind: o.as_kind,
            publication_id: o.publication_id,
            artifact_id: o.artifact_id,
            adopted_existing: o.adopted_existing,
            linked_file_id: o.linked_file_id,
            mirror_id: o.mirror_id,
            annotations_created: o.annotations_created,
            annotations_updated: o.annotations_updated,
            ink_pending_ocr: o.ink_pending_ocr,
            warnings: o.warnings,
            trace: o.trace,
            error: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkOcrJobRecord {
    pub annotation_id: String,
    pub publication_id: String,
    pub linked_file_id: String,
    pub page_number: i32,
    /// Absolute path of the rendered strokes (PNG).
    pub image_path: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EinkAppendResult {
    pub ok: bool,
    /// `false` when that tablet snapshot was already in the Notes field.
    pub appended: bool,
    pub error: Option<String>,
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
    /// Uploaded into the nearest existing folder because the tablet lacks
    /// the exact one.
    pub filed_in_nearest: u32,
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
    /// Papers due for upload that an import-only pass left queued.
    pub pending_uploads: u32,
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
            filed_in_nearest: r.summary.filed_in_nearest,
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
            pending_uploads: r.pending_uploads,
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
    /// Pull annotated copies back without sending anything up. With
    /// `publication_id`, import that one paper now whether or not the
    /// tablet reports a change (after changing the import switches, say).
    #[impress_method]
    async fn eink_import(
        &self,
        publication_id: Option<String>,
        device_id: Option<String>,
    ) -> EinkSyncRecord;
    /// Documents on the tablet that imbib did not put there — notebooks
    /// written on it, files copied in by hand — with the library and
    /// collection their folder names resolve to. Needs the tablet plugged in.
    #[impress_method]
    async fn eink_list_unmatched(&self, device_id: Option<String>) -> Vec<EinkUnmatchedRecord>;
    /// Bring one such document into the store. `as_kind` `publication`
    /// (default: a notebook becomes a `@misc` entry with the rendered PDF as
    /// its file; a PDF/ePUB whose bytes match a file already here adopts
    /// that publication) or `note` (an `impress/artifact/note`). The
    /// library may be omitted for a document under `imbib/<Library>`.
    #[impress_method]
    async fn eink_import_document(
        &self,
        remote_id: String,
        library_id: Option<String>,
        collection_id: Option<String>,
        as_kind: Option<String>,
        device_id: Option<String>,
    ) -> EinkDocumentImportRecord;
    /// Every row an e-ink import wrote for a publication (highlights with
    /// their text, typed text, ink groups with OCR text), in page order.
    #[impress_method]
    async fn eink_list_annotations(&self, publication_id: String) -> Vec<AnnotationRecord>;
    /// Say how an attempt to get a paper's PDF went, so a row waiting for
    /// its source can name the reason. Only something that can download
    /// (the app, an agent) knows this; the engine never does. `error`
    /// absent clears the last one.
    #[impress_method]
    async fn eink_note_source_error(
        &self,
        publication_id: String,
        device_id: Option<String>,
        error: Option<String>,
    ) -> MutationResult;
    /// Highlight, typed and OCR text from the tablet containing `query`
    /// (case-insensitive), newest first. `limit` 0 = 100.
    #[impress_method]
    async fn eink_search_annotations(&self, query: String, limit: u32) -> Vec<AnnotationRecord>;
    /// Ink rows whose handwriting has not been recognised yet, with the
    /// PNG to run OCR on. `publication_id` absent = everywhere.
    #[impress_method]
    async fn eink_pending_ocr(&self, publication_id: Option<String>) -> Vec<EinkOcrJobRecord>;
    /// Record an OCR result. `text` absent with a confidence still closes
    /// the job (nothing legible), so it is not retried forever.
    #[impress_method]
    async fn eink_complete_ocr(
        &self,
        annotation_id: String,
        text: Option<String>,
        confidence: f64,
    ) -> MutationResult;
    /// Append the imported highlights and notes to the paper's Notes field
    /// as one dated block. A snapshot already appended is skipped unless
    /// `force`; rows that carry no text yet (handwriting awaiting
    /// recognition) are an error, not a silent no-op. Never runs on its own.
    #[impress_method]
    async fn eink_append_notes(&self, publication_id: String, force: bool) -> EinkAppendResult;
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
                    filed_in_nearest: status.counts.filed_in_nearest,
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

    async fn eink_import(
        &self,
        publication_id: Option<String>,
        device_id: Option<String>,
    ) -> EinkSyncRecord {
        let store = Arc::clone(&self.store);
        match blocking("eink_import", move || {
            store.eink_import(publication_id, device_id)
        })
        .await
        {
            Ok(report) => report.into(),
            Err(error) => EinkSyncRecord {
                error: Some(error),
                ..Default::default()
            },
        }
    }

    async fn eink_list_unmatched(&self, device_id: Option<String>) -> Vec<EinkUnmatchedRecord> {
        let store = Arc::clone(&self.store);
        blocking("eink_list_unmatched", move || {
            store.eink_list_unmatched(device_id)
        })
        .await
        .map(|docs| docs.into_iter().map(EinkUnmatchedRecord::from).collect())
        .unwrap_or_default()
    }

    async fn eink_import_document(
        &self,
        remote_id: String,
        library_id: Option<String>,
        collection_id: Option<String>,
        as_kind: Option<String>,
        device_id: Option<String>,
    ) -> EinkDocumentImportRecord {
        let store = Arc::clone(&self.store);
        let id = remote_id.clone();
        match blocking("eink_import_document", move || {
            store.eink_import_document(remote_id, library_id, collection_id, as_kind, device_id)
        })
        .await
        {
            Ok(outcome) => outcome.into(),
            Err(error) => EinkDocumentImportRecord {
                remote_id: id,
                error: Some(error),
                ..Default::default()
            },
        }
    }

    async fn eink_list_annotations(&self, publication_id: String) -> Vec<AnnotationRecord> {
        self.store
            .eink_annotations_for_publication(publication_id)
            .map(|rows| rows.iter().map(AnnotationRecord::from).collect())
            .unwrap_or_else(|e| {
                log("eink_list_annotations", e);
                vec![]
            })
    }

    async fn eink_search_annotations(&self, query: String, limit: u32) -> Vec<AnnotationRecord> {
        self.store
            .eink_search_annotations(query, limit)
            .map(|rows| rows.iter().map(AnnotationRecord::from).collect())
            .unwrap_or_else(|e| {
                log("eink_search_annotations", e);
                vec![]
            })
    }

    async fn eink_pending_ocr(&self, publication_id: Option<String>) -> Vec<EinkOcrJobRecord> {
        self.store
            .eink_pending_ocr(publication_id)
            .map(|jobs| {
                jobs.into_iter()
                    .map(|j| EinkOcrJobRecord {
                        annotation_id: j.annotation_id,
                        publication_id: j.publication_id,
                        linked_file_id: j.linked_file_id,
                        page_number: j.page_number,
                        image_path: j.image_path,
                    })
                    .collect()
            })
            .unwrap_or_else(|e| {
                log("eink_pending_ocr", e);
                vec![]
            })
    }

    async fn eink_note_source_error(
        &self,
        publication_id: String,
        device_id: Option<String>,
        error: Option<String>,
    ) -> MutationResult {
        match self
            .store
            .eink_note_source_attempt(device_id, publication_id, error)
        {
            Ok(changed) => MutationResult {
                affected_count: u32::from(changed),
                ok: true,
            },
            Err(e) => {
                log("eink_note_source_error", e);
                MutationResult {
                    affected_count: 0,
                    ok: false,
                }
            }
        }
    }

    async fn eink_complete_ocr(
        &self,
        annotation_id: String,
        text: Option<String>,
        confidence: f64,
    ) -> MutationResult {
        match self
            .store
            .eink_complete_ocr(annotation_id, text, confidence)
        {
            Ok(()) => MutationResult {
                affected_count: 1,
                ok: true,
            },
            Err(e) => {
                log("eink_complete_ocr", e);
                MutationResult {
                    affected_count: 0,
                    ok: false,
                }
            }
        }
    }

    async fn eink_append_notes(&self, publication_id: String, force: bool) -> EinkAppendResult {
        match self.store.eink_append_notes(publication_id, force) {
            Ok(appended) => EinkAppendResult {
                ok: true,
                appended,
                error: None,
            },
            Err(e) => {
                log("eink_append_notes", &e);
                EinkAppendResult {
                    ok: false,
                    appended: false,
                    error: Some(e.to_string()),
                }
            }
        }
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
        eink_import(publication_id: Option<String>, device_id: Option<String>) -> EinkSyncRecord,
        eink_list_unmatched(device_id: Option<String>) -> Vec<EinkUnmatchedRecord>,
        eink_import_document(remote_id: String, library_id: Option<String>, collection_id: Option<String>, as_kind: Option<String>, device_id: Option<String>) -> EinkDocumentImportRecord,
        eink_list_annotations(publication_id: String) -> Vec<AnnotationRecord>,
        eink_note_source_error(publication_id: String, device_id: Option<String>, error: Option<String>) -> MutationResult,
        eink_search_annotations(query: String, limit: u32) -> Vec<AnnotationRecord>,
        eink_pending_ocr(publication_id: Option<String>) -> Vec<EinkOcrJobRecord>,
        eink_complete_ocr(annotation_id: String, text: Option<String>, confidence: f64) -> MutationResult,
        eink_append_notes(publication_id: String, force: bool) -> EinkAppendResult,
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
            "eink-import",
            "eink-list-unmatched",
            "eink-import-document",
            "eink-list-annotations",
            "eink-note-source-error",
            "eink-search-annotations",
            "eink-pending-ocr",
            "eink-complete-ocr",
            "eink-append-notes",
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
