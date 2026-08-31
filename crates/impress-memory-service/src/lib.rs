//! `MemoryService` — the agent-facing surface of the suite memory kernel
//! (ADR-0028, `docs/ADR-0028-memory-kernel.md`).
//!
//! Every `#[impress_method]` here is a thin wrapper over
//! `impress_core::memory_ops`: this crate converts arguments, maps the
//! kernel's types to DTOs, and turns errors into `ok: false` plus the
//! kernel's own message — the same shape `impress-store-service`'s
//! `TriageService` and `StoreQueryService` use, and for the same reason: no
//! domain logic lives here, so the CLI, MCP and impel all call the identical
//! behaviour a headless `cargo test` already proves.
//!
//! **Two tiers, one always on.** The FTS tier (full-text dedup gate,
//! full-text retrieval, the deterministic ranker) is always live and needs
//! nothing configured. The vector tier (ADR-0028 D6) is opt-in — set
//! `IMPRESS_MEMORY_VECTORS=1` — and COMPOSES with the FTS tier rather than
//! replacing it, per the kernel's own module docs
//! (`memory_ops::MemoryCandidate::vector_similarity`): `remember`'s dedup
//! gate runs FTS first and only falls to the (higher-threshold) vector check
//! when FTS found nothing; `recall` re-ranks the SAME page FTS already
//! selected rather than widening it. [`DefaultMemoryService::memory_status`]
//! reports which tier is actually running — see its own doc for the exact
//! states — rather than a static claim either way.
//!
//! The vector tier is lazy and process-wide: it is built at most once, on
//! the first `remember` or `recall` call after the env var is read as `"1"`,
//! and any failure to build it (missing sidecar, model load failure) turns
//! it off for the rest of the process with one `stderr` line — imitating
//! `impress-mcp::tools::SEMANTIC_UNAVAILABLE`'s degraded-mode discipline.
//! `memory_status` never triggers that build (it would pay for a
//! `SemanticSearch` model load just to answer a status query); it only ever
//! peeks at whatever state already exists and opens the sidecar (cheaply,
//! read-only in effect) to count vectors.
//!
//! # Attribution
//!
//! Every write this service makes is stamped `author: "impress-memory-service"`,
//! `author_kind: `[`ActorKind::System`]. None of the trait methods take an
//! author argument — a caller may be a human at the CLI, an MCP client, or an
//! impel agent, and the service has no reliable way to tell which — so, like
//! `impress-store-service`'s own automated writers
//! (`docs_import_service::new_manuscript`, `source_service::put_*`), it
//! attributes its writes to itself rather than guessing. This mirrors, not
//! invents, the established convention for a service-authored write in this
//! crate family.

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, OnceLock};

use impress_core::item::{ActorKind, ItemId, Value};
use impress_core::memory_ops::{self, GateOutcome, MemoryDraft, MemoryKind};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
use impress_embeddings::EmbeddingStore;
#[cfg(feature = "vector-embedder")]
use impress_embeddings::SemanticSearch;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// Result of [`MemoryService::remember`] and [`MemoryService::supersede_claim`].
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RememberResult {
    pub ok: bool,
    /// `"inserted"` | `"confirmed"`. Empty when `ok` is false.
    pub action: String,
    /// The id of the memory now representing this claim: the freshly written
    /// row when `action` is `"inserted"`, or the existing row when
    /// `"confirmed"`. Empty when `ok` is false.
    pub claim_id: String,
    /// The near-duplicate the dedup gate matched against, when `action` is
    /// `"confirmed"` (equal to `claim_id` in that case). Empty when
    /// `"inserted"` — nothing was matched — and empty when `ok` is false.
    pub matched_id: String,
    /// Which dedup gate produced the match: `"fts"` (token overlap ≥
    /// `memory_ops::GATE_CONFIRM_THRESHOLD`) or `"vector"` (embedding cosine
    /// ≥ [`VECTOR_CONFIRM_THRESHOLD`], only possible when the vector tier is
    /// live). Empty when `action` is `"inserted"` or `ok` is false.
    ///
    /// Additive field (ADR-0028 D6, phase P6b) — `#[serde(default)]` so a
    /// value serialized before this field existed still deserializes.
    #[serde(default)]
    pub matched_via: String,
    pub message: String,
}

/// One recalled memory, hydrated and scored.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RecallEntryDto {
    /// Lowercase UUID string.
    pub id: String,
    /// One of the three memory schema refs (`memory/claim@1.0.0`, …).
    pub schema_ref: String,
    pub title: String,
    pub body: String,
    /// Only meaningful when `schema_ref` is a claim.
    pub claim_type: Option<String>,
    /// 0.0–1.0. Absent means the author left it unstated, not zero.
    pub confidence: Option<f64>,
    /// How many times this memory has been independently re-observed.
    pub confirmations: u32,
    /// `Item::modified`, epoch milliseconds.
    pub modified_ms: i64,
    /// The ranker's score for this entry, within this call. Comparable across
    /// entries of the SAME call only — not a stable identity of the memory.
    pub score: f64,
    /// Lowercase UUIDs of the items this memory is about.
    pub subject_refs: Vec<String>,
}

impl From<memory_ops::RecallEntry> for RecallEntryDto {
    fn from(e: memory_ops::RecallEntry) -> Self {
        Self {
            id: e.id,
            schema_ref: e.schema_ref,
            title: e.title,
            body: e.body,
            claim_type: e.claim_type,
            confidence: e.confidence.map(|f| f as f64),
            confirmations: e.confirmations,
            modified_ms: e.modified_ms,
            score: e.score as f64,
            subject_refs: e.subject_refs,
        }
    }
}

/// Result of [`MemoryService::recall`].
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RecallResult {
    pub ok: bool,
    /// Best match first.
    pub entries: Vec<RecallEntryDto>,
    pub message: String,
}

/// One section of a [`MemoryService::memory_brief`].
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct BriefSectionDto {
    /// The section's schema ref — which of the three memory kinds this is.
    pub kind: String,
    /// Best match first. May be empty; every section is present even when
    /// empty, so a renderer can rely on position rather than search for a
    /// heading.
    pub entries: Vec<RecallEntryDto>,
}

impl From<memory_ops::BriefSection> for BriefSectionDto {
    fn from(s: memory_ops::BriefSection) -> Self {
        Self {
            kind: s.kind,
            entries: s.entries.into_iter().map(RecallEntryDto::from).collect(),
        }
    }
}

/// Result of [`MemoryService::memory_brief`].
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct BriefResult {
    pub ok: bool,
    /// Instructions, then claims, then episodes — always all three, in that
    /// order. Read this for the structured fields (ids, confidence,
    /// confirmations); read `text` for prose.
    pub sections: Vec<BriefSectionDto>,
    /// A compact markdown rendering of `sections` — `### Instructions` /
    /// `### Claims` / `### Episodes` headings (only for non-empty sections),
    /// each entry as `- **title** — body… \`[impress-item:<id>]\``, body cut
    /// to about 200 characters. Ready to paste or inject directly into a
    /// system prompt or session briefing.
    pub text: String,
    pub message: String,
}

/// Result of a single-item action: [`MemoryService::confirm_claim`] and
/// [`MemoryService::forget`].
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ActionResult {
    pub ok: bool,
    /// The item acted on, echoed back.
    pub id: String,
    pub message: String,
}

/// Row counts for one memory schema.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SchemaCountDto {
    pub schema_ref: String,
    /// Current, non-superseded, non-withheld rows — capped at
    /// `memory_ops::MAX_RECALL_LIMIT` (200); a store with more heads than
    /// that in one schema reports the cap, not the true count.
    pub heads: u32,
    /// Every row of this schema, superseded and withheld included.
    pub total: u32,
}

