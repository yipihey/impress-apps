//! Manuscript projects — the store operations behind ADR-0030.
//!
//! A manuscript is a project: the manuscript row is the ENTRY file (its text
//! is `body_content`, its path `entry_path`), and every other file of the
//! tree is a `manuscript-file@1.0.0` row whose parent is the manuscript. This
//! module is the one writer of those rows and of `manuscript-build@1.0.0`;
//! the engine that scans, compiles and materialises a tree lives in
//! `imprint-core::project` and reads what this module returns
//! ([`ProjectSnapshot`]).
//!
//! Two rules every function here keeps:
//!
//! 1. **Paths are validated on the way in** ([`normalize_path`]): POSIX,
//!    relative, no `..`, no empty component, no leading `/`. A row can never
//!    name a file outside its tree, so a materialiser can join `root/path`
//!    without a second check.
//! 2. **Ids are derived from paths** ([`crate::schemas::manuscript_file_id`]).
//!    `get_file` is one `get` by id, never a query; a re-import, a second
//!    device and a watched working copy mint the same row for the same file.
//!    The price is that a move is a new row (and a delete of the old), which
//!    is what [`move_file`] does.
//!
//! Text at or below [`INLINE_TEXT_LIMIT`] is inline in `content`; larger text
//! and every binary go to the workspace CAS ([`crate::blobs`]) as a
//! `blob:sha256:` ref. Either way the row carries `content_hash` and `size`.
//!
//! Writes to file rows use `update` (Routine, Compactable — the same artery
//! `collab::materialize_body` uses for the body, because the text's history
//! is the Automerge document, not the op log). Structural changes on the
//! manuscript row (`entry_path`, `targets_json`) are Editorial, Durable
//! operations attributed to the caller, like `manuscript_ops::create_revision`.

use std::collections::BTreeMap;

use chrono::Utc;
use uuid::Uuid;

use crate::blobs::{self, BlobStore};
use crate::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use crate::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use crate::query::{ItemQuery, Predicate, SortDescriptor};
use crate::reference::{EdgeType, TypedReference};
use crate::schemas::{
    manuscript_file_id, BUILD_STATUS_RUNNING, FILE_KIND_BINARY, FILE_KIND_TEXT, FILE_ROLES,
    INLINE_TEXT_LIMIT, MANUSCRIPT_BUILD_SCHEMA_REF, MANUSCRIPT_FILE_SCHEMA_REF,
};
use crate::sqlite_store::SqliteItemStore;
use crate::store::{FieldMutation, ItemStore, StoreError};

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Normalise a project-relative path: forward slashes, no leading `/`, no
/// `.`/`..`/empty components, no NUL. Returns the cleaned path.
pub fn normalize_path(path: &str) -> Result<String, StoreError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(StoreError::Validation("path must not be empty".into()));
    }
    if trimmed.contains('\0') {
        return Err(StoreError::Validation("path must not contain NUL".into()));
    }
    let unified = trimmed.replace('\\', "/");
    if unified.starts_with('/') {
        return Err(StoreError::Validation(format!(
            "path must be relative, got {trimmed:?}"
        )));
    }
    let mut parts: Vec<&str> = Vec::new();
    for component in unified.split('/') {
        match component {
            "" | "." => continue,
            ".." => {
                return Err(StoreError::Validation(format!(
                    "path must not contain `..`, got {trimmed:?}"
                )))
            }
            other => parts.push(other),
        }
    }
    if parts.is_empty() {
        return Err(StoreError::Validation(format!(
            "path names no file, got {trimmed:?}"
        )));
    }
    Ok(parts.join("/"))
}

/// The extension (lowercased, without the dot) of a project path.
pub fn extension_of(path: &str) -> Option<String> {
    let name = path.rsplit('/').next()?;
    let (stem, ext) = name.rsplit_once('.')?;
    if stem.is_empty() {
        return None;
    }
    Some(ext.to_ascii_lowercase())
}

/// `main.<ext>` for a manuscript format, from the format grammar table.
pub fn default_entry_path(format: &str) -> String {
    let ext = crate::manuscript_format::manuscript_format_grammar(format)
        .and_then(|g| g.extensions.first().copied())
        .unwrap_or("txt");
    format!("main.{ext}")
}

/// The grammar (`typst`, `latex`, `markdown`, `bibtex`, …) a text file's
/// extension implies, for the `format` field. Manuscript formats come from
/// the shared grammar table; the rest are the project's own small table.
pub fn format_for_extension(ext: &str) -> Option<&'static str> {
    if let Some(f) = crate::manuscript_format::manuscript_format_for_extension(ext) {
        return Some(f);
    }
    Some(match ext.to_ascii_lowercase().as_str() {
        "bib" | "bibtex" => "bibtex",
        "py" => "python",
        "jl" => "julia",
        "r" => "r",
        "sh" => "shell",
        "json" => "json",
        "csv" | "tsv" => "csv",
        "yaml" | "yml" => "yaml",
        "toml" => "toml",
        "xml" => "xml",
        "sty" | "cls" | "bst" | "clo" | "def" => "latex",
        "vsz" => "veusz",
        "plot" => "plot-spec",
        "svg" => "svg",
        "html" | "htm" => "html",
        _ => return None,
    })
}

/// Whether bytes look like UTF-8 text (no NUL, valid UTF-8).
pub fn looks_like_text(bytes: &[u8]) -> bool {
    !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok()
}

