//! The e-ink rows on [`ImbibStore`]: devices, per-publication mirror state,
//! and the list-row marker.
//!
//! Two record kinds, both registered in `unified::schemas` and declared in
//! `schema-refs.json`:
//!
//! * `imbib/eink-device` — one per tablet; no parent.
//! * `imbib/eink-mirror` — one per (device, publication); parent = the
//!   publication, so `HasParent` finds a paper's rows and the row goes with
//!   the paper into undo snapshots.
//!
//! Everything exported here is the surface Swift and the service verbs
//! share; the engine's own helpers sit in the non-exported block below.

use std::collections::HashMap;

use chrono::Utc;
use impress_core::item::{Item, Value};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::store::{FieldMutation, ItemStore};
use uuid::Uuid;

use super::config::{
    bool_or, int_of, str_of, EinkDeviceConfig, FolderStrategy, MirrorMode, MirrorState,
    UploadFormat, SCHEMA_DEVICE, SCHEMA_MIRROR, TRANSPORT_USB_WEB,
};
use crate::unified::conversion::bare_item;
use crate::unified::store_api::{parse_uuid, ImbibStore, StoreApiError};

/// A device as callers see it (enums flattened to their spellings).
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkDeviceRow {
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
    /// `rmdoc` or `checklist`.
    pub folder_strategy: String,
    /// File a paper in the deepest folder that exists when the exact one is
    /// missing, rather than holding it in `awaiting_folder`.
    pub file_in_nearest_folder: bool,
    /// `rmdoc` (exact names) or `pdf` (bare file, named `<file>.pdf`).
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
    pub sync_started_at_ms: Option<i64>,
    pub last_error: Option<String>,
    pub created_ms: i64,
}

impl EinkDeviceRow {
    fn from_config(config: &EinkDeviceConfig, created_ms: i64) -> Self {
        Self {
            id: config.id.clone(),
            name: config.name.clone(),
            transport: config.transport.clone(),
            base_url: config.base_url.clone(),
            mirror_mode: config.mirror_mode.as_str().into(),
            root_folder_name: config.root_folder_name.clone(),
            mirror_collections: config.mirror_collections,
            include_library_level: config.include_library_level,
            include_inbox: config.include_inbox,
            folder_strategy: config.folder_strategy.as_str().into(),
            file_in_nearest_folder: config.file_in_nearest_folder,
            upload_format: config.upload_format.as_str().into(),
            auto_fetch_source: config.auto_fetch_source,
            import_annotated_pdf: config.import_annotated_pdf,
            import_rmdoc: config.import_rmdoc,
            import_highlights: config.import_highlights,
            import_ink: config.import_ink,
            import_typed_text: config.import_typed_text,
            run_ocr: config.run_ocr,
            auto_import_on_connect: config.auto_import_on_connect,
            enabled: config.enabled,
            last_sync_at_ms: config.last_sync_at_ms,
            last_seen_at_ms: config.last_seen_at_ms,
            sync_started_at_ms: config.sync_started_at_ms,
            last_error: config.last_error.clone(),
            created_ms,
        }
    }
}

/// What a caller may set on a device. Every field is optional so a partial
/// update leaves the rest alone; `id: None` creates a device.
#[derive(Debug, Clone, Default, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkDeviceConfigInput {
    pub id: Option<String>,
    pub name: Option<String>,
    pub transport: Option<String>,
    pub base_url: Option<String>,
    pub mirror_mode: Option<String>,
    pub root_folder_name: Option<String>,
    pub mirror_collections: Option<bool>,
    pub include_library_level: Option<bool>,
    pub include_inbox: Option<bool>,
    pub folder_strategy: Option<String>,
    pub file_in_nearest_folder: Option<bool>,
    pub upload_format: Option<String>,
    pub auto_fetch_source: Option<bool>,
    pub import_annotated_pdf: Option<bool>,
    pub import_rmdoc: Option<bool>,
    pub import_highlights: Option<bool>,
    pub import_ink: Option<bool>,
    pub import_typed_text: Option<bool>,
    pub run_ocr: Option<bool>,
    pub auto_import_on_connect: Option<bool>,
    pub enabled: Option<bool>,
}

/// One publication's row for one device.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkMirrorRow {
    pub id: String,
    pub publication_id: String,
    pub device_id: String,
    pub marked: bool,
    pub marked_at_ms: Option<i64>,
    pub linked_file_id: Option<String>,
    /// `pdf` or `epub`.
    pub source_kind: Option<String>,
    pub remote_id: Option<String>,
    pub remote_parent_id: Option<String>,
    pub remote_name: Option<String>,
    pub remote_path: Option<String>,
    /// Where the paper belongs when it could not be filed there (the tablet
    /// has no such folder and cannot be told to make one); `None` when the
    /// copy sits exactly where imbib wants it.
    pub desired_path: Option<String>,
    pub uploaded_sha256: Option<String>,
    pub uploaded_at_ms: Option<i64>,
    /// See [`MirrorState`].
    pub state: String,
    pub last_error: Option<String>,
    pub attempts: i64,
    pub last_attempt_ms: Option<i64>,
    pub remote_modified_ms: Option<i64>,
    pub imported_modified_ms: Option<i64>,
    pub annotated_file_id: Option<String>,
    pub resend: bool,
    pub created_ms: i64,
    pub modified_ms: i64,
}

