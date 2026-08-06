//! End-to-end gates for the throughline sync pipeline (ADR-0016 §Phase 3):
//! spawn gating (opt-in, anchored, drifted), the propose→review→apply
//! round-trip in both directions, reject-leaves-stale, and the
//! stale-proposal guard. Style mirrors the §9 enrichment gate.

use std::collections::BTreeMap;

use chrono::Utc;
use impel_core::{create_task_dag, SpawnRule, TaskStoreApi};
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::sqlite_store::SqliteItemStore;
use imprint_service::throughline::{AnchorEntry, AnchorMap, ThroughlineStore};
use imprint_service::{BlobStore, SectionStore};
use uuid::Uuid;

use crate::*;

const HUMAN: &str = "human:test";

fn bare_item(id: Uuid, schema: &str, payload: BTreeMap<String, Value>) -> Item {
    Item {
        id,
        schema: schema.into(),
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: HUMAN.into(),
        author_kind: ActorKind::Human,
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
    }
}

fn put_section(store: &SqliteItemStore, doc: Uuid, key: &str, body: &str) {
    let id = SectionStore::item_id(doc, key);
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String(key.into()));
    payload.insert("body".into(), Value::String(body.into()));
    payload.insert("section_key".into(), Value::String(key.into()));
    payload.insert("document_id".into(), Value::String(doc.to_string()));
    if store.get_item(id).unwrap().is_some() {
        TaskStoreApi::apply(
            store,
            OperationSpec {
                target_id: id,
                op_type: OperationType::SetPayload("body".into(), Value::String(body.into())),
                intent: OperationIntent::Editorial,
                reason: None,
                batch_id: None,
                author: HUMAN.into(),
                author_kind: ActorKind::Human,
                retention: RetentionTier::Durable,
            },
        )
        .unwrap();
    } else {
        store
            .create_item(bare_item(id, MANUSCRIPT_SECTION_SCHEMA, payload))
            .unwrap();
    }
}

/// Seed an opted-in document: one section, a throughline whose single
/// paragraph anchors that section, ledger baselined synced.
fn seed_throughline(store: &SqliteItemStore, doc: Uuid, section_key: &str, section_body: &str) {
    put_section(store, doc, section_key, section_body);

    let source = "The story so far. <tl-overview>\n".to_string();
    let paragraph_hash = extract_paragraphs(&source)[0].content_hash.clone();
    let mut map = AnchorMap::new(doc);
    map.anchors.insert(
        "tl-overview".into(),
        AnchorEntry {
            section_keys: vec![section_key.into()],
            manuscript_hashes: [(section_key.to_string(), BlobStore::sha256_hex(section_body))]
                .into(),
            throughline_hash: paragraph_hash,
        },
    );

    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Story".into()));
    payload.insert("document_ref".into(), Value::String(doc.to_string()));
    payload.insert("body_content".into(), Value::String(source));
    payload.insert(
        "anchor_map_json".into(),
        Value::String(map.serialize().unwrap()),
    );
    store
        .create_item(bare_item(
            ThroughlineStore::item_id(doc),
            "throughline",
            payload,
        ))
        .unwrap();
}

fn section_trigger(store: &SqliteItemStore, doc: Uuid, key: &str) -> Item {
    store
        .get_item(SectionStore::item_id(doc, key))
        .unwrap()
        .unwrap()
}

fn resolve_review(store: &SqliteItemStore, review_id: Uuid, resolution: &str) {
    TaskStoreApi::apply(
        store,
        OperationSpec {
            target_id: review_id,
            op_type: OperationType::SetPayload(
                "resolution".into(),
                Value::String(resolution.into()),
            ),
            intent: OperationIntent::Routine,
            reason: None,
            batch_id: None,
            author: HUMAN.into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Compactable,
        },
    )
    .unwrap();
}

