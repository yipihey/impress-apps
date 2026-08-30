# ADR-0028: The Memory Kernel — Suite-Wide Agent Memory over the Unified Store

**Status:** Proposed
**Date:** 2026-08-30
**Authors:** Tom (with architectural exploration via Claude)
**Depends on:** ADR-0001 (Unified Items), ADR-0003 (Operations and Provenance), ADR-0005/0015 (Task Kernel), ADR-0006 (Retention Tiers), ADR-0012 (Knowledge Objects), ADR-0022 (Collection Kernel), ADR-0026 (Provenance-First AI Infrastructure)
**Implements:** impel ADR-015 (Long-Term Memory), promoted out of `impel/` to suite scope
**Preserves:** imbib ADR-022 (Embedding Index Sync Strategy)
**Scope:** new `crates/impress-embeddings`, `crates/impress-memory-service`, `crates/impel-memory`; new `impress_core::memory_ops` and three `memory/*` schemas; extraction inside `crates/imbib-core/src/search/`; registrations in `impel-taskd`, `impress-mcp`, `impel-tools`; `schema-refs.json`

---

## Context

The suite stores everything with provenance and starts every session from zero.
An agent corrected on Monday repeats the mistake on Wednesday. ADR-0012 D42
already answered the storage question — "episodic memory is a query pattern, not
a subsystem" — and was right about storage. It is not a claim that the
*pipeline* exists. Nothing in the suite writes a memory, and nothing reads one
back.

Analysis of Sapience Labs' continual-learning architecture (spnc.ai) made the
split legible. Theirs is a memory **pipeline**: a novelty gate on write,
consolidation of raw traces into durable claims, competitive inhibition between
overlapping memories, supersession-aware recall, salience decay. Ours is a
memory **substrate**, and measured against that pipeline an unusually complete
one:

| Half | What impress already owns |
|---|---|
| Typed knowledge objects | ADR-0012 D39 field convention, `Item` envelope, `Visibility` |
| Supersession | `EdgeType::Supersedes`, already used by `review@1.0.0` |
| Write order | HLC on every row (ADR-0007 Phase A), CloudKit LWW with tiebreaks |
| Forgetting | ADR-0006 retention tiers plus the live daily compaction loop |
| Scheduling | ADR-0005/0015 task kernel, `impel-taskd` executors, `agent-run@1.0.0` |
| Lexical recall | `items_fts` (`title`, `author_text`, `abstract_text`, `note`, `body`) |
| Vectors | an embedding stack — but only inside imbib |

And none of the other half. No novelty gate, so any writer duplicates. No
consolidation, so episodic traces never become durable claims. Recall is not
supersession-aware — `search_all` returns a superseded review beside the one
that replaced it. No briefing surface, so a memory that existed would not reach
an agent's first turn.

impel ADR-015 specified the missing piece three memory types deep — facts,
episodes, instructions — with a write/read/update lifecycle. It is a good spec,
it was never built, and its namespace (`impel/memory-fact@1.0`) would have
scoped memory to one app in a suite whose whole architecture is one store.

### Verified state, 2026-08-30

Six facts constrain the design. Each was checked against the tree.

1. **No `memory/*` schemas exist.** `schema-refs.json` has no `memory` entry;
   nothing in the repo mentions `memory-fact`/`memory-episode`/
   `memory-instruction` outside impel ADR-015 itself. This is greenfield.

2. **No Rust code writes vectors.** `crates/imbib-core/src/search/embedding_store.rs`
   can persist them; the only caller that does is Swift's
   `EmbeddingService.buildIndex`. Every semantic tool in `impress-mcp` therefore
   degrades to lexical unless imbib.app has run on that device — a cross-process
   capability gated on a GUI having been opened.

3. **A live silent vector-space mismatch.** Swift stamps `model` with the active
   provider id, defaulting to `"apple-nl"` (EmbeddingService.swift:217), from
   NLEmbedding: 512 dimensions strided down to 384 (EmbeddingService.swift:642;
   `AppleContextualEmbeddingProvider.embeddingDimension = 512`). Rust's query
   path embeds with fastembed `AllMiniLML6V2`
   (`crates/imbib-core/src/search/semantic.rs:37`), also 384-d. Both fit the
   same column. Cosine between them is arithmetic over unrelated bases: it
   returns a number, the number is meaningless, and nothing errors. The
   `vectors` table has `model TEXT NOT NULL` and `idx_vectors_model`; no read
   path filters on either.

