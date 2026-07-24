//! ADR-0007 Phase 3 (Phase B) convergence suite — the load-bearing
//! correctness gate for the Rust sync apply/snapshot engine.
//!
//! Core property: two stores exchanging their outboxes through the Phase B
//! surface (snapshots → apply → retry pending refs → confirm seqs), with
//! randomized sub-batch apply order and occasional duplicate delivery of the
//! just-delivered batch (at-least-once semantics, matching CKSyncEngine —
//! which never redelivers arbitrarily old batches), converge to
//! byte-identical sync-visible projections at quiescence.
//!
//! Deliberate scope choices mirroring the plan's accepted 3.0 limitations:
//! - Reference *removal* is exercised sequentially (targeted test), not in
//!   the random mix: concurrent add-vs-remove of the SAME edge is
//!   arbiter-dependent (CloudKit's server orders it; a symmetric two-peer
//!   harness has no arbiter).
//! - The two stores use distinct authors, so the author tiebreak is decisive
//!   for records each store creates; same-item concurrent edits (author
//!   columns stay the creator's) fall through to the content-key tiebreak.
//!
//! Run with: cargo test -p impress-core --features sqlite

#![cfg(feature = "sqlite")]

use std::collections::{BTreeMap, BTreeSet};
use std::thread::sleep;
use std::time::Duration;

use chrono::Utc;
use impress_core::item::{ActorKind, FlagState, Item, Priority, Value, Visibility};
use impress_core::manuscript_ops;
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::sqlite_store::{SqliteItemStore, StoreConfig};
use impress_core::store::{FieldMutation, ItemStore, StoreError};
use impress_core::sync::{
    sync_reference_record_name, SyncItemRecord, SyncReferenceRecord, SyncTombstoneRecord,
};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Deterministic RNG (no new deps): 64-bit LCG, MMIX constants.
// ---------------------------------------------------------------------------

struct Lcg(u64);

impl Lcg {
    fn new(seed: u64) -> Self {
        Lcg(seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1))
    }
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        (self.next() >> 33) % n
    }
    fn chance(&mut self, one_in: u64) -> bool {
        self.below(one_in) == 0
    }
    fn uuid(&mut self) -> Uuid {
        let hi = self.next() as u128;
        let lo = self.next() as u128;
        Uuid::from_u128((hi << 64) | lo)
    }
    fn shuffle<T>(&mut self, slice: &mut [T]) {
        for i in (1..slice.len()).rev() {
            let j = self.below(i as u64 + 1) as usize;
            slice.swap(i, j);
        }
    }
}

// ---------------------------------------------------------------------------
// Store + item helpers
// ---------------------------------------------------------------------------

fn open_store(author: &str) -> SqliteItemStore {
    SqliteItemStore::open_in_memory_with_config(StoreConfig {
        author: author.into(),
        author_kind: ActorKind::Human,
        tag_namespace: "local".into(),
    })
    .unwrap()
}

