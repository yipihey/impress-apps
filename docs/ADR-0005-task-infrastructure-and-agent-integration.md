# ADR-0005: Task Infrastructure and Agent Integration

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with architectural exploration via Claude)
**Supersedes:** ADR-0003 (tasks portion only — retention tier and compaction decisions in ADR-0003 remain in effect)
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0002 (Operations as Overlay Items)
**Scope:** impress-core library, impel execution engine, imbib enrichment pipeline (Phase 3 reference implementation)

---

## Context

ADR-0003 introduced tasks as native items in the item graph, specified the `proposed → active → blocked → complete → failed` state machine, and named the imbib enrichment pipeline as the reference implementation. It deferred execution architecture to "impel's concern" without specifying the contract between impress-core and impel, what the `task@1.0.0` schema looks like concretely, or how agent invocations are recorded for provenance.

Three decisions from the initial design session that were not captured in ADR-0003 are recorded here as D20–D22:

**D20.** Tasks are items with `schema_ref: "task@1.0.0"`. Task state transitions are operation items. Task dependencies are `DependsOn` edges. (Refines ADR-0003 Decision 1 with concrete schema and edge types.)

**D21.** impel is the execution engine. impress-core stores tasks and state; impel subscribes to pending tasks and manages scheduling, retry, and rate limiting. impress-core knows nothing about execution.

**D22.** Spawn rules are Rust code in impel, not declarative items. Phase 3+ may introduce declarative spawn rules.

This ADR also introduces two concepts not in ADR-0003: the `agent-run@1.0.0` schema for recording agent invocations with full provenance, and the `DeliveryHint` model (from ADR-0001 Decision 2 — the agent channel) applied specifically to task output.

### Why tasks must be items, not a parallel system

The alternative is a separate task queue (Redis, SQLite with a dedicated schema, an in-memory queue in impel). This approach is simpler in the short term but creates a split record: research outputs live in the item graph while the process that produced them lives elsewhere. Provenance breaks. "What agent run produced these keywords?" becomes a cross-system query. Retention policy must be coordinated across two schemas. The item graph's operation stream — already the single source of truth for every other change — would be missing the most important class of changes: agent-driven enrichment.

Tasks as items means provenance is uniform. The enrichment DAG for a paper is visible in the same graph as the paper itself, readable by the same query interface, governed by the same retention rules, and legible to the same human review tools.

---

## Decision

### 1. The `task@1.0.0` Schema

A task item is a regular item in the impress-core graph with the following payload fields:

```
task@1.0.0:
  Required:
    title:        String    — Human-readable task name (e.g., "metadata-resolve")
    state:        String    — "pending" | "running" | "done" | "failed" | "cancelled"

  Optional:
    description:  String    — Longer description of what the task does
    assigned_to:  String    — ActorId of the agent or human assigned to this task
    due_at:       Int       — Unix timestamp for deadline (task becomes overdue if unmet)
    output_schema: String   — Schema ref of the item this task is expected to produce
    error:        String    — Set on failure; contains error message or code

  FTS fields:   title, description

  Typical edges:
    DependsOn  →  another task item  (prerequisite; source is blocked until target is "done")
    ProducedBy →  agent-run item     (which agent invocation created or completed this task)
    OperatesOn →  any item           (the publication, artifact, or other item this task targets)
```

The `state` field is set at creation and then updated via `SetPayload("state", ...)` operation items. The operation stream on the task item is the authoritative history of every state change, including who made the change and when.

The `output_schema` field is the task output contract (ADR-0003 Decision 5): it declares what type of item a successful task must produce. Completeness validation checks that a child item with the declared schema exists after `state` reaches `"done"`.

### 2. The Task State Machine

