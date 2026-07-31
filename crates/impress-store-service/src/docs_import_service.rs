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
//! ## Watched folders (ADR-0023)
//!
//! The same service grew the *continuous* form of the same idea.
//! `import_directory` is a verb a human or agent invokes; a watched folder is a
//! verb the filesystem invokes, forever. ADR-0023 D5 puts discovery in Swift
//! (`NSMetadataQuery`, security-scoped bookmarks) and everything below it here,
//! so id derivation, provenance and the re-scan diff are ONE implementation that
//! the CLI, MCP and a headless test drive with every app closed.
//!
//! Eight verbs, in the order a caller uses them: `add_watched_folder` →
//! `import_discovered` (per bounded batch) → `record_produced_rows` (per file
//! the app's real importer ran on) → `finish_watched_scan`, with
//! `list_watched_folders`, `list_watched_files`, `update_watched_folder` and
//! `remove_watched_folder` around them. The mechanics live in
//! [`crate::watched_folder`]; this file is the agent-facing surface over them.
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
use impress_core::schemas::watched_folder::VOLUME_STATE_UNAVAILABLE;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{FieldMutation, ItemStore, StoreError};
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::store::store_instance;
use crate::watched_folder::{
    self, DiscoveredFileInput, DiscoveredFileOutcome, SkippedFile, WatchedFileDto, WatchedFolderDto,
};

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
// Watched-folder DTOs (ADR-0023)
// ---------------------------------------------------------------------------

/// One watched folder, or the failure that stopped the verb.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WatchedFolderResult {
    pub ok: bool,
    pub folder: Option<WatchedFolderDto>,
    /// True when THIS call created the row. False on a re-add, which is a
    /// no-op that returns the existing folder.
    pub created: bool,
    pub message: String,
}

/// Every watched folder the store knows about.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WatchedFolderListResult {
    pub ok: bool,
    pub folders: Vec<WatchedFolderDto>,
    pub message: String,
}

/// What removing a watched folder took with it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WatchedFolderRemovalResult {
    pub ok: bool,
    pub removed: bool,
    /// `watched-file` index entries deleted. Zero unless asked.
    pub file_rows_deleted: u32,
    pub message: String,
}

/// What one discovery batch did (ADR-0023 D4).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct DiscoveredImportResult {
    pub ok: bool,
    /// True when NOTHING was written. The counts are what a real run would do.
    pub dry_run: bool,
    pub watched_folder_id: String,
    pub kind_scope: String,
    /// Files seen for the first time.
    pub created: u32,
    /// Files whose content hash moved.
    pub changed: u32,
    /// Files whose hash is identical — **these wrote nothing at all**.
    pub unchanged: u32,
    /// Files that were `missing` and are back.
    pub restored: u32,
    /// Write-gate batches used (`ceil(files / 500)`), for the D7 burst budget.
    pub batches: u32,
    /// Every file acted on, in path order.
    pub files: Vec<DiscoveredFileOutcome>,
    /// Files declined, with the reason. Never silently dropped.
    pub skipped: Vec<SkippedFile>,
    pub message: String,
}

impl DiscoveredImportResult {
    fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            dry_run: false,
            watched_folder_id: String::new(),
            kind_scope: String::new(),
            created: 0,
            changed: 0,
            unchanged: 0,
            restored: 0,
            batches: 0,
            files: Vec::new(),
            skipped: Vec::new(),
            message: message.into(),
        }
    }
}

/// What the terminal sweep of a scan found.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WatchedScanResult {
    pub ok: bool,
    pub dry_run: bool,
    pub watched_folder_id: String,
    /// Rows examined (everything the folder still called `present`).
    pub examined: u32,
    /// Rows whose path is still on disk.
    pub present: u32,
    /// Rows flipped to `missing` by this call. **Nothing was deleted.**
    pub marked_missing: u32,
    /// The rows that went missing, so a caller can act on them without a
    /// second query.
    pub missing: Vec<WatchedFileDto>,
    /// The folder row after its stats were written.
    pub folder: Option<WatchedFolderDto>,
    pub message: String,
}

impl WatchedScanResult {
    fn failed(watched_folder_id: &str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            dry_run: false,
            watched_folder_id: watched_folder_id.to_string(),
            examined: 0,
            present: 0,
            marked_missing: 0,
            missing: Vec::new(),
            folder: None,
            message: message.into(),
        }
    }
}

/// Discovered files, paged.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WatchedFileListResult {
    pub ok: bool,
    pub files: Vec<WatchedFileDto>,
    /// Unpaged match count, so "200 of 4000" is distinguishable from
    /// "200 of 200".
    pub total: u32,
    pub message: String,
}

