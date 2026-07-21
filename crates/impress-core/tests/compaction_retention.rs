//! Retention/compaction hardening tests (GUI-meld plan §9).
//!
//! `compact_operations` deletes compactable ops older than its window. These
//! tests pin the invariants that deletion must preserve:
//!
//!  (a) Time-travel to clocks below the compaction watermark resolves without
//!      error and returns the documented floor (the watermark snapshot);
//!      time-travel at/above the watermark is *exact* (identical to
//!      pre-compaction replay). Revision refs still dereference.
//!  (b) Compacting a manuscript with no revision at/after the watermark
//!      auto-creates one with `snapshot_reason = "stable-churn"`.
//!  (c) Durable ops are never deleted; a durable `custom:snapshot` op is
//!      left covering the deleted range.
//!  (d) Compaction never changes current state (byte-identical payload).
//!
//! Run with: cargo test -p impress-core --features sqlite

#![cfg(feature = "sqlite")]

use std::collections::BTreeMap;
use std::thread::sleep;
use std::time::Duration;

use chrono::Utc;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::manuscript_ops::{self, sha256_hex};
use impress_core::operation::{RetentionTier, StateAsOf};
use impress_core::store::{FieldMutation, ItemStore};
use impress_core::SqliteItemStore;
use proptest::prelude::*;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_item(schema: &str, payload: BTreeMap<String, Value>) -> Item {
    let now = Utc::now();
    Item {
        id: Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: "test".into(),
        author_kind: ActorKind::Human,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

fn make_manuscript(store: &SqliteItemStore, body: &str) -> ItemId {
    let id = Uuid::new_v4();
    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("title".into(), Value::String("Test Paper".into()));
    payload.insert("status".into(), Value::String("draft".into()));
    // Self-ref until the first revision exists.
    payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
    payload.insert("format".into(), Value::String("typst".into()));
    payload.insert("body_content".into(), Value::String(body.into()));
    payload.insert("body_content_hash".into(), Value::String(sha256_hex(body)));
    let mut item = make_item("manuscript", payload);
    item.id = id;
    store.insert(item).unwrap();
    id
}

/// Save a manuscript body the way imbib-core's `set_manuscript_body` will:
/// body fields marked Compactable.
fn save_body(store: &SqliteItemStore, ms: ItemId, body: &str) {
    store
        .update_with_retention(
            ms,
            vec![
                FieldMutation::SetPayload("body_content".into(), Value::String(body.into())),
                FieldMutation::SetPayload(
                    "body_content_hash".into(),
                    Value::String(sha256_hex(body)),
                ),
                FieldMutation::SetPayload(
                    "body_modified_at".into(),
                    Value::String(manuscript_ops::iso8601_now()),
                ),
            ],
            RetentionTier::Compactable,
        )
        .unwrap();
}

fn op_type_of(op: &Item) -> &str {
    match op.payload.get("op_type") {
        Some(Value::String(s)) => s.as_str(),
        _ => "",
    }
}

fn payload_at(store: &SqliteItemStore, id: ItemId, clock: u64) -> BTreeMap<String, Value> {
    store
        .effective_state(id, StateAsOf::LogicalClock(clock))
        .unwrap()
        .expect("state exists")
        .payload
}

/// Let wall-clock time advance past the ops just written so a
/// `window_days = 0` cutoff (created < now) makes them eligible.
fn age_ops() {
    sleep(Duration::from_millis(5));
}

// ---------------------------------------------------------------------------
// (a) Floor semantics + revision refs survive compaction
// ---------------------------------------------------------------------------

#[test]
fn compaction_preserves_time_travel_floor_and_revision_refs() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let ms = make_manuscript(&store, "v0");

    for body in ["v1", "v2", "v3", "v4"] {
        save_body(&store, ms, body);
    }

    // Named durable snapshot AFTER the churn — satisfies the revision gate.
    let rev =
        manuscript_ops::create_revision(&store, ms, "v1-tag", "manual", "u", ActorKind::Human)
            .unwrap();

    let ops = store.operations_for(ms, None).unwrap();
    let compactable_clocks: Vec<u64> = ops
        .iter()
        .filter(|o| op_type_of(o) == "set_payload")
        .filter(|o| {
            matches!(o.payload.get("op_data"),
                Some(Value::Object(m)) if matches!(m.get("field"),
                    Some(Value::String(f)) if f.starts_with("body_")))
        })
        .map(|o| o.logical_clock)
        .collect();
    assert_eq!(compactable_clocks.len(), 12, "4 saves x 3 body fields");
    let watermark = *compactable_clocks.iter().max().unwrap();
    let mid_clock = compactable_clocks[4]; // somewhere inside the churn

    // Pre-compaction reference states (replay is exact while ops exist).
    let pre_mid = payload_at(&store, ms, mid_clock);
    let pre_watermark = payload_at(&store, ms, watermark);
    assert_eq!(
        pre_mid.get("body_content"),
        Some(&Value::String("v2".into())),
        "sanity: mid-churn state is exact before compaction"
    );

    age_ops();
    let deleted = store.compact_operations(0).unwrap();
    assert_eq!(deleted, 12, "exactly the compactable body ops are deleted");

    // At/above the watermark: replay is still exact.
    let post_watermark = payload_at(&store, ms, watermark);
    assert_eq!(post_watermark, pre_watermark);

    // Below the watermark: resolves without error and returns the documented
    // floor (watermark state), reporting the floor clock.
    let floor_state = store
        .effective_state(ms, StateAsOf::LogicalClock(mid_clock))
        .unwrap()
        .expect("pre-cutoff time-travel must still resolve");
    assert_eq!(
        floor_state.payload, pre_watermark,
        "floor = watermark state"
    );
    assert_eq!(
        floor_state.payload.get("body_content"),
        Some(&Value::String("v4".into()))
    );
    assert!(
        floor_state.as_of_clock >= watermark,
        "returned clock reveals the clamp (never silently pretends to be {})",
        mid_clock
    );

    // Timestamp-based time travel below the floor also clamps, not errors.
    let ancient = Utc::now() - chrono::Duration::days(30);
    let ts_state = store
        .effective_state(ms, StateAsOf::Timestamp(ancient))
        .unwrap()
        .expect("timestamp time-travel resolves");
    assert_eq!(
        ts_state.payload.get("body_content"),
        Some(&Value::String("v4".into()))
    );

    // Revision refs still dereference; the manual revision made the gate
    // pass, so no auto-revision was created.
    let revs = manuscript_ops::list_revisions(&store, ms).unwrap();
    assert_eq!(revs.len(), 1);
    assert_eq!(revs[0].id, rev.id);
    let ms_item = store.get(ms).unwrap().unwrap();
    assert_eq!(
        ms_item.payload.get("current_revision_ref"),
        Some(&Value::String(rev.id.to_string()))
    );
    assert_eq!(
        store
            .get(rev.id)
            .unwrap()
            .unwrap()
            .payload
            .get("source_inline"),
        Some(&Value::String("v4".into()))
    );
}

// ---------------------------------------------------------------------------
// (b) Auto-revision gate
// ---------------------------------------------------------------------------

#[test]
fn compaction_auto_creates_stable_churn_revision() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let ms = make_manuscript(&store, "v0");
    save_body(&store, ms, "draft body one");
    save_body(&store, ms, "draft body two");

    assert!(manuscript_ops::list_revisions(&store, ms)
        .unwrap()
        .is_empty());

    age_ops();
    let deleted = store.compact_operations(0).unwrap();
    assert!(deleted > 0);

    let revs = manuscript_ops::list_revisions(&store, ms).unwrap();
    assert_eq!(revs.len(), 1, "gate auto-created exactly one revision");
    let rev = &revs[0];
    assert_eq!(
        rev.payload.get("snapshot_reason"),
        Some(&Value::String("stable-churn".into()))
    );
    assert_eq!(
        rev.payload.get("revision_tag"),
        Some(&Value::String("auto".into()))
    );
    assert_eq!(rev.author, "system:compaction");
    assert_eq!(rev.author_kind, ActorKind::System);
    assert_eq!(
        rev.payload.get("source_inline"),
        Some(&Value::String("draft body two".into())),
        "auto revision captured the final body, independent of deleted ops"
    );

    // Head pointer advanced to the auto revision.
    let ms_item = store.get(ms).unwrap().unwrap();
    assert_eq!(
        ms_item.payload.get("current_revision_ref"),
        Some(&Value::String(rev.id.to_string()))
    );
}