4. **The sidecar has no migration mechanism.** `embedding_store.rs` opens with
   WAL pragmas and a batch of `CREATE TABLE IF NOT EXISTS`. There is no
   `PRAGMA user_version` in it — the file is at version 0, and any schema change
   is a silent no-op on databases that already exist. Its `chunks` table is also
   publication-scoped by column (`publication_id TEXT NOT NULL`,
   `idx_chunks_pub`): honest about today's only consumer, wrong for a suite.

5. **Compaction already runs daily.** `crates/impress-ai-http/src/main.rs` ticks
   every 300 s and compacts every 288th tick, `IMPRESS_COMPACT_WINDOW_DAYS`
   defaulting to 30. Consolidation must finish reading a window before
   compaction folds it.

6. **`content-chunk@1.0.0` is lexically searchable only**
   (`crates/impress-core/src/schemas/source.rs:9`), and `Visibility::Private` is
   the universal item default (`crates/impress-core/src/item.rs:340`). The
   second matters more than it looks: privacy cannot be the recall gate, because
   the gate would be closed on everything.

### Why now

ADR-0026 landed conversations, runs, and tool invocations as first-class items,
so agent work leaves a structured trace worth consolidating. ADR-0024 cut the
MCP surface to something a local model can hold, so a handful of memory verbs is
affordable. The task kernel has durable, leased, crash-safe executors. Every
prerequisite is in place except the memory itself.

---

## Decisions

### D1. Three suite-scoped schemas, restated as knowledge objects

impel ADR-015's trio is promoted out of `impel/` and registered in
`crates/impress-core/src/schemas/memory.rs`:

```
memory/claim@1.0.0         semantic memory — a durable assertion
  Required:  body: String, confidence: Float
  Optional:  summary, subject_refs: StringArray, evidence_refs: StringArray,
             scope, agent_id, agent_run_ref,
             confirmations: Int, last_confirmed: String, no_recall: Bool
  FTS: title + body + summary

memory/episode@1.0.0       episodic memory — how a piece of work went
  Required:  body: String
  Optional:  task_type, approach, outcome, quality_rating: Float,
             subject_refs, evidence_refs, agent_id, agent_run_ref, no_recall
  FTS: title + body

memory/instruction@1.0.0   procedural memory — a learned rule
  Required:  body: String
  Optional:  applies_to: StringArray, rationale, subject_refs, evidence_refs,
             agent_id, agent_run_ref, confirmations, last_confirmed, no_recall
  FTS: title + body
```

They are knowledge objects under ADR-0012 D39, not a new category:
`subject_refs` and `evidence_refs` are mirrored as `RelatesTo` and `DerivedFrom`
edges alongside the fields; `confidence` carries the author's stance;
`agent_id`/`agent_run_ref` attribute agent authorship; and **replacement is
strictly a `Supersedes` edge**, never an in-place rewrite of a body. `title` and
`body` land in the existing `items_fts` columns
(`crates/impress-core/src/sqlite_store.rs:746`), so memory is lexically
recallable on day one with no new index.

Two departures from ADR-015. The namespace is `memory/`: one store, one memory,
and impel is a consumer like any other. And `subject_refs` is plural where
ADR-0012 D39.1 allows either — a claim learned while reading three papers has
three subjects, and forcing a primary loses the other two.

`memory/claim` and `memory/instruction` are **Durable** (ADR-0006 D1) for
ADR-0012 D43's reason: they are intellectual acts. `memory/episode` is Durable
too, which is the less obvious call. An episode reads like a log line and the
temptation is to make it Compactable. It is not a log line — it is the research
record of *how work went*, and a year of episodes is exactly the corpus a future
consolidation pass wants. Compacting them destroys the input to the thing they
exist to feed. Routine operations *on* memory items stay compactable under the
normal ADR-0006 rules.

