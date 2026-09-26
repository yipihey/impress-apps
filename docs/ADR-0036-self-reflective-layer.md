# ADR-0036 — The self-reflective layer: declared effects, a verb call log, workflows and scenarios as documents, declared registries

**Status:** ACCEPTED (2026-09-26) 2026-09-26
**Amends:** [ADR-0034](ADR-0034-verb-descriptor-pipeline-and-transport.md) D1 (the descriptor gains an
effect set) and D2 (the audit layer writes a call record; approved decision D-P3's "one `core/operation`
row per mutating verb" becomes "one `core/verb-call` row, and `batch_id` on every operation it wrote" —
plan § Decisions D-R2 says why the row cannot be an operation).
**Builds on:** ADR-0033 (a GUI is a stored document a pure crate interprets; verbs are the only way it
computes), ADR-0034 D3 (identity from the transport; review is a surface), D6 (jobs), ADR-0035 D3
(examples as tests), D4 (marker tables CI reads), the wave-7 report and event ring, and the store's
operation log (`impress-core/src/operation.rs`).
**Plan:** [plan-self-reflective-layer.md](plan-self-reflective-layer.md) — the measurements, the
findings, the hooks this needs from P1/P2/P4/P5/G3, the work packages.

## Context

ADR-0033 turned a GUI from Swift into a stored document with a pure interpreter and a thin renderer,
and it held. Five things that decide what the environment does are still code: what a verb touches
(nothing declares it; a `verb` source cannot know when to refresh — RS-S2), what a call did (no
record joins a verb to the `core/operation` rows it wrote; `batch_id` is set by no verb), when
background work runs (31 Swift services, 11 without the 90-second gate, one a duplicate that forgot
it on one platform; the Rust daemon has durable tasks, retry and a start delay but no trigger as
data and no schedule), what a test is (79 Tier A and 25 Tier B closures, three copies of the runner
that disagree on `skipped`), and what a setting or a chord is (224 distinct `UserDefaults`/`@AppStorage`
keys in three stores, 299 `keyboardShortcut` sites in three drifting lists, 2 % of command chords
reaching Rust). The plan measured each from code; this record holds the decisions.

## Decisions

### D1 — Effects are declared on the one descriptor and verified by a store spy, never derived from code

