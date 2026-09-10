//! `imprint-project-service` — a manuscript as a project, headless
//! (ADR-0030 D12). Store-direct like the collab and e-ink services: every
//! verb works with the app closed, from the CLI, MCP and impel alike.
//!
//! The rows are `impress_core::manuscript_project`'s; the questions
//! (scan, graph, staleness) are `imprint_core::project`'s. This module is
//! the bridge: it loads a [`ProjectSnapshot`] from the store, resolves blob
//! bytes from the workspace CAS, and hands the engine a [`ProjectTree`].
//!
//! Writes refuse watched-folder manuscripts (`external_source`, ADR-0023
//! D4): the file on disk is the truth there, and a project row written
//! behind its back would be exactly the drift D4 forbids.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::blobs::BlobStore;
use impress_core::item::ItemId;
use impress_core::manuscript_project::{
    self as mp, Author, ManuscriptBuildRow, ManuscriptFileRow, ProjectSnapshot, PutFile,
};
use impress_core::schemas::{
    BUILD_RETENTION, BUILD_STATUS_FAILED, BUILD_STATUS_OK, BUILD_STATUS_RUNNING,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use imprint_core::project::{
    BibSource, BuildGraph, BuildSpec, ExportLayout, FileBytes, FileKind, FileRole, Materialization,
    ProjectFile, ProjectTree, ProjectedBibliography, Target,
};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectFileRecord {
    pub path: String,
    /// chapter | bibliography | figure | figure-source | data | style | aux | supplement | output
    pub role: String,
    /// text | binary
    pub kind: String,
    pub format: Option<String>,
    pub content_hash: String,
    pub size: i64,
    pub mime_type: Option<String>,
    /// `true` when the bytes are in the workspace CAS rather than inline.
    pub in_blob_store: bool,
    pub derived_from: Option<String>,
    pub derived_from_hash: Option<String>,
    pub build_json: Option<String>,
    pub bib_source_json: Option<String>,
    pub external_path: Option<String>,
    pub modified_ms: Option<i64>,
}

impl From<&ManuscriptFileRow> for ProjectFileRecord {
    fn from(r: &ManuscriptFileRow) -> Self {
        Self {
            path: r.path.clone(),
            role: r.role.clone(),
            kind: r.kind.clone(),
            format: r.format.clone(),
            content_hash: r.content_hash.clone(),
            size: r.size,
            mime_type: r.mime_type.clone(),
            in_blob_store: r.blob_ref.is_some(),
            derived_from: r.derived_from.clone(),
            derived_from_hash: r.derived_from_hash.clone(),
            build_json: r.build_json.clone(),
            bib_source_json: r.bib_source_json.clone(),
            external_path: r.external_path.clone(),
            modified_ms: r.modified_ms,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectTargetRecord {
    pub id: String,
    pub name: String,
    pub entry: String,
    pub engine: String,
    pub output_kind: String,
    pub args: Vec<String>,
}

impl From<&Target> for ProjectTargetRecord {
    fn from(t: &Target) -> Self {
        Self {
            id: t.id.clone(),
            name: t.name.clone(),
            entry: t.entry.clone(),
            engine: t.engine.as_str().into(),
            output_kind: match t.output_kind {
                imprint_core::project::OutputKind::Pdf => "pdf".into(),
                imprint_core::project::OutputKind::Svg => "svg".into(),
                imprint_core::project::OutputKind::Png => "png".into(),
            },
            args: t.args.clone(),
        }
    }
}

/// The project in one read.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectTreeRecord {
    pub ok: bool,
    pub manuscript_id: String,
    pub title: String,
    /// typst | latex | markdown | plaintext
    pub format: String,
    /// The entry file; its text is the manuscript body.
    pub entry_path: String,
    pub entry_hash: String,
    /// 0 for a one-file manuscript, 1 once it grew a file row or a target.
    pub project_version: i64,
    pub files: Vec<ProjectFileRecord>,
    pub targets: Vec<ProjectTargetRecord>,
    pub working_copy_path: Option<String>,
    pub message: String,
}

/// One file with its text (binary files come back as a temp file path).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectFileContentRecord {
    pub ok: bool,
    pub file: Option<ProjectFileRecord>,
    /// The text of a text file (the manuscript body for the entry).
    pub text: Option<String>,
    /// For a binary file: where its bytes were written for the caller.
    pub temp_path: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectFileResult {
    pub ok: bool,
    pub file: Option<ProjectFileRecord>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectMutationResult {
    pub ok: bool,
    pub affected_count: u32,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectEdgeRecord {
    pub from: String,
    pub to: String,
    /// include | import | image | bibliography | data | style | class
    pub kind: String,
    pub line: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectUnresolvedRecord {
    pub from: String,
    pub reference: String,
    pub kind: String,
    pub line: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectStepRecord {
    pub source: String,
    pub runner: String,
    pub outputs: Vec<String>,
    pub inputs: Vec<String>,
    pub input_hash: String,
    pub stale: bool,
    pub stale_outputs: Vec<String>,
    pub missing_outputs: Vec<String>,
    pub missing_inputs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectDiagnosticRecord {
    /// error | warning | info
    pub severity: String,
    pub code: String,
    pub message: String,
    pub file: Option<String>,
    pub line: Option<u32>,
}

/// The derived build graph of one target (ADR-0030 D4).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectGraphRecord {
    pub ok: bool,
    pub manuscript_id: String,
    pub target_id: String,
    pub entry: String,
    pub edges: Vec<ProjectEdgeRecord>,
    pub unresolved: Vec<ProjectUnresolvedRecord>,
    /// Every cite key any text file uses — what the `cited` bibliography projects.
    pub cite_keys: Vec<String>,
    /// Figure steps in run order.
    pub steps: Vec<ProjectStepRecord>,
    /// Files the entry reaches, transitively.
    pub reachable: Vec<String>,
    /// Text and figure files nothing reaches.
    pub unreferenced: Vec<String>,
    /// The bibliography files the target reaches, in first-reference order.
    pub bibliographies: Vec<String>,
    pub diagnostics: Vec<ProjectDiagnosticRecord>,
    pub has_errors: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectSectionRecord {
    pub path: String,
    pub id: String,
    pub title: String,
    pub level: u32,
    pub order_index: u32,
    pub section_type: Option<String>,
    pub word_count: u32,
    /// UTF-16 offsets within `path` (`NSRange` semantics).
    pub start_utf16: u32,
    pub end_utf16: u32,
    pub body_start_utf16: u32,
}

/// The outline of a whole tree, in reading order (ADR-0030 P2).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectOutlineRecord {
    pub ok: bool,
    pub manuscript_id: String,
    pub target_id: String,
    /// The files in the order a reader meets them (entry first).
    pub reading_order: Vec<String>,
    pub sections: Vec<ProjectSectionRecord>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectCitationRecord {
    pub path: String,
    pub key: String,
    pub byte_offset: u32,
    pub byte_len: u32,
    /// The command that cited it (`cite`, `citep`, `textcite`, `typstat`, …).
    pub command: String,
}

/// Every citation in a target's reachable files, reading order first.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectCitationsRecord {
    pub ok: bool,
    pub manuscript_id: String,
    pub target_id: String,
    pub usages: Vec<ProjectCitationRecord>,
    /// Distinct keys, sorted.
    pub keys: Vec<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectBibliographyRecord {
    pub path: String,
    /// Keys the projection asked for; empty for a literal `.bib`.
    pub requested: Vec<String>,
    pub missing: Vec<String>,
    pub synthesized: Vec<String>,
}

/// A compile of one target (not a recorded build — that is `project-build`).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectCompileRecord {
    pub ok: bool,
    pub manuscript_id: String,
    pub target_id: String,
    pub engine: String,
    /// Where the PDF was written (never bytes over MCP).
    pub pdf_path: Option<String>,
    /// One SVG file per page for an `svg` target.
    pub svg_paths: Vec<String>,
    pub page_count: u32,
    pub compile_ms: i64,
    pub diagnostics: Vec<ProjectDiagnosticRecord>,
    pub bibliographies: Vec<ProjectBibliographyRecord>,
    pub message: String,
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// A manuscript as a project: its files, its targets, its derived build
/// graph (ADR-0030). Every `manuscript_id` is a manuscript UUID string;
/// every `path` is project-relative (POSIX, no `..`). The entry file's text
/// is the manuscript body — write it through the collab verbs
/// (`manuscript-collab-service_commit-manuscript-body`), not here.
/// What an import did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectImportRecord {
    pub ok: bool,
    pub manuscript_id: String,
    /// True when the import made the manuscript (no `manuscript_id` given).
    pub created: bool,
    pub entry_path: String,
    /// Why that file is the entry.
    pub entry_reason: String,
    /// typst | latex | markdown | plaintext
    pub format: String,
    /// Every file row written (the entry is the manuscript body, not a row).
    pub files: Vec<ProjectFileRecord>,
    /// `path: why` for what the walk left out.
    pub skipped: Vec<String>,
    pub message: String,
}

/// What a materialisation or an export wrote.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectExportRecord {
    pub ok: bool,
    pub directory: String,
    /// The entry file, absolute.
    pub entry: String,
    pub written: Vec<String>,
    pub unchanged: Vec<String>,
    pub removed: Vec<String>,
    /// Files whose bytes this workspace does not hold.
    pub missing: Vec<String>,
    pub message: String,
}

/// One output of a recorded build.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectBuildOutputRecord {
    /// pdf | svg | synctex | log
    pub kind: String,
    pub name: String,
    /// Where the build wrote it (may be gone; the blob is the durable copy).
    pub path: String,
    /// `blob:sha256:…` in the workspace CAS, for pdf and svg outputs.
    pub blob_ref: Option<String>,
    pub size: u64,
}

/// What happened to one figure step of a build.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectStepReportRecord {
    pub source: String,
    pub runner: String,
    /// ran | fresh | skipped | failed
    pub status: String,
    pub message: String,
    pub duration_ms: u64,
    pub outputs: Vec<String>,
    pub command: Option<String>,
}

/// A recorded build (`manuscript-build@1.0.0`).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectBuildRecord {
    pub id: String,
    pub manuscript_id: String,
    pub target_id: String,
    pub engine: String,
    /// running | ok | failed | cancelled
    pub status: String,
    pub input_stamp: String,
    pub started_ms: i64,
    pub finished_ms: Option<i64>,
    pub duration_ms: Option<i64>,
    pub outputs: Vec<ProjectBuildOutputRecord>,
    pub diagnostics: Vec<ProjectDiagnosticRecord>,
    pub steps: Vec<ProjectStepReportRecord>,
    pub allow_shell: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectBuildResult {
    pub ok: bool,
    pub build: Option<ProjectBuildRecord>,
    /// What ran, in order, with what it printed.
    pub log: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectBuildsRecord {
    pub ok: bool,
    pub manuscript_id: String,
    pub builds: Vec<ProjectBuildRecord>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectBuildOutputResult {
    pub ok: bool,
    pub build_id: String,
    pub kind: String,
    /// A readable path: the build's own file while it is still there, else
    /// a copy from the workspace CAS.
    pub path: Option<String>,
    pub blob_ref: Option<String>,
    pub size: u64,
    pub message: String,
}

/// A revision of the whole tree.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ProjectSnapshotRecord {
    pub ok: bool,
    pub revision_id: String,
    pub revision_tag: String,
    /// `blob:sha256:…` of the `.tar.zst` in the workspace CAS.
    pub archive_ref: String,
    pub archive_bytes: u64,
    pub file_count: u32,
    /// The input stamp the archive holds.
    pub content_hash: String,
    pub message: String,
}

#[impress_service]
pub trait ImprintProjectService: Send + Sync + 'static {
    /// The whole project in one read: entry, every file row, targets.
    #[impress_method]
    async fn project_tree(&self, manuscript_id: String) -> ProjectTreeRecord;

    /// One file with its text; a binary file is written to a temp path for
    /// the caller. The entry path returns the manuscript body.
    #[impress_method]
    async fn project_file(&self, manuscript_id: String, path: String) -> ProjectFileContentRecord;

    /// Create or replace a file. `content` is the text; `file_path` reads
    /// the bytes from a local file instead (binaries, or large text).
    /// `role` absent = classified from the extension. Refused for the entry
    /// path and for watched-folder manuscripts.
    #[impress_method]
    async fn project_put_file(
        &self,
        manuscript_id: String,
        path: String,
        content: Option<String>,
        file_path: Option<String>,
        role: Option<String>,
        author: Option<String>,
    ) -> ProjectFileResult;

    /// Delete a file row (its blob stays in the CAS until hygiene).
    #[impress_method]
    async fn project_delete_file(
        &self,
        manuscript_id: String,
        path: String,
    ) -> ProjectMutationResult;

    /// Move / rename a file. Outputs that named the old path as their source
    /// follow it. Refuses to overwrite an existing path.
    #[impress_method]
    async fn project_move_file(
        &self,
        manuscript_id: String,
        from: String,
        to: String,
        author: Option<String>,
    ) -> ProjectFileResult;

    /// Declare which path is the entry (the manuscript body's file name).
    #[impress_method]
    async fn project_set_entry(
        &self,
        manuscript_id: String,
        path: String,
        author: Option<String>,
    ) -> ProjectMutationResult;

    /// Declare the targets as a JSON array
    /// `[{id, name?, entry?, engine?, output_kind?, args?}]`; absent or empty
    /// restores the implicit single target. Engines: typst | tectonic |
    /// pdflatex | xelatex | lualatex | latexmk | markdown | none.
    #[impress_method]
    async fn project_set_targets(
        &self,
        manuscript_id: String,
        targets_json: Option<String>,
        author: Option<String>,
    ) -> ProjectTreeRecord;

    /// Make a `.bib` row a projection: `{"kind":"cited"}` (every key cited in
    /// the tree, from imbib), `{"kind":"collection","library_id":…,
    /// "collection_id":…}`, `{"kind":"library","library_id":…}`,
    /// `{"kind":"keys","keys":[…]}`. Absent = the row's own BibTeX.
    #[impress_method]
    async fn project_set_bibliography(
        &self,
        manuscript_id: String,
        path: String,
        bib_source_json: Option<String>,
    ) -> ProjectFileResult;

    /// Declare how a `figure-source` makes its outputs:
    /// `{"runner":"impress-plot"|"implore"|"veusz"|"shell","outputs":[…],
    /// "inputs":[…],"args":{…}}`. Absent clears the declaration.
    #[impress_method]
    async fn project_set_figure_build(
        &self,
        manuscript_id: String,
        path: String,
        build_json: Option<String>,
    ) -> ProjectFileResult;

    /// The derived build graph of a target (the first declared one when
    /// `target_id` is absent): edges, unresolved references, cite keys,
    /// figure steps with staleness, reachability, diagnostics.
    #[impress_method]
    async fn project_graph(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectGraphRecord;

    /// The outline of the whole tree in reading order — every included
    /// file's sections spliced in where it is included — with the same ids
    /// the one-file outline uses.
    #[impress_method]
    async fn project_outline(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectOutlineRecord;

    /// Every citation in the target's reachable files, with the file each
    /// sits in, plus the distinct keys.
    #[impress_method]
    async fn project_citations(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectCitationsRecord;

    /// Compile one target from the store, no directory: Typst over the tree
    /// (projected bibliographies resolved from imbib), the PDF or per-page
    /// SVGs written to a cache path. `entry_override` replaces the entry's
    /// text (a live buffer). Not a recorded build — see `project-build`.
    /// LaTeX and Markdown targets report their engine and refuse until P4.
    #[impress_method]
    async fn project_compile(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        entry_override: Option<String>,
    ) -> ProjectCompileRecord;

    /// A directory becomes a project: build residue skipped, roles from the
    /// extension and then from use, the entry guessed (`entry` overrides).
    /// Into an existing manuscript when `manuscript_id` is given — the
    /// directory's entry becomes its body through the document, so history
    /// keeps both — else a new manuscript titled `title` (default: the
    /// directory's name). Additive: rows the directory no longer has stay.
    #[impress_method]
    async fn project_import_directory(
        &self,
        directory: String,
        manuscript_id: Option<String>,
        entry: Option<String>,
        title: Option<String>,
        author: Option<String>,
    ) -> ProjectImportRecord;

    /// Write the tree to a directory the caller chose, once. `layout`:
    /// `bundle` (files plus `manifest.json`, the lossless form; default) or
    /// `standalone` (files only, for collaborators without imprint).
    /// Projected bibliographies are written as the `.bib` they resolved to.
    #[impress_method]
    async fn project_export(
        &self,
        manuscript_id: String,
        directory: String,
        target_id: Option<String>,
        layout: Option<String>,
    ) -> ProjectExportRecord;

    /// Materialise the tree for a toolchain that needs a directory:
    /// hash-compared and atomic, pruning only what an earlier run wrote.
    /// Default directory
    /// `<cache>/impress/imprint/project-build/<manuscript>/<target>/`.
    #[impress_method]
    async fn project_materialize(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        directory: Option<String>,
    ) -> ProjectExportRecord;

    /// Snapshot the whole tree as a revision: a deterministic `.tar.zst`
    /// with the manifest, stored in the workspace CAS; `content_hash` is the
    /// input stamp; lineage shared with one-file revisions.
    #[impress_method]
    async fn project_snapshot(
        &self,
        manuscript_id: String,
        revision_tag: String,
        reason: Option<String>,
        target_id: Option<String>,
        author: Option<String>,
    ) -> ProjectSnapshotRecord;

    /// Build a target and record it: stale figure steps first (`shell`
    /// steps only with `allow_shell`), then the document engine — Typst
    /// from memory, Markdown through Typst, LaTeX through a materialised
    /// directory (`tectonic` embedded, or `pdflatex`/`xelatex`/`lualatex`/
    /// `latexmk` from the system). A `manuscript-build@1.0.0` row holds the
    /// outcome, the PDF goes to the workspace CAS, and what steps produced
    /// becomes `output` rows derived from their source. `entry_override`
    /// is the live buffer.
    #[impress_method]
    async fn project_build(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        allow_shell: Option<bool>,
        entry_override: Option<String>,
        author: Option<String>,
    ) -> ProjectBuildResult;

    /// Recorded builds, newest first (`limit` default 20).
    #[impress_method]
    async fn project_builds(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        limit: Option<u32>,
    ) -> ProjectBuildsRecord;

    /// One output of a build — the newest successful build of the target
    /// when `build_id` is absent — at a readable path (`kind` default
    /// `pdf`).
    #[impress_method]
    async fn project_build_output(
        &self,
        manuscript_id: String,
        build_id: Option<String>,
        target_id: Option<String>,
        kind: Option<String>,
    ) -> ProjectBuildOutputResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed [`ImprintProjectService`]. `new()` uses the suite's shared
/// store (opened lazily, the same handle the collab verbs use);
/// `with_store` takes an explicit one plus the blob root, as tests do;
/// `with_workspace` opens `<dir>/impress.sqlite` + `<dir>/content`.
#[derive(Clone, Default)]
pub struct DefaultImprintProjectService {
    store: Option<Arc<SqliteItemStore>>,
    blob_root: Option<PathBuf>,
}

impl DefaultImprintProjectService {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_store(store: Arc<SqliteItemStore>, blob_root: impl Into<PathBuf>) -> Self {
        Self {
            store: Some(store),
            blob_root: Some(blob_root.into()),
        }
    }

    /// A private workspace directory (tests, the selftest).
    pub fn with_workspace(dir: &Path) -> Result<Self, StoreError> {
        std::fs::create_dir_all(dir).map_err(|e| StoreError::Storage(e.to_string()))?;
        let store = SqliteItemStore::open(&dir.join("impress.sqlite"))?;
        Ok(Self::with_store(
            Arc::new(store),
            BlobStore::for_workspace(dir).root().to_path_buf(),
        ))
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store
            .clone()
            .unwrap_or_else(impress_store_service::store::store_instance)
    }

    fn blobs(&self) -> BlobStore {
        match &self.blob_root {
            Some(root) => BlobStore::new(root.clone()),
            None => {
                let db = impress_store_service::store::store_path();
                let workspace = db.parent().map(Path::to_path_buf).unwrap_or_default();
                BlobStore::for_workspace(&workspace)
            }
        }
    }

    fn parse(id: &str) -> Result<ItemId, StoreError> {
        id.trim()
            .parse::<ItemId>()
            .map_err(|_| StoreError::Validation(format!("invalid manuscript UUID: {id}")))
    }

    fn author(author: Option<String>) -> Author {
        match author
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty())
        {
            Some(name) => Author::agent(name),
            None => Author::agent("agent:imprint-project-service"),
        }
    }

    /// Watched-folder manuscripts are indexes of files edited elsewhere
    /// (ADR-0023 D4): nothing writes project rows behind the file's back.
    fn refuse_external(store: &SqliteItemStore, id: ItemId) -> Result<(), StoreError> {
        let item = store.get(id)?.ok_or(StoreError::NotFound(id))?;
        if item.payload.contains_key("external_source") {
            return Err(StoreError::Validation(format!(
                "manuscript {id} is a watched-folder file (external_source); edit the files on \
                 disk, not the store copy"
            )));
        }
        Ok(())
    }
}

/// Turn a store snapshot into the engine's tree, resolving blob bytes.
pub fn tree_from_snapshot(snapshot: &ProjectSnapshot, blobs: &BlobStore) -> ProjectTree {
    let mut tree = tree_from_rows(snapshot, blobs);
    // The one-file citation convention, carried into the tree (P2).
    if let Some(implicit) = imprint_core::project::implicit_bibliography(&tree) {
        tree.upsert_file(implicit);
    }
    tree
}

fn tree_from_rows(snapshot: &ProjectSnapshot, blobs: &BlobStore) -> ProjectTree {
    let entry = ProjectFile {
        format: imprint_core::project::model::extension_of(&snapshot.entry_path)
            .and_then(|e| imprint_core::project::model::format_for_extension(&e).map(String::from))
            .or_else(|| Some(snapshot.format.clone())),
        ..ProjectFile::text(
            snapshot.entry_path.clone(),
            FileRole::Main,
            snapshot.entry_text.clone(),
        )
    };
    let files: Vec<ProjectFile> = snapshot
        .files
        .iter()
        .map(|row| file_from_row(row, blobs))
        .collect();
    let targets = match &snapshot.targets_json {
        Some(json) => {
            Target::parse_list(json, &snapshot.format, &snapshot.entry_path).unwrap_or_default()
        }
        None => Vec::new(),
    };
    ProjectTree::new(
        snapshot.manuscript_id.to_string(),
        snapshot.title.clone(),
        snapshot.format.clone(),
        entry,
        files,
        targets,
    )
}

fn file_from_row(row: &ManuscriptFileRow, blobs: &BlobStore) -> ProjectFile {
    let bytes = match (&row.content, &row.blob_ref) {
        (Some(text), _) => FileBytes::Text(text.clone()),
        (None, Some(r)) => match blobs.get_ref(r) {
            Ok(Some(b)) if row.is_text() => match String::from_utf8(b) {
                Ok(t) => FileBytes::Text(t),
                Err(e) => FileBytes::Bytes(e.into_bytes()),
            },
            Ok(Some(b)) => FileBytes::Bytes(b),
            _ => FileBytes::Missing,
        },
        (None, None) => FileBytes::Text(String::new()),
    };
    ProjectFile {
        path: row.path.clone(),
        role: FileRole::parse(&row.role).unwrap_or(FileRole::Aux),
        kind: if row.is_text() {
            FileKind::Text
        } else {
            FileKind::Binary
        },
        format: row.format.clone(),
        bytes,
        content_hash: row.content_hash.clone(),
        size: row.size.max(0) as u64,
        derived_from: row.derived_from.clone(),
        derived_from_hash: row.derived_from_hash.clone(),
        build: row
            .build_json
            .as_deref()
            .and_then(|j| BuildSpec::parse(j).ok()),
        bib_source: row
            .bib_source_json
            .as_deref()
            .and_then(|j| BibSource::parse(j).ok()),
    }
}

fn tree_record(snapshot: &ProjectSnapshot, tree: &ProjectTree, message: &str) -> ProjectTreeRecord {
    ProjectTreeRecord {
        ok: true,
        manuscript_id: snapshot.manuscript_id.to_string(),
        title: snapshot.title.clone(),
        format: snapshot.format.clone(),
        entry_path: snapshot.entry_path.clone(),
        entry_hash: snapshot.entry_hash.clone(),
        project_version: snapshot.project_version,
        files: snapshot.files.iter().map(ProjectFileRecord::from).collect(),
        targets: tree.targets.iter().map(ProjectTargetRecord::from).collect(),
        working_copy_path: snapshot.working_copy_path.clone(),
        message: message.into(),
    }
}

fn failed_tree(id: &str, e: impl std::fmt::Display) -> ProjectTreeRecord {
    log_err("project_tree", &e);
    ProjectTreeRecord {
        ok: false,
        manuscript_id: id.into(),
        title: String::new(),
        format: String::new(),
        entry_path: String::new(),
        entry_hash: String::new(),
        project_version: 0,
        files: vec![],
        targets: vec![],
        working_copy_path: None,
        message: e.to_string(),
    }
}

fn file_result(outcome: Result<ManuscriptFileRow, StoreError>, verb: &str) -> ProjectFileResult {
    match outcome {
        Ok(row) => ProjectFileResult {
            ok: true,
            file: Some(ProjectFileRecord::from(&row)),
            message: format!("{verb}: {}", row.path),
        },
        Err(e) => {
            log_err(verb, &e);
            ProjectFileResult {
                ok: false,
                file: None,
                message: e.to_string(),
            }
        }
    }
}

fn log_err(method: &str, e: &impl std::fmt::Display) {
    eprintln!("[imprint-project-service] {method}: {e}");
}

#[async_trait::async_trait]
impl ImprintProjectService for DefaultImprintProjectService {
    async fn project_tree(&self, manuscript_id: String) -> ProjectTreeRecord {
        let store = self.store();
        match Self::parse(&manuscript_id).and_then(|id| mp::load_project(&store, id)) {
            Ok(snapshot) => {
                let tree = tree_from_snapshot(&snapshot, &self.blobs());
                tree_record(
                    &snapshot,
                    &tree,
                    &format!(
                        "{} file(s) besides the entry, {} target(s)",
                        snapshot.files.len(),
                        tree.targets.len()
                    ),
                )
            }
            Err(e) => failed_tree(&manuscript_id, e),
        }
    }

    async fn project_file(&self, manuscript_id: String, path: String) -> ProjectFileContentRecord {
        let store = self.store();
        let blobs = self.blobs();
        let outcome = (|| -> Result<ProjectFileContentRecord, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let snapshot = mp::load_project(&store, id)?;
            let path = mp::normalize_path(&path)?;
            if path == snapshot.entry_path {
                return Ok(ProjectFileContentRecord {
                    ok: true,
                    file: None,
                    text: Some(snapshot.entry_text.clone()),
                    temp_path: None,
                    message: format!("{path}: the entry (the manuscript body)"),
                });
            }
            let row = mp::get_file(&store, id, &path)?
                .ok_or_else(|| StoreError::Validation(format!("no file at {path:?}")))?;
            let bytes = row
                .bytes(&blobs)
                .map_err(|e| StoreError::Storage(format!("blob read: {e}")))?;
            let Some(bytes) = bytes else {
                return Ok(ProjectFileContentRecord {
                    ok: false,
                    file: Some(ProjectFileRecord::from(&row)),
                    text: None,
                    temp_path: None,
                    message: format!("{path}: its bytes are not in this workspace's blob store"),
                });
            };
            if row.is_text() {
                return Ok(ProjectFileContentRecord {
                    ok: true,
                    file: Some(ProjectFileRecord::from(&row)),
                    text: Some(String::from_utf8_lossy(&bytes).into_owned()),
                    temp_path: None,
                    message: format!("{path}: {} bytes", bytes.len()),
                });
            }
            let dir = std::env::temp_dir().join("imprint-project-files");
            std::fs::create_dir_all(&dir).map_err(|e| StoreError::Storage(e.to_string()))?;
            let name = imprint_core::project::model::file_name_of(&path);
            let out = dir.join(format!(
                "{}-{}",
                &row.content_hash[..12.min(row.content_hash.len())],
                name
            ));
            std::fs::write(&out, &bytes).map_err(|e| StoreError::Storage(e.to_string()))?;
            Ok(ProjectFileContentRecord {
                ok: true,
                file: Some(ProjectFileRecord::from(&row)),
                text: None,
                temp_path: Some(out.display().to_string()),
                message: format!("{path}: {} bytes written to a temp file", bytes.len()),
            })
        })();
        outcome.unwrap_or_else(|e| {
            log_err("project_file", &e);
            ProjectFileContentRecord {
                ok: false,
                file: None,
                text: None,
                temp_path: None,
                message: e.to_string(),
            }
        })
    }

    async fn project_put_file(
        &self,
        manuscript_id: String,
        path: String,
        content: Option<String>,
        file_path: Option<String>,
        role: Option<String>,
        author: Option<String>,
    ) -> ProjectFileResult {
        let store = self.store();
        let blobs = self.blobs();
        let author = Self::author(author);
        let outcome = (|| -> Result<ManuscriptFileRow, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            Self::refuse_external(&store, id)?;
            let (bytes, kind): (Vec<u8>, Option<&str>) = match (content, file_path) {
                (Some(text), _) => (text.into_bytes(), Some("text")),
                (None, Some(p)) => (
                    std::fs::read(&p)
                        .map_err(|e| StoreError::Validation(format!("read {p}: {e}")))?,
                    None,
                ),
                (None, None) => {
                    return Err(StoreError::Validation(
                        "send `content` (text) or `file_path` (a local file to read)".into(),
                    ))
                }
            };
            let role = role.as_deref().map(str::trim).filter(|r| !r.is_empty());
            mp::put_file(
                &store,
                &blobs,
                id,
                PutFile {
                    path: &path,
                    role,
                    bytes: &bytes,
                    kind,
                    mime_type: None,
                },
                &author,
            )
        })();
        file_result(outcome, "put")
    }

    async fn project_delete_file(
        &self,
        manuscript_id: String,
        path: String,
    ) -> ProjectMutationResult {
        let store = self.store();
        let outcome = Self::parse(&manuscript_id).and_then(|id| {
            Self::refuse_external(&store, id)?;
            mp::delete_file(&store, id, &path)
        });
        match outcome {
            Ok(true) => ProjectMutationResult {
                ok: true,
                affected_count: 1,
                message: format!("deleted {path}"),
            },
            Ok(false) => ProjectMutationResult {
                ok: true,
                affected_count: 0,
                message: format!("no file at {path}"),
            },
            Err(e) => {
                log_err("project_delete_file", &e);
                ProjectMutationResult {
                    ok: false,
                    affected_count: 0,
                    message: e.to_string(),
                }
            }
        }
    }

    async fn project_move_file(
        &self,
        manuscript_id: String,
        from: String,
        to: String,
        author: Option<String>,
    ) -> ProjectFileResult {
        let store = self.store();
        let author = Self::author(author);
        let outcome = Self::parse(&manuscript_id).and_then(|id| {
            Self::refuse_external(&store, id)?;
            mp::move_file(&store, id, &from, &to, &author)
        });
        file_result(outcome, "moved")
    }

    async fn project_set_entry(
        &self,
        manuscript_id: String,
        path: String,
        author: Option<String>,
    ) -> ProjectMutationResult {
        let store = self.store();
        let author = Self::author(author);
        match Self::parse(&manuscript_id).and_then(|id| {
            Self::refuse_external(&store, id)?;
            mp::set_entry_path(&store, id, &path, &author)
        }) {
            Ok(entry) => ProjectMutationResult {
                ok: true,
                affected_count: 1,
                message: format!("entry is {entry}"),
            },
            Err(e) => {
                log_err("project_set_entry", &e);
                ProjectMutationResult {
                    ok: false,
                    affected_count: 0,
                    message: e.to_string(),
                }
            }
        }
    }

    async fn project_set_targets(
        &self,
        manuscript_id: String,
        targets_json: Option<String>,
        author: Option<String>,
    ) -> ProjectTreeRecord {
        let store = self.store();
        let author = Self::author(author);
        let outcome = Self::parse(&manuscript_id).and_then(|id| {
            Self::refuse_external(&store, id)?;
            // Validate through the engine's parser too, so an unknown engine
            // is refused here rather than at build time.
            if let Some(json) = targets_json
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                let snapshot = mp::load_project(&store, id)?;
                Target::parse_list(json, &snapshot.format, &snapshot.entry_path)
                    .map_err(StoreError::Validation)?;
            }
            mp::set_targets(&store, id, targets_json.as_deref(), &author)?;
            mp::load_project(&store, id)
        });
        match outcome {
            Ok(snapshot) => {
                let tree = tree_from_snapshot(&snapshot, &self.blobs());
                tree_record(
                    &snapshot,
                    &tree,
                    &format!("{} target(s)", tree.targets.len()),
                )
            }
            Err(e) => failed_tree(&manuscript_id, e),
        }
    }

    async fn project_set_bibliography(
        &self,
        manuscript_id: String,
        path: String,
        bib_source_json: Option<String>,
    ) -> ProjectFileResult {
        let store = self.store();
        let outcome = Self::parse(&manuscript_id).and_then(|id| {
            Self::refuse_external(&store, id)?;
            if let Some(json) = bib_source_json.as_deref() {
                BibSource::parse(json).map_err(StoreError::Validation)?;
            }
            let row = mp::get_file(&store, id, &path)?
                .ok_or_else(|| StoreError::Validation(format!("no file at {path:?}")))?;
            if row.role != "bibliography" {
                mp::set_file_field(&store, id, &path, "role", Some("bibliography"))?;
            }
            mp::set_file_field(
                &store,
                id,
                &path,
                "bib_source_json",
                bib_source_json.as_deref(),
            )
        });
        file_result(outcome, "bibliography")
    }

    async fn project_set_figure_build(
        &self,
        manuscript_id: String,
        path: String,
        build_json: Option<String>,
    ) -> ProjectFileResult {
        let store = self.store();
        let outcome = Self::parse(&manuscript_id).and_then(|id| {
            Self::refuse_external(&store, id)?;
            if let Some(json) = build_json.as_deref() {
                let spec = BuildSpec::parse(json).map_err(StoreError::Validation)?;
                for out in &spec.outputs {
                    mp::normalize_path(out)?;
                }
                for input in &spec.inputs {
                    mp::normalize_path(input)?;
                }
            }
            let row = mp::get_file(&store, id, &path)?
                .ok_or_else(|| StoreError::Validation(format!("no file at {path:?}")))?;
            if row.role != "figure-source" && build_json.is_some() {
                mp::set_file_field(&store, id, &path, "role", Some("figure-source"))?;
            }
            mp::set_file_field(&store, id, &path, "build_json", build_json.as_deref())
        });
        file_result(outcome, "figure build")
    }

    async fn project_graph(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectGraphRecord {
        let store = self.store();
        let outcome = (|| -> Result<ProjectGraphRecord, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let snapshot = mp::load_project(&store, id)?;
            let tree = tree_from_snapshot(&snapshot, &self.blobs());
            let target = match target_id
                .as_deref()
                .map(str::trim)
                .filter(|t| !t.is_empty())
            {
                Some(t) => tree
                    .target(t)
                    .cloned()
                    .ok_or_else(|| StoreError::Validation(format!("no target {t:?}")))?,
                None => tree.default_target().clone(),
            };
            let graph = BuildGraph::derive(&tree, &target);
            let errors = graph.errors().count();
            let message = if errors == 0 {
                format!(
                    "{} file(s) reachable, {} step(s), {} diagnostic(s)",
                    graph.reachable.len(),
                    graph.steps.len(),
                    graph.diagnostics.len()
                )
            } else {
                format!(
                    "{errors} error(s): {}",
                    graph
                        .errors()
                        .next()
                        .map(|d| d.message.clone())
                        .unwrap_or_default()
                )
            };
            Ok(graph_record(&manuscript_id, &graph, message))
        })();
        outcome.unwrap_or_else(|e| {
            log_err("project_graph", &e);
            ProjectGraphRecord {
                ok: false,
                manuscript_id,
                target_id: String::new(),
                entry: String::new(),
                edges: vec![],
                unresolved: vec![],
                cite_keys: vec![],
                steps: vec![],
                reachable: vec![],
                unreferenced: vec![],
                bibliographies: vec![],
                diagnostics: vec![],
                has_errors: true,
                message: e.to_string(),
            }
        })
    }

    async fn project_outline(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectOutlineRecord {
        self.outline_impl(manuscript_id, target_id).await
    }

    async fn project_citations(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectCitationsRecord {
        self.citations_impl(manuscript_id, target_id).await
    }

    async fn project_compile(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        entry_override: Option<String>,
    ) -> ProjectCompileRecord {
        self.compile_impl(manuscript_id, target_id, entry_override)
            .await
    }

    async fn project_import_directory(
        &self,
        directory: String,
        manuscript_id: Option<String>,
        entry: Option<String>,
        title: Option<String>,
        author: Option<String>,
    ) -> ProjectImportRecord {
        self.import_directory_impl(directory, manuscript_id, entry, title, author)
            .await
    }

    async fn project_export(
        &self,
        manuscript_id: String,
        directory: String,
        target_id: Option<String>,
        layout: Option<String>,
    ) -> ProjectExportRecord {
        self.export_impl(manuscript_id, directory, target_id, layout)
            .await
    }

    async fn project_materialize(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        directory: Option<String>,
    ) -> ProjectExportRecord {
        self.materialize_impl(manuscript_id, target_id, directory)
            .await
    }

    async fn project_snapshot(
        &self,
        manuscript_id: String,
        revision_tag: String,
        reason: Option<String>,
        target_id: Option<String>,
        author: Option<String>,
    ) -> ProjectSnapshotRecord {
        self.snapshot_impl(manuscript_id, revision_tag, reason, target_id, author)
            .await
    }

    async fn project_build(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        allow_shell: Option<bool>,
        entry_override: Option<String>,
        author: Option<String>,
    ) -> ProjectBuildResult {
        self.build_impl(
            manuscript_id,
            target_id,
            allow_shell,
            entry_override,
            author,
        )
        .await
    }

    async fn project_builds(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        limit: Option<u32>,
    ) -> ProjectBuildsRecord {
        self.builds_impl(manuscript_id, target_id, limit).await
    }

    async fn project_build_output(
        &self,
        manuscript_id: String,
        build_id: Option<String>,
        target_id: Option<String>,
        kind: Option<String>,
    ) -> ProjectBuildOutputResult {
        self.build_output_impl(manuscript_id, build_id, target_id, kind)
            .await
    }
}

fn resolve_target(tree: &ProjectTree, target_id: Option<&str>) -> Result<Target, StoreError> {
    match target_id.map(str::trim).filter(|t| !t.is_empty()) {
        Some(t) => tree
            .target(t)
            .cloned()
            .ok_or_else(|| StoreError::Validation(format!("no target {t:?}"))),
        None => Ok(tree.default_target().clone()),
    }
}

/// Where compile artifacts go:
/// `<cache>/impress/imprint/project-compile/<manuscript>/<target>/`.
fn compile_output_dir(manuscript_id: &str, target_id: &str) -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(std::env::temp_dir);
    base.join("impress")
        .join("imprint")
        .join("project-compile")
        .join(manuscript_id)
        .join(target_id)
}

fn diagnostic_records(diags: &[imprint_core::project::Diagnostic]) -> Vec<ProjectDiagnosticRecord> {
    diags
        .iter()
        .map(|d| ProjectDiagnosticRecord {
            severity: match d.severity {
                imprint_core::project::Severity::Error => "error".into(),
                imprint_core::project::Severity::Warning => "warning".into(),
                imprint_core::project::Severity::Info => "info".into(),
            },
            code: d.code.clone(),
            message: d.message.clone(),
            file: d.file.clone(),
            line: d.line,
        })
        .collect()
}

fn bibliography_records(
    bibs: &[imprint_core::project::ProjectedBibliography],
) -> Vec<ProjectBibliographyRecord> {
    bibs.iter()
        .map(|b| ProjectBibliographyRecord {
            path: b.path.clone(),
            requested: b.requested.clone(),
            missing: b.missing.clone(),
            synthesized: b.synthesized.clone(),
        })
        .collect()
}

#[cfg(feature = "typst-render")]
fn compile_tree_dispatch(
    tree: &ProjectTree,
    target: &Target,
    bibs: &[imprint_core::project::ProjectedBibliography],
    entry_override: Option<&str>,
) -> Result<imprint_core::project::TreeCompileOutcome, String> {
    Ok(imprint_core::project::compile_typst_tree(
        tree,
        target,
        bibs,
        entry_override,
    ))
}

#[cfg(not(feature = "typst-render"))]
fn compile_tree_dispatch(
    _tree: &ProjectTree,
    _target: &Target,
    _bibs: &[imprint_core::project::ProjectedBibliography],
    _entry_override: Option<&str>,
) -> Result<imprint_core::project::TreeCompileOutcome, String> {
    Err("Typst rendering requires imprint-service's `typst-render` feature (impress-mcp enables it)".into())
}

impl DefaultImprintProjectService {
    async fn outline_impl(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectOutlineRecord {
        let store = self.store();
        let outcome = (|| -> Result<ProjectOutlineRecord, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let snapshot = mp::load_project(&store, id)?;
            let tree = tree_from_snapshot(&snapshot, &self.blobs());
            let target = resolve_target(&tree, target_id.as_deref())?;
            let graph = BuildGraph::derive(&tree, &target);
            let order = imprint_core::project::reading_order(&tree, &graph);
            let sections = imprint_core::project::sections_for_tree(&tree, &target, &graph, id);
            Ok(ProjectOutlineRecord {
                ok: true,
                manuscript_id: manuscript_id.clone(),
                target_id: target.id.clone(),
                message: format!(
                    "{} section(s) across {} file(s)",
                    sections.len(),
                    order.len()
                ),
                reading_order: order,
                sections: sections
                    .iter()
                    .map(|s| ProjectSectionRecord {
                        path: s.path.clone(),
                        id: s.section.id.to_string(),
                        title: s.section.title.clone(),
                        level: s.section.level,
                        order_index: s.section.order_index as u32,
                        section_type: s.section.section_type.clone(),
                        word_count: s.section.word_count as u32,
                        start_utf16: s.section.start_utf16 as u32,
                        end_utf16: s.section.end_utf16 as u32,
                        body_start_utf16: s.section.body_start_utf16 as u32,
                    })
                    .collect(),
            })
        })();
        outcome.unwrap_or_else(|e| {
            log_err("project_outline", &e);
            ProjectOutlineRecord {
                ok: false,
                manuscript_id,
                target_id: String::new(),
                reading_order: vec![],
                sections: vec![],
                message: e.to_string(),
            }
        })
    }

    async fn citations_impl(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
    ) -> ProjectCitationsRecord {
        let store = self.store();
        let outcome = (|| -> Result<ProjectCitationsRecord, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let snapshot = mp::load_project(&store, id)?;
            let tree = tree_from_snapshot(&snapshot, &self.blobs());
            let target = resolve_target(&tree, target_id.as_deref())?;
            let graph = BuildGraph::derive(&tree, &target);
            let usages = imprint_core::project::citations_for_tree(&tree, &graph);
            let mut keys: Vec<String> = usages.iter().map(|u| u.usage.key.clone()).collect();
            keys.sort();
            keys.dedup();
            Ok(ProjectCitationsRecord {
                ok: true,
                manuscript_id: manuscript_id.clone(),
                target_id: target.id.clone(),
                message: format!(
                    "{} citation(s), {} distinct key(s)",
                    usages.len(),
                    keys.len()
                ),
                usages: usages
                    .iter()
                    .map(|u| ProjectCitationRecord {
                        path: u.path.clone(),
                        key: u.usage.key.clone(),
                        byte_offset: u.usage.byte_offset as u32,
                        byte_len: u.usage.byte_len as u32,
                        command: format!("{:?}", u.usage.command).to_ascii_lowercase(),
                    })
                    .collect(),
                keys,
            })
        })();
        outcome.unwrap_or_else(|e| {
            log_err("project_citations", &e);
            ProjectCitationsRecord {
                ok: false,
                manuscript_id,
                target_id: String::new(),
                usages: vec![],
                keys: vec![],
                message: e.to_string(),
            }
        })
    }

    async fn compile_impl(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        entry_override: Option<String>,
    ) -> ProjectCompileRecord {
        let store = self.store();
        let blobs = self.blobs();
        let fail = |target: String, engine: String, message: String| ProjectCompileRecord {
            ok: false,
            manuscript_id: manuscript_id.clone(),
            target_id: target,
            engine,
            pdf_path: None,
            svg_paths: vec![],
            page_count: 0,
            compile_ms: 0,
            diagnostics: vec![],
            bibliographies: vec![],
            message,
        };
        let prepared = (|| -> Result<(ProjectTree, Target), StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let snapshot = mp::load_project(&store, id)?;
            let tree = tree_from_snapshot(&snapshot, &blobs);
            let target = resolve_target(&tree, target_id.as_deref())?;
            Ok((tree, target))
        })();
        let (tree, target) = match prepared {
            Ok(p) => p,
            Err(e) => {
                log_err("project_compile", &e);
                return fail(String::new(), String::new(), e.to_string());
            }
        };
        if target.engine != imprint_core::project::Engine::Typst {
            return fail(
                target.id.clone(),
                target.engine.as_str().into(),
                format!(
                    "target {:?} compiles with {}; only Typst compiles from the tree so far \
                     (LaTeX and Markdown land with project-build)",
                    target.id,
                    target.engine.as_str()
                ),
            );
        }
        let graph = BuildGraph::derive(&tree, &target);
        let resolver = crate::project_bib::StoreBibliographyResolver::new(store.clone());
        let bibs = imprint_core::project::resolve_bibliographies(&tree, &graph, &resolver);
        let mut diagnostics = diagnostic_records(&graph.diagnostics);
        for b in &bibs {
            for key in &b.missing {
                diagnostics.push(ProjectDiagnosticRecord {
                    severity: "warning".into(),
                    code: "missing-reference".into(),
                    message: format!(
                        "{} cited but not in the library (projected into {})",
                        key, b.path
                    ),
                    file: Some(b.path.clone()),
                    line: None,
                });
            }
        }
        let outcome = compile_tree_dispatch(&tree, &target, &bibs, entry_override.as_deref());
        match outcome {
            Err(message) => fail(target.id.clone(), "typst".into(), message),
            Ok(out) => {
                diagnostics.extend(diagnostic_records(&out.diagnostics));
                let dir = compile_output_dir(&manuscript_id, &target.id);
                let mut pdf_path = None;
                let mut svg_paths = Vec::new();
                if out.ok {
                    if let Err(e) = std::fs::create_dir_all(&dir) {
                        return fail(
                            target.id.clone(),
                            "typst".into(),
                            format!("create {}: {e}", dir.display()),
                        );
                    }
                    if let Some(pdf) = &out.pdf {
                        let stem = imprint_core::project::model::file_name_of(&target.entry)
                            .trim_end_matches(".typ")
                            .to_string();
                        let path = dir.join(format!("{stem}.pdf"));
                        if let Err(e) = std::fs::write(&path, pdf) {
                            return fail(
                                target.id.clone(),
                                "typst".into(),
                                format!("write {}: {e}", path.display()),
                            );
                        }
                        pdf_path = Some(path.display().to_string());
                    }
                    for (i, svg) in out.svg_pages.iter().enumerate() {
                        let path = dir.join(format!("page-{:03}.svg", i + 1));
                        if std::fs::write(&path, svg).is_ok() {
                            svg_paths.push(path.display().to_string());
                        }
                    }
                }
                let errors = out.errors().count();
                ProjectCompileRecord {
                    ok: out.ok,
                    manuscript_id: manuscript_id.clone(),
                    target_id: target.id.clone(),
                    engine: "typst".into(),
                    pdf_path,
                    svg_paths,
                    page_count: out.page_count,
                    compile_ms: out.compile_ms as i64,
                    diagnostics,
                    bibliographies: bibliography_records(&bibs),
                    message: if out.ok {
                        format!("{} page(s) in {} ms", out.page_count, out.compile_ms)
                    } else {
                        format!(
                            "{errors} error(s): {}",
                            out.errors()
                                .next()
                                .map(|d| d.message.clone())
                                .unwrap_or_default()
                        )
                    },
                }
            }
        }
    }
}

/// Where a materialisation goes by default:
/// `<cache>/impress/imprint/project-build/<manuscript>/<target>/`.
fn build_output_dir(manuscript_id: &str, target_id: &str) -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(std::env::temp_dir);
    base.join("impress")
        .join("imprint")
        .join("project-build")
        .join(manuscript_id)
        .join(target_id)
}

fn export_record(directory: &Path, out: &Materialization, message: String) -> ProjectExportRecord {
    ProjectExportRecord {
        ok: true,
        directory: directory.display().to_string(),
        entry: out.entry.display().to_string(),
        written: out.written.clone(),
        unchanged: out.unchanged.clone(),
        removed: out.removed.clone(),
        missing: out.missing.clone(),
        message,
    }
}

fn failed_export(directory: &str, e: impl std::fmt::Display) -> ProjectExportRecord {
    ProjectExportRecord {
        ok: false,
        directory: directory.to_string(),
        entry: String::new(),
        written: vec![],
        unchanged: vec![],
        removed: vec![],
        missing: vec![],
        message: e.to_string(),
    }
}

impl DefaultImprintProjectService {
    /// The snapshot and the tree it makes.
    fn load_tree(&self, manuscript_id: &str) -> Result<(ProjectSnapshot, ProjectTree), StoreError> {
        let id = Self::parse(manuscript_id)?;
        let snapshot = mp::load_project(&self.store(), id)?;
        let tree = tree_from_snapshot(&snapshot, &self.blobs());
        Ok((snapshot, tree))
    }

    /// The graph of `target` and every projected bibliography resolved
    /// through the store (imbib's rows).
    fn resolve_for(
        &self,
        tree: &ProjectTree,
        target: &Target,
    ) -> (BuildGraph, Vec<ProjectedBibliography>) {
        let graph = BuildGraph::derive(tree, target);
        let resolver = crate::project_bib::StoreBibliographyResolver::new(self.store());
        let bibs = imprint_core::project::resolve_bibliographies(tree, &graph, &resolver);
        (graph, bibs)
    }

    async fn import_directory_impl(
        &self,
        directory: String,
        manuscript_id: Option<String>,
        entry: Option<String>,
        title: Option<String>,
        author: Option<String>,
    ) -> ProjectImportRecord {
        let store = self.store();
        let blobs = self.blobs();
        let fail = |id: String, message: String| ProjectImportRecord {
            ok: false,
            manuscript_id: id,
            created: false,
            entry_path: String::new(),
            entry_reason: String::new(),
            format: String::new(),
            files: vec![],
            skipped: vec![],
            message,
        };
        let dir = PathBuf::from(directory.trim());
        let options = imprint_core::project::ImportOptions {
            entry: entry
                .map(|e| e.trim().to_string())
                .filter(|e| !e.is_empty()),
            ..Default::default()
        };
        let imported = match imprint_core::project::import_directory(&dir, &options) {
            Ok(t) => t,
            Err(e) => {
                log_err("project_import_directory", &e);
                return fail(manuscript_id.unwrap_or_default(), e.to_string());
            }
        };
        let author = Self::author(author);
        let entry_path = imported.tree.entry.path.clone();
        let entry_text = imported
            .tree
            .entry
            .bytes
            .as_text()
            .unwrap_or("")
            .to_string();

        let placed = (|| -> Result<(ItemId, bool), StoreError> {
            match manuscript_id
                .as_deref()
                .map(str::trim)
                .filter(|m| !m.is_empty())
            {
                Some(m) => {
                    let id = Self::parse(m)?;
                    Self::refuse_external(&store, id)?;
                    // The entry: a row at its path from an earlier import
                    // gives way; the path is declared; the text goes through
                    // the document so the history keeps both sides.
                    if mp::get_file(&store, id, &entry_path)?.is_some() {
                        mp::delete_file(&store, id, &entry_path)?;
                    }
                    mp::set_entry_path(&store, id, &entry_path, &author)?;
                    mp::set_format(&store, id, &imported.format, &author)?;
                    store.commit_manuscript_body(id, &[], &entry_text, &author.name)?;
                    Ok((id, false))
                }
                None => {
                    let fallback = dir
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .filter(|n| !n.is_empty())
                        .unwrap_or_else(|| "Imported manuscript".into());
                    let title = title
                        .map(|t| t.trim().to_string())
                        .filter(|t| !t.is_empty())
                        .unwrap_or(fallback);
                    let item = mp::create_manuscript(
                        &store,
                        mp::NewManuscript {
                            title: &title,
                            format: &imported.format,
                            body: &entry_text,
                            entry_path: Some(&entry_path),
                            collection_ref: None,
                        },
                        &author,
                    )?;
                    Ok((item.id, true))
                }
            }
        })();
        let (id, created) = match placed {
            Ok(p) => p,
            Err(e) => {
                log_err("project_import_directory", &e);
                return fail(manuscript_id.unwrap_or_default(), e.to_string());
            }
        };

        let mut files = Vec::new();
        let mut skipped: Vec<String> = imported
            .skipped
            .iter()
            .map(|(p, why)| format!("{p}: {why}"))
            .collect();
        for f in &imported.tree.files {
            let (bytes, kind): (&[u8], &str) = match &f.bytes {
                FileBytes::Text(t) => (t.as_bytes(), impress_core::schemas::FILE_KIND_TEXT),
                FileBytes::Bytes(b) => (b.as_slice(), impress_core::schemas::FILE_KIND_BINARY),
                FileBytes::Missing => {
                    skipped.push(format!("{}: no bytes", f.path));
                    continue;
                }
            };
            let put = PutFile {
                path: &f.path,
                role: Some(f.role.as_str()),
                bytes,
                kind: Some(kind),
                mime_type: None,
            };
            match mp::put_file(&store, &blobs, id, put, &author) {
                Ok(row) => files.push(ProjectFileRecord::from(&row)),
                Err(e) => {
                    log_err("project_import_directory", &e);
                    return ProjectImportRecord {
                        ok: false,
                        manuscript_id: id.to_string(),
                        created,
                        entry_path,
                        entry_reason: imported.entry_reason.clone(),
                        format: imported.format.clone(),
                        files,
                        skipped,
                        message: format!("{}: {e}", f.path),
                    };
                }
            }
        }
        let message = format!(
            "{} file(s) {} {} with entry {} ({})",
            files.len() + 1,
            if created {
                "imported into new manuscript"
            } else {
                "imported into"
            },
            id,
            entry_path,
            imported.entry_reason
        );
        ProjectImportRecord {
            ok: true,
            manuscript_id: id.to_string(),
            created,
            entry_path,
            entry_reason: imported.entry_reason.clone(),
            format: imported.format.clone(),
            files,
            skipped,
            message,
        }
    }

    async fn export_impl(
        &self,
        manuscript_id: String,
        directory: String,
        target_id: Option<String>,
        layout: Option<String>,
    ) -> ProjectExportRecord {
        let layout = match layout
            .as_deref()
            .map(|l| l.trim().to_ascii_lowercase())
            .as_deref()
        {
            None | Some("") | Some("bundle") => ExportLayout::Bundle,
            Some("standalone") => ExportLayout::Standalone,
            Some(other) => {
                return failed_export(&directory, format!("layout {other:?}: bundle | standalone"))
            }
        };
        let dir = PathBuf::from(directory.trim());
        let result = (|| -> Result<ProjectExportRecord, StoreError> {
            let (_, tree) = self.load_tree(&manuscript_id)?;
            let target = resolve_target(&tree, target_id.as_deref())?;
            let (_, bibs) = self.resolve_for(&tree, &target);
            let out = imprint_core::project::export(&tree, &bibs, &target, &dir, layout)
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let message = format!(
                "{} file(s) exported to {}{}",
                out.written.len(),
                dir.display(),
                if out.missing.is_empty() {
                    String::new()
                } else {
                    format!("; {} without bytes here", out.missing.len())
                }
            );
            Ok(export_record(&dir, &out, message))
        })();
        result.unwrap_or_else(|e| {
            log_err("project_export", &e);
            failed_export(&directory, e)
        })
    }

    async fn materialize_impl(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        directory: Option<String>,
    ) -> ProjectExportRecord {
        let result = (|| -> Result<ProjectExportRecord, StoreError> {
            let (_, tree) = self.load_tree(&manuscript_id)?;
            let target = resolve_target(&tree, target_id.as_deref())?;
            let dir = match directory
                .as_deref()
                .map(str::trim)
                .filter(|d| !d.is_empty())
            {
                Some(d) => PathBuf::from(d),
                None => build_output_dir(&manuscript_id, &target.id),
            };
            let (_, bibs) = self.resolve_for(&tree, &target);
            let out = imprint_core::project::materialize(&tree, &bibs, &dir)
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let message = format!(
                "{} written, {} unchanged, {} removed in {}",
                out.written.len(),
                out.unchanged.len(),
                out.removed.len(),
                dir.display()
            );
            Ok(export_record(&dir, &out, message))
        })();
        result.unwrap_or_else(|e| {
            log_err("project_materialize", &e);
            failed_export(directory.as_deref().unwrap_or(""), e)
        })
    }

    async fn snapshot_impl(
        &self,
        manuscript_id: String,
        revision_tag: String,
        reason: Option<String>,
        target_id: Option<String>,
        author: Option<String>,
    ) -> ProjectSnapshotRecord {
        let result = (|| -> Result<ProjectSnapshotRecord, StoreError> {
            let store = self.store();
            let blobs = self.blobs();
            let (snapshot, tree) = self.load_tree(&manuscript_id)?;
            let target = resolve_target(&tree, target_id.as_deref())?;
            let (_, bibs) = self.resolve_for(&tree, &target);
            let (bytes, manifest) = imprint_core::project::pack(&tree, &bibs, &target)
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let digest = blobs
                .put(&bytes)
                .map_err(|e| StoreError::Storage(format!("archive: {e}")))?;
            let archive_ref = impress_core::blobs::blob_ref(&digest);
            let manifest_json = manifest
                .to_canonical_json()
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let stamp = snapshot.input_stamp(&target.id);
            let reason = reason
                .map(|r| r.trim().to_string())
                .filter(|r| !r.is_empty())
                .unwrap_or_else(|| "project snapshot".into());
            let author = Self::author(author);
            let rev = mp::create_project_revision(
                &store,
                snapshot.manuscript_id,
                mp::ProjectRevision {
                    revision_tag: &revision_tag,
                    snapshot_reason: &reason,
                    archive_ref: &archive_ref,
                    manifest_json: &manifest_json,
                    content_hash: &stamp,
                    word_count: Some(snapshot.entry_text.split_whitespace().count() as i64),
                },
                &author,
            )?;
            let file_count = tree.all_files().count() as u32;
            Ok(ProjectSnapshotRecord {
                ok: true,
                revision_id: rev.id.to_string(),
                revision_tag: revision_tag.clone(),
                archive_ref,
                archive_bytes: bytes.len() as u64,
                file_count,
                content_hash: stamp,
                message: format!(
                    "revision {revision_tag:?}: {file_count} file(s), {} bytes",
                    bytes.len()
                ),
            })
        })();
        result.unwrap_or_else(|e| {
            log_err("project_snapshot", &e);
            ProjectSnapshotRecord {
                ok: false,
                revision_id: String::new(),
                revision_tag: revision_tag.clone(),
                archive_ref: String::new(),
                archive_bytes: 0,
                file_count: 0,
                content_hash: String::new(),
                message: e.to_string(),
            }
        })
    }
}

/// Where a copy of a build output goes when the build directory is gone:
/// `<cache>/impress/imprint/project-output/<build>/`.
fn output_copy_dir(build_id: &str) -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(std::env::temp_dir);
    base.join("impress")
        .join("imprint")
        .join("project-output")
        .join(build_id)
}

fn parse_json<T: serde::de::DeserializeOwned>(json: &Option<String>) -> Option<T> {
    json.as_deref().and_then(|j| serde_json::from_str(j).ok())
}

fn build_record(row: &ManuscriptBuildRow) -> ProjectBuildRecord {
    let r = &row.record;
    ProjectBuildRecord {
        id: row.id.to_string(),
        manuscript_id: row.manuscript_id.to_string(),
        target_id: r.target_id.clone(),
        engine: r.engine.clone(),
        status: r.status.clone(),
        input_stamp: r.input_stamp.clone(),
        started_ms: r.started_ms,
        finished_ms: r.finished_ms,
        duration_ms: r.duration_ms,
        outputs: parse_json(&r.outputs_json).unwrap_or_default(),
        diagnostics: parse_json(&r.diagnostics_json).unwrap_or_default(),
        steps: parse_json(&r.steps_json).unwrap_or_default(),
        allow_shell: r.allow_shell,
        message: r.message.clone().unwrap_or_default(),
    }
}

fn step_records(steps: &[imprint_core::project::StepReport]) -> Vec<ProjectStepReportRecord> {
    use imprint_core::project::StepStatus;
    steps
        .iter()
        .map(|s| ProjectStepReportRecord {
            source: s.source.clone(),
            runner: s.runner.clone(),
            status: match s.status {
                StepStatus::Ran => "ran",
                StepStatus::Fresh => "fresh",
                StepStatus::Skipped => "skipped",
                StepStatus::Failed => "failed",
            }
            .into(),
            message: s.message.clone(),
            duration_ms: s.duration_ms,
            outputs: s.outputs.clone(),
            command: s.command.clone(),
        })
        .collect()
}

impl DefaultImprintProjectService {
    async fn build_impl(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        allow_shell: Option<bool>,
        entry_override: Option<String>,
        author: Option<String>,
    ) -> ProjectBuildResult {
        let store = self.store();
        let blobs = self.blobs();
        let allow_shell = allow_shell.unwrap_or(false);
        let fail = |message: String| ProjectBuildResult {
            ok: false,
            build: None,
            log: String::new(),
            message,
        };
        let prepared = (|| -> Result<_, StoreError> {
            let (snapshot, tree) = self.load_tree(&manuscript_id)?;
            let target = resolve_target(&tree, target_id.as_deref())?;
            let (_, bibs) = self.resolve_for(&tree, &target);
            Ok((snapshot, tree, target, bibs))
        })();
        let (snapshot, tree, target, bibs) = match prepared {
            Ok(p) => p,
            Err(e) => {
                log_err("project_build", &e);
                return fail(e.to_string());
            }
        };
        let author = Self::author(author);
        let mut record = mp::BuildRecord {
            target_id: target.id.clone(),
            engine: target.engine.as_str().to_string(),
            status: BUILD_STATUS_RUNNING.to_string(),
            input_stamp: snapshot.input_stamp(&target.id),
            started_ms: chrono::Utc::now().timestamp_millis(),
            finished_ms: None,
            duration_ms: None,
            outputs_json: None,
            diagnostics_json: None,
            steps_json: None,
            allow_shell,
            message: None,
        };
        let row = match mp::record_build(&store, snapshot.manuscript_id, &record, &author) {
            Ok(r) => r,
            Err(e) => {
                log_err("project_build", &e);
                return fail(e.to_string());
            }
        };
        let work_dir = build_output_dir(&manuscript_id, &target.id);

        // The build runs processes: keep the executor free.
        let outcome = {
            let tree = tree.clone();
            let target = target.clone();
            let bibs = bibs.clone();
            let work_dir = work_dir.clone();
            let entry_override = entry_override.clone();
            tokio::task::spawn_blocking(move || {
                let host = imprint_core::project::ProcessRunnerHost::new();
                imprint_core::project::build(
                    &imprint_core::project::BuildRequest {
                        tree: &tree,
                        target: &target,
                        bibliographies: &bibs,
                        work_dir,
                        allow_shell,
                        entry_override: entry_override.as_deref(),
                    },
                    &host,
                )
            })
            .await
        };
        let outcome = match outcome {
            Ok(o) => o,
            Err(e) => {
                record.status = BUILD_STATUS_FAILED.to_string();
                record.finished_ms = Some(chrono::Utc::now().timestamp_millis());
                record.message = Some(format!("build task: {e}"));
                let _ = mp::finish_build(&store, row.id, &record);
                return fail(format!("build task: {e}"));
            }
        };

        // What the steps produced becomes rows derived from their source.
        let mut produced_rows = 0usize;
        for p in &outcome.produced {
            let role = mp::get_file(&store, snapshot.manuscript_id, &p.path)
                .ok()
                .flatten()
                .map(|r| r.role)
                .unwrap_or_else(|| "output".into());
            let put = PutFile::bytes(&p.path, &p.bytes).with_role(&role);
            let written = mp::put_file(&store, &blobs, snapshot.manuscript_id, put, &author)
                .and_then(|_| {
                    mp::record_derived(
                        &store,
                        snapshot.manuscript_id,
                        &p.path,
                        &p.derived_from,
                        &p.derived_from_hash,
                    )
                });
            match written {
                Ok(_) => produced_rows += 1,
                Err(e) => log_err("project_build", &e),
            }
        }

        // The document into the CAS, so the output outlives the directory.
        let mut outputs: Vec<ProjectBuildOutputRecord> = Vec::new();
        for o in &outcome.outputs {
            let blob_ref = if o.kind == "pdf" || o.kind == "svg" {
                std::fs::read(&o.path)
                    .ok()
                    .and_then(|b| blobs.put(&b).ok())
                    .map(|d| impress_core::blobs::blob_ref(&d))
            } else {
                None
            };
            outputs.push(ProjectBuildOutputRecord {
                kind: o.kind.clone(),
                name: o.name.clone(),
                path: o.path.clone(),
                blob_ref,
                size: o.size,
            });
        }
        let diagnostics = diagnostic_records(&outcome.diagnostics);
        let steps = step_records(&outcome.steps);
        record.status = if outcome.ok {
            BUILD_STATUS_OK
        } else {
            BUILD_STATUS_FAILED
        }
        .to_string();
        record.finished_ms = Some(chrono::Utc::now().timestamp_millis());
        record.duration_ms = Some(outcome.duration_ms as i64);
        record.outputs_json = serde_json::to_string(&outputs).ok();
        record.diagnostics_json = serde_json::to_string(&diagnostics).ok();
        record.steps_json = serde_json::to_string(&steps).ok();
        record.message = Some(outcome.message.clone());
        let row = match mp::finish_build(&store, row.id, &record) {
            Ok(r) => r,
            Err(e) => {
                log_err("project_build", &e);
                return ProjectBuildResult {
                    ok: false,
                    build: None,
                    log: outcome.log,
                    message: format!("record: {e}"),
                };
            }
        };
        if let Err(e) = mp::compact_builds(&store, snapshot.manuscript_id, BUILD_RETENTION) {
            log_err("project_build", &e);
        }
        ProjectBuildResult {
            ok: outcome.ok,
            build: Some(build_record(&row)),
            log: outcome.log,
            message: format!(
                "{} — {} step(s), {} produced row(s), {} output(s)",
                outcome.message,
                steps.len(),
                produced_rows,
                outputs.len()
            ),
        }
    }

    async fn builds_impl(
        &self,
        manuscript_id: String,
        target_id: Option<String>,
        limit: Option<u32>,
    ) -> ProjectBuildsRecord {
        let store = self.store();
        let result = (|| -> Result<Vec<ManuscriptBuildRow>, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let limit = limit.map(|l| l as usize).unwrap_or(BUILD_RETENTION).max(1);
            let rows = mp::list_builds(&store, id, None)?;
            Ok(rows
                .into_iter()
                .filter(|b| {
                    target_id
                        .as_deref()
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .is_none_or(|t| b.record.target_id == t)
                })
                .take(limit)
                .collect())
        })();
        match result {
            Ok(rows) => ProjectBuildsRecord {
                ok: true,
                manuscript_id,
                message: format!("{} build(s)", rows.len()),
                builds: rows.iter().map(build_record).collect(),
            },
            Err(e) => {
                log_err("project_builds", &e);
                ProjectBuildsRecord {
                    ok: false,
                    manuscript_id,
                    builds: vec![],
                    message: e.to_string(),
                }
            }
        }
    }

    async fn build_output_impl(
        &self,
        manuscript_id: String,
        build_id: Option<String>,
        target_id: Option<String>,
        kind: Option<String>,
    ) -> ProjectBuildOutputResult {
        let store = self.store();
        let blobs = self.blobs();
        let kind = kind
            .map(|k| k.trim().to_ascii_lowercase())
            .filter(|k| !k.is_empty())
            .unwrap_or_else(|| "pdf".into());
        let wanted = kind.clone();
        let result = (|| -> Result<ProjectBuildOutputResult, StoreError> {
            let id = Self::parse(&manuscript_id)?;
            let row = match build_id.as_deref().map(str::trim).filter(|b| !b.is_empty()) {
                Some(b) => {
                    let bid = Self::parse(b)?;
                    mp::list_builds(&store, id, None)?
                        .into_iter()
                        .find(|r| r.id == bid)
                        .ok_or_else(|| {
                            StoreError::Validation(format!("no build {b} of this manuscript"))
                        })?
                }
                None => {
                    mp::latest_ok_build(&store, id, target_id.as_deref())?.ok_or_else(|| {
                        StoreError::Validation("no successful build yet; run project-build".into())
                    })?
                }
            };
            let outputs: Vec<ProjectBuildOutputRecord> = row
                .record
                .outputs_json
                .as_deref()
                .and_then(|j| serde_json::from_str(j).ok())
                .unwrap_or_default();
            let out = outputs.iter().find(|o| o.kind == wanted).ok_or_else(|| {
                StoreError::Validation(format!(
                    "build {} has no {wanted} output ({})",
                    row.id,
                    outputs
                        .iter()
                        .map(|o| o.kind.clone())
                        .collect::<Vec<_>>()
                        .join(", ")
                ))
            })?;
            // The build's own file, while it is still what it was.
            if let Ok(meta) = std::fs::metadata(&out.path) {
                if meta.len() == out.size {
                    return Ok(ProjectBuildOutputResult {
                        ok: true,
                        build_id: row.id.to_string(),
                        kind: wanted.clone(),
                        path: Some(out.path.clone()),
                        blob_ref: out.blob_ref.clone(),
                        size: out.size,
                        message: "from the build directory".into(),
                    });
                }
            }
            let Some(blob_ref) = &out.blob_ref else {
                return Err(StoreError::Validation(format!(
                    "{} is gone and this output kind is not kept in the CAS",
                    out.path
                )));
            };
            let digest = impress_core::blobs::parse_blob_ref(blob_ref)
                .ok_or_else(|| StoreError::Validation(format!("bad blob ref {blob_ref}")))?;
            let bytes = blobs
                .get(digest)
                .map_err(|e| StoreError::Storage(e.to_string()))?
                .ok_or_else(|| {
                    StoreError::Validation(format!("{blob_ref} is not in this workspace's CAS"))
                })?;
            let dir = output_copy_dir(&row.id.to_string());
            std::fs::create_dir_all(&dir).map_err(|e| StoreError::Storage(e.to_string()))?;
            let path = dir.join(&out.name);
            std::fs::write(&path, &bytes).map_err(|e| StoreError::Storage(e.to_string()))?;
            Ok(ProjectBuildOutputResult {
                ok: true,
                build_id: row.id.to_string(),
                kind: wanted.clone(),
                path: Some(path.display().to_string()),
                blob_ref: Some(blob_ref.clone()),
                size: bytes.len() as u64,
                message: "from the workspace CAS".into(),
            })
        })();
        result.unwrap_or_else(|e| {
            log_err("project_build_output", &e);
            ProjectBuildOutputResult {
                ok: false,
                build_id: build_id.unwrap_or_default(),
                kind,
                path: None,
                blob_ref: None,
                size: 0,
                message: e.to_string(),
            }
        })
    }
}