### D2. Vectors stay device-local derived state; the sidecar gets hardened

imbib ADR-022 decided embeddings regenerate per device rather than sync; that
stands unchanged at suite scope. Vectors are derived state, rebuildable like the
FTS index, and never enter CloudKit. What changes is that the sidecar becomes a
store an unattended process can trust:

- **`PRAGMA user_version` plus a migration runner.** The file is at 0 with no
  mechanism to move off it. Version 1 declares the existing shape explicitly;
  every later change is a numbered step. Without this, D3's generalization is a
  silent no-op on every database that already exists.
- **`model` becomes a first-class filter on every search-path read.** The column
  and its index already exist; the reads ignore them. After this ADR a read that
  does not name a model does not compile — the parameter is required, not
  defaulted.
- **An `owner_type` column generalizes ownership; `publication_id` keeps its
  name.** It is a `uniffi::Record` field visible to Swift, and renaming it churns
  `apps/imbib/ImbibRustCore/Sources/ImbibRustCore/imbib_core.swift` and every
  call site for zero behavioral gain. `owner_type` defaults to `'publication'`,
  so existing rows are correct without a rewrite; a memory item's chunks carry
  `owner_type = 'item'`.

### D3. `crates/impress-embeddings` — extract the vector stack, keep the ABI still

`embedding_store`, `ann_index`, `chunk_index`, and `semantic` move out of
`crates/imbib-core/src/search/` into a new `crates/impress-embeddings` with
honest feature gates and **no `uniffi` dependency anywhere**: `store` =
`rusqlite` (the sidecar), `index` = `hnsw_rs` + `bincode` (the ANN index),
`embedder` = `fastembed` (`AllMiniLML6V2`).

`imbib-core` depends on it and re-exports at the old paths, so no imbib code
moves. Its ~33 `uniffi::export` sites and 11 exported types across those four
modules stay in `imbib-core` as thin shims over mirror `Record`s with `From`
conversions — the FFI surface is authored where the FFI lives, the logic where
anyone can link it.

**Acceptance is byte equality, not review:** regenerate the bindings and run
`git diff --exit-code` on
`apps/imbib/ImbibRustCore/Sources/ImbibRustCore/imbib_core.swift`. If that file
changes, the extraction is wrong. `ImbibCore.xcframework` and all Swift are
unchanged by construction.

`imbib-core`'s `embeddings = ["fastembed"]` feature is **deleted**. It never
shipped: the xcframework builds `--features native`, which does not include it,
so the only fastembed path in the app bundle was one never compiled into it.
Keeping a feature that has never been on keeps a claim that has never been true.

**Why a crate, not a module.** `crates/impress-store-service/Cargo.toml` carries
a written refusal — "No imbib-core dependency: these verbs are schema-agnostic
and run against the shared store directly." That refusal is correct and
load-bearing. Making a suite-wide memory service reach a vector store through
`imbib-core` would drag BibTeX, pdfium, and the publication domain into every
consumer to get a table of 384 floats.

### D4. Rust becomes the canonical cross-process vector writer

Vectors written by any headless process — taskd, CLI, MCP — come from fastembed
`AllMiniLML6V2` and are stamped `model` accordingly. Swift's `apple-nl` vectors
are **not** invalidated: they remain correct for imbib-local semantic
recommendation, which computes queries in the space that wrote them. The two
spaces coexist in one table, correctly, because every search-path reader now
filters on `model` (D2). Fact 3 stops being a silent bug the moment the filter
is mandatory.

The filter ships **gated on the presence of at least one fastembed vector**. A
device whose sidecar holds only `apple-nl` rows keeps getting `apple-nl` results
until the backfill (D7) writes something to switch to. Ungated, the filter would
blank out live semantic search between deploy and backfill — a correctness fix
that presents to the user as the feature breaking.

### D5. Memory logic splits along the existing kernel boundary

The suite already has this rule and six modules obeying it: `collection_ops`,
`manuscript_ops`, `related_ops`, `search_ops`, `triage_ops`,
`watched_folder_ops`. Memory follows it exactly.