```
                  ┌──────────┐
      (created)   │          │
    ─────────────►│ pending  │
                  │          │
                  └────┬─────┘
                       │  impel acquires task
                       ▼
                  ┌──────────┐
                  │          │──────────────────────────────┐
                  │ running  │                              │
                  │          │                              │
                  └────┬─────┘                              │
                       │                                    │
              ┌────────┴────────┐                           │
              ▼                 ▼                           ▼
         ┌─────────┐       ┌──────────┐             ┌────────────┐
         │  done   │       │  failed  │             │ cancelled  │
         │(terminal)│      │(terminal)│             │ (terminal) │
         └─────────┘       └──────────┘             └────────────┘
```

**Allowed transitions:**
- `pending → running` — impel acquires the task (sets `assigned_to`, sets `state = "running"`)
- `pending → cancelled` — explicit cancellation; propagates to downstream tasks via `DependsOn` traversal (ADR-0003 Decision 8)
- `running → done` — successful completion; impel writes output items and marks done
- `running → failed` — failure; impel writes `error` field and marks failed
- `running → pending` — on retry after transient failure; impel resets state before next attempt (this appears in the operation history as a record of the retry)
- `running → cancelled` — in-flight cancellation from upstream

**State transitions as operations.** Each transition is a `SetPayload("state", ...)` operation item targeting the task item, created by the impel agent actor. This gives: full attribution, time-travel ("what state was this task in at 14:00?"), and the operation stream as the retry ledger.

**Blocked state via DependsOn, not an explicit state.** ADR-0003 Decision 2 defined a `blocked` state. This ADR replaces it: a task is implicitly blocked when any of its `DependsOn` targets are not yet `"done"`. impel checks preconditions before transitioning a task from `pending` to `running`; it does not write a `blocked` state to the item. This simplifies the state machine — the graph edges carry the blocking relationship — and avoids a proliferation of state transitions for transient blocking conditions.

### 3. Task State Transitions Are Operation Items

Each state change produces an `OperationType::SetPayload("state", Value::String(...))` operation item on the task item. The operation carries:

- `target_id` — the task item's ID
- `op_type` — `"set_payload"`
- `op_data` — `{"field": "state", "value": "<new-state>"}`
- `intent` — `OperationIntent::Routine` for normal transitions; `OperationIntent::Anomaly` for failure; `OperationIntent::Escalation` for retry-exhausted failures that require human attention
- `author` — the ActorId of the impel agent that drove the transition
- `batch_id` — shared with any sibling operations (e.g., `assigned_to` update alongside the `running` transition)

The operation model is unchanged from ADR-0002. No new operation types are needed for task state management.

### 4. DependsOn Edges for DAG Dependencies

Task dependencies are `EdgeType::DependsOn` edges between task items. The edge is prospective (ADR-0002 Decision 10): it expresses a constraint that must be satisfied before the source task can run. After the dependency resolves (target reaches `"done"`), the `DependsOn` edge remains as provenance, and impel writes a `DerivedFrom` edge from the downstream task to the completed upstream task to record the causal chain.

```
metadata-resolve  ─── DependsOn ──► (none; root task)
abstract-extract  ─── DependsOn ──► metadata-resolve
keyword-tag       ─── DependsOn ──► abstract-extract
recommendation-score ─ DependsOn ─► keyword-tag
digest-generate   ─── DependsOn ──► abstract-extract
```

impel traverses this DAG when scheduling: it queries for `pending` tasks whose `DependsOn` targets are all `"done"` and selects the next task to acquire. DAG traversal is a graph query on the item store, not a separate scheduling data structure.

Cancellation propagation (ADR-0003 Decision 8): when a task is cancelled, impel traverses `DependsOn` edges in the forward direction and cancels all transitively dependent tasks that have no alternative non-cancelled dependencies.

### 5. The `agent-run@1.0.0` Schema

Every agent invocation that produces work is recorded as an `agent-run` item. This separates the task (what was requested and what it produced) from the agent invocation (how it was executed).

