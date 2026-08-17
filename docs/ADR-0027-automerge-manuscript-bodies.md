# ADR-0027: Manuscript Bodies Are Automerge Documents

**Status:** Accepted — implementation in progress (P0–P2; see plan)  
**Date:** 2026-08-16  
**Depends on:** ADR-0006 (Operation log), ADR-0007 (Sync architecture), ADR-0011 (Journal / revisions), ADR-0018 (GUI-meld), ADR-0023 (Watched folders)  
**Supersedes:** the compare-and-set body save (`set_manuscript_body(expected_hash)` → 409 → conflict banner) as the *primary* write path; the verb survives as a compatibility shim over the new one.

## Context

A manuscript body is the one record kind in the suite that two writers
legitimately edit *at the same time*: the same user on a Mac and an iPhone,
imbib and imprint on the same Mac, an agent applying an AI author-task while
the human types, and — the workflow that matters most to a researcher — a
coauthor. Every other kind (bibliography entries, collections, tags, flags,
tasks) is a small record where "last writer wins per row" (ADR-0007's LWW +
HLC merge) is the *right* answer. For prose it is the wrong one: LWW on a
100 KB `body_content` string discards one side's paragraph, and the current
defense against that — a `body_content_hash` compare-and-set with a
"take theirs / keep mine" banner — is a UI for losing work politely.

Two facts about the codebase shaped the decision more than any survey:

1. **Automerge is already in the tree, dormant.** `crates/imprint-core`
   depends on `automerge = "0.5"` and carries an Automerge-backed
   `ImprintDocument` plus a `SyncSession`/`Presence` model. None of it is
   wired: no FFI exposes it, the Swift `ImprintDocument` is an unrelated
   `FileDocument`, and `CollaborationService.swift` is `// TODO` plus demo
   collaborators. Left as-is it is a second definition of the same
   capability waiting to drift (the lesson of the retired TypeScript MCP
   server, root CLAUDE.md).
2. **This week's store incidents were transparency failures of an
   append-only log living inside a mutable table** (23 M operation rows,
   WAL starvation, planner statistics). Whatever the CRDT layer writes must
   be *visible* (a named record kind with counts in `/api/health` and
   `impress://store/schemas`), *bounded* (declared compaction, reusing the
   watermark-snapshot pattern of `compact_operations`), and *immutable
   where it claims to be* (enforced at `apply_operation`, as
   `manuscript-revision` already is).

The survey of alternatives (Perkeep, iroh, Loro, CozoDB, Couchbase Lite,
Kùzu — 2026-08-16 session notes) concluded that no whole-store replacement
is a contender for a local-first, offline, iOS-capable, private research
store, and that the merge engine for *collaborative documents* is the one
layer where a community-tested library is categorically better than an
in-house implementation. Automerge (Ink & Switch; Rust core; first-party
Swift bindings; Automerge 3 memory work) is that library.

## Decision

### D1. One runtime, in `impress-core`, feature `collab`

The Automerge runtime lives in `impress-core` behind a `collab` cargo
feature (`automerge = "0.11"`), enabled by the crates that host manuscript
verbs (`imbib-core`), the daemon that compacts (`impress-ai-http`), and the
FFI/service crates that expose them. Swift never links `automerge-swift`;
every edit crosses the FFI as text and comes back as text plus heads.
`imprint-core`'s dormant `ImprintDocument`/`collaboration.rs` are deleted
and its `automerge` dependency removed. `EditMode` and `DocumentMetadata`
(the non-CRDT halves of `document.rs`) stay.

Cost: automerge is pure Rust and compiles into the frameworks that embed
`impress-core` (ImpressStoreFfi, ImbibCore, and siblings) at low
single-digit MB per slice.

### D2. The document is the truth; `body_content` is a materialization

Each manuscript body is an Automerge `Text` object in a per-manuscript
document. `body_content`, `body_content_hash`, `body_modified_at` remain in
the `manuscript` payload as a **derived cache** rewritten on every commit,
so FTS (`items_fts.body`), list rows, Typst/LaTeX compile, revisions
(`manuscript_ops::create_revision`), throughline anchoring and every
existing reader keep working unchanged.