**`crates/impress-core/src/memory_ops.rs`** — pure store operations, no
embedder, no network: insert a memory item with its `RelatesTo`/`DerivedFrom`
edges in one transaction; supersession-head queries (walk `Supersedes` to the
live head; return only heads for a subject); the Tier-1 near-duplicate gate (FTS
candidate fetch plus token-overlap scoring); and pure ranking with
memory-specific weights.

That last point is a constraint, not a preference. `rank_hybrid_candidates`
(`crates/impress-core/src/search_ops.rs:266`) is **not** reused and **not**
modified: it is pinned by `crates/imbib-core/tests/golden_parity.rs:828` against
frozen Swift behavior. Memory ranking wants confirmation count, recency
half-life, and author kind — weights that would break that parity. It gets its
own function.

**`crates/impress-memory-service`** — the `#[impress_service]` trait, where
vector-aware composition lives, with one `#[impress_method]` each for
`remember`, `recall`, `memory-brief`, `confirm`, `supersede`, `forget`, and
`memory-status`. Seven methods, one definition each, rendering as MCP tool +
CLI verb + impel tool through the existing codegen. There is no second
hand-written surface, and per ADR-0024 D1 the grouped MCP rendering is a view
over these same descriptors.

### D6. The `remember()` gate is two-tier, and Tier 2 is opt-in

Writing memory without a novelty gate produces a store full of near-identical
claims within a week. The gate is competitive inhibition implemented as
merge-on-write.

**Tier 1 — always on, no model required.** Query `items_fts` for the candidate
body, score token overlap against the returned heads, then either insert a new
claim or **confirm** an existing one. `confirm` is a real operation: it bumps
`confirmations` and sets `last_confirmed` through the normal operation stream,
so a repeatedly-observed fact accumulates weight instead of rows.

**Tier 2 — vector kNN, off by default.** Runs only where the embedding model is
already cached locally *and* an opt-in env var is set. Both conditions are
required because a lazy `fastembed` init is a ~100 MB download, and the same
generated inventory handler runs inside the CLI process, the MCP server, and —
via `impel-tools` — the app process. A first `remember()` that silently starts a
100 MB download inside a GUI is not a memory feature; it is a hang.

**Contradiction detection is not in v1.** Deciding that a new claim *refutes* an
old one rather than merely resembling it needs semantic judgment; token overlap
cannot do it, and a wrong automatic supersede silently deletes knowledge from
recall. Until the LLM consolidation tier (D7) exists, supersession is explicit:
the `supersede` verb, or a consolidation-provided hint someone acted on.

### D7. Two executors in `crates/impel-memory`

Both register in `crates/impel-taskd/src/main.rs` alongside the existing
`scheduler.register(Arc::new(…))` calls, each behind an env gate, so a deploy is
inert until switched on.

**`impress.memory.embed`** — batch backfill of memory items and
`content-chunk@1.0.0` items into the sidecar, using a keyset cursor over
`idx_items_schema_created` (`crates/impress-core/src/sqlite_store.rs:729`) so it
never scans. Vector ids are deterministic: `UUIDv5(source_id, model)`. That one
choice makes crash-replay upsert-only — a killed batch re-run writes the same
ids over the same rows, and there is no duplicate-detection pass to get wrong.

**`impress.memory.consolidate`** — episodic traces into durable claims. The v1
source is **completed agent-runs only**. The deterministic tier writes
structural episodes (what ran, what it touched, how it ended) with no model
involved. Every candidate claim goes through the D6 gate, which is what makes
the executor safe to replay: consolidating an overlapping window *confirms*
existing claims rather than duplicating them. One `agent-run@1.0.0` per
execution, `DerivedFrom` edges to every consumed source, `produced_by` on every
output — ADR-0026 D2's provenance shape, unchanged.

The LLM tier follows the pattern proven in
`crates/impel-enrichment/src/classify_llm.rs`: configured from `IMPEL_LLM_*`
env, `complete_sync` inside `tokio::task::spawn_blocking` (classify_llm.rs:110),
or `OmlxClient` via `IMPRESS_OMLX_URL` (`crates/impel-taskd/src/main.rs:345`).
Unconfigured, it falls back to the deterministic tier rather than failing the
task — the same posture as the classifier and the throughline drafter.