fn make_item(id: Uuid, schema: &str, author: &str, payload: BTreeMap<String, Value>) -> Item {
    let now = Utc::now();
    Item {
        id,
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: author.into(),
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

fn insert_paper(store: &SqliteItemStore, rng: &mut Lcg, author: &str, n: u64) -> Uuid {
    let id = rng.uuid();
    let mut payload = BTreeMap::new();
    payload.insert(
        "title".into(),
        Value::String(format!("paper {} from {}", n, author)),
    );
    payload.insert("note".into(), Value::String(format!("note-{}", n)));
    store
        .insert(make_item(id, "test/paper", author, payload))
        .unwrap();
    id
}

/// The sync-visible item ids of a store (op items and ephemera excluded),
/// via the same projection the engine pushes.
fn visible_records(store: &SqliteItemStore) -> Vec<SyncItemRecord> {
    let all = store.query(&ItemQuery::default()).unwrap();
    let ids: Vec<String> = all.iter().map(|i| i.id.to_string()).collect();
    store.sync_snapshot_items(ids).unwrap()
}

fn visible_ids(store: &SqliteItemStore) -> Vec<Uuid> {
    visible_records(store)
        .iter()
        .map(|r| Uuid::parse_str(&r.id).unwrap())
        .collect()
}

// ---------------------------------------------------------------------------
// Exchange harness (models the Phase D CKSyncEngine drain/apply loop)
// ---------------------------------------------------------------------------

struct Batch {
    items: Vec<SyncItemRecord>,
    refs: Vec<SyncReferenceRecord>,
    tombstones: Vec<SyncTombstoneRecord>,
    ref_deletions: Vec<String>,
}

fn drain(store: &SqliteItemStore) -> Batch {
    let entries = store.sync_outbox_entries(u32::MAX).unwrap();
    let seqs: Vec<i64> = entries.iter().map(|(s, _, _)| *s).collect();

    let mut item_ids = Vec::new();
    let mut ref_names = Vec::new();
    let mut deleted_item_names: BTreeSet<String> = BTreeSet::new();
    let mut ref_deletions = Vec::new();
    for (_, kind, record_name) in &entries {
        match kind.as_str() {
            "item" => item_ids.push(record_name.clone()),
            "reference" => ref_names.push(record_name.clone()),
            "delete_item" => {
                deleted_item_names.insert(record_name.clone());
            }
            "delete_reference" => {
                let mut parts = record_name.splitn(3, '|');
                if let (Some(s), Some(t), Some(e)) = (parts.next(), parts.next(), parts.next()) {
                    ref_deletions.push(sync_reference_record_name(s, t, e));
                }
            }
            other => panic!("unexpected outbox kind '{}'", other),
        }
    }

    let items = store.sync_snapshot_items(item_ids).unwrap();
    let refs = store.sync_snapshot_references(ref_names).unwrap();
    let tombstones = store
        .sync_local_tombstones(0)
        .unwrap()
        .into_iter()
        .filter(|t| deleted_item_names.contains(&t.record_name))
        .collect();

    store.sync_outbox_remove(seqs).unwrap();
    Batch {
        items,
        refs,
        tombstones,
        ref_deletions,
    }
}

fn apply(batch: &Batch, store: &SqliteItemStore, rng: &mut Lcg) {
    let mut order = [0usize, 1, 2, 3];
    rng.shuffle(&mut order);
    for phase in order {
        match phase {
            0 => {
                store.sync_apply_remote_items(batch.items.clone()).unwrap();
            }
            1 => {
                store
                    .sync_apply_remote_references(batch.refs.clone())
                    .unwrap();
            }
            2 => {
                store
                    .sync_apply_remote_tombstones(batch.tombstones.clone())
                    .unwrap();
            }
            _ => {
                store
                    .sync_apply_remote_deletions(batch.ref_deletions.clone())
                    .unwrap();
            }
        }
    }
    store.sync_retry_pending_references().unwrap();
}

/// Simultaneous exchange: both sides drain BEFORE either applies (models the
/// concurrent push/fetch window), with occasional immediate duplicate
/// delivery of the whole batch.
fn exchange(a: &SqliteItemStore, b: &SqliteItemStore, rng: &mut Lcg, allow_duplicates: bool) {
    let batch_a = drain(a);
    let batch_b = drain(b);
    apply(&batch_a, b, rng);
    if allow_duplicates && rng.chance(3) {
        apply(&batch_a, b, rng);
    }
    apply(&batch_b, a, rng);
    if allow_duplicates && rng.chance(3) {
        apply(&batch_b, a, rng);
    }
}

/// Exchange until both outboxes are empty (bounded), then assert quiescence.
fn settle(a: &SqliteItemStore, b: &SqliteItemStore, rng: &mut Lcg) {
    for _ in 0..10 {
        let a_empty = a.sync_outbox_entries(1).unwrap().is_empty();
        let b_empty = b.sync_outbox_entries(1).unwrap().is_empty();
        if a_empty && b_empty {
            return;
        }
        exchange(a, b, rng, false);
    }
    assert!(
        a.sync_outbox_entries(1).unwrap().is_empty()
            && b.sync_outbox_entries(1).unwrap().is_empty(),
        "outboxes failed to drain to empty within the settle bound"
    );
}

// ---------------------------------------------------------------------------
// Projection comparison
// ---------------------------------------------------------------------------

fn canonical_payload(json: &str) -> String {
    let map: BTreeMap<String, Value> = serde_json::from_str(json).unwrap();
    serde_json::to_string(&map).unwrap()
}

/// Full sync-visible projection: normalized item records plus the reference
/// set of projected items. Byte-comparable.
fn projection(store: &SqliteItemStore) -> (Vec<SyncItemRecord>, BTreeSet<String>) {
    let all = store.query(&ItemQuery::default()).unwrap();
    let mut records = visible_records(store);
    for rec in &mut records {
        rec.payload_json = canonical_payload(&rec.payload_json);
        rec.tag_paths.sort();
    }
    records.sort_by(|x, y| x.id.cmp(&y.id));

    let projected: BTreeSet<String> = records.iter().map(|r| r.id.clone()).collect();
    let mut refs = BTreeSet::new();
    for item in &all {
        if !projected.contains(&item.id.to_string()) {
            continue;
        }
        for r in &item.references {
            refs.insert(format!(
                "{}|{}|{}|{:?}",
                item.id,
                r.target,
                serde_json::to_string(&r.edge_type).unwrap(),
                r.metadata
            ));
        }
    }
    (records, refs)
}

fn assert_converged(a: &SqliteItemStore, b: &SqliteItemStore, context: &str) {
    let (items_a, refs_a) = projection(a);
    let (items_b, refs_b) = projection(b);
    assert_eq!(items_a, items_b, "item projections diverged ({})", context);
    assert_eq!(refs_a, refs_b, "reference sets diverged ({})", context);
    assert_eq!(
        a.sync_status_counts().unwrap().pending_refs,
        0,
        "store A left unresolved pending refs ({})",
        context
    );
    assert_eq!(
        b.sync_status_counts().unwrap().pending_refs,
        0,
        "store B left unresolved pending refs ({})",
        context
    );
}

// ---------------------------------------------------------------------------
// Random op generation
// ---------------------------------------------------------------------------

fn random_op(store: &SqliteItemStore, rng: &mut Lcg, author: &str, counter: &mut u64) {
    let ids = visible_ids(store);
    *counter += 1;
    let roll = rng.below(100);

    if ids.is_empty() || roll < 30 {
        insert_paper(store, rng, author, *counter);
        return;
    }

    let pick = |rng: &mut Lcg, ids: &[Uuid]| ids[rng.below(ids.len() as u64) as usize];

    if roll < 70 {
        // Envelope / payload mutation.
        let id = pick(rng, &ids);
        let mutation = match rng.below(6) {
            0 => FieldMutation::SetRead(rng.chance(2)),
            1 => FieldMutation::SetStarred(rng.chance(2)),
            2 => {
                if rng.chance(3) {
                    FieldMutation::SetFlag(None)
                } else {
                    FieldMutation::SetFlag(Some(FlagState {
                        color: ["red", "amber", "green"][rng.below(3) as usize].into(),
                        style: None,
                        length: None,
                    }))
                }
            }
            3 => FieldMutation::AddTag(format!("topic/t{}", rng.below(5))),
            4 => FieldMutation::RemoveTag(format!("topic/t{}", rng.below(5))),
            _ => FieldMutation::SetPayload(
                "note".into(),
                Value::String(format!("note-{}-{}", author, rng.below(1000))),
            ),
        };
        store.update(id, vec![mutation]).unwrap();
    } else if roll < 85 {
        // Add a reference between two existing items (adds only in the
        // random mix — see the module doc for why removals are targeted).
        if ids.len() >= 2 {
            let src = pick(rng, &ids);
            let tgt = pick(rng, &ids);
            if src != tgt {
                let edge = if rng.chance(2) {
                    EdgeType::Cites
                } else {
                    EdgeType::RelatesTo
                };
                store
                    .update(
                        src,
                        vec![FieldMutation::AddReference(TypedReference {
                            target: tgt,
                            edge_type: edge,
                            metadata: None,
                        })],
                    )
                    .unwrap();
            }
        }
    } else {
        store.delete(pick(rng, &ids)).unwrap();
    }
}

// ---------------------------------------------------------------------------
// The core convergence property
// ---------------------------------------------------------------------------

#[test]
fn two_store_random_convergence() {
    const SEEDS: u64 = 400;
    const ROUNDS: usize = 5;
    const OPS_PER_STORE_PER_ROUND: usize = 7;
    // 400 seeds x 2 stores x 5 rounds x 7 ops = 28,000 operations total
    // (~23s debug build — inside the <60s budget; shrink SEEDS first if the
    // suite ever needs to get faster).

    for seed in 1..=SEEDS {
        let mut rng = Lcg::new(seed);
        let a = open_store("user-a");
        let b = open_store("user-b");
        let mut counter = 0u64;

        for _round in 0..ROUNDS {
            for _ in 0..OPS_PER_STORE_PER_ROUND {
                random_op(&a, &mut rng, "user-a", &mut counter);
                random_op(&b, &mut rng, "user-b", &mut counter);
            }
            exchange(&a, &b, &mut rng, true);
        }
        settle(&a, &b, &mut rng);
        assert_converged(&a, &b, &format!("seed {}", seed));
    }
}

// ---------------------------------------------------------------------------
// Targeted scenarios
// ---------------------------------------------------------------------------

#[test]
fn idempotent_reapply_of_same_batch() {
    let mut rng = Lcg::new(42);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let x = insert_paper(&a, &mut rng, "user-a", 1);
    let y = insert_paper(&a, &mut rng, "user-a", 2);
    a.update(x, vec![FieldMutation::AddTag("topic/t1".into())])
        .unwrap();
    a.update(
        x,
        vec![FieldMutation::AddReference(TypedReference {
            target: y,
            edge_type: EdgeType::Cites,
            metadata: None,
        })],
    )
    .unwrap();

    let batch = drain(&a);
    apply(&batch, &b, &mut rng);
    let (items_first, refs_first) = projection(&b);

    // Second delivery of the identical batch: pure no-op on state, and the
    // item pass reports everything as an LWW skip.
    let report = b.sync_apply_remote_items(batch.items.clone()).unwrap();
    assert_eq!(report.applied, 0, "identical records must not re-apply");
    assert_eq!(report.skipped_lww, batch.items.len() as u32);
    apply(&batch, &b, &mut rng);

    let (items_second, refs_second) = projection(&b);
    assert_eq!(items_first, items_second);
    assert_eq!(refs_first, refs_second);
    assert_converged(&a, &b, "idempotent reapply");
}

#[test]
fn edit_after_delete_resurrects_and_repushes() {
    let mut rng = Lcg::new(7);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let x = insert_paper(&a, &mut rng, "user-a", 1);
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);

    // B deletes first; A edits strictly later.
    b.delete(x).unwrap();
    sleep(Duration::from_millis(15));
    a.update(
        x,
        vec![FieldMutation::SetPayload(
            "note".into(),
            Value::String("survives the delete".into()),
        )],
    )
    .unwrap();

    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);
    assert_converged(&a, &b, "edit after delete");

    // The edit won on both sides.
    for store in [&a, &b] {
        let item = store.get(x).unwrap().expect("item must be resurrected");
        assert_eq!(
            item.payload.get("note"),
            Some(&Value::String("survives the delete".into()))
        );
    }
}