fn throughline_body(store: &SqliteItemStore, doc: Uuid) -> String {
    let item = store
        .get_item(ThroughlineStore::item_id(doc))
        .unwrap()
        .unwrap();
    match item.payload.get("body_content") {
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

fn anchor_state(store: &SqliteItemStore, doc: Uuid) -> String {
    let item = store
        .get_item(ThroughlineStore::item_id(doc))
        .unwrap()
        .unwrap();
    let (map, source) = throughline_state(&item).unwrap();
    let sections = ledger_sections(store, doc, &map).unwrap();
    let paragraphs = extract_paragraphs(&source);
    derive_anchor_states(&map, &sections, &paragraphs)[0].state()
}

// ─── Negative gate: opt-in invariant (ADR-0016 D1) ─────────────────────────

#[tokio::test]
async fn non_opted_document_spawns_nothing() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    put_section(&store, doc, "introduction", "We measure X.");

    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    assert!(specs.is_empty(), "non-opted document must spawn zero tasks");
}

#[tokio::test]
async fn unanchored_or_synced_sections_spawn_nothing() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");

    // Synced: baseline matches current → no spawn.
    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    assert!(specs.is_empty(), "synced anchor must not spawn");

    // A section that exists but is not anchored → no spawn even if edited.
    put_section(&store, doc, "appendix", "Supporting detail.");
    let trigger = section_trigger(&store, doc, "appendix");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    assert!(specs.is_empty(), "unanchored section must not spawn");
}

// ─── End-to-end: manuscript-ahead propose → approve → apply ────────────────

#[tokio::test]
async fn manuscript_ahead_round_trip() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");

    // Drift the manuscript.
    put_section(&store, doc, "introduction", "We measure X and Y.");
    assert_eq!(anchor_state(&store, doc), "manuscript-ahead");

    // Spawn fires exactly one sync task.
    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    assert_eq!(specs.len(), 1);
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();

    // First execute: proposal + suspension. Nothing applied.
    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    let outcome = exec.execute(&task, &store).await.unwrap();
    assert_eq!(outcome, ExecutionOutcome::Suspended);
    assert_eq!(
        anchor_state(&store, doc),
        "manuscript-ahead",
        "propose must not apply"
    );

    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    assert_eq!(unresolved.len(), 1);
    let review = &unresolved[0];
    assert_eq!(
        review.payload.get("context_direction"),
        Some(&Value::String("manuscript-ahead".into()))
    );

    // Human approves with an edited paragraph (the human owns the words).
    TaskStoreApi::apply(
        &store,
        OperationSpec {
            target_id: review.id,
            op_type: OperationType::SetPayload(
                "context_proposed_paragraph".into(),
                Value::String("We now measure X and Y.".into()),
            ),
            intent: OperationIntent::Editorial,
            reason: None,
            batch_id: None,
            author: HUMAN.into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        },
    )
    .unwrap();
    resolve_review(&store, review.id, "approved");

    // Resume: apply + rebaseline + complete.
    let outcome = exec.execute(&task, &store).await.unwrap();
    assert_eq!(outcome, ExecutionOutcome::Complete);
    assert!(
        throughline_body(&store, doc).contains("We now measure X and Y. <tl-overview>"),
        "approved paragraph must be applied: {}",
        throughline_body(&store, doc)
    );
    assert_eq!(
        anchor_state(&store, doc),
        "synced",
        "ledger must rebaseline on accept"
    );
}

// ─── End-to-end: throughline-ahead propose → approve → apply ───────────────

