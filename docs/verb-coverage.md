# Verb coverage: what the inventory holds, and which crates are outside it

**Decided by:** plan-auto-gui-and-self-docs.md (tables 1 and 5, findings C-1 and C-2, D-G4).
**Executed by:** work package G0; G6 finishes the per-item `internal` binding-tell.
**Enforced by:** `crates/impress-capabilities/tests/census.rs` (the linked
inventory against the tables below) and `scripts/check-verb-coverage.sh` (the
source-only half, run by `.github/workflows/kit.yml`).

Two claims the suite makes need a document CI can read. First, *every verb in
the linked `full` inventory* has a description an agent can act on, and the
count of verbs, arguments and described arguments per service is known rather
than estimated. Second, *every workspace crate* either exposes its capability
through a `*-service` crate or says why it does not. The tables here are the
record of both; the test and the script are what keep the record true.

The rule is the one `docs/kit-manifest.md` uses: the tables between the
markers are data. Edit the table and the checks change with it. They keep no
second list.

## Services (table 1 of the plan)

Counted from `McpToolDescriptor::iter()` with every feature on. *Real
description* is a description that is not the macro's `Invoke Service.method`
fallback — since G1 the macro refuses an undocumented method, so this column
equals *Verbs* and stays that way. *Args (required)* counts the properties of
each verb's published input schema; *Args described* the ones carrying a
`description` (argument `///` lines); *Strict* the verbs of services using
the default `strict_args = true` (unless explicitly disabled). When the
inventory moves, the census test fails and prints the row as it should now
read.