/// The graph as a record; shared with the build verbs of later phases.
pub fn graph_record(
    manuscript_id: &str,
    graph: &BuildGraph,
    message: String,
) -> ProjectGraphRecord {
    ProjectGraphRecord {
        ok: true,
        manuscript_id: manuscript_id.into(),
        target_id: graph.target_id.clone(),
        entry: graph.entry.clone(),
        edges: graph
            .deps
            .edges
            .iter()
            .map(|e| ProjectEdgeRecord {
                from: e.from.clone(),
                to: e.to.clone(),
                kind: e.kind.as_str().into(),
                line: e.line,
            })
            .collect(),
        unresolved: graph
            .deps
            .unresolved
            .iter()
            .map(|u| ProjectUnresolvedRecord {
                from: u.from.clone(),
                reference: u.reference.clone(),
                kind: u.kind.as_str().into(),
                line: u.line,
            })
            .collect(),
        cite_keys: graph.deps.cite_keys.iter().cloned().collect(),
        steps: graph
            .steps
            .iter()
            .map(|s| ProjectStepRecord {
                source: s.source.clone(),
                runner: s.runner.as_str().into(),
                outputs: s.outputs.clone(),
                inputs: s.inputs.clone(),
                input_hash: s.input_hash.clone(),
                stale: s.is_stale(),
                stale_outputs: s.stale_outputs.clone(),
                missing_outputs: s.missing_outputs.clone(),
                missing_inputs: s.missing_inputs.clone(),
            })
            .collect(),
        reachable: graph.reachable.iter().cloned().collect(),
        unreferenced: graph.unreferenced.clone(),
        bibliographies: graph.bibliographies(),
        diagnostics: graph
            .diagnostics
            .iter()
            .map(|d| ProjectDiagnosticRecord {
                severity: match d.severity {
                    imprint_core::project::Severity::Error => "error".into(),
                    imprint_core::project::Severity::Warning => "warning".into(),
                    imprint_core::project::Severity::Info => "info".into(),
                },
                code: d.code.clone(),
                message: d.message.clone(),
                file: d.file.clone(),
                line: d.line,
            })
            .collect(),
        has_errors: graph.has_errors(),
        message,
    }
}