/// What attributing rows to a file changed — **the W2 seam's answer**.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProducedRowsResult {
    pub ok: bool,
    pub file: Option<WatchedFileDto>,
    /// Ids newly attributed to this file.
    pub added: u32,
    /// Ids that were attributed to it before and are not now — the rows a
    /// re-import ORPHANED, which is how a deletion inside a `.bib` becomes
    /// visible. What to do about them is the app's decision, not this crate's.
    pub removed_ids: Vec<String>,
    pub message: String,
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Files on disk become store rows, repeatably — once on request
/// (`import_directory`) or continuously (the watched-folder verbs, ADR-0023).
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

    // -- Watched folders (ADR-0023) ----------------------------------------

    /// Start watching a directory for files of one record kind.
    ///
    /// `kind_scope` is the record kind whose `FileDiscoveryCapability` decides
    /// *which* files count: `"publication"` (`.bib`/`.ris`), `"manuscript"`
    /// (the manuscript-format extensions), `"figure"` (`.vsz`), `"message"`
    /// (`.mbox`/`.eml`). The file types are deliberately NOT an argument —
    /// they are declared once, on the record kind, and restating them here
    /// would be a second authority that can disagree with the first.
    ///
    /// **Idempotent.** The folder's id is derived from `(path, kind_scope)`, so
    /// adding the same folder twice returns the existing row rather than a
    /// duplicate. Re-adding with a fresh `bookmark_base64` swaps the bookmark
    /// in — that is how a Swift caller hands over a re-granted access scope —
    /// and changes nothing else.
    ///
    /// Watching a directory for two different kinds is two folders, on purpose:
    /// they have two file sets and two provenances.
    ///
    /// Nothing is scanned by this call. Discovery is `import_discovered`.
    #[impress_method]
    async fn add_watched_folder(
        &self,
        path: String,
        kind_scope: String,
        display_name: Option<String>,
        bookmark_base64: Option<String>,
        recursive: bool,
    ) -> WatchedFolderResult;

    /// Every watched folder, optionally narrowed to one `kind_scope`, in path
    /// order — with its last-scan stats and its declared volume state.
    #[impress_method]
    async fn list_watched_folders(&self, kind_scope: Option<String>) -> WatchedFolderListResult;

    /// Change a watched folder's mutable facets. Every field is optional and a
    /// null leaves that field alone, so pausing a folder cannot blank its
    /// bookmark by omission.
    ///
    /// `volume_state` is the ADR-0023 D6 declaration — `"indexed"`,
    /// `"unindexed"`, `"scan-on-demand"` or `"unavailable"`. Setting it is how
    /// a folder on a Spotlight-less volume says so, instead of rendering as an
    /// honest-looking zero.
    #[impress_method]
    async fn update_watched_folder(
        &self,
        id: String,
        enabled: Option<bool>,
        recursive: Option<bool>,
        display_name: Option<String>,
        bookmark_base64: Option<String>,
        volume_state: Option<String>,
    ) -> WatchedFolderResult;

    /// Stop watching a folder.
    ///
    /// **Never touches a byte on disk** — ADR-0023 D4's reference-in-place rule
    /// is one-way, and the store row was only ever an index entry. The rows the
    /// folder's files PRODUCED are also left alone: a publication imported from
    /// a watched `.bib` is a publication, and un-watching its folder is not a
    /// retraction of it.
    ///
    /// `delete_file_rows` additionally removes the folder's `watched-file`
    /// index entries. Leave it false to keep the provenance readable.
    #[impress_method]
    async fn remove_watched_folder(
        &self,
        id: String,
        delete_file_rows: bool,
    ) -> WatchedFolderRemovalResult;

    /// Record a batch of discovered files against a watched folder — the
    /// ADR-0023 D4 diff.
    ///
    /// * A path not seen before becomes a `watched-file` row carrying its
    ///   provenance, content hash and mtime.
    /// * A path whose hash changed is updated **in place, same id**.
    /// * A path whose hash is identical writes **nothing at all** — not the
    ///   row, not a timestamp. Re-running discovery over a settled tree is
    ///   free and fires no store mutation.
    /// * A path that was `missing` and is back is restored, same id, with its
    ///   produced-row attribution intact.
    ///
    /// Missing files are NOT found here. A batch never has to be a complete
    /// set — live discovery reports one file at a time — so absence from a
    /// batch means nothing. `finish_watched_scan` is what looks for them.
    ///
    /// `content_hash`, `mtime` and `size_bytes` on each file are optional: pass
    /// them if you have them (Swift does, from the metadata query), and they
    /// are read off disk if you do not.
    ///
    /// There is deliberately no `kind_scope` argument. The folder declares its
    /// scope when it is added, and it is read from the folder row here. A
    /// second copy on every discovery call could only ever be redundant or
    /// wrong, and "wrong" would mean file rows whose scope disagrees with the
    /// folder that owns them.
    ///
    /// Bounded per ADR-0023 D7: paths are sorted and written in batches of 500,
    /// and at most 5000 files may be sent in one call. A bigger tree is paged.
    #[impress_method]
    async fn import_discovered(
        &self,
        watched_folder_id: String,
        files: Vec<DiscoveredFileInput>,
        dry_run: bool,
    ) -> DiscoveredImportResult;

    /// Close a scan: find the files that vanished, and write the folder's
    /// last-scan stats.
    ///
    /// A file whose path is gone is marked `missing` — **never deleted**
    /// (ADR-0023 D4). A moved file is not a retracted one, and the rows it
    /// produced are still real.
    ///
    /// **Refuses to run when the folder's own root is unreachable.** If a
    /// volume unmounted or a bookmark lapsed, every path under it stops
    /// existing at once and a credulous sweep would mark a whole library
    /// missing in a single pass. ADR-0023 D6 requires the folder to declare
    /// that state instead; this is that rule with teeth.
    ///
    /// `new_count` / `changed_count` / `duration_ms` are the caller's running
    /// totals across however many `import_discovered` calls the scan took — no
    /// single one of them knows the total. The file and missing counts are
    /// computed here.
    ///
    /// Pass `dry_run` to see what would be marked without marking it.
    #[impress_method]
    async fn finish_watched_scan(
        &self,
        watched_folder_id: String,
        new_count: Option<i64>,
        changed_count: Option<i64>,
        duration_ms: Option<i64>,
        dry_run: bool,
    ) -> WatchedScanResult;

    /// Attribute store rows to the discovered file that produced them.
    ///
    /// This is the seam between file-level bookkeeping (here) and each app's
    /// real importer (there). Discovery never writes it, because this crate
    /// does not know how to parse a `.bib` and must not learn:
    ///
    /// 1. `import_discovered` reports a file as `created` / `changed` /
    ///    `restored`.
    /// 2. The app's own importer runs on that one file — imbib's BibTeX/RIS
    ///    import with its identifier dedup for `entries` ingest, or the
    ///    reference-in-place row builder for `file` ingest.
    /// 3. It calls this with the ids it produced.
    ///
    /// `replace` is what makes deletions detectable. Re-importing an edited
    /// `.bib` that lost an entry returns that entry's id in `removed_ids`, so
    /// the caller can decide what "the source no longer contains this" should
    /// mean — a product decision, and therefore not one this crate makes. Pass
    /// `replace: false` to union instead, which is what an incremental append
    /// wants.
    #[impress_method]
    async fn record_produced_rows(
        &self,
        file_id: String,
        produced_ids: Vec<String>,
        replace: bool,
    ) -> ProducedRowsResult;

    /// The provenance query, both directions.
    ///
    /// * `watched_folder_id` — "which files does this folder know about?",
    ///   optionally narrowed to `state: "present"` or `"missing"`, paged.
    /// * `file_id` — one file's row, whose `produced_ids` answers "which store
    ///   rows did this file produce?" and whose `needs_reimport` says whether
    ///   its content has moved on since.
    ///
    /// One of the two is required.
    #[impress_method]
    async fn list_watched_files(
        &self,
        watched_folder_id: Option<String>,
        file_id: Option<String>,
        state: Option<String>,
        limit: i64,
        offset: i64,
    ) -> WatchedFileListResult;
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

    // -- Watched folders (ADR-0023) ----------------------------------------

    async fn add_watched_folder(
        &self,
        path: String,
        kind_scope: String,
        display_name: Option<String>,
        bookmark_base64: Option<String>,
        recursive: bool,
    ) -> WatchedFolderResult {
        let store = self.store();
        let expanded = shellexpand_home(&path);
        match watched_folder::create_folder(
            &store,
            &expanded,
            &kind_scope,
            display_name.as_deref(),
            bookmark_base64.as_deref(),
            recursive,
        ) {
            Ok((folder, created)) => {
                let message = if created {
                    format!(
                        "Watching '{}' for {} files. Nothing scanned yet — call \
                         import_discovered with the files you find.",
                        folder.path, folder.kind_scope
                    )
                } else {
                    format!(
                        "'{}' is already watched for {} files (id {}).",
                        folder.path, folder.kind_scope, folder.id
                    )
                };
                WatchedFolderResult {
                    ok: true,
                    folder: Some(folder),
                    created,
                    message,
                }
            }
            Err(e) => WatchedFolderResult {
                ok: false,
                folder: None,
                created: false,
                message: e,
            },
        }
    }

    async fn list_watched_folders(&self, kind_scope: Option<String>) -> WatchedFolderListResult {
        let store = self.store();
        match watched_folder::list_folders(&store, kind_scope.as_deref()) {
            Ok(folders) => WatchedFolderListResult {
                message: format!("{} watched folder(s).", folders.len()),
                ok: true,
                folders,
            },
            Err(e) => WatchedFolderListResult {
                ok: false,
                folders: Vec::new(),
                message: e,
            },
        }
    }

    async fn update_watched_folder(
        &self,
        id: String,
        enabled: Option<bool>,
        recursive: Option<bool>,
        display_name: Option<String>,
        bookmark_base64: Option<String>,
        volume_state: Option<String>,
    ) -> WatchedFolderResult {
        let store = self.store();
        match watched_folder::update_folder(
            &store,
            &id,
            enabled,
            recursive,
            display_name.as_deref(),
            bookmark_base64.as_deref(),
            volume_state.as_deref(),
        ) {
            Ok(folder) => WatchedFolderResult {
                message: format!(
                    "'{}' — enabled: {}, volume: {}.",
                    folder.path,
                    folder.enabled,
                    folder.volume_state.as_deref().unwrap_or("undeclared")
                ),
                ok: true,
                folder: Some(folder),
                created: false,
            },
            Err(e) => WatchedFolderResult {
                ok: false,
                folder: None,
                created: false,
                message: e,
            },
        }
    }

    async fn remove_watched_folder(
        &self,
        id: String,
        delete_file_rows: bool,
    ) -> WatchedFolderRemovalResult {
        let store = self.store();
        match watched_folder::remove_folder(&store, &id, delete_file_rows) {
            Ok((removed, deleted)) => WatchedFolderRemovalResult {
                ok: true,
                removed,
                file_rows_deleted: deleted,
                message: if removed {
                    format!(
                        "Stopped watching {id}; {deleted} index entr(ies) removed. No \
                         file on disk was touched, and the rows these files produced \
                         are untouched."
                    )
                } else {
                    format!("No watched folder {id}.")
                },
            },
            Err(e) => WatchedFolderRemovalResult {
                ok: false,
                removed: false,
                file_rows_deleted: 0,
                message: e,
            },
        }
    }

    async fn import_discovered(
        &self,
        watched_folder_id: String,
        files: Vec<DiscoveredFileInput>,
        dry_run: bool,
    ) -> DiscoveredImportResult {
        let store = self.store();
        let folder = match watched_folder::load_folder(&store, &watched_folder_id) {
            Ok(Some(item)) => item,
            Ok(None) => {
                return DiscoveredImportResult::failed(format!(
                    "no watched folder {watched_folder_id} — call add_watched_folder first"
                ))
            }
            Err(e) => return DiscoveredImportResult::failed(e),
        };
        let kind_scope = watched_folder::folder_to_dto(&folder).kind_scope;

        match watched_folder::upsert_discovered(&store, &folder, &files, dry_run) {
            Ok(outcome) => {
                let prefix = if dry_run { "Would record" } else { "Recorded" };
                let message = format!(
                    "{prefix} {} discovered file(s) for {kind_scope} in {} batch(es): \
                     {} new, {} changed, {} unchanged, {} restored, {} skipped. \
                     Missing files are found by finish_watched_scan, not by absence here.",
                    outcome.files.len(),
                    outcome.batches,
                    outcome.created,
                    outcome.changed,
                    outcome.unchanged,
                    outcome.restored,
                    outcome.skipped.len()
                );
                DiscoveredImportResult {
                    ok: true,
                    dry_run,
                    watched_folder_id: folder.id.to_string(),
                    kind_scope,
                    created: outcome.created,
                    changed: outcome.changed,
                    unchanged: outcome.unchanged,
                    restored: outcome.restored,
                    batches: outcome.batches,
                    files: outcome.files,
                    skipped: outcome.skipped,
                    message,
                }
            }
            Err(e) => DiscoveredImportResult::failed(e),
        }
    }

    async fn finish_watched_scan(
        &self,
        watched_folder_id: String,
        new_count: Option<i64>,
        changed_count: Option<i64>,
        duration_ms: Option<i64>,
        dry_run: bool,
    ) -> WatchedScanResult {
        let store = self.store();
        let folder = match watched_folder::load_folder(&store, &watched_folder_id) {
            Ok(Some(item)) => item,
            Ok(None) => {
                return WatchedScanResult::failed(
                    &watched_folder_id,
                    format!("no watched folder {watched_folder_id}"),
                )
            }
            Err(e) => return WatchedScanResult::failed(&watched_folder_id, e),
        };

        let outcome = match watched_folder::sweep_missing(&store, &folder, dry_run) {
            Ok(outcome) => outcome,
            Err(e) => {
                // The root is unreachable. Declare it (D6) rather than
                // reporting a scan that found nothing, and say why.
                let declared = watched_folder::update_folder(
                    &store,
                    &watched_folder_id,
                    None,
                    None,
                    None,
                    None,
                    Some(VOLUME_STATE_UNAVAILABLE),
                )
                .ok();
                let mut failure = WatchedScanResult::failed(&watched_folder_id, e);
                failure.folder = declared;
                return failure;
            }
        };

        let folder_dto = if dry_run {
            Some(watched_folder::folder_to_dto(&folder))
        } else {
            match watched_folder::record_scan_stats(
                &store,
                &folder,
                outcome.present as i64,
                new_count.unwrap_or(0).max(0),
                changed_count.unwrap_or(0).max(0),
                outcome.marked_missing as i64,
                duration_ms.unwrap_or(0).max(0),
            ) {
                Ok(dto) => Some(dto),
                Err(e) => return WatchedScanResult::failed(&watched_folder_id, e),
            }
        };

        let prefix = if dry_run { "Would mark" } else { "Marked" };
        let message = format!(
            "Examined {} present file(s): {} still on disk, {prefix} {} missing. \
             Nothing was deleted — a vanished file keeps its row and its provenance.",
            outcome.examined, outcome.present, outcome.marked_missing
        );
        WatchedScanResult {
            ok: true,
            dry_run,
            watched_folder_id: folder.id.to_string(),
            examined: outcome.examined,
            present: outcome.present,
            marked_missing: outcome.marked_missing,
            missing: outcome.missing,
            folder: folder_dto,
            message,
        }
    }

    async fn record_produced_rows(
        &self,
        file_id: String,
        produced_ids: Vec<String>,
        replace: bool,
    ) -> ProducedRowsResult {
        let store = self.store();
        match watched_folder::record_produced(&store, &file_id, &produced_ids, replace) {
            Ok(outcome) => {
                let message = format!(
                    "{} now accounts for {} produced row(s): {} added, {} orphaned by \
                     this import.",
                    outcome.file.path,
                    outcome.file.produced_ids.len(),
                    outcome.added,
                    outcome.removed_ids.len()
                );
                ProducedRowsResult {
                    ok: true,
                    file: Some(outcome.file),
                    added: outcome.added,
                    removed_ids: outcome.removed_ids,
                    message,
                }
            }
            Err(e) => ProducedRowsResult {
                ok: false,
                file: None,
                added: 0,
                removed_ids: Vec::new(),
                message: e,
            },
        }
    }

    async fn list_watched_files(
        &self,
        watched_folder_id: Option<String>,
        file_id: Option<String>,
        state: Option<String>,
        limit: i64,
        offset: i64,
    ) -> WatchedFileListResult {
        let store = self.store();
        let limit = if limit <= 0 {
            watched_folder::DEFAULT_FILE_LIST_LIMIT
        } else {
            limit
        };
        match watched_folder::list_files(
            &store,
            watched_folder_id.as_deref(),
            file_id.as_deref(),
            state.as_deref(),
            limit,
            offset,
        ) {
            Ok((files, total)) => WatchedFileListResult {
                message: format!("{} of {total} discovered file(s).", files.len()),
                ok: true,
                files,
                total,
            },
            Err(e) => WatchedFileListResult {
                ok: false,
                files: Vec::new(),
                total: 0,
                message: e,
            },
        }
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
        // ADR-0023 watched folders.
        add_watched_folder(
            path: String,
            kind_scope: String,
            display_name: Option<String>,
            bookmark_base64: Option<String>,
            recursive: bool
        ) -> WatchedFolderResult,
        list_watched_folders(kind_scope: Option<String>) -> WatchedFolderListResult,
        update_watched_folder(
            id: String,
            enabled: Option<bool>,
            recursive: Option<bool>,
            display_name: Option<String>,
            bookmark_base64: Option<String>,
            volume_state: Option<String>
        ) -> WatchedFolderResult,
        remove_watched_folder(
            id: String,
            delete_file_rows: bool
        ) -> WatchedFolderRemovalResult,
        import_discovered(
            watched_folder_id: String,
            files: Vec<DiscoveredFileInput>,
            dry_run: bool
        ) -> DiscoveredImportResult,
        finish_watched_scan(
            watched_folder_id: String,
            new_count: Option<i64>,
            changed_count: Option<i64>,
            duration_ms: Option<i64>,
            dry_run: bool
        ) -> WatchedScanResult,
        record_produced_rows(
            file_id: String,
            produced_ids: Vec<String>,
            replace: bool
        ) -> ProducedRowsResult,
        list_watched_files(
            watched_folder_id: Option<String>,
            file_id: Option<String>,
            state: Option<String>,
            limit: i64,
            offset: i64
        ) -> WatchedFileListResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item_named, test_store, ScratchDir as TempDir};

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