<!-- verb-coverage-services:begin -->
| Service | Crate | Verbs | Real description | Args (required) | Args described | Strict |
|---|---|---:|---:|---:|---:|---:|
| `capabilities-service` | capabilities-service | 4 | 4 | 5 (1) | 5 | 4 |
| `collection-service` | impress-store-service | 12 | 12 | 25 (22) | 25 | 12 |
| `docs-import-service` | impress-store-service | 10 | 10 | 38 (22) | 38 | 10 |
| `history-service` | impress-store-service | 7 | 7 | 15 (9) | 15 | 7 |
| `imbib-annotations-service` | imbib-service | 9 | 9 | 27 (15) | 27 | 9 |
| `imbib-app-service` | imbib-service | 18 | 18 | 29 (20) | 29 | 18 |
| `imbib-artifacts-service` | imbib-service | 9 | 9 | 36 (14) | 36 | 9 |
| `imbib-backup-service` | imbib-service | 6 | 6 | 8 (7) | 8 | 6 |
| `imbib-eink-service` | imbib-service | 22 | 22 | 35 (15) | 35 | 22 |
| `imbib-library-service` | imbib-service | 49 | 49 | 95 (71) | 95 | 49 |
| `imbib-manuscripts-service` | imbib-service | 7 | 7 | 9 (8) | 9 | 7 |
| `imbib-scix-service` | imbib-service | 7 | 7 | 17 (15) | 17 | 7 |
| `imbib-search-service` | imbib-service | 10 | 10 | 23 (18) | 23 | 10 |
| `imbib-semantic-service` | imbib-semantic-service | 3 | 3 | 4 (2) | 4 | 3 |
| `imbib-tags-service` | imbib-service | 10 | 10 | 20 (14) | 20 | 10 |
| `imbib-text-service` | imbib-service | 5 | 5 | 7 (4) | 7 | 5 |
| `imbib-undo-service` | imbib-service | 3 | 3 | 3 (3) | 3 | 3 |
| `impart-service` | impart-service | 10 | 10 | 24 (14) | 24 | 10 |
| `impel-service` | impel-service | 11 | 11 | 15 (12) | 15 | 11 |
| `implore-service` | implore-service | 23 | 23 | 51 (17) | 51 | 23 |
| `impress-ai-service` | impress-ai-service | 16 | 16 | 25 (19) | 25 | 16 |
| `impress-bridges-service` | impress-bridges-service | 18 | 18 | 30 (29) | 30 | 18 |
| `impress-scenario-service` | impress-scenario-service | 6 | 6 | 11 (4) | 11 | 6 |
| `impress-surface-service` | impress-surface-service | 15 | 15 | 33 (18) | 33 | 15 |
| `impress-workflow-service` | impress-workflow-service | 7 | 7 | 7 (6) | 7 | 7 |
| `imprint-app-service` | imprint-service | 17 | 17 | 37 (24) | 37 | 17 |
| `imprint-manuscript-service` | imprint-service | 17 | 17 | 34 (34) | 34 | 17 |
| `imprint-project-service` | imprint-service | 30 | 30 | 97 (47) | 97 | 30 |
| `imprint-selftest-service` | imprint-selftest | 1 | 1 | 1 (1) | 1 | 1 |
| `imprint-text-service` | imprint-service | 5 | 5 | 11 (11) | 11 | 5 |
| `imprint-throughline-service` | imprint-service | 9 | 9 | 16 (16) | 16 | 9 |
| `layout-selftest-service` | impress-layout-service | 1 | 1 | 1 (1) | 1 | 1 |
| `layout-service` | impress-layout-service | 36 | 36 | 184 (83) | 184 | 36 |
| `manuscript-collab-service` | impress-store-service | 4 | 4 | 8 (8) | 8 | 4 |
| `memory-service` | impress-memory-service | 7 | 7 | 20 (20) | 20 | 7 |
| `parsers-service` | impress-parsers-service | 6 | 6 | 9 (9) | 9 | 6 |
| `perf-service` | perf-service | 4 | 4 | 4 (3) | 4 | 4 |
| `provider-service` | impress-store-service | 2 | 2 | 2 (2) | 2 | 2 |
| `settings-service` | impress-store-service | 6 | 6 | 6 (5) | 6 | 6 |
| `smart-search-service` | impress-smart-search-service | 10 | 10 | 28 (28) | 28 | 10 |
| `source-service` | impress-store-service | 9 | 9 | 21 (10) | 21 | 9 |
| `store-query-service` | impress-store-service | 4 | 4 | 8 (8) | 8 | 4 |
| `surface-demo-service` | surface-demo-service | 2 | 2 | 4 (4) | 4 | 2 |
| `surface-selftest-service` | impress-surface-service | 1 | 1 | 1 (1) | 1 | 1 |
| `triage-service` | impress-store-service | 5 | 5 | 10 (8) | 10 | 5 |
| `vw-diagnostic-service` | vw-impress-adapter | 15 | 15 | 24 (20) | 24 | 15 |
| **Total** | 21 crates, 46 services | **488** | **488** | **1118 (722)** | **1118** | **488** |
<!-- verb-coverage-services:end -->

The *Crate* column is the crate holding the service's `impress_service_impl!`
block — the one that emits the inventory entries — so `vw-diagnostic-service`
is `vw-impress-adapter`'s, though `vw-service` holds the trait.

### Argument shapes

Every argument of every verb, classified from its published JSON schema. A
form generator maps `scalar` to a field widget and everything else to a
raw-JSON field, which is the CLI's precedent (plan § Table 2). An
`Option<Dto>` (`anyOf: [{$ref}, {type: null}]`) counts as the DTO, so this
histogram folds the plan's one `tagged-union` into `ref-object`.

<!-- verb-coverage-shapes:begin -->
| Shape | Arguments |
|---|---:|
| `array-of-objects` | 4 |
| `array-of-scalars` | 55 |
| `inline-object` | 7 |
| `map` | 2 |
| `other` | 43 |
| `ref-object` | 6 |
| `scalar` | 1001 |
<!-- verb-coverage-shapes:end -->

## Crates (table 5 and appendix A5 of the plan)

One row per workspace member. The verdicts:

- **verb-crate**: holds an `impress_service_impl!` block that the `full`
  inventory links. The test derives this from the sources and refuses any other
  verdict for such a crate, and this verdict for any other.
- **covered-through**: no verbs of its own; its capability reaches agents
  through a verb crate that calls it.
- **internal**: no verbs, and correctly so — a binary, glue, an FFI shim, a UI
  state machine, or something an agent should not hold — with the reason.