```
agent-run@1.0.0:
  Required:
    agent_id:     String    — ActorId of the agent persona (e.g., "librarian-1")
    model:        String    — Model identifier (e.g., "claude-opus-4-6")
    prompt_hash:  String    — SHA-256 of the rendered prompt; enables reproducibility checks

  Optional:
    result_summary: String  — Short natural-language summary of what the run produced
    token_count:    Int     — Total tokens consumed (input + output)
    duration_ms:    Int     — Wall-clock duration of the API call

  FTS fields:   result_summary

  Typical edges:
    ProducedBy  →  task item       (which task triggered this agent invocation)
    DerivedFrom →  any item        (items that were inputs to the prompt)
```

An agent-run item is created by impel when it calls an LLM or tool on behalf of a task. The task item then gets a `ProducedBy → agent-run` edge added after the run completes. For multi-turn agent loops, each turn is a separate agent-run item, linked by `InResponseTo` edges.

The `prompt_hash` field enables reproducibility: given the same items (via `DerivedFrom` edges), was the same prompt generated? If the model or hash differ, the result may differ and the difference is traceable.

Agent-run items carry `OperationIntent::Routine` by default, with `retention: Compactable` (ADR-0003 Decision 3). They are infrastructure — researchers should see enrichment results, not agent log noise.

### 6. The impel Boundary Definition

The impress-core / impel boundary is a strict API contract. Neither side crosses it.

**impress-core responsibilities:**
- Persist task items with the `task@1.0.0` schema
- Persist agent-run items with the `agent-run@1.0.0` schema
- Apply operation items to update task state (via `SetPayload`)
- Provide a subscription interface: notify impel when a new `pending` task item appears
- Provide a DAG query: given a task item, return its `DependsOn` targets and their states
- Store task output as child items (via `parent` field or `ProducedBy` edges)
- Know nothing about: HTTP, Claude API, tool calls, retry logic, rate limiting, backoff

**impel responsibilities:**
- Poll or subscribe for `pending` tasks via impress-core's subscription API
- Check preconditions (all `DependsOn` targets are `"done"`) before acquiring a task
- Transition task to `running` by writing a `SetPayload("state", "running")` operation via impress-core API
- Execute the task (call LLM, external API, or internal tool)
- Write results back as items via impress-core API (new items with appropriate edges)
- Transition task to `done` or `failed` via impress-core API
- Manage retry scheduling, backoff, and rate limiting internally
- Create agent-run items to record each invocation via impress-core API
- Direct SQLite: never. impel writes to SQLite only through impress-core's public API

This boundary is enforced architecturally: impel depends on impress-core as a library; it does not link to the SQLite crate directly.

### 7. The `TaskExecutor` Trait

impel implements task execution through a Rust trait that each task type satisfies. The trait is the formal contract between impel's scheduler and its task handlers:

```rust
/// Trait implemented by each task type handler in impel.
/// The handler receives a fully-loaded task item and the store API,
/// and is responsible for writing all output via the store.
pub trait TaskExecutor: Send + Sync {
    /// The schema ref this executor handles (e.g., "task@1.0.0" with task_kind "metadata-resolve").
    fn task_kind(&self) -> &str;

    /// Execute the task. On success, the executor must:
    ///   1. Write output items via `store.create_item()`
    ///   2. Return Ok(()) — the scheduler transitions state to "done"
    /// On failure, return Err(TaskError) — scheduler transitions state to "failed".
    ///
    /// The executor must not transition task state itself; state transitions
    /// are the scheduler's responsibility.
    async fn execute(
        &self,
        task: &TaskItem,
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError>;

    /// Maximum number of retry attempts before escalating to human review.
    fn max_retries(&self) -> u32 { 3 }

    /// Whether this task can be retried after a failure.
    fn is_retryable(&self, error: &TaskError) -> bool;
}
```

Key design choices in this trait:

- **Executors do not transition state.** The scheduler drives state transitions after `execute()` returns. This prevents executors from leaving tasks in inconsistent states and makes state management testable independent of execution.
- **Executors write output via the store API.** They never mutate the task item directly; they create new items that the scheduler then links.
- **`is_retryable` separates transient from permanent failures.** Network errors are retryable; schema validation failures are not. impel uses this to decide whether to retry or escalate.

