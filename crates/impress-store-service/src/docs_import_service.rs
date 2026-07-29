//! `DocsImportService` — a directory of markdown files becomes a manuscript
//! collection, repeatably.
//!
//! The capability this exists for: a project keeps prose on disk (ADRs, design
//! notes, plans) and wants that prose *in the store* — searchable, filable,
//! triageable, readable in imprint — without anybody hand-copying it. Markdown
//! is a first-class manuscript format (`manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS`
//! contains `"markdown"`), so a markdown file needs no conversion to become a
//! manuscript: the file *is* the body.
//!
//! Nothing here is ADR-specific. `docs/ADR-*.md → "ADRs"` is the first caller,
//! not the design.
//!
//! ## Idempotency is the whole point
//!
//! An importer you can only run once is a migration script; an importer you can
//! run on every change is a capability. Each file's manuscript id is
//! **deterministic** — a UUIDv5 over `"<collection>/<path relative to the
//! source directory>"` in a fixed namespace, mirroring the scheme
//! `apps/impart/.../DeterministicID.swift` uses for mail rows. So:
//!
//! * re-importing an unchanged tree writes nothing and creates nothing;
//! * editing a file updates that manuscript's body **in place**, same id;
//! * changing a file's `# ` heading renames that manuscript, same id;
//! * membership is added through the ADR-0022 kernel, which is itself
//!   idempotent per member, so nothing is ever double-filed.
//!
//! The consequence to know: the key includes the collection name, so importing
//! the same directory into a *different* collection produces a different set of
//! manuscripts. That is deliberate — two collections built from one tree are
//! two collections, not one aliased twice.
//!
//! ## The companion verb
//!
//! [`DocsImportService::prune_empty_manuscripts`] exists because the thing an
//! importer usually has to replace is a set of **placeholder shells**: items
//! with a title and no body, left by whatever created the outline first. It
//! reports by default and only deletes under `apply`, and it will never delete
//! a manuscript that has real content — the emptiness test is the safety
//! interlock, not a convenience.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::collection_ops::{self, MANUSCRIPT_COLLECTION};
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::manuscript_ops::{iso8601_now, sha256_hex};
use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{FieldMutation, ItemStore, StoreError};
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::store::store_instance;

/// Fixed namespace for every manuscript this importer derives.
///
/// Derived ONCE as `UUIDv5(NAMESPACE_DNS, "store.impress.docs-import")` and
/// hardcoded, exactly as `DeterministicID.impartNamespace` is. **Never change
/// it** — every imported manuscript in every store depends on it, and a new
/// namespace would silently fork every document into a duplicate.
pub const DOCS_IMPORT_NAMESPACE: &str = "3dc1875a-7b3e-5f85-8316-6c52d757c92b";

/// The `manuscript.format` this importer writes. Set explicitly on every
/// document, on create and on update alike.
pub const MARKDOWN_FORMAT: &str = "markdown";

/// Extensions treated as markdown, lowercased.
pub const MARKDOWN_EXTENSIONS: [&str; 2] = ["md", "markdown"];

/// Mirrors imprint's current `DocumentSchemaVersion` (v1.4), the same value
/// `imbib-core::create_manuscript` writes, so an imported manuscript is
/// indistinguishable from an app-created one.
const FORMAT_SCHEMA_VERSION: i64 = 140;

/// Hard ceiling on how deep a recursive import will walk. A docs tree is
/// shallow; anything deeper is a symlink loop or a mistake.
const MAX_DEPTH: usize = 16;

// ---------------------------------------------------------------------------
// Deterministic identity
// ---------------------------------------------------------------------------

/// The stable key a document's id is derived from: `"<collection>/<relative
/// path>"`, lowercased. Exposed because a caller that wants to *find* an
/// imported manuscript without re-importing needs the same arithmetic.
pub fn document_key(collection: &str, relative_path: &str) -> String {
    format!(
        "{}/{}",
        collection.trim(),
        relative_path.trim_start_matches('/')
    )
    .to_lowercase()
}

/// The deterministic manuscript id for one source file.
pub fn document_id(collection: &str, relative_path: &str) -> Uuid {
    let namespace = Uuid::parse_str(DOCS_IMPORT_NAMESPACE).expect("namespace constant is a UUID");
    Uuid::new_v5(
        &namespace,
        document_key(collection, relative_path).as_bytes(),
    )
}

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// One document the importer acted on.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ImportedDocDto {
    /// Deterministic lowercase UUID. Stable across re-imports of the same
    /// file into the same collection.
    pub id: String,
    /// Title taken from the first `# ` ATX heading, or the filename stem.
    pub title: String,
    /// Path relative to the source directory — the half of the id key that
    /// varies.
    pub source_path: String,
    /// Byte length of the body written (the whole file).
    pub body_bytes: u64,
    /// `"created"` | `"updated"` | `"unchanged"`. `"updated"` means the title,
    /// the body, or both changed.
    pub action: String,
    /// True when this call added the manuscript to the collection. False on a
    /// re-import, because it was already a member.
    pub filed: bool,
}

/// A file the importer deliberately did not import, and why.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SkippedDocDto {
    /// Path relative to the source directory.
    pub source_path: String,
    /// Human-readable cause: not markdown, empty, unreadable, or an id
    /// collision with an item of another kind.
    pub reason: String,
}