#[test]
fn delete_after_edit_deletes_everywhere() {
    let mut rng = Lcg::new(8);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let x = insert_paper(&a, &mut rng, "user-a", 1);
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);

    // A edits first; B deletes strictly later.
    a.update(
        x,
        vec![FieldMutation::SetPayload(
            "note".into(),
            Value::String("doomed edit".into()),
        )],
    )
    .unwrap();
    sleep(Duration::from_millis(15));
    b.delete(x).unwrap();

    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);
    assert_converged(&a, &b, "delete after edit");
    assert!(a.get(x).unwrap().is_none(), "delete must win on A");
    assert!(b.get(x).unwrap().is_none(), "delete must win on B");
}

#[test]
fn deferred_reference_resolves_when_endpoint_arrives() {
    let mut rng = Lcg::new(9);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let x = insert_paper(&a, &mut rng, "user-a", 1);
    let y = insert_paper(&a, &mut rng, "user-a", 2);
    a.update(
        x,
        vec![FieldMutation::AddReference(TypedReference {
            target: y,
            edge_type: EdgeType::Cites,
            metadata: None,
        })],
    )
    .unwrap();

    let batch = drain(&a);

    // Deliver the reference FIRST: endpoints missing, it must defer.
    let report = b.sync_apply_remote_references(batch.refs.clone()).unwrap();
    assert_eq!(report.deferred, 1);
    assert_eq!(report.applied, 0);
    assert_eq!(b.sync_status_counts().unwrap().pending_refs, 1);
    let retry = b.sync_retry_pending_references().unwrap();
    assert_eq!(retry.deferred, 1, "still unresolvable without endpoints");

    // Endpoints arrive; the retry applies the parked edge.
    b.sync_apply_remote_items(batch.items.clone()).unwrap();
    let retry = b.sync_retry_pending_references().unwrap();
    assert_eq!(retry.applied, 1);
    assert_eq!(b.sync_status_counts().unwrap().pending_refs, 0);
    let item = b.get(x).unwrap().unwrap();
    assert!(
        item.references
            .iter()
            .any(|r| r.target == y && r.edge_type == EdgeType::Cites),
        "deferred edge must materialize after its endpoint arrives"
    );
}