### D8. Watermarks derive from the completed task chain

A consolidation pipeline needs to know where it left off. It does not get a side
channel. Window bounds and the embed cursor live in the **task item's own
payload**. An executor advances its cursor with `SetPayload`
(`crates/impress-core/src/operation.rs:19`) on its own task — legal, because
only `state` is scheduler-exclusive; payload is ordinary mutable item data with
ordinary operation provenance. The spawner reads the latest done task of that
kind to compute the next window.

A watermark in `store_metadata` would be a second authority with no provenance,
no sync story, and no answer to "which run advanced it." A watermark in the task
chain *is* the run that advanced it.

**Consolidation-before-compaction is held by cadence arithmetic, not a lease.**
Consolidation runs daily windows; compaction folds operations older than 30 days
(`IMPRESS_COMPACT_WINDOW_DAYS`, `crates/impress-ai-http/src/main.rs`).
Twenty-nine days of margin is not a race. No coupling between the loops is
introduced, and `impress-ai-http` is not modified by this ADR.

### D9. Recall privacy is its own axis — and a stated non-goal

`Visibility::Private` is the universal default (fact 6), so it cannot gate
recall: a gate closed on every item is not a gate. Memory gets a dedicated axis
— a `no_recall` payload flag, set by the `forget` verb, enforced **inside
`memory_ops`' recall and brief paths in the kernel**, so every surface (MCP,
CLI, impel, any future chassis UI) inherits it without re-implementing it.
`forget` marks; it does not delete. The item stays in the graph for audit,
exactly as a superseded review does.

**The non-goal, stated plainly:** memory bodies remain globally FTS-indexed, and
`search_all` will return them to any caller. `no_recall` governs memory *recall*
surfaces only, not generic search. Gating `search_all` would change pinned
search behavior suite-wide, for every schema, to fix a property memory items do
not have relative to any other item in the store. Anyone who needs a memory to
be undiscoverable by full-text search should not write it.

This answers ADR-0012 open question 5 for memory items: the answer is a payload
flag on a recall axis, not `Visibility::Private` and not a `private: bool` on
every knowledge object.

### D10. v1 surfaces: tools, one resource, one hook

- **The generated MCP tools, CLI verbs, and impel tools** from D5.
- **An MCP resource `impress://memory/brief`**, joining `impress://guide`,
  `impress://store/schemas`, and `impress://store/collections` in
  `crates/impress-mcp/src/server.rs`. A resource, not a tool, because a briefing
  is read at connect time, not decided on by a model.
- **An opt-in Claude Code `SessionStart` hook** running `impress memory-brief`.
  Opt-in because injecting memory into every session unasked is a change to the
  user's context budget that the user should make.

**impel in-prompt injection is deferred.** ADR-015's read phase puts memory into
the system prompt before each loop iteration; impel's agent loop lives in Swift
`CounselEngine` behind a checksum-pinned UniFFI boundary, and reaching into it
is a separate change with its own regression surface. v1 does the smaller true
thing: make the memory tools *visible* to impel. That is one change in
`crates/impel-tools/src/lib.rs:152` — `list_available_tools` keeps only tools
whose owning app resolves to a reachable HTTP backend, and `app_of` returns
`None` for any namespace that is not `imbib-`/`imprint-`, so a store-backed
service is filtered out as unreachable. Add the **"no owning app ⇒ available"**
case: a tool that needs no app cannot be blocked by one being closed.

**Chassis and Swift UI are deferred** to a follow-up composed with ADR-0017's
connection surfaces, where a memory item's edges are the interesting part.

One consequence to record now: an `impel-tools` memory call writes the shared
store **from inside the app process**. That is safe today only because no app
caches memory items, so there is no in-process view to invalidate. When a
chassis memory UI lands this must be revisited — it is precisely the shape of
cache-coherence bug the store's mutation notifications exist to prevent.

### D11. Explicit v1 cuts, each with a named home