/// What an import run did, or (dry run) would do.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct DocsImportResult {
    pub ok: bool,
    /// True when NOTHING was written — not the manuscripts, not the
    /// collection, not the membership. The counts are what a real run would
    /// produce.
    pub dry_run: bool,
    /// The target collection's id, or null on a dry run that would have
    /// created it.
    pub collection_id: Option<String>,
    /// True when this call created the collection.
    pub collection_created: bool,
    pub created: u32,
    pub updated: u32,
    pub unchanged: u32,
    /// Manuscripts newly filed into the collection by this call.
    pub filed: u32,
    /// Every document acted on, in path order.
    pub documents: Vec<ImportedDocDto>,
    /// Every file skipped, with the reason. Non-markdown and empty files land
    /// here rather than being silently dropped.
    pub skipped: Vec<SkippedDocDto>,
    pub message: String,
}

impl DocsImportResult {
    fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            dry_run: false,
            collection_id: None,
            collection_created: false,
            created: 0,
            updated: 0,
            unchanged: 0,
            filed: 0,
            documents: Vec::new(),
            skipped: Vec::new(),
            message: message.into(),
        }
    }
}

/// One empty-bodied manuscript found by the prune scan.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EmptyManuscriptDto {
    pub id: String,
    pub title: String,
    /// Character count of `body_content` after trimming. Zero means the field
    /// is absent or whitespace-only.
    pub body_chars: u64,
    /// The `format` payload field, if any — so a caller can see whether the
    /// shell even claimed a format.
    pub format: Option<String>,
    /// True when this call deleted it. Always false without `apply`.
    pub deleted: bool,
}

/// What the prune scan found, and what it removed.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PruneResult {
    pub ok: bool,
    /// True when nothing was deleted (no `apply`).
    pub dry_run: bool,
    /// Manuscripts examined.
    pub examined: u32,
    /// Manuscripts whose body is empty (or within `max_body_chars`).
    pub empty: u32,
    /// Manuscripts actually deleted. Zero on a dry run.
    pub deleted: u32,
    /// The empty ones, in the order examined. Read this BEFORE passing
    /// `apply`.
    pub manuscripts: Vec<EmptyManuscriptDto>,
    pub message: String,
}

impl PruneResult {
    fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            dry_run: true,
            examined: 0,
            empty: 0,
            deleted: 0,
            manuscripts: Vec::new(),
            message: message.into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Markdown on disk becomes manuscripts in the store, repeatably.
#[impress_service]
pub trait DocsImportService: Send + Sync + 'static {
    /// Import every markdown file under `source_dir` into the manuscript
    /// collection named `collection`, creating the collection if it does not
    /// exist.
    ///
    /// Each file becomes a `manuscript` with `format: "markdown"`, its title
    /// from the first `# ` ATX heading (filename stem when there is none), and
    /// its body set to the file's full contents.
    ///
    /// **Safe to re-run.** Ids are derived deterministically from the file's
    /// path relative to `source_dir`, so a second run updates the same
    /// manuscripts in place instead of duplicating them: an unchanged file
    /// reports `unchanged`, an edited one reports `updated` with the same id,
    /// and membership is never double-added.
    ///
    /// `pattern` is an optional filename glob (`*` and `?`), e.g. `ADR-*.md`;
    /// files that do not match it are ignored entirely. Files that DO match
    /// but are not markdown, are empty, or are not UTF-8 are reported in
    /// `skipped` with a reason rather than dropped silently.
    ///
    /// Pass `dry_run` first on anything you have not imported before: it
    /// writes nothing at all and reports exactly the counts the real run will.
    #[impress_method]
    async fn import_directory(
        &self,
        source_dir: String,
        collection: String,
        pattern: Option<String>,
        recursive: bool,
        dry_run: bool,
    ) -> DocsImportResult;