/// A MIME type for an extension, for `mime_type`.
pub fn mime_for_extension(ext: &str) -> &'static str {
    match ext.to_ascii_lowercase().as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "tif" | "tiff" => "image/tiff",
        "eps" => "application/postscript",
        "typ" => "text/x-typst",
        "tex" | "sty" | "cls" => "text/x-tex",
        "md" | "markdown" => "text/markdown",
        "bib" => "text/x-bibtex",
        "json" => "application/json",
        "csv" => "text/csv",
        "txt" => "text/plain",
        "py" => "text/x-python",
        "zip" => "application/zip",
        "npz" | "npy" => "application/octet-stream",
        "h5" | "hdf5" => "application/x-hdf5",
        "fits" => "application/fits",
        "parquet" => "application/vnd.apache.parquet",
        _ => "application/octet-stream",
    }
}

fn validate_role(role: &str) -> Result<(), StoreError> {
    if FILE_ROLES.contains(&role) {
        Ok(())
    } else {
        Err(StoreError::Validation(format!(
            "role must be one of {:?}, got {role:?}",
            FILE_ROLES
        )))
    }
}

/// A sensible role for a path nobody classified: by extension.
pub fn default_role_for(path: &str) -> &'static str {
    match extension_of(path).as_deref() {
        Some("tex") | Some("typ") | Some("md") | Some("markdown") | Some("txt") => "chapter",
        Some("bib") | Some("bibtex") | Some("bst") => "bibliography",
        Some("png") | Some("jpg") | Some("jpeg") | Some("pdf") | Some("svg") | Some("eps")
        | Some("gif") | Some("tif") | Some("tiff") | Some("webp") => "figure",
        Some("vsz") | Some("plot") | Some("py") | Some("jl") | Some("r") | Some("sh") => {
            "figure-source"
        }
        Some("csv") | Some("tsv") | Some("json") | Some("npz") | Some("npy") | Some("h5")
        | Some("hdf5") | Some("fits") | Some("parquet") | Some("yaml") | Some("yml")
        | Some("toml") => "data",
        Some("sty") | Some("cls") | Some("clo") | Some("def") => "style",
        _ => "aux",
    }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// A file row as callers see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManuscriptFileRow {
    pub id: ItemId,
    pub manuscript_id: ItemId,
    pub path: String,
    pub role: String,
    pub kind: String,
    pub format: Option<String>,
    /// Inline text when the row holds it; `None` for blobs.
    pub content: Option<String>,
    pub blob_ref: Option<String>,
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

impl ManuscriptFileRow {
    pub fn from_item(item: &Item) -> Self {
        let p = &item.payload;
        Self {
            id: item.id,
            manuscript_id: item.parent.unwrap_or(Uuid::nil()),
            path: str_of(p, "path").unwrap_or_default(),
            role: str_of(p, "role").unwrap_or_else(|| "aux".into()),
            kind: str_of(p, "kind").unwrap_or_else(|| FILE_KIND_BINARY.into()),
            format: str_of(p, "format"),
            content: match p.get("blob_ref") {
                Some(Value::String(r)) if !r.is_empty() => None,
                _ => str_of(p, "content"),
            },
            blob_ref: str_of(p, "blob_ref").filter(|r| !r.is_empty()),
            content_hash: str_of(p, "content_hash").unwrap_or_default(),
            size: int_of(p, "size").unwrap_or(0),
            mime_type: str_of(p, "mime_type"),
            derived_from: str_of(p, "derived_from"),
            derived_from_hash: str_of(p, "derived_from_hash"),
            build_json: str_of(p, "build_json"),
            bib_source_json: str_of(p, "bib_source_json"),
            external_path: str_of(p, "external_path"),
            modified_ms: int_of(p, "modified_ms"),
        }
    }

    pub fn is_text(&self) -> bool {
        self.kind == FILE_KIND_TEXT
    }

    /// The bytes: inline text, or the blob from `blobs`. `None` when the
    /// blob is absent (pruned, or not yet synced from another device).
    pub fn bytes(&self, blobs: &BlobStore) -> std::io::Result<Option<Vec<u8>>> {
        if let Some(text) = &self.content {
            return Ok(Some(text.as_bytes().to_vec()));
        }
        match &self.blob_ref {
            Some(r) => blobs.get_ref(r),
            None => Ok(Some(Vec::new())),
        }
    }
}

/// What to write for a file.
#[derive(Debug, Clone)]
pub struct PutFile<'a> {
    pub path: &'a str,
    /// `None` = classify from the extension (`default_role_for`).
    pub role: Option<&'a str>,
    pub bytes: &'a [u8],
    /// `None` = inferred: text when the bytes are UTF-8 without NUL.
    pub kind: Option<&'a str>,
    pub mime_type: Option<&'a str>,
}

impl<'a> PutFile<'a> {
    pub fn text(path: &'a str, text: &'a str) -> Self {
        Self {
            path,
            role: None,
            bytes: text.as_bytes(),
            kind: Some(FILE_KIND_TEXT),
            mime_type: None,
        }
    }

    pub fn bytes(path: &'a str, bytes: &'a [u8]) -> Self {
        Self {
            path,
            role: None,
            bytes,
            kind: None,
            mime_type: None,
        }
    }

    pub fn with_role(mut self, role: &'a str) -> Self {
        self.role = Some(role);
        self
    }
}

/// Who is writing.
#[derive(Debug, Clone)]
pub struct Author {
    pub name: String,
    pub kind: ActorKind,
}

impl Author {
    pub fn human(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: ActorKind::Human,
        }
    }
    pub fn agent(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: ActorKind::Agent,
        }
    }
    pub fn system() -> Self {
        Self {
            name: "system:local".into(),
            kind: ActorKind::System,
        }
    }
}

fn manuscript_row(store: &SqliteItemStore, manuscript: ItemId) -> Result<Item, StoreError> {
    let item = store
        .get(manuscript)?
        .ok_or(StoreError::NotFound(manuscript))?;
    if item.schema != "manuscript" {
        return Err(StoreError::Validation(format!(
            "expected a manuscript, got '{}'",
            item.schema
        )));
    }
    Ok(item)
}

fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

