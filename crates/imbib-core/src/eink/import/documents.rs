//! Documents the tablet holds that imbib did not put there — notebooks
//! written on the tablet, PDFs dropped into a folder by hand — listed for
//! the researcher and brought into the store on request.
//!
//! A document inside `imbib/<Library>/<Collection>` is filed there without
//! asking; anywhere else the caller names the library (and collection).
//! A PDF or ePUB whose bytes match a linked file already in the store is
//! *adopted*: the existing publication gains the mirror row, and the
//! tablet's rendition and rows come in as for any mirrored paper. Anything
//! else becomes a new publication — `@misc` for a notebook (title = its
//! name, the rendered PDF as its one file), an entry from the first page's
//! text for a PDF — or, on request, a note artifact.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::{TimeZone, Utc};
use impress_core::item::Value;
use impress_core::query::{ItemQuery, Predicate};
use impress_core::store::{FieldMutation, ItemStore};
use impress_remarkable::rm::parse_rm;
use impress_remarkable::rmdoc::{read_rmdoc, RmDocumentArchive, SourceKind};
use impress_remarkable::{DownloadKind, RemarkableDocument};

use super::super::apply::{download_dir, resolve_device, walk_tablet};
use super::super::collections::CollectionIndex;
use super::super::config::{EinkDeviceConfig, MirrorMode, MirrorState, SCHEMA_MIRROR};
use super::super::paths;
use super::super::transport::{EinkError, EinkTransport};
use super::{convert_archive, reconcile};
use crate::files::naming::{generate_filename, FilenameOptions};
use crate::unified::store_api::{parse_uuid, ImbibStore, StoreApiError};

pub const KIND_NOTEBOOK: &str = "notebook";
pub const AS_PUBLICATION: &str = "publication";
pub const AS_NOTE: &str = "note";

/// A document on the tablet with no mirror row behind it.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkUnmatchedDocument {
    pub remote_id: String,
    pub name: String,
    /// `notebook`, `pdf` or `epub`.
    pub kind: String,
    /// Folder names from the top, joined with `/` (empty at the top level).
    pub remote_path: String,
    pub remote_parent_id: String,
    /// Under the device's root folder.
    pub in_imbib_tree: bool,
    /// Resolved from the folder names when they match a library and a
    /// collection chain; the import needs nothing more then.
    pub library_id: Option<String>,
    pub collection_id: Option<String>,
    pub modified_ms: i64,
    pub page_count: u32,
}

/// What importing one document did.
#[derive(Debug, Clone, Default, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct EinkDocumentImportOutcome {
    pub remote_id: String,
    /// `publication` or `note`.
    pub as_kind: String,
    pub publication_id: Option<String>,
    pub artifact_id: Option<String>,
    /// The bytes matched a file already in the store.
    pub adopted_existing: bool,
    pub linked_file_id: Option<String>,
    pub mirror_id: Option<String>,
    pub annotations_created: u32,
    pub annotations_updated: u32,
    pub ink_pending_ocr: u32,
    pub warnings: Vec<String>,
    pub trace: Vec<String>,
}

/// What to import and where.
#[derive(Debug, Clone, Default)]
pub struct ImportDocumentRequest {
    pub remote_id: String,
    /// Required unless the document sits under `imbib/<Library>`.
    pub library_id: Option<String>,
    pub collection_id: Option<String>,
    /// `publication` (default) or `note`.
    pub as_kind: String,
    /// The library folder to write into instead of the one derived from
    /// the library id (tests).
    pub library_dir: Option<PathBuf>,
}

/// Where a tablet path lands in the store.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PathResolution {
    pub in_imbib_tree: bool,
    pub library_id: Option<String>,
    pub collection_id: Option<String>,
}