    /// Find — and, with `apply`, delete — manuscripts that have a title and no
    /// body: the placeholder shells an outline pass leaves behind.
    ///
    /// **Reports by default.** Without `apply` nothing is deleted; run it that
    /// way first and read `manuscripts`, because deletion is not undoable.
    ///
    /// A manuscript with real content is NEVER deleted: `max_body_chars` sets
    /// how many trimmed characters still count as "empty" (0 — the default —
    /// means strictly empty or whitespace-only), and anything above the
    /// threshold is not even reported.
    ///
    /// `collection` scopes the scan to one manuscript collection by name;
    /// null scans every manuscript in the store.
    #[impress_method]
    async fn prune_empty_manuscripts(
        &self,
        collection: Option<String>,
        max_body_chars: i64,
        apply: bool,
    ) -> PruneResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed `DocsImportService`. `new()` uses the shared store (opened
/// lazily); `with_store` takes an explicit one, which is how the tests run
/// against a temp database.
#[derive(Clone, Default)]
pub struct DefaultDocsImportService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultDocsImportService {
    pub fn new() -> Self {
        Self { store: None }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store.clone().unwrap_or_else(store_instance)
    }
}

// --- pure helpers ----------------------------------------------------------

/// Title from the first ATX `# ` heading, per CommonMark: up to three leading
/// spaces, one `#`, then whitespace. Trailing `#`s are stripped. Returns
/// `None` when the document has no level-1 heading, which is the caller's cue
/// to fall back to the filename.
pub fn title_from_markdown(body: &str) -> Option<String> {
    for line in body.lines() {
        let indent = line.len() - line.trim_start_matches(' ').len();
        if indent > 3 {
            continue;
        }
        let rest = &line[indent..];
        let Some(after_hash) = rest.strip_prefix('#') else {
            continue;
        };
        // `##` is a level-2 heading, not a title.
        if after_hash.starts_with('#') {
            continue;
        }
        let text = after_hash.trim_start_matches([' ', '\t']);
        if text.len() == after_hash.len() && !after_hash.is_empty() {
            // `#Word` is not a heading at all.
            continue;
        }
        let text = text.trim().trim_end_matches('#').trim();
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    None
}

/// Filename-glob match supporting `*` (any run, including empty) and `?` (one
/// character). Case-insensitive, because a docs directory is on a
/// case-insensitive filesystem more often than not.
///
/// Deliberately not a dependency: the patterns a caller passes here are
/// `ADR-*.md`-shaped, and a glob crate would be more surface than the feature.
pub fn glob_match(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    // Classic two-pointer wildcard match with backtracking on the last `*`.
    let (mut pi, mut ni) = (0usize, 0usize);
    let (mut star, mut star_n) = (None::<usize>, 0usize);
    while ni < n.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            star_n = ni;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            star_n += 1;
            ni = star_n;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| MARKDOWN_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// Every regular file under `dir`, sorted, so a run's report and its ids are
/// reproducible. Hidden entries are skipped: `.git` is not documentation.
fn collect_files(dir: &Path, recursive: bool) -> Result<Vec<PathBuf>, String> {
    fn walk(
        dir: &Path,
        recursive: bool,
        depth: usize,
        out: &mut Vec<PathBuf>,
    ) -> Result<(), String> {
        if depth > MAX_DEPTH {
            return Ok(());
        }
        let mut entries: Vec<PathBuf> = fs::read_dir(dir)
            .map_err(|e| format!("cannot read {}: {e}", dir.display()))?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                !p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with('.'))
                    .unwrap_or(true)
            })
            .collect();
        entries.sort();
        for path in entries {
            if path.is_dir() {
                if recursive {
                    walk(&path, recursive, depth + 1, out)?;
                }
            } else if path.is_file() {
                out.push(path);
            }
        }
        Ok(())
    }

    let mut out = Vec::new();
    walk(dir, recursive, 0, &mut out)?;
    Ok(out)
}

fn string_field(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

/// A bare item with a CALLER-CHOSEN id — the whole basis of idempotency here,
/// and the one thing `imbib-core::create_manuscript` cannot do (it mints a v4).
fn new_manuscript(id: Uuid, payload: BTreeMap<String, Value>) -> Item {
    let now = chrono::Utc::now();
    Item {
        id,
        schema: "manuscript".into(),
        payload,
        created: now,
        modified: now,
        author: "impress-store-service:docs-import".into(),
        author_kind: ActorKind::System,
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

/// The manuscript collection named `name`, or `None`. Case-insensitive: a
/// caller typing "adrs" means the collection they see as "ADRs".
fn find_collection(store: &SqliteItemStore, name: &str) -> Result<Option<String>, StoreError> {
    let rows = collection_ops::list_tree(store, &MANUSCRIPT_COLLECTION)?;
    Ok(rows
        .into_iter()
        .find(|r| r.name.trim().eq_ignore_ascii_case(name.trim()))
        .map(|r| r.id))
}

/// Everything the importer decided about one file, before any writing.
struct Planned {
    id: Uuid,
    title: String,
    body: String,
    relative: String,
    existing: Option<Item>,
}

#[async_trait::async_trait]
impl DocsImportService for DefaultDocsImportService {
    async fn import_directory(
        &self,
        source_dir: String,
        collection: String,
        pattern: Option<String>,
        recursive: bool,
        dry_run: bool,
    ) -> DocsImportResult {
        let store = self.store();
        let collection_name = collection.trim().to_string();
        if collection_name.is_empty() {
            return DocsImportResult::failed("collection name must not be empty");
        }
        let root = PathBuf::from(shellexpand_home(&source_dir));
        if !root.is_dir() {
            return DocsImportResult::failed(format!(
                "source_dir '{}' is not a directory",
                root.display()
            ));
        }
        let pattern = pattern
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty());

        let files = match collect_files(&root, recursive) {
            Ok(f) => f,
            Err(e) => return DocsImportResult::failed(e),
        };

        // --- Plan: read and classify every file before touching the store.
        let mut planned: Vec<Planned> = Vec::new();
        let mut skipped: Vec<SkippedDocDto> = Vec::new();
        for path in &files {
            let relative = path
                .strip_prefix(&root)
                .unwrap_or(path)
                .to_string_lossy()
                .replace('\\', "/");
            let file_name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if let Some(p) = &pattern {
                if !glob_match(p, &file_name) {
                    continue;
                }
            }
            if !is_markdown(path) {
                skipped.push(SkippedDocDto {
                    source_path: relative,
                    reason: "not a markdown file (.md/.markdown)".into(),
                });
                continue;
            }
            let body = match fs::read(path) {
                Ok(bytes) => match String::from_utf8(bytes) {
                    Ok(text) => text,
                    Err(_) => {
                        skipped.push(SkippedDocDto {
                            source_path: relative,
                            reason: "not valid UTF-8".into(),
                        });
                        continue;
                    }
                },
                Err(e) => {
                    skipped.push(SkippedDocDto {
                        source_path: relative,
                        reason: format!("unreadable: {e}"),
                    });
                    continue;
                }
            };
            if body.trim().is_empty() {
                skipped.push(SkippedDocDto {
                    source_path: relative,
                    reason: "empty file".into(),
                });
                continue;
            }
            let id = document_id(&collection_name, &relative);
            let existing = match store.get(id) {
                Ok(item) => item,
                Err(e) => {
                    skipped.push(SkippedDocDto {
                        source_path: relative,
                        reason: format!("store read failed: {e}"),
                    });
                    continue;
                }
            };
            if let Some(item) = &existing {
                if item.schema != "manuscript" {
                    skipped.push(SkippedDocDto {
                        source_path: relative,
                        reason: format!(
                            "deterministic id {id} is already held by a '{}' item",
                            item.schema
                        ),
                    });
                    continue;
                }
            }
            let title = title_from_markdown(&body).unwrap_or_else(|| {
                path.file_stem()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| relative.clone())
            });
            planned.push(Planned {
                id,
                title,
                body,
                relative,
                existing,
            });
        }

        // --- Dry run stops here, having written nothing at all.
        if dry_run {
            let existing_collection = match find_collection(&store, &collection_name) {
                Ok(c) => c,
                Err(e) => return DocsImportResult::failed(e.to_string()),
            };
            let mut result = DocsImportResult {
                ok: true,
                dry_run: true,
                collection_created: existing_collection.is_none(),
                collection_id: existing_collection.clone(),
                created: 0,
                updated: 0,
                unchanged: 0,
                filed: 0,
                documents: Vec::new(),
                skipped,
                message: String::new(),
            };
            let members: Vec<ItemId> = match &existing_collection {
                Some(cid) => collection_ops::list_members(&store, &MANUSCRIPT_COLLECTION, cid)
                    .map(|items| items.iter().map(|i| i.id).collect())
                    .unwrap_or_default(),
                None => Vec::new(),
            };
            for doc in &planned {
                let action = plan_action(doc);
                match action {
                    "created" => result.created += 1,
                    "updated" => result.updated += 1,
                    _ => result.unchanged += 1,
                }
                let filed = !members.contains(&doc.id);
                if filed {
                    result.filed += 1;
                }
                result.documents.push(ImportedDocDto {
                    id: doc.id.to_string(),
                    title: doc.title.clone(),
                    source_path: doc.relative.clone(),
                    body_bytes: doc.body.len() as u64,
                    action: action.to_string(),
                    filed,
                });
            }
            result.message = summarize(&result, &collection_name);
            return result;
        }

        // --- Collection: find or create through the ADR-0022 kernel.
        let (collection_id, collection_created) = match find_collection(&store, &collection_name) {
            Ok(Some(id)) => (id, false),
            Ok(None) => match collection_ops::create(
                &store,
                &MANUSCRIPT_COLLECTION,
                &collection_name,
                None,
                Some("manuscript"),
                None,
            ) {
                Ok(row) => (row.id, true),
                Err(e) => return DocsImportResult::failed(format!("create collection: {e}")),
            },
            Err(e) => return DocsImportResult::failed(e.to_string()),
        };

        let mut result = DocsImportResult {
            ok: true,
            dry_run: false,
            collection_id: Some(collection_id.clone()),
            collection_created,
            created: 0,
            updated: 0,
            unchanged: 0,
            filed: 0,
            documents: Vec::new(),
            skipped,
            message: String::new(),
        };

        for doc in &planned {
            let action = plan_action(doc);
            let outcome = match (&doc.existing, action) {
                (None, _) => insert_document(&store, doc, &source_dir_display(&root, doc)),
                (Some(_), "unchanged") => Ok(()),
                (Some(item), _) => update_document(&store, item, doc),
            };
            if let Err(e) = outcome {
                result.skipped.push(SkippedDocDto {
                    source_path: doc.relative.clone(),
                    reason: format!("write failed: {e}"),
                });
                continue;
            }
            match action {
                "created" => result.created += 1,
                "updated" => result.updated += 1,
                _ => result.unchanged += 1,
            }
            // Membership through the kernel: idempotent per member, so a
            // re-import files nothing and reports `filed: false`.
            let filed = match collection_ops::add_members(
                &store,
                &MANUSCRIPT_COLLECTION,
                &collection_id,
                &[doc.id.to_string()],
            ) {
                Ok(changed) => !changed.is_empty(),
                Err(e) => {
                    result.skipped.push(SkippedDocDto {
                        source_path: doc.relative.clone(),
                        reason: format!("filing failed: {e}"),
                    });
                    false
                }
            };
            if filed {
                result.filed += 1;
            }
            result.documents.push(ImportedDocDto {
                id: doc.id.to_string(),
                title: doc.title.clone(),
                source_path: doc.relative.clone(),
                body_bytes: doc.body.len() as u64,
                action: action.to_string(),
                filed,
            });
        }

        result.message = summarize(&result, &collection_name);
        result
    }

    async fn prune_empty_manuscripts(
        &self,
        collection: Option<String>,
        max_body_chars: i64,
        apply: bool,
    ) -> PruneResult {
        let store = self.store();
        let threshold = max_body_chars.max(0) as usize;

        let items: Vec<Item> = match collection
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty())
        {
            Some(name) => match find_collection(&store, name) {
                Ok(Some(id)) => {
                    match collection_ops::list_members(&store, &MANUSCRIPT_COLLECTION, &id) {
                        Ok(items) => items
                            .into_iter()
                            .filter(|i| i.schema == "manuscript")
                            .collect(),
                        Err(e) => return PruneResult::failed(e.to_string()),
                    }
                }
                Ok(None) => {
                    return PruneResult::failed(format!("no manuscript collection named '{name}'"))
                }
                Err(e) => return PruneResult::failed(e.to_string()),
            },
            None => {
                let q = ItemQuery {
                    schema: Some("manuscript".into()),
                    ..Default::default()
                };
                match store.query(&q) {
                    Ok(items) => items,
                    Err(e) => return PruneResult::failed(e.to_string()),
                }
            }
        };

        let mut result = PruneResult {
            ok: true,
            dry_run: !apply,
            examined: items.len() as u32,
            empty: 0,
            deleted: 0,
            manuscripts: Vec::new(),
            message: String::new(),
        };

        for item in &items {
            let body = string_field(item, "body_content").unwrap_or_default();
            let trimmed = body.trim();
            if trimmed.chars().count() > threshold {
                continue;
            }
            result.empty += 1;
            let mut deleted = false;
            if apply {
                match store.delete(item.id) {
                    Ok(()) => {
                        deleted = true;
                        result.deleted += 1;
                    }
                    Err(e) => {
                        result.ok = false;
                        result.message = format!("delete {} failed: {e}", item.id);
                    }
                }
            }
            result.manuscripts.push(EmptyManuscriptDto {
                id: item.id.to_string(),
                title: string_field(item, "title").unwrap_or_default(),
                body_chars: trimmed.chars().count() as u64,
                format: string_field(item, "format"),
                deleted,
            });
        }

        if result.message.is_empty() {
            result.message = if apply {
                format!(
                    "Examined {} manuscript(s); {} empty; deleted {}.",
                    result.examined, result.empty, result.deleted
                )
            } else {
                format!(
                    "Examined {} manuscript(s); {} have an empty body. Nothing deleted — \
                     re-run with apply to remove them.",
                    result.examined, result.empty
                )
            };
        }
        result
    }
}

/// Would this document be created, updated, or left alone? Pure — the dry run
/// and the real run share it, which is what makes the dry run's counts the
/// real run's counts.
fn plan_action(doc: &Planned) -> &'static str {
    match &doc.existing {
        None => "created",
        Some(item) => {
            let same_body =
                string_field(item, "body_content").as_deref() == Some(doc.body.as_str());
            let same_title = string_field(item, "title").as_deref() == Some(doc.title.as_str());
            let same_format = string_field(item, "format").as_deref() == Some(MARKDOWN_FORMAT);
            if same_body && same_title && same_format {
                "unchanged"
            } else {
                "updated"
            }
        }
    }
}