Invariant: `body_content == doc.text()` after every collab verb.

### D3. Change chunks are the persistence and sync unit

Every commit writes one immutable `manuscript-change@1.0.0` item carrying
the raw bytes of the Automerge changes it produced (base64 in the payload;
these are hundreds of bytes to a few KB — payload-sized, not blob-sized),
with envelope `parent = manuscript id` (indexed by `idx_items_parent`) and
payload `parent_manuscript_ref`, `kind` (`change` | `snapshot`), `heads`,
`byte_length`, `actor`.

Why chunks, not "Automerge bytes in `crdt_state`": a single mutable state
field would be rewritten on every debounce (the op-churn pattern just
fixed) *and* would be LWW-merged by ADR-0007 sync — which silently drops
one device's edits, the exact failure this ADR exists to end. Immutable
chunk items are **set-union convergent**: sync inserts rows, never merges
them; Automerge de-duplicates changes by hash on load; a chunk arriving in
any order, twice, or after a snapshot is harmless.

Why chunk-per-commit, not coalesced: the store's in-memory document lives
in the *process*, and imbib and imprint on the same Mac hold separate
processes over the same SQLite file. Un-flushed in-memory changes are
invisible to the sibling; the only state both can see is what is in the
database. A chunk per commit makes "what is in the database" complete.
Volume is bounded by the session debounce (200 ms while typing, ~10⁴
chunks on a heavy writing day) and folded by D5. It is measured from day
one via `/api/health` `ops_by_target_schema` and the schemas resource.

Chunk items are **payload-immutable**, enforced in `apply_operation`
alongside `manuscript-revision`.

### D4. Deterministic genesis and recovery — the idempotency rule

Two edits must never enter a document twice. Text-diff "recovery" is the
way that happens: two processes (or two devices) noticing the same
`body_content ≠ doc.text()` would each mint a change inserting the same
text, and merging them duplicates it.

Therefore every change that is *derived from the materialized text* rather
than typed is made **byte-identical wherever it is computed**:

- **Genesis** (a manuscript with no chunks yet — every existing manuscript
  on first touch, on every device): a change with actor id derived from
  `sha256("genesis" ‖ manuscript id ‖ body hash)`, time `0`, fixed message,
  produced by `update_text` from empty. Two devices migrating the same
  manuscript produce the same change hash; Automerge de-duplicates.
- **Recovery** (a legacy or external writer moved `body_content` without a
  chunk — an old build, a watched-folder snapshot replace): actor derived
  from `sha256("recovery" ‖ manuscript id ‖ doc heads ‖ body hash)`, time
  `0`, applied as `update_text(body_content)` on a fork at the doc's
  current heads. Same inputs anywhere → same bytes → de-duplicated.

