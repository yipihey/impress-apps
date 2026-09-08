//! Run a sync: read the tablet, gather the papers, plan, execute, stamp.
//!
//! Every action's outcome is written to the mirror rows as it happens, so
//! a sync that dies half-way leaves a true picture; the report carries the
//! three-point trace (what was planned, what was written, what a list row
//! will now show) for the caller's log.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use chrono::Utc;
use impress_core::item::Value;
use impress_core::store::ItemStore;
use impress_remarkable::rmdoc::{build_rmdoc, RmdocKind, RmdocSpec, SourceKind};
use impress_remarkable::{DocumentKind, DownloadKind, RemarkableDocument};
use uuid::Uuid;

use super::collections::CollectionIndex;
use super::config::{EinkDeviceConfig, MirrorMode, MirrorState, UploadFormat};
use super::folders::{FolderMap, FolderNeed};
use super::naming::NameInputs;
use super::paths;
use super::planner::{self, Candidate, LocalSource, PlanAction, PlanInputs, PlanSummary, SyncPlan};
use super::store::EinkMirrorRow;
use super::transport::{EinkError, EinkTransport};
use crate::unified::shaped_queries::BibliographyRow;
use crate::unified::store_api::{ImbibStore, StoreApiError};

/// A sync that holds the device row for longer than this is presumed dead.
const LOCK_STALE_MS: i64 = 10 * 60 * 1000;

#[derive(Debug, Clone)]
pub struct SyncOptions {
    /// Plan and report, touch nothing (the tablet is still listed).
    pub dry_run: bool,
    /// Send queued papers and create folders (`false` = an import-only
    /// pass: bookkeeping and downloads, nothing goes up).
    pub upload: bool,
    /// Pull changed documents back through the import sink.
    pub import: bool,
    /// Where downloads land instead of `<library dir>/EInk/<remote id>/`
    /// (tests, and callers that keep their own cache).
    pub download_root: Option<PathBuf>,
}

impl Default for SyncOptions {
    fn default() -> Self {
        Self {
            dry_run: false,
            upload: true,
            import: false,
            download_root: None,
        }
    }
}

/// What an import wrote for one document.
#[derive(Debug, Clone, Default, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ImportOutcome {
    pub annotated_file_id: Option<String>,
    /// Set when the import refreshed the primary file itself (a notebook
    /// the tablet authored); the mirror row's `uploaded_sha256` follows it.
    pub primary_sha256: Option<String>,
    pub created: u32,
    pub updated: u32,
    pub deleted: u32,
    pub ink_pending_ocr: u32,
    pub warnings: Vec<String>,
}

/// Everything the import side needs about one changed document.
#[derive(Debug, Clone)]
pub struct ImportHandoff {
    pub device: EinkDeviceConfig,
    pub mirror_id: String,
    pub publication_id: String,
    pub library_id: Option<String>,
    pub library_dir: PathBuf,
    pub source_linked_file_id: Option<String>,
    pub remote_id: String,
    pub remote_name: String,
    pub remote_modified_ms: i64,
    pub annotated_pdf: PathBuf,
    pub rmdoc: Option<PathBuf>,
}

/// The import side of the engine (annotated variant, highlights, notes).
/// `NoopSink` records nothing beyond the downloads.
pub trait EinkImportSink: Send + Sync {
    fn ingest(
        &self,
        store: &ImbibStore,
        handoff: &ImportHandoff,
    ) -> Result<ImportOutcome, EinkError>;
}

pub struct NoopSink;

impl EinkImportSink for NoopSink {
    fn ingest(
        &self,
        _store: &ImbibStore,
        _handoff: &ImportHandoff,
    ) -> Result<ImportOutcome, EinkError> {
        Ok(ImportOutcome::default())
    }
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ImportedDocument {
    pub publication_id: String,
    pub remote_id: String,
    pub annotated_pdf: String,
    pub rmdoc: Option<String>,
    pub annotated_file_id: Option<String>,
    pub created: u32,
    pub updated: u32,
    pub deleted: u32,
    pub ink_pending_ocr: u32,
}

/// What a sync did.
#[derive(Debug, Clone, Default, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkSyncReport {
    pub device_id: String,
    pub reachable: bool,
    pub dry_run: bool,
    pub summary: PlanSummary,
    /// Publications sent this run.
    pub uploaded: Vec<String>,
    /// Publications whose upload failed (`last_error` on the row says why).
    pub failed: Vec<String>,
    pub folder_needs: Vec<FolderNeed>,
    pub folders_created: Vec<String>,
    pub imports: Vec<ImportedDocument>,
    /// Documents with new annotations that were not imported this run.
    pub pending_imports: u32,
    /// Papers due for upload that an import-only pass left queued.
    pub pending_uploads: u32,
    pub trace: Vec<String>,
    pub duration_ms: i64,
}

/// The dry-run view: the plan plus what it was computed from.
pub struct Prepared {
    pub device: EinkDeviceConfig,
    pub plan: SyncPlan,
    pub folders: FolderMap,
    pub remote_docs: Vec<RemarkableDocument>,
    pub root_id: Option<String>,
    pub trace: Vec<String>,
}

fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