`VerbDescriptor.effects: Effects { reads, writes, reach }` is declared per service with per-method
exceptions, exactly as P1 declares `safety`. A kind is a canonical `SchemaRef`, or `Target(arg)` /
`Children(arg)` / `Prefix(…)` for the 76 verbs whose effect is a function of an argument (a triage verb
writes the kind of whatever `id` names), or `Any` with a reason in the exception table. Reach is
`App(id) | Network | Fs | Subprocess | Device | Provider`; `App` is derived from the backend slot as
`needs_app` already is. Verification is a `SpyStore` over the examples in Tier A (`observed ⊆
declared` fails the build naming verb, kind and example) and, on every path at run time, the call
log's observed set (`effects_mismatch`, counted and shown). A verb with no headless path is listed in
`docs/verb-effects.md` with the reason the test wrote. A misspelt ref is a compile error (the macro
reads `schema-refs.json`). Consumers read the one field: surface invalidation (`query_refs` unions
verb sources' reads — RS-S2 closed), the safety-consistency test (`read_only ⇒ writes = ∅`), conflict
detection in the policy layer (destructive verbs refused `conflict` on a target another caller is
writing; mutating ones logged), and `capabilities-service_impact`.

### D2 — The audit record is a call, with `batch_id` as the join to the operation log

One new kind `core/verb-call@1.0.0`: verb, caller identity (from the pipeline, never an argument),
trace and parent ids, a privacy-filtered argument summary (ids and sizes by default; scalars ≤ 64
chars unless `#[impress_private]`; full values only for verbs declaring `replay = full` with no
private field), outcome, duration, the observed effect set, inserted/deleted ids, and `job`,
`surface`, `workflow_run`, `scenario` links. The pipeline's audit layer sets a task-local call
context around invoke; the store stamps `batch_id = call_id` on every `OperationSpec` written under
it, so "why did this item change" is `ops_for(item) → batch_id → call → parent…` over the two
indexes that already exist. Read-only calls are not recorded by default (their timing is the span's).
Records go through a bounded channel to one writer; overflow is a counter in `/api/health`, never a
silent drop. Retention follows the operation log's window and daemon; an aged row is reduced, not
lost. `history-service_{calls, why, trace, replay, save-macro, health}` are the verbs.

### D3 — A workflow is a surface without a screen, run as a job, planned by a pure crate, gated by the runtime

`impress/workflow@1.0.0` is a `SurfaceSpec` with no `root` and one `trigger` (`schedule | store | job
| message | call | manual`), guards, and the unchanged action vocabulary (`call`, `each`, `set`,
`emit`, `refresh`); the trigger payload is the event and `impress_surface::reduce` runs unchanged. A
run is a P4 job (`task@1.0.0`, kind `impress.workflow.run`) with the kernel's handle, ring, cancel,
retry and review suspension. One pure planner (`impress-workflow::plan`) is called from the daemon (a
fourth spawn rule) and from the app when no daemon holds the lease; `SchedulerConfig::start_delay`
(90 s) is the startup rule's single owner, held by a test. `validate` names an unknown verb or a
feedback loop; `dry-run` returns `would_call` without executing. An agent's workflow is stored
`proposed` and `enable` is a review for an agent. The first migration is imbib's
`RetentionCleanupService`, and the ungated macOS duplicate goes with it.

### D4 — A scenario is a document one interpreter runs against a scratch store or a running app

`impress/scenario@1.0.0`: `requires` (skip, never pass), `seed`, `steps` of `call` (with `as` for
identity, `expect` from a closed set of comparisons, `capture` by JSON path), `event` (a surface
event), `gesture` (a layout verb), `wait` (job or log line), and `teardown`; templates are the
surface's resolver. One `impress-scenario` interpreter over a `Caller` trait; Tier A is the pipeline
on a per-scenario store (hook H-P2-3) with the spy on, Tier B is the transport. The three
`run_selftest` verbs keep their names and ids. `scenario-service_record` turns a call-log trace into a
scenario. Four hand-coded Tier B entries and one recorded session are the proof; the four platform
entries stay code and say so.

### D5 — Settings and chords are declared once, in Rust, and everything else is a projection

`impress-settings` declares each setting (key, type, default, scope, legacy keys, doc) in Rust and
stores it in `<workspace>/settings/<scope>.json` the way `impress_ai::preferences` does (one store
row for the synced scope); `settings-service_{schema, list, get, set, reset}` are the verbs; Swift
reads through one UniFFI object and one `@ImpressSetting` wrapper; migration copies a legacy
`UserDefaults` value on first read and never removes it; the settings UI is ADR-0035's generated
surface over the schema. `impress-keymap` declares each binding (chord, `Verb(name, args)` or
`Command(id)`, context); Swift's `.keyboardShortcut` sites and the palette read it; CI proves every
command has a chord or a palette entry, no context has a collision, and every `Verb` binding names a
verb with valid literal args. Overrides are a device setting applied on load.

### D6 — Four new pure kit crates, two store-tier service crates, no new action kinds, no second inventory

`impress-workflow`, `impress-scenario`, `impress-settings`, `impress-keymap` are pure kit crates;
`impress-workflow-service` and `impress-scenario-service` are store tier; `history-service` and
`settings-service` live in `impress-store-service`. Every verb is an `#[impress_method]` in the
linked inventory. The surface vocabulary gains nothing; the descriptor gains one field; the
pipeline gains one record in the layer it already has.

## Alternatives rejected

- **Effects derived from the code.** The plan's static walker names a kind on 241 of 433 verbs and
  over-approximates the rest (`triage-service` "touches" the surface kind because `.update(` resolves
  to two stores); 76 verbs' effects depend on an argument and have no static answer. Derivation seeds
  the declarations (appendix A) and cannot verify them; the spy can.
- **An effect set as a second table beside the descriptor** (a `docs/verb-effects.md` that is the
  source). Two definitions of a verb drift; the table is the exception list the test writes, not the
  declaration.
- **The audit row as a `core/operation`** (D-P3 as worded). `op_target_id` is NOT NULL and a foreign
  key; a call has zero or many targets; inventing one would make the join lie.
- **Logging every call, with full arguments.** The 23 M-row backlog was mechanical churn recorded
  durably; read calls are the span's, arguments are ids and sizes, and the writer is bounded.
- **A trace id in `produced_by` instead of `batch_id`.** `produced_by` names a producing item and is
  NULL on every op row; `batch_id` is a batch key with an index and the meaning "these came from one
  call" already, extended from one store call to one verb call.
- **A new workflow engine, or a cron in Swift.** The kernel has the task, retry, review and start
  delay; the surface has the action vocabulary and reducer; what is missing is a trigger as data and
  a planner, which is 200 lines of pure Rust, not a runtime.
- **Workflow steps as a new language** (conditionals, loops). ADR-0033 D3 holds: no expressions in a
  document; `each` fans out, sources compute by calling verbs, and anything else is a verb.
- **Scenarios as Rust DSL / macros** or **YAML with expressions.** A closed comparison set over JSON
  paths covers all 25 Tier B entries (appendix B); an expression language would be a second reducer.
- **A settings store in the SQLite store only.** The daemon and the CLI would open the store to read
  a port; the AI preferences precedent chose a file for that reason. The synced scope is the one row.
- **Migrating `UserDefaults` by moving values.** A rollback would lose them; copying and leaving the
  old key costs nothing and is reversible.
- **Keeping chords in Swift with a better test.** The collision test reads one source file and three
  lists have already drifted (⌘5/⌘6, ⇧⌘F ×3); a source scan cannot see a chord a `ForEach` computes.

## Consequences

- A verb's footprint is one declared field, checked at build time on its examples and at run time on
  every call; four consumers read it and none re-derives it. RS-S2 closes; two agents writing the
  same record are told so.
- Every mutating call on every path is on the record with its caller and its operations; "why did
  this change" is a verb over MCP and the CLI; sessions become macros and scenarios.
- Background work has one owner of the startup rule, a durable job per run, a review step for
  agent-proposed automation, and a dry run before anything runs.
- Tests are documents agents can write and the log can generate; the three runners become one.
- Settings and chords exist once; the drift the census found (three imbib chord lists, a split-brain
  import setting, PMC's keys in six domains) ends by construction for what moves, and the census is
  the list of what has not moved yet.
- Ask-first items, each with a decision in the plan: four record kinds (`core/verb-call@1.0.0`,
  `impress/workflow@1.0.0`, `impress/scenario@1.0.0`, `impress/settings@1.0.0`), the amendment to
  D-P3, one kit dependency (`impress-fs-lock`), a per-call store override in the pipeline, the first
  migrated service and the deletion of its duplicate.
- Cost: one field per service in the seeding pass (appendix A), one store row per mutating call under
  the existing rate budget, four small pure crates in the manifest, and the Mac for the registries.
