# ADR-0035 — Generated verb surfaces, reference docs and profiles from one descriptor

**Status:** PROPOSED 2026-09-26
**Depends on:** [ADR-0034](ADR-0034-verb-descriptor-pipeline-and-transport.md) — the shared descriptor (its D1), the invoker pipeline (D2) and the verb lifecycle (D5); nothing here starts before P1/P2 of its plan, and the catalogue waits for P3.
**Builds on:** ADR-0033 (agent surfaces: verbs are the only way a surface computes; one linked
inventory), ADR-0024 (one inventory, two renderings; D3 and D8 outstanding), wave 7 (codes,
strictness, `wire_version`)
**Plan:** [plan-auto-gui-and-self-docs.md](plan-auto-gui-and-self-docs.md) — the measurements, the
findings and the work packages; this record holds only the decision.

## Context

One `#[impress_method]` already generates the MCP tool, the CLI subcommand and impel's agent tool.
ADR-0033 made a GUI a stored JSON document that computes only by calling verbs. So the same inventory
could generate a form for every verb, a reference page whose examples run as tests, and a profile of
every verb composition, with no per-verb hand work — including for the layout and surface verbs, so
the GUI layer operates and documents itself.

Measured on main at 3222f573 (plan § Measurements): 433 verbs in 38 services from 16 crates; every
one can be given a form from its input schema (347 fully typed, 86 with a raw-JSON field, none
impossible); but the descriptor carries only name, description, input schema and handler. There is
no output schema (results render as raw JSON), no safety class (MCP's `readOnlyHint` /
`destructiveHint` / `idempotentHint` / `openWorldHint` are never emitted), no example (305 verbs are
named in no document, example or test), and no grouping (ADR-0024's primary set is a table in the
server). 54 verbs still ship the `Invoke X.y` description and 951 of 1001 arguments have none. Two of
38 services are strict. Nothing on the verb path has a `tracing` span.

## Decision

### D1 — One descriptor, projected

`McpToolDescriptor` and `CliSubcommand` become projections of one `VerbDescriptor` in
`impress-service-core` that carries, beside today's four fields: `output_schema: fn() -> Value`
(derived from the return type, which must implement `JsonSchema`), `safety: Safety` (read-only /
mutating / destructive / external, plus `idempotent`, `long_running`, `needs_app`), `examples:
&'static [Example]`, `group: &'static str` (the service's domain), `surface: Surface` (ADR-0024 D3's
primary/grouped), `since: &'static str`, and `budget_ms: Option<u32>`. Every declared field is
derived where it can be (the output schema always; safety from a service default the macro checks
against a name convention; the group from the crate) and declared with a compile-time-checked
attribute where it cannot. A field that is neither derived nor declared fails a test that walks the
linked inventory, so no verb can be half-described.

### D2 — The GUI for a verb is a generated `SurfaceSpec`, in the kit

`impress-verb-surface` (a new pure kit crate) owns `verb_surface(descriptor) -> SurfaceSpec` and
`catalogue() -> SurfaceSpec`. A form is fields from the input schema (a raw-JSON field for the shapes
the CLI already takes as raw JSON), a Run button whose `call` names the verb, and a result node chosen
from the output schema (kv, table, text, plot, status). Destructive and external verbs get a review
step inside the surface (state, not a modal). The catalogue lists every linked verb grouped by
service, searchable by a query source over a new read-only verb `capabilities-service_list-verbs`,
which is the inventory as data. Nothing is added to the surface vocabulary; where a form would be
better with a widget the vocabulary lacks, the plan says so and asks.

### D3 — Examples are the documentation, the prefill and the test

An example is written once, beside the method it belongs to, as data (`#[impress_example(...)]` or
the service's Tier A catalogue registering through the same descriptor). The reference generator
prints it, the generated form prefills from it, and Tier A runs it against a scratch store and checks
the result against the output schema — an example that needs an app, the network or a device is
marked and runs in Tier B. `docs/agent-surfaces.md`'s `doc_wire.rs` is this pattern for fifteen verbs;
this makes it the pattern for all of them. No reference page is written by hand; the generator output
is the page, and CI diffs it.

### D4 — Coverage is measured from the inventory against a declared exception table

A script reads the linked inventory and a marker table in this repository listing crates and items
that are deliberately not verbs (binaries, HTTP backends, FFI projections of verbs, codecs used only by
verbs). A public capability that is in neither is a failure. The rule for "should be a verb": a `pub`
function or method in a domain core or library that takes and returns serde-shaped data and needs no
UI handle or platform API is a capability; it reaches agents through a `*-service` crate or it is
listed as internal with a reason.

### D5 — A span per verb, one aggregator, the same table as Swift

The macro's invoker enters a `tracing` span (`verb`, name, ok/code, sizes and ids — never argument
values); the few I/O seams (store reads and writes, the sibling-app HTTP client, the blob store, the
AI provider port, Typst compilation) are spans marked `io`; one aggregating subscriber keeps the
fields `PerfBucketStat` already has, so Rust's table and Swift's are one table; `perf_summary` and
`perf_trace` are verbs, so the profiler gets a generated form and an MCP surface for free; budgets
live on the descriptor and Tier A checks them on the examples.

## Alternatives rejected

- **Hand-composed surfaces per service.** A second definition of every verb's arguments and docs, kept
  in step by hand — the failure that retired the TypeScript server. Composition is allowed only
  *around* the generated form (D2), never as a copy of it.
- **A Markdown reference written from the code by a person or an agent once.** Drifts within a wave
  (the review found `docs/agent-surfaces.md` documenting seven shapes that did not exist before
  `doc_wire.rs` pinned it).
- **Output schema and safety as free attributes with no check.** The 54 `Invoke X.y` descriptions and
  the 951 undescribed arguments show what an unchecked optional becomes; every field gets a test.
- **Per-method Python shims from the macro** (the module doc's claim). Nothing today needs them and the
  claim has cost trust; one generic `call(verb, json)` over the inventory covers the need at 1/400th
  of the surface (plan § Python).
- **A second renderer now** (HTML, MCP Apps). Out of scope; the generator writes `SurfaceSpec`, which
  is renderer-neutral by ADR-0033 D2, so one can come later as a mapping.
- **Profiling through `log` lines and Swift timers.** Rust already logs through `log`; a span tree
  cannot be rebuilt from lines, and Swift cannot see inside a verb.

## Consequences

- A Rust capability becomes a GUI, a reference page, a test and a profile row by gaining a verb — and
  only by gaining a verb. Libraries reach agents through service crates, never directly, and the
  coverage check says which library items still lack that path.
- The descriptor grows; every service compiles against it. The derived fields cost nothing per verb;
  the declared ones (safety for verbs whose name does not decide it, examples) are a one-time pass
  over the inventory, which the plan sizes.
- The surface vocabulary stays closed. Three widgets would make generated forms better (a list-input
  field, a record picker, a confirm affordance); each is an ask, not a design-around.
- `strict_args` becomes the default in the same wave (plan § Strictness), because a generated form
  cannot send fields the schema does not name, and a strict verb is the only one whose schema is a
  complete description of it.
- The `log` → `tracing` move for the Rust half is a decision for Tom; until it is made, spans and
  `log` lines coexist through `tracing-log`, at the cost the plan measured.
- Two definitions of one capability drift. This ADR adds none: the descriptor is the definition, and
  the form, the page, the annotations, the profile row and the coverage table are projections that a
  test compares back to it.