/// One sync at a time per device inside this process (a second caller
/// waits its turn); the device row's `sync_started_at_ms` extends that
/// across processes.
fn device_lock(device_id: &str) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();
    let locks = LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
    locks
        .lock()
        .unwrap()
        .entry(device_id.to_string())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

pub(crate) fn resolve_device(
    store: &ImbibStore,
    device_id: Option<&str>,
) -> Result<EinkDeviceConfig, EinkError> {
    match device_id {
        Some(id) => store
            .eink_device_config(id)?
            .ok_or_else(|| EinkError::Invalid(format!("no e-ink device {id}"))),
        None => store
            .eink_default_device_config()?
            .ok_or(EinkError::NoDevice),
    }
}

/// Walk the whole tablet: every folder (for path resolution) and every
/// document, wherever it sits. The planner needs all of them — a mirrored
/// paper the user moved out of the `imbib` tree is still on the tablet,
/// and a document imbib never sent may need to be offered for import — and
/// the tablet has tens of folders, not thousands, so one listing per folder
/// is cheap over USB. Also returns the id of the root folder, if present.
pub(crate) fn walk_tablet(
    transport: &dyn EinkTransport,
    root_name: &str,
    trace: &mut Vec<String>,
) -> Result<(FolderMap, Vec<RemarkableDocument>, Option<String>), EinkError> {
    let top = transport.list_folder(None)?;
    let mut folders = FolderMap::from_entries(&top);
    let root = top
        .iter()
        .find(|e| e.kind == DocumentKind::Folder && e.visible_name.trim() == root_name.trim())
        .or_else(|| {
            top.iter().find(|e| {
                e.kind == DocumentKind::Folder
                    && e.visible_name.trim().eq_ignore_ascii_case(root_name.trim())
            })
        })
        .map(|e| e.id.clone());
    let mut documents: Vec<RemarkableDocument> = Vec::new();
    let mut queue: Vec<String> = Vec::new();
    for entry in top {
        match entry.kind {
            DocumentKind::Folder => queue.push(entry.id),
            DocumentKind::Document => documents.push(entry),
            DocumentKind::Unknown => {}
        }
    }
    let mut seen: HashSet<String> = HashSet::new();
    while let Some(folder) = queue.pop() {
        if !seen.insert(folder.clone()) {
            continue;
        }
        let entries = transport.list_folder(Some(&folder))?;
        for entry in entries {
            match entry.kind {
                DocumentKind::Folder => {
                    folders.insert(&entry.id, &entry.parent, &entry.visible_name);
                    queue.push(entry.id.clone());
                }
                DocumentKind::Document => documents.push(entry),
                DocumentKind::Unknown => {}
            }
        }
    }
    match &root {
        Some(root_id) => {
            let under_root = documents
                .iter()
                .filter(|d| {
                    folders
                        .path_of(&d.parent)
                        .first()
                        .map(|top| top.eq_ignore_ascii_case(root_name.trim()))
                        .unwrap_or(false)
                })
                .count();
            trace.push(format!(
                "tablet: root folder {root_name:?} = {root_id}; {} folders and {} documents in all, {under_root} under the root",
                folders.len(),
                documents.len()
            ));
        }
        None => trace.push(format!(
            "tablet: no top-level folder named {root_name:?} ({} folders, {} documents elsewhere)",
            folders.len(),
            documents.len()
        )),
    }
    Ok((folders, documents, root))
}

fn local_source_for(
    store: &ImbibStore,
    publication_id: &str,
) -> Result<Option<LocalSource>, EinkError> {
    let Some(source) = store.eink_local_source(publication_id.to_string())? else {
        return Ok(None);
    };
    let Some(path) = store.resolve_linked_file(source.linked_file_id.clone())? else {
        return Ok(None);
    };
    let path = PathBuf::from(path);
    let size = std::fs::metadata(&path)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    Ok(Some(LocalSource {
        linked_file_id: source.linked_file_id,
        kind: if source.kind == "epub" {
            SourceKind::Epub
        } else {
            SourceKind::Pdf
        },
        filename: source.filename,
        path,
        sha256: source.sha256,
        size,
    }))
}

fn candidate_from_row(
    store: &ImbibStore,
    index: &CollectionIndex,
    row: &BibliographyRow,
    library_id: Option<&str>,
    mirror: Option<EinkMirrorRow>,
) -> Result<Candidate, EinkError> {
    let collection_ids = store.eink_collection_ids_for(&row.id)?;
    let library_id = match library_id {
        Some(id) => Some(id.to_string()),
        None => {
            let uuid = Uuid::parse_str(&row.id).map_err(|e| EinkError::Invalid(e.to_string()))?;
            store
                .store
                .get(uuid)
                .map_err(StoreApiError::from)?
                .and_then(|item| item.parent.map(|p| p.to_string()))
        }
    };
    Ok(Candidate {
        publication_id: row.id.clone(),
        name: NameInputs::from_display(&row.cite_key, &row.author_string, row.year, &row.title),
        source: local_source_for(store, &row.id)?,
        collection_paths: index.paths_for(&collection_ids),
        library_name: library_id
            .as_deref()
            .and_then(|id| index.library_name(id))
            .map(String::from),
        library_is_inbox: library_id
            .as_deref()
            .map(|id| index.library_is_inbox(id))
            .unwrap_or(false),
        mirror,
    })
}

