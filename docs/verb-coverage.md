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
`description` (argument `///` lines); *Strict* the verbs of services declared
`strict_args = true`. When the inventory moves, the census test fails and
prints the row as it should now read.

<!-- verb-coverage-services:begin -->
| Service | Crate | Verbs | Real description | Args (required) | Args described | Strict |
|---|---|---:|---:|---:|---:|---:|
| `collection-service` | impress-store-service | 12 | 12 | 25 (22) | 0 | 0 |
| `docs-import-service` | impress-store-service | 10 | 10 | 38 (22) | 0 | 0 |
| `imbib-annotations-service` | imbib-service | 9 | 9 | 27 (15) | 0 | 0 |
| `imbib-app-service` | imbib-service | 17 | 17 | 24 (19) | 0 | 0 |
| `imbib-artifacts-service` | imbib-service | 9 | 9 | 36 (14) | 0 | 0 |
| `imbib-backup-service` | imbib-service | 6 | 6 | 8 (7) | 0 | 0 |
| `imbib-eink-service` | imbib-service | 22 | 22 | 35 (15) | 0 | 0 |
| `imbib-library-service` | imbib-service | 44 | 44 | 81 (62) | 0 | 0 |
| `imbib-manuscripts-service` | imbib-service | 7 | 7 | 9 (8) | 0 | 0 |
| `imbib-scix-service` | imbib-service | 7 | 7 | 17 (15) | 0 | 0 |
| `imbib-search-service` | imbib-service | 10 | 10 | 23 (18) | 0 | 0 |
| `imbib-tags-service` | imbib-service | 10 | 10 | 20 (14) | 0 | 0 |
| `imbib-text-service` | imbib-service | 5 | 5 | 7 (4) | 0 | 0 |
| `imbib-undo-service` | imbib-service | 3 | 3 | 3 (3) | 0 | 0 |
| `impart-service` | impart-service | 10 | 10 | 22 (14) | 0 | 0 |
| `impel-service` | impel-service | 6 | 6 | 6 (6) | 0 | 0 |
| `implore-service` | implore-service | 20 | 20 | 26 (13) | 8 | 0 |
| `impress-ai-service` | impress-ai-service | 16 | 16 | 25 (19) | 0 | 0 |
| `impress-bridges-service` | impress-bridges-service | 18 | 18 | 30 (29) | 0 | 0 |
| `impress-surface-service` | impress-surface-service | 15 | 15 | 33 (18) | 16 | 15 |
| `imprint-app-service` | imprint-service | 15 | 15 | 29 (22) | 0 | 0 |
| `imprint-manuscript-service` | imprint-service | 17 | 17 | 34 (34) | 0 | 0 |
| `imprint-project-service` | imprint-service | 30 | 30 | 97 (47) | 0 | 0 |
| `imprint-selftest-service` | imprint-selftest | 1 | 1 | 1 (1) | 0 | 0 |
| `imprint-text-service` | imprint-service | 5 | 5 | 11 (11) | 0 | 0 |
| `imprint-throughline-service` | imprint-service | 9 | 9 | 16 (16) | 0 | 0 |
| `layout-selftest-service` | impress-layout-service | 1 | 1 | 1 (1) | 0 | 0 |
| `layout-service` | impress-layout-service | 36 | 36 | 184 (83) | 26 | 36 |
| `manuscript-collab-service` | impress-store-service | 4 | 4 | 8 (8) | 0 | 0 |
| `memory-service` | impress-memory-service | 7 | 7 | 20 (20) | 0 | 0 |
| `parsers-service` | impress-parsers-service | 6 | 6 | 9 (9) | 0 | 0 |
| `smart-search-service` | impress-smart-search-service | 10 | 10 | 28 (28) | 0 | 0 |
| `source-service` | impress-store-service | 9 | 9 | 21 (10) | 0 | 0 |
| `store-query-service` | impress-store-service | 4 | 4 | 8 (8) | 0 | 0 |
| `surface-demo-service` | surface-demo-service | 2 | 2 | 4 (4) | 0 | 0 |
| `surface-selftest-service` | impress-surface-service | 1 | 1 | 1 (1) | 0 | 0 |
| `triage-service` | impress-store-service | 5 | 5 | 10 (8) | 0 | 0 |
| `vw-diagnostic-service` | vw-impress-adapter | 15 | 15 | 24 (20) | 0 | 0 |
| **Total** | 16 crates, 38 services | **433** | **433** | **1001 (668)** | **50** | **51** |
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
| `array-of-objects` | 3 |
| `array-of-scalars` | 49 |
| `inline-object` | 4 |
| `map` | 2 |
| `other` | 3 |
| `ref-object` | 40 |
| `scalar` | 900 |
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