impl EinkMirrorRow {
    pub fn from_item(item: &Item) -> Self {
        let p = &item.payload;
        Self {
            id: item.id.to_string(),
            publication_id: item.parent.map(|id| id.to_string()).unwrap_or_default(),
            device_id: str_of(p, "device_id").unwrap_or_default(),
            marked: bool_or(p, "marked", false),
            marked_at_ms: int_of(p, "marked_at_ms"),
            linked_file_id: str_of(p, "linked_file_id"),
            source_kind: str_of(p, "source_kind"),
            remote_id: str_of(p, "remote_id"),
            remote_parent_id: str_of(p, "remote_parent_id"),
            remote_name: str_of(p, "remote_name"),
            remote_path: str_of(p, "remote_path"),
            desired_path: str_of(p, "desired_path").filter(|path| !path.is_empty()),
            uploaded_sha256: str_of(p, "uploaded_sha256"),
            uploaded_at_ms: int_of(p, "uploaded_at_ms"),
            state: str_of(p, "state").unwrap_or_else(|| MirrorState::Queued.as_str().into()),
            last_error: str_of(p, "last_error"),
            attempts: int_of(p, "attempts").unwrap_or(0),
            last_attempt_ms: int_of(p, "last_attempt_ms"),
            remote_modified_ms: int_of(p, "remote_modified_ms"),
            imported_modified_ms: int_of(p, "imported_modified_ms"),
            annotated_file_id: str_of(p, "annotated_file_id"),
            resend: bool_or(p, "resend", false),
            created_ms: item.created.timestamp_millis(),
            modified_ms: item.modified.timestamp_millis(),
        }
    }

    pub fn mirror_state(&self) -> MirrorState {
        MirrorState::parse(&self.state).unwrap_or(MirrorState::Queued)
    }

    /// Whether the tablet copy changed since it was last imported.
    pub fn has_new_annotations(&self) -> bool {
        match (self.remote_modified_ms, self.imported_modified_ms) {
            (Some(remote), Some(imported)) => remote > imported,
            (Some(remote), None) => self
                .uploaded_at_ms
                .map(|uploaded| remote > uploaded + 60_000)
                .unwrap_or(true),
            _ => false,
        }
    }
}

/// The marker a list row shows for one publication.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkRowState {
    pub publication_id: String,
    pub state: String,
}

/// What a mark/unmark did.
#[derive(Debug, Clone, Default, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkMarkOutcome {
    pub device_id: String,
    /// Publications whose row changed.
    pub changed: Vec<String>,
    /// Publications already in the requested state, or unknown ids.
    pub unchanged: Vec<String>,
    /// Marked publications with no local PDF/ePUB: only the running app can
    /// fetch one; the row waits in `awaiting_source` until then.
    pub awaiting_source: Vec<String>,
}

/// A marked publication that still needs its PDF/ePUB fetched.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkAwaitingSource {
    pub mirror_id: String,
    pub publication_id: String,
    pub cite_key: String,
    pub title: String,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub url: Option<String>,
}

/// The local file the engine would send for a publication.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkLocalSource {
    pub linked_file_id: String,
    /// `pdf` or `epub`.
    pub kind: String,
    pub filename: String,
    pub relative_path: Option<String>,
    pub sha256: Option<String>,
}

/// Which device puts markers on list rows, keyed by a fingerprint of the
/// device rows so a change made by another process is noticed.
#[derive(Debug, Clone)]
pub struct EinkMarkerCache {
    fingerprint: (i64, i64),
    marker_device: Option<String>,
}

fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

fn value_str(value: &str) -> Value {
    Value::String(value.to_string())
}

fn device_query() -> ItemQuery {
    ItemQuery {
        schema: Some(SCHEMA_DEVICE.into()),
        sort: vec![SortDescriptor {
            field: "created".into(),
            ascending: true,
        }],
        include_tags: false,
        include_references: false,
        ..Default::default()
    }
}