/// The papers this sync looks at: every marked row in individual mode,
/// every publication of every library (inbox excluded unless asked) in
/// mirror-all mode — plus, in that mode, every existing row.
fn gather_candidates(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    trace: &mut Vec<String>,
) -> Result<Vec<Candidate>, EinkError> {
    let index = CollectionIndex::load(store)?;
    let rows = store.eink_mirror_rows(&device.id)?;
    let mut by_publication: HashMap<String, EinkMirrorRow> = rows
        .into_iter()
        .map(|row| (row.publication_id.clone(), row))
        .collect();
    let mut candidates = Vec::new();
    match device.mirror_mode {
        MirrorMode::Individual => {
            for (publication_id, mirror) in by_publication.drain() {
                let Some(row) = store.get_publication(publication_id.clone())? else {
                    continue;
                };
                candidates.push(candidate_from_row(store, &index, &row, None, Some(mirror))?);
            }
        }
        MirrorMode::All => {
            let mut seen: HashSet<String> = HashSet::new();
            for library in store.list_libraries()? {
                if library.is_inbox && !device.include_inbox {
                    continue;
                }
                let rows = store.query_publications(
                    library.id.clone(),
                    "title".into(),
                    true,
                    None,
                    None,
                )?;
                for row in rows {
                    if !seen.insert(row.id.clone()) {
                        continue;
                    }
                    let mirror = by_publication.remove(&row.id);
                    candidates.push(candidate_from_row(
                        store,
                        &index,
                        &row,
                        Some(&library.id),
                        mirror,
                    )?);
                }
            }
            for (publication_id, mirror) in by_publication.drain() {
                if seen.contains(&publication_id) {
                    continue;
                }
                let Some(row) = store.get_publication(publication_id.clone())? else {
                    continue;
                };
                candidates.push(candidate_from_row(store, &index, &row, None, Some(mirror))?);
            }
        }
    }
    trace.push(format!(
        "plan: {} candidate(s) in {} mode",
        candidates.len(),
        device.mirror_mode.as_str()
    ));
    Ok(candidates)
}

/// Everything up to (not including) execution.
pub fn prepare(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    transport: &dyn EinkTransport,
) -> Result<Prepared, EinkError> {
    let mut trace = Vec::new();
    let (folders, remote_docs, root_id) =
        walk_tablet(transport, &device.root_folder_name, &mut trace)?;
    let candidates = gather_candidates(store, device, &mut trace)?;
    let plan = planner::plan(PlanInputs {
        device,
        folders: &folders,
        remote_docs: &remote_docs,
        candidates,
    });
    trace.push(format!(
        "plan: upload {} · awaiting source {} · awaiting folder {} · stale {} · removed {} · import {} · unchanged {} · skipped (no source) {} · skipped (scope) {} · folders to create {}",
        plan.summary.to_upload,
        plan.summary.awaiting_source,
        plan.summary.awaiting_folder,
        plan.summary.stale,
        plan.summary.removed,
        plan.summary.to_import,
        plan.summary.unchanged,
        plan.summary.skipped_no_source,
        plan.summary.skipped_scope,
        plan.summary.folders_to_create
    ));
    Ok(Prepared {
        device: device.clone(),
        plan,
        folders,
        remote_docs,
        root_id,
        trace,
    })
}

fn state_value(state: MirrorState) -> Value {
    Value::String(state.as_str().into())
}

fn record_failure(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    publication_id: &str,
    mirror_id: Option<&str>,
    message: &str,
) -> Result<(), StoreApiError> {
    let now = now_ms();
    match mirror_id {
        Some(id) => {
            let attempts = store
                .eink_mirror_rows(&device.id)?
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.attempts)
                .unwrap_or(0);
            store.eink_update_mirror(
                id,
                vec![
                    ("state", Some(state_value(MirrorState::Failed))),
                    ("last_error", Some(Value::String(message.into()))),
                    ("attempts", Some(Value::Int(attempts + 1))),
                    ("last_attempt_ms", Some(Value::Int(now))),
                ],
            )
        }
        None => store
            .eink_insert_mirror(
                &device.id,
                publication_id,
                false,
                MirrorState::Failed,
                vec![
                    ("last_error", Value::String(message.into())),
                    ("attempts", Value::Int(1)),
                    ("last_attempt_ms", Value::Int(now)),
                ],
            )
            .map(|_| ()),
    }
}