- **Automated instruction promotion via review-requests.** The obvious design —
  a candidate instruction becomes a suspended review task — is unavailable: the
  kernel has no review-expiry mechanism, and this machine currently holds
  roughly **546 suspended review tasks**. Adding a generator to a queue nobody
  drains makes the queue worse. Capping and expiring reviews is its own kernel
  design and belongs in a task-kernel ADR. `memory/instruction` **is** writable
  in v1, explicitly via `remember(kind=instruction)`; only the *automatic*
  promotion path is cut.
- **Consolidation of conversations, reading traces** (`record_recent`,
  `last_activity_at`), **and ops-journal windows.** Agent-runs have the only
  clean completion semantic available today; the others have no unambiguous
  "finished and safe to summarize" signal, and consolidating a live conversation
  produces a claim about a thought the user had not finished.
- **Search-run traces.** They do not exist anywhere in the store. Consolidating
  them requires first deciding to record them.
- **Claim sharing and sync posture.** Memory items sync like any item today.
  Whether a claim should be *shareable* as a distinct act is an open question
  below, not a v1 decision.

### D12. Record-kind descriptors are deferred with the UI phase

ADR-0021 D4 makes adding a record kind additive: one `RecordKindDescriptor`, one
row struct, one scope, one thin list wrapper, matrix rows, a selftest capability.
None of that is written for the three memory kinds in v1, because v1 ships no
memory UI and a descriptor with no surface to describe is speculative contract.

Until the UI phase, memory items render as **generic items** in store-browse
surfaces — visible and inspectable, without per-kind tabs, triage capabilities,
or creation affordances. This is an **accepted gap**, recorded here so it is
found deliberately rather than rediscovered as a bug: a kind with no
`capabilities(of:)` case is silently read-only, exactly the micro-bug class
`docs/chassis-capability-matrix.md` exists to catch. The follow-up ADR that adds
the chassis surface owns the descriptors and the matrix rows.

---

## Consequences

### Positive

- Memory is items. FTS, tagging, edges, operations, time-travel, sync, backup,
  and mbox export work on day one because nothing about memory is special.
  ADR-0012 D42's thesis is honored — this adds the pipeline it presumed, not a
  parallel store.
- The vector-space mismatch stops being silent. A wrong-space comparison becomes
  impossible to express rather than merely unlikely.
- `crates/impress-embeddings` gives every consumer a vector store without
  linking BibTeX, pdfium, or tantivy, and `impress-store-service`'s written
  refusal to depend on `imbib-core` stays true.
- `impress-mcp`'s semantic tools stop depending on whether a GUI has been opened
  on that device.
- Storage growth is trivial: memory items are prose-sized, and a year of
  aggressive daily consolidation is thousands of rows against an operation
  stream already sized in millions (ADR-0006 Context). No special handling.
- Every decision here is additive and env-gated. A deploy with nothing switched
  on changes no behavior.

### Negative

- **Tier-1 gate quality is lexical only.** Token overlap misses a claim restated
  in different words and occasionally confirms two claims that merely share
  vocabulary. Until Tier 2 is default-on, the store accumulates some
  near-duplicates and some wrong merges. The wrong merge is the worse failure
  and is only partly mitigated by `confirmations` being visible in `recall`.
- **Consolidation quality is the local model's quality.** The deterministic tier
  produces structurally correct but shallow episodes; the LLM tier is only as
  good as the configured model. A weak local model writes confident, wrong
  claims that later runs over the same window then *confirm*.
- **Memory text is globally discoverable by design** (D9). `search_all` returns
  memory bodies to any caller. Correct for a single-user local-first store;
  wrong for a shared one.
- **D3 is a large mechanical change with a narrow test.** `git diff
  --exit-code` on the generated bindings proves the ABI is unchanged and nothing
  about behavior. The existing imbib search tests are the only guard on that and
  must pass unmodified.
- **Four new crates**, plus a new `impress-core` module. Each is justified above;
  the count is still real, and the workspace gate gets slower.
- **Deferring in-prompt injection makes v1 memory opt-in at the point of use.**
  An agent that never calls `recall` gets no benefit. The brief resource and the
  SessionStart hook mitigate this for MCP clients; impel gets tool visibility
  only.

---

## Open Questions

