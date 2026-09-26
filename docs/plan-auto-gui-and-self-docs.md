# Plan: an automatic GUI, self-documentation and profiling layer over the verb inventory

**Status:** PROPOSED 2026-09-26 — an evaluation and a plan, no production code. Written on a worktree of
main at 3222f573 (waves 7 and 8 merged). Every number below was measured from a linked inventory or a
script over the source; nothing is sampled unless a table says so.
**Decision record:** [ADR-0035-generated-verb-surfaces-and-docs.md](ADR-0035-generated-verb-surfaces-and-docs.md).
**Depends on:** [plan-verb-pipeline-and-transport.md](plan-verb-pipeline-and-transport.md) /
[ADR-0034](ADR-0034-verb-descriptor-pipeline-and-transport.md) — the shared descriptor, the invoker
pipeline, the verb lifecycle and the one transport. This plan generates from that descriptor; it cannot
start before ADR-0034's P1 (the descriptor) and P2 (the pipeline) have landed, and its safety and
profiling packages read what P2 records. The order is stated in both plans.
**Builds on:** ADR-0033 (agent surfaces, D3/D4/D7), ADR-0024 (one inventory, two renderings — its D3 and
D8 are asks this plan also needs), wave 7 T5/T6 (codes, strictness, `wire_version`), the `doc_wire.rs`
pattern (`crates/impress-surface-service/tests/doc_wire.rs`) and the Tier A / Tier B self-test pattern
(`crates/imprint-selftest`, `crates/impress-layout-service/src/tier_a.rs`,
`crates/impress-surface-service/src/tier_a.rs`).

## Goal (Tom)

Every `#[impress_method]` already generates the MCP tool, the CLI subcommand and impel's tool from one
definition. Make the same definition generate, with zero per-verb hand work: (1) a GUI for every verb
(a form from the input schema, a Run button, a result view; a searchable catalogue), (2) active
documentation (a reference page per verb whose examples run, and run as tests), (3) the same for the
GUI layer's own verbs, so the layout and surface layers document and operate themselves, and (4) a
profile for every verb composition, with no per-verb work (addendum). The question is whether this
gives **all** the Rust libraries in impress a consistent and complete way to become self-documenting;
if not, what exactly is missing and what closes the gap.

## The answer in one paragraph

Yes for the inventory, no for the libraries, and the descriptor is the gap. Every one of the 433
linked verbs can be given a generated form today (347 fully typed, 86 with a raw-JSON field, none
impossible by shape), but the descriptor carries only name, description, input schema and handler:
no output schema (results render as raw JSON, and 90% of return types already derive `JsonSchema`
unused), no safety class (MCP's `readOnlyHint`/`destructiveHint`/`idempotentHint`/`openWorldHint` are
never emitted; 32 verbs are destructive and 58 do not say so in their name or doc), no example (305
verbs are named in no document, example or test) and no grouping (ADR-0024's primary set is a table in
the server). Those fields can be derived for most of the inventory and declared for the rest, each with
a test that fails when missing, and that is ADR-0034's descriptor. Below the inventory, "crate has no
verb" hides two different things: of the 58 non-verb crates, 7 are fully covered through a service
crate, 31 are correctly internal (binaries, HTTP backends, FFI projections, plumbing) and 20 hold
capabilities a researcher or agent should be able to call and cannot — most visibly the ones that
already have a Swift, Python or private-MCP binding and no verb. Profiling has the same shape: a span in
the invoker is nearly free (≤ 5 µs, table P2) and covers MCP, CLI, impel and surface sources, but the
GUI's own hot path never runs the invoker, so the one place every read passes is the store. The clean
design is one descriptor both `McpToolDescriptor` and `CliSubcommand` project from (ADR-0034), a
generator in a new pure kit crate, a coverage check that reads the inventory against a declared
exception table, and a span at the invoker plus one at each of five I/O seams. Recommendation: **go,
with named prerequisites** (§ Recommendation).

## What "complete" means (testable)

1. **Every verb has a form.** `verb_surface(name)` returns a valid `SurfaceSpec` for every descriptor
   in the linked inventory; a test iterates the inventory and runs `surface_validate` on each with zero
   errors. Today: 0 of 433 (no generator).
2. **Every verb has a reference page** — description, argument table, result shape, safety class, at
   least one example — generated from the descriptor; a test fails for any verb whose page would carry
   the `Invoke X.y` fallback, an undescribed argument or no example. Today: 54 fallback descriptions,
   951 of 1001 arguments undescribed, 305 verbs with no example anywhere.
3. **Every example runs.** Each example is executed headlessly as a Tier A capability against a scratch
   store and its result validated against the output schema; one that needs an app, the network or a
   device is marked and runs in Tier B. Today: hand-written Tier A code names 67 verbs; prose names 77.
4. **Every verb has a safety class** and MCP `annotations` are emitted from it; a test fails for a verb
   with none. Today: no field; `impress-mcp/src/surface.rs:213` publishes name, description,
   `inputSchema` only.
5. **Every result renders** through the vocabulary without a raw-JSON fallback for the shapes table 3
   gives a widget; a test asserts each verb's output schema maps to one. Today: no output schema; the
   MCP transport re-shapes non-objects (`envelope_structured_content`) and nothing else does.
6. **Library coverage holds the line.** A check reads the linked inventory and a marker table in this
   repository listing crates and items that are deliberately not verbs, and fails when a public
   capability is in neither. Today: no such check; the 20 should-be-verb crates in table 5 are invisible.
7. **Every verb has a profile.** A span per invoker and per I/O seam, one aggregator whose rows have
   `PerfBucketStat`'s fields, a verb that returns them, budgets on the descriptor checked by Tier A on
   the examples. Today: 0 spans in 74 crates.
8. **The GUI layer dogfoods.** The catalogue, the verb form, the surface browser and the layout
   inspector are surfaces generated or composed from the inventory, stored as `impress/ui/surface@1.0.0`
   rows; none needs a Swift view.

## Measurements

**How.** The inventory was read from a linked binary: an integration test in `impress-capabilities`
(`full`) that calls `force_link()` and dumps every `McpToolDescriptor` (name, description,
`input_schema()`) and every `CliSubcommand`, so the counts are what `impress-mcp` and `impress-cli`
link, not what a grep finds. Facts a descriptor does not carry (return type, Rust argument types,
`strict_args`, crate) were taken by parsing every `impress_service_impl!` block under `crates/` and
joined by tool name; the join is exact both ways (433 = 433, zero unmatched). Argument shapes were
classified from the published JSON schema. Safety classes, result shapes and library coverage were
assigned by reading the implementation of every verb and every crate (file:line evidence in the
appendices), then spot-checked by the author against source. The full-inventory build linked and ran
here — the `ort-sys` block the brief anticipated did not occur, because `impress-capabilities`'s
`memory` feature does not enable `vector-embedder` (`crates/impress-cli/Cargo.toml:28`) — so nothing
was measured through the kit alone and nothing is unmeasured for that reason. The measurement tests
were throwaway and are not committed; work package G0 makes the census a permanent check.

### Re-verified starting facts

| Fact in the brief | Measured 2026-09-26 on 3222f573 | Where |
|---|---|---|
| 467 `#[impress_method]`s across 20 crates | **433 verbs, 38 services, 16 crates** in the linked `full` inventory. A strict `^\s*#\[impress_method` over `crates/*-service/src` finds exactly 433; looser greps over all of `crates/` find 452–467 depending on whether doc-comment mentions, tests, `examples/echo_demo.rs`, `impress-mcp`'s own docs and `imprint-selftest` are counted. The brief's number was a grep. `apps/impel-tui` is the 74th workspace member; 73 are under `crates/` | `McpToolDescriptor::iter()` with `full`; `cargo metadata` |
| 53 crates expose no verb | **58 of 74 workspace members** (57 of the 73 under `crates/`) | table 5 |
| No output schema, no safety metadata | Confirmed: `McpToolDescriptor {name, description, input_schema, handler}`, `CliSubcommand {name, qualified_name, description, input_schema, apply}` | `crates/impress-service-core/src/lib.rs:170,249` |
| The macro's doc claims uniffi/pyo3 shims; the code emits neither | Confirmed: `lib.rs:43` promises them; `expand_method` emits an args struct, a schema fn, an invoker and two `inventory::submit!`s. The only Python bindings are `crates/im-bibtex/src/python.rs` (8 functions) and `crates/im-identifiers/src/python.rs` (19), and both crates also ship their own MCP servers (`src/mcp.rs`) outside the inventory | `crates/impress-service-macros/src/lib.rs:384-544` |
| Argument `///` docs become schema descriptions (a2dc8a17) | Confirmed and barely used: **50 of 1001 arguments** are described (layout 26, surface 16, implore 8) | table 1 |
| Wave 7 made verbs strict, opt-in | **2 of 38 services**: `layout-service` (36 verbs) and `impress-surface-service` (15); 51 of 433 strict | `impress-layout-service/src/service.rs:2705`, `impress-surface-service/src/service.rs:1134` |
| The surface vocabulary as listed | Confirmed; no list-input field, no record picker, no confirm affordance, no file picker | `docs/agent-surfaces.md` § Vocabulary, `impress-surface/src/spec.rs` |
| Some verbs take whole JSON values as one argument | 49 arguments do: `PaneRefWire` ×21, whole specs ×3, `PaneQuery`, `PaneSpec` ×2, `Event`, the state object, 13 named DTOs | table 1b |

Also found while verifying: four MCP tools are hand-written in `impress-mcp` and not in the inventory
(`search_papers`, `get_paper_chunks`, `list_indexed_papers`, `render_pdf_page`; `server.rs:566-640`),
which ADR-0024 D7 lists as outstanding; the grouped projection's primary set is a declared table of 30
names (`surface.rs:39-78`), which ADR-0024 D3 says should be an attribute on the method; and
`crates/impress-ai-tools` keeps a third force-link list beside `impress-capabilities` and
`impress-capabilities-kit` (recorded in the pipeline plan).

### Table 1 — inventory census, per service

| Service | Crate | Verbs | Real description | Args (required) | Args described | Strict | Form a / b | Safety R / M / D / X | Named in a doc or example | Named in a test |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `imbib-annotations-service` | imbib-service | 9 | 7 | 27 (15) | 0 | 0 | 9 / 0 | 5 / 3 / 1 / 0 | 1 | 0 |
| `imbib-app-service` | imbib-service | 17 | 17 | 24 (19) | 0 | 0 | 13 / 4 | 0 / 0 / 0 / 17 | 3 | 0 |
| `imbib-artifacts-service` | imbib-service | 9 | 6 | 36 (14) | 0 | 0 | 8 / 1 | 5 / 3 / 1 / 0 | 0 | 0 |
| `imbib-backup-service` | imbib-service | 6 | 6 | 8 (7) | 0 | 0 | 6 / 0 | 2 / 1 / 2 / 1 | 0 | 0 |
| `imbib-eink-service` | imbib-service | 22 | 22 | 35 (15) | 0 | 0 | 18 / 4 | 7 / 7 / 1 / 7 | 0 | 0 |
| `imbib-library-service` | imbib-service | 44 | 16 | 81 (62) | 0 | 0 | 34 / 10 | 25 / 16 / 3 / 0 | 6 | 0 |
| `imbib-manuscripts-service` | imbib-service | 7 | 7 | 9 (8) | 0 | 0 | 7 / 0 | 0 / 0 / 0 / 7 | 2 | 0 |
| `imbib-scix-service` | imbib-service | 7 | 0 | 17 (15) | 0 | 0 | 5 / 2 | 4 / 3 / 0 / 0 | 0 | 0 |
| `imbib-search-service` | imbib-service | 10 | 5 | 23 (18) | 0 | 0 | 9 / 1 | 9 / 1 / 0 / 0 | 3 | 0 |
| `imbib-tags-service` | imbib-service | 10 | 6 | 20 (14) | 0 | 0 | 8 / 2 | 4 / 5 / 1 / 0 | 1 | 0 |
| `imbib-text-service` | imbib-service | 5 | 5 | 7 (4) | 0 | 0 | 5 / 0 | 5 / 0 / 0 / 0 | 0 | 2 |
| `imbib-undo-service` | imbib-service | 3 | 3 | 3 (3) | 0 | 0 | 3 / 0 | 1 / 2 / 0 / 0 | 0 | 0 |
| `impart-service` | impart-service | 10 | 10 | 22 (14) | 0 | 0 | 10 / 0 | 0 / 0 / 0 / 10 | 4 | 0 |
| `impel-service` | impel-service | 6 | 6 | 6 (6) | 0 | 0 | 6 / 0 | 4 / 1 / 1 / 0 | 0 | 0 |
| `implore-service` | implore-service | 20 | 20 | 26 (13) | 8 | 0 | 18 / 2 | 0 / 0 / 0 / 20 | 10 | 0 |
| `impress-ai-service` | impress-ai-service | 16 | 16 | 25 (19) | 0 | 0 | 13 / 3 | 6 / 5 / 0 / 5 | 0 | 0 |
| `impress-bridges-service` | impress-bridges-service | 18 | 18 | 30 (29) | 0 | 0 | 17 / 1 | 5 / 1 / 0 / 12 | 4 | 0 |
| `layout-selftest-service` | impress-layout-service | 1 | 1 | 1 (1) | 0 | 0 | 1 / 0 | 0 / 0 / 0 / 1 | 0 | 1 |
| `layout-service` | impress-layout-service | 36 | 36 | 184 (83) | 26 | 36 | 15 / 21 | 6 / 23 / 7 / 0 | 1 | 4 |
| `memory-service` | impress-memory-service | 7 | 7 | 20 (20) | 0 | 0 | 6 / 1 | 3 / 3 / 1 / 0 | 2 | 0 |
| `parsers-service` | impress-parsers-service | 6 | 6 | 9 (9) | 0 | 0 | 6 / 0 | 6 / 0 / 0 / 0 | 0 | 6 |
| `smart-search-service` | impress-smart-search-service | 10 | 10 | 28 (28) | 0 | 0 | 8 / 2 | 10 / 0 / 0 / 0 | 0 | 10 |
| `collection-service` | impress-store-service | 12 | 12 | 25 (22) | 0 | 0 | 9 / 3 | 3 / 7 / 2 / 0 | 0 | 12 |
| `docs-import-service` | impress-store-service | 10 | 10 | 38 (22) | 0 | 0 | 8 / 2 | 2 / 5 / 3 / 0 | 0 | 0 |
| `manuscript-collab-service` | impress-store-service | 4 | 4 | 8 (8) | 0 | 0 | 2 / 2 | 3 / 1 / 0 / 0 | 0 | 0 |
| `source-service` | impress-store-service | 9 | 9 | 21 (10) | 0 | 0 | 5 / 4 | 3 / 4 / 0 / 2 | 2 | 6 |
| `store-query-service` | impress-store-service | 4 | 4 | 8 (8) | 0 | 0 | 4 / 0 | 4 / 0 / 0 / 0 | 4 | 4 |
| `triage-service` | impress-store-service | 5 | 5 | 10 (8) | 0 | 0 | 5 / 0 | 0 / 5 / 0 / 0 | 3 | 5 |
| `impress-surface-service` | impress-surface-service | 15 | 15 | 33 (18) | 16 | 15 | 8 / 7 | 9 / 5 / 1 / 0 | 15 | 5 |
| `surface-selftest-service` | impress-surface-service | 1 | 1 | 1 (1) | 0 | 0 | 1 / 0 | 0 / 0 / 0 / 1 | 0 | 1 |
| `imprint-selftest-service` | imprint-selftest | 1 | 1 | 1 (1) | 0 | 0 | 1 / 0 | 0 / 0 / 0 / 1 | 0 | 0 |
| `imprint-app-service` | imprint-service | 15 | 15 | 29 (22) | 0 | 0 | 15 / 0 | 0 / 0 / 0 / 15 | 6 | 0 |
| `imprint-manuscript-service` | imprint-service | 17 | 12 | 34 (34) | 0 | 0 | 15 / 2 | 13 / 2 / 2 / 0 | 8 | 0 |
| `imprint-project-service` | imprint-service | 30 | 30 | 97 (47) | 0 | 0 | 27 / 3 | 10 / 13 / 4 / 3 | 0 | 0 |
| `imprint-text-service` | imprint-service | 5 | 5 | 11 (11) | 0 | 0 | 5 / 0 | 5 / 0 / 0 / 0 | 0 | 0 |
| `imprint-throughline-service` | imprint-service | 9 | 9 | 16 (16) | 0 | 0 | 8 / 1 | 3 / 4 / 2 / 0 | 0 | 0 |
| `surface-demo-service` | surface-demo-service | 2 | 2 | 4 (4) | 0 | 0 | 1 / 1 | 2 / 0 / 0 / 0 | 2 | 2 |
| `vw-diagnostic-service` | vw-impress-adapter | 15 | 15 | 24 (20) | 0 | 0 | 8 / 7 | 8 / 6 / 0 / 1 | 0 | 9 |
| **Total** | 16 crates, 38 services | **433** | **379** | **1001** (668) | **50** | **51** | **347 / 86** | **172 / 126 / 32 / 103** | **77** | **67** |

Argument shapes across all 1001 arguments:

| Argument shape (from the published schema) | Arguments | Widget in the vocabulary |
|---|---:|---|
| scalar | 900 | field text / number / toggle |
| array-of-scalars | 49 | none (no list-input field) — raw JSON |
| ref-object | 39 | none — raw JSON |
| inline-object | 4 | none — raw JSON |
| array-of-objects | 3 | none — raw JSON |
| other | 3 | none (an `allOf`-wrapped `$ref`) — raw JSON |
| map | 2 | none — raw JSON |
| tagged-union | 1 | none — raw JSON |

Named types behind `ref-object`: `PaneRefWire` ×21, `PaneSpec` ×2, `EinkDeviceInput` ×1, `SourceCitationInput` ×1, `FigureRegionInput` ×1, `ContentChunkInput` ×1, `ExtractionRunInput` ×1, `PaneQuery` ×1, `Geometry` ×1, `SectionMetadata` ×1, `CompileOptions` ×1, `RecordMeasurementCommand` ×1, `RecordObservationCommand` ×1, `CreateSessionRequest` ×1, `CloseSessionCommand` ×1, `RecordProcedureStepCommand` ×1, `StartProcedureCommand` ×1, `OpenAIFile` ×1. Rust argument types across the inventory: `String` 460, `Option<String>` 271, `Vec<String>` 45, `u32` 41, `bool` 38, `i64` 25, `PaneRefDto` 19 (+2 `Option`), and 24 others with ≤ 8 uses each. Required 668, optional 333.

Appendix A1 has the per-verb row for all 433 verbs.

### Table 2 — form fitness