/// Result of [`MemoryService::memory_status`].
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct StatusResult {
    pub ok: bool,
    /// One entry per memory schema (claim, episode, instruction).
    pub schemas: Vec<SchemaCountDto>,
    /// Fraction (0.0–1.0) of memory items with a same-model vector in the
    /// vector-tier sidecar, i.e. `N / M` from the `vector_tier` string
    /// below. Always `0.0` when the vector tier is off (`IMPRESS_MEMORY_VECTORS`
    /// unset); real whenever it is at least configured — computed by
    /// opening the sidecar and counting, which needs no live embedder, so
    /// this is accurate even in the `"initializing lazily"` state.
    pub embedding_coverage: f64,
    /// One of four states, cheapest-to-most-configured:
    /// `"off (set IMPRESS_MEMORY_VECTORS=1)"` — the env var is unset;
    /// `"initializing lazily"` — set, but no `remember`/`recall` has run in
    /// this process yet, so the tier has not tried to build itself;
    /// `"live (model <id>, N/M items embedded)"` — built successfully;
    /// `"unavailable: <reason>"` — it tried and failed (logged once to
    /// `stderr` when that happened). See the module docs for the full
    /// two-tier picture.
    pub vector_tier: String,
    pub message: String,
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Suite-scoped agent memory: write, recall and brief over `memory/claim`,
/// `memory/episode` and `memory/instruction` rows in the shared store
/// (ADR-0028).
///
/// A **claim** is what is true ("the 2018 catalogue's flux column is in mJy,
/// not Jy"); an **episode** is what happened ("re-ran the fit with the 2019
/// zero-point, converged in 3 minutes"); an **instruction** is what to do
/// ("never open the shared container from a shell"), from the user, and
/// retired only by supersession or `forget` — never by an agent deciding it
/// no longer applies.
///
/// The FTS tier — full-text retrieval, a token-overlap dedup gate, and a
/// deterministic ranker over relevance, confirmations, recency, author and
/// confidence — is always live. An opt-in vector tier (`IMPRESS_MEMORY_VECTORS=1`,
/// see `memory_status`) composes with it in `remember` (a second,
/// higher-threshold dedup check) and `recall` (an embedding-similarity
/// re-ranking of the same page FTS already selected).
#[impress_service]
pub trait MemoryService: Send + Sync + 'static {
    /// Write a memory, or — if a near-duplicate already exists — confirm it
    /// instead of writing a second copy.
    ///
    /// `kind` is one of `"claim"`, `"episode"` or `"instruction"`; anything
    /// else fails with `ok: false`. Before writing, this runs the dedup gate:
    /// if an existing memory of the SAME kind has near-identical prose (token
    /// overlap ≥ 0.85) and a compatible `claim_type`, that row is CONFIRMED
    /// (its `confirmations` count goes up) instead of a duplicate being
    /// inserted — `action` reports which happened, and `matched_id` names the
    /// row that was matched. Call this whenever something is worth keeping
    /// across sessions; re-remembering the same fact is safe and cheap by
    /// design; it is very much not free to fail to remember something, so
    /// default to calling this rather than deciding for yourself whether a
    /// fact is "new enough".
    ///
    /// When the vector tier is live (`IMPRESS_MEMORY_VECTORS=1`) and the FTS
    /// gate above found nothing, a SECOND check runs: embed the draft and
    /// compare against stored memory-item vectors by cosine similarity. A
    /// paraphrase the FTS gate's token overlap missed entirely can still
    /// score high here, so this bar is deliberately higher than the FTS
    /// one's (`VECTOR_CONFIRM_THRESHOLD` = 0.92) — see its doc for why. When
    /// it fires, `matched_via` reports `"vector"` instead of `"fts"`.
    ///
    /// `claim_type` (meaningful only when `kind` is `"claim"`: `"fact"` |
    /// `"preference"` | `"method"` | `"decision"` | `"result"`, or any other
    /// label — the vocabulary is open) and `confidence` (0.0–1.0) may be left
    /// as an empty string / a negative number respectively to mean
    /// "unstated" — that is NOT the same as zero and is not scored as zero.
    /// `subject_refs` are the lowercase-UUID ids of items this memory is
    /// ABOUT; `evidence_refs` are the ids it was DERIVED FROM (a transcript,
    /// a paper, a run). Either may be empty. An id that does not resolve to a
    /// live item is kept in the record but silently skipped as a graph edge
    /// — it does not fail the write.
    #[impress_method]
    #[allow(clippy::too_many_arguments)]
    async fn remember(
        &self,
        kind: String,
        title: String,
        body: String,
        claim_type: String,
        confidence: f64,
        subject_refs: Vec<String>,
        evidence_refs: Vec<String>,
    ) -> RememberResult;

    /// Retrieve memories, ranked by relevance, confirmations, recency, author
    /// and confidence.
    ///
    /// `query` is treated as words, not FTS5 syntax. An EMPTY query is not an
    /// empty result — it returns the most relevant heads by recency, which is
    /// what lets `memory_brief` be a composition of this call rather than a
    /// second retrieval path. Pass a non-empty `subject_ref` (a lowercase
    /// UUID) to narrow to memories about one item. `limit` of `0` means the
    /// kernel default (20); values are clamped to 200. Superseded memories
    /// (retracted by a `supersede_claim` correction) are withheld unless
    /// `include_superseded` is true; memories withheld by `forget` are never
    /// returned, regardless.
    ///
    /// When the vector tier is live, this page is RE-RANKED — never widened
    /// — by embedding `query` once and scoring every entry that has a stored
    /// vector by cosine similarity; entries with no vector keep their
    /// FTS/recency position. Off, or against a store with no memory-item
    /// vectors embedded yet, results are byte-identical to the FTS-only
    /// tier.
    #[impress_method]
    async fn recall(
        &self,
        query: String,
        subject_ref: String,
        limit: i64,
        include_superseded: bool,
    ) -> RecallResult;

    /// The "start of session" digest: standing instructions, then claims
    /// (optionally scoped to `topic`), then recent episodes — always in that
    /// order, because instructions constrain everything that follows them.
    /// Call this once at the start of a task to load what you already know,
    /// the same way a human would re-read their own notes.
    ///
    /// `topic` scopes ONLY the claims section (full-text, same rules as
    /// `recall`); an instruction that does not mention the topic still binds
    /// and still appears — filtering instructions by topic would quietly
    /// drop exactly the constraint the current work was not expecting to
    /// need. Pass a non-empty `subject_ref` to narrow every section to
    /// memories about one item. `max_entries` caps each section
    /// independently (`0` means the kernel default of 8).
    ///
    /// `text` is ready to paste or inject directly into a system prompt;
    /// read `sections` instead when the structured fields (id, confidence,
    /// confirmations) matter more than prose.
    #[impress_method]
    async fn memory_brief(
        &self,
        topic: String,
        subject_ref: String,
        max_entries: i64,
    ) -> BriefResult;

    /// Record that a memory was independently re-observed, WITHOUT writing a
    /// duplicate row: bumps `confirmations` and stamps `last_confirmed`.
    ///
    /// `remember` already calls this automatically when its dedup gate finds
    /// a near-duplicate — call it directly only when you already hold the
    /// exact id (from a prior `recall` or `memory_brief`) and want to record
    /// that it still holds without restating the prose.
    #[impress_method]
    async fn confirm_claim(&self, id: String) -> ActionResult;

    /// Retract a claim by REPLACING it: writes a new claim from `title` /
    /// `body`, then records that it supersedes `old_id`. The old row is left
    /// completely untouched (it stays in the graph for audit — pass
    /// `include_superseded: true` to a later `recall` to see it again); this
    /// only stops it being returned by default.
    ///
    /// Use this when a previously-remembered fact turns out to be wrong, or
    /// needs correcting or sharpening. `reason` is optional (empty string
    /// omits it) but is recorded on the replacement edge when given, and is
    /// worth the sentence — it is the only place "why was this retracted"
    /// survives. This is NOT how to retire a memory that was never wrong but
    /// is simply unwanted or private; use `forget` for that instead.
    #[impress_method]
    async fn supersede_claim(
        &self,
        old_id: String,
        title: String,
        body: String,
        reason: String,
    ) -> RememberResult;

    /// Withhold a memory from `recall` and `memory_brief` WITHOUT deleting it
    /// — for something that turned out to be private, unwanted, or wrong in a
    /// way `supersede_claim` does not express (there is no correct
    /// replacement text). The row and its evidence edges stay in the store;
    /// this only flips the flag every read path already honours, so the
    /// action is reversible by a direct store edit even though no verb here
    /// un-forgets it.
    #[impress_method]
    async fn forget(&self, id: String) -> ActionResult;

    /// Row counts per memory schema (heads and totals), plus which retrieval
    /// tier is running.
    ///
    /// Call this to sanity-check that memory is actually being written to —
    /// an agent that has called `remember` all session but sees zero counts
    /// here has found a real bug, not an empty library — or to decide whether
    /// a semantic (non-lexical) recall would help before deciding one is
    /// worth building. `vector_tier` reports the vector tier's real state
    /// (off / initializing lazily / live / unavailable — see
    /// [`StatusResult::vector_tier`]) and `embedding_coverage` is a real
    /// fraction whenever the tier is at least configured; this call never
    /// pays for a model load itself, so it is always cheap to check.
    #[impress_method]
    async fn memory_status(&self) -> StatusResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Envelope author stamped on every write this service makes. See the module
/// docs ("Attribution") for why this is a constant rather than a
/// caller-supplied argument.
const AUTHOR: &str = "impress-memory-service";

/// Payload key holding the withhold-from-recall flag. Mirrors
/// `impress_core::memory_ops`'s private `NO_RECALL_FIELD` constant — not a
/// schema ref (it names a payload field, not a record kind), so it is outside
/// `scripts/check-schema-refs.sh`'s scope. Kept honest by
/// `forget_hides_a_memory_from_recall`, which asserts through the kernel's
/// own public `recall` rather than by re-reading this field back.
const NO_RECALL_FIELD: &str = "no_recall";

// ---------------------------------------------------------------------------
// Vector tier (ADR-0028 D6) — opt-in, lazy, process-wide.
// ---------------------------------------------------------------------------
//
// This section is everything the vector tier needs, self-contained: the
// embedder seam, the lazily-built process singleton, the env gate, and the
// read-only coverage counter `memory_status` uses instead of it. Nothing
// outside this section reaches `impress_embeddings::SemanticSearch`,
// `EmbeddingStore`, or the two env vars directly — `remember`/`recall` go
// through `DefaultMemoryService::vector_tier`, and `memory_status` goes
// through `DefaultMemoryService::vector_status`.

/// Env var that opts a process into the vector tier. Any value other than
/// exactly `"1"` (including unset) means "off" — see the module docs.
const VECTOR_TIER_ENV: &str = "IMPRESS_MEMORY_VECTORS";

/// Env var overriding the embeddings sidecar path for this process. Mirrors
/// `impel_memory::embed::EMBEDDINGS_PATH_ENV` and the default
/// `impress_mcp::default_embeddings_path()` resolves to
/// (`dirs::data_dir()/imbib/embeddings.sqlite`) — REPLICATED here rather
/// than imported, the same way `impel-memory` replicates rather than
/// imports `impress-mcp`'s (private, and the wrong dependency direction:
/// `impress-mcp` already depends on this crate) copy. Three copies of one
/// six-line function is accepted duplication, not a design; a shared
/// `impress-embeddings`-side helper would be the right fix (see this PR's
/// report for the pointer).
const EMBEDDINGS_PATH_ENV: &str = "IMPRESS_EMBEDDINGS_PATH";

/// The sidecar `source_type` a memory-item vector is written under. Mirrors
/// `impel_memory::SOURCE_TYPE_MEMORY` (duplicated for the same reason as
/// [`EMBEDDINGS_PATH_ENV`] — this crate does not depend on `impel-memory`).
const MEMORY_ITEM_SOURCE_TYPE: &str = "memory-item";

/// Cosine similarity at or above which the vector tier's half of `remember`'s
/// dedup gate confirms an existing memory instead of inserting a new one —
/// the semantic-tier counterpart to `memory_ops::GATE_CONFIRM_THRESHOLD`
/// (0.85 token overlap).
///
/// Deliberately HIGHER than the FTS threshold. `remember` bodies are
/// typically a sentence or two, and short texts embed into a tighter region
/// of a sentence-embedding model's vector space than long ones do — two
/// genuinely UNRELATED short claims routinely cosine well above 0.85 purely
/// from sharing sentence structure and common words, so reusing the FTS
/// number here would over-merge distinct memories. 0.92 is a conservative
/// choice for the same asymmetric-cost reason `GATE_CONFIRM_THRESHOLD` is
/// high rather than moderate: confirming when it should have inserted loses
/// a distinct memory outright, while inserting when it should have confirmed
/// only costs one redundant row a later consolidation pass can merge.
const VECTOR_CONFIRM_THRESHOLD: f32 = 0.92;

/// Turns text into a vector. The seam that keeps the vector tier testable
/// without ever constructing a real `SemanticSearch` — first use downloads a
/// ~100MB ONNX model, which has no place in a unit test. Implemented for the
/// real embedder below; tests implement it with a deterministic stub.
/// `impel_memory::TextEmbedder` is the identical seam on the WRITE side of
/// this same sidecar, for the identical reason.
trait Embedder: Send + Sync {
    /// Embed `text`. `Err` is always treated as "this one call degrades",
    /// never as "turn the tier off" — see `DefaultMemoryService::vector_tier`'s
    /// callers.
    fn embed(&self, text: &str) -> Result<Vec<f32>, String>;

    /// The id stamped into / filtered by `StoredVector.model` (ADR-0028 D4).
    /// Must be what THIS embedder actually is, never a caller's request.
    fn model_id(&self) -> &str;
}

#[cfg(feature = "vector-embedder")]
impl Embedder for SemanticSearch {
    fn embed(&self, text: &str) -> Result<Vec<f32>, String> {
        self.embed_text(text).map_err(|e| e.to_string())
    }

    fn model_id(&self) -> &str {
        SemanticSearch::model_id(self)
    }
}

/// The live vector tier: an opened sidecar plus a ready embedder. Built at
/// most once per process by [`process_vector_tier`] — or, in tests,
/// constructed directly against a temp sidecar and a stub embedder, via
/// [`DefaultMemoryService::with_store_and_vector_tier`], bypassing the env
/// gate and the process-wide singleton entirely so tests never race each
/// other over shared process state.
struct VectorTierInner {
    embedding_store: EmbeddingStore,
    embedder: Box<dyn Embedder>,
}

/// The result of the one, at-most-once attempt to build [`VectorTierInner`]
/// for this process.
enum TierState {
    Live(VectorTierInner),
    /// Carries the reason so `memory_status` can report
    /// `"unavailable: <reason>"` — the plain `Option` `impress-mcp::tools::ToolContext`
    /// caches for its own degraded mode is not enough here because, unlike
    /// that context, this service ALSO ANSWERS A STATUS QUERY about the
    /// failure rather than only degrading tool calls.
    Failed(String),
}

/// Whether this process has opted into the vector tier. Cheap and stateless
/// — reads the env var fresh every call — because the ONLY thing gating on
/// it must guarantee is "never touch [`VECTOR_TIER`] when this is false",
/// not "cache the answer".
fn vector_tier_env_enabled() -> bool {
    std::env::var(VECTOR_TIER_ENV)
        .map(|v| v == "1")
        .unwrap_or(false)
}

/// Resolve the sidecar path: [`EMBEDDINGS_PATH_ENV`], then the platform
/// default. `None` only when the platform has no data directory AND the env
/// var is unset — a machine misconfiguration [`try_init_vector_tier`] turns
/// into a `Failed` state like any other.
fn resolve_embeddings_path() -> Option<String> {
    if let Ok(path) = std::env::var(EMBEDDINGS_PATH_ENV) {
        if !path.trim().is_empty() {
            return Some(path);
        }
    }
    dirs::data_dir().map(|dir| {
        dir.join("imbib/embeddings.sqlite")
            .to_string_lossy()
            .into_owned()
    })
}

/// Open the sidecar and load the embedding model. The fallible half of
/// building a [`VectorTierInner`], separated from [`init_vector_tier`] so the
/// `stderr` line lives in exactly one place regardless of which step failed.
#[cfg(feature = "vector-embedder")]
fn try_init_vector_tier() -> Result<VectorTierInner, String> {
    let path = resolve_embeddings_path().ok_or_else(|| {
        "no data directory available and IMPRESS_EMBEDDINGS_PATH is unset".to_string()
    })?;
    let embedding_store =
        EmbeddingStore::open(&path).map_err(|e| format!("open sidecar {path}: {e}"))?;
    let embedder = SemanticSearch::new().map_err(|e| format!("initialize embedding model: {e}"))?;
    Ok(VectorTierInner {
        embedding_store,
        embedder: Box::new(embedder),
    })
}

/// Feature-off twin: binaries built without `vector-embedder` (the FFI
/// consumers — impel-tools must never link the ONNX runtime) get the same
/// degraded path a missing model produces at runtime.
#[cfg(not(feature = "vector-embedder"))]
fn try_init_vector_tier() -> Result<VectorTierInner, String> {
    Err("built without the vector-embedder feature (FTS tier only)".to_string())
}

/// [`try_init_vector_tier`], with the one-time `stderr` line on failure. Only
/// ever invoked by [`VECTOR_TIER`]'s `get_or_init` — i.e. AT MOST ONCE per
/// process — so this printing here (rather than at every call site that sees
/// a cached `Failed`) is what keeps it to one line for the process lifetime,
/// imitating `impress-mcp::tools::ToolContext::semantic`'s degraded-mode
/// discipline.
fn init_vector_tier() -> TierState {
    match try_init_vector_tier() {
        Ok(inner) => TierState::Live(inner),
        Err(e) => {
            eprintln!("impress-memory-service: vector tier unavailable: {e}");
            TierState::Failed(e)
        }
    }
}

/// Process-wide, at-most-once vector tier state. Reached ONLY through
/// [`process_vector_tier`] (which gates on the env var first) and peeked
/// (never initialized) by `memory_status` via a bare `.get()` — see the
/// module docs' cost rule.
static VECTOR_TIER: OnceLock<TierState> = OnceLock::new();

/// The live tier for `remember`/`recall`'s production path, or `None` when
/// it is off, still uninitialized-and-this-call-does-not-need-it-yet (it
/// does; calling this always resolves it), or unavailable. Building it here,
/// lazily, on the first call that needs it is what satisfies the cost rule:
/// nothing pays for a sidecar open or a model load unless the env var is set
/// AND a memory verb actually runs.
fn process_vector_tier() -> Option<&'static VectorTierInner> {
    if !vector_tier_env_enabled() {
        return None;
    }
    match VECTOR_TIER.get_or_init(init_vector_tier) {
        TierState::Live(inner) => Some(inner),
        TierState::Failed(_) => None,
    }
}