/// The ADR-0023 watched-folder verbs, driven through the service exactly as
/// MCP, the CLI and (via the FFI) W1's `FolderWatchService` drive them.
///
/// Every test here runs against an in-memory store and a scratch directory
/// under the OS temp dir. Nothing in this file can see a real library.
#[cfg(test)]
mod watched_folder_tests {
    use super::*;
    use crate::test_support::{test_store, ScratchDir};
    use crate::watched_folder::{MAX_DISCOVERED_FILES_PER_CALL, MAX_DISCOVERY_BATCH};
    use impress_core::schemas::watched_folder::{
        FILE_STATE_MISSING, FILE_STATE_PRESENT, WATCHED_FILE_SCHEMA, WATCHED_FOLDER_SCHEMA,
    };

    /// A `.bib`-watching folder over a scratch tree with two files in it.
    async fn fixture(
        tag: &str,
    ) -> (
        Arc<SqliteItemStore>,
        DefaultDocsImportService,
        ScratchDir,
        String,
    ) {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = ScratchDir::new(tag);
        dir.write("refs.bib", "@article{a2020, title={A}}\n");
        dir.write("more.ris", "TY  - JOUR\nTI  - B\nER  -\n");
        let added = s
            .add_watched_folder(dir.path(), "publication".into(), None, None, true)
            .await;
        assert!(added.ok, "{}", added.message);
        let id = added.folder.expect("folder").id;
        (store, s, dir, id)
    }