/// Create one folder through an archive upload and register it.
fn ensure_folder(
    transport: &dyn EinkTransport,
    folders: &mut FolderMap,
    path: &[String],
) -> Result<String, EinkError> {
    if let Ok(id) = folders.resolve(path) {
        return Ok(id);
    }
    let (parent_path, name) = path.split_at(path.len() - 1);
    let parent_id = if parent_path.is_empty() {
        String::new()
    } else {
        folders
            .resolve(parent_path)
            .map_err(|_| EinkError::Invalid(format!("parent of {} is missing", path.join("/"))))?
    };
    let name = &name[0];
    let id = Uuid::new_v4().to_string();
    let spec = RmdocSpec {
        id: id.clone(),
        visible_name: name.clone(),
        parent: parent_id.clone(),
        last_modified_ms: now_ms(),
        kind: RmdocKind::Folder,
        page_count: None,
        page_files: Vec::new(),
    };
    let bytes = build_rmdoc(&spec)?;
    let dir = std::env::temp_dir().join("imbib-eink");
    std::fs::create_dir_all(&dir).map_err(|e| EinkError::Io(e.to_string()))?;
    let file = dir.join(format!("{id}.rmdoc"));
    std::fs::write(&file, bytes).map_err(|e| EinkError::Io(e.to_string()))?;
    let receipt = transport.upload_into(
        (!parent_id.is_empty()).then_some(parent_id.as_str()),
        &file,
        &format!("{name}.rmdoc"),
    );
    let _ = std::fs::remove_file(&file);
    receipt?;
    // Trust the listing, not the archive: find the folder by name.
    let listed = transport.list_folder((!parent_id.is_empty()).then_some(parent_id.as_str()))?;
    let created = listed
        .iter()
        .find(|e| e.kind == DocumentKind::Folder && e.visible_name.trim() == name.trim())
        .ok_or_else(|| {
            EinkError::Transport(format!(
                "the tablet accepted the folder archive for {} but lists no such folder — the firmware does not create folders this way; switch the device to the checklist strategy",
                path.join("/")
            ))
        })?;
    folders.insert(&created.id, &parent_id, name);
    Ok(created.id.clone())
}

/// Build a reMarkable archive around a source file; the tablet takes the
/// name from the archive rather than the filename.
fn wrap_as_archive(
    source: &LocalSource,
    visible_name: &str,
    folder_id: &str,
) -> Result<PathBuf, EinkError> {
    let bytes = std::fs::read(&source.path).map_err(|e| EinkError::Io(e.to_string()))?;
    let spec = RmdocSpec {
        id: Uuid::new_v4().to_string(),
        visible_name: visible_name.to_string(),
        parent: folder_id.to_string(),
        last_modified_ms: now_ms(),
        kind: RmdocKind::Document {
            kind: source.kind,
            source: bytes,
        },
        page_count: None,
        page_files: Vec::new(),
    };
    let archive = build_rmdoc(&spec)?;
    let dir = std::env::temp_dir().join("imbib-eink");
    std::fs::create_dir_all(&dir).map_err(|e| EinkError::Io(e.to_string()))?;
    let path = dir.join(format!("{}.rmdoc", spec.id));
    std::fs::write(&path, archive).map_err(|e| EinkError::Io(e.to_string()))?;
    Ok(path)
}

/// The library folder a download for this publication belongs in.
fn library_dir_for(
    store: &ImbibStore,
    publication_id: &str,
) -> Result<(Option<String>, PathBuf), EinkError> {
    let home = paths::user_home().ok_or_else(|| EinkError::Io("no HOME".into()))?;
    let uuid = Uuid::parse_str(publication_id).map_err(|e| EinkError::Invalid(e.to_string()))?;
    let library_id = store
        .store
        .get(uuid)
        .map_err(StoreApiError::from)?
        .and_then(|item| item.parent.map(|p| p.to_string()));
    let dir = match &library_id {
        Some(id) => paths::library_dir_for_write(id, &home),
        None => home.join("Library/Application Support/imbib/Libraries/Unfiled"),
    };
    Ok((library_id, dir))
}

/// Run a sync end to end.
pub fn run_sync(
    store: &ImbibStore,
    device_id: Option<&str>,
    transport: &dyn EinkTransport,
    sink: &dyn EinkImportSink,
    options: SyncOptions,
) -> Result<EinkSyncReport, EinkError> {
    let started = Instant::now();
    let device = resolve_device(store, device_id)?;
    let mut report = EinkSyncReport {
        device_id: device.id.clone(),
        dry_run: options.dry_run,
        ..Default::default()
    };
    if !transport.reachable() {
        report.trace.push(format!(
            "tablet at {} is not reachable; nothing to do",
            device.base_url
        ));
        report.duration_ms = started.elapsed().as_millis() as i64;
        return Ok(report);
    }
    report.reachable = true;

    let lock = device_lock(&device.id);
    let _guard = lock.lock().map_err(|_| {
        EinkError::Locked("a previous sync panicked while holding the device".into())
    })?;
    let now = now_ms();
    if !options.dry_run {
        if let Some(started_at) = device.sync_started_at_ms {
            if now - started_at < LOCK_STALE_MS {
                return Err(EinkError::Locked(format!(
                    "another process started a sync {} s ago",
                    (now - started_at) / 1000
                )));
            }
        }
        store.eink_update_device(
            &device.id,
            vec![("sync_started_at_ms", Some(Value::Int(now)))],
        )?;
    }

    let outcome = execute(store, &device, transport, sink, &options, &mut report);

    if !options.dry_run {
        let mut stamps: Vec<(&str, Option<Value>)> = vec![
            ("sync_started_at_ms", None),
            ("last_seen_at_ms", Some(Value::Int(now_ms()))),
        ];
        match &outcome {
            Ok(()) => {
                stamps.push(("last_sync_at_ms", Some(Value::Int(now_ms()))));
                stamps.push(("last_error", None));
            }
            Err(error) => stamps.push(("last_error", Some(Value::String(error.to_string())))),
        }
        store.eink_update_device(&device.id, stamps)?;
    }
    outcome?;
    report.duration_ms = started.elapsed().as_millis() as i64;
    Ok(report)
}