fn source_dir_display(root: &Path, doc: &Planned) -> String {
    root.join(&doc.relative).to_string_lossy().to_string()
}

fn import_source_json(absolute_path: &str) -> String {
    serde_json::json!({
        "kind": "markdown-directory",
        "original_path": absolute_path,
    })
    .to_string()
}

fn insert_document(
    store: &SqliteItemStore,
    doc: &Planned,
    absolute: &str,
) -> Result<(), StoreError> {
    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("title".into(), Value::String(doc.title.clone()));
    payload.insert("status".into(), Value::String("draft".into()));
    // Self-referential until the first revision — the same convention
    // `imbib-core::create_manuscript` and imprint's adapter use.
    payload.insert(
        "current_revision_ref".into(),
        Value::String(doc.id.to_string()),
    );
    payload.insert("format".into(), Value::String(MARKDOWN_FORMAT.into()));
    payload.insert("body_content".into(), Value::String(doc.body.clone()));
    payload.insert(
        "body_content_hash".into(),
        Value::String(sha256_hex(&doc.body)),
    );
    payload.insert("body_modified_at".into(), Value::String(iso8601_now()));
    payload.insert(
        "format_schema_version".into(),
        Value::Int(FORMAT_SCHEMA_VERSION),
    );
    payload.insert(
        "import_source".into(),
        Value::String(import_source_json(absolute)),
    );
    store.insert(new_manuscript(doc.id, payload))?;
    Ok(())
}