#[tokio::test]
async fn throughline_ahead_round_trip() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");

    // Edit the narrative (ledger untouched → throughline-ahead).
    let tl_id = ThroughlineStore::item_id(doc);
    TaskStoreApi::apply(
        &store,
        OperationSpec {
            target_id: tl_id,
            op_type: OperationType::SetPayload(
                "body_content".into(),
                Value::String("A bolder story. <tl-overview>\n".into()),
            ),
            intent: OperationIntent::Editorial,
            reason: None,
            batch_id: None,
            author: HUMAN.into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        },
    )
    .unwrap();
    assert_eq!(anchor_state(&store, doc), "throughline-ahead");

    // Spawn via the (anchored) section trigger.
    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    assert_eq!(specs.len(), 1);
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();

    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    let review = &unresolved[0];
    assert_eq!(
        review.payload.get("context_direction"),
        Some(&Value::String("throughline-ahead".into()))
    );

    // Human drafts the section edit and approves.
    TaskStoreApi::apply(
        &store,
        OperationSpec {
            target_id: review.id,
            op_type: OperationType::SetPayload(
                "context_proposed_section_bodies".into(),
                Value::Object(
                    [(
                        "introduction".to_string(),
                        Value::String("We measure X, and boldly so.".into()),
                    )]
                    .into(),
                ),
            ),
            intent: OperationIntent::Editorial,
            reason: None,
            batch_id: None,
            author: HUMAN.into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        },
    )
    .unwrap();
    resolve_review(&store, review.id, "approved");

    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );
    let section = store
        .get_item(SectionStore::item_id(doc, "introduction"))
        .unwrap()
        .unwrap();
    assert_eq!(
        section.payload.get("body"),
        Some(&Value::String("We measure X, and boldly so.".into())),
        "approved section edit must be applied"
    );
    assert_eq!(anchor_state(&store, doc), "synced");
}

// ─── Reject leaves visible staleness (ADR-0016 D5) ─────────────────────────

#[tokio::test]
async fn rejected_proposal_leaves_anchor_stale() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");
    put_section(&store, doc, "introduction", "We measure X and Y.");

    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();

    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    resolve_review(&store, unresolved[0].id, "rejected");

    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );
    assert_eq!(
        anchor_state(&store, doc),
        "manuscript-ahead",
        "rejection leaves staleness visible; nothing auto-fixes"
    );
}

// ─── Regression: multi-paragraph apply preserves paragraph boundaries ──────

#[tokio::test]
async fn manuscript_ahead_apply_preserves_following_paragraphs() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    put_section(&store, doc, "introduction", "We measure X.");
    put_section(&store, doc, "results", "We find Y.");

    // Two-paragraph throughline: tl-a anchored+baselined, tl-b synced.
    let source = "Para A. <tl-a>\n\nPara B. <tl-b>\n";
    let ps = extract_paragraphs(source);
    let mut map = AnchorMap::new(doc);
    map.anchors.insert(
        "tl-a".into(),
        AnchorEntry {
            section_keys: vec!["introduction".into()],
            manuscript_hashes: [(
                "introduction".to_string(),
                BlobStore::sha256_hex("We measure X."),
            )]
            .into(),
            throughline_hash: ps[0].content_hash.clone(),
        },
    );
    map.anchors.insert(
        "tl-b".into(),
        AnchorEntry {
            section_keys: vec!["results".into()],
            manuscript_hashes: [("results".to_string(), BlobStore::sha256_hex("We find Y."))]
                .into(),
            throughline_hash: ps[1].content_hash.clone(),
        },
    );
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Story".into()));
    payload.insert("document_ref".into(), Value::String(doc.to_string()));
    payload.insert("body_content".into(), Value::String(source.into()));
    payload.insert(
        "anchor_map_json".into(),
        Value::String(map.serialize().unwrap()),
    );
    store
        .create_item(bare_item(
            ThroughlineStore::item_id(doc),
            "throughline",
            payload,
        ))
        .unwrap();

    // Drift only tl-a's section, approve an update.
    put_section(&store, doc, "introduction", "We measure X and Y.");
    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();
    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    resolve_review(&store, unresolved[0].id, "approved");
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );

    // tl-b must survive as its own paragraph (blank-line separator intact).
    let body = throughline_body(&store, doc);
    let after = extract_paragraphs(&body);
    assert_eq!(
        after.iter().map(|p| p.label.as_str()).collect::<Vec<_>>(),
        vec!["tl-a", "tl-b"],
        "apply must not swallow the following paragraph: {body:?}"
    );
}

// ─── Regression: a rejected anchor must not starve later stale anchors ─────