#[test]
fn compaction_skips_auto_revision_when_fresh_one_exists() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let ms = make_manuscript(&store, "v0");
    save_body(&store, ms, "body");
    manuscript_ops::create_revision(&store, ms, "v1", "manual", "u", ActorKind::Human).unwrap();

    age_ops();
    store.compact_operations(0).unwrap();

    let revs = manuscript_ops::list_revisions(&store, ms).unwrap();
    assert_eq!(revs.len(), 1, "fresh manual revision satisfies the gate");
    assert_eq!(
        revs[0].payload.get("snapshot_reason"),
        Some(&Value::String("manual".into()))
    );
}

// ---------------------------------------------------------------------------
// (c) Durable ops are never deleted; snapshot op covers the range
// ---------------------------------------------------------------------------

#[test]
fn compaction_never_deletes_durable_ops_and_leaves_snapshot() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let item = make_item("note", BTreeMap::new());
    let id = item.id;
    store.insert(item).unwrap();

    store
        .update(
            id,
            vec![FieldMutation::SetPayload(
                "title".into(),
                Value::String("Durable Title".into()),
            )],
        )
        .unwrap();
    store
        .update_with_retention(
            id,
            vec![FieldMutation::SetPayload(
                "scratch".into(),
                Value::String("churn 1".into()),
            )],
            RetentionTier::Compactable,
        )
        .unwrap();
    store
        .update(id, vec![FieldMutation::AddTag("keep/me".into())])
        .unwrap();
    store
        .update_with_retention(
            id,
            vec![FieldMutation::SetPayload(
                "scratch".into(),
                Value::String("churn 2".into()),
            )],
            RetentionTier::Compactable,
        )
        .unwrap();

    let pre_ops = store.operations_for(id, None).unwrap();
    let durable_ids: Vec<ItemId> = pre_ops
        .iter()
        .filter(|o| {
            !matches!(o.payload.get("op_data"),
                Some(Value::Object(m)) if m.get("field") == Some(&Value::String("scratch".into())))
        })
        .map(|o| o.id)
        .collect();
    assert_eq!(durable_ids.len(), 2);

    age_ops();
    let deleted = store.compact_operations(0).unwrap();
    assert_eq!(deleted, 2, "only the compactable ops were deleted");

    let post_ops = store.operations_for(id, None).unwrap();
    for durable in &durable_ids {
        assert!(
            post_ops.iter().any(|o| o.id == *durable),
            "durable op {} must survive compaction",
            durable
        );
    }
    let snapshots: Vec<&Item> = post_ops
        .iter()
        .filter(|o| op_type_of(o) == "custom:snapshot")
        .collect();
    assert_eq!(snapshots.len(), 1, "one durable snapshot covers the range");
    assert_eq!(snapshots[0].author, "system:compaction");
    assert_eq!(post_ops.len(), durable_ids.len() + 1);

    // Compacting again with nothing eligible is a no-op — in particular the
    // snapshot itself is durable and must never be compacted away.
    age_ops();
    assert_eq!(store.compact_operations(0).unwrap(), 0);
    assert_eq!(store.operations_for(id, None).unwrap().len(), 3);
}