/// `N / M`, or `0.0` when there is nothing to divide by — never a division
/// producing NaN or infinity.
fn coverage_ratio(embedded: usize, total: u32) -> f64 {
    if total == 0 {
        0.0
    } else {
        embedded as f64 / total as f64
    }
}

/// Vector coverage WITHOUT constructing a [`SemanticSearch`] — opens the
/// sidecar (cheap: no model, no HNSW build) and counts memory-item vectors
/// for `model`. This is the whole reason `memory_status` does not simply
/// call [`process_vector_tier`]: that path may need to load the embedding
/// model, and a status query must never pay for that just to answer.
///
/// `0.0` when the sidecar cannot be opened (including "does not exist yet")
/// — an absent sidecar means zero vectors, not an error worth surfacing here
/// (the `vector_tier` status string already says `"initializing lazily"` or
/// `"unavailable: ..."` in the cases where that distinction matters).
fn readonly_coverage(model: &str, total_items: u32) -> f64 {
    let Some(path) = resolve_embeddings_path() else {
        return 0.0;
    };
    let Ok(store) = EmbeddingStore::open(&path) else {
        return 0.0;
    };
    let embedded = store
        .load_vectors_by_type_and_model(MEMORY_ITEM_SOURCE_TYPE, model)
        .map(|v| v.len())
        .unwrap_or(0);
    coverage_ratio(embedded, total_items)
}

/// Store-backed `MemoryService`. `new()` uses the shared store (opened
/// lazily); `with_store` takes an explicit one, as the tests do.
#[derive(Clone, Default)]
pub struct DefaultMemoryService {
    store: Option<Arc<SqliteItemStore>>,
    /// Test-only override for the vector tier. `None` in every production
    /// instance (`new()` never sets it) — meaning "ask the process-wide,
    /// env-gated singleton". `Some` means "use exactly this, unconditionally
    /// LIVE, ignoring `IMPRESS_MEMORY_VECTORS` entirely" — set only by
    /// [`DefaultMemoryService::with_store_and_vector_tier`], so tests never
    /// touch the env var or the process-wide static and so never race each
    /// other over either.
    vector_override: Option<Arc<VectorTierInner>>,
}

impl DefaultMemoryService {
    pub fn new() -> Self {
        Self {
            store: None,
            vector_override: None,
        }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self {
            store: Some(store),
            vector_override: None,
        }
    }

    /// Test seam: a service whose vector tier is exactly `embedding_store` +
    /// `embedder`, unconditionally live, never touching
    /// [`VECTOR_TIER_ENV`]/[`EMBEDDINGS_PATH_ENV`] or the process-wide
    /// [`VECTOR_TIER`] static. See [`DefaultMemoryService::vector_override`].
    #[cfg(test)]
    fn with_store_and_vector_tier(
        store: Arc<SqliteItemStore>,
        embedding_store: EmbeddingStore,
        embedder: impl Embedder + 'static,
    ) -> Self {
        Self {
            store: Some(store),
            vector_override: Some(Arc::new(VectorTierInner {
                embedding_store,
                embedder: Box::new(embedder),
            })),
        }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store
            .clone()
            .unwrap_or_else(impress_store_service::store::store_instance)
    }

    /// The tier `remember`/`recall` use: the test override when set,
    /// otherwise the process-wide lazy singleton (which resolves the env
    /// gate itself). Never called by `memory_status` — see
    /// [`DefaultMemoryService::vector_status`].
    fn vector_tier(&self) -> Option<&VectorTierInner> {
        self.vector_override
            .as_deref()
            .or_else(|| process_vector_tier())
    }