#[test]
fn reference_removal_propagates() {
    let mut rng = Lcg::new(10);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let x = insert_paper(&a, &mut rng, "user-a", 1);
    let y = insert_paper(&a, &mut rng, "user-a", 2);
    a.update(
        x,
        vec![FieldMutation::AddReference(TypedReference {
            target: y,
            edge_type: EdgeType::Cites,
            metadata: None,
        })],
    )
    .unwrap();
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);
    assert!(b
        .get(x)
        .unwrap()
        .unwrap()
        .references
        .iter()
        .any(|r| r.target == y));

    a.update(x, vec![FieldMutation::RemoveReference(y, EdgeType::Cites)])
        .unwrap();
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);
    assert_converged(&a, &b, "reference removal");
    assert!(
        b.get(x).unwrap().unwrap().references.is_empty(),
        "edge removal must propagate as a CKRecord deletion"
    );
}

#[test]
fn manuscript_conflict_backup_preserves_losing_unpushed_body() {
    let mut rng = Lcg::new(11);
    let a = open_store("user-a");
    let b = open_store("user-b");

    // Shared manuscript on both stores.
    let m = rng.uuid();
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Draft".into()));
    payload.insert("body_content".into(), Value::String("v0".into()));
    a.insert(make_item(m, "manuscript", "user-a", payload))
        .unwrap();
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);

    // A drafts locally (never pushed); B edits later and wins LWW.
    a.update(
        m,
        vec![FieldMutation::SetPayload(
            "body_content".into(),
            Value::String("local-draft".into()),
        )],
    )
    .unwrap();
    sleep(Duration::from_millis(15));
    b.update(
        m,
        vec![FieldMutation::SetPayload(
            "body_content".into(),
            Value::String("remote-final".into()),
        )],
    )
    .unwrap();

    // Deliver B's winning record to A while A's edit still sits unpushed.
    let batch_b = drain(&b);
    let report = a.sync_apply_remote_items(batch_b.items.clone()).unwrap();
    assert_eq!(
        report.conflict_backups, 1,
        "losing unpushed body must be backed up"
    );
    assert_eq!(report.applied, 1);

    // The remote body won...
    let manuscript = a.get(m).unwrap().unwrap();
    assert_eq!(
        manuscript.payload.get("body_content"),
        Some(&Value::String("remote-final".into()))
    );
    // ...and the losing draft is preserved as a sync-conflict-backup revision.
    let revisions = manuscript_ops::list_revisions(&a, m).unwrap();
    let backup = revisions
        .iter()
        .find(|r| {
            r.payload.get("snapshot_reason") == Some(&Value::String("sync-conflict-backup".into()))
        })
        .expect("a sync-conflict-backup revision must exist");
    assert_eq!(
        backup.payload.get("source_inline"),
        Some(&Value::String("local-draft".into()))
    );

    // The backup revision itself syncs; the peers still converge.
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);
    assert_converged(&a, &b, "manuscript conflict backup");
    let revisions_b = manuscript_ops::list_revisions(&b, m).unwrap();
    assert!(
        revisions_b.iter().any(|r| r.payload.get("snapshot_reason")
            == Some(&Value::String("sync-conflict-backup".into()))),
        "the conflict backup must replicate to the peer"
    );
}