/// `imbib/<Library>/<Collection>/…` → the library and collection it names.
pub fn resolve_tablet_path(
    index: &CollectionIndex,
    root_name: &str,
    path: &[String],
) -> PathResolution {
    let in_tree = path
        .first()
        .map(|top| top.trim().eq_ignore_ascii_case(root_name.trim()))
        .unwrap_or(false);
    if !in_tree {
        return PathResolution::default();
    }
    let library_id = path.get(1).and_then(|name| index.library_by_name(name));
    let collection_id = match (&library_id, path.len() > 2) {
        (Some(library), true) => index.find_by_chain(library, &path[2..]),
        _ => None,
    };
    PathResolution {
        in_imbib_tree: true,
        library_id,
        collection_id,
    }
}

pub fn document_kind(doc: &RemarkableDocument) -> &'static str {
    match doc.file_type.trim().to_ascii_lowercase().as_str() {
        "pdf" => "pdf",
        "epub" => "epub",
        _ => KIND_NOTEBOOK,
    }
}

/// Every remote id a mirror row (on any device) refers to, current or
/// superseded.
fn known_remote_ids(store: &ImbibStore) -> Result<HashSet<String>, StoreApiError> {
    let q = ItemQuery {
        schema: Some(SCHEMA_MIRROR.into()),
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    let mut known = HashSet::new();
    for item in store.store.query(&q)? {
        for key in ["remote_id", "superseded_remote_id"] {
            if let Some(Value::String(id)) = item.payload.get(key) {
                if !id.is_empty() {
                    known.insert(id.clone());
                }
            }
        }
    }
    Ok(known)
}

/// The documents on the tablet imbib knows nothing about, in-tree first.
pub fn list_unmatched(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    transport: &dyn EinkTransport,
) -> Result<Vec<EinkUnmatchedDocument>, EinkError> {
    let mut trace = Vec::new();
    let (folders, documents, _) = walk_tablet(transport, &device.root_folder_name, &mut trace)?;
    let known = known_remote_ids(store)?;
    let index = CollectionIndex::load(store)?;
    let mut out: Vec<EinkUnmatchedDocument> = documents
        .into_iter()
        .filter(|doc| !known.contains(&doc.id))
        .map(|doc| {
            let path = folders.path_of(&doc.parent);
            let resolved = resolve_tablet_path(&index, &device.root_folder_name, &path);
            EinkUnmatchedDocument {
                kind: document_kind(&doc).into(),
                remote_id: doc.id,
                name: doc.visible_name,
                remote_path: path.join("/"),
                remote_parent_id: doc.parent,
                in_imbib_tree: resolved.in_imbib_tree,
                library_id: resolved.library_id,
                collection_id: resolved.collection_id,
                modified_ms: doc.last_modified_ms,
                page_count: doc.page_count,
            }
        })
        .collect();
    out.sort_by(|a, b| {
        b.in_imbib_tree
            .cmp(&a.in_imbib_tree)
            .then_with(|| a.remote_path.cmp(&b.remote_path))
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(out)
}

/// Bring one tablet document into the store.
pub fn import_document(
    store: &ImbibStore,
    device: &EinkDeviceConfig,
    transport: &dyn EinkTransport,
    req: &ImportDocumentRequest,
) -> Result<EinkDocumentImportOutcome, EinkError> {
    let as_kind = if req.as_kind.trim().is_empty() {
        AS_PUBLICATION
    } else {
        req.as_kind.trim()
    };
    if as_kind != AS_PUBLICATION && as_kind != AS_NOTE {
        return Err(EinkError::Invalid(format!(
            "as_kind must be {AS_PUBLICATION:?} or {AS_NOTE:?}, not {as_kind:?}"
        )));
    }
    let mut outcome = EinkDocumentImportOutcome {
        remote_id: req.remote_id.clone(),
        as_kind: as_kind.into(),
        ..Default::default()
    };
    if !transport.reachable() {
        return Err(EinkError::Transport(format!(
            "tablet at {} is not reachable",
            device.base_url
        )));
    }
    let (folders, documents, _) =
        walk_tablet(transport, &device.root_folder_name, &mut outcome.trace)?;
    let doc = documents
        .into_iter()
        .find(|d| d.id == req.remote_id)
        .ok_or_else(|| {
            EinkError::Invalid(format!("document {} is not on the tablet", req.remote_id))
        })?;
    if known_remote_ids(store)?.contains(&doc.id) {
        return Err(EinkError::Invalid(format!(
            "document {} ({:?}) already belongs to a mirrored publication",
            doc.id, doc.visible_name
        )));
    }
    let path = folders.path_of(&doc.parent);
    let index = CollectionIndex::load(store)?;
    let resolved = resolve_tablet_path(&index, &device.root_folder_name, &path);
    let kind = document_kind(&doc);
    outcome.trace.push(format!(
        "import {}: {:?} ({kind}) at {:?}",
        doc.id,
        doc.visible_name,
        path.join("/")
    ));

    let library_id = req
        .library_id
        .clone()
        .or_else(|| resolved.library_id.clone());
    let collection_id = req
        .collection_id
        .clone()
        .or_else(|| resolved.collection_id.clone());

    // Downloads go under the library the document will belong to; a note
    // has no library, so its files sit in the support folder.
    let library_dir = match (&req.library_dir, &library_id) {
        (Some(dir), _) => dir.clone(),
        (None, Some(library)) => {
            let home = paths::user_home().ok_or_else(|| EinkError::Io("no HOME".into()))?;
            paths::library_dir_for_write(library, &home)
        }
        (None, None) => {
            let home = paths::user_home().ok_or_else(|| EinkError::Io("no HOME".into()))?;
            paths::real_home(&home).join("Library/Application Support/imbib")
        }
    };
    let dest = download_dir(&library_dir, &doc.id);
    let rendered_pdf = transport.download(&doc.id, DownloadKind::Pdf, &dest)?;
    let rmdoc_path = transport.download(&doc.id, DownloadKind::Rmdoc, &dest).ok();
    let archive = match &rmdoc_path {
        Some(path) => match read_rmdoc(path) {
            Ok(archive) => Some(archive),
            Err(error) => {
                outcome
                    .warnings
                    .push(format!("archive unreadable ({error}); rendition only"));
                None
            }
        },
        None => {
            outcome
                .warnings
                .push("the tablet gave no archive; rendition only".into());
            None
        }
    };

    if as_kind == AS_NOTE {
        return import_as_note(store, &doc, &path, &rendered_pdf, archive.as_ref(), outcome);
    }
    let library_id = library_id.ok_or_else(|| {
        EinkError::Invalid(format!(
            "document {:?} is not under {}/<Library> on the tablet: name the library to import it into",
            doc.visible_name, device.root_folder_name
        ))
    })?;
    let library = store
        .list_libraries()?
        .into_iter()
        .find(|l| l.id.eq_ignore_ascii_case(&library_id))
        .ok_or_else(|| EinkError::Invalid(format!("no library {library_id}")))?;
    if let Some(collection) = &collection_id {
        parse_uuid(collection)?;
    }

    // --- the publication ---------------------------------------------------
    let source = archive.as_ref().and_then(|a| a.source.as_ref());
    let (publication_id, primary_file) = match source {
        Some(source) => {
            let sha = paths::sha256_bytes(&source.bytes);
            match find_file_by_sha(store, &sha)? {
                Some((publication_id, file_id, filename)) => {
                    if store
                        .eink_mirror_for_publication(
                            Some(device.id.clone()),
                            publication_id.clone(),
                        )?
                        .is_some()
                    {
                        return Err(EinkError::Invalid(format!(
                            "the bytes match publication {publication_id}, which is already mirrored to this device; unmark it first"
                        )));
                    }
                    outcome.adopted_existing = true;
                    outcome.trace.push(format!(
                        "adopted publication {publication_id}: file {filename} has the same checksum"
                    ));
                    if let Some(collection) = &collection_id {
                        store
                            .add_to_collection(vec![publication_id.clone()], collection.clone())?;
                        outcome.trace.push(format!(
                            "filed {publication_id} into collection {collection}"
                        ));
                    }
                    (publication_id, (file_id, filename, sha))
                }
                None => create_publication_for_source(
                    store,
                    &library.id,
                    collection_id.as_deref(),
                    &doc,
                    source.kind,
                    &source.bytes,
                    &sha,
                    &library_dir,
                    &device.id,
                    &mut outcome,
                )?,
            }
        }
        None => create_publication_for_notebook(
            store,
            &library.id,
            collection_id.as_deref(),
            &doc,
            &rendered_pdf,
            &library_dir,
            &device.id,
            &mut outcome,
        )?,
    };
    outcome.publication_id = Some(publication_id.clone());
    outcome.linked_file_id = Some(primary_file.0.clone());

    // --- the mirror row -----------------------------------------------------
    let now = now_ms();
    let row = store.eink_insert_mirror(
        &device.id,
        &publication_id,
        device.mirror_mode == MirrorMode::Individual,
        MirrorState::Uploaded,
        vec![
            ("remote_id", Value::String(doc.id.clone())),
            ("remote_parent_id", Value::String(doc.parent.clone())),
            ("remote_name", Value::String(doc.visible_name.clone())),
            ("remote_path", Value::String(path.join("/"))),
            ("source_kind", Value::String(kind.into())),
            ("linked_file_id", Value::String(primary_file.0.clone())),
            ("uploaded_sha256", Value::String(primary_file.2.clone())),
            ("uploaded_at_ms", Value::Int(now)),
            ("last_attempt_ms", Value::Int(now)),
            ("remote_modified_ms", Value::Int(doc.last_modified_ms)),
        ],
    )?;
    outcome.mirror_id = Some(row.id.clone());
    outcome.trace.push(format!(
        "mirror row {} written for {publication_id}",
        row.id
    ));

    // --- the rendition and the rows -----------------------------------------
    // A source-backed document gets the rendition as a variant; a notebook's
    // primary file already *is* the rendition.
    if source.is_some() && device.import_annotated_pdf {
        let variant = super::variant::upsert_annotated_variant(
            store,
            &publication_id,
            &library_dir,
            &primary_file.1,
            &rendered_pdf,
            &device.id,
            &doc.id,
            doc.last_modified_ms,
        )?;
        store.eink_update_mirror(
            &row.id,
            vec![(
                "annotated_file_id",
                Some(Value::String(variant.linked_file_id.clone())),
            )],
        )?;
        outcome
            .trace
            .push(format!("rendition stored as {}", variant.relative_path));
    }
    if let Some(archive) = archive.as_ref().filter(|_| device.import_rmdoc) {
        let drafts = convert_archive(
            archive,
            device,
            &doc.id,
            &rendered_pdf,
            &mut outcome.warnings,
        );
        let reconciled = reconcile::reconcile(
            store,
            &primary_file.0,
            &device.id,
            &doc.id,
            &library_dir,
            drafts,
        )?;
        outcome.annotations_created = reconciled.created;
        outcome.annotations_updated = reconciled.updated;
        outcome.ink_pending_ocr = reconciled.ink_pending_ocr;
        outcome.trace.push(format!(
            "rows: +{} ~{} -{} ({} ink pending OCR)",
            reconciled.created, reconciled.updated, reconciled.deleted, reconciled.ink_pending_ocr
        ));
    }
    store.eink_update_mirror(
        &row.id,
        vec![(
            "imported_modified_ms",
            Some(Value::Int(doc.last_modified_ms)),
        )],
    )?;
    Ok(outcome)
}

/// A note artifact carrying the typed text, with the rendition beside it.
fn import_as_note(
    store: &ImbibStore,
    doc: &RemarkableDocument,
    path: &[String],
    rendered_pdf: &Path,
    archive: Option<&RmDocumentArchive>,
    mut outcome: EinkDocumentImportOutcome,
) -> Result<EinkDocumentImportOutcome, EinkError> {
    let typed = archive.map(typed_text_of).unwrap_or_default();
    let mut notes = String::new();
    if !typed.is_empty() {
        notes.push_str(&typed);
        notes.push_str("\n\n");
    }
    notes.push_str(&format!(
        "Rendered from the reMarkable ({} page{}): {}",
        doc.page_count.max(1),
        if doc.page_count == 1 { "" } else { "s" },
        rendered_pdf.display()
    ));
    let size = std::fs::metadata(rendered_pdf)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    let sha = paths::sha256_file(rendered_pdf).ok();
    let title = if doc.visible_name.trim().is_empty() {
        "reMarkable notebook".to_string()
    } else {
        doc.visible_name.trim().to_string()
    };
    let context = if path.is_empty() {
        "reMarkable".to_string()
    } else {
        format!("reMarkable: {}", path.join("/"))
    };
    let row = store.create_artifact(
        "impress/artifact/note".into(),
        title,
        None,
        Some(notes),
        Some("remarkable".into()),
        rendered_pdf
            .file_name()
            .map(|n| n.to_string_lossy().to_string()),
        sha,
        Some(size),
        Some("application/pdf".into()),
        Some(context),
        None,
        None,
        None,
        vec!["remarkable".into()],
    )?;
    outcome.artifact_id = Some(row.id.clone());
    outcome.trace.push(format!(
        "note artifact {} written ({} typed chars)",
        row.id,
        typed.len()
    ));
    Ok(outcome)
}

/// The typed text of every page, in page order.
pub fn typed_text_of(archive: &RmDocumentArchive) -> String {
    let mut out = Vec::new();
    for page in &archive.pages {
        let Some(bytes) = &page.rm_bytes else {
            continue;
        };
        if let Ok(scene) = parse_rm(bytes) {
            if let Some(text) = scene.root_text.as_ref().map(|t| t.text()) {
                if !text.trim().is_empty() {
                    out.push(text.trim().to_string());
                }
            }
        }
    }
    out.join("\n\n")
}

/// (publication id, linked file id, filename) of the first linked file
/// whose bytes hash to `sha`.
fn find_file_by_sha(
    store: &ImbibStore,
    sha: &str,
) -> Result<Option<(String, String, String)>, StoreApiError> {
    let q = ItemQuery {
        schema: Some("imbib/linked-file".into()),
        predicates: vec![Predicate::Eq("sha256".into(), Value::String(sha.into()))],
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    let items = store.store.query(&q)?;
    let mut candidates: Vec<(String, String, String)> = items
        .into_iter()
        .filter_map(|item| {
            let publication = item.parent?.to_string();
            let filename = match item.payload.get("filename") {
                Some(Value::String(name)) => name.clone(),
                _ => String::new(),
            };
            Some((publication, item.id.to_string(), filename))
        })
        .collect();
    candidates.sort();
    Ok(candidates.into_iter().next())
}

/// Strip what would unbalance a BibTeX field.
fn bibtex_text(text: &str) -> String {
    text.chars()
        .filter(|c| !matches!(c, '{' | '}' | '\\' | '"' | '@' | '#'))
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn year_of_ms(ms: i64) -> i32 {
    if ms <= 0 {
        return Utc::now().format("%Y").to_string().parse().unwrap_or(2000);
    }
    Utc.timestamp_millis_opt(ms)
        .single()
        .map(|t| t.format("%Y").to_string().parse().unwrap_or(2000))
        .unwrap_or(2000)
}

fn cite_key_for(doc: &RemarkableDocument) -> String {
    let stem: String = doc
        .id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect();
    format!("remarkable-{stem}")
}

/// A place for the file under `Papers/` that does not clobber another.
fn free_path(papers_dir: &Path, filename: &str, remote_id: &str) -> PathBuf {
    let candidate = papers_dir.join(filename);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = filename
        .rsplit_once('.')
        .map(|(s, e)| (s.to_string(), format!(".{e}")))
        .unwrap_or((filename.to_string(), String::new()));
    let tag: String = remote_id.chars().take(8).collect();
    papers_dir.join(format!("{stem}-{tag}{ext}"))
}

#[allow(clippy::too_many_arguments)]
fn attach_primary(
    store: &ImbibStore,
    publication_id: &str,
    library_dir: &Path,
    filename: &str,
    bytes: &[u8],
    extension: &str,
    sha: &str,
    device_id: &str,
    doc: &RemarkableDocument,
) -> Result<(String, String, String), EinkError> {
    let papers_dir = library_dir.join("Papers");
    std::fs::create_dir_all(&papers_dir).map_err(|e| EinkError::Io(e.to_string()))?;
    let destination = free_path(&papers_dir, filename, &doc.id);
    let temp = destination.with_extension(format!("{extension}.tmp"));
    std::fs::write(&temp, bytes).map_err(|e| EinkError::Io(e.to_string()))?;
    std::fs::rename(&temp, &destination).map_err(|e| EinkError::Io(e.to_string()))?;
    let final_name = destination
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| filename.to_string());
    let relative = paths::relative_or_absolute(library_dir, &destination);
    let row = store.add_linked_file(
        publication_id.to_string(),
        final_name.clone(),
        Some(relative),
        Some(extension.to_string()),
        bytes.len() as i64,
        Some(sha.to_string()),
        extension == "pdf",
    )?;
    // Remember where it came from: a re-import refreshes a tablet-born
    // primary in place instead of adding a variant.
    let uuid = parse_uuid(&row.id)?;
    store
        .store
        .update(
            uuid,
            vec![
                FieldMutation::SetPayload(
                    "source_device_id".into(),
                    Value::String(device_id.into()),
                ),
                FieldMutation::SetPayload("source_remote_id".into(), Value::String(doc.id.clone())),
                FieldMutation::SetPayload(
                    "source_remote_modified_ms".into(),
                    Value::Int(doc.last_modified_ms),
                ),
            ],
        )
        .map_err(StoreApiError::from)?;
    Ok((row.id, final_name, sha.to_string()))
}

#[allow(clippy::too_many_arguments)]
fn create_publication_for_notebook(
    store: &ImbibStore,
    library_id: &str,
    collection_id: Option<&str>,
    doc: &RemarkableDocument,
    rendered_pdf: &Path,
    library_dir: &Path,
    device_id: &str,
    outcome: &mut EinkDocumentImportOutcome,
) -> Result<(String, (String, String, String)), EinkError> {
    let title = if doc.visible_name.trim().is_empty() {
        "Untitled notebook".to_string()
    } else {
        doc.visible_name.trim().to_string()
    };
    let year = year_of_ms(doc.last_modified_ms);
    let bibtex = format!(
        "@misc{{{key},\n  title = {{{title}}},\n  year = {{{year}}},\n  howpublished = {{reMarkable notebook}},\n  note = {{Handwritten notebook imported from the reMarkable ({pages} page{s}).}}\n}}\n",
        key = cite_key_for(doc),
        title = bibtex_text(&title),
        pages = doc.page_count.max(1),
        s = if doc.page_count == 1 { "" } else { "s" },
    );
    let imported = store.import_bibtex_into(
        bibtex,
        library_id.to_string(),
        collection_id.map(String::from),
    )?;
    let publication_id = imported
        .imported
        .first()
        .or(imported.existing.first())
        .cloned()
        .ok_or_else(|| EinkError::Invalid("the notebook entry was not created".into()))?;
    outcome.trace.push(format!(
        "publication {publication_id} created for notebook {title:?} in library {library_id}{}",
        collection_id
            .map(|c| format!(", collection {c}"))
            .unwrap_or_default()
    ));
    let bytes = std::fs::read(rendered_pdf).map_err(|e| EinkError::Io(e.to_string()))?;
    let sha = paths::sha256_bytes(&bytes);
    let filename = generate_filename(
        "reMarkable",
        Some(year),
        &title,
        &FilenameOptions::default(),
    );
    let file = attach_primary(
        store,
        &publication_id,
        library_dir,
        &filename,
        &bytes,
        "pdf",
        &sha,
        device_id,
        doc,
    )?;
    outcome
        .trace
        .push(format!("rendition attached as the primary file {}", file.1));
    Ok((publication_id, file))
}

#[allow(clippy::too_many_arguments)]
fn create_publication_for_source(
    store: &ImbibStore,
    library_id: &str,
    collection_id: Option<&str>,
    doc: &RemarkableDocument,
    kind: SourceKind,
    bytes: &[u8],
    sha: &str,
    library_dir: &Path,
    device_id: &str,
    outcome: &mut EinkDocumentImportOutcome,
) -> Result<(String, (String, String, String)), EinkError> {
    let fallback_title = if doc.visible_name.trim().is_empty() {
        "Untitled document".to_string()
    } else {
        doc.visible_name.trim().to_string()
    };
    // What the first page says about itself; pdfium may be absent in a
    // headless process, in which case the tablet's name is the title.
    let heuristics = match kind {
        SourceKind::Pdf => crate::pdf::extract::extract_pdf_text(bytes)
            .ok()
            .and_then(|text| text.pages.first().map(|p| p.text.clone()))
            .map(|first_page| {
                crate::pdf::metadata_heuristics::extract_metadata_heuristics_internal(
                    &first_page,
                    year_of_ms(now_ms()),
                )
            }),
        SourceKind::Epub => None,
    };
    let (entry_type, title, authors, year) = match heuristics {
        Some(h) if h.title.as_deref().map(|t| t.len() > 8).unwrap_or(false) => (
            "article",
            h.title.clone().unwrap_or_else(|| fallback_title.clone()),
            h.authors.clone(),
            h.year,
        ),
        _ => ("misc", fallback_title.clone(), Vec::new(), None),
    };
    let year = year.unwrap_or_else(|| year_of_ms(doc.last_modified_ms));
    let mut fields = vec![
        format!("  title = {{{}}}", bibtex_text(&title)),
        format!("  year = {{{year}}}"),
    ];
    if !authors.is_empty() {
        fields.push(format!(
            "  author = {{{}}}",
            authors
                .iter()
                .map(|a| bibtex_text(a))
                .filter(|a| !a.is_empty())
                .collect::<Vec<_>>()
                .join(" and ")
        ));
    }
    fields.push(format!(
        "  note = {{Imported from the reMarkable ({}).}}",
        bibtex_text(&doc.visible_name)
    ));
    let bibtex = format!(
        "@{entry_type}{{{key},\n{fields}\n}}\n",
        key = cite_key_for(doc),
        fields = fields.join(",\n")
    );
    let imported = store.import_bibtex_into(
        bibtex,
        library_id.to_string(),
        collection_id.map(String::from),
    )?;
    let publication_id = imported
        .imported
        .first()
        .or(imported.existing.first())
        .cloned()
        .ok_or_else(|| EinkError::Invalid("the entry was not created".into()))?;
    outcome.trace.push(format!(
        "publication {publication_id} created as @{entry_type} {title:?} in library {library_id}{}",
        collection_id
            .map(|c| format!(", collection {c}"))
            .unwrap_or_default()
    ));
    let family = authors
        .first()
        .map(|a| {
            a.split(',')
                .next()
                .unwrap_or(a)
                .split_whitespace()
                .last()
                .unwrap_or(a)
                .to_string()
        })
        .unwrap_or_else(|| "reMarkable".into());
    let filename = generate_filename(
        &family,
        Some(year),
        &title,
        &FilenameOptions {
            extension: kind.extension().into(),
            ..Default::default()
        },
    );
    let file = attach_primary(
        store,
        &publication_id,
        library_dir,
        &filename,
        bytes,
        kind.extension(),
        sha,
        device_id,
        doc,
    )?;
    outcome
        .trace
        .push(format!("source attached as the primary file {}", file.1));
    Ok((publication_id, file))
}

fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

// --- exported surface -----------------------------------------------------

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Documents on the tablet that no mirror row accounts for — notebooks
    /// written there, files copied in by hand — in-tree ones first, with
    /// the library and collection their folder names resolve to.
    pub fn eink_list_unmatched(
        &self,
        device_id: Option<String>,
    ) -> Result<Vec<EinkUnmatchedDocument>, StoreApiError> {
        let device = resolve_device(self, device_id.as_deref()).map_err(to_store_error)?;
        let transport = super::super::transport::UsbWebTransport::new(device.base_url.clone());
        if !transport.reachable() {
            return Err(StoreApiError::Storage(format!(
                "tablet at {} is not reachable",
                device.base_url
            )));
        }
        list_unmatched(self, &device, &transport).map_err(to_store_error)
    }

    /// Bring one tablet document into the store: as a publication (a
    /// notebook becomes `@misc` with the rendered PDF; a PDF/ePUB whose
    /// bytes match a file already here adopts that publication) or as a
    /// note artifact. `library_id` may be omitted for a document under
    /// `imbib/<Library>` on the tablet.
    pub fn eink_import_document(
        &self,
        remote_id: String,
        library_id: Option<String>,
        collection_id: Option<String>,
        as_kind: Option<String>,
        device_id: Option<String>,
    ) -> Result<EinkDocumentImportOutcome, StoreApiError> {
        let device = resolve_device(self, device_id.as_deref()).map_err(to_store_error)?;
        let transport = super::super::transport::UsbWebTransport::new(device.base_url.clone());
        let request = ImportDocumentRequest {
            remote_id,
            library_id,
            collection_id,
            as_kind: as_kind.unwrap_or_default(),
            library_dir: None,
        };
        import_document(self, &device, &transport, &request).map_err(to_store_error)
    }
}

fn to_store_error(error: EinkError) -> StoreApiError {
    match error {
        EinkError::Store(inner) => inner,
        EinkError::NoDevice => StoreApiError::NotFound(error.to_string()),
        EinkError::Invalid(message) => StoreApiError::InvalidInput(message),
        other => StoreApiError::Storage(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bibtex_text_drops_what_would_unbalance_a_field() {
        assert_eq!(
            bibtex_text("A {brace} and \\ a \"quote\"  here"),
            "A brace and a quote here"
        );
    }

    #[test]
    fn a_cite_key_comes_from_the_remote_id() {
        let doc = RemarkableDocument {
            id: "1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809".into(),
            visible_name: "Notes".into(),
            kind: impress_remarkable::DocumentKind::Document,
            parent: String::new(),
            last_modified_ms: 0,
            pinned: false,
            file_type: String::new(),
            page_count: 1,
            has_annotations: true,
        };
        assert_eq!(cite_key_for(&doc), "remarkable-1a2b3c4d");
        assert_eq!(document_kind(&doc), KIND_NOTEBOOK);
    }

    #[test]
    fn a_taken_filename_gets_the_remote_id_tag() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("Abel_2002_Notes.pdf"), b"x").unwrap();
        assert_eq!(
            free_path(dir.path(), "Abel_2002_Notes.pdf", "deadbeef-0000"),
            dir.path().join("Abel_2002_Notes-deadbeef.pdf")
        );
        assert_eq!(
            free_path(dir.path(), "fresh.pdf", "deadbeef-0000"),
            dir.path().join("fresh.pdf")
        );
    }
}