// ---------------------------------------------------------------------------
// (d) Current state is byte-identical across compaction
// ---------------------------------------------------------------------------

#[test]
fn compaction_preserves_current_state_bytes() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let ms = make_manuscript(&store, "v0");
    for body in ["alpha", "beta", "gamma"] {
        save_body(&store, ms, body);
    }
    store
        .update(ms, vec![FieldMutation::AddTag("project/gui-meld".into())])
        .unwrap();
    // Satisfy the revision gate up front: the ONLY store change compaction is
    // then allowed to make is deleting ops (the auto-revision path would
    // otherwise legitimately advance current_revision_ref).
    manuscript_ops::create_revision(&store, ms, "v1", "manual", "u", ActorKind::Human).unwrap();

    let pre_item = store.get(ms).unwrap().unwrap();
    let pre_payload_json = serde_json::to_string(&pre_item.payload).unwrap();
    let pre_current = store
        .effective_state(ms, StateAsOf::Current)
        .unwrap()
        .unwrap();

    age_ops();
    let deleted = store.compact_operations(0).unwrap();
    assert!(deleted > 0);

    let post_item = store.get(ms).unwrap().unwrap();
    let post_payload_json = serde_json::to_string(&post_item.payload).unwrap();
    assert_eq!(
        post_payload_json, pre_payload_json,
        "payload byte-identical"
    );
    assert_eq!(post_item.tags, pre_item.tags);
    assert_eq!(post_item.is_read, pre_item.is_read);
    assert_eq!(post_item.is_starred, pre_item.is_starred);

    let post_current = store
        .effective_state(ms, StateAsOf::Current)
        .unwrap()
        .unwrap();
    assert_eq!(post_current.payload, pre_current.payload);
    assert_eq!(post_current.tags, pre_current.tags);
}