impress_service_impl! {
    service = ImprintProjectService,
    impl = DefaultImprintProjectService,
    instance = DefaultImprintProjectService::new,
    methods = [
        project_tree(manuscript_id: String) -> ProjectTreeRecord,
        project_file(manuscript_id: String, path: String) -> ProjectFileContentRecord,
        project_put_file(manuscript_id: String, path: String, content: Option<String>, file_path: Option<String>, role: Option<String>, author: Option<String>) -> ProjectFileResult,
        project_delete_file(manuscript_id: String, path: String) -> ProjectMutationResult,
        project_move_file(manuscript_id: String, from: String, to: String, author: Option<String>) -> ProjectFileResult,
        project_set_entry(manuscript_id: String, path: String, author: Option<String>) -> ProjectMutationResult,
        project_set_targets(manuscript_id: String, targets_json: Option<String>, author: Option<String>) -> ProjectTreeRecord,
        project_set_bibliography(manuscript_id: String, path: String, bib_source_json: Option<String>) -> ProjectFileResult,
        project_set_figure_build(manuscript_id: String, path: String, build_json: Option<String>) -> ProjectFileResult,
        project_graph(manuscript_id: String, target_id: Option<String>) -> ProjectGraphRecord,
        project_outline(manuscript_id: String, target_id: Option<String>) -> ProjectOutlineRecord,
        project_citations(manuscript_id: String, target_id: Option<String>) -> ProjectCitationsRecord,
        project_compile(manuscript_id: String, target_id: Option<String>, entry_override: Option<String>) -> ProjectCompileRecord,
        project_import_directory(directory: String, manuscript_id: Option<String>, entry: Option<String>, title: Option<String>, author: Option<String>) -> ProjectImportRecord,
        project_export(manuscript_id: String, directory: String, target_id: Option<String>, layout: Option<String>) -> ProjectExportRecord,
        project_materialize(manuscript_id: String, target_id: Option<String>, directory: Option<String>) -> ProjectExportRecord,
        project_snapshot(manuscript_id: String, revision_tag: String, reason: Option<String>, target_id: Option<String>, author: Option<String>) -> ProjectSnapshotRecord,
        project_build(manuscript_id: String, target_id: Option<String>, allow_shell: Option<bool>, entry_override: Option<String>, author: Option<String>) -> ProjectBuildResult,
        project_builds(manuscript_id: String, target_id: Option<String>, limit: Option<u32>) -> ProjectBuildsRecord,
        project_build_output(manuscript_id: String, build_id: Option<String>, target_id: Option<String>, kind: Option<String>) -> ProjectBuildOutputResult,
    ],
}
