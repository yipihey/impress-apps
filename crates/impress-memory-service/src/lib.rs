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
//! **FTS tier only.** This crate adds no embedding, no vector index and no
//! `imbib-core` dependency — [`DefaultMemoryService::memory_status`] reports
//! that honestly rather than pretending semantic recall exists. A second
//! (embedding) tier is expected to arrive with the impel-memory backfill; it
//! composes with this one rather than replacing it, per the kernel's own
//! module docs (`memory_ops::MemoryCandidate::vector_similarity`).
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

use std::sync::Arc;

use impress_core::item::{ActorKind, ItemId, Value};
use impress_core::memory_ops::{self, GateOutcome, MemoryDraft, MemoryKind};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
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
    /// Fraction of memory rows with an embedding. Always `0.0` today — see
    /// `vector_tier`.
    pub embedding_coverage: f64,
    /// Honest placeholder: this server runs the FTS tier only. A future
    /// embedding backfill adds a second retrieval signal
    /// (`memory_ops::MemoryCandidate::vector_similarity`) without replacing
    /// this one.
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
/// This is the FTS tier only: full-text retrieval, a token-overlap dedup
/// gate, and a deterministic ranker over relevance, confirmations, recency,
/// author and confidence. No embeddings — see `memory_status`.
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
    /// worth building. `vector_tier` and `embedding_coverage` are honest
    /// placeholders: this server is FTS-only today.
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

/// Store-backed `MemoryService`. `new()` uses the shared store (opened
/// lazily); `with_store` takes an explicit one, as the tests do.
#[derive(Clone, Default)]
pub struct DefaultMemoryService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultMemoryService {
    pub fn new() -> Self {
        Self { store: None }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store
            .clone()
            .unwrap_or_else(impress_store_service::store::store_instance)
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
            GateOutcome::Insert => match memory_ops::insert_memory_item(&store, &draft) {
                Ok(id) => RememberResult {
                    ok: true,
                    action: "inserted".into(),
                    claim_id: id.to_string(),
                    matched_id: String::new(),
                    message: format!("Remembered as a new {kind}: {id}."),
                },
                Err(e) => failed_remember(describe(e)),
            },
            GateOutcome::Confirm(existing) => {
                match memory_ops::confirm(&store, existing, AUTHOR, ActorKind::System) {
                    Ok(n) => RememberResult {
                        ok: true,
                        action: "confirmed".into(),
                        claim_id: existing.to_string(),
                        matched_id: existing.to_string(),
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
        StatusResult {
            ok: true,
            schemas,
            embedding_coverage: 0.0,
            vector_tier:
                "unavailable (FTS tier only; embeddings arrive with the impel-memory backfill)"
                    .into(),
            message: "Memory kernel status (FTS tier).".into(),
        }
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
        assert!(
            status.vector_tier.contains("unavailable"),
            "{}",
            status.vector_tier
        );

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
}