Typed edits use a random per-process actor (Automerge's default), which is
required: two processes sharing an actor id would collide on sequence
numbers.

### D5. Compaction reuses the watermark-snapshot pattern

`compact_manuscript_changes(min_chunks)`: for each manuscript with at least
`min_chunks` chunk items, write one `kind: snapshot` chunk holding
`doc.save()` and delete the chunks it covers (tombstoned, so sync deletes
them too). The daemon runs it in its daily cycle next to
`compact_operations`. Snapshots load with `load`, later chunks with
`load_incremental`; a device that still holds pre-snapshot chunks loads
both and converges.

### D6. The verb, Rust-first: `commit_manuscript_body`

```
commit_manuscript_body(id, base_heads: [hex], text) -> { heads, body, body_hash, merged_external }
```

Under the store's writer serialization: refresh the in-memory doc from any
unseen chunks (all chunk items for the manuscript, applied by item id —
`created` is the *source's* clock and cannot order synced rows); apply D4
recovery if `body_content ≠ doc.text()`; fork the doc **at `base_heads`**,
`update_text(text)` on the fork (the diff is against the base the caller
actually saw, so a stale caller's edits land as concurrent ops, not as
overwrites), merge the fork back; persist the new changes as a chunk;
materialize (D2); return the merged text and the new heads. An empty
`base_heads` means "unknown base" and diffs against the current text —
last-writer semantics for overlapping regions, no loss elsewhere.

`set_manuscript_body(expected_hash)` keeps its compare-and-set contract for
existing callers and tests but writes *through* the document (unknown-base
commit), so no in-repo writer can leave `body_content` and the document
divergent. Every in-repo caller (editor session, imbib-iOS detail view,
`PUT /api/manuscripts/{id}/body`, MCP/CLI via the service traits) moves to
`commit_manuscript_body`; the CAS verb is a compatibility shim.

Watched-folder manuscripts (`external_source`, ADR-0023 D4/W3) stay
snapshot-replace and never take a session; the file is the truth there and
D4 recovery is what keeps the document honest when they are re-read.

### D7. Editors send text, receive text

The chassis `ManuscriptEditorSession` keeps its buffer + debounce and
replaces `saveCAS` with `commit(baseHeads)`. When the returned body differs
from the buffer (another writer's edits were merged), the session applies
the merged text to the buffer, clamps the caret, and re-pins heads. The
"take theirs / keep mine" conflict banner has no remaining case and is
retired. `absorbExternalChange` (a store event from another writer)
fast-forwards when the buffer is clean and otherwise commits, which merges.
The iOS hosts (`IOSManuscriptDetailView`, `IOSManuscriptEditorHost`) do the
same through the same verb. Whole-buffer `update_text` diffing at debounce
is deliberate: it is O(n) per save (the CAS path already hashed the whole
body per save), needs no editor delta plumbing, and can be upgraded to
`splice_text` from `shouldChangeTextIn` later without changing any store
contract.

### D8. Scope boundary

In: the manuscript body. Next candidates, each its own decision:
throughline `body_content` (ADR-0016), the publication `note` document.
Out: bibliography rows, collections, tags, flags, tasks (LWW is correct);
coauthor sharing between iCloud users (CKShare zones or a relay/iroh — a
separate ADR: identity, invitations, permissions); real-time presence
(cursors); the transport for multi-device sync, which is ADR-0007 Phase D
carrying chunk rows like any other item.

## Consequences

- No lost manuscript edits between a user's own devices or processes;
  merge instead of banner; per-change history for free (the "modification
  history" surface shipped 2026-08-07 gains change granularity and
  time-travel to any heads).
- A new record kind with counts a human can see and a compaction someone
  owns — the posture, not the product, that the artifact-repository
  discussion (2026-08-16) argued for.
- Chunk volume is a *measured* number; if the 200 ms cadence proves too
  chatty for the store, the session debounce is the single knob (D3 explains
  why coalescing in-process is not the knob).
- The dormant collaboration scaffolding is gone; presence, when it comes,
  is built on the shipped document, not beside it.
- The FFI grows five verbs (`commit_manuscript_body`,
  `manuscript_collab_heads`, `manuscript_change_history`,
  `manuscript_text_at`, and the daemon-side `compact_manuscript_changes`),
  all generated for MCP/CLI/impel through the service traits like every
  other verb.

## Verification

- `impress-core` unit + property tests: convergence (two stores, random
  interleaved edit scripts, chunks exchanged in random order and with
  duplicates → identical text), genesis and recovery determinism (two
  independent computations → identical change hash), snapshot compaction
  round-trip, `body_content == doc.text()` after every verb, chunk
  immutability rejected at `apply_operation`.
- `imbib-core`: `set_manuscript_body` compatibility tests unchanged and
  green; new commit/merge tests over the FFI-facing API.
- imprint-selftest Tier A capability `manuscripts.collab_convergence`.
- Live: `PUT /api/manuscripts/{id}/body` with stale `base_heads` from a
  second client returns the *merged* body; the editing session shows the
  merge with no banner; `/api/health` reports the chunk kind's ops.

## Plan

`~/.claude/plans/plan-automerge-manuscript-collab.md` — phases P0
(runtime + module), P1 (schema, verbs, compaction, tests), P2 (editors,
routes, history, selftest), P3 (multi-device via ADR-0007 Phase D).
