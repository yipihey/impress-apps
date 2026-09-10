//! A manuscript is a project (ADR-0030).
//!
//! * [`model`] — the tree: files with bytes, roles from the bundle manifest's
//!   vocabulary, one entry, one or more targets.
//! * [`scan`] — what each LaTeX / Typst / Markdown file reaches for, resolved
//!   against the tree; comments respected, offsets preserved.
//! * [`graph`] — the derived build graph: reachability, include cycles,
//!   figure steps with staleness, structured diagnostics.
//! * [`bib`] — bibliographies as files; projected ones resolved through the
//!   `BibliographyResolver` port (D7).
//! * [`outline`] — sections and citations over the whole tree, in reading
//!   order.
//! * [`materialize`] — Rust materialises: a tree written to a directory
//!   idempotently for toolchains that need one, an export in two layouts,
//!   and the deterministic `.tar.zst` revision archive with the manifest.
//! * [`import`] — a directory becomes a tree: build residue skipped, roles
//!   from extension then from use, the entry guessed transparently.
//! * [`runner`] — the port a build executes through (`RunnerHost`): real
//!   processes with timeouts, or a scripted host in tests.
//! * [`build`] — one build of one target: stale figure steps, then the
//!   document engine (Typst from memory, Markdown converted to Typst,
//!   LaTeX through a materialised directory), reported as one record.
//! * [`markdown`] — Markdown → Typst markup (D10), citations included.
//! * [`typst`] (feature `typst-render`) — Typst over the tree from memory,
//!   no directory (D5).
//!
//! Everything here is pure. The store layer
//! (`impress_core::manuscript_project`) knows rows; `imprint-service` turns
//! rows into a [`model::ProjectTree`] and asks this module questions.

pub mod bib;
pub mod build;
pub mod graph;
pub mod import;
pub mod markdown;
pub mod materialize;
pub mod model;
pub mod outline;
pub mod runner;
pub mod scan;
#[cfg(feature = "typst-render")]
pub mod typst;

pub use bib::{
    implicit_bibliography, resolve_bibliographies, synthesize_entry, BibliographyResolver,
    MapResolver, NoResolver, ProjectedBibliography, ResolvedEntry, IMPLICIT_BIBLIOGRAPHY,
};
pub use build::{
    build, BuildOutcome, BuildRequest, BuiltOutput, ProducedFile, StepReport, StepStatus,
};
pub use graph::{BuildGraph, Diagnostic, FigureStep, Severity};
pub use import::{guess_entry, import_directory, ImportError, ImportOptions, ImportedTree};
pub use markdown::{latex_math_to_typst, to_typst, TypstConversion};
pub use materialize::{
    export, manifest_for, materialize, pack, unpack, ExportLayout, Materialization,
    MaterializeError, LEDGER_FILE,
};
pub use model::{
    BibSource, BuildSpec, Engine, FileBytes, FileKind, FileRole, OutputKind, ProjectFile,
    ProjectTree, Runner, Target, IMPLICIT_TARGET_ID,
};
pub use outline::{
    citations_for_tree, reading_order, sections_for_tree, TreeCitation, TreeSection,
};
pub use runner::{
    ProcessRunnerHost, RunError, RunOutput, RunRequest, RunnerHost, ScriptedRunnerHost,
};
pub use scan::{scan, scan_text, DepEdge, DepKind, DependencyGraph, RawReference, Unresolved};
#[cfg(feature = "typst-render")]
pub use typst::{compile_typst_tree, TreeCompileOutcome, TreeCompiler};
