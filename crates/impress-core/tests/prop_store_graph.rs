//! Property tests for the impress-core item graph against real SQLite stores
//! (in-memory and file-backed), encoding the invariants ADR-0001/0002/0005
//! build on:
//!
//!  1. SetPayload sequences are last-write-wins per field; operations on
//!     different fields commute across interleavings.
//!  2. Task state transitions (ADR-0005 section 2) recorded as operations
//!     form an authoritative, replayable history (time-travel per section 3).
//!     NOTE: impress-core does NOT enforce transition legality — see
//!     `state_transitions_are_not_enforced_by_store`.
//!  4. Item + edge graphs round-trip exactly, including across reopen.
//!  5. FTS finds items by their exact tokens; deleted items are gone.
//!  6. The "ready" set of a task DAG computed from store reads matches an
//!     independent in-memory model.
//!
//! Run with: cargo test -p impress-core --features sqlite

#![cfg(feature = "sqlite")]

use std::collections::{BTreeMap, BTreeSet};

use chrono::Utc;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier, StateAsOf};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::store::ItemStore;
use impress_core::SqliteItemStore;
use proptest::prelude::*;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_item(schema: &str, payload: BTreeMap<String, Value>) -> Item {
    Item {
        id: Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: "prop-test".into(),
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
    }
}

fn task_item(title: &str, state: &str) -> Item {
    let mut payload = BTreeMap::new();
    payload.insert("title".to_string(), Value::String(title.to_string()));
    payload.insert("state".to_string(), Value::String(state.to_string()));
    make_item("task", payload)
}

fn set_payload_spec(target: ItemId, field: &str, value: Value) -> OperationSpec {
    OperationSpec {
        target_id: target,
        op_type: OperationType::SetPayload(field.to_string(), value),
        intent: OperationIntent::Routine,
        reason: None,
        batch_id: None,
        author: "impel-agent".to_string(),
        author_kind: ActorKind::Agent,
        retention: RetentionTier::Durable,
    }
}

fn add_reference_spec(source: ItemId, target: ItemId, edge: EdgeType) -> OperationSpec {
    OperationSpec {
        target_id: source,
        op_type: OperationType::AddReference(TypedReference {
            target,
            edge_type: edge,
            metadata: None,
        }),
        intent: OperationIntent::Routine,
        reason: None,
        batch_id: None,
        author: "prop-test".to_string(),
        author_kind: ActorKind::System,
        retention: RetentionTier::Durable,
    }
}

fn payload_str(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

const EDGE_KINDS: [EdgeType; 3] = [EdgeType::DependsOn, EdgeType::ProducedBy, EdgeType::OperatesOn];

// ---------------------------------------------------------------------------
// Property 1: SetPayload — last-write-wins per field, commutes across fields
// ---------------------------------------------------------------------------

const FIELD_POOL: [&str; 4] = ["alpha", "beta", "gamma", "delta"];

fn arb_scalar() -> impl Strategy<Value = Value> {
    prop_oneof![
        any::<i64>().prop_map(Value::Int),
        any::<bool>().prop_map(Value::Bool),
        ".{0,10}".prop_map(Value::String),
    ]
}

/// Per-field value sequences plus TWO independently shuffled interleavings.
/// Each interleaving is a vector of field indices in which every field's
/// occurrences appear exactly seqs[f].len() times; consuming a field's values
/// in order at its occurrence positions preserves per-field order while
/// arbitrarily interleaving distinct fields.
fn arb_interleavings() -> impl Strategy<Value = (Vec<Vec<Value>>, Vec<usize>, Vec<usize>)> {
    prop::collection::vec(prop::collection::vec(arb_scalar(), 1..=4), 2..=4).prop_flat_map(|seqs| {
        let labels: Vec<usize> = seqs
            .iter()
            .enumerate()
            .flat_map(|(i, s)| std::iter::repeat(i).take(s.len()))
            .collect();
        let labels2 = labels.clone();
        (Just(seqs), Just(labels).prop_shuffle(), Just(labels2).prop_shuffle())
    })
}

/// Apply the ops in the given interleaved order on a fresh store; return the
/// final payload restricted to the pool fields.
fn apply_interleaving(seqs: &[Vec<Value>], order: &[usize]) -> BTreeMap<String, Value> {
    let store = SqliteItemStore::open_in_memory().expect("open in-memory store");
    let item = task_item("lww-probe", "pending");
    let id = item.id;
    store.insert(item).expect("insert");

    let mut cursors = vec![0usize; seqs.len()];
    for &f in order {
        let v = seqs[f][cursors[f]].clone();
        cursors[f] += 1;
        store
            .apply_operation(set_payload_spec(id, FIELD_POOL[f], v))
            .expect("apply_operation");
    }

    let after = store.get(id).expect("get").expect("item exists");
    FIELD_POOL
        .iter()
        .filter_map(|f| after.payload.get(*f).map(|v| (f.to_string(), v.clone())))
        .collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// Applying any interleaving of per-field SetPayload sequences yields the
    /// last value of each field's own sequence (LWW per field), and two
    /// different interleavings that preserve per-field order yield identical
    /// final payloads (cross-field commutativity).
    #[test]
    fn setpayload_lww_per_field_commutes_across_fields(
        (seqs, order_a, order_b) in arb_interleavings()
    ) {
        let final_a = apply_interleaving(&seqs, &order_a);
        let final_b = apply_interleaving(&seqs, &order_b);

        for (f, seq) in seqs.iter().enumerate() {
            let expected = seq.last().unwrap();
            prop_assert_eq!(
                final_a.get(FIELD_POOL[f]), Some(expected),
                "field {} should hold its last-written value", FIELD_POOL[f]
            );
        }
        prop_assert_eq!(final_a, final_b, "interleavings differing only across fields must commute");
    }
}

// ---------------------------------------------------------------------------
// Property 2: task state machine — operation stream as authoritative history
// ---------------------------------------------------------------------------

/// Allowed transitions per ADR-0005 section 2.
fn legal_next_states(state: &str) -> &'static [&'static str] {
    match state {
        "pending" => &["running", "cancelled"],
        "running" => &["done", "failed", "cancelled", "pending"],
        _ => &[], // done / failed / cancelled are terminal
    }
}