A generated form maps each argument to a `field`: `string` → text, `integer`/`number` → number,
`boolean` → toggle, an `enum` → select, a `date` format → date. Anything else has no field kind and
becomes a raw-JSON text field, which is what the CLI already does for the same shapes
(`crates/impress-service-core/src/cli.rs:211`: "Anything else (object, complex enum, untyped). The CLI
accepts a raw JSON string"), so class b is the CLI's precedent, not a compromise invented here.

| Class | Verbs | Reason |
|---|---:|---|
| a — every argument maps to a field widget | 347 | scalars, booleans, enums; includes 38 zero-argument verbs (a Run button alone) |
| b — one raw-JSON field for: array-of-scalars | 42 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: ref-object | 31 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: array-of-objects | 2 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: array-of-scalars, ref-object | 2 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: other | 2 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: inline-object | 2 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: array-of-objects, inline-object | 1 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: ref-object, tagged-union | 1 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: map | 1 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: map, other | 1 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| b — one raw-JSON field for: array-of-scalars, inline-object | 1 | the CLI takes the same shapes as a JSON string (`cli.rs:211`) |
| c — not a form by shape | 0 | — |
| c′ — a form runs, but not headlessly or not to completion in one call | 83 need a running app; 53 take seconds or more | these are semantic, not shape, limits: see § Completeness |

What pushes verbs out of class a, in order: **id lists** (`Vec<String>` of record ids — `ids`,
`publication_ids`, `item_ids`, `tags`, `cite_keys` — 42 verbs; a generated form would want the ids to
come from a selection, which is exactly what a surface `param` and `{{state.selected}}` provide, see
§ Consistency), the **pane reference** (`PaneRefWire`, 21 layout verbs: exactly one of `{"id"}`,
`{"role"}`, `{"direction"}`, `{"focused": true}` — a select-of-four plus one field, if the generator
special-cases this one named type), and **whole documents** (a surface spec, a `PaneSpec`, a
`PaneQuery`, an `Event`, the state object, implore's `PlotSpec`, the vw command DTOs — raw JSON is the
honest widget). Zero verbs are unusable by shape. The semantic class c′ is the safety table's
`needs_app` (83) and `long_running` (53) columns.

### Table 3 — result fitness

| Result shape (of the Rust return type) | Types | Verbs | Best widget with an output schema | What a renderer gets today (no schema) |
|---|---:|---:|---|---|
| envelope | 96 | 168 | kv (status line + fields), kv+table when it carries a list | the object unchanged; `ok`/`message` visible only if the type has them |
| list-of-records | 42 | 67 | table | `{"items": [...]}` over MCP, a bare array over CLI/HTTP/Swift |
| flat-object | 35 | 87 | kv | the object unchanged |
| nested-object | 29 | 33 | kv + nested table, or raw JSON | the object unchanged, nested arrays inline |
| string | 2 | 35 | text | `{"value": …}` over MCP, bare over the rest |
| list-of-scalars | 2 | 10 | list | `{"items": [...]}` over MCP |
| scalar | 2 | 33 | status (bool) / kv | `{"value": …}` over MCP, bare over the rest |

| Best widget | Types | Verbs |
|---|---:|---:|
| kv | 83 | 167 |
| status | 16 | 77 |
| table | 41 | 63 |
| kv+table | 45 | 50 |
| text | 7 | 41 |
| raw-json | 7 | 13 |
| list | 2 | 10 |
| image | 4 | 6 |
| log | 1 | 4 |
| plot | 2 | 2 |

- Output schema derivable today (the type derives `JsonSchema`): **172 of 208 types, 390 of 433 verbs**. The 36 types that do not: every `impress-ai-service`, `impel-service`, `smart-search-service` and `parsers-service` result and the `imprint-service` `handlers.rs`/`sections.rs` DTOs (43 verbs; one derive each).
- Carry `ok` + `message`: 83 types / 144 verbs. Carry `wire_version`: 20 types / 51 verbs — exactly the layout and surface DTOs. 28 verbs return `MutationResult {ok, affected_count}` with no message; `impress-ai-service` results carry `error` only; the vw and eink results carry `ok` + `error`.
- "Special" results a generic view cannot show as-is: 48 types / 135 verbs — file paths (backups, compiled PDFs, exports), inline SVG strings (`rg-cascade-plot`, `plot-series`, `project-render-figure`), JSON serialised inside a string (`payload_json`, `tree_json`, `anchor_map_json`, six `rg_*` verbs), `_mcp_content` image blocks (`get-page-image`, `get-figure-image`, vw photos), whole page or section bodies, a `RenderTree` or `SurfaceSpec` (needs the surface renderer itself), raw bytes as a number array (`export-document`). No verb returns a stream.

Appendix A3 lists all 208 return types.

### Table 4 — safety

| Crate | Read-only | Mutating | Destructive | External (also M / D / R) | Needs app | Long-running | Not obvious from name or doc |
|---|---:|---:|---:|---:|---:|---:|---:|
| imbib-service | 67 | 41 | 9 | 32 (12 / 7 / 13) | 24 | 18 | 20 |
| impart-service | 0 | 0 | 0 | 10 (6 / 0 / 0) | 9 | 0 | 0 |
| impel-service | 4 | 1 | 1 | 0 (0 / 0 / 0) | 0 | 0 | 0 |
| implore-service | 0 | 0 | 0 | 20 (2 / 1 / 0) | 19 | 7 | 7 |
| impress-ai-service | 6 | 5 | 0 | 5 (1 / 0 / 0) | 2 | 5 | 3 |
| impress-bridges-service | 5 | 1 | 0 | 12 (5 / 1 / 0) | 12 | 4 | 6 |
| impress-layout-service | 6 | 23 | 7 | 1 (1 / 0 / 0) | 0 | 1 | 5 |
| impress-memory-service | 3 | 3 | 1 | 0 (0 / 0 / 0) | 0 | 0 | 1 |
| impress-parsers-service | 6 | 0 | 0 | 0 (0 / 0 / 0) | 0 | 0 | 0 |
| impress-smart-search-service | 10 | 0 | 0 | 0 (0 / 0 / 0) | 0 | 0 | 0 |
| impress-store-service | 15 | 22 | 5 | 2 (0 / 0 / 0) | 0 | 4 | 3 |
| impress-surface-service | 9 | 5 | 1 | 1 (1 / 0 / 0) | 0 | 4 | 2 |
| imprint-selftest | 0 | 0 | 0 | 1 (1 / 0 / 0) | 0 | 1 | 1 |
| imprint-service | 31 | 19 | 8 | 18 (8 / 4 / 0) | 17 | 8 | 9 |
| surface-demo-service | 2 | 0 | 0 | 0 (0 / 0 / 0) | 0 | 0 | 0 |
| vw-impress-adapter | 8 | 6 | 0 | 1 (1 / 0 / 0) | 0 | 1 | 1 |
| **Total** | **172** | **126** | **32** | **103** (38 / 13 / 13) | **83** | **53** | **58** |

Idempotent: 372 of 433. Classes were assigned from the default implementation's code path, with the HTTP path noted where it differs; the per-verb evidence (file:line) is in appendix A4.

Findings the classification surfaced (evidence in appendix A4): all three imbib `*_undoable` verbs drop
the undo snapshot on the store path (`library_service.rs:770 Ok(_) => ok_n(1)`) and the HTTP path's
undo reaches only the GUI's ⌘Z; `deduplicate-library` hard-deletes the duplicate rows
(`store_api.rs:2581`); `dismiss-paper` inserts a tombstone row, moves nothing to Dismissed and has no
inverse verb; `import-papers` says "fetches metadata from external sources" and parses the BibTeX the
caller supplied; five implore verbs are dead on the wire (`plot-histogram`, `plot-series`,
`rg-statistics`, `rg-slice-raw`, `rg-slice-png`: Rust POSTs, Swift serves GET —
`implore-service-http/src/lib.rs:324-393` vs `ImploreHTTPRouter.swift:126-145`); the three
`run-selftest` verbs mutate the running app's store in tier b; `apply-layout`, `apply-preset` and
`commit` wipe both undo rings; `memory-service_forget` has no un-hide; `update-comment` overwrites
through `store.update` while its siblings use `update_with_undo`.

### Table 5 — library coverage

| Role | Crates | Covered | Should be a verb | Internal |
|---|---:|---:|---:|---:|
| library | 25 | 6 | 11 | 8 |
| binary | 10 | 0 | 2 | 8 |
| glue/inventory | 7 | 0 | 0 | 7 |
| domain-core | 6 | 0 | 6 | 0 |
| ffi | 4 | 0 | 1 | 3 |
| service-http | 4 | 0 | 0 | 4 |
| kit-pure | 1 | 1 | 0 | 0 |
| tooling | 1 | 0 | 0 | 1 |
| **All non-verb crates** | **58** | **7** | **20** | **31** |

Reached by a verb crate's dependency graph: 30 of 58; reached by an actual call site in a `*-service` crate (verified file:line): 35; on no verb path at all: 23. The 16 verb crates themselves are covered by definition; imbib-service reaches `imbib-core` through one type, `ImbibStore` (48 of its 180 methods called), imprint-service through `imprint_core::{project, render, latex, citations, presentation}`, implore-service calls one `implore-core` function (the rest is HTTP), impart-service calls nothing in `impart-core`.

**The rule that decides "should be a verb".** A `pub` function or method is a capability when (a) it is
callable with serde-shaped inputs (strings, ids, paths, JSON specs) and returns serde-shaped output,
(b) it needs no live UI handle, editor buffer, key event, subscription stream or per-device sync
cursor, and (c) it needs no secret the agent should not hold (IMAP/SMTP credentials, CloudKit tokens,
an unsandboxed shell). Everything that meets (a)–(c) reaches agents through a `*-service` crate or is
listed as internal with a reason. The tell for a gap is a function with two or three bindings (Swift,
Python, a private MCP server) and zero verbs: BibTeX parse/format, identifier validation, RIS,
`merge_publications`, the reference-filter grammar, tag hierarchy, plot rendering, provenance queries,
the SciX citation graph (`scix-client-ffi`, 19 exports, all Swift-only), semantic paper search
(`impress-mcp`'s own hand-written tools), and `impel-server`'s HTTP API, which is an agent API that
bypasses the inventory entirely. FFI-only counts: imbib-core ≈170 of 259 `uniffi::export` items have
no verb, impress-store-ffi ≈70, imprint-core ≈22, impress-domain 19.

**How CI holds the line** (G6): a marker table in this file's sibling `docs/verb-coverage.md`, read by
a script the way `docs/kit-manifest.md`'s tables are read by `check-kit-deps.sh` — one row per crate
with a tier (`verb-crate`, `covered-through`, `internal`, `should-be-verb`) and, for `covered-through`
and `internal`, the `pub` items that are deliberately not verbs with a reason. The check fails when a
crate is missing from the table, when an `internal` row's item gains a Swift/Python/MCP binding (the
tell above), or when a `should-be-verb` row's count of listed items goes up. Appendix A5 is the first
draft of that table.

### Table 6 — doc coverage

| Where a verb is named | Verbs |
|---|---:|
| tests | 67 |
| guide.md | 56 |
| agent-surfaces.md | 21 |
| *.surface.json | 5 |
| in at least one doc or example (not counting tests) | 77 |
| nowhere — no doc, example or test names it | 305 |

Could an example run headlessly as Tier A (no app, no network, no device)? By the safety table, 327 verbs are neither `needs_app` nor `external`; the other 106 need Tier B (a running app, the network, a device or a subprocess). Existing runnable examples: `doc_wire.rs` (15 surface verbs), the layout Tier A catalogue, the surface Tier A catalogue, imprint's 25 Tier A capabilities (`imprint-selftest/src/tier_a.rs`), and per-crate tests that call descriptors by name (67 verbs in all).

## Profiling (addendum 1)

### P1 — `log` vs `tracing` today

Only six of 74 crates depend on either facade; there are **zero** `tracing` spans and zero
`#[instrument]` in the workspace. The workspace pins `tracing 0.1` and `tracing-subscriber 0.3`
(`Cargo.toml:288-289`) and nothing on a verb path uses them.

| Crate | `log` dep | `tracing` dep | `log` calls | `tracing` calls | spans |
|---|:-:|:-:|---:|---:|---:|
| impress-layout-service | yes (`Cargo.toml:41`) | | 16 | 0 | 0 |
| impress-surface-service | yes (`:46`) | | 4 | 0 | 0 |
| impress-store-ffi | yes (`:80`) | | 18 | 0 | 0 |
| impel-server | | yes (`:45`) | 0 | 9 | 0 |
| impress-toolbox | | yes (`:19`) | 0 | 9 | 0 |
| apps/impel-tui | | yes (`:36`) | 0 | 0 | 0 |
| the other 68 crates | | | 0 | 0 | 0 |

Subscribers: `tracing_subscriber::fmt::init()` in three binaries (impel-server, impel-tui,
impress-toolbox); the wave-7 bridge `impress-store-ffi/src/log_bridge.rs:106-121` installs a `log`
logger that forwards **only** records of target `layout` or `surface` to Swift's `ImpressLogging` as
`(level, category, message)` — no fields, no durations. Nothing in Rust records a verb duration; the
nearest are `duration_ms` on AI run records (`impress-ai/src/executor.rs:288,406`) and the self-test
timers. De facto logging elsewhere is `eprintln!` (impel-taskd 59 sites, im-bibtex 17, imbib-service 12).
`impress-service-core`, where the macro runtime lives, depends on neither facade.

### P2 — the cost of a span per verb (measured)

Release build, 2000 iterations after warm-up, in-memory store, one thread; the aggregating layer is a
20-line `tracing_subscriber::Layer` that records wall time per span name into a map (the shape a perf
aggregator has); the fmt layer writes span-close events to a sink.

| Verb | bare | span, no subscriber | span + aggregating layer | span + fmt layer |
|---|---:|---:|---:|---:|
| `imbib-text-service_decode-latex` | 12.0 µs | 11.6 µs | 12.3 µs | 15.2 µs |
| `surface-demo-service_series` (n=16) | 0.8 µs | 1.0 µs | 1.0 µs | 3.6 µs |
| `layout-service_get-layout` | 10.8 µs | 11.8 µs | 16.7 µs | 19.5 µs |
| `layout-service_get-pane` | 23.5 µs | 16.1 µs | 17.8 µs | 18.7 µs |
| `store-query-service_list-items` | 14.5 µs | 11.7 µs | 13.5 µs | 14.5 µs |

Run-to-run noise is of the same order as the differences (get-pane's "bare" is the slowest column);
the honest reading is **≤ 5 µs per verb, ≤ 3 µs with the aggregator alone**, against verbs that cost
10–25 µs on an empty store and milliseconds on a real one. A span per invoker is not a performance
decision.

### P3 — where the GUI's time actually goes: the invoker is not on the hot path

The GUI never runs `__impress_*_invoke`. Swift's per-keystroke and per-render calls are UniFFI methods
that reach the service structs and the store directly: `SharedLayout::run_pane` (`store-ffi/src/layout.rs:504`
→ `self.store.query` `:520`, per list-pane page), `::pane` (`:469`, per pane per reload), `::snapshot`
(`:458`), `::apply`/`apply_all` (`:590/:599` → `apply_verb_as`, every chord and outline click),
`SharedSurface::render` / `dispatch` (`surface.rs:626/654`), `SharedStore::query_items`/`count_items`/
`get_item`/`search` (`lib.rs:1157-1260`). The invoker covers MCP, the CLI, impel-tools and the surface
runtime's verb sources and `call` effects — every agent path, no human path. So "a span around every
invoker" profiles agents; profiling the person needs the seams.

### P4 — the I/O seams, and how many it takes

| Seam | Chokepoint | One span covers it? | Reached from service crates |
|---|---|---|---|
| Store reads | `SqliteItemStore::with_read` `sqlite_store.rs:748` (→ `ReaderPool::with_reader` `:194`); every `query`, `count`, `get`, `neighbors`, `query_raw`, FTS goes through it | **yes** | `.query(` 66 sites / 23 files, `.query_raw(` 18 / 10 |
| Store writes | no wrapper: `conn: Mutex<Connection>` locked at 14 sites; `apply_operation_on` `:2149` covers the four `apply_operation*` entry points, `insert`/`insert_batch`/`update`/`delete` `:5041-5142` lock separately | **no — two spans** (`apply_operation_on` + a new `with_write`) | `.apply_operation(` 15 / 11, `.update(` 79 / 16, `.delete(` 35 / 20 |
| Sibling-app HTTP | `impress-app-client` has no request fn: 146 `.send()` sites; only the response decoders `transport.rs:17,47` are shared. implore/impart clients have 3–4 helpers each | **no today** — one span once ADR-0034 P5's single transport exists | all `*-service-http` |
| Blob store | `impress_core::blobs::BlobStore::{put, get, get_ref}` `:77/:109/:118`; imprint's wrapper `blob_store.rs:84/98`; `impress_ai::blob` trait `:21` | **yes, three spans** | 42 sites |
| AI provider | `InferenceProvider::stream` `impress-ai/src/provider.rs:46` (`complete :51` folds it); exits at `registry.rs:660/672`, `executor.rs:299,516` | **yes** (one decorator provider) | — |
| Typst / LaTeX | four `engine.compile` sites (`imprint-core/src/render.rs:907,1254`, `project/typst.rs:219`, `render_project.rs:95`) plus three PDF exports; tectonic in `spawn_blocking` | **no — four spans**, or one at `compile_typst_dispatch` `imprint-service/src/handlers.rs:717` | — |
| Others | tantivy `imprint-service/src/search.rs:230`; embeddings `impress-embeddings/src/semantic.rs:208`; reMarkable `usb_web.rs` five async fns; git `Command::new` at 8 sites; filesystem scans scattered (backup 13, source_assets 10, project build 16) | one each for the first three; the rest stay uncovered | — |

**Answer: eight spans** (store read, two store writes, blob, AI, Typst dispatch, tantivy, embeddings)
split every verb's time into I/O and compute for everything but filesystem scans, git and the device;
those three are `external` verbs whose whole time is the seam, so a verb-level span is enough for them.
The sibling-HTTP seam waits for the one transport.

### P5 — where a span loses context

Non-test sites: `spawn_blocking` 28 sites in 15 files, `std::thread::spawn` 11 in 10, rayon 7 (all
`implore-core/src/noise.rs`), `tokio::spawn` 12 in 9, `block_on` 98 in 24 (31 through
`impress_service_core::runtime::block_on`, 22 `runtime().block_on` in the FFI). On verb paths: (1) the
Swift→Rust root: every UniFFI export in `store-ffi/src/layout.rs:642-798` and `ai_registry.rs:1020-1076`
is `runtime().block_on(...)` — a fresh root span per call, which is right; (2) the surface verb-host hop
loses context three times in one call — `runtime.rs:405 spawn_blocking(host.call_verb)` → the FFI
adapter `surface.rs:335` → Swift `ImpressVerbHost.callVerb` → `impel_tools::call_tool:320` →
`block_on:351` → the invoker → `*-service-http` → HTTP; (3) `spawn_blocking` inside verbs: imprint
compile (`manuscript_service.rs:471`, `project_service.rs:2710,3131`), `impress-ai/blocking.rs:35,98`,
eink; (4) MCP stdio: the reader thread `server.rs:202` and `block_on(handler)` `:282`; (5) cross-process
HTTP to a sibling app carries no trace id. `Span::current()` capture plus `.instrument()` closes (2)–(4)
inside a process; (5) needs a `traceparent` header on the one transport (ADR-0034 P5) so the app-side
span nests under the caller's; the MCP stdio boundary stays a root by design.

### P6 — Swift's table, to be unified with

`PerfBucketStat` (`packages/ImpressLogging/.../PerfMetrics.swift:47-75`): `name, count, totalNanos,
minNanos, maxNanos, mainThreadCount, p50Nanos, p95Nanos, budgetNanos?, breachCount` (+ derived millis
and `mainThreadShare`); a 1024-sample ring, nearest-rank percentiles, a budget breach logs a Console
warning (`:265-270`). `GET /api/performance` is one shared handler
(`SharedAutomationRoutes.swift:272-299`) served by all six apps, answering `{status, capturedAt,
bucketCount, buckets: [{name, count, mainThreadCount, mainThreadShare, minMillis, meanMillis, p50Millis,
p95Millis, maxMillis, breachCount, totalNanos, budgetMillis?}]}`; `GET /api/performance/reset` (a
mutation on GET — recorded as a security finding in the pipeline plan). A Rust aggregator that keeps
exactly these fields per bucket, keyed `verb:<name>` and `io:<seam>`, and a `perf_summary` verb whose
result is this JSON, makes the Console's Performance tab show Rust and Swift rows in one table with no
second schema; `mainThreadCount` is 0 for Rust rows (the FFI is off the main actor since wave 7 T2).

### P7 — what a span must never record

No verb takes a secret (credentials are FFI-only: `store-ffi/src/ai_registry.rs:886
configure_credentials`). Private prose reaches verbs as `body` (8 verbs), `text` (7), `source` (12
imprint Typst/LaTeX verbs), `content`/`contents`/`selected_text`, `notes` (3), `html` (2),
`system_prompt`, `bibtex`, `query` (17 search verbs), `find`/`replace`, `value` (3). The rule the
pipeline enforces by construction: the span records the verb name, `ok`, `code`, the byte length of the
argument object and of the result, and the values of arguments whose schema description or type marks
them as ids (`*_id`, `ids`, `cite_key`, `section_key`, `revision`); nothing else. Strict refusals return
`Ok(refusal_value)` (`macro lib.rs:472`), so `ok`/`code` are read from the result JSON, not from `Err`.

### P8 — findings (profiling)

- **PF-1.** No span, no timer and no duration exists on any verb path (P1). *Fix:* the pipeline's span
  layer (ADR-0034 P2).
- **PF-2.** The GUI's hot path bypasses the invoker (P3). *Fix:* spans at the store seams (P4) and at
  the FFI roots, not a second invoker.
- **PF-3.** Store writes have no chokepoint (P4). *Fix:* a `with_write` wrapper in `sqlite_store.rs`
  that the 14 lock sites call — the same refactor the review's RL-L14 wanted for other reasons.
- **PF-4.** The surface verb host loses trace context three times per call (P5). *Fix:* capture
  `Span::current()` before `spawn_blocking`, and a trace id through `SharedVerbHost::callVerb`'s
  arguments (a string; no UniFFI type change).
- **PF-5.** `impress-service-core` has no logging facade, so the invoker cannot even log today. *Fix:*
  add `tracing` to it (workspace dep exists) — or `log` plus `tracing-log`, per the decision below.
- **PF-6.** `/api/performance/reset` mutates on GET (P6). Recorded in the pipeline plan's security
  package.
- **PF-7.** The `log`-only crates (`layout-service`, `surface-service`, `store-ffi`) and the
  `tracing`-only binaries cannot see each other's records. *Decision for Tom* (D-P1 below).

## Findings

Ids: G (generated GUI and docs), C (coverage), S (safety), R (results), D (docs), PF (profiling, above).
Each has its one-line fix and the package that owns it.

- **G-1** (descriptor). `McpToolDescriptor`/`CliSubcommand` carry no output schema, safety, examples,
  group, version (`service-core/src/lib.rs:170,249`). *Fix:* ADR-0034 P1's `VerbDescriptor`; this plan
  consumes it.
- **G-2** (macro). The macro accepts a method with no doc (`collect_doc` returns `""`, `lib.rs:87,300`),
  which is how 54 verbs ship `Invoke X.y`. *Fix:* `syn::Error` on an empty doc (5 lines; G1).
- **G-3** (macro doc). `lib.rs:43` claims uniffi/pyo3 shims the code does not emit. *Fix:* delete the
  line; Python is decided in the pipeline plan (§ Python there).
- **G-4** (arguments). 951 of 1001 arguments have no description. *Fix:* the reference generator fails
  for an undescribed argument (G3); the descriptions are a one-time pass over 36 services (sized in
  G3's gate: 38 files, ~950 `///` lines).
- **G-5** (shapes). 42 verbs take an id list that a form cannot collect; 21 take a `PaneRefWire`. *Fix:*
  the generator maps `Vec<String>` args named `ids`/`*_ids` to the surface's `param`/selection (a
  composed form, § Consistency) and `PaneRefWire` to a four-way select — both inside the generator, no
  vocabulary change; a real list-input field is ask-first D-G3.
- **G-6** (primary/grouping). The 30-name `PRIMARY` table and the `DOMAINS` prefix table in
  `impress-mcp/src/surface.rs:39-97` are the catalogue's grouping, declared in the server. *Fix:*
  ADR-0024 D3 (`surface` and `group` on the descriptor); the catalogue reads them (G4).
- **C-1** (coverage). 20 non-verb crates hold should-be-verb capabilities (table 5, appendix A5);
  `impel-server` is a whole agent HTTP API outside the inventory; `im-bibtex`/`im-identifiers` ship
  private MCP servers. *Fix:* the coverage table and check (G6); the verbs themselves are follow-on
  service work, one package per crate, not this plan's.
- **C-2** (coverage). `implore-stats` and `implore-selection` have zero callers in the workspace. *Fix:*
  list as `internal` with reason or delete; a decision for the implore owner, recorded in G6's table.
- **S-1** (safety). 32 destructive and 103 external verbs carry no annotation; 58 verbs' class is not
  obvious from name or doc (appendix A4). *Fix:* `safety` on the descriptor from a per-service default
  plus a name convention (`get-`/`list-`/`count-`/`find-`/`query-` → read-only, `delete-`/`purge-`/
  `prune-`/`forget-` → destructive) checked against table 4 by a test that fails on disagreement (G2).
- **S-2** (safety). The three `*_undoable` verbs are not undoable on the store path
  (`library_service.rs:770`). *Fix:* keep the snapshot and write an operation row, or rename — ask-first
  D-G5 (a rename).
- **S-3** (safety). Five implore verbs are dead on the wire (POST vs GET). *Fix:* the one transport
  (ADR-0034 P5) removes the mismatch class; until then, flip the five Rust calls to GET with query
  params — a one-line fix each in `implore-service-http/src/lib.rs:324-393`.
- **S-4** (safety). `run-selftest --tier b` mutates the running app; `apply-layout`/`apply-preset`/
  `commit` wipe both undo rings; `memory-service_forget` has no inverse; `dismiss-paper` and
  `deduplicate-library` are irreversible. *Fix:* class them destructive in the table (done) so the
  generated form's review step applies; the behaviours are findings for their owners.
- **R-1** (results). 36 return types (43 verbs) do not derive `JsonSchema`. *Fix:* one derive each (G2's
  gate lists them).
- **R-2** (results). Results speak four envelopes: `{ok, code?, message, wire_version}` (51 verbs),
  `{ok, message}` (93 more), `{ok, affected_count}` (28), `{error}` / `{ok, error}` / `{success,
  error}` / `{accepted, reason}` (the rest). *Fix:* the generator renders whichever is present; making
  wave 7's envelope universal is ask-first D-G6.
- **R-3** (results). 135 verbs return something a generic view cannot show as-is (paths, inline SVG,
  JSON-in-a-string, `_mcp_content`, bodies). *Fix:* the generator maps `_mcp_content` → `image`, an
  `svg`-named string → `image {url: data:}`, a `*_json` string → a parsed `kv`, a path → `text` with an
  `open` action only where a verb exists to read it; anything else is `text` of the JSON.
- **D-1** (docs). 305 verbs are named nowhere; 77 in prose; the two docs that are tested cover 15 and 0
  verbs. *Fix:* generated reference pages (G3) replace hand-written per-verb prose; `guide.md` keeps its
  workflows and gains a test that every name it uses resolves (as `agent-surfaces.md` has).
- **D-2** (docs). `guide.md` documents the four hand-written MCP tools and impel is "no impel tools
  here" while `impel-service` has 6. *Fix:* the generated catalogue is the list; `guide.md` links it.

## Design

### Completeness

With G1–G7 landed, every verb in the linked inventory gets a form, a page and a profile row with zero
per-verb hand work, **except** for four classes that a request/response form cannot serve alone:

| Class | Verbs | What covers it instead |
|---|---:|---|
| Needs a running app (`needs_app`) | 83 | The generated form still renders; its Run button's `call` fails in the source "by name" (ADR-0033 D4 amendment) with `host-unavailable`, shown in the result `status`. The reference page marks the class. Tier B runs the example. |
| Long-running (compile, sync, device, AI, subprocess) | 53 | The job convention of ADR-0034 P4: the form's Run returns a job handle; a `status` widget follows it through the same `surface_wait`; cancel is a second button. Until P4, the form blocks for the verb's duration, as MCP does today. |
| Needs a selection made elsewhere (id lists) | 42 | A composed form: the generated form declares a `param` of the id's kind and binds `ids` to `{{param.selected}}` / `{{state.selected}}`, so the human picks in a list pane on the channel and the form fans out with `each` — the paper-triage pattern, generated. |
| Needs a native affordance (file picker, drag-in, PDF view, editor) | 11 (paths in: `import-directory`, `project-checkin`, `restore-backup`, `rg-load`, `render_pdf_page`…; the `pdf`/`source` view kinds out) | Not a form. A text field holding a path is what the CLI offers and the form offers the same; the native picker is a Swift concern outside this plan (ask-first D-G3 lists the file picker as the one widget worth asking for). |

Libraries: table 5 says which crates are covered through a service, which are correctly internal, and
which 20 are not covered; the plan does not write their verbs, it makes the gap visible and holds it
(G6). "Every Rust capability that should be agent-facing gets a GUI and a page" therefore becomes true
by construction for the inventory, and true by policy plus a CI check for the libraries.

### Consistency: one generator, composition around it

One generator (`verb_surface`) is enough for classes a and b and for every zero-argument verb. Two verb
families need a composed surface, and both are compositions *around* the generated form, never a
second description of the verb: (1) id-list verbs (above) — the generator itself emits the param-bound
form when it sees an `ids`-shaped argument; (2) verb *sequences* that are one human task (find → import
→ tag; compile → render page), which an agent authors as an ordinary surface whose `call` actions name
the verbs — the generated per-verb form is the starting point (`surface_get` of the generated spec,
edit, `surface_create`), and the composed spec still validates every literal argument against the verb's
own schema (wave 7 T6a), so it cannot drift from the verb. Where they meet: the catalogue lists both the
generated surfaces (tagged `generated`, never stored — regenerated on read, § Where it lives) and stored
hand-composed ones; a hand-composed surface that names a verb whose schema changed fails validation on
its next `surface_update`, which is the drift check. Renderer neutrality: the generator writes
`SurfaceSpec` only; the Swift renderer, an HTML renderer or MCP Apps map the same `RenderTree`
(ADR-0033 D2). Nothing here puts logic in a renderer.

### Descriptor shape

Owned by ADR-0034 P1; this plan states what it needs from it and where each field comes from
("derived" wins; every declared field has a check that fails when missing):

| Field | Source | Check |
|---|---|---|
| `output_schema: fn() -> Value` | derived: `schema_for!(Ret)`; the macro adds the bound | compile error for the 36 types without `JsonSchema` (R-1) |
| `safety: Safety {class, idempotent, long_running, needs_app}` | per-service default in `impress_service_impl! { safety = read_only }` + method attribute for exceptions; `needs_app` derived from the service's `BackendSlot` use | a test compares the linked inventory against appendix A4's table (committed as `docs/verb-safety.md`, marker-table style) and fails on any disagreement; a name-convention lint fails when a `delete-*` is not destructive |
| `examples: &'static [Example]` | declared beside the method (`#[impress_example(name, args = json!(…), expect = …)]`) or registered by the service's Tier A catalogue through the same descriptor | a test fails for a verb with zero examples; Tier A runs each |
| `group`, `surface` (primary/grouped) | derived from the crate name; `surface` per ADR-0024 D3 | `surface_tests::every_primary_tool_exists` moves onto the field |
| `since`, `deprecated`, `aliases` | ADR-0034 P3 | there |
| `budget_ms: Option<u32>` | declared, optional | Tier A fails an example that breaches it |
| `arg docs` | already in the schema (`description`) | the reference generator fails on an undescribed argument (G-4) |

### Examples as tests

An example is written once, as data next to the method, and read three ways: the reference page prints
it; the generated form's `state` is prefilled from it (so "Run" on a fresh form does something
sensible); Tier A executes it against a scratch store (`SqliteItemStore::open_in_memory`, installed
through `impress_store_service::install_store`, the way `surface-service/src/tier_a.rs` does) and
validates the result against the output schema and, where the example says so, against an expected
value. An example marked `tier = b` runs against the app on the isolated port the Tier B catalogues
already use. Where it lives: on the method, because a sidecar file per service is a second place to
name the verb's arguments; the existing Tier A catalogues become examples by registering themselves
(one `inventory::submit!` of an `Example` naming the verb), so nothing already written is duplicated.
`doc_wire.rs` stays as the test of `agent-surfaces.md`'s prose; the generated pages need no such test
because they are output, not input.

### Safety in the GUI

A generated form reads the descriptor's `safety`. Read-only: Run executes. Mutating: Run executes and
the result `status` names what changed and, when the result carries one, the `revision` to undo with.
Destructive or external: the form is generated with a **review step inside the surface** — a second
`section` whose `when` gates on `state.reviewed`, showing the argument summary and a "Confirm and run"
button, and a `dry_run: true` prefill where the verb has a `dry_run`/`apply` argument (12 verbs do:
`migrate`, `prune-empty-manuscripts`, `eink-plan`, `finish-watched-scan`…). This is state, not a modal:
nothing halts the window, the human can leave the pane and come back, and an agent driving the same
surface over `surface_dispatch` passes the same two events. With ADR-0034 P2's policy layer, a
destructive verb called by an agent is queued as exactly this surface instead of run, which is how
"human review points are explicit" becomes a mechanism.

### Strictness

`strict_args = true` should become the default in this wave: a generated form can only send fields the
schema names, a reference page is only complete for a strict verb (the schema is the whole contract),
and a lenient verb's page would have to say "and ignores anything else". What breaks: the macro flag
flips for 36 services; any caller sending an extra key today is refused `invalid-argument` instead of
ignored — the callers are the four `*-service-http` adapters (whose bodies are built from the same
args), impel's tool calls (schema-driven), the surface runtime (already strict) and hand-written HTTP
routes in Swift that forward to Rust (`/api/layout/verb`, `/api/surface/*`, both strict already). The
risk is a Swift route that adds a key: G5's gate runs Tier B on all five apps after the flip. Ask-first
D-G1.

### Dogfooding

| Surface the GUI layer needs | Generated? | How |
|---|---|---|
| Catalogue (every verb, searchable, grouped) | yes | `catalogue()`: a `query`-free surface whose one source is the new read-only verb `capabilities-service_list-verbs {filter?}` (the inventory as data: name, group, description, safety, since) rendered as a `table` with `on_select` → `open` the verb form |
| Verb form | yes | `verb_surface(name)` |
| Surface browser | yes, composed | a query source over `impress/ui/surface@1.0.0` (kind already exists) in a `table`, `on_select` → `open {view_kind: surface}`; buttons call `surface_delete` (destructive → review step) and `surface_render` |
| Layout inspector | yes, composed | sources `layout-service_get-layout` (the tree as `kv` + a `list` of panes) and `layout-service_list-layouts`; buttons for `focus`, `close`, `set-view-kind` are the generated forms for those verbs embedded as sections |
| Reference pages | yes | markdown generated per verb; rendered in a `text` widget by the same catalogue when the human opens "docs" |

All four are `SurfaceSpec`s and use only existing widgets; the catalogue needs one new verb (ask-first
D-G2) because a surface computes only by calling a verb and no verb lists the inventory today
(`impress_capabilities` in MCP is a projection, not a verb).

### Where it lives

`impress-verb-surface`, a new **pure** kit crate (depends on `impress-service-core` for the descriptor
and `impress-surface` for `SurfaceSpec`; nothing else), registered in `docs/kit-manifest.md`'s table
with tier `pure`; `capabilities-service` (the `list-verbs` and `perf-*` verbs) is a store-free
`*-service` crate in `impress-capabilities-kit`. Neither reaches `impress-core`, so `check-kit-deps`
and `check-kit-standalone` pass unchanged; the generated reference pages are written by a `cargo run`
target of `impress-verb-surface` into `docs/verbs/` and CI diffs them. The one kit rule this touches:
`impress-verb-surface` gains no dependency beyond the two named, or it goes into the manifest with a
reason.

## Decisions needed from Tom (ask-first)

**All approved by Tom on 2026-09-26** (D-G5 as "make them undoable, keep the names"; D-P6 as recommended: a provider's safety claim is a floor until trusted). The list is kept as the record of what was asked.

- **D-G1.** `strict_args = true` becomes the macro default (36 services flip; § Strictness).
- **D-G2.** Three new verbs: `capabilities-service_list-verbs`, `perf-service_summary`,
  `perf-service_trace` (read-only; the catalogue and the profiler GUI cannot exist without them).
- **D-G3.** Widget asks, none designed around: a list-input `field` (would move 42 verbs to class a
  without a composed form), a record picker `field` (a selection without a second pane), a `confirm`
  affordance on `button` (a one-widget review step), a file-path picker (11 verbs). The plan works with
  the vocabulary as is; each of these is a quality-of-form ask.
- **D-G4.** `docs/verb-coverage.md` and `docs/verb-safety.md` as marker tables read by scripts, in
  the `kit-manifest.md` style (two new documents that CI treats as data).
- **D-G5.** Renaming the three `*_undoable` verbs or making them undoable (S-2) — either changes a verb.
- **D-G6.** Making wave 7's `{ok, code?, message, wire_version}` envelope universal (382 verbs' result
  shapes change) — or leaving four envelopes and rendering each.
- **D-P1.** Rust logging moves from `log` to `tracing` (three crates, 38 call sites, the Swift bridge
  re-pointed at a `tracing` layer) — or spans go in beside `log` with `tracing-log` bridging (PF-7).
- **D-P2.** Budgets on the descriptor (`budget_ms`) and Tier A failing on a breach — a test that can
  fail on a slow CI runner (the self-hosted runners are oversubscribed, `docs/self-hosted-runners.md`).

## Work packages

Prerequisite: ADR-0034 P1 (descriptor) and P2 (pipeline) merged; P3 (lifecycle) before G4 makes every
name public. Each package: one branch, one PR, the workspace gate, a session-log entry here.

| WP | Owns | Closes | Proof | Gates | Parallel with |
|---|---|---|---|---|---|
| **G0 Census check** | `crates/impress-capabilities/tests/census.rs`, `docs/verb-coverage.md`, `scripts/check-verb-coverage.sh` | table 1 and 5 become a permanent check; C-1, C-2 recorded | the test dumps the inventory and fails when a service is missing from the coverage table or a `should-be-verb` count rises | `cargo test -p impress-capabilities`, the new script in `kit.yml` | G1 |
| **G1 Macro hygiene** | `crates/impress-service-macros` | G-2, G-3, D-G1 if approved | a method with no doc fails to compile (a trybuild test); the false Python line is gone | workspace clippy, every service builds | G0 |
| **G2 Derived fields** | every `*-service` crate's result DTOs (36 derives), `docs/verb-safety.md`, per-service `safety =` defaults | R-1, S-1, S-4 | the inventory test fails on a verb with no output schema or with a safety class disagreeing with the table; MCP `annotations` emitted (`impress-mcp/src/surface.rs:213`) and pinned by `mcp_surface_parity` | full gate; MCP over stdio shows `annotations` | — (after P1) |
| **G3 Examples and reference pages** | `#[impress_example]` in the macro, `docs/verbs/` generator target, the Tier A runner in `impress-service-core::report`, argument `///` docs across 36 services | G-4, D-1, D-2 | every verb has ≥ 1 example; Tier A runs them (headless count from table 6); `docs/verbs/*.md` regenerated byte-identical in CI | `cargo test`, the docs diff | G2 |
| **G4 Generator and catalogue** | new `crates/impress-verb-surface`, `crates/capabilities-service`, `impress-capabilities-kit` registration, `docs/kit-manifest.md` row | completeness 1, 5, 8; G-5, G-6, R-3 | `verb_surface` validates for all 433; the catalogue renders headlessly (`surface_render`) and opens a form; kit-demo `--prove` opens the catalogue, runs `surface-demo-service_series` from its form and reads the result `kv` | kit checks, ImpressSurface `swift test`, Tier B on impress | G3 |
| **G5 Strict by default** | the macro flag, Tier B on five apps | D-G1 | every app's Tier B green after the flip; a Swift route adding a key is found by it | Tier B ×5 | after G1 |
| **G6 Coverage line** | `docs/verb-coverage.md` finished (appendix A5), the check's `internal` binding-tell | C-1 held | the check fails when an `internal` item gains a binding | `kit.yml` | G4 |
| **G7 Profiling** | `tracing` in `impress-service-core` (span layer in P2), eight seam spans, the aggregator (`PerfBucketStat` fields), `perf-service`, trace export (Chrome JSON from the aggregator's span log; folded stacks from parent chains), budgets on examples | completeness 7; PF-1..PF-5 | `perf_summary` after a Tier A run lists `verb:*` and `io:*` rows; the Console Performance tab shows Rust rows; a Chrome trace of one surface render opens in Perfetto | `cargo test`, the span bench stays ≤ 5 µs | G4 |

## Recommendation

**Go, with prerequisites.** The inventory side is sound: nothing in the 433 verbs resists a generated
form, 90% of results already have a derivable schema, and the span cost is noise. What is not sound is
building the generator on today's descriptor — it would have to guess safety, invent a result view and
carry no example — and publishing every verb name before names can be deprecated. So: ADR-0034 P1 and
P2 first (P3 before G4), and the CORS/loopback mitigation before any of it, since a catalogue of every
verb behind `Access-Control-Allow-Origin: *` on loopback is a catalogue for any web page. Then **G0 and
G1 together as the first package**: G0 turns this plan's tables into a check that cannot rot, and G1 is
the five-line macro change that stops the next `Invoke X.y` at compile time. The library gap (20
crates) is real and is held, not closed, by this plan.

## Session log (append-only)

- 2026-09-26 — Planned on a worktree of main at 3222f573, branch `claude/plan-auto-gui-self-docs`.
  Inventory linked and dumped (433/38/16); every `impress_service_impl!` block parsed and joined; 1001
  arguments and 208 return types classified; 433 verbs safety-classified from code; 58 crates surveyed;
  span cost measured in release; the six survey data sets cross-checked against source before use
  (implore's five dead routes, the dropped undo snapshot, the live-store counts, the `log`/`tracing`
  dependency table). Tom's addenda folded in: profiling as § Profiling here; the descriptor, pipeline,
  policy, lifecycle, long-running work, transport, Python, rules-into-construction and runtime providers
  split into `plan-verb-pipeline-and-transport.md` / ADR-0034, on which this plan depends. Not measured:
  nothing was blocked; the `ort-sys` block did not occur. Measurement tests were not committed.

## Appendix A1 — every verb

Columns: args (required); shapes (scalar / arr = array of scalars / obj = object / arr-obj); fit (a/b);
return type; safety (R read-only, M mutating, D destructive, X external, with the secondary class after
`/`); App = needs a running app; Long = long-running; Doc = where it is named (guide, surf =
agent-surfaces.md, ex = an example surface, test); Desc = `fallback` when the description is
`Invoke X.y`; Strict.

| Tool | Args (req) | Shapes | Fit | Ret | Safety | App | Long | Doc | Desc | Strict |
|---|---:|---|:-:|---|---|:-:|:-:|---|:-:|:-:|
| `collection-service_add-members` | 3 (3) | arr,scalar | b | `CollectionMutationResult` | M |  |  | test |  |  |
| `collection-service_create` | 4 (2) | scalar | a | `CollectionResult` | M |  |  | test |  |  |
| `collection-service_delete` | 2 (2) | scalar | a | `CollectionMutationResult` | D |  |  | test |  |  |
| `collection-service_member-counts` | 2 (2) | arr,scalar | b | `MemberCountsResult` | R |  |  | test |  |  |
| `collection-service_migrate` | 1 (1) | scalar | a | `MigrationReportResult` | M |  |  | test |  |  |
| `collection-service_migration-status` | 0 (0) | — | a | `MigrationStatusResult` | R |  |  | test |  |  |
| `collection-service_remove-members` | 3 (3) | arr,scalar | b | `CollectionMutationResult` | M |  |  | test |  |  |
| `collection-service_rename` | 3 (3) | scalar | a | `CollectionResult` | M |  |  | test |  |  |
| `collection-service_reorder` | 3 (3) | scalar | a | `CollectionResult` | M |  |  | test |  |  |
| `collection-service_reparent` | 3 (2) | scalar | a | `CollectionResult` | M |  |  | test |  |  |
| `collection-service_rollback` | 0 (0) | — | a | `RollbackReportResult` | D |  |  | test |  |  |
| `collection-service_tree` | 1 (1) | scalar | a | `CollectionListResult` | R |  |  | test |  |  |
| `docs-import-service_add-watched-folder` | 5 (3) | scalar | a | `WatchedFolderResult` | M |  |  | — |  |  |
| `docs-import-service_finish-watched-scan` | 5 (2) | scalar | a | `WatchedScanResult` | M |  |  | — |  |  |
| `docs-import-service_import-directory` | 5 (4) | scalar | a | `DocsImportResult` | D |  | y | — |  |  |
| `docs-import-service_import-discovered` | 3 (3) | arr-obj,scalar | b | `DiscoveredImportResult` | M |  | y | — |  |  |
| `docs-import-service_list-watched-files` | 5 (2) | scalar | a | `WatchedFileListResult` | R |  |  | — |  |  |
| `docs-import-service_list-watched-folders` | 1 (0) | scalar | a | `WatchedFolderListResult` | R |  |  | — |  |  |
| `docs-import-service_prune-empty-manuscripts` | 3 (2) | scalar | a | `PruneResult` | D |  |  | — |  |  |
| `docs-import-service_record-produced-rows` | 3 (3) | arr,scalar | b | `ProducedRowsResult` | M |  |  | — |  |  |
| `docs-import-service_remove-watched-folder` | 2 (2) | scalar | a | `WatchedFolderRemovalResult` | D |  |  | — |  |  |
| `docs-import-service_update-watched-folder` | 6 (1) | scalar | a | `WatchedFolderResult` | M |  |  | — |  |  |
| `imbib-annotations-service_count-annotations` | 1 (1) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-annotations-service_create-annotation` | 8 (3) | scalar | a | `Option<AnnotationRecord>` | M |  |  | — |  |  |
| `imbib-annotations-service_create-comment` | 5 (2) | scalar | a | `Option<CommentRecord>` | M |  |  | — |  |  |
| `imbib-annotations-service_create-comment-on-item` | 5 (2) | scalar | a | `Option<CommentRecord>` | M |  |  | — |  |  |
| `imbib-annotations-service_list-annotations` | 2 (1) | scalar | a | `Vec<AnnotationRecord>` | R |  |  | guide |  |  |
| `imbib-annotations-service_list-comments` | 1 (1) | scalar | a | `Vec<CommentRecord>` | R |  |  | — |  |  |
| `imbib-annotations-service_list-comments-for-item` | 1 (1) | scalar | a | `Vec<CommentRecord>` | R |  |  | — |  |  |
| `imbib-annotations-service_list-comments-since` | 2 (2) | scalar | a | `Vec<CommentRecord>` | R |  |  | — | fallback |  |
| `imbib-annotations-service_update-comment` | 2 (2) | scalar | a | `MutationResult` | D |  |  | — |  |  |
| `imbib-app-service_add-to-library` | 2 (2) | arr,scalar | b | `u32` | E/M | y |  | — |  |  |
| `imbib-app-service_delete-annotation` | 1 (1) | scalar | a | `bool` | E/D | y |  | — |  |  |
| `imbib-app-service_delete-collection` | 1 (1) | scalar | a | `bool` | E/D | y |  | — |  |  |
| `imbib-app-service_delete-comment` | 1 (1) | scalar | a | `bool` | E/D | y |  | — |  |  |
| `imbib-app-service_delete-smart-searches` | 1 (1) | arr | b | `u32` | E/D | y |  | — |  |  |
| `imbib-app-service_download-pdfs` | 1 (1) | arr | b | `u32` | E/M | y | y | — |  |  |
| `imbib-app-service_get-logs` | 4 (1) | scalar | a | `Vec<LogEntry>` | E/R | y |  | — |  |  |
| `imbib-app-service_get-notes` | 1 (1) | scalar | a | `Option<String>` | E/R | y |  | — |  |  |
| `imbib-app-service_open-manuscript-papers` | 1 (1) | scalar | a | `PapersWindowResult` | E/M | y |  | — |  |  |
| `imbib-app-service_recent-activity` | 2 (1) | scalar | a | `Vec<ActivityEntry>` | E/R | y |  | — |  |  |
| `imbib-app-service_resolve-identifier` | 2 (2) | scalar | a | `Option<String>` | E/M | y | y | guide |  |  |
| `imbib-app-service_search-sources` | 3 (2) | scalar | a | `Vec<ExternalPaper>` | E/R | y | y | guide |  |  |
| `imbib-app-service_status` | 0 (0) | — | a | `AppStatus` | E/R |  |  | guide |  |  |
| `imbib-app-service_sync-nudge` | 0 (0) | — | a | `SyncNudgeResult` | E/M | y | y | — |  |  |
| `imbib-app-service_sync-status` | 0 (0) | — | a | `AppStatus` | E/R | y |  | — |  |  |
| `imbib-app-service_tag-artifact` | 2 (2) | arr,scalar | b | `bool` | E/M | y |  | — |  |  |
| `imbib-app-service_update-notes` | 2 (2) | scalar | a | `bool` | E/D | y |  | — |  |  |
| `imbib-artifacts-service_count-artifacts` | 1 (0) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-artifacts-service_create-artifact` | 14 (3) | arr,scalar | b | `Option<ArtifactRecord>` | M |  |  | — |  |  |
| `imbib-artifacts-service_delete-artifact` | 1 (1) | scalar | a | `MutationResult` | D |  |  | — |  |  |
| `imbib-artifacts-service_get-artifact` | 1 (1) | scalar | a | `Option<ArtifactRecord>` | R |  |  | — |  |  |
| `imbib-artifacts-service_get-artifact-relations` | 1 (1) | scalar | a | `Vec<ArtifactRelationRecord>` | R |  |  | — | fallback |  |
| `imbib-artifacts-service_link-artifact-to-publication` | 2 (2) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `imbib-artifacts-service_list-artifacts` | 5 (4) | scalar | a | `Vec<ArtifactRecord>` | R |  |  | — |  |  |
| `imbib-artifacts-service_search-artifacts` | 2 (1) | scalar | a | `Vec<ArtifactRecord>` | R |  |  | — |  |  |
| `imbib-artifacts-service_update-artifact` | 9 (1) | scalar | a | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-backup-service_create-backup` | 2 (1) | scalar | a | `Vec<BackupRecord>` | M |  | y | — |  |  |
| `imbib-backup-service_delete-backup` | 1 (1) | scalar | a | `bool` | D |  |  | — |  |  |
| `imbib-backup-service_inspect-backup` | 1 (1) | scalar | a | `BackupInspection` | R |  | y | — |  |  |
| `imbib-backup-service_list-backups` | 1 (1) | scalar | a | `Vec<BackupRecord>` | R |  |  | — |  |  |
| `imbib-backup-service_prune-backups` | 2 (2) | scalar | a | `Vec<String>` | D |  |  | — |  |  |
| `imbib-backup-service_restore-backup` | 1 (1) | scalar | a | `RestoreReport` | E/D | y | y | — |  |  |
| `imbib-eink-service_eink-append-notes` | 2 (2) | scalar | a | `EinkAppendResult` | M |  |  | — |  |  |
| `imbib-eink-service_eink-awaiting-source` | 1 (0) | scalar | a | `Vec<EinkAwaitingSourceRecord>` | R |  |  | — |  |  |
| `imbib-eink-service_eink-complete-ocr` | 3 (2) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `imbib-eink-service_eink-configure-device` | 1 (1) | obj | b | `Option<EinkDeviceRecord>` | M |  |  | — |  |  |
| `imbib-eink-service_eink-devices` | 0 (0) | — | a | `Vec<EinkDeviceRecord>` | R |  |  | — |  |  |
| `imbib-eink-service_eink-folder-checklist` | 1 (0) | scalar | a | `Vec<EinkFolderNeedRecord>` | E/R |  | y | — |  |  |
| `imbib-eink-service_eink-import` | 2 (0) | scalar | a | `EinkSyncRecord` | E/M |  | y | — |  |  |
| `imbib-eink-service_eink-import-document` | 5 (1) | scalar | a | `EinkDocumentImportRecord` | E/M |  | y | — |  |  |
| `imbib-eink-service_eink-list-annotations` | 1 (1) | scalar | a | `Vec<AnnotationRecord>` | R |  |  | — |  |  |
| `imbib-eink-service_eink-list-mirrored` | 2 (0) | scalar | a | `Vec<EinkMirrorRecord>` | R |  |  | — |  |  |
| `imbib-eink-service_eink-list-unmatched` | 1 (0) | scalar | a | `Vec<EinkUnmatchedRecord>` | E/R |  | y | — |  |  |
| `imbib-eink-service_eink-mark` | 2 (1) | arr,scalar | b | `EinkMarkResult` | M |  |  | — |  |  |
| `imbib-eink-service_eink-note-source-error` | 3 (1) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `imbib-eink-service_eink-pending-ocr` | 1 (0) | scalar | a | `Vec<EinkOcrJobRecord>` | R |  |  | — |  |  |
| `imbib-eink-service_eink-plan` | 1 (0) | scalar | a | `EinkSyncRecord` | E/R |  | y | — |  |  |
| `imbib-eink-service_eink-reachable` | 1 (0) | scalar | a | `bool` | E/R |  | y | — |  |  |
| `imbib-eink-service_eink-remove-device` | 1 (1) | scalar | a | `MutationResult` | D |  |  | — |  |  |
| `imbib-eink-service_eink-resend` | 1 (1) | arr | b | `MutationResult` | M |  |  | — |  |  |
| `imbib-eink-service_eink-search-annotations` | 2 (2) | scalar | a | `Vec<AnnotationRecord>` | R |  |  | — |  |  |
| `imbib-eink-service_eink-status` | 0 (0) | — | a | `EinkStatusRecord` | R |  |  | — |  |  |
| `imbib-eink-service_eink-sync` | 2 (1) | scalar | a | `EinkSyncRecord` | E/M |  | y | — |  |  |
| `imbib-eink-service_eink-unmark` | 2 (1) | arr,scalar | b | `EinkMarkResult` | M |  |  | — |  |  |
| `imbib-library-service_add-linked-file` | 7 (4) | scalar | a | `Option<LinkedFileRecord>` | M |  |  | — | fallback |  |
| `imbib-library-service_add-to-collection` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | guide |  |  |
| `imbib-library-service_count-flagged` | 1 (0) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-library-service_count-pdfs` | 1 (1) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-library-service_count-publications` | 0 (0) | — | a | `u32` | R |  |  | — |  |  |
| `imbib-library-service_count-starred` | 1 (0) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-library-service_count-unread` | 1 (0) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-library-service_create-collection` | 4 (3) | scalar | a | `Option<CollectionRecord>` | M |  |  | — |  |  |
| `imbib-library-service_create-library` | 1 (1) | scalar | a | `Option<LibraryRecord>` | M |  |  | — |  |  |
| `imbib-library-service_create-muted-item` | 2 (2) | scalar | a | `Option<MutedItemRecord>` | M |  |  | — | fallback |  |
| `imbib-library-service_deduplicate-library` | 1 (1) | scalar | a | `u32` | D |  |  | — | fallback |  |
| `imbib-library-service_delete-library-undoable` | 1 (1) | scalar | a | `MutationResult` | D |  |  | — | fallback |  |
| `imbib-library-service_delete-publications-undoable` | 1 (1) | arr | b | `MutationResult` | D |  |  | guide |  |  |
| `imbib-library-service_dismiss-paper` | 4 (0) | scalar | a | `Option<DismissedPaperRecord>` | M |  |  | — | fallback |  |
| `imbib-library-service_duplicate-publications` | 2 (2) | arr,scalar | b | `Vec<String>` | M |  |  | — | fallback |  |
| `imbib-library-service_export-all-bibtex` | 1 (1) | scalar | a | `String` | R |  |  | — | fallback |  |
| `imbib-library-service_export-bibtex` | 1 (1) | arr | b | `String` | R |  |  | — |  |  |
| `imbib-library-service_get-default-library` | 0 (0) | — | a | `Option<LibraryRecord>` | R |  |  | — | fallback |  |
| `imbib-library-service_get-inbox-library` | 0 (0) | — | a | `Option<LibraryRecord>` | R |  |  | — | fallback |  |
| `imbib-library-service_get-publication` | 1 (1) | scalar | a | `Option<PublicationSummary>` | R |  |  | guide | fallback |  |
| `imbib-library-service_get-publication-detail` | 1 (1) | scalar | a | `Option<PublicationDetailRecord>` | R |  |  | guide |  |  |
| `imbib-library-service_import-bibtex` | 2 (2) | scalar | a | `Vec<String>` | M |  | y | — | fallback |  |
| `imbib-library-service_import-papers` | 2 (2) | arr-obj,scalar | b | `ImportSummary` | M |  | y | guide |  |  |
| `imbib-library-service_is-paper-dismissed` | 4 (0) | scalar | a | `bool` | R |  |  | — | fallback |  |
| `imbib-library-service_list-collection-members` | 5 (5) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — |  |  |
| `imbib-library-service_list-collections` | 1 (1) | scalar | a | `Vec<CollectionRecord>` | R |  |  | — |  |  |
| `imbib-library-service_list-dismissed-papers` | 2 (2) | scalar | a | `Vec<DismissedPaperRecord>` | R |  |  | — | fallback |  |
| `imbib-library-service_list-libraries` | 0 (0) | — | a | `Vec<LibraryRecord>` | R |  |  | — |  |  |
| `imbib-library-service_list-linked-files` | 1 (1) | scalar | a | `Vec<LinkedFileRecord>` | R |  |  | — | fallback |  |
| `imbib-library-service_list-muted-items` | 0 (0) | — | a | `Vec<MutedItemRecord>` | R |  |  | — | fallback |  |
| `imbib-library-service_list-publications` | 2 (2) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-library-service_move-publications` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-library-service_purge-dismissed-from-collection` | 1 (1) | scalar | a | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-library-service_query-publications` | 5 (5) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-library-service_query-recent` | 2 (1) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-library-service_query-starred` | 4 (3) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-library-service_query-unread` | 4 (3) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-library-service_remove-from-collection` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — |  |  |
| `imbib-library-service_search-publications` | 2 (2) | scalar | a | `Vec<PublicationSummary>` | R |  |  | guide | fallback |  |
| `imbib-library-service_set-flag` | 2 (1) | arr,scalar | b | `MutationResult` | M |  |  | — |  |  |
| `imbib-library-service_set-library-default` | 1 (1) | scalar | a | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-library-service_set-read` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — |  |  |
| `imbib-library-service_set-starred` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — |  |  |
| `imbib-library-service_sidebar-view` | 0 (0) | — | a | `SidebarView` | R |  |  | — |  |  |
| `imbib-manuscripts-service_compile-manuscript` | 1 (1) | scalar | a | `CompileResult` | E/M | y | y | guide |  |  |
| `imbib-manuscripts-service_create-manuscript` | 2 (1) | scalar | a | `Option<ManuscriptRecord>` | E/M | y |  | — |  |  |
| `imbib-manuscripts-service_create-manuscript-from-template` | 2 (2) | scalar | a | `Option<ManuscriptRecord>` | E/M | y |  | — |  |  |
| `imbib-manuscripts-service_get-manuscript` | 1 (1) | scalar | a | `Option<ManuscriptRecord>` | E/R | y |  | — |  |  |
| `imbib-manuscripts-service_list-manuscripts` | 0 (0) | — | a | `Vec<ManuscriptRecord>` | E/R | y |  | guide |  |  |
| `imbib-manuscripts-service_list-templates` | 0 (0) | — | a | `Vec<TemplateRecord>` | E/R | y |  | — |  |  |
| `imbib-manuscripts-service_write-manuscript-body` | 3 (3) | scalar | a | `WriteResult` | E/D | y |  | — |  |  |
| `imbib-scix-service_add-to-scix-library` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-scix-service_count-scix-library-publications` | 1 (1) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-scix-service_create-scix-library` | 6 (4) | scalar | a | `Option<SciXLibraryRecord>` | M |  |  | — | fallback |  |
| `imbib-scix-service_get-scix-library` | 1 (1) | scalar | a | `Option<SciXLibraryRecord>` | R |  |  | — | fallback |  |
| `imbib-scix-service_list-scix-libraries` | 0 (0) | — | a | `Vec<SciXLibraryRecord>` | R |  |  | — | fallback |  |
| `imbib-scix-service_query-scix-library-publications` | 5 (5) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-scix-service_remove-from-scix-library` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-search-service_create-smart-search` | 8 (7) | scalar | a | `Option<SmartSearchRecord>` | M |  |  | — |  |  |
| `imbib-search-service_find-by-arxiv` | 1 (1) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-search-service_find-by-bibcode` | 1 (1) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-search-service_find-by-cite-key` | 2 (1) | scalar | a | `Option<PublicationSummary>` | R |  |  | guide | fallback |  |
| `imbib-search-service_find-by-doi` | 1 (1) | scalar | a | `Vec<PublicationSummary>` | R |  |  | guide | fallback |  |
| `imbib-search-service_find-by-identifiers-batch` | 3 (3) | arr | b | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-search-service_full-text-search` | 3 (2) | scalar | a | `Vec<PublicationSummary>` | R |  |  | guide |  |  |
| `imbib-search-service_get-smart-search` | 1 (1) | scalar | a | `Option<SmartSearchRecord>` | R |  |  | — |  |  |
| `imbib-search-service_list-smart-searches` | 1 (0) | scalar | a | `Vec<SmartSearchRecord>` | R |  |  | — |  |  |
| `imbib-search-service_resolve-cite-key` | 2 (1) | scalar | a | `CiteKeyResolution` | R |  |  | — |  |  |
| `imbib-tags-service_add-tag` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | guide |  |  |
| `imbib-tags-service_count-by-tag` | 2 (1) | scalar | a | `u32` | R |  |  | — | fallback |  |
| `imbib-tags-service_create-tag` | 3 (1) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `imbib-tags-service_delete-tag-undoable` | 1 (1) | scalar | a | `MutationResult` | D |  |  | — |  |  |
| `imbib-tags-service_list-tags` | 0 (0) | — | a | `Vec<TagRecord>` | R |  |  | — |  |  |
| `imbib-tags-service_list-tags-with-counts` | 0 (0) | — | a | `Vec<TagWithCount>` | R |  | y | — | fallback |  |
| `imbib-tags-service_query-by-tag` | 5 (4) | scalar | a | `Vec<PublicationSummary>` | R |  |  | — | fallback |  |
| `imbib-tags-service_remove-tag` | 2 (2) | arr,scalar | b | `MutationResult` | M |  |  | — |  |  |
| `imbib-tags-service_rename-tag` | 2 (2) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `imbib-tags-service_update-tag` | 3 (1) | scalar | a | `MutationResult` | M |  |  | — | fallback |  |
| `imbib-text-service_decode-latex` | 1 (1) | scalar | a | `String` | R |  |  | test |  |  |
| `imbib-text-service_expand-journal-macro` | 1 (1) | scalar | a | `String` | R |  |  | — |  |  |
| `imbib-text-service_generate-cite-key` | 3 (0) | scalar | a | `String` | R |  |  | — |  |  |
| `imbib-text-service_normalize-tag-path` | 1 (1) | scalar | a | `String` | R |  |  | test |  |  |
| `imbib-text-service_normalize-tag-segment` | 1 (1) | scalar | a | `String` | R |  |  | — |  |  |
| `imbib-undo-service_recent-undo-groups` | 1 (1) | scalar | a | `Vec<UndoGroupRecord>` | R |  |  | — |  |  |
| `imbib-undo-service_undo-batch` | 1 (1) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `imbib-undo-service_undo-operation` | 1 (1) | scalar | a | `MutationResult` | M |  |  | — |  |  |
| `impart-service_add-message` | 3 (2) | scalar | a | `Option<MessageRecord>` | E/M | y |  | — |  |  |
| `impart-service_branch-conversation` | 2 (2) | scalar | a | `Option<ConversationRecord>` | E/M | y |  | — |  |  |
| `impart-service_create-conversation` | 2 (1) | scalar | a | `Option<ConversationRecord>` | E/M | y |  | — |  |  |
| `impart-service_get-conversation` | 1 (1) | scalar | a | `Option<ConversationRecord>` | E | y |  | guide |  |  |
| `impart-service_get-logs` | 2 (1) | scalar | a | `Vec<LogEntry>` | E | y |  | — |  |  |
| `impart-service_list-conversations` | 2 (2) | scalar | a | `Vec<ConversationRecord>` | E | y |  | guide |  |  |
| `impart-service_record-artifact` | 4 (2) | scalar | a | `bool` | E/M | y |  | — |  |  |
| `impart-service_record-decision` | 3 (2) | scalar | a | `bool` | E/M | y |  | guide |  |  |
| `impart-service_status` | 0 (0) | — | a | `AppStatus` | E |  |  | guide |  |  |
| `impart-service_update-conversation` | 3 (1) | scalar | a | `bool` | E/M | y |  | — |  |  |
| `impel-service_cancel-task` | 1 (1) | scalar | a | `ActionReport` | D |  |  | — |  |  |
| `impel-service_list-failed-tasks` | 1 (1) | scalar | a | `Vec<FailedTaskReport>` | R |  |  | — |  |  |
| `impel-service_list-pending-reviews` | 1 (1) | scalar | a | `Vec<PendingReviewReport>` | R |  |  | — |  |  |
| `impel-service_resolve-review` | 2 (2) | scalar | a | `ActionReport` | M |  |  | — |  |  |
| `impel-service_retention-status` | 1 (1) | scalar | a | `RetentionReport` | R |  |  | — |  |  |
| `impel-service_scheduler-status` | 0 (0) | — | a | `SchedulerStatusReport` | R |  |  | — |  |  |
| `implore-service_create-figure` | 8 (3) | arr-obj,obj,scalar | b | `CreateFigureOutcome` | E/M | y | y | guide |  |  |
| `implore-service_export-figure` | 2 (2) | scalar | a | `Option<String>` | E/M | y | y | guide |  |  |
| `implore-service_get-dataset` | 1 (1) | scalar | a | `Option<DatasetRecord>` | E | y |  | guide |  |  |
| `implore-service_get-figure` | 1 (1) | scalar | a | `Option<FigureRecord>` | E | y |  | — |  |  |
| `implore-service_get-logs` | 2 (1) | scalar | a | `Vec<LogEntry>` | E | y |  | — |  |  |
| `implore-service_list-datasets` | 0 (0) | — | a | `Vec<DatasetRecord>` | E | y |  | guide |  |  |
| `implore-service_list-figures` | 1 (0) | scalar | a | `Vec<FigureRecord>` | E | y |  | — |  |  |
| `implore-service_plot-histogram` | 2 (0) | scalar | a | `Option<String>` | E | y | y | guide |  |  |
| `implore-service_plot-series` | 2 (1) | arr,scalar | b | `Option<String>` | E | y | y | guide |  |  |
| `implore-service_rg-batch` | 1 (1) | scalar | a | `String` | E | y | y | — |  |  |
| `implore-service_rg-cascade-plot` | 0 (0) | — | a | `String` | E | y | y | guide |  |  |
| `implore-service_rg-colormaps` | 0 (0) | — | a | `String` | E | y |  | — |  |  |
| `implore-service_rg-control` | 1 (1) | scalar | a | `String` | E | y |  | — |  |  |
| `implore-service_rg-load` | 1 (1) | scalar | a | `String` | E | y | y | guide |  |  |
| `implore-service_rg-slice-png` | 1 (0) | scalar | a | `String` | E | y |  | guide |  |  |
| `implore-service_rg-slice-raw` | 1 (0) | scalar | a | `String` | E | y |  | — |  |  |
| `implore-service_rg-slice-save` | 1 (1) | scalar | a | `String` | E/D | y |  | — |  |  |
| `implore-service_rg-state` | 0 (0) | — | a | `String` | E | y |  | — |  |  |
| `implore-service_rg-statistics` | 1 (0) | scalar | a | `String` | E | y |  | — |  |  |
| `implore-service_status` | 0 (0) | — | a | `AppStatus` | E |  |  | guide |  |  |
| `impress-ai-service_ai-health` | 0 (0) | — | a | `AiHealthResult` | E | y | y | — |  |  |
| `impress-ai-service_ai-preferences` | 0 (0) | — | a | `AiPreferencesResult` | R |  |  | — |  |  |
| `impress-ai-service_create-conversation` | 9 (7) | arr,scalar | b | `ConversationMutationResult` | M |  |  | — |  |  |
| `impress-ai-service_get-conversation` | 1 (1) | scalar | a | `ConversationResult` | R |  |  | — |  |  |
| `impress-ai-service_list-conversations` | 1 (1) | scalar | a | `ConversationsResult` | R |  |  | — |  |  |
| `impress-ai-service_list-models` | 1 (0) | scalar | a | `ModelsResult` | E |  | y | — |  |  |
| `impress-ai-service_list-providers` | 0 (0) | — | a | `ProvidersResult` | E |  | y | — |  |  |
| `impress-ai-service_mint-pairing-link` | 0 (0) | — | a | `PairingLinkResult` | E/M | y | y | — |  |  |
| `impress-ai-service_provider-health` | 1 (0) | scalar | a | `ProviderHealthResult` | E |  | y | — |  |  |
| `impress-ai-service_queue-message` | 3 (3) | arr,scalar | b | `QueuedMessageResult` | M |  |  | — |  |  |
| `impress-ai-service_run-provenance` | 1 (1) | scalar | a | `ProvenanceResult` | R |  |  | — |  |  |
| `impress-ai-service_select-model` | 2 (1) | scalar | a | `AiPreferencesResult` | M |  |  | — |  |  |
| `impress-ai-service_set-enabled-tools` | 2 (2) | arr,scalar | b | `ConversationMutationResult` | M |  |  | — |  |  |
| `impress-ai-service_set-provider-endpoint` | 2 (1) | scalar | a | `AiPreferencesResult` | M |  |  | — |  |  |
| `impress-ai-service_task-provenance` | 1 (1) | scalar | a | `ProvenanceResult` | R |  |  | — |  |  |
| `impress-ai-service_task-status` | 1 (1) | scalar | a | `TaskStatusResult` | R |  |  | — |  |  |
| `impress-bridges-service_add-papers-from-conversation` | 2 (1) | scalar | a | `Vec<String>` | E/M | y | y | — |  |  |
| `impress-bridges-service_cite-in-section` | 3 (3) | scalar | a | `CitationResult` | M |  |  | guide |  |  |
| `impress-bridges-service_cite-multiple` | 2 (2) | arr,scalar | b | `CitationResult` | E/M | y |  | — |  |  |
| `impress-bridges-service_cite-paper` | 2 (2) | scalar | a | `CitationResult` | E/M | y |  | guide |  |  |
| `impress-bridges-service_conversation-decisions` | 1 (1) | scalar | a | `Vec<String>` | E | y |  | — |  |  |
| `impress-bridges-service_conversation-to-outline` | 1 (1) | scalar | a | `Option<ConversationOutline>` | E | y |  | — |  |  |
| `impress-bridges-service_embed-figure` | 3 (3) | scalar | a | `FigureEmbedResult` | E/M | y | y | guide |  |  |
| `impress-bridges-service_embed-figure-reference` | 3 (3) | scalar | a | `FigureEmbedResult` | E/M | y |  | — |  |  |
| `impress-bridges-service_export-conversation-citations` | 1 (1) | scalar | a | `String` | E | y |  | — |  |  |
| `impress-bridges-service_extract-papers-from-conversation` | 1 (1) | scalar | a | `Vec<ExtractedIdentifier>` | E | y |  | guide |  |  |
| `impress-bridges-service_extract-papers-from-text` | 1 (1) | scalar | a | `Vec<ExtractedIdentifier>` | R |  |  | — |  |  |
| `impress-bridges-service_get-citation-suggestions` | 2 (2) | scalar | a | `Vec<String>` | E | y |  | — |  |  |
| `impress-bridges-service_get-item` | 1 (1) | scalar | a | `Option<StoreItem>` | R |  |  | — |  |  |
| `impress-bridges-service_get-related` | 2 (2) | scalar | a | `Vec<StoreItem>` | R |  |  | — |  |  |
| `impress-bridges-service_list-available-figures` | 0 (0) | — | a | `Vec<String>` | E | y |  | — |  |  |
| `impress-bridges-service_resolve-artifact` | 1 (1) | scalar | a | `Option<StoreItem>` | R |  |  | — |  |  |
| `impress-bridges-service_search-all` | 2 (2) | scalar | a | `Vec<StoreItem>` | R |  | y | — |  |  |
| `impress-bridges-service_sync-figure` | 2 (2) | scalar | a | `FigureEmbedResult` | E/D | y | y | — |  |  |
| `impress-surface-service_surface-create` | 3 (1) | arr,obj,scalar | b | `SurfaceResult` | M |  |  | surf |  | y |
| `impress-surface-service_surface-delete` | 1 (1) | scalar | a | `SurfaceDeleteResult` | D |  |  | surf |  | y |
| `impress-surface-service_surface-dispatch` | 4 (2) | map,other,scalar | b | `SurfaceDispatchResult` | M |  | y | surf,test |  | y |
| `impress-surface-service_surface-events` | 3 (1) | scalar | a | `SurfaceEventsResult` | R |  |  | surf |  | y |
| `impress-surface-service_surface-examples` | 0 (0) | — | a | `SurfaceExamplesResult` | R |  |  | surf,test |  | y |
| `impress-surface-service_surface-get` | 1 (1) | scalar | a | `SurfaceResult` | R |  |  | surf,test |  | y |
| `impress-surface-service_surface-list` | 0 (0) | — | a | `SurfaceListResult` | R |  |  | surf |  | y |
| `impress-surface-service_surface-render` | 3 (1) | map,scalar | b | `SurfaceRenderResult` | R |  | y | surf |  | y |
| `impress-surface-service_surface-schema` | 0 (0) | — | a | `SurfaceSchemaResult` | R |  |  | surf |  | y |
| `impress-surface-service_surface-show` | 4 (3) | other,scalar | b | `SurfaceShowResult` | M |  |  | surf,test |  | y |
| `impress-surface-service_surface-state-get` | 2 (1) | scalar | a | `SurfaceStateResult` | R |  |  | surf |  | y |
| `impress-surface-service_surface-state-set` | 3 (2) | other,scalar | b | `SurfaceStateResult` | M |  |  | surf |  | y |
| `impress-surface-service_surface-update` | 4 (2) | obj,scalar | b | `SurfaceResult` | M |  |  | surf |  | y |
| `impress-surface-service_surface-validate` | 1 (1) | obj | b | `SurfaceValidateResult` | R |  |  | surf |  | y |
| `impress-surface-service_surface-wait` | 4 (2) | scalar | a | `SurfaceWaitResult` | R |  | y | surf,test |  | y |
| `imprint-app-service_create-comment` | 3 (2) | scalar | a | `Option<CommentRecord>` | E/M | y |  | guide |  |  |
| `imprint-app-service_create-document` | 2 (1) | scalar | a | `Option<String>` | E/M | y |  | — |  |  |
| `imprint-app-service_delete-comment` | 1 (1) | scalar | a | `bool` | E/D | y |  | — |  |  |
| `imprint-app-service_delete-text` | 3 (3) | scalar | a | `bool` | E/D | y |  | guide |  |  |
| `imprint-app-service_get-bibliography` | 1 (1) | scalar | a | `Option<String>` | E | y |  | — |  |  |
| `imprint-app-service_get-content` | 1 (1) | scalar | a | `Option<String>` | E | y |  | — |  |  |
| `imprint-app-service_get-logs` | 3 (1) | scalar | a | `Vec<LogEntry>` | E | y |  | — |  |  |
| `imprint-app-service_get-pdf` | 1 (1) | scalar | a | `CompiledPdf` | E/M | y | y | guide |  |  |
| `imprint-app-service_insert-text` | 3 (3) | scalar | a | `bool` | E/M | y |  | guide |  |  |
| `imprint-app-service_list-comments` | 1 (1) | scalar | a | `Vec<CommentRecord>` | E | y |  | — |  |  |
| `imprint-app-service_replace` | 3 (3) | scalar | a | `u32` | E/D | y |  | guide |  |  |
| `imprint-app-service_status` | 0 (0) | — | a | `AppStatus` | E |  |  | guide |  |  |
| `imprint-app-service_update-comment` | 3 (1) | scalar | a | `bool` | E/M | y |  | — |  |  |
| `imprint-app-service_update-document` | 2 (1) | scalar | a | `bool` | E/M | y |  | — |  |  |
| `imprint-app-service_update-metadata` | 2 (2) | scalar | a | `bool` | E/D | y |  | — |  |  |
| `imprint-manuscript-service_compile-latex` | 2 (2) | scalar | a | `LatexCompileResultDto` | R |  | y | — |  |  |
| `imprint-manuscript-service_compile-typst` | 2 (2) | obj,scalar | b | `CompileResult` | M |  | y | guide |  |  |
| `imprint-manuscript-service_delete-section` | 2 (2) | scalar | a | `bool` | D |  |  | guide |  |  |
| `imprint-manuscript-service_document-citations` | 1 (1) | scalar | a | `Vec<CitationUsage>` | R |  |  | — | fallback |  |
| `imprint-manuscript-service_document-outline` | 1 (1) | scalar | a | `Outline` | R |  |  | — | fallback |  |
| `imprint-manuscript-service_export-document` | 2 (2) | scalar | a | `Vec<u8>` | R | y |  | — |  |  |
| `imprint-manuscript-service_get-document` | 1 (1) | scalar | a | `Option<DocumentSummary>` | R | y |  | — |  |  |
| `imprint-manuscript-service_get-section` | 2 (2) | scalar | a | `Option<SectionRecord>` | R |  |  | — |  |  |
| `imprint-manuscript-service_list-documents` | 0 (0) | — | a | `Vec<DocumentSummary>` | R | y |  | guide |  |  |
| `imprint-manuscript-service_list-sections` | 1 (1) | scalar | a | `Vec<SectionRecord>` | R |  |  | guide |  |  |
| `imprint-manuscript-service_presentation-outline` | 1 (1) | scalar | a | `PresentationOutlineDto` | R |  |  | — |  |  |
| `imprint-manuscript-service_put-section` | 4 (4) | obj,scalar | b | `Option<SectionRecord>` | M |  |  | guide | fallback |  |
| `imprint-manuscript-service_reorder-presentation-slide` | 3 (3) | scalar | a | `PresentationMutationDto` | R |  |  | — |  |  |
| `imprint-manuscript-service_replace-in-section` | 4 (4) | scalar | a | `ReplaceResult` | D |  |  | guide | fallback |  |
| `imprint-manuscript-service_search` | 2 (2) | scalar | a | `Vec<SearchHitDto>` | R |  |  | guide |  |  |
| `imprint-manuscript-service_search-in-text` | 3 (3) | scalar | a | `Vec<TextMatch>` | R |  |  | guide | fallback |  |
| `imprint-manuscript-service_set-presentation-slide-beat` | 3 (3) | scalar | a | `PresentationMutationDto` | R |  |  | — |  |  |
| `imprint-project-service_project-build` | 5 (1) | scalar | a | `ProjectBuildResult` | E/M |  | y | — |  |  |
| `imprint-project-service_project-build-output` | 4 (1) | scalar | a | `ProjectBuildOutputResult` | R |  |  | — |  |  |
| `imprint-project-service_project-builds` | 3 (1) | scalar | a | `ProjectBuildsRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-checkin` | 5 (1) | arr,scalar | b | `ProjectCheckinRecord` | M |  |  | — |  |  |
| `imprint-project-service_project-checkout` | 3 (2) | scalar | a | `ProjectCheckoutRecord` | D |  |  | — |  |  |
| `imprint-project-service_project-citations` | 2 (1) | scalar | a | `ProjectCitationsRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-collect` | 3 (2) | arr,scalar | b | `ProjectCollectRecord` | M |  |  | — |  |  |
| `imprint-project-service_project-compile` | 3 (1) | scalar | a | `ProjectCompileRecord` | R |  | y | — |  |  |
| `imprint-project-service_project-delete-file` | 2 (2) | scalar | a | `ProjectMutationResult` | D |  |  | — |  |  |
| `imprint-project-service_project-export` | 4 (2) | scalar | a | `ProjectExportRecord` | D |  |  | — |  |  |
| `imprint-project-service_project-figure-preview` | 3 (2) | scalar | a | `ProjectFigureRenderRecord` | E |  | y | — |  |  |
| `imprint-project-service_project-file` | 2 (2) | scalar | a | `ProjectFileContentRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-graph` | 2 (1) | scalar | a | `ProjectGraphRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-import-directory` | 5 (1) | scalar | a | `ProjectImportRecord` | M |  | y | — |  |  |
| `imprint-project-service_project-materialize` | 3 (1) | scalar | a | `ProjectExportRecord` | M |  |  | — |  |  |
| `imprint-project-service_project-move-file` | 4 (3) | scalar | a | `ProjectFileResult` | M |  |  | — |  |  |
| `imprint-project-service_project-new-figure` | 4 (3) | scalar | a | `ProjectFigureResult` | M |  |  | — |  |  |
| `imprint-project-service_project-outline` | 2 (1) | scalar | a | `ProjectOutlineRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-put-file` | 6 (2) | scalar | a | `ProjectFileResult` | D |  |  | — |  |  |
| `imprint-project-service_project-reading-list` | 2 (1) | scalar | a | `ProjectReadingListRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-render-figure` | 5 (2) | scalar | a | `ProjectFigureRenderRecord` | E/M |  | y | — |  |  |
| `imprint-project-service_project-set-bibliography` | 3 (2) | scalar | a | `ProjectFileResult` | M |  |  | — |  |  |
| `imprint-project-service_project-set-entry` | 3 (2) | scalar | a | `ProjectMutationResult` | M |  |  | — |  |  |
| `imprint-project-service_project-set-figure-build` | 3 (2) | scalar | a | `ProjectFileResult` | M |  |  | — |  |  |
| `imprint-project-service_project-set-targets` | 3 (1) | scalar | a | `ProjectTreeRecord` | M |  |  | — |  |  |
| `imprint-project-service_project-snapshot` | 5 (2) | scalar | a | `ProjectSnapshotRecord` | M |  |  | — |  |  |
| `imprint-project-service_project-status` | 2 (1) | scalar | a | `ProjectStatusRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-sync-reading-collection` | 3 (1) | scalar | a | `ProjectSyncCollectionRecord` | M |  |  | — |  |  |
| `imprint-project-service_project-tree` | 1 (1) | scalar | a | `ProjectTreeRecord` | R |  |  | — |  |  |
| `imprint-project-service_project-uncollect` | 2 (2) | arr,scalar | b | `ProjectCollectRecord` | M |  |  | — |  |  |
| `imprint-selftest-service_run-selftest` | 1 (1) | scalar | a | `SelfTestReport` | E/M |  | y | — |  |  |
| `imprint-text-service_compose-citation` | 3 (3) | scalar | a | `String` | R |  |  | — |  |  |
| `imprint-text-service_compose-heading` | 3 (3) | scalar | a | `String` | R |  |  | — |  |  |
| `imprint-text-service_extract-cite-key-usages` | 2 (2) | scalar | a | `Vec<CiteKeyUsage>` | R |  |  | — |  |  |
| `imprint-text-service_extract-cite-keys` | 2 (2) | scalar | a | `Vec<String>` | R |  |  | — |  |  |
| `imprint-text-service_format-latex` | 1 (1) | scalar | a | `String` | R |  |  | — |  |  |
| `imprint-throughline-service_create-throughline` | 2 (2) | scalar | a | `Option<ThroughlineInfoDto>` | M |  |  | — |  |  |
| `imprint-throughline-service_delete-throughline` | 1 (1) | scalar | a | `bool` | D |  |  | — |  |  |
| `imprint-throughline-service_get-anchor-states` | 1 (1) | scalar | a | `Vec<AnchorStateDto>` | R |  |  | — |  |  |
| `imprint-throughline-service_get-coverage` | 1 (1) | scalar | a | `CoverageDto` | R |  |  | — |  |  |
| `imprint-throughline-service_get-throughline` | 1 (1) | scalar | a | `Option<ThroughlineInfoDto>` | R |  |  | — |  |  |
| `imprint-throughline-service_mark-supporting` | 3 (3) | scalar | a | `Option<ThroughlineInfoDto>` | M |  |  | — |  |  |
| `imprint-throughline-service_remove-anchor` | 2 (2) | scalar | a | `Option<ThroughlineInfoDto>` | M |  |  | — |  |  |
| `imprint-throughline-service_set-anchor` | 3 (3) | arr,scalar | b | `Option<ThroughlineInfoDto>` | M |  |  | — |  |  |
| `imprint-throughline-service_update-throughline-source` | 2 (2) | scalar | a | `Option<ThroughlineInfoDto>` | D |  |  | — |  |  |
| `layout-selftest-service_run-selftest` | 1 (1) | scalar | a | `SelfTestReport` | E/M |  | y | test |  |  |
| `layout-service_apply-layout` | 6 (1) | scalar | a | `LayoutVerbResult` | D |  |  | — |  | y |
| `layout-service_apply-preset` | 5 (2) | scalar | a | `LayoutVerbResult` | D |  |  | — |  | y |
| `layout-service_bind-param` | 7 (4) | obj,scalar,tagged-union | b | `LayoutVerbResult` | M |  |  | surf |  | y |
| `layout-service_close` | 5 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | test |  | y |
| `layout-service_commit` | 6 (3) | scalar | a | `LayoutVerbResult` | D |  |  | — |  | y |
| `layout-service_delete-layout` | 3 (2) | scalar | a | `LayoutVerbResult` | D |  |  | — |  | y |
| `layout-service_detach` | 5 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_focus` | 5 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | test |  | y |
| `layout-service_focus-direction` | 5 (2) | scalar | a | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_get-channel` | 4 (2) | scalar | a | `ChannelResult` | R |  |  | — |  | y |
| `layout-service_get-layout` | 2 (1) | scalar | a | `LayoutResult` | R |  |  | — |  | y |
| `layout-service_get-pane` | 3 (2) | obj,scalar | b | `PaneResult` | R |  |  | — |  | y |
| `layout-service_list-layouts` | 1 (1) | scalar | a | `LayoutListResult` | R |  |  | — |  | y |
| `layout-service_list-presets` | 1 (1) | scalar | a | `PresetListResult` | R |  |  | — |  | y |
| `layout-service_maximize` | 5 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_move-tile` | 7 (4) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_redo` | 6 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_reset-preset` | 3 (2) | scalar | a | `PresetResult` | D |  |  | — |  | y |
| `layout-service_resize` | 6 (3) | arr,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_resolve-reference` | 3 (2) | obj,scalar | b | `ReferenceResult` | R |  |  | — |  | y |
| `layout-service_restore` | 4 (1) | scalar | a | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_save-layout` | 5 (2) | scalar | a | `LayoutVerbResult` | D |  |  | — |  | y |
| `layout-service_save-preset` | 6 (3) | scalar | a | `PresetResult` | D |  |  | — |  | y |
| `layout-service_select` | 7 (4) | arr,obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-channel` | 6 (3) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-collapsed` | 6 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-container-kind` | 6 (3) | scalar | a | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-default-channel` | 6 (2) | scalar | a | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-pane` | 6 (3) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-query` | 6 (3) | obj,scalar | b | `LayoutVerbResult` | M |  |  | test |  | y |
| `layout-service_set-role` | 6 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-view-kind` | 6 (3) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_set-window-geometry` | 6 (1) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_split` | 8 (4) | obj,scalar | b | `LayoutVerbResult` | M |  |  | test |  | y |
| `layout-service_swap` | 6 (3) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `layout-service_undo` | 6 (2) | obj,scalar | b | `LayoutVerbResult` | M |  |  | — |  | y |
| `manuscript-collab-service_commit-manuscript-body` | 4 (4) | arr,scalar | b | `CollabCommitResult` | M |  |  | — |  |  |
| `manuscript-collab-service_manuscript-change-history` | 1 (1) | scalar | a | `CollabHistoryResult` | R |  |  | — |  |  |
| `manuscript-collab-service_manuscript-heads` | 1 (1) | scalar | a | `CollabHeadsResult` | R |  |  | — |  |  |
| `manuscript-collab-service_manuscript-text-at` | 2 (2) | arr,scalar | b | `CollabTextAtResult` | R |  |  | — |  |  |
| `memory-service_confirm-claim` | 1 (1) | scalar | a | `ActionResult` | M |  |  | — |  |  |
| `memory-service_forget` | 1 (1) | scalar | a | `ActionResult` | D |  |  | — |  |  |
| `memory-service_memory-brief` | 3 (3) | scalar | a | `BriefResult` | R |  |  | guide |  |  |
| `memory-service_memory-status` | 0 (0) | — | a | `StatusResult` | R |  |  | — |  |  |
| `memory-service_recall` | 4 (4) | scalar | a | `RecallResult` | R |  |  | guide |  |  |
| `memory-service_remember` | 7 (7) | arr,scalar | b | `RememberResult` | M |  |  | — |  |  |
| `memory-service_supersede-claim` | 4 (4) | scalar | a | `SupersedeResult` | M |  |  | — |  |  |
| `parsers-service_decode-mime-header` | 1 (1) | scalar | a | `String` | R |  |  | test |  |  |
| `parsers-service_decode-quoted-printable` | 2 (2) | scalar | a | `String` | R |  |  | test |  |  |
| `parsers-service_extract-landing-page-pdf` | 3 (3) | scalar | a | `LandingPageReport` | R |  |  | test |  |  |
| `parsers-service_list-publisher-rules` | 0 (0) | — | a | `Vec<PublisherRuleReport>` | R |  |  | test |  |  |
| `parsers-service_parse-mbox` | 2 (2) | scalar | a | `MboxParseReport` | R |  |  | test |  |  |
| `parsers-service_resolve-publisher-pdf` | 1 (1) | scalar | a | `PdfResolutionReport` | R |  |  | test |  |  |
| `smart-search-service_build-ads-query` | 8 (8) | arr,scalar | b | `String` | R |  |  | test |  |  |
| `smart-search-service_classify-search-input` | 1 (1) | scalar | a | `SearchIntentReport` | R |  |  | test |  |  |
| `smart-search-service_clean-ads-query` | 1 (1) | scalar | a | `String` | R |  |  | test |  |  |
| `smart-search-service_extract-page-identifiers` | 1 (1) | scalar | a | `PageExtractionReport` | R |  |  | test |  |  |
| `smart-search-service_free-text-extraction-prompt` | 3 (3) | scalar | a | `String` | R |  |  | test |  |  |
| `smart-search-service_normalize-ads-query` | 1 (1) | scalar | a | `AdsNormalizationReport` | R |  |  | test |  |  |
| `smart-search-service_reference-parse-prompt` | 1 (1) | scalar | a | `String` | R |  |  | test |  |  |
| `smart-search-service_rewrite-free-text-query` | 2 (2) | scalar | a | `QueryRewriteReport` | R |  |  | test |  |  |
| `smart-search-service_split-reference-blocks` | 1 (1) | scalar | a | `Vec<String>` | R |  |  | test |  |  |
| `smart-search-service_validate-parsed-reference` | 9 (9) | arr,scalar | b | `CitationReport` | R |  |  | test |  |  |
| `source-service_get-citation` | 1 (1) | scalar | a | `SourceRecordResult` | R |  |  | test |  |  |
| `source-service_get-content-chunk` | 1 (1) | scalar | a | `SourceRecordResult` | R |  |  | test |  |  |
| `source-service_get-figure-image` | 7 (1) | scalar | a | `FigureImageResult` | E |  | y | guide,test |  |  |
| `source-service_get-page-image` | 5 (1) | scalar | a | `PageImageResult` | E |  | y | guide,test |  |  |
| `source-service_put-citation` | 1 (1) | obj | b | `SourceRecordResult` | M |  |  | test |  |  |
| `source-service_put-content-chunk` | 1 (1) | obj | b | `SourceRecordResult` | M |  |  | — |  |  |
| `source-service_put-extraction-run` | 1 (1) | obj | b | `SourceRecordResult` | M |  |  | — |  |  |
| `source-service_put-figure-region` | 1 (1) | obj | b | `SourceRecordResult` | M |  |  | — |  |  |
| `source-service_search-content-chunks` | 3 (2) | scalar | a | `ContentChunkSearchResult` | R |  |  | test |  |  |
| `store-query-service_get-item` | 1 (1) | scalar | a | `ItemResult` | R |  |  | guide,test |  |  |
| `store-query-service_list-items` | 3 (3) | scalar | a | `ItemListResult` | R |  |  | guide,test |  |  |
| `store-query-service_related-items` | 2 (2) | scalar | a | `RelatedResult` | R |  |  | guide,test |  |  |
| `store-query-service_search-all` | 2 (2) | scalar | a | `SearchResult` | R |  |  | guide,test |  |  |
| `surface-demo-service_histogram` | 2 (2) | arr,scalar | b | `HistogramResult` | R |  |  | surf,ex,test |  |  |
| `surface-demo-service_series` | 2 (2) | scalar | a | `SeriesResult` | R |  |  | surf,ex,test |  |  |
| `surface-selftest-service_run-selftest` | 1 (1) | scalar | a | `SelfTestReport` | E/M |  | y | test |  |  |
| `triage-service_add-tag` | 2 (2) | scalar | a | `TriageResult` | M |  |  | surf,ex,test |  |  |
| `triage-service_remove-tag` | 2 (2) | scalar | a | `TriageResult` | M |  |  | test |  |  |
| `triage-service_set-flag` | 2 (1) | scalar | a | `TriageResult` | M |  |  | surf,ex,test |  |  |
| `triage-service_set-starred` | 2 (2) | scalar | a | `TriageResult` | M |  |  | surf,ex,test |  |  |
| `triage-service_set-status` | 2 (1) | scalar | a | `TriageResult` | M |  |  | test |  |  |
| `vw-diagnostic-service_close-session` | 1 (1) | obj | b | `SessionResult` | M |  |  | — |  |  |
| `vw-diagnostic-service_create-session` | 1 (1) | obj | b | `SessionResult` | M |  |  | test |  |  |
| `vw-diagnostic-service_evaluate-session` | 2 (2) | scalar | a | `AssessmentResult` | R |  |  | test |  |  |
| `vw-diagnostic-service_get-capabilities` | 0 (0) | — | a | `VwCapabilities` | R |  |  | test |  |  |
| `vw-diagnostic-service_get-photo` | 1 (1) | scalar | a | `PhotoEvidenceResult` | R |  |  | test |  |  |
| `vw-diagnostic-service_get-session` | 1 (1) | scalar | a | `SessionResult` | R |  |  | — |  |  |
| `vw-diagnostic-service_ingest-photo` | 7 (4) | arr,obj,scalar | b | `PhotoEvidenceResult` | E/M |  | y | test |  |  |
| `vw-diagnostic-service_list-applicable-procedures` | 1 (1) | scalar | a | `ProcedureListResult` | R |  |  | — |  |  |
| `vw-diagnostic-service_list-sessions` | 1 (1) | scalar | a | `SessionListResult` | R |  |  | — |  |  |
| `vw-diagnostic-service_recommend-next-test` | 2 (2) | scalar | a | `NextTestResult` | R |  |  | test |  |  |
| `vw-diagnostic-service_record-measurement` | 1 (1) | obj | b | `SessionResult` | M |  |  | test |  |  |
| `vw-diagnostic-service_record-observation` | 1 (1) | obj | b | `SessionResult` | M |  |  | test |  |  |
| `vw-diagnostic-service_record-procedure-step` | 1 (1) | obj | b | `SessionResult` | M |  |  | — |  |  |
| `vw-diagnostic-service_search-photos` | 3 (2) | scalar | a | `PhotoEvidenceSearchResult` | R |  |  | test |  |  |
| `vw-diagnostic-service_start-procedure` | 1 (1) | obj | b | `SessionResult` | M |  |  | — |  |  |

## Appendix A3 — every return type

| Return type | Verbs | Shape | Best widget | JsonSchema | ok+msg | wire_v | Special |
|---|---:|---|---|:-:|:-:|:-:|---|
| `LayoutVerbResult` | 28 | envelope | kv | y | y | y | tree_json: Option<String> is a JSON tree serialized as a string |
| `MutationResult` | 28 | flat-object | status | y |  |  |  |
| `String` | 27 | string | text | y |  |  | 27 verbs, wildly mixed payloads: rg_cascade_plot returns an SVG document; rg_slice_png returns a base64 PNG or a file pa |
| `bool` | 19 | scalar | status | y |  |  |  |
| `Vec<PublicationSummary>` | 14 | list-of-records | table | y |  |  |  |
| `u32` | 14 | scalar | kv | y |  |  |  |
| `Vec<String>` | 9 | list-of-scalars | list | y |  |  |  |
| `Option<String>` | 8 | string | text | y |  |  | plot_series/plot_histogram return an SVG document; export_figure returns a file path; get_content returns the full manus |
| `SessionResult` | 7 | envelope | kv | y |  |  |  |
| `Option<ThroughlineInfoDto>` | 6 | flat-object | kv | y |  |  | anchor_map_json is JSON serialized as a String |
| `SourceRecordResult` | 6 | envelope | raw-json | y | y |  | record: Option<serde_json::Value> — the kind-specific source record with no schema; kv can only show ok/id/message aroun |
| `AppStatus` | 5 | flat-object | status | y |  |  |  |
| `TriageResult` | 5 | envelope | status | y | y |  |  |
| `CollectionResult` | 4 | envelope | kv | y | y |  |  |
| `ProjectFileResult` | 4 | envelope | kv | y | y |  |  |
| `Vec<CommentRecord>` | 4 | list-of-records | table | y |  |  |  |
| `Vec<LogEntry>` | 4 | list-of-records | log | y |  |  |  |
| `AiPreferencesResult` | 3 | nested-object | kv |  |  |  |  |
| `CitationResult` | 3 | envelope | kv | y | y |  |  |
| `CollectionMutationResult` | 3 | envelope | status | y | y |  |  |
| `EinkSyncRecord` | 3 | envelope | kv+table | y |  |  |  |
| `FigureEmbedResult` | 3 | envelope | status | y | y |  | path is a file path |
| `Option<CommentRecord>` | 3 | flat-object | kv | y |  |  |  |
| `Option<ConversationRecord>` | 3 | flat-object | kv | y |  |  |  |
| `Option<LibraryRecord>` | 3 | flat-object | kv | y |  |  |  |
| `Option<ManuscriptRecord>` | 3 | flat-object | kv | y |  |  |  |
| `SelfTestReport` | 3 | envelope | kv+table | y |  |  |  |
| `SurfaceResult` | 3 | envelope | kv | y | y | y | spec: Option<SurfaceSpec> is a deep surface spec (raw-json for that field); problems: Vec<Problem> is a table |
| `Vec<AnnotationRecord>` | 3 | list-of-records | table | y |  |  | image_path: Option<String> is a file path to an ink/highlight image, not shown inline |
| `ActionReport` | 2 | envelope | status |  | y |  |  |
| `ActionResult` | 2 | envelope | status | y | y |  |  |
| `CompileResult` | 2 | nested-object | kv |  |  |  | imprint variant carries pdf_data: Option<Vec<u8>> (raw PDF bytes serialized as a JSON number array) and pdf_path; imbib  |
| `ConversationMutationResult` | 2 | flat-object | status |  |  |  |  |
| `EinkMarkResult` | 2 | envelope | kv | y |  |  |  |
| `Option<ArtifactRecord>` | 2 | flat-object | kv | y |  |  |  |
| `Option<PublicationSummary>` | 2 | flat-object | kv | y |  |  |  |
| `Option<SciXLibraryRecord>` | 2 | flat-object | kv | y |  |  |  |
| `Option<SectionRecord>` | 2 | flat-object | kv |  |  |  | body is the full section text (large); Uuid ids |
| `Option<SmartSearchRecord>` | 2 | flat-object | kv | y |  |  |  |
| `Option<StoreItem>` | 2 | flat-object | kv | y |  |  | payload_json is a JSON object serialized as a String |
| `PhotoEvidenceResult` | 2 | envelope | image | y | y |  | _mcp_content: Vec<VwMcpImageBlock> (base64 image blocks, stripped by MCP transports) |
| `PresentationMutationDto` | 2 | flat-object | text | y |  |  | source is the full presentation source text after the mutation (large) |
| `PresetResult` | 2 | envelope | kv | y | y | y |  |
| `ProjectCollectRecord` | 2 | envelope | kv | y | y |  |  |
| `ProjectExportRecord` | 2 | envelope | kv | y | y |  | directory is a file path; four path lists |
| `ProjectFigureRenderRecord` | 2 | envelope | image | y | y |  | svg: Option<String> is an inline SVG document; log is a raw runner log; path is a file path |
| `ProjectMutationResult` | 2 | envelope | status | y | y |  |  |
| `ProjectTreeRecord` | 2 | envelope | kv+table | y | y |  | working_copy_path is a file path |
| `ProvenanceResult` | 2 | nested-object | kv |  |  |  |  |
| `SurfaceStateResult` | 2 | envelope | raw-json | y | y | y | state: Option<serde_json::Value> is the surface's free-form state object |
| `Vec<ArtifactRecord>` | 2 | list-of-records | table | y |  |  |  |
| `Vec<BackupRecord>` | 2 | list-of-records | table | y |  |  | path is a file path |
| `Vec<ExtractedIdentifier>` | 2 | list-of-records | table | y |  |  |  |
| `Vec<StoreItem>` | 2 | list-of-records | table | y |  |  | payload_json is a JSON object serialized as a String |
| `WatchedFolderResult` | 2 | envelope | kv | y | y |  |  |
| `AdsNormalizationReport` | 1 | nested-object | kv |  |  |  |  |
| `AiHealthResult` | 1 | flat-object | kv |  |  |  |  |
| `AssessmentResult` | 1 | envelope | kv | y |  |  |  |
| `BackupInspection` | 1 | nested-object | kv | y |  |  | path is a file path |
| `BriefResult` | 1 | envelope | text | y | y |  | text is a ready-made markdown brief (### headings, bullets); sections duplicates it structurally |
| `ChannelResult` | 1 | envelope | kv | y | y | y |  |
| `CitationReport` | 1 | nested-object | kv |  |  |  |  |
| `CiteKeyResolution` | 1 | nested-object | kv | y |  |  |  |
| `CollabCommitResult` | 1 | envelope | kv | y | y |  | body is the full merged manuscript text (potentially large) |
| `CollabHeadsResult` | 1 | envelope | kv | y | y |  |  |
| `CollabHistoryResult` | 1 | envelope | kv+table | y | y |  |  |
| `CollabTextAtResult` | 1 | envelope | text | y | y |  | body is the full manuscript text at the given heads (large) |
| `CollectionListResult` | 1 | envelope | kv+table | y | y |  |  |
| `CompiledPdf` | 1 | envelope | kv | y |  |  | path is a file path to the PDF |
| `ContentChunkSearchResult` | 1 | envelope | kv+table | y | y |  |  |
| `ConversationResult` | 1 | nested-object | kv |  |  |  |  |
| `ConversationsResult` | 1 | nested-object | kv+table |  |  |  |  |
| `CoverageDto` | 1 | nested-object | kv | y |  |  |  |
| `CreateFigureOutcome` | 1 | envelope | kv | y |  |  |  |
| `DiscoveredImportResult` | 1 | envelope | kv+table | y | y |  |  |
| `DocsImportResult` | 1 | envelope | kv+table | y | y |  |  |
| `EinkAppendResult` | 1 | envelope | status | y |  |  |  |
| `EinkDocumentImportRecord` | 1 | envelope | kv | y |  |  |  |
| `EinkStatusRecord` | 1 | envelope | kv+table | y |  |  |  |
| `FigureImageResult` | 1 | envelope | image | y | y |  | _mcp_content: Vec<McpImageBlock> (base64 image blocks, stripped by MCP transports into the content array; other transpor |
| `HistogramResult` | 1 | nested-object | plot | y |  |  | plot: Value is a plot-spec@1.0.0 payload (typed as serde_json::Value, so no schema for it) |
| `ImportSummary` | 1 | nested-object | kv | y |  |  |  |
| `ItemListResult` | 1 | envelope | kv+table | y | y |  |  |
| `ItemResult` | 1 | envelope | kv | y | y |  | payload is a JSON object serialized as a String (must be re-parsed), bounded/truncated |
| `LandingPageReport` | 1 | flat-object | kv |  |  |  |  |
| `LatexCompileResultDto` | 1 | nested-object | kv | y |  |  |  |
| `LayoutListResult` | 1 | envelope | kv+table | y | y | y |  |
| `LayoutResult` | 1 | envelope | kv | y | y | y |  |
| `MboxParseReport` | 1 | nested-object | kv+table |  |  |  |  |
| `MemberCountsResult` | 1 | envelope | kv | y | y |  |  |
| `MigrationReportResult` | 1 | envelope | kv+table | y | y |  |  |
| `MigrationStatusResult` | 1 | envelope | kv+table | y | y |  |  |
| `ModelsResult` | 1 | nested-object | kv+table |  |  |  |  |
| `NextTestResult` | 1 | envelope | kv | y |  |  |  |
| `Option<AnnotationRecord>` | 1 | flat-object | kv | y |  |  | image_path: Option<String> is a file path to an ink/highlight image, not shown inline |
| `Option<CollectionRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<ConversationOutline>` | 1 | nested-object | kv | y |  |  |  |
| `Option<DatasetRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<DismissedPaperRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<DocumentSummary>` | 1 | flat-object | kv |  |  |  |  |
| `Option<EinkDeviceRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<FigureRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<LinkedFileRecord>` | 1 | flat-object | kv | y |  |  | relative_path is a file path; describes a PDF/attachment, no bytes |
| `Option<MessageRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<MutedItemRecord>` | 1 | flat-object | kv | y |  |  |  |
| `Option<PublicationDetailRecord>` | 1 | nested-object | kv | y |  |  |  |
| `Outline` | 1 | nested-object | list |  |  |  |  |
| `PageExtractionReport` | 1 | nested-object | kv+table |  |  |  |  |
| `PageImageResult` | 1 | envelope | image | y | y |  | _mcp_content: Vec<McpImageBlock> (base64 page image blocks, stripped by MCP transports) |
| `PairingLinkResult` | 1 | flat-object | kv |  |  |  |  |
| `PaneResult` | 1 | envelope | kv | y | y | y |  |
| `PapersWindowResult` | 1 | nested-object | kv | y |  |  |  |
| `PdfResolutionReport` | 1 | nested-object | kv |  |  |  |  |
| `PhotoEvidenceSearchResult` | 1 | envelope | kv+table | y | y |  |  |
| `PresentationOutlineDto` | 1 | nested-object | kv+table | y |  |  |  |
| `PresetListResult` | 1 | envelope | kv+table | y | y | y |  |
| `ProcedureListResult` | 1 | envelope | kv+table | y |  |  |  |
| `ProducedRowsResult` | 1 | envelope | kv | y | y |  |  |
| `ProjectBuildOutputResult` | 1 | envelope | kv | y | y |  | path is a file path; blob_ref names a stored blob (no bytes) |
| `ProjectBuildResult` | 1 | envelope | kv | y | y |  | log is a raw build log string (log widget candidate, can be large) |
| `ProjectBuildsRecord` | 1 | envelope | kv+table | y | y |  |  |
| `ProjectCheckinRecord` | 1 | envelope | kv | y | y |  | directory is a file path; checked_in/pruned are path lists |
| `ProjectCheckoutRecord` | 1 | envelope | kv | y | y |  | directory is a file path; written/unchanged are path lists |
| `ProjectCitationsRecord` | 1 | envelope | kv+table | y | y |  |  |
| `ProjectCompileRecord` | 1 | envelope | kv+table | y | y |  | pdf_path / svg_paths are file paths |
| `ProjectFigureResult` | 1 | envelope | kv | y | y |  | build_json: Option<String> is JSON serialized as a string |
| `ProjectFileContentRecord` | 1 | envelope | text | y | y |  | text: Option<String> is the full file body (large); temp_path is a file path for binary files |
| `ProjectGraphRecord` | 1 | envelope | kv+table | y | y |  |  |
| `ProjectImportRecord` | 1 | envelope | kv+table | y | y |  |  |
| `ProjectOutlineRecord` | 1 | envelope | kv+table | y | y |  |  |
| `ProjectReadingListRecord` | 1 | envelope | kv+table | y | y |  |  |
| `ProjectSnapshotRecord` | 1 | envelope | kv | y | y |  |  |
| `ProjectStatusRecord` | 1 | envelope | kv | y | y |  | directory is a file path; changed/added/missing are path lists |
| `ProjectSyncCollectionRecord` | 1 | envelope | kv | y | y |  |  |
| `ProviderHealthResult` | 1 | nested-object | kv |  |  |  |  |
| `ProvidersResult` | 1 | nested-object | kv+table |  |  |  |  |
| `PruneResult` | 1 | envelope | kv+table | y | y |  |  |
| `QueryRewriteReport` | 1 | flat-object | kv |  |  |  |  |
| `QueuedMessageResult` | 1 | flat-object | status |  |  |  |  |
| `RecallResult` | 1 | envelope | kv+table | y | y |  |  |
| `ReferenceResult` | 1 | envelope | kv | y | y | y |  |
| `RelatedResult` | 1 | envelope | kv+table | y | y |  |  |
| `RememberResult` | 1 | envelope | kv | y | y |  |  |
| `ReplaceResult` | 1 | flat-object | text |  |  |  | new_body is the entire document body after replacement (large) |
| `RestoreReport` | 1 | flat-object | kv | y |  |  | restored_from / safety_snapshot are file paths |
| `RetentionReport` | 1 | flat-object | kv |  |  |  |  |
| `RollbackReportResult` | 1 | envelope | kv+table | y | y |  |  |
| `SchedulerStatusReport` | 1 | nested-object | kv+table |  |  |  |  |
| `SearchIntentReport` | 1 | nested-object | kv |  |  |  |  |
| `SearchResult` | 1 | envelope | kv+table | y | y |  |  |
| `SeriesResult` | 1 | nested-object | plot | y |  |  |  |
| `SessionListResult` | 1 | envelope | kv+table | y |  |  |  |
| `SidebarView` | 1 | nested-object | kv+table | y |  |  |  |
| `StatusResult` | 1 | envelope | kv+table | y | y |  |  |
| `SupersedeResult` | 1 | envelope | kv | y | y |  |  |
| `SurfaceDeleteResult` | 1 | envelope | status | y | y | y |  |
| `SurfaceDispatchResult` | 1 | envelope | raw-json | y | y | y | tree: Option<impress_surface::RenderTree> — a surface render tree; only the surface renderer can draw it (a generic view |
| `SurfaceEventsResult` | 1 | envelope | kv+table | y | y | y |  |
| `SurfaceExamplesResult` | 1 | envelope | raw-json | y | y | y | examples: Vec<SurfaceSpec> — full surface specs (deep nested widget trees) |
| `SurfaceListResult` | 1 | envelope | kv+table | y | y | y |  |
| `SurfaceRenderResult` | 1 | envelope | raw-json | y | y | y | tree: Option<RenderTree> — surface render tree, needs the surface renderer |
| `SurfaceSchemaResult` | 1 | envelope | raw-json | y | y | y | schema: serde_json::Value is a JSON Schema document; example: SurfaceSpec; rules: SurfaceRules |
| `SurfaceShowResult` | 1 | envelope | kv | y | y | y |  |
| `SurfaceValidateResult` | 1 | envelope | kv+table | y | y | y |  |
| `SurfaceWaitResult` | 1 | envelope | kv+table | y | y | y |  |
| `SyncNudgeResult` | 1 | flat-object | status | y |  |  |  |
| `TaskStatusResult` | 1 | nested-object | kv |  |  |  |  |
| `Vec<ActivityEntry>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<AnchorStateDto>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<ArtifactRelationRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<CitationUsage>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<CiteKeyUsage>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<CollectionRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<ConversationRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<DatasetRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<DismissedPaperRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<DocumentSummary>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<EinkAwaitingSourceRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<EinkDeviceRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<EinkFolderNeedRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<EinkMirrorRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<EinkOcrJobRecord>` | 1 | list-of-records | table | y |  |  | image_path is a file path |
| `Vec<EinkUnmatchedRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<ExternalPaper>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<FailedTaskReport>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<FigureRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<LibraryRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<LinkedFileRecord>` | 1 | list-of-records | table | y |  |  | relative_path is a file path; describes a PDF/attachment, no bytes |
| `Vec<ManuscriptRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<MutedItemRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<PendingReviewReport>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<PublisherRuleReport>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<SciXLibraryRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<SearchHitDto>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<SectionRecord>` | 1 | list-of-records | table |  |  |  | body is the full section text (large); Uuid ids |
| `Vec<SmartSearchRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<TagRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<TagWithCount>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<TemplateRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<TextMatch>` | 1 | list-of-records | table |  |  |  |  |
| `Vec<UndoGroupRecord>` | 1 | list-of-records | table | y |  |  |  |
| `Vec<u8>` | 1 | list-of-scalars | raw-json | y |  |  | export_document returns raw file bytes; serde_json serializes Vec<u8> as a JSON array of integers (one number per byte)  |
| `VwCapabilities` | 1 | flat-object | kv | y |  |  |  |
| `WatchedFileListResult` | 1 | envelope | kv+table | y | y |  |  |
| `WatchedFolderListResult` | 1 | envelope | kv+table | y | y |  |  |
| `WatchedFolderRemovalResult` | 1 | envelope | status | y | y |  |  |
| `WatchedScanResult` | 1 | envelope | kv+table | y | y |  |  |
| `WriteResult` | 1 | envelope | status | y | y |  |  |

## Appendix A4 — safety evidence (destructive verbs and every verb whose class is not obvious)

| Tool | Class | Evidence |
|---|---|---|
| `collection-service_delete` | destructive | crates/impress-store-service/src/collection_service.rs:577 collection_ops::delete -> crates/impress-core/src/collection_ops.rs:1035 store.delete(id); kernel returns a restore snapshot but the service drops it (collection_service.rs:578 `Ok(_snapshot)`), so no  |
| `collection-service_rollback` | destructive | crates/impress-store-service/src/collection_service.rs:777 -> crates/impress-core/src/collection_migration.rs:450 raw `UPDATE items SET schema_ref, payload` restoring frozen payloads (post-migration edits discarded) and DELETE marker in one tx; collection_serv |
| `docs-import-service_import-directory` | destructive — not obvious | crates/impress-store-service/src/docs_import_service.rs:893 fs::read every file, then (non-dry) collection_ops::create (docs_import_service.rs:1008), insert_document store.insert (docs_import_service.rs:1583) or update_document (docs_import_service.rs:1607) Se |
| `docs-import-service_prune-empty-manuscripts` | destructive | crates/impress-store-service/src/docs_import_service.rs:1148 `if apply { store.delete(item.id) }` on every manuscript whose trimmed body_content <= max_body_chars; apply is a required bool with no default, so report-only is the dry path; no undo. |
| `docs-import-service_remove-watched-folder` | destructive | crates/impress-store-service/src/docs_import_service.rs:1296 -> crates/impress-core/src/watched_folder_ops.rs:685-690 store.delete of every watched-file row when delete_file_rows, then store.delete(folder); no undo; disk and produced rows untouched; missing fo |
| `imbib-annotations-service_update-comment` | destructive — not obvious | crates/imbib-service/src/annotations_service.rs:318 -> crates/imbib-core/src/unified/store_api.rs:3278-3288 store.update (NOT update_with_undo) overwrites the comment's `text` wholesale; prior text is gone and nothing is in the operation log. Doc says 'Edit th |
| `imbib-app-service_delete-annotation` | external/destructive | crates/imbib-service/src/app_service.rs:349 default refuses; HTTP DELETE /api/annotations/{id} -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:1476 store.deleteItem -> apps/imbib/PublicationManagerCore/Sou |
| `imbib-app-service_delete-collection` | external/destructive | crates/imbib-service/src/app_service.rs:357 default refuses; HTTP DELETE /api/collections/{id} -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:758 store.deleteItem (generic delete; membership edges lost, p |
| `imbib-app-service_delete-comment` | external/destructive | crates/imbib-service/src/app_service.rs:353 default refuses; HTTP DELETE /api/comments/{id} -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:1235 -> crates/imbib-core/src/unified/store_api.rs:1771 delete_co |
| `imbib-app-service_delete-smart-searches` | external/destructive | crates/imbib-service/src/app_service.rs:361 default refuses; HTTP DELETE /api/smart-searches (apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/HTTPAutomationRouter.swift:5001-5013) -> RustStoreAdapter.deleteSmartSearch; rows removed, |
| `imbib-app-service_resolve-identifier` | external/mutating — not obvious | crates/imbib-service/src/app_service.rs:369 default refuses; HTTP POST /api/papers/resolve (apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/HTTPAutomationRouter.swift:2564-2585 handleResolvePaper): cascade local lookup -> external f |
| `imbib-app-service_update-notes` | external/destructive | crates/imbib-service/src/app_service.rs:345 default refuses; HTTP PUT /api/papers/{citeKey}/notes -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:1509 store.updateField('note') replaces the whole user note |
| `imbib-artifacts-service_delete-artifact` | destructive | crates/imbib-service/src/artifacts_service.rs:312 -> crates/imbib-core/src/unified/store_api.rs:4213 store.delete, no snapshot, no operation-log entry. HTTP backend routes the same verb to the running app (imbib-service-http/src/lib.rs); behaviour equivalent. |
| `imbib-backup-service_delete-backup` | destructive | crates/imbib-service/src/backup_service.rs:281 -> crates/imbib-core/src/unified/backup_api.rs:247 backup::delete_backup removes the file and its manifest; undo covers rows, not files. HTTP backend routes the same verb to the running app (imbib-service-http/src |
| `imbib-backup-service_prune-backups` | destructive | crates/imbib-service/src/backup_service.rs:288 -> crates/imbib-core/src/unified/backup_api.rs:253 deletes every backup beyond the newest `keep` (keep=0 deletes all); files, not undoable. HTTP backend routes the same verb to the running app (imbib-service-http/ |
| `imbib-backup-service_restore-backup` | external/destructive | crates/imbib-service/src/backup_service.rs:262 default impl REFUSES (returns error, writes nothing); HTTP backend forwards to POST /api/backups/restore which replaces the entire shared store (imprint + impel data too) after a safety snapshot. Classified by the |
| `imbib-eink-service_eink-folder-checklist` | external/read-only — not obvious | crates/imbib-service/src/eink_service.rs:802 -> crates/imbib-core/src/eink/apply.rs:1302 calls eink_plan, i.e. a LIVE tablet listing over USB; name reads like a local list. |
| `imbib-eink-service_eink-note-source-error` | mutating — not obvious | crates/imbib-service/src/eink_service.rs:913 -> crates/imbib-core/src/eink/store.rs:679 eink_note_source_attempt writes last_error/attempts on the mirror row; reads like a log message but is a store write. HTTP backend routes the same verb to the running app ( |
| `imbib-eink-service_eink-remove-device` | destructive | crates/imbib-service/src/eink_service.rs:654 -> crates/imbib-core/src/eink/store.rs:476-491 store.delete on every mirror row for the device and the device row; no snapshot/undo. Tablet untouched. HTTP backend routes the same verb to the running app (imbib-serv |
| `imbib-library-service_deduplicate-library` | destructive | crates/imbib-service/src/library_service.rs:1075 -> crates/imbib-core/src/unified/store_api.rs:2527-2584 finds dup DOI/arXiv/cite-key rows within library and store.delete()s them outright: no snapshot, no operation-log entry, not merge-aware (tags/notes on the |
| `imbib-library-service_delete-library-undoable` | destructive — not obvious | crates/imbib-service/src/library_service.rs:769 store.delete_library_undoable -> crates/imbib-core/src/unified/store_api.rs:1811-1849 store.delete(library); child pubs/collections get parent NULL; snapshot is RETURNED and DROPPED by the service (Ok(_) => ok_n( |
| `imbib-library-service_delete-publications-undoable` | destructive | crates/imbib-service/src/library_service.rs:1044 -> crates/imbib-core/src/unified/store_api.rs:1744-1762 store.delete per id; snapshots returned but discarded by service (only .len() used) and never written to the operation log, so undo-service cannot restore  |
| `imbib-library-service_dismiss-paper` | mutating — not obvious | crates/imbib-service/src/library_service.rs:1079 -> crates/imbib-core/src/unified/store_api.rs:2337-2355 store.insert of an imbib/dismissed-paper identifier TOMBSTONE; it does NOT move any publication to the Dismissed library and is not undo-logged; no verb de |
| `imbib-library-service_import-papers` | mutating — not obvious | crates/imbib-service/src/library_service.rs:1135 -> crates/imbib-core/src/unified/store_api.rs:1335-1499 batch_import_search_results: parses the BibTeX the CALLER supplies, dedups, insert_batch; NO network fetch in the default path, and the HTTP path (apps/imb |
| `imbib-library-service_purge-dismissed-from-collection` | mutating — not obvious | crates/imbib-service/src/library_service.rs:880 -> crates/imbib-core/src/unified/store_api.rs:967-1044: finds members whose ids match dismissed tombstones and calls remove_from_collection (undo-logged membership removal); deletes NO publication rows despite 'p |
| `imbib-manuscripts-service_create-manuscript` | external/mutating — not obvious | crates/imbib-service/src/manuscripts_service.rs:238 default refuses; HTTP POST /api/manuscripts creates a row (crates/imbib-service-http/src/lib.rs:1507). Doc does not say it needs the app. |
| `imbib-manuscripts-service_create-manuscript-from-template` | external/mutating — not obvious | crates/imbib-service/src/manuscripts_service.rs:272 default refuses; HTTP creates a scaffolded row (crates/imbib-service-http/src/lib.rs:1560). Needs-app not stated. |
| `imbib-manuscripts-service_get-manuscript` | external/read-only — not obvious | crates/imbib-service/src/manuscripts_service.rs:234 default refuses; HTTP GET /api/manuscripts/{id} (crates/imbib-service-http/src/lib.rs:1498). Needs-app not stated in doc. |
| `imbib-manuscripts-service_list-manuscripts` | external/read-only — not obvious | crates/imbib-service/src/manuscripts_service.rs:230 default REFUSES even this read (rows are in the shared store but the service will not read them); HTTP backend GET /api/manuscripts (crates/imbib-service-http/src/lib.rs:1492). Description says 'in the shared |
| `imbib-manuscripts-service_list-templates` | external/read-only — not obvious | crates/imbib-service/src/manuscripts_service.rs:268 default refuses; HTTP GET templates (crates/imbib-service-http/src/lib.rs:1554). Needs-app not stated. |
| `imbib-manuscripts-service_write-manuscript-body` | external/destructive | crates/imbib-service/src/manuscripts_service.rs:246 default refuses; HTTP (crates/imbib-service-http/src/lib.rs:1520) replaces the ENTIRE body (compare-and-set on content_hash; Automerge keeps history but the verb overwrites user prose). Doc says so. |
| `imbib-scix-service_add-to-scix-library` | mutating — not obvious | crates/imbib-service/src/scix_service.rs:160 -> crates/imbib-core/src/unified/store_api.rs:3056 local membership edge only on the store path; HTTP path may sync to ADS via the app's SciXLibraryService. Fallback description. |
| `imbib-scix-service_count-scix-library-publications` | read-only — not obvious | crates/imbib-service/src/scix_service.rs:217 -> crates/imbib-core/src/unified/store_api.rs:2852 local count. Fallback description; name suggests remote. HTTP backend routes the same verb to the running app (imbib-service-http/src/lib.rs); behaviour equivalent. |
| `imbib-scix-service_create-scix-library` | mutating — not obvious | crates/imbib-service/src/scix_service.rs:138 -> crates/imbib-core/src/unified/store_api.rs:2993 inserts a LOCAL mirror row (remote_id supplied by caller); does not create anything on ADS. Fallback description. HTTP backend routes the same verb to the running a |
| `imbib-scix-service_get-scix-library` | read-only — not obvious | crates/imbib-service/src/scix_service.rs:130 -> crates/imbib-core/src/unified/store_api.rs:3039 local get. Fallback description; name suggests remote. HTTP backend routes the same verb to the running app (imbib-service-http/src/lib.rs); behaviour equivalent. |
| `imbib-scix-service_list-scix-libraries` | read-only — not obvious | crates/imbib-service/src/scix_service.rs:121 -> crates/imbib-core/src/unified/store_api.rs:3015 query local imbib/scix-library rows; no ADS/SciX network call. Name suggests remote; fallback description. HTTP backend routes the same verb to the running app (imb |
| `imbib-scix-service_query-scix-library-publications` | read-only — not obvious | crates/imbib-service/src/scix_service.rs:194 -> crates/imbib-core/src/unified/store_api.rs:3115 local query. Fallback description; name suggests remote. HTTP backend routes the same verb to the running app (imbib-service-http/src/lib.rs); behaviour equivalent. |
| `imbib-scix-service_remove-from-scix-library` | mutating — not obvious | crates/imbib-service/src/scix_service.rs:177 -> crates/imbib-core/src/unified/store_api.rs:3079 local membership edge removal (no publication deleted); HTTP path DELETE /api/scix-libraries/{id}/papers may push to ADS. Fallback description. |
| `imbib-tags-service_delete-tag-undoable` | destructive | crates/imbib-service/src/tags_service.rs:203 -> crates/imbib-core/src/unified/store_api.rs:1885-1917 delete_tag: store.delete of the definition + RemoveTag on every tagged publication; snapshot returned and DROPPED by the service, no operation-log entry (doc s |
| `impel-service_cancel-task` | destructive | crates/impel-service/src/lib.rs:660 TaskStoreApi::transition(Cancelled) (impel-core/src/task_store.rs:233 apply_operation on the shared SQLite store) then :674-699 walks dependents and cancels each pending one; cancelled is terminal (:650 refuses any further t |
| `implore-service_plot-histogram` | external — not obvious | crates/implore-service-http/src/lib.rs:335 POST /api/plot/histogram, but apps/implore/.../ImploreHTTPRouter.swift:143 only routes it under GET (routePOST:185 answers 404), so the verb returns None even with implore up; default lib.rs:492 refuses; the app's han |
| `implore-service_plot-series` | external — not obvious | crates/implore-service-http/src/lib.rs:324 POST /api/plot/svg, but ImploreHTTPRouter.swift:140 serves it as GET only (POST -> 404 at :185), so the verb always yields None; default lib.rs:488 refuses; app handler router:945 renders SVG in memory from the rg dat |
| `implore-service_rg-batch` | external — not obvious | crates/implore-service-http/src/lib.rs:397 POST /api/rg/batch -> ImploreHTTPRouter.swift:876 computes one slice+PNG per position in memory (does not change viewer state, writes nothing); default lib.rs:521 refuse_json |
| `implore-service_rg-cascade-plot` | external — not obvious | crates/implore-service-http/src/lib.rs:407 GET /api/rg/cascade_plot -> ImploreHTTPRouter.swift:990 viewer.dataset.plotCascadeStats() in memory, returns SVG, no writes; default lib.rs:527 refuse_json |
| `implore-service_rg-slice-png` | external — not obvious | crates/implore-service-http/src/lib.rs:361 POST /api/rg/slice/png, but ImploreHTTPRouter.swift:126 serves it GET-only (POST -> 404) so the verb returns {error}; the GET handler :683 returns raw PNG bytes unless format=base64 (not JSON either way for the client |
| `implore-service_rg-slice-raw` | external — not obvious | crates/implore-service-http/src/lib.rs:383 POST /api/rg/slice/raw, but ImploreHTTPRouter.swift:129 routes it GET-only (POST -> 404) so the verb returns {error}; handler :769 reads slice values in memory; default lib.rs:515 refuse_json |
| `implore-service_rg-slice-save` | external/destructive | crates/implore-service-http/src/lib.rs:370 POST /api/rg/slice/save -> ImploreHTTPRouter.swift:751 pngData.write(to: path) overwrites any existing file at the caller-given path with no check; default lib.rs:512 refuse_json |
| `implore-service_rg-statistics` | external — not obvious | crates/implore-service-http/src/lib.rs:391 POST /api/rg/statistics, but ImploreHTTPRouter.swift:132 routes it GET-only (POST -> 404 at :185) so the verb returns {error}; handler :820 is pure in-memory stats; default lib.rs:518 refuse_json |
| `impress-ai-service_ai-health` | external — not obvious | crates/impress-ai-service/src/lib.rs:660 reqwest GET http://127.0.0.1:8787/api/health with 3 s timeout against the impress-ai daemon; returns daemon_reachable:false rather than an error when it is down; no store access, despite the 'store-hygiene' wording. |
| `impress-ai-service_list-models` | external — not obvious | crates/impress-ai-service/src/lib.rs:330 registry.models() -> crates/impress-ai/src/registry.rs:447: with no provider ensure_local_health() probes local hosts, then registry.rs:485 client.models().await hits the provider's API for Discovery::Api providers (sta |
| `impress-ai-service_list-providers` | external — not obvious | crates/impress-ai-service/src/lib.rs:351 preferences().load() (file read) then lib.rs:356 registry.provider_states_probed() -> crates/impress-ai/src/registry.rs:599 ensure_local_health() probes each stale Rust-hosted local provider (oMLX/Ollama) over HTTP via  |
| `impress-bridges-service_conversation-decisions` | external — not obvious | crates/impress-bridges-service/src/lib.rs:603 impart_service::service_instance().get_conversation over the BackendSlot (default impart-service/src/lib.rs:193 refuses -> []), returns just the summary field (lib.rs:606) rather than recorded decisions; read only. |
| `impress-bridges-service_conversation-to-outline` | external — not obvious | crates/impress-bridges-service/src/lib.rs:616 impart_service::service_instance().get_conversation (default crates/impart-service/src/lib.rs:193 refuses -> None without impart; HTTP backend to running impart) then fixed section list + conversation_decisions + e |
| `impress-bridges-service_export-conversation-citations` | external — not obvious | crates/impress-bridges-service/src/lib.rs:575 extract_papers_from_conversation -> impart_service::service_instance().get_conversation (default crates/impart-service/src/lib.rs:193 refuses -> empty string without impart; HTTP backend crates/impart-service-http/ |
| `impress-bridges-service_extract-papers-from-conversation` | external — not obvious | crates/impress-bridges-service/src/lib.rs:534 impart_service::service_instance().get_conversation — default crates/impart-service/src/lib.rs:193 refuses (returns []), HTTP backend crates/impart-service-http/src/lib.rs:183 GETs running impart; then pure regex e |
| `impress-bridges-service_get-citation-suggestions` | external — not obvious | crates/impress-bridges-service/src/lib.rs:418 imprint app_service_instance().get_content (default app_service.rs:240 refuses -> returns [] without imprint) then lib.rs:430 imbib search_service_instance().full_text_search (default crates/imbib-service/src/searc |
| `impress-bridges-service_list-available-figures` | external — not obvious | crates/impress-bridges-service/src/lib.rs:444 implore_service::service_instance().list_figures(None); default crates/implore-service/src/lib.rs:457 refuses and returns [] with implore closed, HTTP backend crates/implore-service-http/src/lib.rs:247 GETs the run |
| `impress-bridges-service_sync-figure` | external/destructive | crates/impress-bridges-service/src/lib.rs:507 implore_service::service_instance().export_figure — default crates/implore-service/src/lib.rs:484 refuses (ok:false), HTTP backend crates/implore-service-http/src/lib.rs:304 has running implore re-export and overwr |
| `impress-surface-service_surface-delete` | destructive | crates/impress-surface-service/src/service.rs:744-772 surfaces_for_write().delete -> store.rs:378-394 store.delete() of every state row, every event row and the surface row (hard deletes, no operation/undo), then registry.forget_surface; second call refuses no |
| `impress-surface-service_surface-render` | read-only — not obvious | crates/impress-surface-service/src/service.rs:851-886 registry.with -> runtime.bind_params + runtime.render; runtime.rs:999-1075 render only fills an in-memory source cache, never persist_state; runtime.rs:1631-1676 SessionRegistry::with reads surface+state ro |
| `imprint-app-service_delete-comment` | external/destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/app_service.rs:301 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-app-service_delete-text` | external/destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/app_service.rs:250 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-app-service_replace` | external/destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/app_service.rs:255 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-app-service_update-metadata` | external/destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/app_service.rs:236 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-manuscript-service_compile-latex` | read-only — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:463 spawn_blocking -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers |
| `imprint-manuscript-service_delete-section` | destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:372 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers.rs:418 -> /Use |
| `imprint-manuscript-service_document-citations` | read-only — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:399 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers.rs:433 -> /Use |
| `imprint-manuscript-service_document-outline` | read-only — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:389 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers.rs:427 -> /Use |
| `imprint-manuscript-service_put-section` | mutating — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:351 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers.rs:400 handler |
| `imprint-manuscript-service_reorder-presentation-slide` | read-only — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:428 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:2 |
| `imprint-manuscript-service_replace-in-section` | destructive — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:505 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers.rs:458 get_sec |
| `imprint-manuscript-service_search-in-text` | read-only — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:409 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/handlers.rs:437 -> /Use |
| `imprint-manuscript-service_set-presentation-slide-beat` | read-only — not obvious | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:437 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/manuscript_service.rs:2 |
| `imprint-project-service_project-checkout` | destructive | crates/imprint-service/src/project_service.rs:3213 imprint_core::project::materialize into the caller's directory (materialize.rs:145-208 write_atomic overwrites any existing file at a project path, removes files listed in its own .ledger) then mp::set_working |
| `imprint-project-service_project-delete-file` | destructive | crates/imprint-service/src/project_service.rs:1267 mp::delete_file -> manuscript_project.rs:549-560 store.delete(row.id); no undo ring, blob bytes stay in the CAS; refuses external_source. |
| `imprint-project-service_project-export` | destructive | crates/imprint-service/src/project_service.rs:2464 imprint_core::project::export (materialize.rs:257-289): create_dir_all then write_atomic for every file plus manifest.json — unconditional overwrite of same-named files in the user-chosen directory, no ledger, |
| `imprint-project-service_project-figure-preview` | external — not obvious | crates/imprint-service/src/project_service.rs:1665 render_figure_impl(record=false) -> build.rs:727-790 render_figure: for veusz/shell runners it materialises the whole tree into <cache>/impress/imprint/project-preview/<manuscript>/ (:2973) and build.rs:427-45 |
| `imprint-project-service_project-put-file` | destructive | crates/imprint-service/src/project_service.rs:1242 mp::put_file -> manuscript_project.rs:370-470: an existing row's content/blob_ref/content_hash are replaced via store.update with no revision of the prior content (only >INLINE_TEXT_LIMIT bytes survive as an o |
| `imprint-selftest-service_run-selftest` | external/mutating — not obvious | crates/imprint-selftest/src/service.rs:38 -> lib.rs:71-87; tier A (tier_a.rs:31,97) runs against tempfile workspaces / SqliteItemStore::open_in_memory only and compiles LaTeX via Tectonic and Typst in-process (tier_a.rs:980,442; compute, slow); tier B (tier_b. |
| `imprint-throughline-service_delete-throughline` | destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/throughline_service.rs:219 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/throughline.rs:555 del |
| `imprint-throughline-service_update-throughline-source` | destructive | /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/throughline_service.rs:209 -> /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb3dc8e891e/crates/imprint-service/src/throughline.rs:714 upd |
| `layout-selftest-service_run-selftest` | external/mutating — not obvious | selftest.rs:48-62: tier 'a' (and any unrecognised tier) runs tier_a.rs:92-94 over a private SqliteItemStore::open_in_memory (no user-store rows); tier 'b' and the default 'all'/'' run tier_b.rs:389-458 which drives the running app over HTTP with reqwest (tier_ |
| `layout-service_apply-layout` | destructive — not obvious | service.rs:1968-2061 verb_for_write -> apply_tree service.rs:1432-1453 session.replace (session.rs:376-378 drops both undo rings) + session.save overwrites the live arrangement row (store.rs:258); an ordinal/name that is a preset goes through apply_preset_row  |
| `layout-service_apply-preset` | destructive — not obvious | service.rs:2347-2369 -> presets.ensure_shipped (seeds rows) -> apply_preset_row service.rs:1462-1495 -> apply_tree service.rs:1432-1453 session.replace (session.rs:376-378 resets both undo rings) then session.save overwrites the live arrangement row (store.rs: |
| `layout-service_close` | mutating — not obvious | service.rs:1570-1583 apply_verb(Verb::Close) removes a pane/subtree from the live tree -> store.rs:258 patch (Ephemeral); undo.rs:138 ARRANGEMENT ring so the close IS undoable (undo stack=arrangement) — the patch reverts it; never the last pane; no durable row |
| `layout-service_commit` | destructive — not obvious | service.rs:1885-1928 as_kind 'layout'/'' delegates to save_layout (store.rs:401 save_named overwrite + commit_boundary), 'preset' delegates to save_preset (presets.rs:1316 overwrite + commit_boundary + DerivedFrom edge), anything else refused invalid-argument; |
| `layout-service_delete-layout` | destructive | service.rs:2063-2079 -> delete_named_as service.rs:1241-1274 (refuses presets, ensure_shipped seeds first) -> store.rs:459-467 store.delete(row.id) hard delete of the named layout row, operations cascade, tombstone carries no author; NOT on any undo ring; miss |
| `layout-service_reset-preset` | destructive | service.rs:2445-2477 layout_store_for_write (refuses store-unavailable on fallback store) -> presets.rs:1373-1395 reset -> presets.rs:1316-1368 save patches layout/queries/roles/purpose/version of the user-edited preset row (Durable, Editorial) over the user's |
| `layout-service_save-layout` | destructive | service.rs:1930-1966 verb_for_write -> store.rs:401-443 save_named inserts a new row or PATCHES the existing same-named row's layout/purpose (Ephemerality::Commit, durable) — an existing name is overwritten with no undo; then session.commit_boundary() session. |
| `layout-service_save-preset` | destructive | service.rs:2371-2443 with_session_for_write -> presets.rs:1316-1368 save inserts a new preset row or PATCHES an existing one (including a shipped preset) with the live tree, Durable; then session.commit_boundary() (session.rs:370) clears BOTH undo rings and re |
| `memory-service_forget` | destructive — not obvious | crates/impress-memory-service/src/lib.rs:1349-1406 store.apply_operation SetPayload(NO_RECALL_FIELD=true, Durable/Editorial) — a soft hide, the row and edges stay; but no verb un-forgets it (only a direct store edit), so not undoable through the service. |
| `source-service_get-figure-image` | external — not obvious | crates/impress-store-service/src/source_service.rs:1428 render_page -> crates/impress-store-service/src/source_assets.rs:242 spawns `osascript -l JavaScript` (PDFKit) as a subprocess and writes PNGs into the render cache (source_assets.rs:240,268; crop cache s |
| `source-service_get-page-image` | external — not obvious | crates/impress-store-service/src/source_service.rs:70 render_page -> crates/impress-store-service/src/source_assets.rs:242 Command::new("osascript") PDFKit render subprocess on cache miss, PNG written to render-cache dir (source_assets.rs:240,268); reads/hashe |
| `surface-selftest-service_run-selftest` | external/mutating — not obvious | crates/impress-surface-service/src/selftest.rs:48-56 tier a -> tier_a.rs:48 World::open() uses SqliteItemStore::open_in_memory() (private store, nothing durable); tier b/all -> tier_b.rs:108-118 reqwest client to IMPRESS_SURFACE_SELFTEST_BASE_URL/http://127.0. |
| `vw-diagnostic-service_ingest-photo` | external/mutating — not obvious | crates/vw-impress-adapter/src/photo.rs:52-83 ingest(): takes a ChatGptFile {download_url,file_id} not bytes, validates https non-private URL (photo.rs:404) and downloads it with reqwest (photo.rs:263, 45 s timeout), then ingest_bytes writes blob file FileBlobS |

## Appendix A5 — every non-verb crate (first draft of `docs/verb-coverage.md`)

| Crate | Role | pub items (upper bound) | Reaches a verb | Verdict | Uncovered capabilities (examples) |
|---|---|---:|---|---|---|
| `im-bibtex` | library | 44 | yes | should-be-verb | im_bibtex::parser::{parse,parse_with_options,parse_entry} (src/parser.rs) - no #[impress_method]; import_bibtex verb ingests but does not return parsed entries; im_bibtex::formatter::{format_entry,format_entries,format_c |
| `im-identifiers` | library | 49 | yes | should-be-verb | im_identifiers::validators::{is_valid_doi,is_valid_arxiv_id,is_valid_isbn,normalize_doi,normalize_arxiv_id} (src/validators.rs) - no verb; im_identifiers::resolver::{identifier_url,identifier_display_name,preferred_ident |
| `imbib-cli` | binary | 0 | yes | internal |  |
| `imbib-core` | domain-core | 1294 | yes | should-be-verb | imbib_core::ris::{parse,format,ris_to_bibtex} + import::import_ris / export::export_ris (src/ris/, src/import/mod.rs, src/export/mod.rs) - no verb (import_bibtex/export_bibtex exist, RIS does not); imbib_core::merge::mer |
| `imbib-service-http` | service-http | 21 | yes | internal |  |
| `impart-core` | domain-core | 128 | no | should-be-verb | impart_core::provenance::queries::{trace_lineage,trace_effects,artifact_history,artifact_introduction,decisions_in_conversation,decision_history,insights_in_conversation,insights_derived_from,events_by_actor,conversation |
| `impart-service-http` | service-http | 8 | yes | internal |  |
| `impel-core` | domain-core | 454 | yes | should-be-verb | impel_core::escalation::{Escalation::new,acknowledge,resolve,resolve_with_option,dismiss} (src/escalation/) - no verb (only via impel-server HTTP); impel_core::coordination::{available_threads,threads_by_state,open_escal |
| `impel-enrichment` | library | 16 | no | internal | impel_enrichment::classify::HeuristicClassifier / LlmClassifier (src/classify.rs, classify_llm.rs) - classify a publication, no verb; impel_enrichment::metadata_resolve::MetadataResolveExecutor - runs only as a task; imp |
| `impel-memory` | library | 32 | no | internal | impel_memory::claim_distill::{build_prompt,parse_reply} - internal to consolidation; impel_memory::spawn::plan_memory_tasks - daemon only |
| `impel-server` | binary | 83 | no | should-be-verb | impel_server::http::{list_escalations,create_escalation,acknowledge_escalation,resolve_escalation,poll_escalation} (src/http.rs) - no verb; impel_server::http::{list_threads,create_thread,claim_thread,submit_for_review,c |
| `impel-taskd` | binary | 0 | no | internal |  |
| `impel-throughline` | library | 15 | no | internal | impel_throughline::draft_prompt::{build_prompt,parse_reply}, TemplateDrafter/LlmDrafter - drafting a proposal on demand has no verb (only the scheduled executor) |
| `impel-tools` | glue/inventory | 9 | yes | internal |  |
| `impel-tui` | binary | 57 | no | internal |  |
| `implore-core` | domain-core | 619 | yes | should-be-verb | implore_core::plugin (85 pub fns, src/plugin/) - plugin registry, no verb; implore_core::library (24) and dataset (21) - dataset catalogue only reachable via list_datasets/get_dataset over HTTP (app must run); implore_co |
| `implore-io` | library | 52 | no | should-be-verb | implore_io::reader::open_file / DataReader (src/reader.rs) - no verb opens a CSV/HDF5/FITS/Parquet/NPZ and returns schema/columns; implore_io::hdf5_reader::Hdf5Reader::list_datasets, npz_reader::NpzFile::{array_names,pee |
| `implore-selection` | library | 47 | no | internal | implore_selection::parser::parse_selection (src/parser.rs) and eval::Evaluator::{evaluate,selected_indices} - no verb |
| `implore-service-http` | service-http | 8 | yes | internal |  |
| `implore-stats` | library | 51 | no | should-be-verb | implore_stats::ecdf::Ecdf::{from_data,quantile,five_number_summary} (src/ecdf.rs) - no verb; implore_stats::summary::SummaryStats::{from_data,zscore,robust_zscore,winsorize} (src/summary.rs) - no verb; implore_stats::pcd |
| `impress-ai` | domain-core | 302 | yes | should-be-verb | impress_ai::registry::{complete,stream} (src/registry.rs) - direct chat completion, no verb (queue_message only enqueues a conversation turn); impress_ai::registry::{set_model_enabled,set_enabled_models,set_task_category |
| `impress-ai-http` | binary | 15 | no | internal | impress_ai_http::router / Inference - HTTP transport for impress-ai chat, no verb |
| `impress-ai-tools` | glue/inventory | 5 | no | internal |  |
| `impress-app-client` | library | 172 | yes | internal | ImprintClient::{manuscript_history_count,manuscript_revisions_count,manuscript_detail_probe,get_throughline_anchors,patch_throughline_anchors} - selftest-only probes; the same data has store-service/imprint verbs |
| `impress-bibtex` | ffi | 42 | yes | internal | parse_ffi/parse_with_options_ffi/parse_entry_ffi, bdsk_file_*_ffi - Swift only (same gap as im-bibtex) |
| `impress-capabilities` | glue/inventory | 1 | no | internal |  |
| `impress-capabilities-kit` | glue/inventory | 1 | yes | internal |  |
| `impress-cli` | binary | 0 | yes | internal |  |
| `impress-collab` | library | 31 | no | internal | impress_collab::permissions::Permissions::{can_view,can_comment,can_edit,can_share} (src/permissions.rs) - no verb; impress_collab::presence::PresenceInfo (src/presence.rs) - no verb |
| `impress-core` | library | 545 | yes | covered | impress_core::sync (17 pub fns; also 12 sync_* on ImbibStore and SharedStore) - CloudKit-style outbox/tombstones, Swift only (correctly internal); impress_core::maintenance (2) and task_schema_migration (11) - no verb; m |
| `impress-domain` | library | 137 | no | should-be-verb | impress_domain::citation_reference::{create_citation_reference,citation_to_typst,citation_to_latex,create_citation_batch,citation_batch_combined_bibtex} (src/citation_reference.rs) - Swift only; imprint compose_citation  |
| `impress-embeddings` | library | 68 | yes | should-be-verb | impress_embeddings::chunk_index::ChunkIndex::{search,search_scoped} (src/chunk_index.rs) - no verb (store-service search_content_chunks is the store-side variant; impress-mcp exposes search_papers/get_paper_chunks as non |
| `impress-flags` | library | 18 | no | should-be-verb | impress_flags::query::{parse_flag_query,FlagQuery::matches} (src/query.rs) - no verb; impress_flags::parse::parse_flag_command (src/parse.rs) - no verb; impress_flags::flag::{FlagColor::from_char,display_name,FlagStyle,F |
| `impress-git` | library | 51 | no | should-be-verb | impress_git::commands::{status_cmd,commit_cmd,log_cmd,diff_cmd,push_cmd,pull_cmd,clone_cmd,checkout_cmd,branch_list_cmd} + parse::{parse_status_porcelain_v2,parse_log,parse_diff_stat} (src/commands.rs, src/parse.rs) - no |
| `impress-helix` | library | 137 | no | internal | HelixState / FfiHelixEditor::handle_key - keystroke state machine, UI only |
| `impress-identifiers` | ffi | 75 | yes | internal | 31 of 35 *_ffi fns have no verb (see im-identifiers list) |
| `impress-layout` | library | 159 | yes | covered |  |
| `impress-mcp` | binary | 37 | yes | should-be-verb | impress_mcp::tools::{tool_search_papers,tool_get_paper_chunks,tool_list_indexed_papers} (src/tools.rs) - agent-reachable via this MCP only, no verb; overlaps memory-service recall / store-service search_content_chunks; i |
| `impress-mcp-host` | glue/inventory | 9 | no | internal |  |
| `impress-pane-query` | kit-pure | 19 | yes | covered |  |
| `impress-plot` | library | 69 | yes | should-be-verb | impress_plot::render::{LinePlot::render,Hist2DFigure::render,ContourFigure::render} (src/render.rs) - reached only through a project figure build, no direct spec->SVG/Typst verb; impress_plot::hist2d::Hist2D::{from_grid, |
| `impress-remarkable` | library | 80 | yes | covered | impress_remarkable::rm::parse_rm / RmScene (src/rm/) - reached only inside eink_import ink rendering; no verb returns strokes/text of a page; impress_remarkable::rmdoc::build_rmdoc (src/rmdoc.rs) - reached via eink_sync; |
| `impress-service-core` | glue/inventory | 52 | yes | internal |  |
| `impress-service-macros` | glue/inventory | 6 | yes | internal |  |
| `impress-smart-search` | library | 56 | yes | covered | impress_smart_search::rewriter::{filter_authors,extract_decade,decode_cloud_json} - only via rewrite_free_text_query; ok; impress_smart_search::url_extract::extract_title - not directly exposed (extract_page_identifiers  |
| `impress-sources` | library | 29 | no | should-be-verb | impress_sources::SourcePlugin::{search,fetch_by_doi,...} for ArxivSource/CrossrefSource/AdsSource/OpenAlexSource/PubmedSource/SemanticScholarSource/WosSource (src/*.rs) - no Rust verb; search_sources refuses when the app |
| `impress-store-ffi` | ffi | 314 | yes | internal | SharedStore::{upsert_item,upsert_item_v2,upsert_items,upsert_item_guarded,add_reference,remove_reference,set_parent,delete_item} (src/lib.rs) - generic item writes, Swift only (store-service has create/delete/reparent pe |
| `impress-surface` | library | 78 | yes | covered |  |
| `impress-tags` | library | 42 | yes | should-be-verb | impress_tags::query::{parse_tag_query,TagQuery::matches} (src/query.rs) - no verb browses/filters by tag expression; impress_tags::hierarchy::TagHierarchy::{from_tags,children_of,descendants_of,format_tree} (src/hierarch |
| `impress-toolbox` | binary | 25 | no | internal | impress_toolbox::execute::{handle_execute,handle_execute_file} (src/execute.rs) - run a local command, no verb (deliberately: unsandboxed); impress_toolbox::git::router (src/git.rs) - git status/commit/log/diff/clone ove |
| `imprint-cli` | binary | 0 | yes | internal |  |
| `imprint-core` | domain-core | 739 | yes | should-be-verb | imprint_core::selection (47 pub fns, src/selection/) - editor selection model, no verb (UI-bound, correctly internal); imprint_core::sourcemap::{generate_source_map,source_map_lookup,source_to_render_lookup} (src/sourcem |
| `imprint-service-http` | service-http | 9 | yes | internal |  |
| `scix-client-ffi` | ffi | 26 | no | should-be-verb | scix_search / scix_count (src/lib.rs) - ADS search, no Rust verb (search_sources needs the app); scix_fetch_references / scix_fetch_citations / scix_fetch_similar / scix_fetch_coreads - citation graph, no verb; scix_expo |
| `uniffi-bindgen` | tooling | 0 | no | internal |  |
| `vw-domain` | library | 75 | yes | covered |  |
| `vw-mcp` | binary | 0 | yes | internal |  |
| `vw-service` | library | 15 | yes | internal |  |