/// Create or replace the row for `put.path`. Returns the row after the write.
pub fn put_file(
    store: &SqliteItemStore,
    blobs: &BlobStore,
    manuscript: ItemId,
    put: PutFile<'_>,
    author: &Author,
) -> Result<ManuscriptFileRow, StoreError> {
    let manuscript_item = manuscript_row(store, manuscript)?;
    let path = normalize_path(put.path)?;
    if entry_path_of(&manuscript_item) == path {
        return Err(StoreError::Validation(format!(
            "{path:?} is the entry file; write it through the manuscript body"
        )));
    }
    let role = match put.role {
        Some(r) => {
            validate_role(r)?;
            r.to_string()
        }
        None => default_role_for(&path).to_string(),
    };
    let kind = match put.kind {
        Some(k) if k == FILE_KIND_TEXT || k == FILE_KIND_BINARY => k.to_string(),
        Some(other) => {
            return Err(StoreError::Validation(format!(
                "kind must be text or binary, got {other:?}"
            )))
        }
        None => {
            if looks_like_text(put.bytes) {
                FILE_KIND_TEXT.into()
            } else {
                FILE_KIND_BINARY.into()
            }
        }
    };
    if kind == FILE_KIND_TEXT && std::str::from_utf8(put.bytes).is_err() {
        return Err(StoreError::Validation(format!(
            "{path:?} is declared text but is not valid UTF-8"
        )));
    }
    let content_hash = blobs::sha256_hex_bytes(put.bytes);
    let ext = extension_of(&path);
    let format = if kind == FILE_KIND_TEXT {
        ext.as_deref()
            .and_then(format_for_extension)
            .map(String::from)
    } else {
        None
    };
    let mime = put
        .mime_type
        .map(String::from)
        .unwrap_or_else(|| mime_for_extension(ext.as_deref().unwrap_or("")).to_string());

    let inline = kind == FILE_KIND_TEXT && put.bytes.len() <= INLINE_TEXT_LIMIT;
    let (content, blob_ref) = if inline {
        (
            String::from_utf8(put.bytes.to_vec()).expect("checked above"),
            String::new(),
        )
    } else {
        let digest = blobs
            .put(put.bytes)
            .map_err(|e| StoreError::Storage(format!("blob write for {path:?}: {e}")))?;
        (String::new(), blobs::blob_ref(&digest))
    };

    let id = manuscript_file_id(manuscript, &path);
    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("path".into(), Value::String(path.clone()));
    payload.insert("role".into(), Value::String(role));
    payload.insert("kind".into(), Value::String(kind));
    if let Some(f) = &format {
        payload.insert("format".into(), Value::String(f.clone()));
    }
    payload.insert("content".into(), Value::String(content));
    payload.insert("blob_ref".into(), Value::String(blob_ref));
    payload.insert("content_hash".into(), Value::String(content_hash));
    payload.insert("size".into(), Value::Int(put.bytes.len() as i64));
    payload.insert("mime_type".into(), Value::String(mime));
    payload.insert("modified_ms".into(), Value::Int(now_ms()));

    match store.get(id)? {
        Some(existing) if existing.schema == MANUSCRIPT_FILE_SCHEMA_REF => {
            // Keep what the caller did not send: role when unspecified,
            // derivation and build fields, bibliography spec, external path.
            let mut mutations: Vec<FieldMutation> = Vec::new();
            for (key, value) in &payload {
                if key == "role" && put.role.is_none() {
                    continue;
                }
                mutations.push(FieldMutation::SetPayload(key.clone(), value.clone()));
            }
            store.update(id, mutations)?;
        }
        Some(other) => {
            return Err(StoreError::Validation(format!(
                "id collision: {} is a '{}'",
                id, other.schema
            )));
        }
        None => {
            let now = Utc::now();
            let item = Item {
                id,
                schema: MANUSCRIPT_FILE_SCHEMA_REF.into(),
                payload,
                created: now,
                modified: now,
                author: author.name.clone(),
                author_kind: author.kind,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: true,
                is_starred: false,
                priority: Priority::None,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![TypedReference {
                    target: manuscript,
                    edge_type: EdgeType::IsPartOf,
                    metadata: None,
                }],
                parent: Some(manuscript),
            };
            store.insert(item)?;
            mark_project(store, &manuscript_item, author)?;
        }
    }
    let row = store
        .get(id)?
        .map(|i| ManuscriptFileRow::from_item(&i))
        .ok_or(StoreError::NotFound(id))?;
    Ok(row)
}

/// The row for `path`, if any. One `get` by derived id.
pub fn get_file(
    store: &SqliteItemStore,
    manuscript: ItemId,
    path: &str,
) -> Result<Option<ManuscriptFileRow>, StoreError> {
    let path = normalize_path(path)?;
    let id = manuscript_file_id(manuscript, &path);
    Ok(store
        .get(id)?
        .filter(|i| i.schema == MANUSCRIPT_FILE_SCHEMA_REF && i.parent == Some(manuscript))
        .map(|i| ManuscriptFileRow::from_item(&i)))
}

