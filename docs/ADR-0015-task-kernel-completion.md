# ADR-0015: Task Kernel Completion and the Enrichment Reference Implementation

**Status:** Proposed (implemented in the same change series that introduces this document)
**Date:** 2026-07-20
**Authors:** Claude (Opus 4.8 deep-work session), for Tom's review
**Depends on:** ADR-0001, ADR-0002, ADR-0005
**Scope:** impress-core task kernel, impel-core executor/scheduler, imbib enrichment reference implementation (ADR-0005 §9)

---

## Context

ADR-0005 specified the task infrastructure in detail fifteen months of commits ago. A
systematic gap audit (2026-07-20, five parallel code surveys) found:

1. **impress-core**: the generic item graph is complete and well-tested
   (operations-as-items, undo, time-travel, FTS, neighbors traversal), and
   `task@1.0.0` / `agent-run@1.0.0` schemas are registered — but *passively*.
   There is **no state-machine enforcement** (any string is a legal `state`,
   any transition permitted), **no DAG readiness query** (ADR-0005's
   "pending tasks whose DependsOn targets are all done" cannot be expressed
   in one `ItemQuery`), the **subscription interface is unusable as specified**
   (the `ItemQuery` filter is ignored — `sqlite_store.rs` `subscribe(&self, _q:)`;
   single-subscriber mpsc, second subscribe errors; `ItemEvent::Updated` is
   never emitted), and **`DeliveryHint` does not exist anywhere**.

2. **impel-core**: a pre-ADR-0005 orchestration model (threads/agents/
   escalations). Its `TaskExecutor` is a synchronous
   `fn execute(&self, task_id: &str, input: &str) -> Result<String, _>` stub
   with **zero implementors**, missing `task_kind`/`max_retries`/`is_retryable`
   and the `TaskStoreApi`. `SpawnRule`, `TaskSpec`, `TaskError`, scheduler,
   retry, and DAG precondition checks are absent. `register_impel_schemas()`
   is called by no production code.

3. **The live task system** is Swift-side (`CounselEngine`/GRDB, port 23124)
   with a **third state vocabulary** (`queued/completed` vs the ADR's
   `pending/done`), and `SharedTaskBridge` mirrors state via read-merge-
   `upsertItem` — no operation items, no attribution, no edges (despite doc
   comments claiming them). The provenance model ADR-0005 exists to protect
   is bypassed by the only system actually running.

4. **imbib enrichment** (the §9 reference implementation) exists as working
   but *ephemeral* Swift: in-memory queue, per-call retry, no task records,
   no provenance. Rust already holds the strategy layer (`enrichment/merge.rs`
   with `changed_fields` diffs, `priority.rs`, `retry.rs`) and the source
   clients (`impress-sources`: ADS/Crossref/arXiv/OpenAlex with test
   fixtures). `keyword-tag` runs as a hardcoded post-enrichment callback that
   **silently skips on low confidence** — the exact decision point ADR-0005 §8
   designed `AwaitHumanResponse` for.

## Decision

### D1. Canonical task-state vocabulary, enforced in impress-core

The five ADR-0005 states — `pending`, `running`, `done`, `failed`,
`cancelled` — are canonical. impress-core gains a task kernel module
(`crates/impress-core/src/task.rs`) with:

```rust
pub enum TaskState { Pending, Running, Done, Failed, Cancelled }
impl TaskState { pub fn parse(&str) -> Option<Self>; pub fn as_str(&self) -> &'static str; }
pub fn allowed_transition(from: TaskState, to: TaskState) -> bool; // ADR-0005 §2 table
```

and a store method:

```rust
pub fn transition_task(&self, task_id, to: TaskState, actor: &ActorId,
                       intent: OperationIntent) -> Result<(), StoreError>
```

which (a) rejects illegal transitions and unknown current states,
(b) writes the transition as a `SetPayload("state", …)` **operation item**
(never a payload merge) so attribution/time-travel/retry-ledger semantics
hold, (c) is the only blessed way to move task state.
Compat mapping for bridge use: `queued→pending`, `completed→done`
(`TaskState::parse_compat`).

### D2. DAG readiness is one SQL query

`ready_tasks(&self, limit) -> Vec<Item>` on the store: pending `task@1.0.0`
items with **no** `DependsOn` edge to a target whose payload `state` is not
`done`. Implemented as a single SQL statement over the items + references
tables (no N×neighbors loop), with a regression test that builds a random
DAG and cross-checks against a brute-force evaluation. This resolves
ADR-0005 open question 4 in favor of "the store provides it".

### D3. The event channel becomes a broadcast bus with schema filtering