fn mirror_query(
    device_id: Option<&str>,
    state: Option<&str>,
    publication: Option<Uuid>,
) -> ItemQuery {
    let mut predicates = Vec::new();
    if let Some(device) = device_id {
        predicates.push(Predicate::Eq("device_id".into(), value_str(device)));
    }
    if let Some(state) = state {
        predicates.push(Predicate::Eq("state".into(), value_str(state)));
    }
    if let Some(publication) = publication {
        predicates.push(Predicate::HasParent(publication));
    }
    ItemQuery {
        schema: Some(SCHEMA_MIRROR.into()),
        predicates,
        sort: vec![SortDescriptor {
            field: "modified".into(),
            ascending: false,
        }],
        include_tags: false,
        include_references: false,
        ..Default::default()
    }
}

fn set(key: &str, value: Value) -> FieldMutation {
    FieldMutation::SetPayload(key.into(), value)
}

// --- exported surface -----------------------------------------------------

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Every configured device, oldest first.
    pub fn eink_devices(&self) -> Result<Vec<EinkDeviceRow>, StoreApiError> {
        let items = self.store.query(&device_query())?;
        Ok(items
            .iter()
            .map(|item| {
                EinkDeviceRow::from_config(
                    &EinkDeviceConfig::from_item(item),
                    item.created.timestamp_millis(),
                )
            })
            .collect())
    }

    pub fn eink_get_device(&self, id: String) -> Result<Option<EinkDeviceRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        Ok(self
            .store
            .get(uuid)?
            .filter(|item| item.schema == SCHEMA_DEVICE)
            .map(|item| {
                EinkDeviceRow::from_config(
                    &EinkDeviceConfig::from_item(&item),
                    item.created.timestamp_millis(),
                )
            }))
    }

    /// Create a device (`id: None`) or update one field-by-field. Values are
    /// validated before anything is written; the list-row marker context is
    /// recomputed afterwards.
    pub fn eink_configure_device(
        &self,
        input: EinkDeviceConfigInput,
    ) -> Result<EinkDeviceRow, StoreApiError> {
        let existing = match &input.id {
            Some(id) => {
                let uuid = parse_uuid(id)?;
                self.store
                    .get(uuid)?
                    .filter(|item| item.schema == SCHEMA_DEVICE)
            }
            None => None,
        };
        let mut config = match &existing {
            Some(item) => EinkDeviceConfig::from_item(item),
            None => EinkDeviceConfig::usb_web(
                input
                    .id
                    .clone()
                    .unwrap_or_else(|| Uuid::new_v4().to_string()),
                input.name.clone().unwrap_or_else(|| "reMarkable".into()),
            ),
        };
        if let Some(name) = &input.name {
            let trimmed = name.trim();
            if trimmed.is_empty() {
                return Err(StoreApiError::InvalidInput(
                    "the device needs a name".into(),
                ));
            }
            config.name = trimmed.to_string();
        }
        if let Some(transport) = &input.transport {
            if transport != TRANSPORT_USB_WEB {
                return Err(StoreApiError::InvalidInput(format!(
                    "unsupported transport {transport:?}; only {TRANSPORT_USB_WEB} mirrors papers today"
                )));
            }
            config.transport = transport.clone();
        }
        if let Some(url) = &input.base_url {
            let trimmed = url.trim().trim_end_matches('/');
            if !(trimmed.starts_with("http://") || trimmed.starts_with("https://")) {
                return Err(StoreApiError::InvalidInput(format!(
                    "base_url must start with http:// or https://, got {url:?}"
                )));
            }
            config.base_url = trimmed.to_string();
        }
        if let Some(mode) = &input.mirror_mode {
            config.mirror_mode = MirrorMode::parse(mode).ok_or_else(|| {
                StoreApiError::InvalidInput(format!(
                    "mirror_mode must be `all` or `individual`, got {mode:?}"
                ))
            })?;
        }
        if let Some(root) = &input.root_folder_name {
            let trimmed = root.trim().trim_matches('/');
            if trimmed.is_empty() || trimmed.contains('/') {
                return Err(StoreApiError::InvalidInput(
                    "root_folder_name must be one non-empty folder name".into(),
                ));
            }
            config.root_folder_name = trimmed.to_string();
        }
        if let Some(strategy) = &input.folder_strategy {
            config.folder_strategy = FolderStrategy::parse(strategy).ok_or_else(|| {
                StoreApiError::InvalidInput(format!(
                    "folder_strategy must be `rmdoc` or `checklist`, got {strategy:?}"
                ))
            })?;
        }
        if let Some(format) = &input.upload_format {
            config.upload_format = UploadFormat::parse(format).ok_or_else(|| {
                StoreApiError::InvalidInput(format!(
                    "upload_format must be `rmdoc` or `pdf`, got {format:?}"
                ))
            })?;
        }
        macro_rules! take_bool {
            ($($field:ident),*) => {
                $( if let Some(value) = input.$field { config.$field = value; } )*
            };
        }
        take_bool!(
            mirror_collections,
            include_library_level,
            include_inbox,
            file_in_nearest_folder,
            auto_fetch_source,
            import_annotated_pdf,
            import_rmdoc,
            import_highlights,
            import_ink,
            import_typed_text,
            run_ocr,
            auto_import_on_connect,
            enabled
        );

        let created_ms = match existing {
            Some(item) => {
                let mutations: Vec<FieldMutation> = config
                    .to_payload()
                    .into_iter()
                    .map(|(key, value)| FieldMutation::SetPayload(key, value))
                    .collect();
                self.store.update(item.id, mutations)?;
                item.created.timestamp_millis()
            }
            None => {
                let uuid = parse_uuid(&config.id)?;
                let item = bare_item(uuid, SCHEMA_DEVICE, config.to_payload());
                self.store.insert(item)?;
                now_ms()
            }
        };
        self.invalidate_eink_cache();
        Ok(EinkDeviceRow::from_config(&config, created_ms))
    }

    /// Delete a device and every mirror row it owns; returns the row count.
    pub fn eink_remove_device(&self, id: String) -> Result<u32, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let rows = self.store.query(&mirror_query(Some(&id), None, None))?;
        for row in &rows {
            self.store.delete(row.id)?;
        }
        if self
            .store
            .get(uuid)?
            .is_some_and(|item| item.schema == SCHEMA_DEVICE)
        {
            self.store.delete(uuid)?;
        }
        self.invalidate_eink_cache();
        Ok(rows.len() as u32)
    }

    /// Mark publications for the device (`device_id: None` = the default
    /// device). A paper with a local PDF/ePUB queues; one without waits in
    /// `awaiting_source`. Re-marking a paper the user removed on the tablet
    /// asks for it to be sent again.
    pub fn eink_mark(
        &self,
        device_id: Option<String>,
        publication_ids: Vec<String>,
    ) -> Result<EinkMarkOutcome, StoreApiError> {
        let device = self.eink_require_device(device_id.as_deref())?;
        let mut outcome = EinkMarkOutcome {
            device_id: device.id.clone(),
            ..Default::default()
        };
        let now = now_ms();
        for publication_id in publication_ids {
            let Ok(pub_uuid) = parse_uuid(&publication_id) else {
                outcome.unchanged.push(publication_id);
                continue;
            };
            let exists = self
                .store
                .get(pub_uuid)?
                .is_some_and(|item| item.schema == "imbib/bibliography-entry");
            if !exists {
                outcome.unchanged.push(publication_id);
                continue;
            }
            let existing = self
                .store
                .query(&mirror_query(Some(&device.id), None, Some(pub_uuid)))?
                .into_iter()
                .next();
            match existing {
                Some(item) => {
                    let row = EinkMirrorRow::from_item(&item);
                    let mut mutations = Vec::new();
                    match row.mirror_state() {
                        MirrorState::Unmarked => {
                            mutations.push(set("marked", Value::Bool(true)));
                            mutations.push(set("marked_at_ms", Value::Int(now)));
                            mutations.push(set("state", value_str(MirrorState::Uploaded.as_str())));
                        }
                        MirrorState::RemovedOnDevice | MirrorState::Superseded => {
                            mutations.push(set("marked", Value::Bool(true)));
                            mutations.push(set("marked_at_ms", Value::Int(now)));
                            mutations.push(set("resend", Value::Bool(true)));
                        }
                        _ if !row.marked => {
                            mutations.push(set("marked", Value::Bool(true)));
                            mutations.push(set("marked_at_ms", Value::Int(now)));
                        }
                        _ => {}
                    }
                    if row.mirror_state() == MirrorState::AwaitingSource {
                        outcome.awaiting_source.push(publication_id.clone());
                    }
                    if mutations.is_empty() {
                        outcome.unchanged.push(publication_id);
                    } else {
                        self.store.update(item.id, mutations)?;
                        outcome.changed.push(publication_id);
                    }
                }
                None => {
                    let source = self.eink_local_source(publication_id.clone())?;
                    let state = if source.is_some() {
                        MirrorState::Queued
                    } else {
                        MirrorState::AwaitingSource
                    };
                    let mut payload = std::collections::BTreeMap::new();
                    payload.insert("device_id".into(), value_str(&device.id));
                    payload.insert("marked".into(), Value::Bool(true));
                    payload.insert("marked_at_ms".into(), Value::Int(now));
                    payload.insert("state".into(), value_str(state.as_str()));
                    payload.insert("attempts".into(), Value::Int(0));
                    payload.insert("resend".into(), Value::Bool(false));
                    if let Some(source) = &source {
                        payload.insert("linked_file_id".into(), value_str(&source.linked_file_id));
                        payload.insert("source_kind".into(), value_str(&source.kind));
                    }
                    let mut item = bare_item(Uuid::new_v4(), SCHEMA_MIRROR, payload);
                    item.parent = Some(pub_uuid);
                    self.store.insert(item)?;
                    if state == MirrorState::AwaitingSource {
                        outcome.awaiting_source.push(publication_id.clone());
                    }
                    outcome.changed.push(publication_id);
                }
            }
        }
        Ok(outcome)
    }

    /// Un-mark publications. A row that never reached the tablet is deleted;
    /// one that did becomes `unmarked` (the tablet copy stays — nothing can
    /// delete over USB — and imbib stops touching it).
    pub fn eink_unmark(
        &self,
        device_id: Option<String>,
        publication_ids: Vec<String>,
    ) -> Result<EinkMarkOutcome, StoreApiError> {
        let device = self.eink_require_device(device_id.as_deref())?;
        let mut outcome = EinkMarkOutcome {
            device_id: device.id.clone(),
            ..Default::default()
        };
        for publication_id in publication_ids {
            let Ok(pub_uuid) = parse_uuid(&publication_id) else {
                outcome.unchanged.push(publication_id);
                continue;
            };
            let existing = self
                .store
                .query(&mirror_query(Some(&device.id), None, Some(pub_uuid)))?
                .into_iter()
                .next();
            let Some(item) = existing else {
                outcome.unchanged.push(publication_id);
                continue;
            };
            let row = EinkMirrorRow::from_item(&item);
            match row.mirror_state() {
                MirrorState::Queued | MirrorState::AwaitingSource | MirrorState::AwaitingFolder => {
                    self.store.delete(item.id)?;
                    outcome.changed.push(publication_id);
                }
                MirrorState::Uploaded | MirrorState::Stale | MirrorState::Failed => {
                    if row.remote_id.is_none() {
                        // Failed before anything reached the tablet: nothing
                        // to leave a tombstone for.
                        self.store.delete(item.id)?;
                    } else {
                        self.store.update(
                            item.id,
                            vec![
                                set("marked", Value::Bool(false)),
                                set("resend", Value::Bool(false)),
                                set("state", value_str(MirrorState::Unmarked.as_str())),
                            ],
                        )?;
                    }
                    outcome.changed.push(publication_id);
                }
                MirrorState::RemovedOnDevice | MirrorState::Superseded => {
                    self.store.delete(item.id)?;
                    outcome.changed.push(publication_id);
                }
                MirrorState::Unmarked => outcome.unchanged.push(publication_id),
            }
        }
        Ok(outcome)
    }

    /// Ask for rows to be sent again (a stale copy, one removed on the
    /// tablet, an un-marked one): sets `resend`, which the planner turns
    /// into an upload that supersedes the old copy.
    pub fn eink_resend(&self, mirror_ids: Vec<String>) -> Result<u32, StoreApiError> {
        let mut count = 0;
        for id in mirror_ids {
            let uuid = parse_uuid(&id)?;
            if let Some(item) = self
                .store
                .get(uuid)?
                .filter(|item| item.schema == SCHEMA_MIRROR)
            {
                self.store.update(
                    item.id,
                    vec![
                        set("resend", Value::Bool(true)),
                        set("marked", Value::Bool(true)),
                        set("marked_at_ms", Value::Int(now_ms())),
                    ],
                )?;
                count += 1;
            }
        }
        Ok(count)
    }

    /// Record how the app's attempt to fetch a paper's PDF went, so an
    /// `awaiting_source` row can say why it is still waiting. Only the
    /// running app can download; the engine never can, so without this the
    /// row is a dead end with no reason on it. `error: None` clears a
    /// previous one.
    pub fn eink_note_source_attempt(
        &self,
        device_id: Option<String>,
        publication_id: String,
        error: Option<String>,
    ) -> Result<bool, StoreApiError> {
        let device = self.eink_require_device(device_id.as_deref())?;
        let pub_uuid = parse_uuid(&publication_id)?;
        let Some(item) = self
            .store
            .query(&mirror_query(Some(&device.id), None, Some(pub_uuid)))?
            .into_iter()
            .next()
        else {
            return Ok(false);
        };
        let attempts = EinkMirrorRow::from_item(&item).attempts;
        let mut mutations = vec![
            set("attempts", Value::Int(attempts.saturating_add(1))),
            set("last_attempt_ms", Value::Int(now_ms())),
        ];
        mutations.push(match &error {
            Some(message) => set("last_error", Value::String(message.clone())),
            None => FieldMutation::RemovePayload("last_error".into()),
        });
        self.store.update(item.id, mutations)?;
        Ok(true)
    }

    /// Mirror rows, newest change first; filtered by device (`None` = the
    /// default device) and optionally by state.
    pub fn eink_list_mirrored(
        &self,
        device_id: Option<String>,
        state: Option<String>,
    ) -> Result<Vec<EinkMirrorRow>, StoreApiError> {
        let device = match device_id {
            Some(id) => Some(id),
            None => self.eink_default_device_config()?.map(|d| d.id),
        };
        let Some(device) = device else {
            return Ok(Vec::new());
        };
        if let Some(state) = &state {
            MirrorState::parse(state).ok_or_else(|| {
                StoreApiError::InvalidInput(format!("unknown mirror state {state:?}"))
            })?;
        }
        let items = self
            .store
            .query(&mirror_query(Some(&device), state.as_deref(), None))?;
        Ok(items.iter().map(EinkMirrorRow::from_item).collect())
    }

    /// The row for one publication on one device, if any.
    pub fn eink_mirror_for_publication(
        &self,
        device_id: Option<String>,
        publication_id: String,
    ) -> Result<Option<EinkMirrorRow>, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let device = match device_id {
            Some(id) => Some(id),
            None => self.eink_default_device_config()?.map(|d| d.id),
        };
        let Some(device) = device else {
            return Ok(None);
        };
        Ok(self
            .store
            .query(&mirror_query(Some(&device), None, Some(pub_uuid)))?
            .first()
            .map(EinkMirrorRow::from_item))
    }

    /// Every (publication, state) pair for a device — the counts/sidebar
    /// path; list rows get theirs stitched in by `query_publications`.
    pub fn eink_row_states(
        &self,
        device_id: Option<String>,
    ) -> Result<Vec<EinkRowState>, StoreApiError> {
        Ok(self
            .eink_list_mirrored(device_id, None)?
            .into_iter()
            .map(|row| EinkRowState {
                publication_id: row.publication_id,
                state: row.state,
            })
            .collect())
    }

    /// Marked papers with no local PDF/ePUB, with the identifiers a fetcher
    /// needs.
    pub fn eink_awaiting_source(
        &self,
        device_id: Option<String>,
    ) -> Result<Vec<EinkAwaitingSource>, StoreApiError> {
        let rows =
            self.eink_list_mirrored(device_id, Some(MirrorState::AwaitingSource.as_str().into()))?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let Ok(pub_uuid) = parse_uuid(&row.publication_id) else {
                continue;
            };
            let Some(item) = self.store.get(pub_uuid)? else {
                continue;
            };
            let p = &item.payload;
            out.push(EinkAwaitingSource {
                mirror_id: row.id,
                publication_id: row.publication_id,
                cite_key: str_of(p, "cite_key").unwrap_or_default(),
                title: str_of(p, "title").unwrap_or_default(),
                doi: str_of(p, "doi"),
                arxiv_id: str_of(p, "arxiv_id"),
                url: str_of(p, "url"),
            });
        }
        Ok(out)
    }

    /// The PDF (preferred) or ePUB the engine would send for a publication.
    pub fn eink_local_source(
        &self,
        publication_id: String,
    ) -> Result<Option<EinkLocalSource>, StoreApiError> {
        let files = self.list_linked_files(publication_id)?;
        let is_primary = |role: &Option<String>| {
            role.as_deref()
                .map(|r| r.is_empty() || r == "primary")
                .unwrap_or(true)
        };
        let pdf = files
            .iter()
            .find(|f| f.is_pdf && f.is_locally_materialized && is_primary(&f.role));
        let epub = files.iter().find(|f| {
            f.is_locally_materialized
                && is_primary(&f.role)
                && (f
                    .file_type
                    .as_deref()
                    .map(|t| t.eq_ignore_ascii_case("epub"))
                    == Some(true)
                    || f.filename.to_ascii_lowercase().ends_with(".epub"))
        });
        Ok(pdf.or(epub).map(|f| EinkLocalSource {
            linked_file_id: f.id.clone(),
            kind: if f.is_pdf {
                "pdf".into()
            } else {
                "epub".into()
            },
            filename: f.filename.clone(),
            relative_path: f.relative_path.clone(),
            sha256: f.sha256.clone(),
        }))
    }

    /// Delete mirror rows whose publication is gone (the parent link is
    /// nulled when a paper is deleted); returns how many.
    pub fn eink_gc_orphans(&self) -> Result<u32, StoreApiError> {
        let ids = self.store.query_raw(
            "SELECT id FROM items WHERE schema_ref = 'imbib/eink-mirror' AND parent_id IS NULL",
            &[],
            |row| row.get::<_, String>(0),
        )?;
        let mut count = 0;
        for id in ids {
            if let Ok(uuid) = Uuid::parse_str(&id) {
                self.store.delete(uuid)?;
                count += 1;
            }
        }
        Ok(count)
    }

    /// How many publications still carry the retired `_remarkable_*` payload
    /// keys the old Swift sync manager wrote (expected 0: that writer never
    /// worked end to end).
    pub fn eink_legacy_marker_rows(&self) -> Result<u32, StoreApiError> {
        let counts = self.store.query_raw(
            "SELECT COUNT(*) FROM items WHERE schema_ref = 'imbib/bibliography-entry' \
             AND (json_extract(payload, '$._remarkable_doc_id') IS NOT NULL \
                  OR json_extract(payload, '$.extra_fields._remarkable_doc_id') IS NOT NULL)",
            &[],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(counts.first().copied().unwrap_or(0) as u32)
    }

    /// The absolute path of a linked file on this Mac, resolved through the
    /// same ladder as Swift's `AttachmentManager`; `None` when no candidate
    /// exists.
    pub fn resolve_linked_file(
        &self,
        linked_file_id: String,
    ) -> Result<Option<String>, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let Some(file) = self
            .store
            .get(file_uuid)?
            .filter(|item| item.schema == "imbib/linked-file")
        else {
            return Ok(None);
        };
        let Some(relative) = str_of(&file.payload, "relative_path") else {
            return Ok(None);
        };
        let Some(home) = super::paths::user_home() else {
            return Ok(None);
        };
        let library_ids = self.eink_library_ids_for_file(&file)?;
        if library_ids.is_empty() {
            return Ok(super::paths::resolve_relative(None, &relative, &home)
                .map(|p| p.display().to_string()));
        }
        for library in library_ids {
            if let Some(path) = super::paths::resolve_relative(Some(&library), &relative, &home) {
                return Ok(Some(path.display().to_string()));
            }
        }
        Ok(None)
    }
}