1. **Salience decay tuning.** Claims should lose weight when they stop being
   confirmed, on a temperature-style half-life over `last_confirmed`. The
   mechanism is easy; the half-life is not. Too short and stable domain
   knowledge evaporates; too long and a corrected instruction keeps outranking
   its correction. v1 ranks on `confirmations` and recency with no decay curve;
   the curve needs data from real recall sessions before it is chosen.

2. **When to promote the vector tier to default-on.** D6 keeps Tier 2 opt-in
   because of the ~100 MB download inside app-hosted handlers. The promotion
   condition is probably "the model ships in the bundle or is fetched by an
   explicit setup step" — a distribution decision (bundle size, signing,
   first-run experience) that belongs with the ADR-0026 local-model work.

3. **Whether claim sharing rides CloudKit visibility or a dedicated grant
   model.** `Visibility::Shared` exists and is the cheap answer, probably the
   wrong one: sharing a *claim* asserts what someone else should believe, which
   wants an explicit grant with an author and a revocation, not an envelope
   flag. Deferred until there is a second person.

4. **Review-expiry design for instruction promotion.** D11 cuts automated
   promotion because ~546 suspended review tasks prove the queue has no drain.
   The design needed is general — per-kind caps, an expiry policy, a "these
   expired unreviewed" digest — and belongs to the task kernel. Memory is simply
   the first subsystem that would have made the existing problem visibly worse.

---

## References

- `crates/impress-core/src/schemas/source.rs` — `CONTENT_CHUNK_SCHEMA`, D7's
  second embed source
- `crates/impress-core/src/search_ops.rs` — `rank_hybrid_candidates`, pinned by
  golden parity and deliberately not reused (D5)
- `crates/impress-core/src/sqlite_store.rs` — `items_fts` columns (:746),
  `idx_items_schema_created` (:729)
- `crates/impress-core/src/operation.rs` — `OperationType::SetPayload`, D8's
  cursor-advance mechanism
- `crates/impress-core/src/item.rs` — `Visibility::Private` as universal default
- `crates/imbib-core/src/search/{embedding_store,ann_index,chunk_index,semantic}.rs`
  — the four modules D3 extracts
- `crates/imbib-core/Cargo.toml` — the `embeddings = ["fastembed"]` feature D3
  deletes
- `crates/impress-store-service/Cargo.toml` — the written refusal that motivates
  D3
- `crates/impress-ai-http/src/main.rs` — the daily compaction loop and
  `IMPRESS_COMPACT_WINDOW_DAYS`
- `crates/impel-enrichment/src/classify_llm.rs` — the LLM-with-deterministic-
  fallback pattern D7 follows
- `crates/impel-taskd/src/main.rs` — executor registration, `IMPRESS_OMLX_URL`
- `crates/impel-tools/src/lib.rs` — `list_available_tools` and the reachability
  filter D10 amends
- `crates/impress-mcp/src/server.rs` — the `impress://` resource surface
- `apps/imbib/.../Recommendation/EmbeddingService.swift` — the only writer of
  vectors today; the `apple-nl` stamp and the 512→384 stride
- ADR-0001 (item envelope) · ADR-0003 (attribution on every mutation) ·
  ADR-0005/0015 (executors, `agent-run@1.0.0`) · ADR-0006 (why memory is
  Durable, and the window D8 stays ahead of) · ADR-0022 (store-generic service
  precedent)
- ADR-0012: Knowledge Objects — D39 field convention, D42 (this ADR's premise),
  D43 retention, open question 5 (answered by D9)
- ADR-0017: The Legible Graph — where the deferred memory UI composes
- ADR-0021: Record-Kind Descriptors — the contract D12 defers
- ADR-0024: MCP Surface Projection — why seven verbs, and why grouping is a view
- ADR-0026: Provenance-First AI Infrastructure — agent-runs as the v1
  consolidation source
- impel ADR-015 (`crates/impel-core/docs/adr/015-long-term-memory.md`) — the
  three memory types, promoted to suite scope by D1
- imbib ADR-022 (`apps/imbib/docs/adr/022-embedding-index-sync-strategy.md`) —
  device-local embedding generation, preserved by D2