// ---------------------------------------------------------------------------
// compact_undo_history: same snapshot-floor treatment as compact_operations
//
// `compact_undo_history(keep)` keeps the N most-recent undo groups and deletes
// every non-durable op below the resulting logical-clock cutoff, across targets
// in one pass. It must emit a durable watermark snapshot per affected target
// first, so the same floor invariants hold.
// ---------------------------------------------------------------------------

/// Ops for a target in ascending clock order.
fn ops_by_clock(store: &SqliteItemStore, id: ItemId) -> Vec<Item> {
    let mut ops = store.operations_for(id, None).unwrap();
    ops.sort_by_key(|o| o.logical_clock);
    ops
}

fn snapshot_ops(store: &SqliteItemStore, id: ItemId) -> Vec<Item> {
    store
        .operations_for(id, None)
        .unwrap()
        .into_iter()
        .filter(|o| op_type_of(o) == "custom:snapshot")
        .collect()
}

#[test]
fn undo_compaction_preserves_floor_and_survivors() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let item = make_item("note", BTreeMap::new());
    let id = item.id;
    store.insert(item).unwrap();

    // Interleave compactable body churn with durable envelope edits. Each
    // update is its own undo group (distinct id, no batch).
    let set_body = |v: &str, tier: RetentionTier| {
        store
            .update_with_retention(
                id,
                vec![FieldMutation::SetPayload(
                    "body".into(),
                    Value::String(v.into()),
                )],
                tier,
            )
            .unwrap();
    };
    set_body("v1", RetentionTier::Compactable); // op 0
    set_body("v2", RetentionTier::Compactable); // op 1
    store
        .update(id, vec![FieldMutation::AddTag("keep/a".into())])
        .unwrap(); // op 2 (durable)
    set_body("v3", RetentionTier::Compactable); // op 3
    set_body("v4", RetentionTier::Compactable); // op 4
    set_body("v5", RetentionTier::Compactable); // op 5
    store
        .update(id, vec![FieldMutation::AddTag("keep/b".into())])
        .unwrap(); // op 6 (durable)
    set_body("v6", RetentionTier::Compactable); // op 7

    let clocks: Vec<u64> = ops_by_clock(&store, id)
        .iter()
        .map(|o| o.logical_clock)
        .collect();
    assert_eq!(clocks.len(), 8);

    // Exact reference states while the full log exists.
    let pre_current = store.get(id).unwrap().unwrap();
    let pre_current_json = serde_json::to_string(&pre_current.payload).unwrap();

    // keep the 2 most-recent groups → cutoff = clocks[6]; deletes non-durable
    // ops below it: ops 0,1,3,4,5 (five compactable ops). Durable ops 2,6 and
    // the most-recent compactable op 7 survive.
    let deleted = store.compact_undo_history(2).unwrap();
    assert_eq!(deleted, 5, "exactly the five sub-cutoff compactable ops");

    // A single durable watermark snapshot pinned at the newest deleted clock.
    let snaps = snapshot_ops(&store, id);
    assert_eq!(snaps.len(), 1);
    assert_eq!(snaps[0].author, "system:compaction");
    assert_eq!(snaps[0].author_kind, ActorKind::System);
    let watermark = clocks[5]; // op 5 = v5, newest deleted
    assert_eq!(snaps[0].logical_clock, watermark);

    // Durable ops survive.
    let post_ops = ops_by_clock(&store, id);
    assert!(post_ops.iter().any(|o| o.logical_clock == clocks[2]));
    assert!(post_ops.iter().any(|o| o.logical_clock == clocks[6]));
    assert!(post_ops.iter().any(|o| o.logical_clock == clocks[7]));

    // Current state is byte-identical.
    let post_current = store.get(id).unwrap().unwrap();
    assert_eq!(
        serde_json::to_string(&post_current.payload).unwrap(),
        pre_current_json,
        "payload byte-identical across undo compaction"
    );
    assert_eq!(post_current.tags, pre_current.tags);
    let cur = store
        .effective_state(id, StateAsOf::Current)
        .unwrap()
        .unwrap();
    assert_eq!(cur.payload.get("body"), Some(&Value::String("v6".into())));
    assert_eq!(cur.tags, vec!["keep/a".to_string(), "keep/b".to_string()]);

    // Below the floor: resolves to the watermark state (v5, only keep/a), and
    // as_of_clock reveals the clamp.
    let floor = store
        .effective_state(id, StateAsOf::LogicalClock(clocks[1]))
        .unwrap()
        .expect("pre-cutoff time-travel still resolves");
    assert_eq!(floor.payload.get("body"), Some(&Value::String("v5".into())));
    assert_eq!(floor.tags, vec!["keep/a".to_string()]);
    assert!(
        floor.as_of_clock >= watermark,
        "clamp is visible: {} >= {}",
        floor.as_of_clock,
        watermark
    );

    // At/above the floor: replay is exact. At clocks[6] (durable keep/b),
    // body is still v5 (v6 lands later at clocks[7]).
    let at_keep_b = store
        .effective_state(id, StateAsOf::LogicalClock(clocks[6]))
        .unwrap()
        .unwrap();
    assert_eq!(
        at_keep_b.payload.get("body"),
        Some(&Value::String("v5".into()))
    );
    assert_eq!(
        at_keep_b.tags,
        vec!["keep/a".to_string(), "keep/b".to_string()]
    );

    // Idempotent: re-running with the same depth deletes nothing more and adds
    // no second snapshot (the snapshot is durable, above no cutoff it survives).
    let again = store.compact_undo_history(2).unwrap();
    assert_eq!(again, 0);
    assert_eq!(snapshot_ops(&store, id).len(), 1);
}