`subscribe(SubscriptionFilter) -> Receiver<ItemEvent>` supports **multiple
subscribers** (each gets an independent channel), filters at minimum on
`schema_ref` prefix + event kind, and `OperationApplied` events carry
`(target_id, field, new_value_summary)` so a scheduler can react to
"a task became pending" without a re-fetch. The old single-receiver
behavior is removed (its one caller is migrated). Cross-process
notification remains out of scope (impel links impress-core in-process;
Swift apps already have Darwin notifications).

### D4. `DeliveryHint` lands with minimal semantics

The ADR-0005 §8 enum, in impress-core:
`FireAndForget` (default, current behavior), `ConfirmStored` (durability:
the write path fsync-confirms before returning — SQLite WAL checkpoint not
required; a committed transaction suffices and is documented as such),
`AwaitHumanResponse` (the write creates a `review-request@1.0.0` item
linked `OperatesOn → task`, and `transition_task` refuses to move the task
out of `running` until the review item's `resolution` field is set).
Attention routing to impart is explicitly deferred; the review item in the
graph is the contract.

### D5. impel-core adopts the ADR-0005 §7 contract verbatim

The stub `TaskExecutor` is **replaced** (zero implementors → zero breakage)
by the async trait exactly as specified in ADR-0005 §7 (`task_kind`,
`execute(task, store)`, `max_retries`, `is_retryable`), plus `TaskStoreApi`
(object-safe facade over impress-core: create item, apply ops, edges,
ready query), `TaskError` (Retryable/Permanent), `TaskSpec`, and
`SpawnRule` per §10. A `Scheduler` drives the §6 loop: poll/subscribe ready
tasks → acquire (transition to `running`, set `assigned_to`) → execute →
write `agent-run@1.0.0` + `ProducedBy` edge → transition `done`/`failed`,
with retry/backoff ported from the semantics of `imbib-core`'s
`enrichment/retry.rs` and `OperationIntent::Escalation` on exhaustion.
The duplicate `impel/agent-run` and `impel/task` schemas are deprecated in
favor of the core ones; `SharedTaskBridge`'s vocabulary is mapped via D1's
compat parse (Swift-side migration is follow-up work, not this change).

### D6. Reference implementation: two executors + one spawn rule

Per ADR-0005 §9, in a new crate `crates/impel-enrichment`:

- **`MetadataResolveExecutor`** — composes `impress-sources` clients with
  `imbib-core::enrichment::{merge, priority}`; emits `SetPayload` operations
  only for `changed_fields`; `is_retryable` maps network/rate-limit to
  retryable, not-found/parse to permanent.
- **`KeywordTagExecutor`** — classification behind a `Classifier` trait
  (LLM-backed later; deterministic heuristic now). Below the confidence
  threshold it returns output with `DeliveryHint::AwaitHumanResponse`,
  exercising D4 end-to-end instead of today's silent skip.
- **`EnrichmentSpawnRule`** — `trigger_schema = "bibliography-entry@1.0.0"`,
  builds the DAG slice (`metadata-resolve ← abstract-extract(keyword-tag)`)
  with `DependsOn` edges.
- **Integration test** (the ADR-0005 "architecture validated at scale"
  gate, scoped to the slice): insert a bibliography-entry against fixture
  HTTP responses → spawn → schedule → verify task items, edges, operation
  attribution, agent-run provenance, and an `AwaitHumanResponse` suspension
  that resumes on review resolution.

### D7. Boundaries and guards

impel-enrichment/impel-core touch SQLite **only** through impress-core's
API (ADR-0005 §6; enforced by dependency direction). The scheduler honors
the 90-second startup grace period (CLAUDE.md invariant) via a
caller-supplied `start_delay`. The CounselEngine GRDB system **coexists**;
its convergence onto the kernel is a recommended follow-up recorded here,
not performed in this series.

## Consequences

- The three-vocabulary state split ends at the kernel boundary; bridges
  translate at the edge.
- ADR-0005 open questions 1 (subscription: both — poll via `ready_tasks`,
  push via filtered bus), 4 (DAG query: store-provided SQL) and 5
  (`output_schema` validation: still deferred) are updated.
- The event-bus change is the only behavioral change to existing
  production paths; its single current subscriber is migrated in the same
  commit and covered by existing store tests plus new bus tests.
- Property-based suites (added in the same session) guard the kernel:
  transition legality, DAG readiness vs brute force, operation attribution.

## References

- ADR-0005 (contract being completed), ADR-0002 (operations), ADR-0001 (items)
- Gap audit session artifacts: five-survey code map, 2026-07-20
- `crates/imbib-core/src/enrichment/` (strategy layer), `crates/impress-sources/` (clients)