#[test]
fn no_backup_when_local_edit_was_already_pushed() {
    let mut rng = Lcg::new(12);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let m = rng.uuid();
    let mut payload = BTreeMap::new();
    payload.insert("body_content".into(), Value::String("v0".into()));
    a.insert(make_item(m, "manuscript", "user-a", payload))
        .unwrap();
    exchange(&a, &b, &mut rng, false);
    settle(&a, &b, &mut rng);

    // A's edit is PUSHED (outbox drained) before B's winning record lands:
    // nothing unconfirmed is at risk, so no backup revision.
    a.update(
        m,
        vec![FieldMutation::SetPayload(
            "body_content".into(),
            Value::String("pushed-draft".into()),
        )],
    )
    .unwrap();
    let batch_a = drain(&a); // pushed (and delivered below)
    sleep(Duration::from_millis(15));
    b.sync_apply_remote_items(batch_a.items.clone()).unwrap();
    b.update(
        m,
        vec![FieldMutation::SetPayload(
            "body_content".into(),
            Value::String("remote-final".into()),
        )],
    )
    .unwrap();

    let batch_b = drain(&b);
    let report = a.sync_apply_remote_items(batch_b.items.clone()).unwrap();
    assert_eq!(report.conflict_backups, 0, "pushed edits need no backup");
    assert!(manuscript_ops::list_revisions(&a, m).unwrap().is_empty());
}

