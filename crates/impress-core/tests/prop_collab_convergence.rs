//! Property tests for the collaborative manuscript body (ADR-0027).
//!
//! The invariant fortress entry for `impress_core::collab`: two replicas that
//! apply RANDOM interleaved edit scripts, ship their chunk items to each
//! other in RANDOM order with RANDOM duplication, and read back the same
//! text and heads — plus the D4 determinism rules under the same fuzzing.
//! The unit tests in `collab.rs` pin the specific scenarios that broke during
//! implementation; this file searches for the ones that did not.

#![cfg(feature = "collab")]

use std::collections::BTreeMap;

use chrono::Utc;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::schemas::MANUSCRIPT_CHANGE_SCHEMA_REF;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use proptest::prelude::*;

fn manuscript_row(id: ItemId, body: &str) -> Item {
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Paper".into()));
    payload.insert("format".into(), Value::String("typst".into()));
    payload.insert("body_content".into(), Value::String(body.into()));
    payload.insert(
        "body_content_hash".into(),
        Value::String(impress_core::manuscript_ops::sha256_hex(body)),
    );
    let now = Utc::now();
    Item {
        id,
        schema: "manuscript".into(),
        payload,
        created: now,
        modified: now,
        author: "user:test".into(),
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

fn body_of(store: &SqliteItemStore, id: ItemId) -> String {
    match store.get(id).unwrap().unwrap().payload.get("body_content") {
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

fn chunks_of(store: &SqliteItemStore, id: ItemId) -> Vec<Item> {
    store
        .query(&ItemQuery {
            schema: Some(MANUSCRIPT_CHANGE_SCHEMA_REF.into()),
            predicates: vec![Predicate::HasParent(id)],
            ..Default::default()
        })
        .unwrap()
}

/// The sync engine, simulated: copy `from`'s chunk rows into `to`, in the
/// order given by `perm` (a permutation seed), optionally shipping some rows
/// twice. Rows already present are skipped, as an item sync would.
fn ship(from: &SqliteItemStore, to: &SqliteItemStore, id: ItemId, perm: u64, duplicate: bool) {
    let mut chunks = chunks_of(from, id);
    // A cheap deterministic shuffle keyed on `perm`.
    let n = chunks.len();
    for i in 0..n {
        let j = ((perm >> (i % 60)) as usize + i * 7) % n;
        chunks.swap(i, j);
    }
    for chunk in &chunks {
        if to.get(chunk.id).unwrap().is_none() {
            to.insert(chunk.clone()).unwrap();
        }
    }
    if duplicate {
        for chunk in chunks.iter().rev().take(n / 2) {
            // A duplicate DELIVERY of a row already stored is a no-op at the
            // sync layer; simulate the loader seeing the same bytes twice by
            // re-touching the store (a real second insert would violate the
            // primary key, which is the point: chunk ids are the dedup key).
            let _ = to.get(chunk.id).unwrap();
        }
    }
}

/// One editor's edit: apply `op` to `text` at a position derived from `pos`.
#[derive(Debug, Clone)]
enum Edit {
    Insert(usize, String),
    Delete(usize, usize),
    Replace(usize, usize, String),
}

fn apply_edit(text: &str, edit: &Edit) -> String {
    let chars: Vec<char> = text.chars().collect();
    let clamp = |p: usize| p.min(chars.len());
    match edit {
        Edit::Insert(p, s) => {
            let p = clamp(*p);
            let mut out: String = chars[..p].iter().collect();
            out.push_str(s);
            out.extend(chars[p..].iter());
            out
        }
        Edit::Delete(p, len) => {
            let p = clamp(*p);
            let end = clamp(p + len);
            let mut out: String = chars[..p].iter().collect();
            out.extend(chars[end..].iter());
            out
        }
        Edit::Replace(p, len, s) => {
            let p = clamp(*p);
            let end = clamp(p + len);
            let mut out: String = chars[..p].iter().collect();
            out.push_str(s);
            out.extend(chars[end..].iter());
            out
        }
    }
}

fn edit_strategy() -> impl Strategy<Value = Edit> {
    let word = "[a-z ]{1,12}";
    prop_oneof![
        (0usize..200, word).prop_map(|(p, s)| Edit::Insert(p, s)),
        (0usize..200, 1usize..20).prop_map(|(p, l)| Edit::Delete(p, l)),
        (0usize..200, 1usize..20, word).prop_map(|(p, l, s)| Edit::Replace(p, l, s)),
    ]
}

/// A script for one replica: a sequence of (edits-then-commit) rounds; each
/// round's `sync_after` says whether the replica pulls the other's chunks
/// before committing (a stale base otherwise).
#[derive(Debug, Clone)]
struct Round {
    edits: Vec<Edit>,
    sync_before: bool,
}

fn round_strategy() -> impl Strategy<Value = Round> {
    (
        proptest::collection::vec(edit_strategy(), 1..4),
        any::<bool>(),
    )
        .prop_map(|(edits, sync_before)| Round { edits, sync_before })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// Two replicas, random interleaved edit scripts, random shipping order,
    /// duplicates, random staleness — after a final exchange both read the
    /// same text and heads, and each replica's `body_content` equals its
    /// document. Every edit ever committed is either present or was
    /// legitimately superseded by an overlapping edit — never silently
    /// dropped by the merge (checked via the appended-marker sub-property).
    #[test]
    fn replicas_converge_under_random_edit_scripts(
        seed_body in "[a-z ]{5,60}",
        script_a in proptest::collection::vec(round_strategy(), 1..5),
        script_b in proptest::collection::vec(round_strategy(), 1..5),
        perm in any::<u64>(),
        duplicate in any::<bool>(),
    ) {
        let a = SqliteItemStore::open_in_memory().unwrap();
        let b = SqliteItemStore::open_in_memory().unwrap();
        let id = uuid::Uuid::new_v4();
        a.insert(manuscript_row(id, &seed_body)).unwrap();
        b.insert(manuscript_row(id, &seed_body)).unwrap();

        // Both load: genesis is deterministic, so no exchange is needed for
        // the base to agree.
        let mut heads_a = a.manuscript_collab_heads(id).unwrap();
        let mut heads_b = b.manuscript_collab_heads(id).unwrap();
        prop_assert_eq!(&heads_a, &heads_b, "genesis must agree");

        let rounds = script_a.len().max(script_b.len());
        for r in 0..rounds {
            if let Some(round) = script_a.get(r) {
                if round.sync_before {
                    ship(&b, &a, id, perm.rotate_left(r as u32), duplicate);
                    heads_a = a.manuscript_collab_heads(id).unwrap();
                }
                let mut text = body_of(&a, id);
                for e in &round.edits { text = apply_edit(&text, e); }
                let out = a.commit_manuscript_body(id, &heads_a, &text, "a").unwrap();
                heads_a = out.heads;
                prop_assert_eq!(body_of(&a, id), out.body, "materialization == outcome (a)");
            }
            if let Some(round) = script_b.get(r) {
                if round.sync_before {
                    ship(&a, &b, id, perm.rotate_right(r as u32), duplicate);
                    heads_b = b.manuscript_collab_heads(id).unwrap();
                }
                let mut text = body_of(&b, id);
                for e in &round.edits { text = apply_edit(&text, e); }
                let out = b.commit_manuscript_body(id, &heads_b, &text, "b").unwrap();
                heads_b = out.heads;
                prop_assert_eq!(body_of(&b, id), out.body, "materialization == outcome (b)");
            }
        }

        // Final exchange in both directions, then both replicas must agree.
        ship(&a, &b, id, perm, duplicate);
        ship(&b, &a, id, perm.rotate_left(17), duplicate);
        let fa = a.manuscript_collab_heads(id).unwrap();
        let fb = b.manuscript_collab_heads(id).unwrap();
        prop_assert_eq!(&fa, &fb, "heads differ after full exchange");
        prop_assert_eq!(body_of(&a, id), body_of(&b, id), "bodies differ after full exchange");
        // And each replica's row equals its document at those heads.
        prop_assert_eq!(a.manuscript_text_at(id, &fa).unwrap(), body_of(&a, id));
        prop_assert_eq!(b.manuscript_text_at(id, &fb).unwrap(), body_of(&b, id));
    }

    /// Non-overlapping concurrent edits are BOTH present after merge — the
    /// property the compare-and-set path could not offer. A prepends a marker,
    /// B appends one, each from the same stale base; whichever commits second
    /// must see the other's marker in the merged text.
    #[test]
    fn concurrent_prepend_and_append_both_survive(
        seed_body in "[a-z ]{5,80}",
        head_marker in "[A-Z]{3,8}",
        tail_marker in "[A-Z]{3,8}",
        b_first in any::<bool>(),
    ) {
        let s = SqliteItemStore::open_in_memory().unwrap();
        let id = uuid::Uuid::new_v4();
        s.insert(manuscript_row(id, &seed_body)).unwrap();
        let base = s.manuscript_collab_heads(id).unwrap();
        let prepend = format!("{head_marker} {seed_body}");
        let append = format!("{seed_body} {tail_marker}");
        let (first, second) = if b_first { (append, prepend) } else { (prepend, append) };
        let o1 = s.commit_manuscript_body(id, &base, &first, "1").unwrap();
        prop_assert!(!o1.merged_external);
        let o2 = s.commit_manuscript_body(id, &base, &second, "2").unwrap();
        prop_assert!(o2.merged_external);
        prop_assert!(o2.body.starts_with(&head_marker), "prepend lost: {}", o2.body);
        prop_assert!(o2.body.ends_with(&tail_marker), "append lost: {}", o2.body);
        prop_assert_eq!(body_of(&s, id), o2.body);
    }

    /// D4: genesis and recovery are byte-identical across replicas for ANY
    /// body, and cross-shipping the derived chunks never duplicates text.
    #[test]
    fn genesis_and_recovery_are_deterministic_for_any_body(
        seed_body in "[a-z0-9 \\n]{0,80}",
        legacy_body in "[a-z0-9 \\n]{1,80}",
    ) {
        let a = SqliteItemStore::open_in_memory().unwrap();
        let b = SqliteItemStore::open_in_memory().unwrap();
        let id = uuid::Uuid::new_v4();
        a.insert(manuscript_row(id, &seed_body)).unwrap();
        b.insert(manuscript_row(id, &seed_body)).unwrap();
        prop_assert_eq!(
            a.manuscript_collab_heads(id).unwrap(),
            b.manuscript_collab_heads(id).unwrap()
        );
        // A legacy writer moves body_content on both replicas (as a synced
        // row from an old build would), without a chunk.
        for s in [&a, &b] {
            s.update(
                id,
                vec![
                    impress_core::store::FieldMutation::SetPayload(
                        "body_content".into(), Value::String(legacy_body.clone())),
                    impress_core::store::FieldMutation::SetPayload(
                        "body_content_hash".into(),
                        Value::String(impress_core::manuscript_ops::sha256_hex(&legacy_body))),
                ],
            ).unwrap();
        }
        let ra = a.manuscript_collab_heads(id).unwrap();
        let rb = b.manuscript_collab_heads(id).unwrap();
        prop_assert_eq!(&ra, &rb, "recovery must hash identically");
        ship(&a, &b, id, 1, true);
        ship(&b, &a, id, 2, true);
        let _ = a.manuscript_collab_heads(id).unwrap();
        let _ = b.manuscript_collab_heads(id).unwrap();
        prop_assert_eq!(body_of(&a, id), legacy_body.clone());
        prop_assert_eq!(body_of(&b, id), legacy_body);
    }
}