/// Generate a legal transition sequence starting from "pending".
fn arb_legal_state_seq() -> impl Strategy<Value = Vec<&'static str>> {
    prop::collection::vec(any::<u8>(), 0..10).prop_map(|choices| {
        let mut state = "pending";
        let mut seq = Vec::new();
        for c in choices {
            let opts = legal_next_states(state);
            if opts.is_empty() {
                break;
            }
            state = opts[c as usize % opts.len()];
            seq.push(state);
        }
        seq
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// For any legal transition sequence: the materialized state equals the
    /// last transition, `operations_for` returns exactly the transition
    /// operations in order, and time-travel (`effective_state` at each op's
    /// logical clock) reconstructs every intermediate state (ADR-0005 §3).
    #[test]
    fn state_transition_history_is_authoritative(seq in arb_legal_state_seq()) {
        let store = SqliteItemStore::open_in_memory().expect("open store");
        let task = task_item("state-probe", "pending");
        let task_id = task.id;
        store.insert(task).expect("insert task");

        let mut op_clocks = Vec::new();
        for s in &seq {
            let op_id = store
                .apply_operation(set_payload_spec(task_id, "state", Value::String(s.to_string())))
                .expect("transition op accepted");
            let op_item = store.get(op_id).expect("get op").expect("op item exists");
            prop_assert_eq!(op_item.schema.as_str(), "core/operation");
            op_clocks.push(op_item.logical_clock);
        }

        // Materialized state == last transition (or creation state).
        let current = store.get(task_id).expect("get").expect("exists");
        let expected_final = seq.last().copied().unwrap_or("pending");
        let current_state = payload_str(&current, "state");
        prop_assert_eq!(current_state.as_deref(), Some(expected_final));

        // Operation stream is the full ordered history.
        let ops = store.operations_for(task_id, None).expect("operations_for");
        let recorded: Vec<String> = ops
            .iter()
            .filter_map(|op| match op.payload.get("op_data") {
                Some(Value::Object(m)) => match (m.get("field"), m.get("value")) {
                    (Some(Value::String(f)), Some(Value::String(v))) if f == "state" => {
                        Some(v.clone())
                    }
                    _ => None,
                },
                _ => None,
            })
            .collect();
        let expected_seq: Vec<String> = seq.iter().map(|s| s.to_string()).collect();
        prop_assert_eq!(recorded, expected_seq, "operation stream must record every transition in order");

        // Time-travel: state at each op's clock is the state after that prefix.
        for (k, clock) in op_clocks.iter().enumerate() {
            let st = store
                .effective_state(task_id, StateAsOf::LogicalClock(*clock))
                .expect("effective_state")
                .expect("state exists");
            prop_assert_eq!(
                match st.payload.get("state") { Some(Value::String(s)) => Some(s.as_str()), _ => None },
                Some(seq[k]),
                "time-travel to clock of op {} must yield state {}", k, seq[k]
            );
        }
    }

    /// ENFORCEMENT GAP (documented, not a failure): impress-core accepts ANY
    /// state string via SetPayload("state", ...) — including transitions
    /// outside the ADR-0005 §2 allowed set and states outside the enum
    /// entirely. Legality is currently impel's responsibility (ADR-0005 §6).
    /// This property pins the current totality behavior: arbitrary state
    /// writes never panic, never corrupt the item, and always materialize
    /// last-write-wins. If impress-core ever grows transition enforcement,
    /// this test will fail and should be rewritten against the new API.
    #[test]
    fn state_transitions_are_not_enforced_by_store(
        states in prop::collection::vec(
            prop_oneof![
                prop::sample::select(vec!["pending", "running", "done", "failed", "cancelled"])
                    .prop_map(|s| s.to_string()),
                "[a-z]{0,8}",
            ],
            1..6,
        )
    ) {
        let store = SqliteItemStore::open_in_memory().expect("open store");
        let task = task_item("gap-probe", "done"); // terminal from the start
        let task_id = task.id;
        store.insert(task).expect("insert");

        for s in &states {
            // Even done -> running (illegal per ADR-0005 §2) is accepted.
            let res = store.apply_operation(set_payload_spec(task_id, "state", Value::String(s.clone())));
            prop_assert!(res.is_ok(), "store rejected state write '{}': {:?}", s, res.err());
        }
        let current = store.get(task_id).expect("get").expect("exists");
        prop_assert_eq!(payload_str(&current, "state"), states.last().cloned());
    }
}

// ---------------------------------------------------------------------------
// Property 4: edge/store round-trip, including reopen from disk
// ---------------------------------------------------------------------------

type EdgeSpec = (usize, usize, usize, bool); // (source, target, edge kind idx, insert_time)

fn arb_graph() -> impl Strategy<Value = (usize, Vec<EdgeSpec>)> {
    (2usize..=6).prop_flat_map(|n| {
        (
            Just(n),
            prop::collection::vec((0..n, 0..n, 0..EDGE_KINDS.len(), any::<bool>()), 0..12),
        )
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(24))]

    /// Items + typed edges (DependsOn / ProducedBy / OperatesOn) written via
    /// both insert-time references and AddReference operations read back as
    /// exactly the deduplicated set that was written — no loss, no
    /// duplication — through get(), through neighbors(), and again after
    /// closing and reopening the store file.
    #[test]
    fn edge_graph_round_trips_and_survives_reopen((n, edges) in arb_graph()) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("graph.sqlite3");

        // Expected edge set after dedup on (source, target, kind).
        let expected: BTreeSet<(usize, usize, usize)> = edges
            .iter()
            .filter(|(s, t, _, _)| s != t)
            .map(|(s, t, k, _)| (*s, *t, *k))
            .collect();

        let mut ids: Vec<ItemId> = Vec::with_capacity(n);
        {
            let store = SqliteItemStore::open(&path).expect("open file store");

            // Insert nodes in index order. Edges flagged insert-time whose
            // target is already inserted (t < s) ride on the item itself;
            // everything else is added via apply_operation afterwards.
            for i in 0..n {
                let mut item = task_item(&format!("node-{}", i), "pending");
                for (s, t, k, at_insert) in &edges {
                    if *s == i && *at_insert && t < s {
                        item.references.push(TypedReference {
                            target: ids[*t],
                            edge_type: EDGE_KINDS[*k].clone(),
                            metadata: None,
                        });
                    }
                }
                ids.push(item.id);
                store.insert(item).expect("insert node");
            }
            for (s, t, k, at_insert) in &edges {
                if s == t || (*at_insert && t < s) {
                    continue;
                }
                store
                    .apply_operation(add_reference_spec(ids[*s], ids[*t], EDGE_KINDS[*k].clone()))
                    .expect("add reference op");
            }

            verify_graph(&store, &ids, &expected)?;
        } // store dropped, file closed

        // Reopen from disk: the graph must be byte-for-byte the same.
        let reopened = SqliteItemStore::open(&path).expect("reopen file store");
        verify_graph(&reopened, &ids, &expected)?;
    }
}