### 8. The DeliveryHint Model for Task Output

When an executor writes output items via the store API, each output carries a `DeliveryHint` (from ADR-0001 Decision 2, agent channel) that controls how the store handles persistence and downstream routing:

```rust
pub enum DeliveryHint {
    /// Write and continue. Used for intermediate enrichment output,
    /// progress log entries, and agent-run items.
    /// The vast majority of task output.
    FireAndForget,

    /// Write and confirm durability before returning.
    /// Used for task state transitions ("done"/"failed") and
    /// primary enrichment outputs (keyword tags, metadata patches).
    ConfirmStored,

    /// Write, save impel state, and suspend until a human responds.
    /// Used when a task reaches a decision point requiring human input:
    /// ambiguous entity resolution, low-confidence classification,
    /// content requiring editorial judgment.
    AwaitHumanResponse,
}
```

The `AwaitHumanResponse` hint integrates the task system with the attention routing system (ADR-0001 Decision 4): impress-core routes the handoff item to the researcher via impart, and impel suspends the task in `running` state. When the researcher responds, impress-core delivers the response to impel, which resumes execution. This is the explicit human review checkpoint from ADR-0001's agent-native architecture.

### 9. The Imbib Enrichment Pipeline (Reference Implementation)

The imbib enrichment pipeline is the concrete forcing function for the task infrastructure. It exercises every mechanism in this ADR and serves as the integration test for the impress-core / impel boundary.

**Trigger:** A new item with `schema_ref: "bibliography-entry@1.0.0"` appears in the item store.

**Task DAG created by impel:**

```
bibliography-entry (Publication)
    │
    ├── metadata-resolve              [TaskExecutor: MetadataResolveExecutor]
    │   └── Calls: ADS / CrossRef / DOI APIs
    │   └── Produces: SetPayload operations on the publication item
    │       (title, abstract, authors, year, venue if missing or incomplete)
    │
    ├── abstract-extract              [TaskExecutor: AbstractExtractExecutor]
    │   └── DependsOn: metadata-resolve
    │   └── Trigger: if abstract still missing after metadata-resolve
    │   └── Calls: PDF text extraction on linked file
    │   └── Produces: SetPayload("abstract", ...) operation on publication
    │
    ├── keyword-tag                   [TaskExecutor: KeywordTagExecutor]
    │   └── DependsOn: abstract-extract
    │   └── Calls: LLM with abstract + domain vocabulary
    │   └── Produces: AddTag operations on publication (e.g., "methods/sims/hydro")
    │   └── DeliveryHint: ConfirmStored for tag operations (durable by default)
    │
    ├── recommendation-score          [TaskExecutor: RecommendationScoreExecutor]
    │   └── DependsOn: keyword-tag
    │   └── Calls: Internal embedding model / cosine similarity
    │   └── Produces: SetPayload("recommendation_score", ...) + Cites/RelatesTo edges
    │                 to similar publications
    │
    └── digest-generate               [TaskExecutor: DigestGenerateExecutor]
        └── DependsOn: abstract-extract  (parallel branch with keyword-tag)
        └── Calls: LLM with abstract
        └── Produces: New child item with schema "digest@1.0.0" (one-paragraph summary)
        └── DeliveryHint: FireAndForget (compactable; regenerable)
```

**Retention classification:**
- Task items themselves: `Compactable` (routine infrastructure)
- Agent-run items: `Compactable`
- Tag operations (AddTag on publication): `Durable` — the tags are part of the research record
- Metadata patch operations: `Durable` — corrected fields are part of the research record
- Digest items: `Compactable` — summaries are regenerable; they are not primary research outputs
- Recommendation score: `Compactable` — scores will be recomputed as the model improves