    /// Discovery input naming a file by path only — the CLI/MCP shape, where
    /// the hash and mtime are read off disk.
    fn by_path(path: &str) -> DiscoveredFileInput {
        DiscoveredFileInput {
            path: path.into(),
            content_hash: None,
            mtime: None,
            size_bytes: None,
            bookmark_base64: None,
        }
    }

    /// Discovery input that carries everything — the Swift shape, where the
    /// metadata query already knows. No disk access at all, which is what lets
    /// the bounds tests use thousands of files that never existed.
    fn declared(path: &str, hash: &str) -> DiscoveredFileInput {
        DiscoveredFileInput {
            path: path.into(),
            content_hash: Some(hash.into()),
            mtime: Some("2026-07-31T00:00:00Z".into()),
            size_bytes: Some(42),
            bookmark_base64: None,
        }
    }

    fn file_row(store: &SqliteItemStore, id: &str) -> Item {
        store
            .get(Uuid::parse_str(id).unwrap())
            .unwrap()
            .expect("file row present")
    }

    // --- the folder ------------------------------------------------------

    #[tokio::test]
    async fn adding_a_folder_is_idempotent_and_scoped_by_kind() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = ScratchDir::new("folder-idempotent");

        let first = s
            .add_watched_folder(dir.path(), "publication".into(), None, None, true)
            .await;
        assert!(first.ok && first.created, "{}", first.message);

        // Same directory, same kind: the same row, not a second one.
        let again = s
            .add_watched_folder(dir.path(), "publication".into(), None, None, true)
            .await;
        assert!(again.ok && !again.created);
        assert_eq!(again.folder.unwrap().id, first.folder.clone().unwrap().id);

        // Trailing slash is the same folder too.
        let slashed = s
            .add_watched_folder(
                format!("{}/", dir.path()),
                "publication".into(),
                None,
                None,
                true,
            )
            .await;
        assert!(!slashed.created, "a trailing slash is not a new folder");

        // Same directory, DIFFERENT kind: a second folder, on purpose — two
        // file sets, two provenances.
        let manuscripts = s
            .add_watched_folder(dir.path(), "manuscript".into(), None, None, true)
            .await;
        assert!(manuscripts.ok && manuscripts.created);
        assert_ne!(
            manuscripts.folder.unwrap().id,
            first.folder.unwrap().id,
            "one directory watched for two kinds is two folders"
        );