/// Every file row of the manuscript, sorted by path.
pub fn list_files(
    store: &SqliteItemStore,
    manuscript: ItemId,
) -> Result<Vec<ManuscriptFileRow>, StoreError> {
    let q = ItemQuery {
        schema: Some(MANUSCRIPT_FILE_SCHEMA_REF.into()),
        predicates: vec![Predicate::HasParent(manuscript)],
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    let mut rows: Vec<ManuscriptFileRow> = store
        .query(&q)?
        .iter()
        .map(ManuscriptFileRow::from_item)
        .collect();
    rows.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(rows)
}

/// Delete the row for `path`. `Ok(false)` when there was none.
pub fn delete_file(
    store: &SqliteItemStore,
    manuscript: ItemId,
    path: &str,
) -> Result<bool, StoreError> {
    match get_file(store, manuscript, path)? {
        Some(row) => {
            store.delete(row.id)?;
            Ok(true)
        }
        None => Ok(false),
    }
}

/// Move `from` to `to`: a new row (ids derive from paths) with the same
/// payload, then the old row is deleted. Refuses to overwrite an existing
/// `to`. Text files' Automerge history stays with the old id — a moved
/// text file starts a fresh document from its content (ADR-0030 D3 notes
/// this; re-parenting chunks is a later refinement).
pub fn move_file(
    store: &SqliteItemStore,
    manuscript: ItemId,
    from: &str,
    to: &str,
    author: &Author,
) -> Result<ManuscriptFileRow, StoreError> {
    let from = normalize_path(from)?;
    let to = normalize_path(to)?;
    if from == to {
        return get_file(store, manuscript, &from)?
            .ok_or_else(|| StoreError::Validation(format!("no file at {from:?}")));
    }
    let manuscript_item = manuscript_row(store, manuscript)?;
    if entry_path_of(&manuscript_item) == to {
        return Err(StoreError::Validation(format!("{to:?} is the entry path")));
    }
    if get_file(store, manuscript, &to)?.is_some() {
        return Err(StoreError::Validation(format!(
            "a file already exists at {to:?}"
        )));
    }
    let old_id = manuscript_file_id(manuscript, &from);
    let old = store
        .get(old_id)?
        .filter(|i| i.schema == MANUSCRIPT_FILE_SCHEMA_REF && i.parent == Some(manuscript))
        .ok_or_else(|| StoreError::Validation(format!("no file at {from:?}")))?;
    let new_id = manuscript_file_id(manuscript, &to);
    let mut payload = old.payload.clone();
    payload.insert("path".into(), Value::String(to.clone()));
    payload.insert("modified_ms".into(), Value::Int(now_ms()));
    let ext = extension_of(&to);
    if str_of(&payload, "kind").as_deref() == Some(FILE_KIND_TEXT) {
        match ext.as_deref().and_then(format_for_extension) {
            Some(f) => {
                payload.insert("format".into(), Value::String(f.into()));
            }
            None => {
                payload.remove("format");
            }
        }
    }
    let now = Utc::now();
    let item = Item {
        id: new_id,
        schema: MANUSCRIPT_FILE_SCHEMA_REF.into(),
        payload,
        created: old.created,
        modified: now,
        author: author.name.clone(),
        author_kind: author.kind,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: old.tags.clone(),
        flag: old.flag.clone(),
        is_read: true,
        is_starred: old.is_starred,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![TypedReference {
            target: manuscript,
            edge_type: EdgeType::IsPartOf,
            metadata: None,
        }],
        parent: Some(manuscript),
    };
    store.insert(item)?;
    store.delete(old_id)?;
    // Outputs that named the old path as their source follow it.
    for row in list_files(store, manuscript)? {
        if row.derived_from.as_deref() == Some(from.as_str()) {
            store.update(
                row.id,
                vec![FieldMutation::SetPayload(
                    "derived_from".into(),
                    Value::String(to.clone()),
                )],
            )?;
        }
    }
    store
        .get(new_id)?
        .map(|i| ManuscriptFileRow::from_item(&i))
        .ok_or(StoreError::NotFound(new_id))
}

/// Set one optional string field on a file row (`build_json`,
/// `bib_source_json`, `derived_from`, `derived_from_hash`, `external_path`,
/// `role`, `mime_type`). `None` clears it.
pub fn set_file_field(
    store: &SqliteItemStore,
    manuscript: ItemId,
    path: &str,
    field: &str,
    value: Option<&str>,
) -> Result<ManuscriptFileRow, StoreError> {
    const SETTABLE: &[&str] = &[
        "role",
        "build_json",
        "bib_source_json",
        "derived_from",
        "derived_from_hash",
        "external_path",
        "mime_type",
    ];
    if !SETTABLE.contains(&field) {
        return Err(StoreError::Validation(format!(
            "{field:?} is not a settable file field ({SETTABLE:?})"
        )));
    }
    if field == "role" {
        validate_role(value.unwrap_or(""))?;
    }
    if let (Some(json), true) = (value, field.ends_with("_json")) {
        serde_json::from_str::<serde_json::Value>(json)
            .map_err(|e| StoreError::Validation(format!("{field} is not valid JSON: {e}")))?;
    }
    let row = get_file(store, manuscript, path)?
        .ok_or_else(|| StoreError::Validation(format!("no file at {path:?}")))?;
    let mutation = match value {
        Some(v) => FieldMutation::SetPayload(field.into(), Value::String(v.into())),
        None => FieldMutation::RemovePayload(field.into()),
    };
    store.update(
        row.id,
        vec![
            mutation,
            FieldMutation::SetPayload("modified_ms".into(), Value::Int(now_ms())),
        ],
    )?;
    store
        .get(row.id)?
        .map(|i| ManuscriptFileRow::from_item(&i))
        .ok_or(StoreError::NotFound(row.id))
}

/// Record that `output` was produced from `source` at `input_hash` (D6).
pub fn record_derived(
    store: &SqliteItemStore,
    manuscript: ItemId,
    output: &str,
    source: &str,
    input_hash: &str,
) -> Result<ManuscriptFileRow, StoreError> {
    let source = normalize_path(source)?;
    set_file_field(store, manuscript, output, "derived_from", Some(&source))?;
    set_file_field(
        store,
        manuscript,
        output,
        "derived_from_hash",
        Some(input_hash),
    )
}

// ---------------------------------------------------------------------------
// Manuscript-row structure: entry, targets
// ---------------------------------------------------------------------------

/// The entry path the manuscript row declares, or the format's default.
pub fn entry_path_of(manuscript: &Item) -> String {
    match manuscript.payload.get("entry_path") {
        Some(Value::String(p)) if !p.trim().is_empty() => {
            normalize_path(p).unwrap_or_else(|_| default_entry_for(manuscript))
        }
        _ => default_entry_for(manuscript),
    }
}

fn default_entry_for(manuscript: &Item) -> String {
    let format = str_of(&manuscript.payload, "format").unwrap_or_else(|| "typst".into());
    default_entry_path(&format)
}

fn editorial(
    store: &SqliteItemStore,
    target: ItemId,
    key: &str,
    value: Value,
    reason: &str,
    author: &Author,
) -> Result<(), StoreError> {
    store.apply_operation(OperationSpec {
        target_id: target,
        op_type: OperationType::SetPayload(key.into(), value),
        intent: OperationIntent::Editorial,
        reason: Some(reason.into()),
        batch_id: None,
        author: author.name.clone(),
        author_kind: author.kind,
        retention: RetentionTier::Durable,
    })?;
    Ok(())
}

/// Stamp `project_version = 1` the first time a manuscript grows beyond
/// one file, so one-file readers can tell there is more to see.
fn mark_project(
    store: &SqliteItemStore,
    manuscript: &Item,
    author: &Author,
) -> Result<(), StoreError> {
    if int_of(&manuscript.payload, "project_version").unwrap_or(0) >= 1 {
        return Ok(());
    }
    editorial(
        store,
        manuscript.id,
        "project_version",
        Value::Int(1),
        "became a project",
        author,
    )
}

/// Declare the entry path. Refuses a path that is also a file row (the
/// entry's text lives on the manuscript row, never in a file row).
pub fn set_entry_path(
    store: &SqliteItemStore,
    manuscript: ItemId,
    path: &str,
    author: &Author,
) -> Result<String, StoreError> {
    let item = manuscript_row(store, manuscript)?;
    let path = normalize_path(path)?;
    if get_file(store, manuscript, &path)?.is_some() {
        return Err(StoreError::Validation(format!(
            "{path:?} is a file row; delete it first or pick another entry path"
        )));
    }
    if entry_path_of(&item) != path {
        editorial(
            store,
            manuscript,
            "entry_path",
            Value::String(path.clone()),
            "entry path",
            author,
        )?;
        mark_project(store, &item, author)?;
    }
    Ok(path)
}

/// Declare the targets (`[{id, name, entry, engine, output_kind, args[]}]`).
/// Validated as JSON with unique non-empty ids and normalised entries;
/// `None`/empty restores the implicit single target.
pub fn set_targets(
    store: &SqliteItemStore,
    manuscript: ItemId,
    targets_json: Option<&str>,
    author: &Author,
) -> Result<(), StoreError> {
    let item = manuscript_row(store, manuscript)?;
    match targets_json.map(str::trim).filter(|s| !s.is_empty()) {
        Some(json) => {
            let parsed: Vec<serde_json::Value> = serde_json::from_str(json).map_err(|e| {
                StoreError::Validation(format!("targets_json must be a JSON array: {e}"))
            })?;
            let mut seen = std::collections::HashSet::new();
            for t in &parsed {
                let id = t.get("id").and_then(|v| v.as_str()).unwrap_or("").trim();
                if id.is_empty() {
                    return Err(StoreError::Validation(
                        "every target needs a non-empty id".into(),
                    ));
                }
                if !seen.insert(id.to_string()) {
                    return Err(StoreError::Validation(format!(
                        "duplicate target id {id:?}"
                    )));
                }
                if let Some(entry) = t.get("entry").and_then(|v| v.as_str()) {
                    normalize_path(entry)?;
                }
            }
            editorial(
                store,
                manuscript,
                "targets_json",
                Value::String(json.to_string()),
                "targets",
                author,
            )?;
            mark_project(store, &item, author)?;
        }
        None => {
            if item.payload.contains_key("targets_json") {
                store.apply_operation(OperationSpec {
                    target_id: manuscript,
                    op_type: OperationType::RemovePayload("targets_json".into()),
                    intent: OperationIntent::Editorial,
                    reason: Some("targets cleared".into()),
                    batch_id: None,
                    author: author.name.clone(),
                    author_kind: author.kind,
                    retention: RetentionTier::Durable,
                })?;
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// The project as one read
// ---------------------------------------------------------------------------

/// The manuscript as a project, in one read: the entry (from the manuscript
/// row) and every file row. The engine turns this into a `ProjectTree`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectSnapshot {
    pub manuscript_id: ItemId,
    pub title: String,
    /// `typst | latex | markdown | plaintext`.
    pub format: String,
    pub entry_path: String,
    pub entry_text: String,
    pub entry_hash: String,
    pub files: Vec<ManuscriptFileRow>,
    pub targets_json: Option<String>,
    pub working_copy_path: Option<String>,
    pub project_version: i64,
}

impl ProjectSnapshot {
    pub fn file(&self, path: &str) -> Option<&ManuscriptFileRow> {
        self.files.iter().find(|f| f.path == path)
    }

    /// A stable stamp over every file's identity and bytes: two snapshots
    /// with equal stamps build identical outputs.
    pub fn input_stamp(&self, target_id: &str) -> String {
        let mut lines: Vec<String> = self
            .files
            .iter()
            .map(|f| format!("{}\t{}", f.path, f.content_hash))
            .collect();
        lines.push(format!("{}\t{}", self.entry_path, self.entry_hash));
        lines.sort();
        lines.push(format!("target\t{target_id}"));
        blobs::sha256_hex_bytes(lines.join("\n").as_bytes())
    }
}

pub fn load_project(
    store: &SqliteItemStore,
    manuscript: ItemId,
) -> Result<ProjectSnapshot, StoreError> {
    let item = manuscript_row(store, manuscript)?;
    let entry_text = str_of(&item.payload, "body_content").unwrap_or_default();
    let entry_hash = match str_of(&item.payload, "body_content_hash") {
        Some(h) if !h.is_empty() => h,
        _ => crate::manuscript_ops::sha256_hex(&entry_text),
    };
    Ok(ProjectSnapshot {
        manuscript_id: manuscript,
        title: str_of(&item.payload, "title").unwrap_or_default(),
        format: str_of(&item.payload, "format").unwrap_or_else(|| "typst".into()),
        entry_path: entry_path_of(&item),
        entry_text,
        entry_hash,
        files: list_files(store, manuscript)?,
        targets_json: str_of(&item.payload, "targets_json").filter(|s| !s.trim().is_empty()),
        working_copy_path: str_of(&item.payload, "working_copy_path")
            .filter(|s| !s.trim().is_empty()),
        project_version: int_of(&item.payload, "project_version").unwrap_or(0),
    })
}

// ---------------------------------------------------------------------------
// Builds
// ---------------------------------------------------------------------------

/// What a build wrote.
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct BuildRecord {
    pub target_id: String,
    pub engine: String,
    /// `running | ok | failed | cancelled`.
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
}

/// A build row as callers see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManuscriptBuildRow {
    pub id: ItemId,
    pub manuscript_id: ItemId,
    pub record: BuildRecord,
    pub created_ms: i64,
}

impl ManuscriptBuildRow {
    pub fn from_item(item: &Item) -> Self {
        let p = &item.payload;
        Self {
            id: item.id,
            manuscript_id: item.parent.unwrap_or(Uuid::nil()),
            record: BuildRecord {
                target_id: str_of(p, "target_id").unwrap_or_default(),
                engine: str_of(p, "engine").unwrap_or_default(),
                status: str_of(p, "status").unwrap_or_else(|| BUILD_STATUS_RUNNING.into()),
                input_stamp: str_of(p, "input_stamp").unwrap_or_default(),
                started_ms: int_of(p, "started_ms").unwrap_or(0),
                finished_ms: int_of(p, "finished_ms"),
                duration_ms: int_of(p, "duration_ms"),
                outputs_json: str_of(p, "outputs_json"),
                diagnostics_json: str_of(p, "diagnostics_json"),
                steps_json: str_of(p, "steps_json"),
                allow_shell: matches!(p.get("allow_shell"), Some(Value::Bool(true))),
                message: str_of(p, "message"),
            },
            created_ms: item.created.timestamp_millis(),
        }
    }
}

fn build_payload(record: &BuildRecord) -> BTreeMap<String, Value> {
    let mut p: BTreeMap<String, Value> = BTreeMap::new();
    p.insert("target_id".into(), Value::String(record.target_id.clone()));
    p.insert("engine".into(), Value::String(record.engine.clone()));
    p.insert("status".into(), Value::String(record.status.clone()));
    p.insert(
        "input_stamp".into(),
        Value::String(record.input_stamp.clone()),
    );
    p.insert("started_ms".into(), Value::Int(record.started_ms));
    if let Some(v) = record.finished_ms {
        p.insert("finished_ms".into(), Value::Int(v));
    }
    if let Some(v) = record.duration_ms {
        p.insert("duration_ms".into(), Value::Int(v));
    }
    for (key, value) in [
        ("outputs_json", &record.outputs_json),
        ("diagnostics_json", &record.diagnostics_json),
        ("steps_json", &record.steps_json),
        ("message", &record.message),
    ] {
        if let Some(v) = value {
            p.insert(key.into(), Value::String(v.clone()));
        }
    }
    p.insert("allow_shell".into(), Value::Bool(record.allow_shell));
    p
}

/// Write a build row (typically `running`, then finished with
/// [`finish_build`]; or complete in one go).
pub fn record_build(
    store: &SqliteItemStore,
    manuscript: ItemId,
    record: &BuildRecord,
    author: &Author,
) -> Result<ManuscriptBuildRow, StoreError> {
    manuscript_row(store, manuscript)?;
    if record.target_id.trim().is_empty() || record.engine.trim().is_empty() {
        return Err(StoreError::Validation(
            "a build needs a target_id and an engine".into(),
        ));
    }
    let now = Utc::now();
    let item = Item {
        id: Uuid::new_v4(),
        schema: MANUSCRIPT_BUILD_SCHEMA_REF.into(),
        payload: build_payload(record),
        created: now,
        modified: now,
        author: author.name.clone(),
        author_kind: author.kind,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: true,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![TypedReference {
            target: manuscript,
            edge_type: EdgeType::IsPartOf,
            metadata: None,
        }],
        parent: Some(manuscript),
    };
    let id = store.insert(item)?;
    store
        .get(id)?
        .map(|i| ManuscriptBuildRow::from_item(&i))
        .ok_or(StoreError::NotFound(id))
}

/// Complete a `running` build: status, timing, outputs, diagnostics, steps.
pub fn finish_build(
    store: &SqliteItemStore,
    build: ItemId,
    record: &BuildRecord,
) -> Result<ManuscriptBuildRow, StoreError> {
    let existing = store
        .get(build)?
        .filter(|i| i.schema == MANUSCRIPT_BUILD_SCHEMA_REF)
        .ok_or(StoreError::NotFound(build))?;
    let mutations: Vec<FieldMutation> = build_payload(record)
        .into_iter()
        .map(|(k, v)| FieldMutation::SetPayload(k, v))
        .collect();
    store.update(existing.id, mutations)?;
    store
        .get(build)?
        .map(|i| ManuscriptBuildRow::from_item(&i))
        .ok_or(StoreError::NotFound(build))
}

/// Builds of a manuscript, newest first.
pub fn list_builds(
    store: &SqliteItemStore,
    manuscript: ItemId,
    limit: Option<usize>,
) -> Result<Vec<ManuscriptBuildRow>, StoreError> {
    let q = ItemQuery {
        schema: Some(MANUSCRIPT_BUILD_SCHEMA_REF.into()),
        predicates: vec![Predicate::HasParent(manuscript)],
        sort: vec![SortDescriptor {
            field: "created".into(),
            ascending: false,
        }],
        limit,
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    Ok(store
        .query(&q)?
        .iter()
        .map(ManuscriptBuildRow::from_item)
        .collect())
}

/// The newest `ok` build of `target` (or of any target when `None`).
pub fn latest_ok_build(
    store: &SqliteItemStore,
    manuscript: ItemId,
    target_id: Option<&str>,
) -> Result<Option<ManuscriptBuildRow>, StoreError> {
    Ok(list_builds(store, manuscript, None)?.into_iter().find(|b| {
        b.record.status == crate::schemas::BUILD_STATUS_OK
            && target_id.map(|t| t == b.record.target_id).unwrap_or(true)
    }))
}

/// Keep the newest `keep` builds of `manuscript`; delete the rest. Returns
/// how many were removed.
pub fn compact_builds(
    store: &SqliteItemStore,
    manuscript: ItemId,
    keep: usize,
) -> Result<usize, StoreError> {
    let builds = list_builds(store, manuscript, None)?;
    let mut removed = 0;
    for build in builds.into_iter().skip(keep) {
        store.delete(build.id)?;
        removed += 1;
    }
    Ok(removed)
}

/// Compaction for the daemon's hygiene cycle: every manuscript keeps its
/// newest `keep` builds; builds whose manuscript is gone are swept.
pub fn compact_all_builds(store: &SqliteItemStore, keep: usize) -> Result<usize, StoreError> {
    let q = ItemQuery {
        schema: Some(MANUSCRIPT_BUILD_SCHEMA_REF.into()),
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    let all = store.query(&q)?;
    let mut by_parent: BTreeMap<Option<ItemId>, Vec<Item>> = BTreeMap::new();
    for item in all {
        by_parent.entry(item.parent).or_default().push(item);
    }
    let mut removed = 0;
    for (parent, mut items) in by_parent {
        let keep_here = match parent {
            Some(p) if store.get(p)?.is_some() => keep,
            _ => 0,
        };
        items.sort_by_key(|item| std::cmp::Reverse(item.created));
        for item in items.into_iter().skip(keep_here) {
            store.delete(item.id)?;
            removed += 1;
        }
    }
    Ok(removed)
}

// ---------------------------------------------------------------------------
// Payload helpers
// ---------------------------------------------------------------------------

fn str_of(payload: &BTreeMap<String, Value>, key: &str) -> Option<String> {
    match payload.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn int_of(payload: &BTreeMap<String, Value>, key: &str) -> Option<i64> {
    match payload.get(key) {
        Some(Value::Int(i)) => Some(*i),
        Some(Value::Float(f)) => Some(*f as i64),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_normalise_and_reject_escapes() {
        assert_eq!(
            normalize_path("chapters/intro.tex").unwrap(),
            "chapters/intro.tex"
        );
        assert_eq!(
            normalize_path("./figures//fig1.png").unwrap(),
            "figures/fig1.png"
        );
        assert_eq!(normalize_path("a\\b.typ").unwrap(), "a/b.typ");
        assert!(normalize_path("../x.tex").is_err());
        assert!(normalize_path("a/../x.tex").is_err());
        assert!(normalize_path("/etc/passwd").is_err());
        assert!(normalize_path("   ").is_err());
        assert!(normalize_path("./").is_err());
    }

    #[test]
    fn extensions_and_defaults() {
        assert_eq!(extension_of("figures/fig.PNG").as_deref(), Some("png"));
        assert_eq!(extension_of(".gitignore"), None);
        assert_eq!(extension_of("README"), None);
        assert_eq!(default_entry_path("typst"), "main.typ");
        assert_eq!(default_entry_path("latex"), "main.tex");
        assert_eq!(default_entry_path("markdown"), "main.md");
        assert_eq!(default_role_for("chapters/a.tex"), "chapter");
        assert_eq!(default_role_for("refs.bib"), "bibliography");
        assert_eq!(default_role_for("figures/f.pdf"), "figure");
        assert_eq!(default_role_for("figures/f.py"), "figure-source");
        assert_eq!(default_role_for("data/x.csv"), "data");
        assert_eq!(default_role_for("aastex.cls"), "style");
        assert_eq!(default_role_for("Makefile"), "aux");
        assert_eq!(format_for_extension("tex"), Some("latex"));
        assert_eq!(format_for_extension("bib"), Some("bibtex"));
        assert_eq!(format_for_extension("sty"), Some("latex"));
    }

    #[test]
    fn text_detection() {
        assert!(looks_like_text(b"= Hello\nworld"));
        assert!(!looks_like_text(b"\x89PNG\r\n\x1a\n\0\0"));
        assert!(!looks_like_text(&[0xff, 0xfe, 0x00]));
    }
}

// ---------------------------------------------------------------------------
// Whole-project operations: a new manuscript, the format, a revision
// ---------------------------------------------------------------------------

/// What a new manuscript starts with.
#[derive(Debug, Clone)]
pub struct NewManuscript<'a> {
    pub title: &'a str,
    /// `typst | latex | markdown | plaintext`.
    pub format: &'a str,
    /// The entry text.
    pub body: &'a str,
    /// Project-relative entry path; `None` = `main.<ext>` for the format.
    pub entry_path: Option<&'a str>,
    /// The manuscript folder (`parent_collection_ref`), if any.
    pub collection_ref: Option<&'a str>,
}

/// Create a manuscript row: the entry file with its text, marked a project
/// from the start (an import fills in the rest). Returns the row.
pub fn create_manuscript(
    store: &SqliteItemStore,
    new: NewManuscript<'_>,
    author: &Author,
) -> Result<Item, StoreError> {
    let title = new.title.trim();
    if title.is_empty() {
        return Err(StoreError::Validation("title must not be empty".into()));
    }
    let format = new.format.trim();
    if format.is_empty() {
        return Err(StoreError::Validation("format must not be empty".into()));
    }
    let entry_path = match new.entry_path {
        Some(p) => normalize_path(p)?,
        None => default_entry_path(format),
    };
    let id = Uuid::new_v4();
    let now = Utc::now();
    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("title".into(), Value::String(title.to_string()));
    payload.insert("format".into(), Value::String(format.to_string()));
    payload.insert("status".into(), Value::String("draft".into()));
    payload.insert("body_content".into(), Value::String(new.body.to_string()));
    payload.insert(
        "body_content_hash".into(),
        Value::String(crate::manuscript_ops::sha256_hex(new.body)),
    );
    payload.insert(
        "body_modified_at".into(),
        Value::String(crate::manuscript_ops::iso8601_now()),
    );
    payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
    payload.insert("entry_path".into(), Value::String(entry_path));
    payload.insert("project_version".into(), Value::Int(1));
    if let Some(c) = new.collection_ref.map(str::trim).filter(|c| !c.is_empty()) {
        payload.insert("parent_collection_ref".into(), Value::String(c.to_string()));
    }
    let item = Item {
        id,
        schema: "manuscript".into(),
        payload,
        created: now,
        modified: now,
        author: author.name.clone(),
        author_kind: author.kind,
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
    };
    store.insert(item.clone())?;
    Ok(item)
}

/// Declare the manuscript's format (`typst | latex | markdown | plaintext`)
/// — what an import into an existing manuscript does when the directory's
/// entry is written in another grammar.
pub fn set_format(
    store: &SqliteItemStore,
    manuscript: ItemId,
    format: &str,
    author: &Author,
) -> Result<(), StoreError> {
    let item = manuscript_row(store, manuscript)?;
    let format = format.trim();
    if format.is_empty() {
        return Err(StoreError::Validation("format must not be empty".into()));
    }
    if str_of(&item.payload, "format").as_deref() == Some(format) {
        return Ok(());
    }
    editorial(
        store,
        manuscript,
        "format",
        Value::String(format.to_string()),
        "format",
        author,
    )
}

/// A revision of the whole tree (ADR-0030 D8).
#[derive(Debug, Clone)]
pub struct ProjectRevision<'a> {
    pub revision_tag: &'a str,
    pub snapshot_reason: &'a str,
    /// `blob:sha256:…` of the `.tar.zst` archive in the workspace CAS.
    pub archive_ref: &'a str,
    /// The bundle manifest the archive carries, canonical JSON.
    pub manifest_json: &'a str,
    /// The input stamp of the tree the archive holds
    /// ([`ProjectSnapshot::input_stamp`]).
    pub content_hash: &'a str,
    pub word_count: Option<i64>,
}

/// Record a revision whose source archive is the packed tree. Same lineage
/// as [`crate::manuscript_ops::create_revision`] — predecessor via
/// `Supersedes`, the manuscript's head pointer advanced as an attributed
/// edit — so one-file and project revisions interleave in one history.
pub fn create_project_revision(
    store: &SqliteItemStore,
    manuscript: ItemId,
    rev: ProjectRevision<'_>,
    author: &Author,
) -> Result<Item, StoreError> {
    let item = manuscript_row(store, manuscript)?;
    let tag = rev.revision_tag.trim();
    if tag.is_empty() {
        return Err(StoreError::Validation(
            "revision_tag must not be empty".into(),
        ));
    }
    if !rev.archive_ref.starts_with(blobs::BLOB_REF_PREFIX) {
        return Err(StoreError::Validation(format!(
            "archive_ref must be a {} reference",
            blobs::BLOB_REF_PREFIX
        )));
    }
    let predecessor = crate::manuscript_ops::current_head(store, manuscript, &item)?;

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert(
        "parent_manuscript_ref".into(),
        Value::String(manuscript.to_string()),
    );
    payload.insert("revision_tag".into(), Value::String(tag.to_string()));
    payload.insert(
        "content_hash".into(),
        Value::String(rev.content_hash.to_string()),
    );
    payload.insert("pdf_artifact_ref".into(), Value::String(String::new()));
    payload.insert(
        "source_archive_ref".into(),
        Value::String(rev.archive_ref.to_string()),
    );
    payload.insert(
        "bundle_manifest_json".into(),
        Value::String(rev.manifest_json.to_string()),
    );
    payload.insert(
        "snapshot_reason".into(),
        Value::String(rev.snapshot_reason.to_string()),
    );
    if let Some(wc) = rev.word_count {
        payload.insert("word_count".into(), Value::Int(wc));
    }
    if let Some(pred) = &predecessor {
        payload.insert(
            "predecessor_revision_ref".into(),
            Value::String(pred.to_string()),
        );
    }

    let mut references = vec![TypedReference {
        target: manuscript,
        edge_type: EdgeType::IsPartOf,
        metadata: None,
    }];
    if let Some(pred) = predecessor {
        references.push(TypedReference {
            target: pred,
            edge_type: EdgeType::Supersedes,
            metadata: None,
        });
    }

    let now = Utc::now();
    let revision = Item {
        id: Uuid::new_v4(),
        schema: "manuscript-revision".into(),
        payload,
        created: now,
        modified: now,
        author: author.name.clone(),
        author_kind: author.kind,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references,
        parent: Some(manuscript),
    };
    store.insert(revision.clone())?;
    editorial(
        store,
        manuscript,
        "current_revision_ref",
        Value::String(revision.id.to_string()),
        &format!("revision '{tag}'"),
        author,
    )?;
    Ok(revision)
}