    /// `memory_status`'s vector-tier reporting, kept separate from
    /// `vector_tier` because it must NEVER trigger a `SemanticSearch` build
    /// (the cost rule) — it only peeks at [`VECTOR_TIER`]'s current state
    /// (or, under a test override, treats it as unconditionally live) and
    /// otherwise counts vectors via [`readonly_coverage`], which opens only
    /// the sidecar.
    fn vector_status(&self, total_items: u32) -> (String, f64) {
        if let Some(tier) = &self.vector_override {
            let model = tier.embedder.model_id();
            let embedded = tier
                .embedding_store
                .load_vectors_by_type_and_model(MEMORY_ITEM_SOURCE_TYPE, model)
                .map(|v| v.len())
                .unwrap_or(0);
            return (
                format!("live (model {model}, {embedded}/{total_items} items embedded)"),
                coverage_ratio(embedded, total_items),
            );
        }
        if !vector_tier_env_enabled() {
            return (format!("off (set {VECTOR_TIER_ENV}=1)"), 0.0);
        }
        match VECTOR_TIER.get() {
            None => (
                "initializing lazily".to_string(),
                readonly_coverage(impress_embeddings::FASTEMBED_MODEL_ID, total_items),
            ),
            Some(TierState::Live(inner)) => {
                let model = inner.embedder.model_id();
                let embedded = inner
                    .embedding_store
                    .load_vectors_by_type_and_model(MEMORY_ITEM_SOURCE_TYPE, model)
                    .map(|v| v.len())
                    .unwrap_or(0);
                (
                    format!("live (model {model}, {embedded}/{total_items} items embedded)"),
                    coverage_ratio(embedded, total_items),
                )
            }
            Some(TierState::Failed(reason)) => (
                format!("unavailable: {reason}"),
                readonly_coverage(impress_embeddings::FASTEMBED_MODEL_ID, total_items),
            ),
        }
    }
}

fn describe(err: StoreError) -> String {
    err.to_string()
}

/// Trim `s`; `None` when nothing is left. The service-wide convention for
/// "empty string argument means absent", used for `claim_type`,
/// `subject_ref`, `topic` and `reason` — arguments the codegen macro's
/// allow-listed simple types keep as plain `String` rather than
/// `Option<String>`.
fn non_empty(s: &str) -> Option<String> {
    let trimmed = s.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// A tool argument arrives as a signed integer; the kernel takes an unsigned
/// cap where 0 means "the default". Negative is a caller mistake that should
/// behave like "unspecified", not like an error.
fn clamp_u32(n: i64) -> u32 {
    n.clamp(0, u32::MAX as i64) as u32
}

fn parse_kind(kind: &str) -> Option<MemoryKind> {
    match kind.trim() {
        "claim" => Some(MemoryKind::Claim),
        "episode" => Some(MemoryKind::Episode),
        "instruction" => Some(MemoryKind::Instruction),
        _ => None,
    }
}

fn failed_remember(message: String) -> RememberResult {
    RememberResult {
        ok: false,
        action: String::new(),
        claim_id: String::new(),
        matched_id: String::new(),
        matched_via: String::new(),
        message,
    }
}

fn failed_status(message: String) -> StatusResult {
    StatusResult {
        ok: false,
        schemas: vec![],
        embedding_coverage: 0.0,
        vector_tier: String::new(),
        message,
    }
}

/// The markdown heading for one brief section.
fn section_heading(schema_ref: &str) -> &'static str {
    match MemoryKind::from_schema_ref(schema_ref) {
        Some(MemoryKind::Instruction) => "Instructions",
        Some(MemoryKind::Claim) => "Claims",
        Some(MemoryKind::Episode) => "Episodes",
        None => "Other",
    }
}

/// The first `max` characters of `s`, with a trailing ellipsis when longer.
/// Counts chars, not bytes, so the cut never lands mid-codepoint.
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max).collect();
    out.push('\u{2026}');
    out
}

/// Render a brief's sections as prompt-ready markdown.
///
/// Empty sections are skipped: `sections` (the structured field) always
/// carries all three so a reader can rely on position, but injecting a
/// heading with nothing under it into a prompt would spend tokens saying
/// nothing.
fn render_brief_markdown(sections: &[memory_ops::BriefSection]) -> String {
    let mut out = String::new();
    for section in sections {
        if section.entries.is_empty() {
            continue;
        }
        out.push_str("### ");
        out.push_str(section_heading(&section.kind));
        out.push('\n');
        for entry in &section.entries {
            out.push_str("- **");
            out.push_str(&entry.title);
            out.push_str("** — ");
            out.push_str(&truncate_chars(&entry.body, 200));
            out.push_str(" `[impress-item:");
            out.push_str(&entry.id);
            out.push_str("]`\n");
        }
        out.push('\n');
    }
    out
}

#[async_trait::async_trait]
impl MemoryService for DefaultMemoryService {
    async fn remember(
        &self,
        kind: String,
        title: String,
        body: String,
        claim_type: String,
        confidence: f64,
        subject_refs: Vec<String>,
        evidence_refs: Vec<String>,
    ) -> RememberResult {
        let Some(memory_kind) = parse_kind(&kind) else {
            return failed_remember(format!(
                "kind must be one of claim, episode, instruction; got {kind:?}"
            ));
        };

        let mut draft = MemoryDraft::new(memory_kind, title, body, AUTHOR, ActorKind::System);
        draft.claim_type = non_empty(&claim_type);
        draft.confidence = (confidence >= 0.0).then_some(confidence);
        draft.subject_refs = subject_refs;
        draft.evidence_refs = evidence_refs;

        let store = self.store();
        let outcome = match memory_ops::gate_fts(&store, &draft, memory_ops::GATE_CONFIRM_THRESHOLD)
        {
            Ok(o) => o,
            Err(e) => return failed_remember(describe(e)),
        };

        match outcome {
            // The FTS gate found nothing — try the vector tier's (higher-
            // threshold) semantic check before falling back to a plain
            // insert. `vector_gate_confirm` is a no-op returning `None`
            // whenever the tier is off, so this costs nothing extra when it
            // is.
            GateOutcome::Insert => {
                if let Some(result) = self.vector_gate_confirm(&store, &draft) {
                    return result;
                }
                match memory_ops::insert_memory_item(&store, &draft) {
                    Ok(id) => RememberResult {
                        ok: true,
                        action: "inserted".into(),
                        claim_id: id.to_string(),
                        matched_id: String::new(),
                        matched_via: String::new(),
                        message: format!("Remembered as a new {kind}: {id}."),
                    },
                    Err(e) => failed_remember(describe(e)),
                }
            }
            GateOutcome::Confirm(existing) => {
                match memory_ops::confirm(&store, existing, AUTHOR, ActorKind::System) {
                    Ok(n) => RememberResult {
                        ok: true,
                        action: "confirmed".into(),
                        claim_id: existing.to_string(),
                        matched_id: existing.to_string(),
                        matched_via: "fts".into(),
                        message: format!("Already known; confirmed ({n} total): {existing}."),
                    },
                    Err(e) => failed_remember(describe(e)),
                }
            }
        }
    }

    async fn recall(
        &self,
        query: String,
        subject_ref: String,
        limit: i64,
        include_superseded: bool,
    ) -> RecallResult {
        let store = self.store();
        let opts = memory_ops::RecallOptions {
            subject_ref: non_empty(&subject_ref),
            limit: clamp_u32(limit),
            include_superseded,
            kinds: Vec::new(),
        };
        match memory_ops::recall(&store, &query, &opts) {
            Ok(entries) => {
                let entries = self.rerank_with_vectors(&query, entries);
                let n = entries.len();
                RecallResult {
                    ok: true,
                    entries: entries.into_iter().map(RecallEntryDto::from).collect(),
                    message: format!("{n} memor{}.", if n == 1 { "y" } else { "ies" }),
                }
            }
            Err(e) => RecallResult {
                ok: false,
                entries: vec![],
                message: describe(e),
            },
        }
    }

    async fn memory_brief(
        &self,
        topic: String,
        subject_ref: String,
        max_entries: i64,
    ) -> BriefResult {
        let store = self.store();
        let opts = memory_ops::BriefOptions {
            topic: non_empty(&topic),
            subject_ref: non_empty(&subject_ref),
            max_entries: clamp_u32(max_entries),
        };
        match memory_ops::brief(&store, &opts) {
            Ok(sections) => {
                let text = render_brief_markdown(&sections);
                let total: usize = sections.iter().map(|s| s.entries.len()).sum();
                BriefResult {
                    ok: true,
                    sections: sections.into_iter().map(BriefSectionDto::from).collect(),
                    text,
                    message: format!(
                        "Brief assembled: {total} entr{}.",
                        if total == 1 { "y" } else { "ies" }
                    ),
                }
            }
            Err(e) => BriefResult {
                ok: false,
                sections: vec![],
                text: String::new(),
                message: describe(e),
            },
        }
    }

    async fn confirm_claim(&self, id: String) -> ActionResult {
        let Ok(uuid) = ItemId::parse_str(id.trim()) else {
            return ActionResult {
                ok: false,
                id,
                message: "invalid UUID".into(),
            };
        };
        match memory_ops::confirm(&self.store(), uuid, AUTHOR, ActorKind::System) {
            Ok(n) => ActionResult {
                ok: true,
                id: id.clone(),
                message: format!("Confirmed {id} ({n} total)."),
            },
            Err(e) => ActionResult {
                ok: false,
                id,
                message: describe(e),
            },
        }
    }