#[tokio::test]
async fn rejected_anchor_does_not_starve_later_stale_anchors() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    put_section(&store, doc, "introduction", "We measure X.");
    put_section(&store, doc, "results", "We find Y.");

    let source = "Para A. <tl-a>\n\nPara B. <tl-b>\n";
    let ps = extract_paragraphs(source);
    let mut map = AnchorMap::new(doc);
    for (label, key, body, hash) in [
        ("tl-a", "introduction", "We measure X.", &ps[0].content_hash),
        ("tl-b", "results", "We find Y.", &ps[1].content_hash),
    ] {
        map.anchors.insert(
            label.into(),
            AnchorEntry {
                section_keys: vec![key.into()],
                manuscript_hashes: [(key.to_string(), BlobStore::sha256_hex(body))].into(),
                throughline_hash: hash.clone(),
            },
        );
    }
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Story".into()));
    payload.insert("document_ref".into(), Value::String(doc.to_string()));
    payload.insert("body_content".into(), Value::String(source.into()));
    payload.insert(
        "anchor_map_json".into(),
        Value::String(map.serialize().unwrap()),
    );
    store
        .create_item(bare_item(
            ThroughlineStore::item_id(doc),
            "throughline",
            payload,
        ))
        .unwrap();

    // Both sections drift → both anchors stale in one task.
    put_section(&store, doc, "introduction", "We measure X v2.");
    put_section(&store, doc, "results", "We find Y v2.");
    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();
    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));

    // First proposal (tl-a, label order) — human REJECTS it.
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    assert_eq!(
        unresolved[0].payload.get("context_anchor"),
        Some(&Value::String("tl-a".into()))
    );
    resolve_review(&store, unresolved[0].id, "rejected");

    // Resume must move ON to tl-b, not complete.
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended,
        "rejecting tl-a must not starve tl-b's proposal"
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    assert_eq!(
        unresolved[0].payload.get("context_anchor"),
        Some(&Value::String("tl-b".into()))
    );
    resolve_review(&store, unresolved[0].id, "rejected");

    // Both rejected → complete; both anchors remain visibly stale.
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );
}

// ─── Broken-anchor repair (ADR-0016 D4, Phase 4) ───────────────────────────

#[tokio::test]
async fn broken_anchor_rebind_round_trip() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");

    // Simulate a heading rename: same body under a new key, old key gone.
    put_section(&store, doc, "background", "We measure X.");
    impress_core::store::ItemStore::delete(&store, SectionStore::item_id(doc, "introduction"))
        .unwrap();
    assert_eq!(anchor_state(&store, doc), "broken");

    // The pure heuristic finds the unambiguous rename target.
    let sections = ledger_sections(
        &store,
        doc,
        &AnchorMap {
            version: 1,
            document_id: doc.to_string(),
            anchors: [(
                "tl-overview".to_string(),
                AnchorEntry {
                    section_keys: vec!["background".into()],
                    ..Default::default()
                },
            )]
            .into(),
            supporting: vec![],
            narrative_order: BTreeMap::new(),
        },
    )
    .unwrap();
    assert_eq!(
        imprint_service::throughline::rebind_candidate(
            "introduction",
            Some(&BlobStore::sha256_hex("We measure X.")),
            &sections
        ),
        Some("background".to_string())
    );

    // Spawn via the renamed section, execute → broken proposal.
    let trigger = section_trigger(&store, doc, "background");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    assert_eq!(specs.len(), 1, "broken anchor must spawn a repair task");
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();

    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    let review = &unresolved[0];
    assert_eq!(
        review.payload.get("context_direction"),
        Some(&Value::String("broken".into()))
    );
    assert_eq!(
        review.payload.get("context_broken_key"),
        Some(&Value::String("introduction".into()))
    );

    // Human chooses the rebind and approves.
    for (key, value) in [
        ("context_repair_action", "rebind"),
        ("context_rebind_to", "background"),
    ] {
        TaskStoreApi::apply(
            &store,
            OperationSpec {
                target_id: review.id,
                op_type: OperationType::SetPayload(key.into(), Value::String(value.into())),
                intent: OperationIntent::Editorial,
                reason: None,
                batch_id: None,
                author: HUMAN.into(),
                author_kind: ActorKind::Human,
                retention: RetentionTier::Durable,
            },
        )
        .unwrap();
    }
    resolve_review(&store, review.id, "approved");

    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );
    assert_eq!(
        anchor_state(&store, doc),
        "synced",
        "rebound anchor must rebaseline to the renamed section"
    );
}