fn verify_graph(
    store: &SqliteItemStore,
    ids: &[ItemId],
    expected: &BTreeSet<(usize, usize, usize)>,
) -> Result<(), TestCaseError> {
    let index_of = |id: ItemId| ids.iter().position(|x| *x == id).expect("known id");
    let kind_of = |e: &EdgeType| EDGE_KINDS.iter().position(|k| k == e).expect("known kind");

    // Via get(): full multiset of stored references (as a set + count check
    // to also rule out duplication).
    let mut got = BTreeSet::new();
    let mut total = 0usize;
    for (i, id) in ids.iter().enumerate() {
        let item = store.get(*id).map_err(|e| TestCaseError::fail(e.to_string()))?
            .ok_or_else(|| TestCaseError::fail("node lost"))?;
        for r in &item.references {
            got.insert((i, index_of(r.target), kind_of(&r.edge_type)));
            total += 1;
        }
    }
    prop_assert_eq!(&got, expected, "reference sets differ");
    prop_assert_eq!(total, expected.len(), "duplicate edges stored");

    // Via neighbors(): depth-1 traversal per edge kind. neighbors() is
    // UNDIRECTED by implementation (follows outgoing AND incoming edges), so
    // the expected set is targets of outgoing plus sources of incoming edges.
    for (i, id) in ids.iter().enumerate() {
        for (k, kind) in EDGE_KINDS.iter().enumerate() {
            let want: BTreeSet<ItemId> = expected
                .iter()
                .filter_map(|(s, t, ek)| {
                    if *ek != k {
                        None
                    } else if *s == i {
                        Some(ids[*t])
                    } else if *t == i {
                        Some(ids[*s])
                    } else {
                        None
                    }
                })
                .filter(|nid| *nid != *id) // self not reported
                .collect();
            let got: BTreeSet<ItemId> = store
                .neighbors(*id, &[kind.clone()], 1)
                .map_err(|e| TestCaseError::fail(e.to_string()))?
                .into_iter()
                .map(|it| it.id)
                .collect();
            prop_assert_eq!(got, want, "neighbors mismatch for node {} kind {:?}", i, kind);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Property 5: FTS consistency
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// Items created with FTS-indexed fields (title) are findable by their
    /// exact unique token, only that item matches, and deleted items are no
    /// longer findable while surviving items still are.
    #[test]
    fn fts_finds_exact_tokens_and_forgets_deleted(
        salt in "[a-z]{3}",
        prefixes in prop::collection::vec("[a-zA-Z]{1,8}", 1..=5),
        delete_mask in prop::collection::vec(any::<bool>(), 5),
    ) {
        let store = SqliteItemStore::open_in_memory().expect("open store");
        let n = prefixes.len();
        let tokens: Vec<String> = (0..n).map(|i| format!("zq{}tok{}", salt, i)).collect();

        let mut ids = Vec::new();
        for (i, prefix) in prefixes.iter().enumerate() {
            let mut payload = BTreeMap::new();
            payload.insert("title".to_string(), Value::String(format!("{} {}", prefix, tokens[i])));
            payload.insert("state".to_string(), Value::String("pending".to_string()));
            let item = make_item("task", payload);
            ids.push(item.id);
            store.insert(item).expect("insert");
        }

        let search = |token: &str| -> Vec<ItemId> {
            let q = ItemQuery {
                predicates: vec![Predicate::Contains("title".to_string(), token.to_string())],
                ..Default::default()
            };
            store.query(&q).expect("fts query").into_iter().map(|i| i.id).collect()
        };

        for i in 0..n {
            prop_assert_eq!(search(&tokens[i]), vec![ids[i]], "token {} must find exactly its item", i);
        }

        // Delete a subset; deleted items must vanish from FTS, others remain.
        for i in 0..n {
            if delete_mask[i] {
                store.delete(ids[i]).expect("delete");
            }
        }
        for i in 0..n {
            let found = search(&tokens[i]);
            if delete_mask[i] {
                prop_assert!(found.is_empty(), "deleted item {} still findable via FTS", i);
            } else {
                prop_assert_eq!(found, vec![ids[i]], "surviving item {} lost from FTS", i);
            }
        }
    }
}

/// BUG TRIPWIRE: the FTS index is written only by `insert_item` and cleared
/// only by `delete` — `materialize_operation(SetPayload)` never refreshes
/// `items_fts`. After updating an FTS-indexed field (e.g. title) via a
/// SetPayload operation (the canonical ADR-0002 mutation path, also used by
/// `ItemStore::update`), full-text search still matches the OLD title and
/// does not match the NEW one.
#[test]
#[ignore = "BUG: items_fts not updated on SetPayload/update — FTS matches stale title after payload mutation (update_fts only called from insert_item)"]
fn fts_reflects_payload_updates() {
    let store = SqliteItemStore::open_in_memory().expect("open store");
    let item = task_item("aardvarkzz original", "pending");
    let id = item.id;
    store.insert(item).expect("insert");

    store
        .apply_operation(set_payload_spec(id, "title", Value::String("bumblebeezz updated".into())))
        .expect("update title");

    let search = |token: &str| -> Vec<ItemId> {
        let q = ItemQuery {
            predicates: vec![Predicate::Contains("title".to_string(), token.to_string())],
            ..Default::default()
        };
        store.query(&q).expect("query").into_iter().map(|i| i.id).collect()
    };

    // The materialized item has the new title...
    let current = store.get(id).expect("get").expect("exists");
    assert_eq!(payload_str(&current, "title").as_deref(), Some("bumblebeezz updated"));

    // ...so FTS must find the new token and not the old one.
    assert_eq!(search("bumblebeezz"), vec![id], "new title token not findable after SetPayload");
    assert!(search("aardvarkzz").is_empty(), "stale title token still matches after SetPayload");
}

// ---------------------------------------------------------------------------
// Property 6: DAG precondition ("ready") query matches independent model
// ---------------------------------------------------------------------------

const TASK_STATES: [&str; 5] = ["pending", "running", "done", "failed", "cancelled"];

fn arb_task_dag() -> impl Strategy<Value = (Vec<usize>, BTreeSet<(usize, usize)>)> {
    (1usize..=9).prop_flat_map(|n| {
        (
            prop::collection::vec(0..TASK_STATES.len(), n..=n),
            // DependsOn edges i -> j with j < i guarantee acyclicity.
            prop::collection::btree_set(
                (1..n.max(2), 0..n.max(2) - 1).prop_filter("j < i", |(i, j)| j < i),
                0..(n * 2).min(14),
            ),
        )
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// For a random task DAG with random states, the "ready" set computed
    /// entirely from store reads (query for pending tasks, follow their
    /// DependsOn references, check each dependency's state — exactly the
    /// impel scheduling walk from ADR-0005 §4) equals the ready set of an
    /// independent in-memory model: pending tasks whose deps are all "done".
    #[test]
    fn dag_ready_set_matches_model((state_idx, deps) in arb_task_dag()) {
        let n = state_idx.len();
        let deps: BTreeSet<(usize, usize)> =
            deps.into_iter().filter(|(i, j)| *i < n && *j < n).collect();

        let store = SqliteItemStore::open_in_memory().expect("open store");
        let mut ids = Vec::with_capacity(n);
        for i in 0..n {
            let mut item = task_item(&format!("task-{}", i), TASK_STATES[state_idx[i]]);
            for (s, t) in &deps {
                if *s == i {
                    item.references.push(TypedReference {
                        target: ids[*t], // t < s == i, already inserted
                        edge_type: EdgeType::DependsOn,
                        metadata: None,
                    });
                }
            }
            ids.push(item.id);
            store.insert(item).expect("insert task");
        }

        // Model: pending tasks whose DependsOn targets are all "done".
        let model_ready: BTreeSet<ItemId> = (0..n)
            .filter(|i| TASK_STATES[state_idx[*i]] == "pending")
            .filter(|i| {
                deps.iter()
                    .filter(|(s, _)| s == i)
                    .all(|(_, t)| TASK_STATES[state_idx[*t]] == "done")
            })
            .map(|i| ids[i])
            .collect();

        // Store walk: query pending task items, then check dependency states.
        let pending_q = ItemQuery {
            schema: Some("task".to_string()),
            predicates: vec![Predicate::Eq("state".to_string(), Value::String("pending".to_string()))],
            ..Default::default()
        };
        let pending = store.query(&pending_q).expect("query pending");

        // Cross-check the query itself against the model's pending set.
        let model_pending: BTreeSet<ItemId> = (0..n)
            .filter(|i| TASK_STATES[state_idx[*i]] == "pending")
            .map(|i| ids[i])
            .collect();
        let got_pending: BTreeSet<ItemId> = pending.iter().map(|t| t.id).collect();
        prop_assert_eq!(&got_pending, &model_pending, "pending query mismatch");

        let mut store_ready = BTreeSet::new();
        for task in &pending {
            let all_deps_done = task
                .references
                .iter()
                .filter(|r| r.edge_type == EdgeType::DependsOn)
                .all(|r| {
                    let dep = store.get(r.target).expect("get dep").expect("dep exists");
                    payload_str(&dep, "state").as_deref() == Some("done")
                });
            if all_deps_done {
                store_ready.insert(task.id);
            }
        }
        prop_assert_eq!(store_ready, model_ready, "ready set mismatch");
    }
}