#[test]
fn undo_compaction_interleaves_with_compact_operations_newest_floor_wins() {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let item = make_item("note", BTreeMap::new());
    let id = item.id;
    store.insert(item).unwrap();

    let set_body = |v: &str, tier: RetentionTier| {
        store
            .update_with_retention(
                id,
                vec![FieldMutation::SetPayload(
                    "body".into(),
                    Value::String(v.into()),
                )],
                tier,
            )
            .unwrap();
    };
    // Low-clock compactable churn (folded by compact_operations), then
    // higher-clock ephemeral churn (folded by compact_undo_history), with
    // durable envelope edits interleaved and a durable final body edit.
    set_body("a", RetentionTier::Compactable); // op 0
    set_body("b", RetentionTier::Compactable); // op 1
    store
        .update(id, vec![FieldMutation::AddTag("t/1".into())])
        .unwrap(); // op 2 (durable)
    set_body("c", RetentionTier::Ephemeral); // op 3
    set_body("d", RetentionTier::Ephemeral); // op 4
    store
        .update(id, vec![FieldMutation::AddTag("t/2".into())])
        .unwrap(); // op 5 (durable)
    set_body("e", RetentionTier::Ephemeral); // op 6
    set_body("f", RetentionTier::Durable); // op 7 (durable, current body)

    let clocks: Vec<u64> = ops_by_clock(&store, id)
        .iter()
        .map(|o| o.logical_clock)
        .collect();
    assert_eq!(clocks.len(), 8);

    // Exact reference states across the full clock range while the log exists.
    let mut pre_states: BTreeMap<u64, (BTreeMap<String, Value>, Vec<String>)> = BTreeMap::new();
    for &c in &clocks {
        let s = store
            .effective_state(id, StateAsOf::LogicalClock(c))
            .unwrap()
            .unwrap();
        pre_states.insert(c, (s.payload, s.tags));
    }
    let pre_current = store.get(id).unwrap().unwrap();
    let pre_current_json = serde_json::to_string(&pre_current.payload).unwrap();

    // Pass 1: fold the aged compactable ops (0,1) → snapshot at clocks[1].
    age_ops();
    let deleted_ops = store.compact_operations(0).unwrap();
    assert_eq!(deleted_ops, 2);
    // current unchanged by pass 1.
    assert_eq!(
        serde_json::to_string(&store.get(id).unwrap().unwrap().payload).unwrap(),
        pre_current_json
    );

    // Pass 2: keep 2 most-recent groups. Deletes the two sub-cutoff ephemeral
    // ops (3,4) → snapshot at clocks[4], which is NEWER than pass 1's.
    let deleted_undo = store.compact_undo_history(2).unwrap();
    assert_eq!(deleted_undo, 2);

    // Two durable snapshots coexist; the floor is the NEWEST (highest clock).
    let snaps = snapshot_ops(&store, id);
    assert_eq!(
        snaps.len(),
        2,
        "one snapshot per pass, both durable, both kept"
    );
    let floor_clock = snaps.iter().map(|s| s.logical_clock).max().unwrap();
    assert_eq!(floor_clock, clocks[4], "undo pass produced the newer floor");

    // Current state byte-identical across BOTH passes.
    let post_current = store.get(id).unwrap().unwrap();
    assert_eq!(
        serde_json::to_string(&post_current.payload).unwrap(),
        pre_current_json,
        "payload byte-identical across both compactions"
    );
    assert_eq!(post_current.tags, pre_current.tags);

    // Every original clock resolves consistently: below the newest floor →
    // floor state; at/above → exact pre-compaction replay.
    for &c in &clocks {
        let post = store
            .effective_state(id, StateAsOf::LogicalClock(c))
            .unwrap()
            .unwrap();
        let expected = if c < floor_clock {
            &pre_states[&floor_clock]
        } else {
            &pre_states[&c]
        };
        assert_eq!(&post.payload, &expected.0, "payload at clock {}", c);
        assert_eq!(&post.tags, &expected.1, "tags at clock {}", c);
        if c < floor_clock {
            assert!(
                post.as_of_clock >= floor_clock,
                "clamp visible at clock {}",
                c
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Property: compaction preserves replay at/above the watermark and floors
// below it — for arbitrary interleavings of durable/compactable ops.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum EditOp {
    SetField(u8, String, bool), // (field index, value, compactable?)
    AddTag(u8, bool),
    SetRead(bool, bool),
}

fn edit_op_strategy() -> impl Strategy<Value = EditOp> {
    prop_oneof![
        (0u8..3, "[a-z]{1,8}", any::<bool>()).prop_map(|(f, v, c)| EditOp::SetField(f, v, c)),
        (0u8..3, any::<bool>()).prop_map(|(t, c)| EditOp::AddTag(t, c)),
        (any::<bool>(), any::<bool>()).prop_map(|(v, c)| EditOp::SetRead(v, c)),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    #[test]
    fn prop_compaction_preserves_replay_and_floors(
        edits in proptest::collection::vec(edit_op_strategy(), 1..10)
    ) {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("note", BTreeMap::new());
        let id = item.id;
        store.insert(item).unwrap();

        for edit in &edits {
            let (mutation, compactable) = match edit {
                EditOp::SetField(f, v, c) => (
                    FieldMutation::SetPayload(format!("field_{}", f), Value::String(v.clone())),
                    *c,
                ),
                EditOp::AddTag(t, c) => (FieldMutation::AddTag(format!("tag/{}", t)), *c),
                EditOp::SetRead(v, c) => (FieldMutation::SetRead(*v), *c),
            };
            let tier = if compactable {
                RetentionTier::Compactable
            } else {
                RetentionTier::Durable
            };
            store.update_with_retention(id, vec![mutation], tier).unwrap();
        }

        let ops = store.operations_for(id, None).unwrap();
        prop_assert_eq!(ops.len(), edits.len());
        let clocks: Vec<u64> = ops.iter().map(|o| o.logical_clock).collect();
        let compactable_count = edits
            .iter()
            .filter(|e| matches!(e,
                EditOp::SetField(_, _, true) | EditOp::AddTag(_, true) | EditOp::SetRead(_, true)))
            .count();
        let watermark: Option<u64> = ops
            .iter()
            .zip(edits.iter())
            .filter(|(_, e)| matches!(e,
                EditOp::SetField(_, _, true) | EditOp::AddTag(_, true) | EditOp::SetRead(_, true)))
            .map(|(o, _)| o.logical_clock)
            .max();

        // Reference states while the full log exists (exact replay).
        let mut pre_states = BTreeMap::new();
        for &c in &clocks {
            let s = store
                .effective_state(id, StateAsOf::LogicalClock(c))
                .unwrap()
                .unwrap();
            pre_states.insert(c, (s.payload, s.tags, s.is_read));
        }
        let pre_current = store.get(id).unwrap().unwrap();

        sleep(Duration::from_millis(3));
        let deleted = store.compact_operations(0).unwrap();
        prop_assert_eq!(deleted as usize, compactable_count);

        // Current state untouched.
        let post_current = store.get(id).unwrap().unwrap();
        prop_assert_eq!(&post_current.payload, &pre_current.payload);
        prop_assert_eq!(&post_current.tags, &pre_current.tags);
        prop_assert_eq!(post_current.is_read, pre_current.is_read);

        for &c in &clocks {
            let post = store
                .effective_state(id, StateAsOf::LogicalClock(c))
                .unwrap()
                .unwrap();
            let expected = match watermark {
                Some(w) if c < w => &pre_states[&w], // documented floor
                _ => &pre_states[&c],                // exact replay
            };
            prop_assert_eq!(&post.payload, &expected.0, "payload at clock {}", c);
            prop_assert_eq!(&post.tags, &expected.1, "tags at clock {}", c);
            prop_assert_eq!(post.is_read, expected.2, "is_read at clock {}", c);
        }
    }
}