`implore-stats` and `implore-selection` have zero callers in the workspace
(C-2); they are listed as the plan found them, `should-be-verb` and `internal`,
and the implore owner decides between verbs and deletion.

<!-- verb-coverage-crates:begin -->
| Crate | Role | Verdict | Reason / uncovered capabilities |
|---|---|---|---|
| `im-bibtex` | library | should-be-verb | `parser::{parse, parse_with_options, parse_entry}` and `formatter::{format_entry, format_entries}` have no verb; `import_bibtex` ingests but does not return parsed entries; ships its own MCP server (`src/mcp.rs`) and Python bindings outside the inventory |
| `im-identifiers` | library | should-be-verb | `validators::{is_valid_doi, is_valid_arxiv_id, is_valid_isbn, normalize_doi, normalize_arxiv_id}` and `resolver::{identifier_url, identifier_display_name}` have no verb; own MCP server and Python bindings outside the inventory |
| `imbib-cli` | binary | internal | the CLI binary over the inventory |
| `imbib-core` | domain-core | should-be-verb | reached by `imbib-service` through `ImbibStore` (48 of 180 methods); RIS parse/format/import/export, `merge_publications`, the reference-filter grammar and ≈170 of 259 `uniffi::export` items have no verb |
| `imbib-service` | verb-crate | verb-crate | |
| `imbib-service-http` | service-http | internal | the HTTP adapter of `imbib-service` for a running app; no capability of its own |
| `impart-core` | domain-core | should-be-verb | `provenance::queries::{trace_lineage, trace_effects, artifact_history, decision_history, …}` have no verb; `impart-service` calls nothing in it |
| `impart-service` | verb-crate | verb-crate | |
| `impart-service-http` | service-http | internal | the HTTP adapter of `impart-service`; no capability of its own |
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
| `implore-service-http` | service-http | internal | the HTTP adapter of `implore-service`; no capability of its own |
| `implore-stats` | library | should-be-verb | `Ecdf::{from_data, quantile, five_number_summary}`, `SummaryStats::{from_data, zscore, robust_zscore, winsorize}` have no verb and zero callers (C-2) |
| `impress-ai` | domain-core | should-be-verb | `registry::{complete, stream}` (direct completion), `set_model_enabled`, `set_task_category` have no verb; `queue_message` only enqueues a turn |
| `impress-ai-http` | binary | internal | HTTP transport for impress-ai chat |
| `impress-ai-service` | verb-crate | verb-crate | |
| `impress-ai-tools` | glue/inventory | internal | a third force-link list beside `impress-capabilities` (recorded in the pipeline plan) |
| `impress-app-client` | library | internal | `ImprintClient` selftest probes; the same data has store-service and imprint verbs |
| `impress-bibtex` | ffi | internal | Swift-only `*_ffi` shims over `im-bibtex` (the gap is `im-bibtex`'s row) |
| `impress-bridges-service` | verb-crate | verb-crate | |
| `impress-capabilities` | glue/inventory | internal | the one linked inventory |
| `impress-capabilities-kit` | glue/inventory | internal | the kit's slice of the inventory |
| `impress-cli` | binary | internal | the CLI binary over the inventory |
| `impress-collab` | library | internal | `Permissions::{can_view, can_comment, can_edit, can_share}` and `PresenceInfo` are per-session state, not agent capability |
| `impress-core` | library | covered-through | the store every service crate persists into; `sync` (CloudKit-style outbox) is Swift-only and correctly so; `maintenance` and `task_schema_migration` have no verb |
| `impress-domain` | library | should-be-verb | `citation_reference::{create_citation_reference, citation_to_typst, citation_to_latex, create_citation_batch}` are Swift-only |
| `impress-embeddings` | library | should-be-verb | `ChunkIndex::{search, search_scoped}` reach agents only through `impress-mcp`'s hand-written `search_papers` / `get_paper_chunks` |
| `impress-flags` | library | should-be-verb | `query::{parse_flag_query, FlagQuery::matches}` and `parse::parse_flag_command` have no verb |
| `impress-git` | library | should-be-verb | `commands::{status_cmd, commit_cmd, log_cmd, diff_cmd, push_cmd, pull_cmd, clone_cmd}` and the porcelain parsers have no verb |
| `impress-helix` | library | internal | `HelixState` / `FfiHelixEditor::handle_key` is a keystroke state machine, UI only |
| `impress-identifiers` | ffi | internal | Swift-only `*_ffi` shims over `im-identifiers` (the gap is `im-identifiers`' row) |
| `impress-layout` | library | covered-through | `impress-layout-service` exposes the D8 verbs over it |
| `impress-layout-service` | verb-crate | verb-crate | |
| `impress-mcp` | binary | should-be-verb | `tools::{tool_search_papers, tool_get_paper_chunks, tool_list_indexed_papers}` and `render_pdf_page` are hand-written MCP tools outside the inventory (ADR-0024 D7) |
| `impress-mcp-host` | glue/inventory | internal | hosts the inventory for an in-process MCP client |
| `impress-memory-service` | verb-crate | verb-crate | |
| `impress-pane-query` | kit-pure | covered-through | the pane-query algebra `layout-service` verbs take as arguments |
| `impress-parsers-service` | verb-crate | verb-crate | |
| `impress-plot` | library | should-be-verb | `render::{LinePlot::render, Hist2DFigure::render, ContourFigure::render}` are reached only through a project figure build; no spec-to-SVG/Typst verb |
| `impress-remarkable` | library | covered-through | `imbib-eink-service` reaches it through `imbib-core::eink`; `rm::parse_rm` (strokes of a page) has no verb |
| `impress-service-core` | glue/inventory | internal | runtime types of the macro pipeline |
| `impress-service-macros` | glue/inventory | internal | the proc macros |
| `impress-smart-search` | library | covered-through | `smart-search-service` exposes it; `url_extract::extract_title` only indirectly |
| `impress-smart-search-service` | verb-crate | verb-crate | |
| `impress-sources` | library | should-be-verb | `SourcePlugin::{search, fetch_by_doi}` for arXiv, Crossref, ADS, OpenAlex, PubMed, Semantic Scholar have no Rust verb; `search_sources` refuses when the app is down |
| `impress-store-ffi` | ffi | internal | `SharedStore::{upsert_item, upsert_items, add_reference, set_parent, delete_item}` are Swift-only generic writes; `store-service` has the per-kind verbs |
| `impress-store-service` | verb-crate | verb-crate | |
| `impress-surface` | library | covered-through | `impress-surface-service` exposes plan/resolve/reduce over it |
| `impress-surface-service` | verb-crate | verb-crate | |
| `impress-tags` | library | should-be-verb | `query::{parse_tag_query, TagQuery::matches}` and `TagHierarchy::{from_tags, children_of, descendants_of}` have no verb; nothing browses by tag expression |
| `impress-toolbox` | binary | internal | `execute::{handle_execute, handle_execute_file}` run a local command — deliberately unsandboxed, deliberately no verb |
| `imprint-cli` | binary | internal | the CLI binary over the inventory |
| `imprint-core` | domain-core | should-be-verb | reached by `imprint-service` through `{project, render, latex, citations, presentation}`; `sourcemap::{generate_source_map, source_map_lookup}` and ≈22 `uniffi::export` items have no verb (`selection` is UI-bound and correctly internal) |
| `imprint-selftest` | verb-crate | verb-crate | |
| `imprint-service` | verb-crate | verb-crate | |
| `imprint-service-http` | service-http | internal | the HTTP adapter of `imprint-service`; no capability of its own |
| `scix-client-ffi` | ffi | should-be-verb | `scix_search`, `scix_count`, `scix_fetch_{references, citations, similar, coreads}` — the ADS citation graph, 19 exports, all Swift-only |
| `surface-demo-service` | verb-crate | verb-crate | |
| `uniffi-bindgen` | tooling | internal | the bindgen binary |
| `vw-domain` | library | covered-through | `vw-diagnostic-service` exposes it |
| `vw-impress-adapter` | verb-crate | verb-crate | |
| `vw-mcp` | binary | internal | a standalone MCP binary over the same verbs |
| `vw-service` | library | internal | holds the `vw-diagnostic-service` trait; the verbs are emitted by `vw-impress-adapter`'s impl block |
<!-- verb-coverage-crates:end -->

## How each check enforces it

| Check | What it proves | How it fails |
|---|---|---|
| `crates/impress-capabilities/tests/census.rs` | Every service in the linked `full` inventory has a row whose counts match; no row names an unlinked service; every workspace member has a verdict; a crate holding a linked `impress_service_impl!` block is `verb-crate` and no other crate is; the shape histogram matches; at most 20 crates are `should-be-verb`. `cargo test -p impress-capabilities --test census -- --nocapture dump` prints the tables as they should read now. | A list of the stale rows, each with its replacement. |
| `scripts/check-verb-coverage.sh` | Without a build: every workspace member has a row with a known verdict, every `impress_service_impl!` block under `crates/*/src` names a service that has a row, and the `should-be-verb` count is at most the ceiling. | `FAIL: …` per problem. Exit 1. |