    async fn supersede_claim(
        &self,
        old_id: String,
        title: String,
        body: String,
        reason: String,
    ) -> RememberResult {
        let Ok(old_uuid) = ItemId::parse_str(old_id.trim()) else {
            return failed_remember(format!("invalid UUID: {old_id}"));
        };
        let store = self.store();
        match store.get(old_uuid) {
            Ok(Some(_)) => {}
            Ok(None) => return failed_remember(format!("not found: {old_id}")),
            Err(e) => return failed_remember(describe(e)),
        }

        // No gate: a correction is deliberate text the caller already wrote,
        // not a candidate for the dedup heuristic.
        let draft = MemoryDraft::new(MemoryKind::Claim, title, body, AUTHOR, ActorKind::System);
        let new_id = match memory_ops::insert_memory_item(&store, &draft) {
            Ok(id) => id,
            Err(e) => return failed_remember(describe(e)),
        };

        let reason_opt = non_empty(&reason);
        match memory_ops::supersede(
            &store,
            old_uuid,
            new_id,
            reason_opt.as_deref(),
            AUTHOR,
            ActorKind::System,
        ) {
            Ok(()) => RememberResult {
                ok: true,
                action: "inserted".into(),
                claim_id: new_id.to_string(),
                matched_id: old_id,
                // Not a dedup-gate match — `matched_id` here names the OLD
                // claim being superseded, a different relation entirely.
                matched_via: String::new(),
                message: format!("{new_id} supersedes {old_uuid}."),
            },
            // The new claim WAS written even though the supersession edge
            // failed — report the id rather than pretending nothing happened,
            // so the caller can retry recording the edge without re-writing
            // the text.
            Err(e) => RememberResult {
                ok: false,
                action: "inserted".into(),
                claim_id: new_id.to_string(),
                matched_id: old_id,
                matched_via: String::new(),
                message: format!(
                    "inserted {new_id} but failed to record supersession over {old_uuid}: {}",
                    describe(e)
                ),
            },
        }
    }

    async fn forget(&self, id: String) -> ActionResult {
        let Ok(uuid) = ItemId::parse_str(id.trim()) else {
            return ActionResult {
                ok: false,
                id,
                message: "invalid UUID".into(),
            };
        };
        let store = self.store();
        match store.get(uuid) {
            Ok(Some(item)) if MemoryKind::from_schema_ref(&item.schema).is_some() => {
                let outcome = store.apply_operation(OperationSpec {
                    target_id: uuid,
                    op_type: OperationType::SetPayload(NO_RECALL_FIELD.into(), Value::Bool(true)),
                    intent: OperationIntent::Editorial,
                    reason: None,
                    batch_id: None,
                    author: AUTHOR.to_string(),
                    author_kind: ActorKind::System,
                    retention: RetentionTier::Durable,
                });
                match outcome {
                    Ok(_) => ActionResult {
                        ok: true,
                        id: id.clone(),
                        message: format!("Withheld {id} from recall."),
                    },
                    Err(e) => ActionResult {
                        ok: false,
                        id,
                        message: describe(e),
                    },
                }
            }
            Ok(Some(item)) => ActionResult {
                ok: false,
                id: id.clone(),
                message: format!("{id} is a '{}' item, not a memory row", item.schema),
            },
            Ok(None) => ActionResult {
                ok: false,
                id: id.clone(),
                message: format!("not found: {id}"),
            },
            Err(e) => ActionResult {
                ok: false,
                id,
                message: describe(e),
            },
        }
    }

    async fn memory_status(&self) -> StatusResult {
        let store = self.store();
        let mut schemas = Vec::with_capacity(3);
        for kind in MemoryKind::all() {
            let schema_ref = kind.schema_ref();
            let heads =
                match memory_ops::claim_heads(&store, schema_ref, memory_ops::MAX_RECALL_LIMIT) {
                    Ok(ids) => ids.len() as u32,
                    Err(e) => return failed_status(describe(e)),
                };
            let total = match store.query_raw(
                "SELECT COUNT(*) FROM items WHERE schema_ref = ?1",
                &[&schema_ref],
                |row| row.get::<_, i64>(0),
            ) {
                Ok(counts) => counts.first().copied().unwrap_or(0).max(0) as u32,
                Err(e) => return failed_status(describe(e)),
            };
            schemas.push(SchemaCountDto {
                schema_ref: schema_ref.to_string(),
                heads,
                total,
            });
        }
        let total_items: u32 = schemas.iter().map(|s| s.total).sum();
        let (vector_tier, embedding_coverage) = self.vector_status(total_items);

        StatusResult {
            ok: true,
            schemas,
            embedding_coverage,
            vector_tier,
            message: "Memory kernel status.".into(),
        }
    }
}

/// The vector tier's contribution to `remember` and `recall`. Kept as a
/// separate `impl` block from the trait's own (above) because neither method
/// here is part of `MemoryService` — they are internals the trait methods
/// call into, mirroring how `impress-mcp::tools`'s three semantic-search
/// tools are hand-written functions layered over the SAME
/// `#[impress_service]`-generated inventory rather than trait methods
/// themselves.
impl DefaultMemoryService {
    /// The vector tier's half of `remember`'s dedup gate — reached only when
    /// [`GateOutcome::Insert`] already fired, i.e. the FTS gate found
    /// nothing close enough. `Some(result)` when a semantic near-duplicate
    /// was found, re-checked, and confirmed instead; `None` means "insert as
    /// planned" — the tier is off, the draft had no text to embed, embedding
    /// failed, the sidecar holds no memory-item vectors for this model yet,
    /// or every hit at or above [`VECTOR_CONFIRM_THRESHOLD`] failed the
    /// re-check.
    ///
    /// Walks candidates best-first and re-checks each in turn — the same
    /// discipline `memory_ops::gate_fts` uses and for the identical reason:
    /// a lower-scoring hit that IS a compatible live head must not be
    /// blocked by a higher-scoring one that is superseded, withheld, or a
    /// different `claim_type`.
    fn vector_gate_confirm(
        &self,
        store: &SqliteItemStore,
        draft: &MemoryDraft,
    ) -> Option<RememberResult> {
        let tier = self.vector_tier()?;

        // Mirrors `impel_memory::embed::embeddable_text`'s composition for a
        // memory row (`"{title}\n{body}"`) so the draft's on-the-fly
        // embedding lands in the same comparison space as the STORED
        // vectors, which were embedded the same way.
        let text = format!("{}\n{}", draft.title.trim(), draft.body.trim());
        if text.trim().is_empty() {
            return None;
        }

        let query_vec = match tier.embedder.embed(&text) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "impress-memory-service: vector gate skipped this call: embed failed: {e}"
                );
                return None;
            }
        };

        let model = tier.embedder.model_id();
        let vectors = match tier
            .embedding_store
            .load_vectors_by_type_and_model(MEMORY_ITEM_SOURCE_TYPE, model)
        {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "impress-memory-service: vector gate skipped this call: sidecar read failed: {e}"
                );
                return None;
            }
        };
        if vectors.is_empty() {
            return None;
        }

        let mut scored: Vec<(ItemId, f32)> = vectors
            .iter()
            .filter_map(|v| {
                ItemId::parse_str(&v.source_id).ok().map(|id| {
                    (
                        id,
                        impress_embeddings::cosine_similarity(&query_vec, &v.vector),
                    )
                })
            })
            .collect();
        scored.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.cmp(&b.0))
        });

        // Live heads of this draft's kind — a candidate not in this set is
        // superseded or withheld (`no_recall`), and must never absorb a
        // confirmation for either reason (mirrors `gate_fts`'s own
        // `is_superseded` check).
        let heads: BTreeSet<ItemId> = match memory_ops::claim_heads(
            store,
            draft.kind.schema_ref(),
            memory_ops::MAX_RECALL_LIMIT,
        ) {
            Ok(ids) => ids.into_iter().collect(),
            Err(e) => {
                eprintln!(
                    "impress-memory-service: vector gate skipped this call: head lookup failed: {e}"
                );
                return None;
            }
        };
        let draft_type = draft
            .claim_type
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());

        for (id, similarity) in scored
            .into_iter()
            .take_while(|(_, s)| *s >= VECTOR_CONFIRM_THRESHOLD)
        {
            if !heads.contains(&id) {
                continue;
            }
            let Ok(Some(item)) = store.get(id) else {
                continue;
            };
            let stored_type = match item.payload.get("claim_type") {
                Some(Value::String(s)) if !s.trim().is_empty() => Some(s.as_str()),
                _ => None,
            };
            // Compatible means equal, or either side unset — same rule
            // `gate_fts` applies, for the same reason: a different
            // `claim_type` is never the same memory even at high similarity.
            let compatible = match (draft_type, stored_type) {
                (Some(a), Some(b)) => a == b,
                _ => true,
            };
            if !compatible {
                continue;
            }
            return Some(match memory_ops::confirm(store, id, AUTHOR, ActorKind::System) {
                Ok(n) => RememberResult {
                    ok: true,
                    action: "confirmed".into(),
                    claim_id: id.to_string(),
                    matched_id: id.to_string(),
                    matched_via: "vector".into(),
                    message: format!(
                        "Already known (semantic match, {similarity:.2} similarity); confirmed ({n} total): {id}."
                    ),
                },
                Err(e) => failed_remember(describe(e)),
            });
        }
        None
    }

    /// Re-ranks `entries` — already retrieved, filtered and FTS/recency-
    /// ranked by `memory_ops::recall` — using embedding similarity, when the
    /// vector tier is live. Never widens the retrieved SET: this only
    /// reorders the page `memory_ops::recall` already selected, so the
    /// vector tier composes with the FTS one as a pure re-ranking signal, as
    /// `memory_ops::MemoryCandidate::vector_similarity`'s own doc comment
    /// describes.
    ///
    /// Returns `entries` completely UNCHANGED — same `Vec`, same order, same
    /// scores — whenever the tier is off, the sidecar holds no memory-item
    /// vectors for the resolved model, or embedding the query fails. That is
    /// what makes recall's tier-off behavior and its tier-on-with-an-empty-
    /// sidecar behavior provably IDENTICAL rather than merely
    /// same-order-different-numbers.
    fn rerank_with_vectors(
        &self,
        query: &str,
        entries: Vec<memory_ops::RecallEntry>,
    ) -> Vec<memory_ops::RecallEntry> {
        if entries.is_empty() {
            return entries;
        }
        let Some(tier) = self.vector_tier() else {
            return entries;
        };
        let model = tier.embedder.model_id().to_string();
        let stored = match tier
            .embedding_store
            .load_vectors_by_type_and_model(MEMORY_ITEM_SOURCE_TYPE, &model)
        {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "impress-memory-service: vector recall skipped this call: sidecar read failed: {e}"
                );
                return entries;
            }
        };
        if stored.is_empty() {
            return entries;
        }
        let query_vec = match tier.embedder.embed(query) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "impress-memory-service: vector recall skipped this call: embed failed: {e}"
                );
                return entries;
            }
        };

        let by_id: HashMap<&str, &Vec<f32>> = stored
            .iter()
            .map(|v| (v.source_id.as_str(), &v.vector))
            .collect();

        // `modified_ms` / `now_ms` both pinned to 0 rather than a real clock
        // reading: `recency_decay(0, 0, half_life)` is exactly 1.0 regardless
        // of `half_life`, so it contributes the SAME flat recency bonus to
        // every candidate here and never perturbs their relative order —
        // deliberately, since `entries` is already recency-ranked by
        // `memory_ops::recall` (folded into `fts_score` below) and this
        // pass's only job is layering the vector signal on top of that.
        let candidates: Vec<memory_ops::MemoryCandidate> = entries
            .iter()
            .map(|e| memory_ops::MemoryCandidate {
                id: e.id.clone(),
                fts_score: Some(e.score),
                vector_similarity: by_id
                    .get(e.id.as_str())
                    .map(|v| impress_embeddings::cosine_similarity(&query_vec, v.as_slice())),
                confirmations: 0,
                modified_ms: 0,
                author_kind_human: false,
                confidence: None,
            })
            .collect();
        let ranked = memory_ops::rank_memory_candidates(
            &candidates,
            &memory_ops::MemoryWeights::default(),
            0,
        );

        let mut by_id_entry: HashMap<String, memory_ops::RecallEntry> =
            entries.into_iter().map(|e| (e.id.clone(), e)).collect();
        ranked
            .into_iter()
            .filter_map(|(id, score)| {
                by_id_entry.remove(&id).map(|mut e| {
                    e.score = score;
                    e
                })
            })
            .collect()
    }
}