/// Update in place. Only the fields that actually changed are written, and
/// `status` is never touched — a document the user moved to `submitted` must
/// not be dragged back to `draft` by a re-import.
fn update_document(
    store: &SqliteItemStore,
    existing: &Item,
    doc: &Planned,
) -> Result<(), StoreError> {
    let mut mutations = Vec::new();
    if string_field(existing, "title").as_deref() != Some(doc.title.as_str()) {
        mutations.push(FieldMutation::SetPayload(
            "title".into(),
            Value::String(doc.title.clone()),
        ));
    }
    if string_field(existing, "format").as_deref() != Some(MARKDOWN_FORMAT) {
        mutations.push(FieldMutation::SetPayload(
            "format".into(),
            Value::String(MARKDOWN_FORMAT.into()),
        ));
    }
    if string_field(existing, "body_content").as_deref() != Some(doc.body.as_str()) {
        mutations.push(FieldMutation::SetPayload(
            "body_content".into(),
            Value::String(doc.body.clone()),
        ));
        mutations.push(FieldMutation::SetPayload(
            "body_content_hash".into(),
            Value::String(sha256_hex(&doc.body)),
        ));
        mutations.push(FieldMutation::SetPayload(
            "body_modified_at".into(),
            Value::String(iso8601_now()),
        ));
    }
    if mutations.is_empty() {
        return Ok(());
    }
    store.update(existing.id, mutations)
}

fn summarize(result: &DocsImportResult, collection: &str) -> String {
    let prefix = if result.dry_run {
        "Would import"
    } else {
        "Imported"
    };
    format!(
        "{prefix} {} document(s) into '{collection}': {} created, {} updated, {} unchanged, \
         {} newly filed, {} skipped.",
        result.documents.len(),
        result.created,
        result.updated,
        result.unchanged,
        result.filed,
        result.skipped.len()
    )
}

