//! `impel-throughline` — the ADR-0016 sync pipeline: manuscript-section
//! drift spawns `throughline-sync` tasks whose executor drafts proposals
//! and opens `review-request@1.0.0` checkpoints. Nothing auto-commits
//! (ADR-0016 D6): the ledger and document content move only on an
//! `"approved"` resolution, through attributed operation items.
//!
//! Opt-in invariant (ADR-0016 D1): the spawn rule's FIRST act is a single
//! keyed `get_item` on the deterministic throughline id — documents
//! without a throughline spawn zero tasks and do zero further work.
//!
//! Layering: all store access goes through `TaskStoreApi` (the kernel
//! boundary, ADR-0015 D5) using the deterministic UUID-v5 ids shared with
//! `imprint-service`; the pure domain logic (anchor map, extraction,
//! derivation) is imported from `imprint_service::throughline` — the
//! canonical implementation (ADR-0016 D4).

use std::collections::BTreeMap;
use std::time::Instant;

use async_trait::async_trait;
use impel_core::{
    AgentRunRecord, ExecutionOutcome, ReviewRequest, SpawnError, SpawnRule, TaskError,
    TaskExecutor, TaskSpec, TaskStoreApi,
};
use impress_core::item::{ActorKind, Item, ItemId, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::reference::EdgeType;
use imprint_service::throughline::{
    derive_anchor_states, extract_paragraphs, AnchorAssessment, AnchorMap, ThroughlineParagraph,
    ThroughlineStore,
};
use imprint_service::{BlobStore, SectionRecord};
use uuid::Uuid;

/// Task kind handled by [`ThroughlineSyncExecutor`].
pub const KIND_THROUGHLINE_SYNC: &str = "throughline-sync";

/// Schema whose mutations trigger the spawn rule.
pub const MANUSCRIPT_SECTION_SCHEMA: &str = "manuscript-section";

/// Actor id for all writes from this pipeline.
const ACTOR: &str = "impel/throughline-sync";

// ---------------------------------------------------------------------------
// Store-side views (via TaskStoreApi, deterministic ids)
// ---------------------------------------------------------------------------

/// Read the throughline item for a document, if it has one. One keyed get —
/// this is the D1 opt-in check.
fn throughline_item(
    store: &dyn TaskStoreApi,
    document_id: Uuid,
) -> Result<Option<Item>, TaskError> {
    Ok(store.get_item(ThroughlineStore::item_id(document_id))?)
}

fn payload_str<'a>(item: &'a Item, key: &str) -> Option<&'a str> {
    match item.payload.get(key) {
        Some(Value::String(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// Parse the throughline item's ledger + source.
fn throughline_state(item: &Item) -> Result<(AnchorMap, String), TaskError> {
    let source = payload_str(item, "body_content").unwrap_or_default().to_string();
    let map = match payload_str(item, "anchor_map_json") {
        Some(json) => AnchorMap::parse(json)
            .map_err(|e| TaskError::Permanent(format!("corrupt anchor map: {e}")))?,
        None => {
            return Err(TaskError::Permanent(
                "throughline item has no anchor_map_json".into(),
            ))
        }
    };
    Ok((map, source))
}

/// Load the sections referenced by the ledger (deterministic UUID-v5 ids —
/// no store scan). Sections whose item is missing are simply absent, which
/// the derivation reports as `broken`.
///
/// CAS-offloaded bodies (>64 KiB) carry `content_hash` but an empty inline
/// `body`; staleness comparison still works (the hash IS the comparison
/// key), and proposals for such sections include the hash, not the text.
fn ledger_sections(
    store: &dyn TaskStoreApi,
    document_id: Uuid,
    map: &AnchorMap,
) -> Result<Vec<SectionRecord>, TaskError> {
    let mut keys: Vec<&String> = map
        .anchors
        .values()
        .flat_map(|e| e.section_keys.iter())
        .collect();
    keys.sort();
    keys.dedup();

    let mut out = Vec::new();
    for key in keys {
        let id = imprint_service::SectionStore::item_id(document_id, key);
        if let Some(item) = store.get_item(id)? {
            let body = payload_str(&item, "body").unwrap_or_default().to_string();
            let content_hash = payload_str(&item, "content_hash").map(String::from);
            out.push(SectionRecord {
                item_id: id,
                document_id,
                section_key: key.clone(),
                title: payload_str(&item, "title").unwrap_or_default().to_string(),
                body,
                section_type: payload_str(&item, "section_type").map(String::from),
                order_index: match item.payload.get("order_index") {
                    Some(Value::Int(i)) => Some(*i),
                    _ => None,
                },
                word_count: match item.payload.get("word_count") {
                    Some(Value::Int(i)) => *i,
                    _ => 0,
                },
                content_hash,
                created_ms: 0,
            });
        }
    }
    Ok(out)
}

fn section_hash(record: &SectionRecord) -> String {
    imprint_service::throughline::section_body_hash(record)
}

// ---------------------------------------------------------------------------
// Spawn rule
// ---------------------------------------------------------------------------

/// Spawns a `throughline-sync` task when a manuscript section belonging to
/// an opted-in document mutates.
///
/// Dedup note: the rule may spawn while an earlier sync task for the same
/// document is still pending/running. That is safe — the executor re-derives
/// anchor state from the graph on every run and completes immediately when
/// nothing is stale — but it costs a task row. An event-bus-side debounce
/// (quiet period per document) is the planned refinement.
pub struct ThroughlineSpawnRule;

#[async_trait]
impl SpawnRule for ThroughlineSpawnRule {
    fn trigger_schema(&self) -> &str {
        MANUSCRIPT_SECTION_SCHEMA
    }

    async fn spawn(
        &self,
        trigger: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<Vec<TaskSpec>, SpawnError> {
        // Owning document of the mutated section.
        let Some(doc_str) = payload_str(trigger, "document_id") else {
            return Ok(vec![]);
        };
        let Ok(document_id) = doc_str.parse::<Uuid>() else {
            return Ok(vec![]);
        };

        // D1 opt-in gate: one keyed get; non-opted documents stop here.
        let Some(tl_item) = throughline_item(store, document_id)
            .map_err(|e| SpawnError::InvalidSpec(e.to_string()))?
        else {
            return Ok(vec![]);
        };

        // Only spawn when the mutated section is actually anchored and
        // actually drifted — an unanchored section edit is not sync work.
        let Ok((map, source)) = throughline_state(&tl_item) else {
            return Ok(vec![]);
        };
        let Some(section_key) = payload_str(trigger, "section_key") else {
            return Ok(vec![]);
        };
        let anchored = map
            .anchors
            .values()
            .any(|e| e.section_keys.iter().any(|k| k == section_key));
        let sections = ledger_sections(store, document_id, &map)
            .map_err(|e| SpawnError::InvalidSpec(e.to_string()))?;
        let paragraphs = extract_paragraphs(&source);
        let states = derive_anchor_states(&map, &sections, &paragraphs);
        let any_broken = states
            .iter()
            .any(|a| !a.broken.is_empty() || a.missing_paragraph);
        // An edit to an UNANCHORED section is only sync work when an anchor
        // is broken — a heading rename surfaces as (new unanchored key +
        // broken ledger key), and the repair proposal must spawn.
        if !anchored && !any_broken {
            return Ok(vec![]);
        }
        let any_stale = states.iter().any(|a| !a.is_synced());
        if !any_stale {
            return Ok(vec![]);
        }

        Ok(vec![TaskSpec {
            kind: KIND_THROUGHLINE_SYNC.into(),
            description: Some(format!(
                "Propose throughline sync for document {document_id}"
            )),
            depends_on: vec![],
            operates_on: Some(tl_item.id),
            output_schema: None,
        }])
    }
}

// ---------------------------------------------------------------------------
// Proposal drafting
// ---------------------------------------------------------------------------

/// One direction of a sync proposal (ADR-0016 D6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncDirection {
    /// Anchored manuscript content changed → propose an updated paragraph.
    ManuscriptAhead,
    /// The paragraph changed → propose drafts into the anchored sections.
    ThroughlineAhead,
    /// An anchored section no longer resolves → propose a repair.
    Broken,
}

impl SyncDirection {
    fn as_str(&self) -> &'static str {
        match self {
            SyncDirection::ManuscriptAhead => "manuscript-ahead",
            SyncDirection::ThroughlineAhead => "throughline-ahead",
            SyncDirection::Broken => "broken",
        }
    }
}

/// Drafts proposal text for a stale anchor. The model call lives behind
/// this trait so the kernel pipeline stays LLM-free and tests are
/// deterministic; production wires an LLM-backed drafter whose prompt
/// contract encodes the ADR-0016 D6 authority split verbatim:
///
/// > Claims and narrative order flow from the throughline; evidence,
/// > derivations, and numbers flow from the manuscript. Never strengthen a
/// > claim beyond what the anchored sections support — if the throughline
/// > asserts more than the manuscript shows, say so in the proposal rather
/// > than papering over it.
#[async_trait]
pub trait ProposalDrafter: Send + Sync {
    /// Identifier recorded in the agent-run provenance row.
    fn model_id(&self) -> &str;

    /// Draft the proposed replacement text. `paragraph` is the current
    /// throughline paragraph; `sections` are the anchored sections' current
    /// records. For `ManuscriptAhead` return proposed paragraph text; for
    /// `ThroughlineAhead` return proposed replacement body for EACH section
    /// (keyed by section_key); `Broken` needs no text.
    async fn draft(
        &self,
        direction: &SyncDirection,
        paragraph: &ThroughlineParagraph,
        sections: &[SectionRecord],
    ) -> DraftResult;
}

/// Drafter output.
#[derive(Debug, Clone, Default)]
pub struct DraftResult {
    /// Proposed paragraph text (ManuscriptAhead).
    pub paragraph_text: Option<String>,
    /// Proposed section bodies keyed by section_key (ThroughlineAhead).
    pub section_bodies: BTreeMap<String, String>,
    /// Free-text note shown to the reviewer (e.g. "the throughline claims
    /// X but the anchored sections only show Y").
    pub note: Option<String>,
}

/// Deterministic no-model drafter: proposes the current counterpart text
/// framed for human editing. Keeps the pipeline fully functional (and the
/// checkpoint meaningful) before an LLM drafter is wired: the human sees
/// the drift context and edits the proposal in the review UI.
pub struct TemplateDrafter;

#[async_trait]
impl ProposalDrafter for TemplateDrafter {
    fn model_id(&self) -> &str {
        "template/v1"
    }

    async fn draft(
        &self,
        direction: &SyncDirection,
        paragraph: &ThroughlineParagraph,
        sections: &[SectionRecord],
    ) -> DraftResult {
        match direction {
            SyncDirection::ManuscriptAhead => DraftResult {
                paragraph_text: Some(paragraph.body.clone()),
                section_bodies: BTreeMap::new(),
                note: Some(
                    "Anchored sections changed. Review the sections and update this \
                     paragraph to keep the story truthful to the evidence."
                        .into(),
                ),
            },
            SyncDirection::ThroughlineAhead => DraftResult {
                paragraph_text: None,
                section_bodies: sections
                    .iter()
                    .map(|s| (s.section_key.clone(), s.body.clone()))
                    .collect(),
                note: Some(
                    "The narrative changed. Draft the corresponding manuscript edits; \
                     evidence, derivations, and numbers remain manuscript-authoritative."
                        .into(),
                ),
            },
            SyncDirection::Broken => DraftResult {
                paragraph_text: None,
                section_bodies: BTreeMap::new(),
                note: Some(
                    "An anchored section no longer resolves (heading renamed or \
                     removed). Rebind the anchor or drop it."
                        .into(),
                ),
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Executes `throughline-sync` tasks: derives anchor states, opens one
/// review per stale anchor (loop-until-dry across suspensions), and applies
/// accepted proposals as attributed operations with a stale-proposal guard.
pub struct ThroughlineSyncExecutor {
    drafter: Box<dyn ProposalDrafter>,
}

impl ThroughlineSyncExecutor {
    pub fn new(drafter: Box<dyn ProposalDrafter>) -> Self {
        Self { drafter }
    }

    fn target_throughline(
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<Item, TaskError> {
        let target = task
            .references
            .iter()
            .find(|r| r.edge_type == EdgeType::OperatesOn)
            .map(|r| r.target)
            .ok_or_else(|| TaskError::Permanent("task has no OperatesOn target".into()))?;
        store
            .get_item(target)?
            .ok_or_else(|| TaskError::Permanent(format!("throughline item {target} missing")))
    }

    fn document_id(tl_item: &Item) -> Result<Uuid, TaskError> {
        payload_str(tl_item, "document_ref")
            .and_then(|s| s.parse::<Uuid>().ok())
            .ok_or_else(|| TaskError::Permanent("throughline item has no document_ref".into()))
    }

    /// First stale anchor without an already-open review, in label order.
    fn first_stale(assessments: &[AnchorAssessment]) -> Option<&AnchorAssessment> {
        assessments.iter().find(|a| !a.is_synced())
    }

    /// Open the review checkpoint for one stale anchor.
    async fn open_proposal_review(
        &self,
        task: &Item,
        tl_item: &Item,
        document_id: Uuid,
        assessment: &AnchorAssessment,
        map: &AnchorMap,
        source: &str,
        sections: &[SectionRecord],
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError> {
        let started = Instant::now();
        let direction = if !assessment.broken.is_empty() || assessment.missing_paragraph {
            SyncDirection::Broken
        } else if assessment.throughline_ahead {
            // When both sides drifted the human sequences the directions;
            // throughline-ahead first keeps claims authoritative (D6).
            SyncDirection::ThroughlineAhead
        } else {
            SyncDirection::ManuscriptAhead
        };

        let paragraphs = extract_paragraphs(source);
        let paragraph = paragraphs
            .iter()
            .find(|p| p.label == assessment.label)
            .cloned()
            .unwrap_or(ThroughlineParagraph {
                label: assessment.label.clone(),
                body: String::new(),
                content_hash: String::new(),
                order_index: 0,
                start: 0,
                end: 0,
            });

        let entry = map.anchors.get(&assessment.label).ok_or_else(|| {
            TaskError::Permanent(format!("no ledger entry for <{}>", assessment.label))
        })?;
        let anchored: Vec<&SectionRecord> = sections
            .iter()
            .filter(|s| entry.section_keys.contains(&s.section_key))
            .collect();
        let anchored_owned: Vec<SectionRecord> = anchored.iter().map(|s| (*s).clone()).collect();

        let draft = self.drafter.draft(&direction, &paragraph, &anchored_owned).await;

        // Provenance row for the drafting run.
        store.record_agent_run(
            task.id,
            AgentRunRecord {
                agent_id: ACTOR.into(),
                model: self.drafter.model_id().into(),
                prompt_hash: BlobStore::sha256_hex(&format!(
                    "{}::{}::{}",
                    document_id, assessment.label, paragraph.content_hash
                )),
                result_summary: Some(format!(
                    "{} proposal for <{}>",
                    direction.as_str(),
                    assessment.label
                )),
                token_count: None,
                duration_ms: Some(started.elapsed().as_millis() as i64),
            },
        )?;

        // Expected-state snapshot for the stale-proposal guard at accept.
        let expected_hashes: BTreeMap<String, Value> = anchored
            .iter()
            .map(|s| (s.section_key.clone(), Value::String(section_hash(s))))
            .collect();

        let mut context = BTreeMap::new();
        context.insert("direction".into(), Value::String(direction.as_str().into()));
        context.insert("anchor".into(), Value::String(assessment.label.clone()));
        context.insert(
            "document_id".into(),
            Value::String(document_id.to_string()),
        );
        context.insert(
            "expected_section_hashes".into(),
            Value::Object(expected_hashes),
        );
        context.insert(
            "expected_throughline_hash".into(),
            Value::String(paragraph.content_hash.clone()),
        );
        if let Some(text) = &draft.paragraph_text {
            context.insert("proposed_paragraph".into(), Value::String(text.clone()));
        }
        if !draft.section_bodies.is_empty() {
            context.insert(
                "proposed_section_bodies".into(),
                Value::Object(
                    draft
                        .section_bodies
                        .iter()
                        .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                        .collect(),
                ),
            );
        }
        if let Some(note) = &draft.note {
            context.insert("note".into(), Value::String(note.clone()));
        }
        if direction == SyncDirection::Broken {
            if let Some(first_broken) = assessment.broken.first() {
                context.insert("broken_key".into(), Value::String(first_broken.clone()));
            }
        }
        context.insert(
            "current_paragraph".into(),
            Value::String(paragraph.body.clone()),
        );

        store.open_review(
            task.id,
            ReviewRequest {
                question: format!(
                    "Throughline sync (<{}>, {}): apply the proposed {}?",
                    assessment.label,
                    direction.as_str(),
                    match direction {
                        SyncDirection::ManuscriptAhead => "paragraph update",
                        SyncDirection::ThroughlineAhead => "manuscript edits",
                        SyncDirection::Broken => "anchor repair",
                    }
                ),
                context: Some(context),
            },
            ACTOR,
        )?;
        let _ = tl_item;
        Ok(())
    }

    /// Apply an approved proposal. Stale-guard first: if the graph moved
    /// since the proposal was computed, apply nothing — the spawn rule
    /// fires again on the next mutation and a fresh proposal is computed.
    /// Returns whether anything was applied.
    fn apply_approved(
        &self,
        review: &Item,
        tl_item: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<bool, TaskError> {
        let label = match review.payload.get("context_anchor") {
            Some(Value::String(s)) => s.clone(),
            _ => return Ok(false),
        };
        let document_id = Self::document_id(tl_item)?;
        let (mut map, source) = throughline_state(tl_item)?;
        let sections = ledger_sections(store, document_id, &map)?;

        // ── Stale-proposal guard (ADR-0016 D9) ─────────────────────────
        if let Some(Value::Object(expected)) = review.payload.get("context_expected_section_hashes")
        {
            for (key, expected_hash) in expected {
                let current = sections
                    .iter()
                    .find(|s| &s.section_key == key)
                    .map(section_hash);
                let expected_str = match expected_hash {
                    Value::String(s) => Some(s.as_str()),
                    _ => None,
                };
                if current.as_deref() != expected_str {
                    return Ok(false); // invalidated — never force-apply
                }
            }
        }
        let paragraphs = extract_paragraphs(&source);
        let current_paragraph = paragraphs.iter().find(|p| p.label == label);
        if let Some(Value::String(expected)) = review.payload.get("context_expected_throughline_hash")
        {
            let current_hash = current_paragraph.map(|p| p.content_hash.as_str());
            if !expected.is_empty() && current_hash != Some(expected.as_str()) {
                return Ok(false);
            }
        }

        let direction = match review.payload.get("context_direction") {
            Some(Value::String(s)) => s.clone(),
            _ => return Ok(false),
        };
        let mut applied = false;

        match direction.as_str() {
            "manuscript-ahead" => {
                // Replace the paragraph body in the throughline source.
                if let (Some(Value::String(proposed)), Some(p)) = (
                    review.payload.get("context_proposed_paragraph"),
                    current_paragraph,
                ) {
                    let token = format!("<{}>", p.label);
                    let new_run = format!("{} {}", proposed.trim(), token);
                    let mut new_source = source.clone();
                    new_source.replace_range(p.start..p.end, &new_run);
                    self.write_throughline(
                        tl_item.id,
                        &new_source,
                        &mut map,
                        &label,
                        &sections,
                        store,
                    )?;
                    applied = true;
                }
            }
            "throughline-ahead" => {
                // Write proposed bodies into the anchored section items.
                if let Some(Value::Object(bodies)) =
                    review.payload.get("context_proposed_section_bodies")
                {
                    let mut updated_sections = sections.clone();
                    for (key, body) in bodies {
                        let Value::String(body) = body else { continue };
                        // The ledger must record the hash of the NEW body,
                        // so mirror the patch into the section snapshot
                        // that write_throughline hashes below.
                        if let Some(s) =
                            updated_sections.iter_mut().find(|s| &s.section_key == key)
                        {
                            s.body = body.clone();
                            s.content_hash = None;
                        }
                        let section_id =
                            imprint_service::SectionStore::item_id(document_id, key);
                        store.apply(OperationSpec {
                            target_id: section_id,
                            op_type: OperationType::PatchPayload({
                                let mut m = BTreeMap::new();
                                m.insert("body".into(), Value::String(body.clone()));
                                m.insert(
                                    "word_count".into(),
                                    Value::Int(
                                        body.split_whitespace().count() as i64,
                                    ),
                                );
                                m
                            }),
                            intent: OperationIntent::Editorial,
                            reason: Some(format!("throughline sync: <{label}> approved")),
                            batch_id: None,
                            author: ACTOR.into(),
                            author_kind: ActorKind::Agent,
                            retention: RetentionTier::Durable,
                        })?;
                    }
                    self.write_throughline(
                        tl_item.id, &source, &mut map, &label, &updated_sections, store,
                    )?;
                    applied = true;
                }
            }
            "broken" => {
                // Repair actions ride on the review: the reviewer (or the
                // UI, via imprint-service's repair_candidates) sets
                // context_repair_action = "rebind" (+ context_rebind_to)
                // or "drop". Applied as a ledger edit only.
                let action = match review.payload.get("context_repair_action") {
                    Some(Value::String(s)) => s.clone(),
                    _ => return Ok(false),
                };
                let Some(entry) = map.anchors.get_mut(&label) else {
                    return Ok(false);
                };
                let broken_key = match review.payload.get("context_broken_key") {
                    Some(Value::String(s)) => s.clone(),
                    _ => return Ok(false),
                };
                match action.as_str() {
                    "rebind" => {
                        let Some(Value::String(new_key)) =
                            review.payload.get("context_rebind_to")
                        else {
                            return Ok(false);
                        };
                        // The rebind target must actually resolve.
                        let new_id =
                            imprint_service::SectionStore::item_id(document_id, new_key);
                        if store.get_item(new_id)?.is_none() {
                            return Ok(false);
                        }
                        for key in entry.section_keys.iter_mut() {
                            if key == &broken_key {
                                *key = new_key.clone();
                            }
                        }
                        entry.manuscript_hashes.remove(&broken_key);
                    }
                    "drop" => {
                        entry.section_keys.retain(|k| k != &broken_key);
                        entry.manuscript_hashes.remove(&broken_key);
                        if entry.section_keys.is_empty() {
                            map.anchors.remove(&label);
                        }
                    }
                    _ => return Ok(false),
                }
                // Re-load sections under the repaired ledger so the
                // rebaseline records the rebind target's current hash.
                let repaired_sections = ledger_sections(store, document_id, &map)?;
                self.write_throughline(
                    tl_item.id,
                    &source,
                    &mut map,
                    &label,
                    &repaired_sections,
                    store,
                )?;
                applied = true;
            }
            _ => {}
        }
        Ok(applied)
    }

    /// Rebaseline the ledger for `label` and write the throughline item's
    /// payload — the ONLY ledger write path in this crate, always as an
    /// attributed `PatchPayload` operation (never a raw upsert).
    fn write_throughline(
        &self,
        tl_id: ItemId,
        new_source: &str,
        map: &mut AnchorMap,
        label: &str,
        sections: &[SectionRecord],
        store: &dyn TaskStoreApi,
    ) -> Result<(), TaskError> {
        let paragraphs = extract_paragraphs(new_source);
        if let Some(entry) = map.anchors.get_mut(label) {
            let mut hashes = BTreeMap::new();
            for key in &entry.section_keys {
                if let Some(s) = sections.iter().find(|s| &s.section_key == key) {
                    hashes.insert(key.clone(), section_hash(s));
                }
            }
            entry.manuscript_hashes = hashes;
            if let Some(p) = paragraphs.iter().find(|p| p.label == label) {
                entry.throughline_hash = p.content_hash.clone();
            }
        }
        let map_json = map
            .serialize()
            .map_err(|e| TaskError::Permanent(format!("ledger serialize: {e}")))?;

        let mut patch = BTreeMap::new();
        patch.insert("body_content".into(), Value::String(new_source.to_string()));
        patch.insert("anchor_map_json".into(), Value::String(map_json.clone()));
        patch.insert(
            "content_hash".into(),
            Value::String(BlobStore::sha256_hex(new_source)),
        );
        patch.insert(
            "anchor_map_hash".into(),
            Value::String(BlobStore::sha256_hex(&map_json)),
        );
        patch.insert(
            "paragraph_count".into(),
            Value::Int(paragraphs.len() as i64),
        );
        store.apply(OperationSpec {
            target_id: tl_id,
            op_type: OperationType::PatchPayload(patch),
            intent: OperationIntent::Editorial,
            reason: Some(format!("throughline sync: <{label}> ledger rebaseline")),
            batch_id: None,
            author: ACTOR.into(),
            author_kind: ActorKind::Agent,
            retention: RetentionTier::Durable,
        })?;
        Ok(())
    }
}

#[async_trait]
impl TaskExecutor for ThroughlineSyncExecutor {
    fn task_kind(&self) -> &str {
        KIND_THROUGHLINE_SYNC
    }

    async fn execute(
        &self,
        task: &Item,
        store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        let tl_item = Self::target_throughline(task, store)?;
        let document_id = Self::document_id(&tl_item)?;

        // ── Resume path ────────────────────────────────────────────────
        let (unresolved, resolved) = store.reviews_for(task.id)?;
        if !unresolved.is_empty() {
            return Ok(ExecutionOutcome::Suspended);
        }
        for review in &resolved {
            let approved = matches!(review.payload.get("resolution"),
                                    Some(Value::String(r)) if r == "approved");
            let handled = matches!(review.payload.get("context_applied"),
                                   Some(Value::Bool(true)));
            if approved && !handled {
                let applied = self.apply_approved(review, &tl_item, store)?;
                // Mark the review consumed so a later resume doesn't
                // re-apply (idempotence across scheduler passes).
                store.apply(OperationSpec {
                    target_id: review.id,
                    op_type: OperationType::SetPayload(
                        "context_applied".into(),
                        Value::Bool(true),
                    ),
                    intent: OperationIntent::Routine,
                    reason: Some(format!("throughline sync: applied={applied}")),
                    batch_id: None,
                    author: ACTOR.into(),
                    author_kind: ActorKind::Agent,
                    retention: RetentionTier::Compactable,
                })?;
            }
        }

        // ── Derive current state (fresh read: applies above moved it) ──
        let tl_item = Self::target_throughline(task, store)?;
        let (map, source) = throughline_state(&tl_item)?;
        let sections = ledger_sections(store, document_id, &map)?;
        let paragraphs = extract_paragraphs(&source);
        let assessments = derive_anchor_states(&map, &sections, &paragraphs);

        // ── Loop-until-dry: one review per stale anchor ────────────────
        match Self::first_stale(&assessments) {
            None => Ok(ExecutionOutcome::Complete),
            Some(stale) => {
                // Don't reopen for an anchor whose review was just
                // rejected: a rejected resolution leaves the anchor stale
                // by design (visible state, not an error). Only open a new
                // review if no resolved review exists for this anchor yet.
                let already_reviewed = resolved.iter().any(|r| {
                    matches!(r.payload.get("context_anchor"),
                             Some(Value::String(l)) if l == &stale.label)
                });
                if already_reviewed {
                    return Ok(ExecutionOutcome::Complete);
                }
                self.open_proposal_review(
                    task, &tl_item, document_id, stale, &map, &source, &sections, store,
                )
                .await?;
                Ok(ExecutionOutcome::Suspended)
            }
        }
    }

    fn max_retries(&self) -> u32 {
        2
    }
}

#[cfg(test)]
mod tests;