// --- engine-facing helpers (not exported) ---------------------------------

impl ImbibStore {
    pub(crate) fn invalidate_eink_cache(&self) {
        *self.eink_marker_cache.lock().unwrap() = None;
    }

    /// Every device as configuration, oldest first.
    pub fn eink_device_configs(&self) -> Result<Vec<EinkDeviceConfig>, StoreApiError> {
        Ok(self
            .store
            .query(&device_query())?
            .iter()
            .map(EinkDeviceConfig::from_item)
            .collect())
    }

    pub fn eink_device_config(&self, id: &str) -> Result<Option<EinkDeviceConfig>, StoreApiError> {
        let uuid = parse_uuid(id)?;
        Ok(self
            .store
            .get(uuid)?
            .filter(|item| item.schema == SCHEMA_DEVICE)
            .map(|item| EinkDeviceConfig::from_item(&item)))
    }

    /// The device a call without a device id means: the oldest enabled one,
    /// else the oldest at all.
    pub fn eink_default_device_config(&self) -> Result<Option<EinkDeviceConfig>, StoreApiError> {
        let devices = self.eink_device_configs()?;
        Ok(devices
            .iter()
            .find(|d| d.enabled)
            .cloned()
            .or_else(|| devices.first().cloned()))
    }

    fn eink_require_device(
        &self,
        device_id: Option<&str>,
    ) -> Result<EinkDeviceConfig, StoreApiError> {
        match device_id {
            Some(id) => self
                .eink_device_config(id)?
                .ok_or_else(|| StoreApiError::NotFound(format!("e-ink device {id}"))),
            None => self.eink_default_device_config()?.ok_or_else(|| {
                StoreApiError::NotFound(
                    "no e-ink device is configured (Settings › E-Ink Devices)".into(),
                )
            }),
        }
    }

