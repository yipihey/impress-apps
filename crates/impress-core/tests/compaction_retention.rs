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