#[test]
fn sync_metadata_roundtrip_and_namespace_guard() {
    let store = open_store("user-a");

    assert_eq!(store.sync_metadata_get("sync.change_token").unwrap(), None);
    store
        .sync_metadata_set("sync.change_token", Some("tok-1".into()))
        .unwrap();
    assert_eq!(
        store.sync_metadata_get("sync.change_token").unwrap(),
        Some("tok-1".into())
    );
    store.sync_metadata_set("sync.change_token", None).unwrap();
    assert_eq!(store.sync_metadata_get("sync.change_token").unwrap(), None);

    // Non-"sync." keys are rejected — the store's own metadata (origin_id,
    // hlc state, logical_clock) must be unreachable through this surface.
    assert!(matches!(
        store.sync_metadata_get("origin_id"),
        Err(StoreError::Validation(_))
    ));
    assert!(matches!(
        store.sync_metadata_set("hlc_counter", Some("0".into())),
        Err(StoreError::Validation(_))
    ));
}

#[test]
fn record_state_roundtrip_and_status_counts() {
    let mut rng = Lcg::new(13);
    let store = open_store("user-a");

    // Record-state blob lifecycle.
    assert_eq!(store.sync_record_state_get("rec-1").unwrap(), None);
    store
        .sync_record_state_set("rec-1", vec![1, 2, 3, 255])
        .unwrap();
    assert_eq!(
        store.sync_record_state_get("rec-1").unwrap(),
        Some(vec![1, 2, 3, 255])
    );
    store.sync_record_state_set("rec-1", vec![9]).unwrap();
    assert_eq!(store.sync_record_state_get("rec-1").unwrap(), Some(vec![9]));
    store.sync_record_state_delete("rec-1").unwrap();
    assert_eq!(store.sync_record_state_get("rec-1").unwrap(), None);

    // Status counts track the queues.
    let x = insert_paper(&store, &mut rng, "user-a", 1);
    let counts = store.sync_status_counts().unwrap();
    assert_eq!(counts.outbox, 1);
    assert_eq!(counts.pending_refs, 0);
    assert_eq!(counts.tombstones, 0);

    store.delete(x).unwrap();
    let counts = store.sync_status_counts().unwrap();
    assert_eq!(counts.outbox, 1, "delete supersedes the pending item push");
    assert_eq!(counts.tombstones, 1);
}

#[test]
fn bootstrap_apply_populates_fts() {
    let mut rng = Lcg::new(14);
    let a = open_store("user-a");
    let b = open_store("user-b");

    let id = rng.uuid();
    let mut payload = BTreeMap::new();
    payload.insert(
        "title".into(),
        Value::String("Neutrino Oscillations in Dense Media".into()),
    );
    a.insert(make_item(id, "test/paper", "user-a", payload))
        .unwrap();

    // Bootstrap: a fresh store applies the fetched records.
    let batch = drain(&a);
    apply(&batch, &b, &mut rng);

    let hits = b
        .query(&ItemQuery {
            predicates: vec![Predicate::Contains("title".into(), "neutrino".into())],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(hits.len(), 1, "applied records must be FTS-searchable");
    assert_eq!(hits[0].id, id);
}
