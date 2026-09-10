# ADR-0030: A Manuscript Is a Project

**Status:** Accepted — implementation in progress (P0 landing 2026-09-09; execution plan in
`~/.claude/plans/manuscript-projects.md`)
**Date:** 2026-09-09
**Depends on:** ADR-0001 (unified items), ADR-0011 (journal: manuscript envelope, revisions,
bundle manifest), ADR-0018 (thin-twin chassis), ADR-0023 (watched folders, reference-in-place),
ADR-0027 (Automerge manuscript bodies)
**Extends:** ADR-0027 D2 (one body per manuscript → one body per *file*); the journal plan's
Phase 8 bundle format (an archive-only description → the serialisation of a live model)

## Context

imprint models a manuscript as **one string**: `manuscript.body_content`, Automerge-backed,
in one of four formats. Real manuscripts are not one string. A paper is chapters `\input` from a
main file, a `figures/` directory, one `.bib` per collaborator plus the one imbib projects,
`.cls`/`.sty` files the journal shipped, data files a Typst `csv(…)` reads, and — increasingly
— the script or plot document that *made* each figure. Every one of those had grown a separate,
partial, mostly Swift-side accommodation:

- figures live in an app-group directory the store cannot see (`ManuscriptWorkingDirectory`),
  listed by a `VeuszPlotRef` array on the Swift document model;
- the bibliography is one virtual `bibliography.bib` assembled in Swift from cited keys;
- multi-file LaTeX is scanned by `LaTeXProjectService.swift` over files on disk, and multi-file
  Typst by `render_project.rs` over a directory — both require the manuscript to already be a
  directory, which a store-resident manuscript never is;
- the `manuscript-bundle-manifest` describes only snapshot archives, and `create_revision`
  snapshots only the single body;
- import and export handle one file; a project directory cannot become one manuscript;
- "the code that makes figure 3" is Veusz-only, Swift-only, and nothing knows when `fig3.pdf`
  is stale;
- Markdown previews but never builds.

Each accommodation was a second definition of "what a manuscript contains", kept in step by
hand — the drift the root briefing warns about. And none of it was agent-drivable: an agent
could commit a body but not add a chapter, attach a figure, or ask why the build failed.

## Decisions

### D1. A manuscript is a project: a tree of files in the store

`manuscript-file@1.0.0` rows, **parent = the manuscript item**, hold every file of the
manuscript except its entry. Each row: `path` (POSIX-relative, validated), `role`, `kind`
(`text|binary`), `format`, `content` (inline text) or `blob_ref` (content-addressed), always a
`content_hash` and `size`, plus the derivation fields of D6 and the bibliography spec of D7.
The row id is `uuid_v5(NS, "<manuscript>|<path>")`: two devices, a re-import and a watched
folder agree on identity without a query (the rule ADR-0023 uses one layer down).

**The entry file's content stays in `manuscript.body_content`.** Every existing manuscript is
therefore already a one-file project; FTS, list rows, editor sessions, revisions and sync keep
reading what they read today, and there is no migration. `entry_path` (default `main.<ext>`)
names it; a manuscript with no file rows and no targets is exactly today's manuscript.

### D2. One vocabulary for roles, in rows and in archives

`FileRole` = `chapter | bibliography | figure | figure-source | data | style | aux | supplement |
output` (`main` is implicit — the entry). It is the same enum as the bundle manifest's
`BundleEntryRole`, extended. The manifest is no longer hand-described: it is **produced** by
serialising the tree (`materialize::pack`), so a revision's `bundle_manifest_json` and a live
project cannot disagree.

### D3. Text is Automerge, binaries are blobs, there is one CAS

Text files are Automerge documents through the ADR-0027 machinery, generalised from "the
manuscript" to "an item with a text field": `collab.rs` accepts `manuscript` (field
`body_content`) and `manuscript-file` (field `content`); change chunks' parent is the item.
Heads, commits, history and time-travel work per file with no new code paths. Binaries and
text over 1 MiB are `blob:sha256:<hex>` refs into **one** workspace CAS
(`impress_core::blobs`, the layout `imprint-service::blob_store` already used), shared by
manuscript snapshots, section bodies, project binaries and build outputs.