#[test]
fn rebind_candidate_refuses_ambiguity() {
    let mk = |key: &str, body: &str| SectionRecord {
        item_id: Uuid::new_v4(),
        document_id: Uuid::new_v4(),
        section_key: key.into(),
        title: key.into(),
        body: body.into(),
        section_type: None,
        order_index: None,
        word_count: 0,
        content_hash: None,
        created_ms: 0,
    };
    let hash = BlobStore::sha256_hex("same body");
    // Two sections share the ledger hash → ambiguous → None.
    let sections = vec![mk("a", "same body"), mk("b", "same body")];
    assert_eq!(
        imprint_service::throughline::rebind_candidate("old", Some(&hash), &sections),
        None
    );
    // No match → None.
    assert_eq!(
        imprint_service::throughline::rebind_candidate("old", Some(&hash), &[mk("c", "different")]),
        None
    );
}

// ─── Stale-proposal guard (ADR-0016 D9) ────────────────────────────────────

#[tokio::test]
async fn stale_proposal_is_never_force_applied() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");
    put_section(&store, doc, "introduction", "We measure X and Y.");

    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();

    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    let review_id = unresolved[0].id;

    // Document moves AFTER the proposal was computed…
    put_section(&store, doc, "introduction", "We measure X, Y and Z.");
    // …and the human approves the (now stale) proposal.
    resolve_review(&store, review_id, "approved");

    let before = throughline_body(&store, doc);
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );
    assert_eq!(
        throughline_body(&store, doc),
        before,
        "guard must refuse to apply a proposal computed against old state"
    );
    assert_eq!(anchor_state(&store, doc), "manuscript-ahead");
}

#[tokio::test]
async fn narrative_reorder_invalidates_an_open_proposal() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let doc = Uuid::new_v4();
    seed_throughline(&store, doc, "introduction", "We measure X.");
    put_section(&store, doc, "introduction", "We measure X and Y.");

    let trigger = section_trigger(&store, doc, "introduction");
    let specs = ThroughlineSpawnRule.spawn(&trigger, &store).await.unwrap();
    let ids = create_task_dag(&store, &specs, ACTOR).unwrap();
    let task = store.get_item(ids[0]).unwrap().unwrap();
    let exec = ThroughlineSyncExecutor::new(Box::new(TemplateDrafter));
    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Suspended
    );
    let (unresolved, _) = store.reviews_for(task.id).unwrap();
    let review_id = unresolved[0].id;

    // The words are unchanged, but the anchored beat moves from position 0
    // to 1 while review is open.
    let moved_source = "A new opening. <tl-opening>\n\nThe story so far. <tl-overview>\n";
    TaskStoreApi::apply(
        &store,
        OperationSpec {
            target_id: ThroughlineStore::item_id(doc),
            op_type: OperationType::SetPayload(
                "body_content".into(),
                Value::String(moved_source.into()),
            ),
            intent: OperationIntent::Editorial,
            reason: None,
            batch_id: None,
            author: HUMAN.into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        },
    )
    .unwrap();
    resolve_review(&store, review_id, "approved");

    assert_eq!(
        exec.execute(&task, &store).await.unwrap(),
        ExecutionOutcome::Complete
    );
    assert_eq!(
        throughline_body(&store, doc),
        moved_source,
        "order guard must refuse a proposal computed before the beat moved"
    );
    assert_eq!(anchor_state(&store, doc), "manuscript-ahead");
}