fn execute(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    transport: &dyn EinkTransport,
    sink: &dyn EinkImportSink,
    options: &SyncOptions,
    report: &mut EinkSyncReport,
) -> Result<(), EinkError> {
    let mut prepared = prepare(store, device, transport)?;
    report.trace.append(&mut prepared.trace);
    report.summary = prepared.plan.summary.clone();
    report.folder_needs = prepared.plan.folder_needs.clone();
    if !report.folder_needs.is_empty() {
        report.trace.push(format!(
            "folders to create on the tablet: {}",
            report
                .folder_needs
                .iter()
                .map(FolderNeed::display)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if options.dry_run {
        report.trace.push("dry run: nothing written".into());
        return Ok(());
    }

    let mut folders = prepared.folders;
    let mut rows_written = 0u32;
    for action in prepared.plan.actions {
        match action {
            PlanAction::Skip { .. } => {}
            PlanAction::EnsureFolder { path } if !options.upload => {
                report.trace.push(format!(
                    "import-only pass: folder {} not created",
                    path.join("/")
                ));
            }
            PlanAction::Upload { publication_id, .. } if !options.upload => {
                report.pending_uploads += 1;
                report.trace.push(format!(
                    "import-only pass: upload of {publication_id} left queued"
                ));
            }
            PlanAction::EnsureFolder { path } => {
                match ensure_folder(transport, &mut folders, &path) {
                    Ok(id) => {
                        report
                            .trace
                            .push(format!("folder created: {} = {id}", path.join("/")));
                        report.folders_created.push(path.join("/"));
                    }
                    Err(error) => {
                        report
                            .trace
                            .push(format!("folder {} not created: {error}", path.join("/")));
                        // Uploads below this path will fail to resolve and be
                        // recorded per row.
                    }
                }
            }
            PlanAction::Hold {
                publication_id,
                mirror_id,
                state,
                reason,
            } => {
                match mirror_id {
                    Some(id) => store.eink_update_mirror(
                        &id,
                        vec![
                            ("state", Some(state_value(state))),
                            ("last_error", Some(Value::String(reason.clone()))),
                        ],
                    )?,
                    None => {
                        if device.mirror_mode == MirrorMode::Individual {
                            store.eink_insert_mirror(
                                &device.id,
                                &publication_id,
                                true,
                                state,
                                vec![("last_error", Value::String(reason.clone()))],
                            )?;
                        }
                    }
                }
                rows_written += 1;
                report.trace.push(format!(
                    "hold {publication_id}: {} ({reason})",
                    state.as_str()
                ));
            }
            PlanAction::Update {
                mirror_id,
                publication_id,
                state,
                fields,
                reason,
            } => {
                let mut updates: Vec<(&str, Option<Value>)> = Vec::new();
                let owned: Vec<(String, Value)> = fields;
                for (key, value) in &owned {
                    updates.push((key.as_str(), Some(value.clone())));
                }
                if let Some(state) = state {
                    updates.push(("state", Some(state_value(state))));
                }
                store.eink_update_mirror(&mirror_id, updates)?;
                rows_written += 1;
                report.trace.push(format!(
                    "update {publication_id}: {}{} ({reason})",
                    state.map(|s| s.as_str()).unwrap_or("fields"),
                    if owned.is_empty() {
                        String::new()
                    } else {
                        format!(" +{}", owned.len())
                    }
                ));
            }
            PlanAction::Upload {
                publication_id,
                mirror_id,
                source,
                target_path,
                visible_name,
                upload_name,
                previous_remote_id,
            } => {
                let folder_id = match folders.resolve(&target_path) {
                    Ok(id) => id,
                    Err(_) => {
                        let message = format!(
                            "folder {} does not exist on the tablet",
                            target_path.join("/")
                        );
                        report
                            .trace
                            .push(format!("upload {publication_id}: {message}"));
                        // Not a failure of the paper: park it.
                        match &mirror_id {
                            Some(id) => store.eink_update_mirror(
                                id,
                                vec![
                                    ("state", Some(state_value(MirrorState::AwaitingFolder))),
                                    ("last_error", Some(Value::String(message))),
                                ],
                            )?,
                            None => {
                                if device.mirror_mode == MirrorMode::Individual {
                                    store.eink_insert_mirror(
                                        &device.id,
                                        &publication_id,
                                        true,
                                        MirrorState::AwaitingFolder,
                                        vec![("last_error", Value::String(message))],
                                    )?;
                                }
                            }
                        }
                        report.summary.awaiting_folder += 1;
                        continue;
                    }
                };
                let sha = match &source.sha256 {
                    Some(sha) => sha.clone(),
                    None => match paths::sha256_file(&source.path) {
                        Ok(sha) => sha,
                        Err(error) => {
                            let message =
                                format!("source unreadable ({}): {error}", source.path.display());
                            record_failure(
                                store,
                                device,
                                &publication_id,
                                mirror_id.as_deref(),
                                &message,
                            )?;
                            report.failed.push(publication_id.clone());
                            report
                                .trace
                                .push(format!("upload {publication_id}: {message}"));
                            continue;
                        }
                    },
                };
                // Wrap the file in an archive so the tablet keeps the exact
                // name (a bare upload is shown as `<name>.pdf`).
                let (upload_path, upload_name, wrapped) = match device.upload_format {
                    UploadFormat::Rmdoc => {
                        match wrap_as_archive(&source, &visible_name, &folder_id) {
                            Ok(path) => (path, format!("{visible_name}.rmdoc"), true),
                            Err(error) => {
                                report.trace.push(format!(
                                "upload {publication_id}: could not build an archive ({error}); sending the bare file"
                            ));
                                (source.path.clone(), upload_name.clone(), false)
                            }
                        }
                    }
                    UploadFormat::Pdf => (source.path.clone(), upload_name.clone(), false),
                };
                report.trace.push(format!(
                    "upload {publication_id}: {upload_name:?} → {} ({} bytes)",
                    target_path.join("/"),
                    source.size
                ));
                let sent = transport.upload_into(Some(&folder_id), &upload_path, &upload_name);
                if wrapped {
                    let _ = std::fs::remove_file(&upload_path);
                }
                match sent {
                    Ok(receipt) => {
                        let now = now_ms();
                        let mut fields: Vec<(&str, Option<Value>)> = vec![
                            ("state", Some(state_value(MirrorState::Uploaded))),
                            (
                                "linked_file_id",
                                Some(Value::String(source.linked_file_id.clone())),
                            ),
                            (
                                "source_kind",
                                Some(Value::String(source.kind.extension().into())),
                            ),
                            ("remote_parent_id", Some(Value::String(folder_id.clone()))),
                            ("remote_name", Some(Value::String(visible_name.clone()))),
                            ("remote_path", Some(Value::String(target_path.join("/")))),
                            ("uploaded_sha256", Some(Value::String(sha))),
                            ("uploaded_size", Some(Value::Int(source.size))),
                            ("uploaded_at_ms", Some(Value::Int(now))),
                            ("last_attempt_ms", Some(Value::Int(now))),
                            ("last_error", None),
                            ("resend", Some(Value::Bool(false))),
                            ("imported_modified_ms", None),
                            ("annotated_file_id", None),
                        ];
                        match &receipt.id {
                            Some(id) => fields.push(("remote_id", Some(Value::String(id.clone())))),
                            None => fields.push(("remote_id", None)),
                        }
                        if let Some(previous) = &previous_remote_id {
                            fields.push((
                                "superseded_remote_id",
                                Some(Value::String(previous.clone())),
                            ));
                        }
                        match &mirror_id {
                            Some(id) => store.eink_update_mirror(id, fields)?,
                            None => {
                                let owned: Vec<(&str, Value)> = fields
                                    .into_iter()
                                    .filter_map(|(k, v)| v.map(|v| (k, v)))
                                    .collect();
                                store.eink_insert_mirror(
                                    &device.id,
                                    &publication_id,
                                    device.mirror_mode == MirrorMode::Individual,
                                    MirrorState::Uploaded,
                                    owned,
                                )?;
                            }
                        }
                        rows_written += 1;
                        report.uploaded.push(publication_id.clone());
                        report.trace.push(format!(
                            "uploaded {publication_id}: id {}",
                            receipt
                                .id
                                .as_deref()
                                .unwrap_or("(not found in listing yet)")
                        ));
                    }
                    Err(error) => {
                        let message = error.to_string();
                        record_failure(
                            store,
                            device,
                            &publication_id,
                            mirror_id.as_deref(),
                            &message,
                        )?;
                        rows_written += 1;
                        report.failed.push(publication_id.clone());
                        report
                            .trace
                            .push(format!("upload {publication_id} failed: {message}"));
                    }
                }
            }
            PlanAction::Import {
                mirror_id,
                publication_id,
                remote_id,
                remote_name,
                remote_modified_ms,
            } => {
                if !options.import {
                    report.pending_imports += 1;
                    continue;
                }
                match import_one(
                    store,
                    device,
                    transport,
                    sink,
                    options.download_root.as_deref(),
                    &mirror_id,
                    &publication_id,
                    &remote_id,
                    &remote_name,
                    remote_modified_ms,
                ) {
                    Ok(imported) => {
                        rows_written += 1;
                        report.trace.push(format!(
                            "imported {publication_id}: {} (+{} ~{} -{} rows, {} ink pending OCR)",
                            imported.annotated_pdf,
                            imported.created,
                            imported.updated,
                            imported.deleted,
                            imported.ink_pending_ocr
                        ));
                        report.imports.push(imported);
                    }
                    Err(error) => {
                        report
                            .trace
                            .push(format!("import {publication_id} failed: {error}"));
                        store.eink_update_mirror(
                            &mirror_id,
                            vec![(
                                "last_error",
                                Some(Value::String(format!("import failed: {error}"))),
                            )],
                        )?;
                    }
                }
            }
        }
    }
    report
        .trace
        .push(format!("save: {rows_written} mirror row(s) written"));
    let visible = store.eink_row_states(Some(device.id.clone()))?;
    report.trace.push(format!(
        "display: {} row(s) carry a marker state for device {}",
        visible.len(),
        device.id
    ));
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn import_one(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    transport: &dyn EinkTransport,
    sink: &dyn EinkImportSink,
    download_root: Option<&Path>,
    mirror_id: &str,
    publication_id: &str,
    remote_id: &str,
    remote_name: &str,
    remote_modified_ms: i64,
) -> Result<ImportedDocument, EinkError> {
    let (library_id, library_dir) = match download_root {
        Some(root) => (None, root.to_path_buf()),
        None => library_dir_for(store, publication_id)?,
    };
    let dest = download_dir(&library_dir, remote_id);
    let annotated_pdf = transport.download(remote_id, DownloadKind::Pdf, &dest)?;
    let rmdoc = if device.import_rmdoc {
        transport
            .download(remote_id, DownloadKind::Rmdoc, &dest)
            .ok()
    } else {
        None
    };
    let source_linked_file_id = store
        .eink_local_source(publication_id.to_string())?
        .map(|s| s.linked_file_id);
    let handoff = ImportHandoff {
        device: device.clone(),
        mirror_id: mirror_id.to_string(),
        publication_id: publication_id.to_string(),
        library_id,
        library_dir,
        source_linked_file_id,
        remote_id: remote_id.to_string(),
        remote_name: remote_name.to_string(),
        remote_modified_ms,
        annotated_pdf: annotated_pdf.clone(),
        rmdoc: rmdoc.clone(),
    };
    let outcome = sink.ingest(store, &handoff)?;
    let mut fields: Vec<(&str, Option<Value>)> = vec![
        ("imported_modified_ms", Some(Value::Int(remote_modified_ms))),
        ("remote_modified_ms", Some(Value::Int(remote_modified_ms))),
        ("last_error", None),
    ];
    if let Some(id) = &outcome.annotated_file_id {
        fields.push(("annotated_file_id", Some(Value::String(id.clone()))));
    }
    if let Some(sha) = &outcome.primary_sha256 {
        fields.push(("uploaded_sha256", Some(Value::String(sha.clone()))));
    }
    store.eink_update_mirror(mirror_id, fields)?;
    Ok(ImportedDocument {
        publication_id: publication_id.to_string(),
        remote_id: remote_id.to_string(),
        annotated_pdf: annotated_pdf.display().to_string(),
        rmdoc: rmdoc.map(|p| p.display().to_string()),
        annotated_file_id: outcome.annotated_file_id,
        created: outcome.created,
        updated: outcome.updated,
        deleted: outcome.deleted,
        ink_pending_ocr: outcome.ink_pending_ocr,
    })
}

/// Import one mirrored paper now, regardless of whether the tablet reports
/// a change since the last import. The row must be on the tablet
/// (`uploaded` or `stale` with a remote id); the listing of its folder
/// supplies the current name and modification time.
pub fn import_publication(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    transport: &dyn EinkTransport,
    sink: &dyn EinkImportSink,
    publication_id: &str,
    download_root: Option<&Path>,
) -> Result<EinkSyncReport, EinkError> {
    let started = Instant::now();
    let mut report = EinkSyncReport {
        device_id: device.id.clone(),
        ..Default::default()
    };
    let row = store
        .eink_mirror_for_publication(Some(device.id.clone()), publication_id.to_string())?
        .ok_or_else(|| {
            EinkError::Invalid(format!(
                "publication {publication_id} is not mirrored to device {}",
                device.id
            ))
        })?;
    let remote_id = row.remote_id.clone().ok_or_else(|| {
        EinkError::Invalid(format!(
            "publication {publication_id} has no copy on the tablet yet (state {})",
            row.state
        ))
    })?;
    if !transport.reachable() {
        report.trace.push(format!(
            "tablet at {} is not reachable; nothing to do",
            device.base_url
        ));
        report.duration_ms = started.elapsed().as_millis() as i64;
        return Ok(report);
    }
    report.reachable = true;
    let lock = device_lock(&device.id);
    let _guard = lock.lock().map_err(|_| {
        EinkError::Locked("a previous sync panicked while holding the device".into())
    })?;
    let parent = row.remote_parent_id.clone().unwrap_or_default();
    let listed = transport.list_folder((!parent.is_empty()).then_some(parent.as_str()))?;
    let entry = listed.into_iter().find(|e| e.id == remote_id);
    let (remote_name, remote_modified_ms) = match entry {
        Some(entry) => (entry.visible_name, entry.last_modified_ms),
        None => {
            // Not in the folder imbib last saw it in: look everywhere before
            // declaring it gone.
            let (_, documents, _) =
                walk_tablet(transport, &device.root_folder_name, &mut report.trace)?;
            match documents.into_iter().find(|d| d.id == remote_id) {
                Some(entry) => (entry.visible_name, entry.last_modified_ms),
                None => {
                    store.eink_update_mirror(
                        &row.id,
                        vec![
                            ("state", Some(state_value(MirrorState::RemovedOnDevice))),
                            (
                                "last_error",
                                Some(Value::String(format!(
                                    "document {remote_id} is no longer on the tablet"
                                ))),
                            ),
                        ],
                    )?;
                    report.summary.removed += 1;
                    report.trace.push(format!(
                        "import {publication_id}: document {remote_id} is no longer on the tablet"
                    ));
                    report.duration_ms = started.elapsed().as_millis() as i64;
                    return Ok(report);
                }
            }
        }
    };
    report.summary.to_import = 1;
    match import_one(
        store,
        device,
        transport,
        sink,
        download_root,
        &row.id,
        publication_id,
        &remote_id,
        &remote_name,
        remote_modified_ms,
    ) {
        Ok(imported) => {
            report.trace.push(format!(
                "imported {publication_id}: {} (+{} ~{} -{} rows, {} ink pending OCR)",
                imported.annotated_pdf,
                imported.created,
                imported.updated,
                imported.deleted,
                imported.ink_pending_ocr
            ));
            report.imports.push(imported);
        }
        Err(error) => {
            report
                .trace
                .push(format!("import {publication_id} failed: {error}"));
            store.eink_update_mirror(
                &row.id,
                vec![(
                    "last_error",
                    Some(Value::String(format!("import failed: {error}"))),
                )],
            )?;
            report.failed.push(publication_id.to_string());
        }
    }
    report.duration_ms = started.elapsed().as_millis() as i64;
    Ok(report)
}

/// Where `import_one` puts downloads, for callers that clean up.
pub fn download_dir(library_dir: &Path, remote_id: &str) -> PathBuf {
    library_dir.join("EInk").join(remote_id)
}

// --- exported surface -----------------------------------------------------

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Run a sync against the device's USB interface. Blocking: call it off
    /// the main thread. `import` also pulls changed documents back.
    pub fn eink_sync(
        &self,
        device_id: Option<String>,
        import: bool,
    ) -> Result<EinkSyncReport, StoreApiError> {
        let device = resolve_device(self, device_id.as_deref()).map_err(eink_to_store_error)?;
        let transport = super::transport::UsbWebTransport::new(device.base_url.clone());
        let options = SyncOptions {
            import,
            ..Default::default()
        };
        run_sync(
            self,
            Some(&device.id),
            &transport,
            &super::import::StoreImportSink,
            options,
        )
        .map_err(eink_to_store_error)
    }

    /// An import-only pass: pull every document with new annotations back,
    /// send nothing up. `publication_id` narrows it to one paper and
    /// imports it whether or not the tablet reports a change (the way to
    /// re-run an import after changing the device's import switches).
    pub fn eink_import(
        &self,
        publication_id: Option<String>,
        device_id: Option<String>,
    ) -> Result<EinkSyncReport, StoreApiError> {
        let device = resolve_device(self, device_id.as_deref()).map_err(eink_to_store_error)?;
        let transport = super::transport::UsbWebTransport::new(device.base_url.clone());
        match publication_id {
            Some(publication_id) => import_publication(
                self,
                &device,
                &transport,
                &super::import::StoreImportSink,
                &publication_id,
                None,
            )
            .map_err(eink_to_store_error),
            None => {
                let options = SyncOptions {
                    upload: false,
                    import: true,
                    ..Default::default()
                };
                run_sync(
                    self,
                    Some(&device.id),
                    &transport,
                    &super::import::StoreImportSink,
                    options,
                )
                .map_err(eink_to_store_error)
            }
        }
    }

    /// Plan only: list the tablet, decide, write nothing.
    pub fn eink_plan(&self, device_id: Option<String>) -> Result<EinkSyncReport, StoreApiError> {
        let device = resolve_device(self, device_id.as_deref()).map_err(eink_to_store_error)?;
        let transport = super::transport::UsbWebTransport::new(device.base_url.clone());
        let options = SyncOptions {
            dry_run: true,
            ..Default::default()
        };
        run_sync(self, Some(&device.id), &transport, &NoopSink, options)
            .map_err(eink_to_store_error)
    }

    /// The missing-folder checklist for the device, computed from a live
    /// listing.
    pub fn eink_folder_checklist(
        &self,
        device_id: Option<String>,
    ) -> Result<Vec<FolderNeed>, StoreApiError> {
        Ok(self.eink_plan(device_id)?.folder_needs)
    }

    /// A two-second probe of the device's USB interface.
    pub fn eink_reachable(&self, device_id: Option<String>) -> Result<bool, StoreApiError> {
        let device = resolve_device(self, device_id.as_deref()).map_err(eink_to_store_error)?;
        Ok(super::transport::UsbWebTransport::new(device.base_url).reachable())
    }
}

fn eink_to_store_error(error: EinkError) -> StoreApiError {
    match error {
        EinkError::Store(inner) => inner,
        EinkError::NoDevice => StoreApiError::NotFound(error.to_string()),
        EinkError::Invalid(message) => StoreApiError::InvalidInput(message),
        other => StoreApiError::Storage(other.to_string()),
    }
}