**Error handling in the pipeline:**
- `metadata-resolve` fails (ADS unreachable): `TaskError` is retryable; impel retries with exponential backoff, up to `max_retries()`. If exhausted, transitions task to `failed` with `OperationIntent::Escalation` so the operation appears in the researcher's triage feed.
- `keyword-tag` low confidence: `DeliveryHint::AwaitHumanResponse` — impel suspends, impart surfaces a review card asking the researcher to confirm or adjust the proposed tags.
- `abstract-extract` PDF not yet available: task returns to `pending`; impel re-queues with a delay. This is not a failure — it is a precondition not yet met.

### 10. Spawn Rules Are Rust Code in impel (D22)

ADR-0003 Decision 4 specified that spawn rules would be items in the graph. This ADR revises that decision for Phase 3 (the current phase).

Spawn rules are implemented as Rust code in impel, not as declarative items. Each rule is a function that receives an item creation event and returns a list of task items to create:

```rust
pub trait SpawnRule: Send + Sync {
    /// Schema ref that triggers this rule.
    fn trigger_schema(&self) -> &str;

    /// Given the triggering item, return task items to create.
    /// Returns an empty vec if no tasks should be spawned for this item.
    async fn spawn(
        &self,
        trigger: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<Vec<TaskSpec>, SpawnError>;
}
```

The imbib enrichment spawn rule implements `SpawnRule` with `trigger_schema() = "bibliography-entry@1.0.0"` and `spawn()` returning the five-task DAG described in Section 9, with appropriate `DependsOn` edges.

**Why not declarative items in Phase 3.** ADR-0003 Decision 4 argued for declarative spawn rules to make pipelines inspectable and editable without code changes. This is the right long-term goal. However, the imbib enrichment pipeline has non-trivial conditional logic: whether `abstract-extract` is needed depends on whether metadata-resolve succeeded and found an abstract; whether `keyword-tag` emits low-confidence tags depends on a runtime LLM score. Expressing this in a declarative format requires a query or rule language that does not yet exist in the codebase. Writing Rust now and migrating to declarative items in Phase 4+ is a smaller risk than designing a rule language whose expressiveness requirements are not yet fully known.

**Phase 4+ migration path.** When declarative spawn rules are introduced, the `SpawnRule` trait is the migration boundary: a declarative rule engine implements `SpawnRule` by interpreting a rule item from the graph. Existing Rust rules can coexist with declarative ones. No task items, agent-run items, or output items need to change.

---

## Consequences

### Positive

- Task provenance is uniform with all other item provenance. "What produced these keywords?" is a graph traversal, not a cross-system query.
- The impress-core / impel boundary is explicit and testable. impress-core can be tested with a mock executor; impel can be tested with a mock store API.
- The `TaskExecutor` trait makes adding new enrichment task types a mechanical operation: implement the trait, register the executor, add the spawn rule.
- `DeliveryHint::AwaitHumanResponse` gives the enrichment pipeline a first-class mechanism for human-in-the-loop review without any new infrastructure. It reuses the attention routing system designed in ADR-0001.
- Agent-run items with `prompt_hash` enable reproducibility auditing: if an enrichment result is questioned, the exact prompt that produced it is recoverable.
- The five-stage enrichment DAG is a complete integration test of the item graph, operation model, DAG scheduling, and impel boundary. If it works, the architecture is validated at scale.

### Negative

- Every task state transition is an operation item. For a five-task enrichment pipeline, this is approximately 10–15 operation items per publication. At 10,000 publications, this is 100,000–150,000 additional items. These are compactable (ADR-0003 Decision 3), but they consume index space and must be included in materialization performance budgets.
- The `TaskExecutor` trait is async. impel must manage an async runtime that is isolated from the Swift main thread and does not interfere with the startup grace period (see CLAUDE.md: background services must not fire mutations during the first 90 seconds of launch).
- `AwaitHumanResponse` creates a suspension protocol between impel and impart. impel must save enough state to resume after an arbitrary delay (researcher may respond in 5 minutes or 5 days). Exactly what state is saved and how it is serialized is an open question.
- Spawn rules as Rust code make pipelines opaque — a researcher cannot inspect or modify them without a code change. This is the explicit trade-off of D22, acceptable in Phase 3, resolved in Phase 4+.