### D4. The build graph is derived, never stored

Rust scans the tree — LaTeX (`\input`, `\include`, `\includegraphics`, `\bibliography`,
`\addbibresource`, local `.cls`/`.sty`, …), Typst (`#include`, `#import`, `image`,
`bibliography`, `read`, `csv/json/…`), Markdown (images, front-matter `bibliography:`) — and
derives edges, unresolved references (a diagnostic naming the file and line) and staleness.
Nothing about structure is written down twice: rename a chapter and the graph follows the
source. `LaTeXProjectService.swift` is retired by this.

### D5. Rust materialises; toolchains see a directory or an in-memory tree

`materialize(tree, dir)` writes the tree idempotently (hash-compare, tmp+rename, prunes only
what left the tree, never leaves `dir`). Tectonic and system TeX compile in it; export *is*
materialisation to a user path; a revision archive *is* materialisation into `tar.zst`. Typst
never needs it: a `TreeFileResolver` serves the tree's bytes to the persistent engine directly,
so multi-file previews cost no disk, work on iOS, and stay deterministic. Swift no longer
assembles a directory for anything.

### D6. Figures made by code are files with a declared runner and declared outputs

A `figure-source` row carries `build_json = {runner, outputs[], inputs[], args}`. Its outputs
are `figure` rows with `derived_from` = the source path and `derived_from_hash` = the hash of
(source bytes, input bytes, build_json) they were last built from; the graph reports them
stale when that hash moves. Runners: `impress-plot` (a plot-spec file, native, always
available), `implore` (export of an implore figure item, native), `veusz` (the host executes
`veusz.exe --export`), `shell` (an explicit command — **never automatic**: a build runs shell
steps only with `allow_shell`, recorded on the build row, desktop only). Rust plans every step;
only the two the host must execute leave Rust, as `RunnerRequest`s.

### D7. Bibliographies are files; projected ones carry their query

A `bibliography` row is either literal BibTeX or a `bib_source_json` spec — `cited` (every key
cited anywhere in the tree, projected from imbib: today's behaviour, now expressed as the
implicit `bibliography.bib`), `collection`/`library` (an imbib collection or library),
`keys`. Projection happens at materialisation/compile through a `BibliographyResolver` port
that imbib-core implements; imprint-core never learns imbib's store. `\addbibresource{a.bib}`
and `#bibliography(("a.bib", "b.bib"))` therefore just work.

### D8. Builds are records; previews are not

An explicit build (⌘B, `project-build`, snapshot, export) writes a `manuscript-build@1.0.0` row:
target, engine, input stamp, outputs as blob refs, structured diagnostics, the steps that ran,
duration, whether shell was allowed. It is what "the PDF for this manuscript" means, what an
agent reads to learn why a build failed, and what a revision attaches. The editor's debounced
preview compiles are ephemeral — a row per keystroke would be a churn incident. The daemon's
hygiene cycle keeps the last 20 per manuscript.

### D9. Targets: one project, many outputs

`entry_path` plus `targets_json` (`[{id, name, entry, engine, output_kind, args}]`): the paper,
its supplement and the talk are three targets of one tree. Absent → one implicit target from
`entry_path` and `format`.

### D10. Markdown builds through Typst

A Markdown manuscript compiles by conversion to Typst in Rust (`pulldown-cmark`: headings,
emphasis, lists, links, images, code, math, tables, footnotes, `[@key]` citations, front-matter
title/authors/bibliography) and then the Typst path — so `.md` manuscripts get figures,
bibliographies and PDFs from the same graph.

### D11. Working copies are watched folders

`project-checkout` materialises the tree to a user directory and records `working_copy_path`;
that directory is a watched folder scoped to the manuscript (ADR-0023), so edits made there by
a collaborator, a script or git land back as file-row updates; `project-checkin` reconciles by
hash and refuses only when an editor buffer holds unsynced edits to the same file. Git links
the working copy — `ImprintGitIntegration` needs no new concept.

### D12. Every capability is a verb first