/// `~` expansion, because a tool argument typed by a human or a model will
/// contain one sooner or later and `PathBuf` does not expand it.
fn shellexpand_home(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed == "~" || trimmed.starts_with("~/") {
        if let Some(home) = dirs::home_dir() {
            return home
                .join(trimmed.trim_start_matches("~/").trim_start_matches('~'))
                .to_string_lossy()
                .to_string();
        }
    }
    trimmed.to_string()
}

impress_service_impl! {
    service = DocsImportService,
    impl = DefaultDocsImportService,
    instance = DefaultDocsImportService::new,
    methods = [
        import_directory(
            source_dir: String,
            collection: String,
            pattern: Option<String>,
            recursive: bool,
            dry_run: bool
        ) -> DocsImportResult,
        prune_empty_manuscripts(
            collection: Option<String>,
            max_body_chars: i64,
            apply: bool
        ) -> PruneResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item_named, test_store};

    /// A temp directory that cleans itself up. No dev-dependency for four
    /// lines of `std::fs`.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "impress-docs-import-{tag}-{}",
                Uuid::new_v4().simple()
            ));
            fs::create_dir_all(&dir).expect("create temp dir");
            Self(dir)
        }

        fn write(&self, name: &str, contents: &str) -> PathBuf {
            let path = self.0.join(name);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("create parent");
            }
            fs::write(&path, contents).expect("write file");
            path
        }

        fn path(&self) -> String {
            self.0.to_string_lossy().to_string()
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn fixture(tag: &str) -> TempDir {
        let dir = TempDir::new(tag);
        dir.write("ADR-0001-first.md", "# The First Decision\n\nBody one.\n");
        dir.write("ADR-0002-second.md", "# The Second Decision\n\nBody two.\n");
        dir.write("notes.txt", "not markdown at all\n");
        dir.write("blank.md", "   \n\n");
        dir
    }

    fn body_of(store: &SqliteItemStore, id: &str) -> String {
        let item = store
            .get(Uuid::parse_str(id).unwrap())
            .unwrap()
            .expect("item present");
        string_field(&item, "body_content").unwrap_or_default()
    }

    fn title_of(store: &SqliteItemStore, id: &str) -> String {
        let item = store
            .get(Uuid::parse_str(id).unwrap())
            .unwrap()
            .expect("item present");
        string_field(&item, "title").unwrap_or_default()
    }

    // --- the deterministic-id contract ------------------------------------

    /// The namespace is load-bearing: every imported manuscript in every store
    /// hangs off it, exactly as `DeterministicID.impartNamespace` does for
    /// mail. This is the same verification test impart keeps.
    #[test]
    fn namespace_is_the_documented_derivation() {
        let expected = Uuid::new_v5(&Uuid::NAMESPACE_DNS, b"store.impress.docs-import");
        assert_eq!(
            expected.to_string(),
            DOCS_IMPORT_NAMESPACE,
            "the hardcoded namespace must equal UUIDv5(DNS, \"store.impress.docs-import\")"
        );
    }

    #[test]
    fn ids_are_stable_and_scoped() {
        let a = document_id("ADRs", "ADR-0001-first.md");
        assert_eq!(a, document_id("adrs", "ADR-0001-first.md"), "case-folded");
        assert_ne!(a, document_id("ADRs", "ADR-0002-second.md"), "per file");
        assert_ne!(
            a,
            document_id("Designs", "ADR-0001-first.md"),
            "per collection"
        );
        assert_eq!(a.get_version_num(), 5);
    }

    // --- title extraction --------------------------------------------------

    #[test]
    fn titles_come_from_the_first_atx_heading() {
        assert_eq!(
            title_from_markdown("# Hello\n## Not this\n").as_deref(),
            Some("Hello")
        );
        assert_eq!(
            title_from_markdown("Preamble\n\n   # Indented Still Counts\n").as_deref(),
            Some("Indented Still Counts")
        );
        assert_eq!(
            title_from_markdown("# Closed Sequence #\n").as_deref(),
            Some("Closed Sequence")
        );
        // `##`, `#Word` and a bare `#` are not level-1 headings.
        assert_eq!(title_from_markdown("## Only level two\n"), None);
        assert_eq!(title_from_markdown("#NoSpace\n"), None);
        assert_eq!(title_from_markdown("#\n\ntext\n"), None);
        assert_eq!(title_from_markdown("no heading here\n"), None);
    }

    #[test]
    fn globs_match_the_shapes_callers_type() {
        assert!(glob_match("*.md", "ADR-0001.md"));
        assert!(glob_match("ADR-*.md", "adr-0001-thing.md"));
        assert!(!glob_match("ADR-*.md", "design-notes.md"));
        assert!(glob_match("ADR-000?-*.md", "ADR-0001-x.md"));
        assert!(glob_match("*", "anything"));
        assert!(!glob_match("a*b", "acd"));
    }

    // --- the import contract ----------------------------------------------

    #[tokio::test]
    async fn fresh_import_creates_one_manuscript_per_markdown_file() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = fixture("fresh");

        let r = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        assert!(r.ok, "{}", r.message);
        assert_eq!(r.created, 2, "{:?}", r.documents);
        assert_eq!(r.updated, 0);
        assert_eq!(r.unchanged, 0);
        assert_eq!(r.filed, 2);
        assert!(r.collection_created);

        // Bodies are the whole file; the format is set explicitly.
        let first = r
            .documents
            .iter()
            .find(|d| d.source_path == "ADR-0001-first.md")
            .expect("first doc");
        assert_eq!(first.title, "The First Decision");
        assert_eq!(
            body_of(&store, &first.id),
            "# The First Decision\n\nBody one.\n"
        );
        let item = store
            .get(Uuid::parse_str(&first.id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(string_field(&item, "format").as_deref(), Some("markdown"));
        assert_eq!(
            string_field(&item, "body_content_hash").as_deref(),
            Some(sha256_hex("# The First Decision\n\nBody one.\n").as_str())
        );

        // Non-markdown and empty files are reported, not silently dropped.
        let reasons: Vec<(&str, &str)> = r
            .skipped
            .iter()
            .map(|s| (s.source_path.as_str(), s.reason.as_str()))
            .collect();
        assert!(
            reasons
                .iter()
                .any(|(p, why)| *p == "notes.txt" && why.contains("markdown")),
            "{reasons:?}"
        );
        assert!(
            reasons
                .iter()
                .any(|(p, why)| *p == "blank.md" && why.contains("empty")),
            "{reasons:?}"
        );

        // And they are members of the collection the run created.
        let cid = r.collection_id.clone().unwrap();
        let members = collection_ops::list_members(&store, &MANUSCRIPT_COLLECTION, &cid).unwrap();
        assert_eq!(members.len(), 2);
    }

    #[tokio::test]
    async fn re_import_is_a_no_op_in_count_and_in_membership() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = fixture("reimport");

        let first = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        let again = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;

        assert!(again.ok, "{}", again.message);
        assert_eq!(again.created, 0, "a re-import must create nothing");
        assert_eq!(again.updated, 0);
        assert_eq!(again.unchanged, 2);
        assert_eq!(again.filed, 0, "membership must not be double-added");
        assert!(!again.collection_created);
        assert_eq!(again.collection_id, first.collection_id);

        // Same ids, and exactly two manuscripts in the whole store.
        let ids_first: Vec<&str> = first.documents.iter().map(|d| d.id.as_str()).collect();
        let ids_again: Vec<&str> = again.documents.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(ids_first, ids_again);
        let all = store
            .query(&ItemQuery {
                schema: Some("manuscript".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(all.len(), 2);
        let cid = again.collection_id.unwrap();
        assert_eq!(
            collection_ops::list_members(&store, &MANUSCRIPT_COLLECTION, &cid)
                .unwrap()
                .len(),
            2
        );
    }

    #[tokio::test]
    async fn editing_a_file_updates_the_body_and_keeps_the_id() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = fixture("edit");

        let first = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        let id = first
            .documents
            .iter()
            .find(|d| d.source_path == "ADR-0001-first.md")
            .unwrap()
            .id
            .clone();

        dir.write(
            "ADR-0001-first.md",
            "# The First Decision\n\nBody one, revised substantially.\n",
        );
        let again = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;

        assert_eq!(again.updated, 1, "{:?}", again.documents);
        assert_eq!(again.unchanged, 1);
        assert_eq!(again.created, 0);
        let same = again
            .documents
            .iter()
            .find(|d| d.source_path == "ADR-0001-first.md")
            .unwrap();
        assert_eq!(same.id, id, "the id must survive an edit");
        assert!(body_of(&store, &id).contains("revised substantially"));
        let item = store.get(Uuid::parse_str(&id).unwrap()).unwrap().unwrap();
        assert_eq!(
            string_field(&item, "body_content_hash").as_deref(),
            Some(sha256_hex(&body_of(&store, &id)).as_str()),
            "the hash must track the body"
        );
    }

    #[tokio::test]
    async fn changing_the_heading_renames_the_manuscript() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = fixture("retitle");

        let first = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        let id = first
            .documents
            .iter()
            .find(|d| d.source_path == "ADR-0002-second.md")
            .unwrap()
            .id
            .clone();
        assert_eq!(title_of(&store, &id), "The Second Decision");

        dir.write("ADR-0002-second.md", "# Renamed Decision\n\nBody two.\n");
        let again = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;

        assert_eq!(again.updated, 1);
        assert_eq!(title_of(&store, &id), "Renamed Decision");
        assert_eq!(
            again
                .documents
                .iter()
                .find(|d| d.source_path == "ADR-0002-second.md")
                .unwrap()
                .id,
            id
        );
    }

    #[tokio::test]
    async fn a_file_with_no_heading_falls_back_to_its_filename() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = TempDir::new("fallback");
        dir.write("plan-throughline.md", "No heading, just prose.\n");

        let r = s
            .import_directory(dir.path(), "Plans".into(), None, false, false)
            .await;
        assert_eq!(r.created, 1);
        assert_eq!(r.documents[0].title, "plan-throughline");
        assert_eq!(title_of(&store, &r.documents[0].id), "plan-throughline");
    }

    #[tokio::test]
    async fn a_dry_run_writes_nothing_and_predicts_the_real_run() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = fixture("dry");

        let dry = s
            .import_directory(dir.path(), "ADRs".into(), None, false, true)
            .await;
        assert!(dry.ok && dry.dry_run);
        assert_eq!(dry.created, 2);
        assert_eq!(dry.filed, 2);
        assert!(dry.collection_created);
        assert_eq!(dry.collection_id, None);
        assert_eq!(dry.skipped.len(), 2);

        // Nothing was written: no manuscripts, no collection.
        assert!(store
            .query(&ItemQuery {
                schema: Some("manuscript".into()),
                ..Default::default()
            })
            .unwrap()
            .is_empty());
        assert!(find_collection(&store, "ADRs").unwrap().is_none());

        // And the real run matches the prediction exactly.
        let real = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        assert_eq!(
            (real.created, real.updated, real.unchanged, real.filed),
            (2, 0, 0, 2)
        );
    }

    #[tokio::test]
    async fn a_pattern_narrows_the_set_without_reporting_the_rest() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = fixture("pattern");
        dir.write("design-notes.md", "# Design Notes\n\nUnrelated.\n");

        let r = s
            .import_directory(
                dir.path(),
                "ADRs".into(),
                Some("ADR-*.md".into()),
                false,
                false,
            )
            .await;
        assert_eq!(r.created, 2);
        assert!(
            r.documents
                .iter()
                .all(|d| d.source_path.starts_with("ADR-")),
            "{:?}",
            r.documents
        );
        assert!(
            r.skipped.is_empty(),
            "files excluded by the pattern are not 'skipped', they are out of scope: {:?}",
            r.skipped
        );
    }

    #[tokio::test]
    async fn recursion_is_opt_in_and_relative_paths_key_the_ids() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = TempDir::new("recursive");
        dir.write("top.md", "# Top\n\nx\n");
        dir.write("architecture/deep.md", "# Deep\n\ny\n");

        let flat = s
            .import_directory(dir.path(), "Docs".into(), None, false, true)
            .await;
        assert_eq!(flat.created, 1, "non-recursive stays at the top level");

        let deep = s
            .import_directory(dir.path(), "Docs".into(), None, true, false)
            .await;
        assert_eq!(deep.created, 2);
        assert!(deep
            .documents
            .iter()
            .any(|d| d.source_path == "architecture/deep.md"));
    }

    #[tokio::test]
    async fn a_missing_source_directory_fails_loudly() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let r = s
            .import_directory("/nope/not/here".into(), "ADRs".into(), None, false, false)
            .await;
        assert!(!r.ok);
        assert!(r.message.contains("not a directory"), "{}", r.message);
    }

    // --- the prune contract ------------------------------------------------

    #[tokio::test]
    async fn prune_reports_before_it_deletes_and_spares_real_content() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());

        // Two placeholder shells (title, no body) and one real manuscript.
        let shell_a = make_item_named(&store, "manuscript", "ADR-0011 impress journal");
        let shell_b = make_item_named(&store, "manuscript", "ADR-0012 knowledge objects");
        let dir = TempDir::new("prune");
        dir.write("ADR-0001-first.md", "# Real\n\nActual content.\n");
        let imported = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        let real_id = imported.documents[0].id.clone();

        let report = s.prune_empty_manuscripts(None, 0, false).await;
        assert!(report.ok && report.dry_run);
        assert_eq!(report.examined, 3);
        assert_eq!(report.empty, 2);
        assert_eq!(report.deleted, 0, "a report must not delete");
        let found: Vec<&str> = report.manuscripts.iter().map(|m| m.id.as_str()).collect();
        assert!(found.contains(&shell_a.as_str()) && found.contains(&shell_b.as_str()));
        assert!(
            !found.contains(&real_id.as_str()),
            "content is never reported"
        );
        // Still all there.
        assert!(store
            .get(Uuid::parse_str(&shell_a).unwrap())
            .unwrap()
            .is_some());

        let applied = s.prune_empty_manuscripts(None, 0, true).await;
        assert!(applied.ok && !applied.dry_run);
        assert_eq!(applied.deleted, 2);
        assert!(store
            .get(Uuid::parse_str(&shell_a).unwrap())
            .unwrap()
            .is_none());
        assert!(store
            .get(Uuid::parse_str(&shell_b).unwrap())
            .unwrap()
            .is_none());
        assert!(
            store
                .get(Uuid::parse_str(&real_id).unwrap())
                .unwrap()
                .is_some(),
            "the manuscript with a body must survive"
        );
    }

    #[tokio::test]
    async fn prune_scopes_to_a_collection_and_honours_the_threshold() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());

        // An unfiled shell, and a near-empty one inside the target collection.
        let unfiled = make_item_named(&store, "manuscript", "Loose shell");
        let dir = TempDir::new("prune-scope");
        dir.write("stub.md", "# Stub\n");
        let imported = s
            .import_directory(dir.path(), "ADRs".into(), None, false, false)
            .await;
        let stub_id = imported.documents[0].id.clone();

        // Strictly empty: the stub has 8 characters of body, so nothing goes.
        let strict = s
            .prune_empty_manuscripts(Some("ADRs".into()), 0, false)
            .await;
        assert_eq!(strict.examined, 1, "scoped to the collection");
        assert_eq!(strict.empty, 0);

        // Raise the threshold above the stub's length and it is reported.
        let loose = s
            .prune_empty_manuscripts(Some("ADRs".into()), 32, false)
            .await;
        assert_eq!(loose.empty, 1);
        assert_eq!(loose.manuscripts[0].id, stub_id);

        // The unfiled shell was never in scope.
        assert!(store
            .get(Uuid::parse_str(&unfiled).unwrap())
            .unwrap()
            .is_some());

        let missing = s
            .prune_empty_manuscripts(Some("Nope".into()), 0, true)
            .await;
        assert!(!missing.ok);
        assert!(
            missing.message.contains("no manuscript collection"),
            "{}",
            missing.message
        );
    }
}