### Mitigations

- Compactable operation items for task state transitions are eligible for summary compaction (ADR-0003 Decision 3). After the retention window, the full state-transition chain collapses to a summary without losing effective state.
- The 90-second startup guard from CLAUDE.md applies to the impel scheduler: it must not begin processing pending tasks until after the grace period. This is the same pattern as `SmartSearchRefreshService.startupGracePeriod` in imbib.
- Suspension state for `AwaitHumanResponse` can be minimal: the task item ID and a continuation token. impel re-runs task setup on resume rather than serializing full executor state.

---

## Open Questions

1. **Subscription mechanism between impress-core and impel.** Should impel poll (periodic query for `pending` tasks where preconditions are met) or subscribe (push notification from impress-core event bus when a new pending task appears)? Polling is simpler to implement; subscription reduces latency for time-sensitive enrichment. Decide during Phase 3 implementation.

2. **Agent-run retention and compaction.** Agent-run items are marked `Compactable`. But `prompt_hash` on a compacted agent-run item is the primary reproducibility artifact — if the item is summarized away, the hash is lost. Does reproducibility require retaining agent-run items longer than other compactable items? Consider a separate `reproducibility_tier` classification or a `must_retain_fields: [prompt_hash]` compaction annotation.

3. **Multi-turn agent loop granularity.** For a `keyword-tag` task that requires a multi-turn LLM conversation (initial classification, self-critique, final tags), is each turn a separate `agent-run` item linked by `InResponseTo`, or is the entire conversation one `agent-run` item with the full conversation in `result_summary`? Per-turn items give better reproducibility; per-conversation items are less noisy. Decide during KeywordTagExecutor implementation.

4. **DAG query performance.** The precondition check ("all `DependsOn` targets are `done`") is a graph traversal query. At scale (many tasks with deep dependency chains), this query must be fast. impress-core's `sql_query.rs` layer must have an efficient path for this. If not, impel may need to maintain its own in-memory DAG projection.

5. **`output_schema` validation timing.** The task output contract (Section 1) is currently a documentation field. Should impress-core enforce it — refusing to mark a task `done` unless a child item with `output_schema` exists? Enforcement catches executor bugs early but couples the store to schema knowledge. Decide before Phase 3 integration test.

6. **Declarative spawn rules format.** Phase 4+ will introduce declarative spawn rules as items in the graph. The rule language must handle at minimum: trigger schema, conditional logic on item payload fields, DAG construction with conditional edges. TOML is insufficient for conditional logic; a minimal Datalog or expression language is likely needed. Begin design during Phase 3 while the Rust rules are the living specification.

7. **Human review UX for `AwaitHumanResponse`.** When the enrichment pipeline suspends waiting for human input (e.g., confirm keyword tags), where does the review card appear? In imbib's sidebar? In impart as a message? The attention routing system routes it; but the review UI must be designed. This is a cross-app UX question for the imbib and impart teams.

---

## References

- ADR-0001: Unified Item Architecture for the Impress Suite
- ADR-0002: Operations as Overlay Items and Data Model Foundations
- ADR-0003: Tasks, Retention, and Enrichment (retention tier decisions remain in effect)
- `crates/impress-core/src/operation.rs` — `OperationType`, `OperationSpec`, `OperationIntent`
- `crates/impress-core/src/reference.rs` — `EdgeType` including `DependsOn`, `OperatesOn`, `ProducedBy`
- `crates/impress-core/src/item.rs` — `Item`, `ActorKind`, `Priority`, `Visibility`
- `crates/impel-core/src/agent/` — `Agent`, `AgentType`, `AgentStatus` (current impel agent model)
- `crates/impel-core/src/coordination/` — `Command`, `CoordinationState` (current impel scheduling model)
- CLAUDE.md: "Background Services Must Defer Startup Work" — startup grace period constraint on impel scheduler
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*, Ch. 11 (Event Sourcing, Stream Processing)