    /// The device whose marks show on list rows: the oldest enabled device
    /// in individual mode, or none. Cached behind a fingerprint of the
    /// device rows.
    pub(crate) fn eink_marker_device(&self) -> Result<Option<String>, StoreApiError> {
        let fingerprint = self
            .store
            .query_raw(
                "SELECT COUNT(*), COALESCE(MAX(modified), 0) FROM items \
                 WHERE schema_ref = 'imbib/eink-device'",
                &[],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )?
            .first()
            .copied()
            .unwrap_or((0, 0));
        if fingerprint.0 == 0 {
            return Ok(None);
        }
        if let Some(cache) = self.eink_marker_cache.lock().unwrap().as_ref() {
            if cache.fingerprint == fingerprint {
                return Ok(cache.marker_device.clone());
            }
        }
        let marker_device = self
            .eink_device_configs()?
            .into_iter()
            .find(|d| d.enabled && d.is_individual())
            .map(|d| d.id);
        *self.eink_marker_cache.lock().unwrap() = Some(EinkMarkerCache {
            fingerprint,
            marker_device: marker_device.clone(),
        });
        Ok(marker_device)
    }

    /// The marker per publication for the list rows: one query per chunk of
    /// ids, nothing per row, and nothing at all unless a device in
    /// individual mode is configured. Rows in `superseded`/`unmarked` show
    /// no marker.
    pub(crate) fn load_eink_states(
        &self,
        pub_ids: &[Uuid],
    ) -> Result<HashMap<Uuid, String>, StoreApiError> {
        let mut result = HashMap::new();
        if pub_ids.is_empty() {
            return Ok(result);
        }
        let Some(device) = self.eink_marker_device()? else {
            return Ok(result);
        };
        for chunk in pub_ids.chunks(900) {
            let placeholders = (2..=chunk.len() + 1)
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT parent_id, json_extract(payload, '$.state') FROM items \
                 WHERE schema_ref = 'imbib/eink-mirror' \
                   AND json_extract(payload, '$.device_id') = ?1 \
                   AND parent_id IN ({placeholders})"
            );
            let mut params: Vec<String> = Vec::with_capacity(chunk.len() + 1);
            params.push(device.clone());
            params.extend(chunk.iter().map(|id| id.to_string()));
            let params_ref: Vec<&dyn rusqlite::types::ToSql> = params
                .iter()
                .map(|p| p as &dyn rusqlite::types::ToSql)
                .collect();
            let rows = self.store.query_raw(&sql, &params_ref, |row| {
                let parent: String = row.get(0)?;
                let state: Option<String> = row.get(1)?;
                Ok((parent, state))
            })?;
            for (parent, state) in rows {
                let Some(state) = state else { continue };
                if MirrorState::parse(&state).is_some_and(|s| s.shows_marker()) {
                    if let Ok(uuid) = Uuid::parse_str(&parent) {
                        result.insert(uuid, state);
                    }
                }
            }
        }
        Ok(result)
    }

    /// Every mirror row of a device, as items (the engine needs the ids).
    pub fn eink_mirror_rows(&self, device_id: &str) -> Result<Vec<EinkMirrorRow>, StoreApiError> {
        Ok(self
            .store
            .query(&mirror_query(Some(device_id), None, None))?
            .iter()
            .map(EinkMirrorRow::from_item)
            .collect())
    }

    /// Write mirror-row fields. `None` values remove the key.
    pub fn eink_update_mirror(
        &self,
        mirror_id: &str,
        fields: Vec<(&str, Option<Value>)>,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(mirror_id)?;
        let mutations: Vec<FieldMutation> = fields
            .into_iter()
            .map(|(key, value)| match value {
                Some(value) => FieldMutation::SetPayload(key.into(), value),
                None => FieldMutation::RemovePayload(key.into()),
            })
            .collect();
        if mutations.is_empty() {
            return Ok(());
        }
        Ok(self.store.update(uuid, mutations)?)
    }

    /// Create a mirror row for a publication the engine put in scope
    /// (mirror-all mode) or found on the tablet.
    pub fn eink_insert_mirror(
        &self,
        device_id: &str,
        publication_id: &str,
        marked: bool,
        state: MirrorState,
        fields: Vec<(&str, Value)>,
    ) -> Result<EinkMirrorRow, StoreApiError> {
        let pub_uuid = parse_uuid(publication_id)?;
        let mut payload = std::collections::BTreeMap::new();
        payload.insert("device_id".into(), value_str(device_id));
        payload.insert("marked".into(), Value::Bool(marked));
        if marked {
            payload.insert("marked_at_ms".into(), Value::Int(now_ms()));
        }
        payload.insert("state".into(), value_str(state.as_str()));
        payload.insert("attempts".into(), Value::Int(0));
        payload.insert("resend".into(), Value::Bool(false));
        for (key, value) in fields {
            payload.insert(key.into(), value);
        }
        let mut item = bare_item(Uuid::new_v4(), SCHEMA_MIRROR, payload);
        item.parent = Some(pub_uuid);
        self.store.insert(item.clone())?;
        Ok(EinkMirrorRow::from_item(&item))
    }

    /// Stamp device fields (last sync, last error, lock).
    pub fn eink_update_device(
        &self,
        device_id: &str,
        fields: Vec<(&str, Option<Value>)>,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(device_id)?;
        let mutations: Vec<FieldMutation> = fields
            .into_iter()
            .map(|(key, value)| match value {
                Some(value) => FieldMutation::SetPayload(key.into(), value),
                None => FieldMutation::RemovePayload(key.into()),
            })
            .collect();
        if !mutations.is_empty() {
            self.store.update(uuid, mutations)?;
        }
        self.invalidate_eink_cache();
        Ok(())
    }

    /// The libraries that could hold a linked file: the publication's
    /// envelope parent first, then every library it is filed in by edge.
    fn eink_library_ids_for_file(&self, file: &Item) -> Result<Vec<String>, StoreApiError> {
        let Some(pub_uuid) = file.parent else {
            return Ok(Vec::new());
        };
        let Some(publication) = self.store.get(pub_uuid)? else {
            return Ok(Vec::new());
        };
        let mut ids: Vec<String> = publication
            .parent
            .map(|id| id.to_string())
            .into_iter()
            .collect();
        for library in self.list_libraries()? {
            if !ids.contains(&library.id) {
                ids.push(library.id);
            }
        }
        Ok(ids)
    }
}