impress_service_impl! {
    service = MemoryService,
    impl = DefaultMemoryService,
    instance = DefaultMemoryService::new,
    methods = [
        remember(
            kind: String,
            title: String,
            body: String,
            claim_type: String,
            confidence: f64,
            subject_refs: Vec<String>,
            evidence_refs: Vec<String>
        ) -> RememberResult,
        recall(query: String, subject_ref: String, limit: i64, include_superseded: bool) -> RecallResult,
        memory_brief(topic: String, subject_ref: String, max_entries: i64) -> BriefResult,
        confirm_claim(id: String) -> ActionResult,
        supersede_claim(old_id: String, title: String, body: String, reason: String) -> RememberResult,
        forget(id: String) -> ActionResult,
        memory_status() -> StatusResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::schemas::{
        MEMORY_CLAIM_SCHEMA, MEMORY_EPISODE_SCHEMA, MEMORY_INSTRUCTION_SCHEMA,
    };
    use impress_embeddings::StoredVector;
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    fn test_store() -> Arc<SqliteItemStore> {
        Arc::new(SqliteItemStore::open_in_memory().expect("open in-memory store"))
    }

    fn svc() -> DefaultMemoryService {
        DefaultMemoryService::with_store(test_store())
    }

    /// A non-memory item, so `forget`'s kind-check has something real to
    /// refuse.
    fn make_plain_item(store: &SqliteItemStore) -> String {
        use impress_core::item::{Item, Priority, Visibility};
        let now = chrono::Utc::now();
        let item = Item {
            id: uuid::Uuid::new_v4(),
            schema: "manuscript".into(),
            payload: Default::default(),
            created: now,
            modified: now,
            author: "test".into(),
            author_kind: ActorKind::System,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        };
        store.insert(item).expect("insert plain item").to_string()
    }

    // ─── Inventory ───────────────────────────────────────────────────────

    /// Every method must reach the MCP inventory. A missing entry means the
    /// tool silently doesn't exist for agents.
    #[test]
    fn all_methods_registered_in_mcp_inventory() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "memory-service_remember",
            "memory-service_recall",
            "memory-service_memory-brief",
            "memory-service_confirm-claim",
            "memory-service_supersede-claim",
            "memory-service_forget",
            "memory-service_memory-status",
        ] {
            assert!(
                names.contains(&expected),
                "{expected} missing from MCP inventory; have {names:?}"
            );
        }
    }

    #[test]
    fn all_methods_registered_in_cli_inventory() {
        let names: Vec<&str> = CliSubcommand::iter().map(|d| d.name).collect();
        for expected in [
            "remember",
            "recall",
            "memory-brief",
            "confirm-claim",
            "supersede-claim",
            "forget",
            "memory-status",
        ] {
            assert!(
                names.contains(&expected),
                "{expected} missing from CLI inventory; have {names:?}"
            );
        }
    }

    #[test]
    fn descriptions_are_not_the_fallback() {
        for d in McpToolDescriptor::iter() {
            if d.name.starts_with("memory-service_") {
                assert!(
                    !d.description.starts_with("Invoke "),
                    "{} has the fallback description",
                    d.name
                );
            }
        }
    }

    // ─── remember / recall ──────────────────────────────────────────────

    #[tokio::test]
    async fn remember_then_recall_finds_it() {
        let svc = svc();
        let r = svc
            .remember(
                "claim".into(),
                "Flux units".into(),
                "The catalogue flux column is in millijansky.".into(),
                "fact".into(),
                0.9,
                vec![],
                vec![],
            )
            .await;
        assert!(r.ok, "{}", r.message);
        assert_eq!(r.action, "inserted");
        assert!(!r.claim_id.is_empty());
        assert!(r.matched_id.is_empty());

        let found = svc
            .recall("millijansky".into(), String::new(), 0, false)
            .await;
        assert!(found.ok, "{}", found.message);
        assert_eq!(found.entries.len(), 1, "{:?}", found.entries);
        assert_eq!(found.entries[0].id, r.claim_id);
        assert_eq!(found.entries[0].schema_ref, MEMORY_CLAIM_SCHEMA);
        assert_eq!(found.entries[0].claim_type.as_deref(), Some("fact"));
        // The kernel's RecallEntry carries confidence as f32 (rank_memory_candidates'
        // signal type), so a round trip through it loses a little precision —
        // compare with tolerance rather than exact equality.
        let confidence = found.entries[0].confidence.expect("confidence stated");
        assert!((confidence - 0.9).abs() < 1e-6, "{confidence}");
    }

    #[tokio::test]
    async fn remembering_the_same_thing_twice_confirms_the_second_time() {
        let svc = svc();
        let body = "Never open the shared container from a shell.";
        let first = svc
            .remember(
                "instruction".into(),
                "No shell scans".into(),
                body.into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(first.ok, "{}", first.message);
        assert_eq!(first.action, "inserted");

        let second = svc
            .remember(
                "instruction".into(),
                "No shell scans, restated".into(),
                body.into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(second.ok, "{}", second.message);
        assert_eq!(second.action, "confirmed");
        assert_eq!(second.claim_id, first.claim_id);
        assert_eq!(second.matched_id, first.claim_id);
        assert_eq!(second.matched_via, "fts");

        // Only one row exists: recall must not return the same memory twice.
        let found = svc.recall("shell".into(), String::new(), 0, false).await;
        assert_eq!(found.entries.len(), 1, "{:?}", found.entries);
        assert_eq!(found.entries[0].confirmations, 1);
    }

    #[tokio::test]
    async fn an_invalid_kind_fails_loudly() {
        let svc = svc();
        let r = svc
            .remember(
                "essay".into(),
                "T".into(),
                "B".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(!r.ok);
        assert!(r.message.contains("claim"), "{}", r.message);
        assert!(r.claim_id.is_empty());
    }

    #[tokio::test]
    async fn recall_narrows_to_a_subject() {
        let svc = svc();
        let store = svc.store();
        let paper = make_plain_item(&store);

        let about = svc
            .remember(
                "claim".into(),
                "About the paper".into(),
                "Calibration detail worth keeping.".into(),
                String::new(),
                -1.0,
                vec![paper.clone()],
                vec![],
            )
            .await;
        assert!(about.ok, "{}", about.message);
        let unrelated = svc
            .remember(
                "claim".into(),
                "Unrelated".into(),
                "Calibration detail about something else.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(unrelated.ok, "{}", unrelated.message);

        let scoped = svc
            .recall("calibration".into(), paper.clone(), 0, false)
            .await;
        assert!(scoped.ok, "{}", scoped.message);
        let ids: Vec<&str> = scoped.entries.iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, vec![about.claim_id.as_str()]);
    }

    // ─── confirm / supersede / forget ───────────────────────────────────

    #[tokio::test]
    async fn confirm_claim_bumps_the_count() {
        let svc = svc();
        let r = svc
            .remember(
                "claim".into(),
                "Fact".into(),
                "Still true.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(r.ok, "{}", r.message);

        let c1 = svc.confirm_claim(r.claim_id.clone()).await;
        assert!(c1.ok, "{}", c1.message);
        let c2 = svc.confirm_claim(r.claim_id.clone()).await;
        assert!(c2.ok, "{}", c2.message);
        assert!(c2.message.contains('2'), "{}", c2.message);
    }

    #[tokio::test]
    async fn supersede_claim_retracts_the_old_row_without_deleting_it() {
        let svc = svc();
        let old = svc
            .remember(
                "claim".into(),
                "Old".into(),
                "Flux is Jy.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(old.ok, "{}", old.message);

        let replaced = svc
            .supersede_claim(
                old.claim_id.clone(),
                "New".into(),
                "Flux is mJy.".into(),
                "unit corrected against the header".into(),
            )
            .await;
        assert!(replaced.ok, "{}", replaced.message);
        assert_eq!(replaced.action, "inserted");
        assert_ne!(replaced.claim_id, old.claim_id);
        assert_eq!(replaced.matched_id, old.claim_id);

        let found = svc.recall("flux".into(), String::new(), 0, false).await;
        let ids: Vec<&str> = found.entries.iter().map(|e| e.id.as_str()).collect();
        assert!(ids.contains(&replaced.claim_id.as_str()), "{ids:?}");
        assert!(
            !ids.contains(&old.claim_id.as_str()),
            "the superseded claim must not recall by default: {ids:?}"
        );

        // Old row still exists, just retracted — proven by widening the
        // recall rather than by reaching into the store directly.
        let widened = svc.recall("flux".into(), String::new(), 0, true).await;
        let widened_ids: Vec<&str> = widened.entries.iter().map(|e| e.id.as_str()).collect();
        assert!(
            widened_ids.contains(&old.claim_id.as_str()),
            "{widened_ids:?}"
        );
    }

    #[tokio::test]
    async fn supersede_claim_fails_loudly_on_a_missing_old_id() {
        let svc = svc();
        let bad = svc
            .supersede_claim(
                uuid::Uuid::new_v4().to_string(),
                "T".into(),
                "B".into(),
                String::new(),
            )
            .await;
        assert!(!bad.ok);
        assert!(bad.message.contains("not found"), "{}", bad.message);
        // Nothing orphaned: no claim id was minted for a supersession that
        // never happened.
        assert!(bad.claim_id.is_empty());
    }

    #[tokio::test]
    async fn forget_hides_a_memory_from_recall_without_deleting_it() {
        let svc = svc();
        let r = svc
            .remember(
                "claim".into(),
                "Aperture radius".into(),
                "Aperture radius is five pixels.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(r.ok, "{}", r.message);

        let before = svc.recall("aperture".into(), String::new(), 0, false).await;
        assert_eq!(before.entries.len(), 1);

        let forgotten = svc.forget(r.claim_id.clone()).await;
        assert!(forgotten.ok, "{}", forgotten.message);

        let after = svc.recall("aperture".into(), String::new(), 0, false).await;
        assert!(after.entries.is_empty(), "{:?}", after.entries);

        // Unlike supersession, forget is never lifted by include_superseded.
        let widened = svc.recall("aperture".into(), String::new(), 0, true).await;
        assert!(widened.entries.is_empty(), "{:?}", widened.entries);
    }

    #[tokio::test]
    async fn forget_refuses_a_non_memory_item() {
        let svc = svc();
        let store = svc.store();
        let plain = make_plain_item(&store);

        let r = svc.forget(plain.clone()).await;
        assert!(!r.ok);
        assert!(r.message.contains("not a memory row"), "{}", r.message);
    }

    #[tokio::test]
    async fn bad_ids_fail_loudly_rather_than_silently() {
        let svc = svc();
        let malformed = svc.confirm_claim("not-a-uuid".into()).await;
        assert!(!malformed.ok);

        let missing = svc.forget(uuid::Uuid::new_v4().to_string()).await;
        assert!(!missing.ok);
        assert!(missing.message.contains("not found"), "{}", missing.message);
    }

    // ─── memory_brief ────────────────────────────────────────────────────

    #[tokio::test]
    async fn brief_text_contains_an_inserted_instruction() {
        let svc = svc();
        let r = svc
            .remember(
                "instruction".into(),
                "No shell scans".into(),
                "Never scan the shared container from a shell.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(r.ok, "{}", r.message);

        let brief = svc.memory_brief(String::new(), String::new(), 0).await;
        assert!(brief.ok, "{}", brief.message);
        assert_eq!(brief.sections.len(), 3);
        assert!(brief.text.contains("### Instructions"), "{}", brief.text);
        assert!(brief.text.contains("No shell scans"), "{}", brief.text);
        assert!(
            brief
                .text
                .contains(&format!("[impress-item:{}]", r.claim_id)),
            "{}",
            brief.text
        );
        // Nothing was written to claims or episodes, so those headings must
        // not appear — the whole point of skipping empty sections in prose.
        assert!(!brief.text.contains("### Claims"), "{}", brief.text);
        assert!(!brief.text.contains("### Episodes"), "{}", brief.text);
    }

    #[tokio::test]
    async fn brief_scopes_claims_by_topic_but_not_instructions() {
        let svc = svc();
        svc.remember(
            "instruction".into(),
            "No shell scans".into(),
            "Never scan the shared container from a shell.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        )
        .await;
        svc.remember(
            "claim".into(),
            "Flux units".into(),
            "The catalogue flux column is in millijansky.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        )
        .await;
        svc.remember(
            "claim".into(),
            "Build flags".into(),
            "Debug builds link the skinny frameworks.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        )
        .await;

        let brief = svc.memory_brief("flux".into(), String::new(), 0).await;
        assert!(brief.ok, "{}", brief.message);
        assert!(
            brief.text.contains("No shell scans"),
            "an instruction ignores topic: {}",
            brief.text
        );
        assert!(brief.text.contains("Flux units"), "{}", brief.text);
        assert!(!brief.text.contains("Build flags"), "{}", brief.text);
    }

    // ─── memory_status ───────────────────────────────────────────────────

    #[tokio::test]
    async fn memory_status_counts_heads_and_totals_per_schema() {
        let svc = svc();
        svc.remember(
            "claim".into(),
            "A".into(),
            "Body A about widgets.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        )
        .await;
        svc.remember(
            "claim".into(),
            "B".into(),
            "Body B is unrelated to gadgets.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        )
        .await;
        svc.remember(
            "episode".into(),
            "E".into(),
            "Something happened during the run.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        )
        .await;

        let status = svc.memory_status().await;
        assert!(status.ok, "{}", status.message);
        assert_eq!(status.schemas.len(), 3);
        assert_eq!(status.embedding_coverage, 0.0);
        // `svc()` sets no vector-tier override and this test never touches
        // IMPRESS_MEMORY_VECTORS, so the tier is off — the cheapest of the
        // four `vector_tier` states (see `DefaultMemoryService::vector_status`).
        assert!(status.vector_tier.contains("off"), "{}", status.vector_tier);

        let claim_row = status
            .schemas
            .iter()
            .find(|s| s.schema_ref == MEMORY_CLAIM_SCHEMA)
            .expect("claim row");
        assert_eq!(claim_row.heads, 2);
        assert_eq!(claim_row.total, 2);

        let episode_row = status
            .schemas
            .iter()
            .find(|s| s.schema_ref == MEMORY_EPISODE_SCHEMA)
            .expect("episode row");
        assert_eq!(episode_row.heads, 1);
        assert_eq!(episode_row.total, 1);

        let instruction_row = status
            .schemas
            .iter()
            .find(|s| s.schema_ref == MEMORY_INSTRUCTION_SCHEMA)
            .expect("instruction row");
        assert_eq!(instruction_row.heads, 0);
        assert_eq!(instruction_row.total, 0);
    }

    #[tokio::test]
    async fn memory_status_total_counts_a_superseded_row_but_not_its_head() {
        let svc = svc();
        let old = svc
            .remember(
                "claim".into(),
                "Old".into(),
                "Flux is Jy.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        svc.supersede_claim(
            old.claim_id.clone(),
            "New".into(),
            "Flux is mJy.".into(),
            String::new(),
        )
        .await;

        let status = svc.memory_status().await;
        let claim_row = status
            .schemas
            .iter()
            .find(|s| s.schema_ref == MEMORY_CLAIM_SCHEMA)
            .expect("claim row");
        assert_eq!(claim_row.total, 2, "old + new both exist");
        assert_eq!(claim_row.heads, 1, "only the replacement is a head");
    }

    // ─── Vector tier (ADR-0028 D6) ──────────────────────────────────────
    //
    // No test below constructs a `SemanticSearch` — that downloads a
    // ~100MB ONNX model on first use, which has no place in a unit test.
    // `StubEmbedder` is the deterministic seam `vector_gate_confirm` /
    // `rerank_with_vectors` / `vector_status` are written against.
    //
    // None of these tests touch `IMPRESS_MEMORY_VECTORS` or any other env
    // var: `DefaultMemoryService::with_store_and_vector_tier` bypasses the
    // env gate and the process-wide `VECTOR_TIER` singleton entirely, so a
    // test below can never race an env-driven default-off test above
    // regardless of `cargo test`'s thread interleaving — deliberately, so
    // this module needs no `--test-threads=1`.

    /// A deterministic stand-in for `SemanticSearch`: exact input strings
    /// map to fixed vectors via a lookup table (`with`), with a
    /// caller-chosen default for anything not listed. This gives tests full
    /// control over cosine similarity without reasoning about what a real
    /// model would produce.
    struct StubEmbedder {
        model: String,
        vectors: HashMap<String, Vec<f32>>,
        default_vector: Vec<f32>,
    }

    impl StubEmbedder {
        fn new(model: &str) -> Self {
            Self {
                model: model.to_string(),
                vectors: HashMap::new(),
                // Orthogonal to every explicit test vector used below, and
                // never itself at or above VECTOR_CONFIRM_THRESHOLD against
                // them — so a text nobody bothered to map never
                // accidentally satisfies a similarity assertion.
                default_vector: vec![0.0, 0.0, 1.0],
            }
        }

        fn with(mut self, text: impl Into<String>, vector: Vec<f32>) -> Self {
            self.vectors.insert(text.into(), vector);
            self
        }
    }

    impl Embedder for StubEmbedder {
        fn embed(&self, text: &str) -> Result<Vec<f32>, String> {
            Ok(self
                .vectors
                .get(text)
                .cloned()
                .unwrap_or_else(|| self.default_vector.clone()))
        }

        fn model_id(&self) -> &str {
            &self.model
        }
    }

    /// A fresh temp-file sidecar path. The `TempDir` must be kept alive by
    /// the caller for as long as the path is used — dropping it deletes the
    /// directory.
    fn temp_sidecar_path() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir
            .path()
            .join("embeddings.sqlite")
            .to_string_lossy()
            .into_owned();
        (dir, path)
    }

    /// Write one memory-item vector directly into the sidecar at `path`,
    /// bypassing `remember` entirely — this is what a real backfill
    /// executor (`impel_memory::EmbedBackfillExecutor`) would already have
    /// done by the time these tests' scenarios begin. Opens its own
    /// `EmbeddingStore` handle, independent of whatever handle a
    /// `DefaultMemoryService` under test holds on the same path — safe,
    /// since `EmbeddingStore::open` sets WAL mode, which serves multiple
    /// connections to one file.
    fn seed_vector(path: &str, source_id: &str, model: &str, vector: Vec<f32>) {
        let store = EmbeddingStore::open(path).expect("open sidecar to seed");
        store
            .save_vectors(&[StoredVector {
                id: uuid::Uuid::new_v4().to_string(),
                source_id: source_id.to_string(),
                source_type: MEMORY_ITEM_SOURCE_TYPE.to_string(),
                vector,
                model: model.to_string(),
                created_at: "2026-01-01T00:00:00Z".into(),
            }])
            .expect("seed vector");
    }

    /// A service with its own fresh in-memory item store and a vector tier
    /// unconditionally live against the sidecar at `path`.
    fn svc_with_vectors(path: &str, embedder: StubEmbedder) -> DefaultMemoryService {
        let embedding_store = EmbeddingStore::open(path).expect("open sidecar for service");
        DefaultMemoryService::with_store_and_vector_tier(test_store(), embedding_store, embedder)
    }

    // -- remember: the vector half of the dedup gate -------------------

    #[tokio::test]
    async fn vector_confirm_matches_a_paraphrase_fts_misses() {
        let (_dir, path) = temp_sidecar_path();
        let model = "stub/v1";
        let title2 = "Currency exchange note";
        let body2 = "Exchange rates fluctuate throughout the trading day session.";
        let text2 = format!("{title2}\n{body2}");

        let embedder = StubEmbedder::new(model).with(text2.clone(), vec![1.0, 0.0, 0.0]);
        let svc = svc_with_vectors(&path, embedder);

        // First insert: the tier is live from the start, but the sidecar is
        // still empty, so this is a plain insert regardless.
        let first = svc
            .remember(
                "claim".into(),
                "Flux units".into(),
                "The catalogue flux column is in millijansky.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(first.ok, "{}", first.message);
        assert_eq!(first.action, "inserted");

        seed_vector(&path, &first.claim_id, model, vec![1.0, 0.0, 0.0]);

        // A paraphrase in completely different words — the FTS gate's token
        // overlap misses it entirely — but the stub embeds `text2` to the
        // SAME vector as the one just seeded, so the vector gate must catch
        // it.
        let second = svc
            .remember(
                "claim".into(),
                title2.into(),
                body2.into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(second.ok, "{}", second.message);
        assert_eq!(second.action, "confirmed", "{second:?}");
        assert_eq!(second.claim_id, first.claim_id);
        assert_eq!(second.matched_id, first.claim_id);
        assert_eq!(second.matched_via, "vector");
    }

    #[tokio::test]
    async fn vector_confirm_falls_through_when_candidate_is_superseded() {
        let (_dir, path) = temp_sidecar_path();
        let model = "stub/v1";
        let title2 = "New topic altogether";
        let body2 = "Something entirely unrelated to the earlier note.";
        let text2 = format!("{title2}\n{body2}");

        let embedder = StubEmbedder::new(model).with(text2.clone(), vec![1.0, 0.0, 0.0]);
        let svc = svc_with_vectors(&path, embedder);

        let old = svc
            .remember(
                "claim".into(),
                "Old topic".into(),
                "A statement that will later be superseded.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(old.ok, "{}", old.message);

        let replacement = svc
            .supersede_claim(
                old.claim_id.clone(),
                "New version".into(),
                "A corrected statement, worded very differently from the note above.".into(),
                String::new(),
            )
            .await;
        assert!(replacement.ok, "{}", replacement.message);

        // The vector points at the OLD, now-superseded row.
        seed_vector(&path, &old.claim_id, model, vec![1.0, 0.0, 0.0]);

        let third = svc
            .remember(
                "claim".into(),
                title2.into(),
                body2.into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(third.ok, "{}", third.message);
        assert_eq!(third.action, "inserted", "{third:?}");
        assert_ne!(third.claim_id, old.claim_id);
        assert_ne!(third.claim_id, replacement.claim_id);
        assert_eq!(third.matched_via, "");
    }

    #[tokio::test]
    async fn vector_confirm_falls_through_when_candidate_is_forgotten() {
        let (_dir, path) = temp_sidecar_path();
        let model = "stub/v1";
        let title2 = "Yet another topic";
        let body2 = "Completely different wording from the forgotten note.";
        let text2 = format!("{title2}\n{body2}");

        let embedder = StubEmbedder::new(model).with(text2.clone(), vec![1.0, 0.0, 0.0]);
        let svc = svc_with_vectors(&path, embedder);

        let original = svc
            .remember(
                "claim".into(),
                "Private note".into(),
                "A claim that will be withheld from recall.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(original.ok, "{}", original.message);

        let forgotten = svc.forget(original.claim_id.clone()).await;
        assert!(forgotten.ok, "{}", forgotten.message);

        seed_vector(&path, &original.claim_id, model, vec![1.0, 0.0, 0.0]);

        let third = svc
            .remember(
                "claim".into(),
                title2.into(),
                body2.into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(third.ok, "{}", third.message);
        assert_eq!(third.action, "inserted", "{third:?}");
        assert_eq!(third.matched_via, "");
    }

    #[tokio::test]
    async fn vector_confirm_falls_through_on_claim_type_mismatch() {
        let (_dir, path) = temp_sidecar_path();
        let model = "stub/v1";
        let title2 = "A preference, not a fact";
        let body2 = "Worded nothing like the fact claim below, on purpose.";
        let text2 = format!("{title2}\n{body2}");

        let embedder = StubEmbedder::new(model).with(text2.clone(), vec![1.0, 0.0, 0.0]);
        let svc = svc_with_vectors(&path, embedder);

        let fact = svc
            .remember(
                "claim".into(),
                "A fact".into(),
                "Water boils at 100 degrees Celsius at sea level.".into(),
                "fact".into(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(fact.ok, "{}", fact.message);

        seed_vector(&path, &fact.claim_id, model, vec![1.0, 0.0, 0.0]);

        let preference = svc
            .remember(
                "claim".into(),
                title2.into(),
                body2.into(),
                "preference".into(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(preference.ok, "{}", preference.message);
        assert_eq!(preference.action, "inserted", "{preference:?}");
        assert_ne!(preference.claim_id, fact.claim_id);
        assert_eq!(preference.matched_via, "");
    }

    // -- recall: vector re-ranking --------------------------------------

    #[tokio::test]
    async fn recall_ranking_uses_vector_similarity() {
        let (_dir, path) = temp_sidecar_path();
        let model = "stub/v1";
        // The query text ("") embeds to something identical to claim A's
        // stored vector and orthogonal to claim B's.
        let embedder = StubEmbedder::new(model).with(String::new(), vec![1.0, 0.0]);
        let svc = svc_with_vectors(&path, embedder);

        let a = svc
            .remember(
                "claim".into(),
                "Topic A".into(),
                "Alpha alpha alpha content, first claim.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(a.ok, "{}", a.message);
        let b = svc
            .remember(
                "claim".into(),
                "Topic B".into(),
                "Beta beta beta content, second claim entirely.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(b.ok, "{}", b.message);

        seed_vector(&path, &a.claim_id, model, vec![1.0, 0.0]);
        seed_vector(&path, &b.claim_id, model, vec![0.0, 1.0]);

        let recalled = svc.recall(String::new(), String::new(), 0, false).await;
        assert!(recalled.ok, "{}", recalled.message);
        assert_eq!(recalled.entries.len(), 2, "{:?}", recalled.entries);
        assert_eq!(
            recalled.entries[0].id, a.claim_id,
            "the vector-nearer claim must rank first: {:?}",
            recalled.entries
        );
    }

    #[tokio::test]
    async fn recall_identical_tier_off_vs_tier_on_with_empty_sidecar() {
        let store = test_store();
        let svc_off = DefaultMemoryService::with_store(store.clone());

        svc_off
            .remember(
                "claim".into(),
                "First".into(),
                "The first seeded claim about widgets.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        svc_off
            .remember(
                "claim".into(),
                "Second".into(),
                "The second seeded claim about gadgets.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        svc_off
            .remember(
                "episode".into(),
                "Third".into(),
                "An episode about the same widgets.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;

        let off_result = svc_off
            .recall("widgets".into(), String::new(), 0, false)
            .await;
        assert!(off_result.ok, "{}", off_result.message);
        assert!(!off_result.entries.is_empty(), "{:?}", off_result.entries);

        // Tier ON, but the sidecar is (and stays) completely empty — no
        // `seed_vector` call at all.
        let (_dir, path) = temp_sidecar_path();
        let embedding_store = EmbeddingStore::open(&path).expect("open empty sidecar");
        let svc_on = DefaultMemoryService::with_store_and_vector_tier(
            store.clone(),
            embedding_store,
            StubEmbedder::new("stub/v1"),
        );
        let on_result = svc_on
            .recall("widgets".into(), String::new(), 0, false)
            .await;
        assert!(on_result.ok, "{}", on_result.message);

        let off_ids: Vec<&str> = off_result.entries.iter().map(|e| e.id.as_str()).collect();
        let on_ids: Vec<&str> = on_result.entries.iter().map(|e| e.id.as_str()).collect();
        assert_eq!(
            off_ids, on_ids,
            "tier-on with an empty sidecar must not perturb order"
        );
        assert_eq!(off_result.entries.len(), on_result.entries.len());
    }

    // -- memory_status: coverage -----------------------------------------

    #[tokio::test]
    async fn memory_status_reports_vector_coverage_when_tier_live() {
        let (_dir, path) = temp_sidecar_path();
        let model = "stub/v1";
        let svc = svc_with_vectors(&path, StubEmbedder::new(model));

        let a = svc
            .remember(
                "claim".into(),
                "A".into(),
                "First claim, entirely on its own topic.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        let b = svc
            .remember(
                "claim".into(),
                "B".into(),
                "Second claim, a distinctly different topic.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        let c = svc
            .remember(
                "claim".into(),
                "C".into(),
                "Third claim, yet another unrelated topic.".into(),
                String::new(),
                -1.0,
                vec![],
                vec![],
            )
            .await;
        assert!(a.ok && b.ok && c.ok, "{a:?} {b:?} {c:?}");

        // Only two of the three claims have been embedded.
        seed_vector(&path, &a.claim_id, model, vec![1.0, 0.0, 0.0]);
        seed_vector(&path, &b.claim_id, model, vec![0.0, 1.0, 0.0]);

        let status = svc.memory_status().await;
        assert!(status.ok, "{}", status.message);
        assert_eq!(
            status.vector_tier,
            format!("live (model {model}, 2/3 items embedded)")
        );
        assert!(
            (status.embedding_coverage - 2.0 / 3.0).abs() < 1e-9,
            "{}",
            status.embedding_coverage
        );
    }
}