`imprint-project-service_project-*` (`#[impress_service]`, store-direct, works with the app
closed): tree, file get/put/delete/move, entry, targets, bibliography spec, figure build spec,
graph, build, builds, build output, import directory, export, snapshot, checkout/checkin.
Swift is a projection: the Files side panel, a session per file, the Build panel, and the two
host executors (Veusz, system TeX).

## Consequences

- A researcher imports a paper directory and gets one manuscript whose chapters, figures, data
  and bibliographies are rows: searchable, syncable, revisioned, agent-visible.
- An agent can add a chapter, attach a figure, declare how it is made, ask for the graph, run
  the build and read the diagnostics — headless.
- Existing single-file manuscripts change nothing; the one-file tree walks to byte-identical
  sections (pinned by a golden test).
- The Swift accommodations retire in order: the LaTeX project scanner and sidebar, the
  Veusz plot list on the document model, the exporter's directory assembly, the working
  directory's materialisation logic.
- More rows: one per file, one per explicit build, Automerge chunks per text file. All three
  kinds are named, counted in `/api/health`, and compacted by declared policy.

## Not decided here

Cross-manuscript file sharing (a `.cls` used by two papers is two rows until a `shared`
role earns its two use cases). Remote build runners. Typst `--root` semantics beyond the tree
(a reference above the entry's directory is unresolved, by design).

## Status (2026-09-09)

| Phase | State | Where |
|---|---|---|
| P0 records + store ops | landed | `impress_core::{schemas::manuscript_file, schemas::manuscript_build, manuscript_project, blobs}`, `collab.rs` generalised; `crates/impress-core/tests/manuscript_project.rs` |
| P1 scanners + graph + verbs | landed | `imprint_core::project::{model,scan,graph}`, `imprint-project-service` (tree/file/put/delete/move/set-entry/set-targets/set-bibliography/set-figure-build/graph); `crates/imprint-core/tests/project_graph.rs`, `crates/imprint-service/tests/project_service.rs`, selftest `project.tree_roundtrip` / `project.graph_diagnostics` |
| P2 Typst over the tree | landed | `project::{bib,outline,typst}`, verbs outline/citations/compile, `StoreBibliographyResolver`, FFI `compile_typst_tree_to_output`/`project_graph_json`, `SharedStore.manuscript_project_*`; Swift `ManuscriptProjectModel`, `ManuscriptSessionRegistry.fileSession`, tree previews, imprint Files inspector |
| P3 materialise / import / export / snapshot | landed | `project::{materialize,import}`, verbs import-directory/export/materialize/snapshot, `manuscript_project::{create_manuscript,set_format,create_project_revision}`; selftest `project.import_export_snapshot`; imprint File ▸ Import Folder as Manuscript…, Files ▸ Import folder… |
| P4 builds | landed | `project::{runner,build,markdown}`, verbs build/builds/build-output, FFI `project_build_tree`/`markdown_to_typst`, `SharedStore.manuscript_project_record_build/finish_build/record_derived`; selftest `project.build_records`; imprint Build inspector + File ▸ Build Manuscript (⌥⌘B); LaTeX projects preview through the engine |
| P5 figure code (native runners) | not started | `build.rs` reports `impress-plot`/`implore` steps as `skipped`; `veusz` and `shell` run through the host today |
| P6 working copies + git | not started | `working_copy_path` is declared on the manuscript row and unused |
| P7 retirement + docs | in progress | `docs/imprint-projects.md` (guide), matrix rows; `LaTeXProjectService.swift`, `LaTeXProjectSidebarView`, the Swift Veusz plot list and `ManuscriptExporter`'s directory assembly still exist beside the new paths |

Verification is the workspace gate plus `cargo test -p impress-core --features "sqlite collab"
--test manuscript_project`, `cargo test -p imprint-core --features typst-render`,
`cargo test -p imprint-service --features typst-render --test project_service`,
`cargo test -p imprint-selftest`, and the framework rebuilds (`IMPRESS_SKIP_X86=1`) followed by
PMC `swift test --parallel` and a Debug imprint build.