- **should-be-verb**: holds capability that meets the plan's rule (serde-shaped
  in and out, no live UI handle, no secret) and reaches agents through nothing
  in the inventory. The *Reason* column names examples. This is the gap the
  plan holds rather than closes (C-1): the test fails when the number of
  `should-be-verb` rows rises above 20, so a new crate in this state either
  writes its verbs or is listed `internal` with a reason. Writing a crate's
  verbs moves its row to `verb-crate` or `covered-through` and lowers the
  ceiling in `census.rs`.
- **optional-feature**: holds an `impress_service_impl!` block, but linked
  only under a named Cargo feature outside `full` — the Reason column names
  it. Whether *this* build links it depends on the feature flags this test
  run passed, so the test accepts the crate whether or not it currently shows
  up as a verb crate (P3c step 2). `imbib-semantic-service` is the first:
  `impress-capabilities`'s `semantic-search` feature, which only
  `impress-mcp` turns on.

`implore-stats` and `implore-selection` have zero callers in the workspace
(C-2); they are listed as the plan found them, `should-be-verb` and `internal`,
and the implore owner decides between verbs and deletion.

<!-- verb-coverage-crates:begin -->
| Crate | Role | Verdict | Reason / uncovered capabilities |
|---|---|---|---|
| `capabilities-service` | verb-crate | verb-crate | |
| `im-bibtex` | library | should-be-verb | `parser::{parse, parse_with_options, parse_entry}` and `formatter::{format_entry, format_entries}` have no verb; `import_bibtex` ingests but does not return parsed entries; ships its own MCP server (`src/mcp.rs`) and Python bindings outside the inventory |
| `im-identifiers` | library | should-be-verb | `validators::{is_valid_doi, is_valid_arxiv_id, is_valid_isbn, normalize_doi, normalize_arxiv_id}` and `resolver::{identifier_url, identifier_display_name}` have no verb; own MCP server and Python bindings outside the inventory |
| `imbib-cli` | binary | internal | the CLI binary over the inventory |
| `imbib-core` | domain-core | should-be-verb | reached by `imbib-service` through `ImbibStore` (48 of 180 methods); RIS parse/format/import/export, `merge_publications`, the reference-filter grammar and ≈170 of 259 `uniffi::export` items have no verb |
| `imbib-semantic-service` | verb-crate | optional-feature | `semantic-search` — the three legacy semantic-search MCP tools; deliberately not in `full` (the fastembed/tokenizers stack is a cost only `impress-mcp` should pay); only `impress-mcp` enables it |
| `imbib-service` | verb-crate | verb-crate | |
| `imbib-verbs-ffi` | ffi | internal | imbib per-app dispatch and exact-store initialization (P5b prerequisite for W3); no independent capability |
| `impart-core` | domain-core | should-be-verb | `provenance::queries::{trace_lineage, trace_effects, artifact_history, decision_history, …}` have no verb; `impart-service` calls nothing in it |
| `impart-service` | verb-crate | verb-crate | |
| `impart-verbs-ffi` | ffi | internal | impart's native app dispatcher over its service inventory; no independent capability |
| `impel-core` | domain-core | should-be-verb | `escalation::{acknowledge, resolve, dismiss}` and `coordination::{available_threads, threads_by_state, open_escalations}` reach agents only over `impel-server`'s HTTP |
| `impel-enrichment` | library | internal | task executors (`HeuristicClassifier`, `LlmClassifier`, `MetadataResolveExecutor`) that run only as scheduled impel tasks |
| `impel-memory` | library | internal | `claim_distill` and `spawn::plan_memory_tasks` are internal to the daemon's consolidation |
| `impel-server` | binary | should-be-verb | an agent HTTP API (escalations, threads, claims, reviews) that bypasses the inventory entirely |
| `impel-service` | verb-crate | verb-crate | |
| `impel-taskd` | binary | internal | the task scheduler daemon |
| `impel-throughline` | library | internal | `draft_prompt` and the drafters run only as the scheduled executor |
| `impel-tools` | glue/inventory | internal | projects the inventory into impel's agent loop |
| `impel-tui` | binary | internal | a terminal UI |
| `implore-core` | domain-core | should-be-verb | `plugin` (85 pub fns), `library` and `dataset` catalogues reachable only over HTTP with the app running; `implore-service` calls one function |
| `implore-io` | library | should-be-verb | `reader::open_file` / `DataReader`, `Hdf5Reader::list_datasets`, `NpzFile::array_names` — no verb opens a data file and returns its schema |
| `implore-selection` | library | internal | `parser::parse_selection` and `Evaluator::{evaluate, selected_indices}` have zero callers in the workspace (C-2); the implore owner decides between a verb and deletion |
| `implore-service` | verb-crate | verb-crate | |
| `implore-stats` | library | should-be-verb | `Ecdf::{from_data, quantile, five_number_summary}`, `SummaryStats::{from_data, zscore, robust_zscore, winsorize}` have no verb and zero callers (C-2) |
| `implore-verbs-ffi` | ffi | internal | implore's own per-app UniFFI target (P5); dispatches `implore-service`'s existing verbs by name, no capability of its own |
| `impress-ai` | domain-core | should-be-verb | `registry::{complete, stream}` (direct completion), `set_model_enabled`, `set_task_category` have no verb; `queue_message` only enqueues a turn |
| `impress-ai-http` | binary | internal | HTTP transport for impress-ai chat |
| `impress-ai-service` | verb-crate | verb-crate | |
| `impress-ai-tools` | glue/inventory | internal | a third force-link list beside `impress-capabilities` (recorded in the pipeline plan) |
| `impress-app-transport` | library | internal | the P5 transport's client side (`call(app, verb, args)`); no capability of its own, it reaches a verb another crate already holds |
| `impress-bibtex` | ffi | internal | Swift-only `*_ffi` shims over `im-bibtex` (the gap is `im-bibtex`'s row) |
| `impress-bridges-service` | verb-crate | verb-crate | |
| `impress-capabilities` | glue/inventory | internal | the one linked inventory |
| `impress-cli` | binary | internal | the CLI binary over the inventory |
| `impress-collab` | library | internal | `Permissions::{can_view, can_comment, can_edit, can_share}` and `PresenceInfo` are per-session state, not agent capability |
| `impress-core` | library | covered-through | the store every service crate persists into; `sync` (CloudKit-style outbox) is Swift-only and correctly so; `maintenance` and `task_schema_migration` have no verb |
| `impress-domain` | library | should-be-verb | `citation_reference::{create_citation_reference, citation_to_typst, citation_to_latex, create_citation_batch}` are Swift-only |
| `impress-embeddings` | library | should-be-verb | `ChunkIndex::{search, search_scoped}` reach agents only through `impress-mcp`'s hand-written `search_papers` / `get_paper_chunks` |
| `impress-flags` | library | should-be-verb | `query::{parse_flag_query, FlagQuery::matches}` and `parse::parse_flag_command` have no verb |
| `impress-fs-lock` | library | internal | the advisory `flock` `impress-ai` and `impress-settings` share (ADR-0036 D-R8); a lock is not a capability |
| `impress-git` | library | should-be-verb | `commands::{status_cmd, commit_cmd, log_cmd, diff_cmd, push_cmd, pull_cmd, clone_cmd}` and the porcelain parsers have no verb |
| `impress-helix` | library | internal | `HelixState` / `FfiHelixEditor::handle_key` is a keystroke state machine, UI only |
| `impress-identifiers` | ffi | internal | Swift-only `*_ffi` shims over `im-identifiers` (the gap is `im-identifiers`' row) |
| `impress-keymap` | kit-pure | internal | R2: declares every GUI chord as data (`Chord`, `Binding`, the coverage test); no capability of its own — `keymap_json` is exported by `impress-store-ffi`, not this crate |
| `impress-layout` | library | covered-through | `impress-layout-service` exposes the D8 verbs over it |
| `impress-layout-service` | verb-crate | verb-crate | |
| `impress-mcp` | binary | should-be-verb | `tools::{tool_search_papers, tool_get_paper_chunks, tool_list_indexed_papers}` and `render_pdf_page` are hand-written MCP tools outside the inventory (ADR-0024 D7) |
| `impress-mcp-host` | glue/inventory | internal | hosts the inventory for an in-process MCP client |
| `impress-memory-service` | verb-crate | verb-crate | |
| `impress-pane-query` | kit-pure | covered-through | the pane-query algebra `layout-service` verbs take as arguments |
| `impress-parsers-service` | verb-crate | verb-crate | |
| `impress-plot` | library | should-be-verb | `render::{LinePlot::render, Hist2DFigure::render, ContourFigure::render}` are reached only through a project figure build; no spec-to-SVG/Typst verb |
| `impress-py` | library | internal | the P6 Python binding: `list_verbs()`/`call(verb, args)`; no capability of its own, it reaches a verb another crate already holds |
| `impress-remarkable` | library | covered-through | `imbib-eink-service` reaches it through `imbib-core::eink`; `rm::parse_rm` (strokes of a page) has no verb |
| `impress-scenario` | library | covered-through | `impress-scenario-service` exposes validate/interpret over it |
| `impress-scenario-service` | verb-crate | verb-crate | |
| `impress-service-core` | glue/inventory | internal | runtime types of the macro pipeline |
| `impress-service-macros` | glue/inventory | internal | the proc macros |
| `impress-settings` | library | covered-through | `settings-service` (in `impress-store-service`) exposes the registry, its files and the generated pane; the registry itself is data |
| `impress-smart-search` | library | covered-through | `smart-search-service` exposes it; `url_extract::extract_title` only indirectly |
| `impress-smart-search-service` | verb-crate | verb-crate | |
| `impress-sources` | library | should-be-verb | `SourcePlugin::{search, fetch_by_doi}` for arXiv, Crossref, ADS, OpenAlex, PubMed, Semantic Scholar have no Rust verb; `search_sources` refuses when the app is down |
| `impress-store-ffi` | ffi | internal | `SharedStore::{upsert_item, upsert_items, add_reference, set_parent, delete_item}` are Swift-only generic writes; `store-service` has the per-kind verbs |
| `impress-store-service` | verb-crate | verb-crate | |
| `impress-surface` | library | covered-through | `impress-surface-service` exposes plan/resolve/reduce over it |
| `impress-surface-service` | verb-crate | verb-crate | |
| `impress-tags` | library | should-be-verb | `query::{parse_tag_query, TagQuery::matches}` and `TagHierarchy::{from_tags, children_of, descendants_of}` have no verb; nothing browses by tag expression |
| `impress-toolbox` | binary | internal | `execute::{handle_execute, handle_execute_file}` run a local command — deliberately unsandboxed, deliberately no verb |
| `impress-verb-surface` | kit-pure | covered-through | `capabilities-service` exposes `verb_surface`/`catalogue` as `verb-surface`/`catalogue-surface` (ADR-0035 D2) |
| `impress-workflow` | library | covered-through | `impress-workflow-service` exposes the spec, validator and planner |
| `impress-workflow-service` | verb-crate | verb-crate | |
| `impress-workspace-hack` | tooling | internal | the generated cargo-hakari crate: dependency glue, no code (plan-verb-pipeline-and-transport § Build cost, B4) |
| `imprint-cli` | binary | internal | the CLI binary over the inventory |
| `imprint-core` | domain-core | should-be-verb | reached by `imprint-service` through `{project, render, latex, citations, presentation}`; `sourcemap::{generate_source_map, source_map_lookup}` and ≈22 `uniffi::export` items have no verb (`selection` is UI-bound and correctly internal) |
| `imprint-selftest` | verb-crate | verb-crate | |
| `imprint-service` | verb-crate | verb-crate | |
| `imprint-verbs-ffi` | ffi | internal | imprint's native app dispatcher over its service inventory; no independent capability |
| `perf-service` | verb-crate | verb-crate | |
| `scix-client-ffi` | ffi | should-be-verb | `scix_search`, `scix_count`, `scix_fetch_{references, citations, similar, coreads}` — the ADS citation graph, 19 exports, all Swift-only |
| `surface-demo-service` | verb-crate | verb-crate | |
| `uniffi-bindgen` | tooling | internal | the bindgen binary |
| `vw-domain` | library | covered-through | `vw-diagnostic-service` exposes it |
| `vw-impress-adapter` | verb-crate | verb-crate | |
| `vw-mcp` | binary | internal | a standalone MCP binary over the same verbs |
| `vw-service` | library | internal | holds the `vw-diagnostic-service` trait; the verbs are emitted by `vw-impress-adapter`'s impl block |
<!-- verb-coverage-crates:end -->

### The internal binding-tell (G6)

Table 5's rule for "should be a verb" (appendix A5, above) names the tell for
a gap: "a function with two or three bindings (Swift, Python, a private MCP
server) and zero verbs". `scripts/check-verb-coverage.sh` enforces the
converse of that reflex on every `internal` row: a `pub fn`/`impl` under
`crates/<name>/src` marked with `#[uniffi::export]`, `#[pyfunction]` /
`#[pymodule]`, or an HTTP route registration (`.route(`) *is* a binding, so an
`internal` crate that has one is either wrong (its capability is
agent-facing and belongs in the inventory) or already justified — an `ffi` /
`service-http` role crate (the binding is the crate's whole job), or one of
the five rows below, each with a reason the binding does not make it
agent-facing. Adding an `internal` crate here without moving or explaining it
is what the check is for; the table is the only way past it, the same shape
as `docs/kit-manifest.md`'s open findings.

<!-- verb-coverage-internal-bindings:begin -->
| Crate | Binding | Reason |
|---|---|---|
| `impel-tools` | `#[uniffi::export]` | projects the inventory into impel's agent loop; the binding is the glue itself, not a second capability |
| `impress-py` | `#[pyfunction]`/`#[pymodule]` | the P6 Python binding: `list_verbs()`/`call(verb, args)` project the linked inventory into a Python process; the binding is the glue itself, not a second capability |
| `impress-ai-http` | `.route(` | the HTTP transport of `impress-ai-service`'s chat completion, mirrored not duplicated (D-A above) |
| `impress-helix` | `#[uniffi::export]` | `HelixState`/`FfiHelixEditor::handle_key` crosses to Swift because it is a keystroke state machine bound to a live editor buffer — rule (b) excludes it regardless of the binding |
| `impress-mcp-host` | `.route(` | hosts the linked inventory for an in-process MCP client; the route serves verbs already in the census, not a new capability |
| `impress-toolbox` | `.route(` | `execute::{handle_execute, handle_execute_file}` run a local command over its own server — deliberately unsandboxed, deliberately outside the inventory |
| `impress-service-core` | `.route(` | the pipeline's app transport router invokes the registered verb inventory; it defines no independent capability |
<!-- verb-coverage-internal-bindings:end -->

## How each check enforces it

| Check | What it proves | How it fails |
|---|---|---|
| `crates/impress-capabilities/tests/census.rs` | Every service in the linked `full` inventory has a row whose counts match; no row names an unlinked service — except a service whose crate is `optional-feature` in the crates table, which is allowed to sit unmatched when this build did not turn its feature on (P3c step 2); every workspace member has a verdict; a crate holding a linked `impress_service_impl!` block is `verb-crate` (or `optional-feature`) and no other crate is; the shape histogram and Total row match exactly for a `--features semantic-search` build, the doc's own recorded convention; at most 20 crates are `should-be-verb`. `cargo test -p impress-capabilities --features semantic-search --test census -- --nocapture dump` prints the tables as they should read now. | A list of the stale rows, each with its replacement. |
| `scripts/check-verb-coverage.sh` | Without a build: every workspace member has a row with a known verdict (`verb-crate`, `covered-through`, `internal`, `should-be-verb`, `optional-feature`), every `impress_service_impl!` block under `crates/*/src` names a service that has a row, the `should-be-verb` count is at most the ceiling, and no `internal` crate outside an `ffi`/`service-http` role or the internal-binding table above has gained a `#[uniffi::export]`, `#[pyfunction]`/`#[pymodule]` or `.route(` binding (G6, the tell of table 5/A5). `--self-test` feeds the binding classifier known-good and known-bad fixtures. | `FAIL: …` per problem. Exit 1. |