        let listed = s.list_watched_folders(None).await;
        assert_eq!(listed.folders.len(), 2);
        assert_eq!(
            s.list_watched_folders(Some("publication".into()))
                .await
                .folders
                .len(),
            1,
            "the kind_scope filter narrows"
        );
    }

    #[tokio::test]
    async fn re_adding_a_folder_swaps_in_a_refreshed_bookmark_and_nothing_else() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = ScratchDir::new("bookmark-refresh");

        s.add_watched_folder(
            dir.path(),
            "publication".into(),
            Some("Papers".into()),
            Some("Ym9va21hcmstMQ==".into()),
            true,
        )
        .await;
        // A re-grant produces new bookmark bytes; the display name must survive.
        let again = s
            .add_watched_folder(
                dir.path(),
                "publication".into(),
                None,
                Some("Ym9va21hcmstMg==".into()),
                true,
            )
            .await;
        let folder = again.folder.expect("folder");
        assert!(!again.created);
        assert_eq!(folder.bookmark_base64.as_deref(), Some("Ym9va21hcmstMg=="));
        assert_eq!(folder.display_name, "Papers");
    }

    #[tokio::test]
    async fn a_folder_declares_its_volume_state_and_rejects_an_invented_one() {
        let (_store, s, _dir, id) = fixture("volume").await;

        let declared = s
            .update_watched_folder(id.clone(), None, None, None, None, Some("unindexed".into()))
            .await;
        assert!(declared.ok, "{}", declared.message);
        assert_eq!(
            declared.folder.unwrap().volume_state.as_deref(),
            Some("unindexed"),
            "D6: an unindexed volume says so rather than reading as empty"
        );

        let invented = s
            .update_watched_folder(id.clone(), None, None, None, None, Some("vibes".into()))
            .await;
        assert!(!invented.ok);
        assert!(
            invented.message.contains("volume_state"),
            "{}",
            invented.message
        );

        // Pausing must not blank anything by omission.
        let paused = s
            .update_watched_folder(id, Some(false), None, None, None, None)
            .await;
        let folder = paused.folder.unwrap();
        assert!(!folder.enabled);
        assert_eq!(folder.volume_state.as_deref(), Some("unindexed"));
    }

    // --- D4: new / changed / unchanged / missing --------------------------

    #[tokio::test]
    async fn a_new_file_becomes_an_index_row_carrying_its_provenance() {
        let (store, s, dir, folder_id) = fixture("new").await;

        let r = s
            .import_discovered(
                folder_id.clone(),
                vec![
                    by_path(&dir.join("refs.bib")),
                    by_path(&dir.join("more.ris")),
                ],
                false,
            )
            .await;
        assert!(r.ok, "{}", r.message);
        assert_eq!(
            (r.created, r.changed, r.unchanged, r.restored),
            (2, 0, 0, 0)
        );
        assert_eq!(r.batches, 1);
        assert!(r.files.iter().all(|f| f.action == "created"));

        let listed = s
            .list_watched_files(Some(folder_id.clone()), None, None, 0, 0)
            .await;
        assert_eq!(listed.total, 2);
        let bib = listed
            .files
            .iter()
            .find(|f| f.path.ends_with("refs.bib"))
            .expect("the .bib row");
        assert_eq!(bib.watched_folder_id, folder_id, "provenance is recorded");
        assert_eq!(bib.state, FILE_STATE_PRESENT);
        assert_eq!(bib.kind_scope, "publication");
        assert_eq!(bib.content_hash.len(), 64, "a sha256 hex digest");
        assert!(bib.mtime.is_some() && bib.size_bytes > 0, "read off disk");
        assert!(bib.first_seen_at.is_some() && bib.last_seen_at.is_some());
        assert!(
            bib.produced_ids.is_empty() && bib.produced_at.is_none(),
            "discovery never writes the fan-out — that is W2's seam"
        );
        assert!(bib.needs_reimport, "nothing has imported it yet");

        // The envelope parent is the owning folder, so a graph traversal finds
        // the same set the payload back-reference does.
        let item = file_row(&store, &bib.id);
        assert_eq!(item.schema, WATCHED_FILE_SCHEMA);
        assert_eq!(item.parent, Some(Uuid::parse_str(&folder_id).unwrap()));
    }

    #[tokio::test]
    async fn a_changed_hash_updates_in_place_and_keeps_the_id() {
        let (store, s, dir, folder_id) = fixture("changed").await;
        let bib = dir.join("refs.bib");

        let first = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;
        let id = first.files[0].id.clone();
        let hash_before = first.files[0].content_hash.clone();

        dir.write(
            "refs.bib",
            "@article{a2020, title={A revised}}\n@book{b, }\n",
        );
        let again = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;

        assert_eq!(
            (again.created, again.changed, again.unchanged),
            (0, 1, 0),
            "{:?}",
            again.files
        );
        assert_eq!(again.files[0].id, id, "the id must survive an edit");
        assert_ne!(again.files[0].content_hash, hash_before);
        let row = file_row(&store, &id);
        assert_eq!(
            string_field(&row, "content_hash").as_deref(),
            Some(again.files[0].content_hash.as_str()),
        );
    }

    /// The idempotency claim, asserted where it lives: not "the counts say
    /// unchanged" but "the ROWS did not move". `modified` and `logical_clock`
    /// are what `store.update` bumps, so comparing them proves no write
    /// happened — which is what keeps a settled tree from firing
    /// `.storeDidMutate` on every re-scan.
    #[tokio::test]
    async fn an_unchanged_rescan_writes_nothing_at_all() {
        let (store, s, dir, folder_id) = fixture("idempotent").await;
        let files = vec![
            by_path(&dir.join("refs.bib")),
            by_path(&dir.join("more.ris")),
        ];

        let first = s
            .import_discovered(folder_id.clone(), files.clone(), false)
            .await;
        assert_eq!(first.created, 2);
        let before: Vec<(String, chrono::DateTime<chrono::Utc>, u64)> = first
            .files
            .iter()
            .map(|f| {
                let row = file_row(&store, &f.id);
                (f.id.clone(), row.modified, row.logical_clock)
            })
            .collect();

        let again = s.import_discovered(folder_id.clone(), files, false).await;
        assert_eq!(
            (
                again.created,
                again.changed,
                again.unchanged,
                again.restored
            ),
            (0, 0, 2, 0)
        );

        for (id, modified, clock) in before {
            let row = file_row(&store, &id);
            assert_eq!(
                row.modified, modified,
                "{id} was rewritten by a no-op re-scan"
            );
            assert_eq!(row.logical_clock, clock, "{id} took a logical-clock tick");
        }
        // And no duplicate rows were minted.
        assert_eq!(
            store
                .query(&ItemQuery {
                    schema: Some(WATCHED_FILE_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap()
                .len(),
            2
        );
    }

    #[tokio::test]
    async fn a_vanished_file_is_marked_missing_and_never_deleted() {
        let (store, s, dir, folder_id) = fixture("missing").await;
        let r = s
            .import_discovered(
                folder_id.clone(),
                vec![
                    by_path(&dir.join("refs.bib")),
                    by_path(&dir.join("more.ris")),
                ],
                false,
            )
            .await;
        let bib_id = r
            .files
            .iter()
            .find(|f| f.path.ends_with("refs.bib"))
            .unwrap()
            .id
            .clone();

        // Something the importer produced from it, so we can prove the
        // provenance survives the disappearance.
        let produced =
            crate::test_support::make_item_named(&store, "imbib/bibliography-entry", "A paper");
        let attributed = s
            .record_produced_rows(bib_id.clone(), vec![produced.clone()], true)
            .await;
        assert!(attributed.ok, "{}", attributed.message);

        dir.remove("refs.bib");
        let scan = s
            .finish_watched_scan(folder_id.clone(), Some(2), Some(0), Some(120), false)
            .await;

        assert!(scan.ok, "{}", scan.message);
        assert_eq!(
            (scan.examined, scan.present, scan.marked_missing),
            (2, 1, 1)
        );
        assert_eq!(scan.missing.len(), 1);
        assert!(scan.missing[0].path.ends_with("refs.bib"));

        let row = file_row(&store, &bib_id);
        assert_eq!(
            string_field(&row, "state").as_deref(),
            Some(FILE_STATE_MISSING),
            "the row is MARKED, not deleted"
        );
        assert!(string_field(&row, "missing_since").is_some());

        let one = s
            .list_watched_files(None, Some(bib_id.clone()), None, 0, 0)
            .await;
        assert_eq!(
            one.files[0].produced_ids,
            vec![produced],
            "what the file put in the store outlives the file"
        );
        assert!(
            !one.files[0].needs_reimport,
            "a missing file owes the importer nothing"
        );

        // The folder's stats record what the scan saw.
        let folder = scan.folder.expect("folder stats");
        assert_eq!(folder.last_scan_file_count, 1);
        assert_eq!(folder.last_scan_missing_count, 1);
        assert_eq!(folder.last_scan_new_count, 2);
        assert_eq!(folder.last_scan_duration_ms, 120);
        assert!(folder.last_scan_at.is_some());
    }

    #[tokio::test]
    async fn a_returning_file_is_restored_with_the_same_id() {
        let (store, s, dir, folder_id) = fixture("restored").await;
        let bib = dir.join("refs.bib");
        let first = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;
        let id = first.files[0].id.clone();

        dir.remove("refs.bib");
        s.finish_watched_scan(folder_id.clone(), None, None, None, false)
            .await;
        assert_eq!(
            string_field(&file_row(&store, &id), "state").as_deref(),
            Some(FILE_STATE_MISSING)
        );

        // Back, byte for byte identical — which is still news, because the row
        // says otherwise.
        dir.write("refs.bib", "@article{a2020, title={A}}\n");
        let back = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;
        assert_eq!(
            (back.created, back.changed, back.unchanged, back.restored),
            (0, 0, 0, 1),
            "an identical hash is still a restore when the row said missing"
        );
        assert_eq!(back.files[0].id, id);
        let row = file_row(&store, &id);
        assert_eq!(
            string_field(&row, "state").as_deref(),
            Some(FILE_STATE_PRESENT)
        );
        assert!(
            string_field(&row, "missing_since").is_none(),
            "a returned file is not a stale tombstone"
        );
    }

    /// The D6 interlock. An unmounted volume makes every path vanish at once;
    /// a sweep that believed the filesystem would mark a whole library missing
    /// in one pass. The failure must be loud, the rows untouched, and the
    /// folder's state declared.
    #[tokio::test]
    async fn the_sweep_refuses_to_run_when_the_folder_root_is_unreachable() {
        let (store, s, dir, folder_id) = fixture("unmounted").await;
        let r = s
            .import_discovered(
                folder_id.clone(),
                vec![
                    by_path(&dir.join("refs.bib")),
                    by_path(&dir.join("more.ris")),
                ],
                false,
            )
            .await;
        let ids: Vec<String> = r.files.iter().map(|f| f.id.clone()).collect();

        dir.destroy();
        let scan = s
            .finish_watched_scan(folder_id.clone(), None, None, None, false)
            .await;

        assert!(
            !scan.ok,
            "an unreachable root must not read as a clean scan"
        );
        assert!(
            scan.message.contains("refusing to mark any file missing"),
            "{}",
            scan.message
        );
        assert_eq!(scan.marked_missing, 0);
        assert_eq!(
            scan.folder.expect("folder").volume_state.as_deref(),
            Some("unavailable"),
            "D6: the folder DECLARES the degraded state"
        );
        for id in ids {
            assert_eq!(
                string_field(&file_row(&store, &id), "state").as_deref(),
                Some(FILE_STATE_PRESENT),
                "not one row may be touched when the volume went away"
            );
        }
    }

    #[tokio::test]
    async fn a_dry_run_predicts_the_real_run_and_writes_nothing() {
        let (store, s, dir, folder_id) = fixture("dry").await;
        let files = vec![
            by_path(&dir.join("refs.bib")),
            by_path(&dir.join("more.ris")),
        ];

        let dry = s
            .import_discovered(folder_id.clone(), files.clone(), true)
            .await;
        assert!(dry.ok && dry.dry_run);
        assert_eq!(dry.created, 2);
        assert!(
            store
                .query(&ItemQuery {
                    schema: Some(WATCHED_FILE_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap()
                .is_empty(),
            "a dry run writes nothing at all"
        );

        let real = s.import_discovered(folder_id.clone(), files, false).await;
        assert_eq!(
            (real.created, real.changed, real.unchanged),
            (dry.created, dry.changed, dry.unchanged)
        );

        // And a dry sweep marks nothing.
        dir.remove("refs.bib");
        let dry_scan = s
            .finish_watched_scan(folder_id.clone(), None, None, None, true)
            .await;
        assert!(dry_scan.ok && dry_scan.dry_run);
        assert_eq!(dry_scan.marked_missing, 1);
        assert_eq!(
            string_field(&file_row(&store, &real.files[1].id), "state").as_deref(),
            Some(FILE_STATE_PRESENT)
        );
    }

    // --- D7: the bounds --------------------------------------------------

    /// The write gate. Input is sorted and chunked at the store-mirror's ≤500,
    /// so a first watch of a large tree is ordered and bounded rather than one
    /// unbounded transaction.
    #[tokio::test]
    async fn discovery_chunks_at_the_write_gate_bound() {
        let (_store, s, dir, folder_id) = fixture("batches").await;
        // Declared hashes, so nothing here touches the disk: this test is about
        // the gate, not about I/O.
        let files: Vec<DiscoveredFileInput> = (0..1_200)
            .map(|i| declared(&dir.join(&format!("p{i:05}.bib")), &format!("{i:064x}")))
            .collect();

        let r = s.import_discovered(folder_id.clone(), files, false).await;
        assert!(r.ok, "{}", r.message);
        assert_eq!(r.created, 1_200);
        assert_eq!(
            r.batches,
            (1_200_f64 / MAX_DISCOVERY_BATCH as f64).ceil() as u32,
            "1200 files at {MAX_DISCOVERY_BATCH}/batch is three batches"
        );
        // Ordered: the report is path-sorted, so a resumed run and a fresh one
        // agree on where they are.
        let paths: Vec<&str> = r.files.iter().map(|f| f.path.as_str()).collect();
        let mut sorted = paths.clone();
        sorted.sort_unstable();
        assert_eq!(paths, sorted);
    }

    #[tokio::test]
    async fn a_call_over_the_per_call_bound_is_rejected_with_instructions() {
        let (_store, s, dir, folder_id) = fixture("over-bound").await;
        let files: Vec<DiscoveredFileInput> = (0..=MAX_DISCOVERED_FILES_PER_CALL)
            .map(|i| declared(&dir.join(&format!("p{i:05}.bib")), &format!("{i:064x}")))
            .collect();

        let r = s.import_discovered(folder_id, files, false).await;
        assert!(!r.ok, "a truncated ingest must not read as a complete one");
        assert!(
            r.message
                .contains(&MAX_DISCOVERED_FILES_PER_CALL.to_string()),
            "the bound must be named so the caller can page: {}",
            r.message
        );
    }

    #[tokio::test]
    async fn a_repeated_path_inside_one_burst_is_recorded_once() {
        let (_store, s, dir, folder_id) = fixture("dedup").await;
        let bib = dir.join("refs.bib");
        let r = s
            .import_discovered(
                folder_id,
                vec![by_path(&bib), by_path(&bib), by_path(&bib)],
                false,
            )
            .await;
        assert_eq!(
            r.created, 1,
            "a watcher reporting a path three times in a burst"
        );
        assert_eq!(r.files.len(), 1);
    }

    // --- provenance ------------------------------------------------------

    /// The W2 seam, both directions: which rows a file produced, and which of
    /// them a re-import orphaned.
    #[tokio::test]
    async fn produced_rows_are_attributed_and_a_re_import_reports_the_orphans() {
        let (store, s, dir, folder_id) = fixture("produced").await;
        let bib = dir.join("refs.bib");
        let first = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;
        let file_id = first.files[0].id.clone();

        // The rows imbib's importer would have created from the three entries.
        let entry = |title: &str| {
            crate::test_support::make_item_named(&store, "imbib/bibliography-entry", title)
        };
        let a = entry("Entry A");
        let b = entry("Entry B");
        let c = entry("Entry C");

        // W2: imbib's importer ran and produced three entries.
        let recorded = s
            .record_produced_rows(file_id.clone(), vec![a.clone(), b.clone(), c.clone()], true)
            .await;
        assert!(recorded.ok, "{}", recorded.message);
        assert_eq!(recorded.added, 3);
        assert!(recorded.removed_ids.is_empty());
        let file = recorded.file.expect("file");
        assert_eq!(file.produced_ids.len(), 3);
        assert!(
            !file.needs_reimport,
            "the fan-out is current with the content"
        );

        // The user deletes an entry from the .bib and it is re-imported.
        dir.write(
            "refs.bib",
            "@article{a2020, title={A}}\n% one entry removed\n",
        );
        let changed = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;
        assert_eq!(changed.changed, 1);
        let after_edit = s
            .list_watched_files(None, Some(file_id.clone()), None, 0, 0)
            .await;
        assert!(
            after_edit.files[0].needs_reimport,
            "the content moved on since the fan-out — this is W2's work queue"
        );
        assert_eq!(
            after_edit.files[0].produced_ids.len(),
            3,
            "a re-scan must NEVER clear the attribution — it is the only record \
             of what this file put in the store"
        );

        let reimported = s
            .record_produced_rows(file_id.clone(), vec![a.clone(), b.clone()], true)
            .await;
        assert_eq!(reimported.added, 0);
        assert_eq!(
            reimported.removed_ids,
            vec![c],
            "the entry the source no longer contains — a DELETION, made visible"
        );
        assert!(!reimported.file.unwrap().needs_reimport);

        // Union mode appends without orphaning.
        let d = entry("Entry D");
        let unioned = s
            .record_produced_rows(file_id.clone(), vec![d.clone()], false)
            .await;
        assert_eq!(unioned.added, 1);
        assert!(unioned.removed_ids.is_empty());
        assert_eq!(unioned.file.unwrap().produced_ids, vec![a, b, d]);

        // And an id that names nothing is refused with a sentence, not a
        // foreign-key error from three layers down.
        let dangling = s
            .record_produced_rows(file_id, vec![Uuid::new_v4().to_string()], true)
            .await;
        assert!(!dangling.ok);
        assert!(
            dangling.message.contains("no row in the store"),
            "{}",
            dangling.message
        );
    }

    #[tokio::test]
    async fn produced_ids_are_lowercased_at_the_boundary() {
        let (store, s, dir, folder_id) = fixture("case").await;
        let first = s
            .import_discovered(folder_id, vec![by_path(&dir.join("refs.bib"))], false)
            .await;
        let id = crate::test_support::make_item_named(&store, "imbib/bibliography-entry", "A");
        let r = s
            .record_produced_rows(first.files[0].id.clone(), vec![id.to_uppercase()], true)
            .await;
        assert!(r.ok, "{}", r.message);
        assert_eq!(
            r.file.unwrap().produced_ids,
            vec![id],
            "Swift's UUID().uuidString is uppercase and the store's canonical \
             form is not — normalise at the boundary or the same row gets two \
             spellings (apps/imbib/CLAUDE.md)"
        );
    }

    #[tokio::test]
    async fn files_of_a_folder_are_listable_filtered_and_paged() {
        let (_store, s, dir, folder_id) = fixture("listing").await;
        for i in 0..5 {
            dir.write(&format!("e{i}.bib"), &format!("@article{{k{i}}}\n"));
        }
        let inputs: Vec<DiscoveredFileInput> = (0..5)
            .map(|i| by_path(&dir.join(&format!("e{i}.bib"))))
            .collect();
        s.import_discovered(folder_id.clone(), inputs, false).await;

        let all = s
            .list_watched_files(Some(folder_id.clone()), None, None, 0, 0)
            .await;
        assert_eq!(all.total, 5);

        let page = s
            .list_watched_files(Some(folder_id.clone()), None, None, 2, 2)
            .await;
        assert_eq!(page.files.len(), 2);
        assert_eq!(page.total, 5, "total is the UNPAGED count");
        assert_eq!(
            page.files[0].path, all.files[2].path,
            "offset applies to a stable order"
        );

        dir.remove("e0.bib");
        dir.remove("e1.bib");
        s.finish_watched_scan(folder_id.clone(), None, None, None, false)
            .await;
        assert_eq!(
            s.list_watched_files(Some(folder_id.clone()), None, Some("missing".into()), 0, 0)
                .await
                .total,
            2
        );
        assert_eq!(
            s.list_watched_files(Some(folder_id.clone()), None, Some("present".into()), 0, 0)
                .await
                .total,
            3
        );

        let bad = s
            .list_watched_files(Some(folder_id.clone()), None, Some("gone-ish".into()), 0, 0)
            .await;
        assert!(
            !bad.ok,
            "an invented state is a caller error, not an empty list"
        );

        let neither = s.list_watched_files(None, None, None, 0, 0).await;
        assert!(!neither.ok, "{}", neither.message);
    }

    #[tokio::test]
    async fn two_folders_over_one_directory_keep_separate_provenance() {
        let store = test_store();
        let s = DefaultDocsImportService::with_store(store.clone());
        let dir = ScratchDir::new("two-folders");
        let shared = dir.write("notes.md", "# Notes\n");
        let shared = shared.to_string_lossy().to_string();

        let pubs = s
            .add_watched_folder(dir.path(), "publication".into(), None, None, true)
            .await
            .folder
            .unwrap()
            .id;
        let manuscripts = s
            .add_watched_folder(dir.path(), "manuscript".into(), None, None, true)
            .await
            .folder
            .unwrap()
            .id;

        let a = s
            .import_discovered(pubs.clone(), vec![by_path(&shared)], false)
            .await;
        let b = s
            .import_discovered(manuscripts.clone(), vec![by_path(&shared)], false)
            .await;
        assert_ne!(
            a.files[0].id, b.files[0].id,
            "one file discovered by two folders is two index entries — deleting \
             one folder must not orphan the other's record of it"
        );
        assert_eq!(a.files[0].content_hash, b.files[0].content_hash);
        assert_eq!(
            s.list_watched_files(Some(pubs), None, None, 0, 0)
                .await
                .total,
            1
        );
        assert_eq!(
            s.list_watched_files(Some(manuscripts), None, None, 0, 0)
                .await
                .total,
            1
        );
    }

    /// D4 is one-way. Un-watching a folder removes an index, not a library —
    /// not the user's files, and not the rows those files produced.
    #[tokio::test]
    async fn removing_a_folder_touches_neither_the_disk_nor_the_produced_rows() {
        let (store, s, dir, folder_id) = fixture("remove").await;
        let bib = dir.join("refs.bib");
        let first = s
            .import_discovered(folder_id.clone(), vec![by_path(&bib)], false)
            .await;
        let produced = crate::test_support::make_item_named(
            &store,
            "imbib/bibliography-entry",
            "A paper from the watched .bib",
        );
        s.record_produced_rows(first.files[0].id.clone(), vec![produced.clone()], true)
            .await;

        // Default: the index entries stay, so the provenance is still readable.
        let kept = s.remove_watched_folder(folder_id.clone(), false).await;
        assert!(kept.ok && kept.removed);
        assert_eq!(kept.file_rows_deleted, 0);
        assert!(
            std::path::Path::new(&bib).exists(),
            "the user's file is the user's"
        );
        assert!(
            store
                .get(Uuid::parse_str(&produced).unwrap())
                .unwrap()
                .is_some(),
            "a publication imported from a watched .bib is a publication"
        );
        assert!(store
            .get(Uuid::parse_str(&first.files[0].id).unwrap())
            .unwrap()
            .is_some());

        // Removing an id that is not there is a report, not an error.
        let twice = s.remove_watched_folder(folder_id, false).await;
        assert!(twice.ok && !twice.removed);
    }

    #[tokio::test]
    async fn removing_a_folder_can_clear_its_index_entries() {
        let (store, s, dir, folder_id) = fixture("remove-index").await;
        let first = s
            .import_discovered(
                folder_id.clone(),
                vec![
                    by_path(&dir.join("refs.bib")),
                    by_path(&dir.join("more.ris")),
                ],
                false,
            )
            .await;
        let removed = s.remove_watched_folder(folder_id, true).await;
        assert_eq!(removed.file_rows_deleted, 2);
        for f in &first.files {
            assert!(store
                .get(Uuid::parse_str(&f.id).unwrap())
                .unwrap()
                .is_none());
        }
        assert!(
            std::path::Path::new(&dir.join("refs.bib")).exists(),
            "clearing the index must not clear the user's files"
        );
    }

    // --- guards ----------------------------------------------------------

    #[tokio::test]
    async fn discovery_against_an_unknown_or_wrong_kind_id_fails_loudly() {
        let (store, s, _dir, _folder_id) = fixture("guards").await;

        let unknown = s
            .import_discovered(Uuid::new_v4().to_string(), vec![], false)
            .await;
        assert!(!unknown.ok);
        assert!(
            unknown.message.contains("add_watched_folder"),
            "{}",
            unknown.message
        );

        let not_a_uuid = s.import_discovered("hello".into(), vec![], false).await;
        assert!(!not_a_uuid.ok);

        // An id held by something else must not be silently adopted.
        let manuscript = crate::test_support::make_item_named(&store, "manuscript", "Not a folder");
        let wrong = s.import_discovered(manuscript, vec![], false).await;
        assert!(!wrong.ok);
        assert!(
            wrong.message.contains("not a watched folder"),
            "{}",
            wrong.message
        );
    }

    #[tokio::test]
    async fn an_unreadable_path_is_reported_not_dropped() {
        let (_store, s, dir, folder_id) = fixture("unreadable").await;
        let r = s
            .import_discovered(
                folder_id,
                vec![by_path(&dir.join("never-existed.bib")), by_path("")],
                false,
            )
            .await;
        assert!(r.ok, "one bad path does not fail the batch");
        assert_eq!(r.created, 0);
        assert_eq!(r.skipped.len(), 2);
        assert!(r.skipped.iter().any(|s| s.reason.contains("unreadable")));
        assert!(r.skipped.iter().any(|s| s.reason.contains("empty path")));
    }

    #[tokio::test]
    async fn a_directory_offered_as_a_file_is_refused() {
        let (_store, s, dir, folder_id) = fixture("dir-as-file").await;
        dir.write("nested/inner.bib", "@article{n}\n");
        let r = s
            .import_discovered(folder_id, vec![by_path(&dir.join("nested"))], false)
            .await;
        assert_eq!(r.created, 0);
        assert!(r.skipped[0].reason.contains("not a regular file"));
    }

    #[tokio::test]
    async fn the_folder_schema_is_the_ref_the_manifest_declares() {
        let (store, s, dir, folder_id) = fixture("schema-ref").await;
        s.import_discovered(
            folder_id.clone(),
            vec![by_path(&dir.join("refs.bib"))],
            false,
        )
        .await;
        let folder = store
            .get(Uuid::parse_str(&folder_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(folder.schema, WATCHED_FOLDER_SCHEMA);
        assert_eq!(
            store
                .query(&ItemQuery {
                    schema: Some(WATCHED_FILE_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap()
                .len(),
            1,
            "the file rows are queryable by the ref schema-refs.json declares"
        );
    }
}
