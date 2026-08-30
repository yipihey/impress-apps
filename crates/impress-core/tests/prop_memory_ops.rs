//! Property tests for the memory kernel (`impress_core::memory_ops`).
//!
//! Three properties, each covering a failure this kernel exists to prevent:
//!
//!  1. **The gate is idempotent.** Remembering the same thing repeatedly
//!     through `gate_fts` + insert-or-confirm yields ONE row, however many
//!     times it is remembered, and the repetitions land as `confirmations`.
//!     Memory's characteristic failure is not forgetting — it is storing forty
//!     paraphrases of one fact until recall returns nothing else.
//!  2. **Supersession is a real retraction.** Over random supersession DAGs,
//!     `recall` never returns a memory something supersedes, unless the caller
//!     explicitly asked for them. A superseded fact re-asserting itself is
//!     worse than no memory at all.
//!  3. **Ranking is a function.** `rank_memory_candidates` is deterministic
//!     under input permutation, total, and tie-broken by ascending id — the
//!     discipline that lets a golden test over a ranked list exist.
//!
//! Run with: cargo test -p impress-core --features sqlite

#![cfg(feature = "sqlite")]

use std::collections::BTreeSet;

use impress_core::item::{ActorKind, ItemId, Value};
use impress_core::memory_ops::{
    self, GateOutcome, MemoryCandidate, MemoryDraft, MemoryKind, MemoryWeights, RecallOptions,
    GATE_CONFIRM_THRESHOLD, MAX_RECALL_LIMIT,
};
use impress_core::store::{FieldMutation, ItemStore};
use impress_core::SqliteItemStore;
use proptest::prelude::*;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open() -> SqliteItemStore {
    SqliteItemStore::open_in_memory().expect("open in-memory store")
}

/// The full write path a caller uses: gate first, then insert or confirm.
/// This is the composition the first property is about — neither half is
/// idempotent alone.
fn remember(store: &SqliteItemStore, draft: &MemoryDraft) -> ItemId {
    match memory_ops::gate_fts(store, draft, GATE_CONFIRM_THRESHOLD).expect("gate") {
        GateOutcome::Insert => memory_ops::insert_memory_item(store, draft).expect("insert"),
        GateOutcome::Confirm(existing) => {
            memory_ops::confirm(store, existing, &draft.author, draft.author_kind)
                .expect("confirm");
            existing
        }
    }
}

fn draft(title: &str, body: &str) -> MemoryDraft {
    MemoryDraft::new(
        MemoryKind::Claim,
        title,
        body,
        "prop-test",
        ActorKind::Agent,
    )
}

fn claim_count(store: &SqliteItemStore) -> usize {
    store
        .query(&impress_core::query::ItemQuery {
            schema: Some(MemoryKind::Claim.schema_ref().to_string()),
            ..Default::default()
        })
        .expect("query claims")
        .len()
}

fn confirmations(store: &SqliteItemStore, id: ItemId) -> i64 {
    match store
        .get(id)
        .expect("get")
        .expect("item present")
        .payload
        .get("confirmations")
    {
        Some(Value::Int(n)) => *n,
        _ => 0,
    }
}

/// A vocabulary with no FTS operators and no punctuation, so every generated
/// body is a valid search probe and the property is testing the gate rather
/// than the sanitizer (which `search_ops` covers on its own).
const WORDS: [&str; 24] = [
    "flux",
    "column",
    "catalogue",
    "millijansky",
    "aperture",
    "correction",
    "zero",
    "point",
    "pipeline",
    "checkpoint",
    "container",
    "manuscript",
    "citation",
    "rotation",
    "curve",
    "spectrum",
    "calibration",
    "residual",
    "seed",
    "convergence",
    "threshold",
    "binding",
    "outline",
    "toolchain",
];

/// 6–14 words drawn from [`WORDS`]. Long enough that Jaccard overlap is a
/// meaningful signal, short enough that the FTS probe is not truncated.
fn body_strategy() -> impl Strategy<Value = String> {
    prop::collection::vec(0usize..WORDS.len(), 6..15)
        .prop_map(|idx| idx.iter().map(|i| WORDS[*i]).collect::<Vec<_>>().join(" "))
}

// ---------------------------------------------------------------------------
// 1. Gate idempotency
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// Remembering ONE memory `repeats` times writes ONE row, and the extra
    /// observations land as confirmations rather than as rows.
    ///
    /// The title is varied on every pass on purpose: two agents describing the
    /// same fact will not choose the same label, and a gate that only
    /// recognises identical titles would not catch a single real duplicate.
    #[test]
    fn remembering_the_same_body_repeatedly_yields_one_row(
        body in body_strategy(),
        repeats in 2usize..6,
    ) {
        let store = open();
        let mut ids = BTreeSet::new();
        for pass in 0..repeats {
            ids.insert(remember(&store, &draft(&format!("pass {pass}"), &body)));
        }

        prop_assert_eq!(ids.len(), 1, "one memory, remembered {} times", repeats);
        prop_assert_eq!(claim_count(&store), 1);

        let id = *ids.iter().next().unwrap();
        prop_assert_eq!(
            confirmations(&store, id),
            (repeats - 1) as i64,
            "every repetition after the first is a confirmation"
        );
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(32))]

    /// The same property over a MIXED stream: whatever the interleaving, the
    /// store never holds more rows than there were distinct bodies, and every
    /// body is recoverable.
    ///
    /// The bound is one-sided deliberately. Two *different* random bodies can
    /// legitimately be near-duplicates of each other (they are drawn from a
    /// 24-word vocabulary), and merging those is the gate working, not
    /// failing. What must never happen is the opposite: one body producing two
    /// rows.
    #[test]
    fn a_mixed_stream_never_grows_past_its_distinct_bodies(
        bodies in prop::collection::vec(body_strategy(), 1..6),
        rounds in 1usize..4,
    ) {
        let store = open();
        let distinct: BTreeSet<&String> = bodies.iter().collect();

        for round in 0..rounds {
            for (n, body) in bodies.iter().enumerate() {
                remember(&store, &draft(&format!("r{round} b{n}"), body));
            }
        }

        prop_assert!(
            claim_count(&store) <= distinct.len(),
            "{} rows for {} distinct bodies",
            claim_count(&store),
            distinct.len()
        );
        prop_assert!(claim_count(&store) >= 1);

        // And nothing was lost: every distinct body still resolves to a row.
        for body in &distinct {
            let outcome = memory_ops::gate_fts(
                &store,
                &draft("probe", body),
                GATE_CONFIRM_THRESHOLD,
            )
            .expect("gate");
            prop_assert!(
                matches!(outcome, GateOutcome::Confirm(_)),
                "a body already remembered must gate to Confirm: {body:?}"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// 2. Supersession hides, and only `include_superseded` unhides
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(32))]

    /// Over a random supersession DAG, `recall` returns exactly the heads.
    ///
    /// Edges are generated from a later row to an earlier one, which makes the
    /// graph acyclic by construction — chains (`c → b → a`), fans (two rows
    /// superseding one) and forks (one row superseding two) all arise from
    /// that shape, and every one of them must hide its targets.
    #[test]
    fn recall_never_returns_a_superseded_memory(
        n in 2usize..9,
        edge_seeds in prop::collection::vec((0usize..64, 0usize..64), 0..10),
    ) {
        let store = open();
        // Every body shares a token, so ONE query reaches all of them and the
        // property is about the head filter rather than about retrieval.
        let ids: Vec<ItemId> = (0..n)
            .map(|i| {
                memory_ops::insert_memory_item(
                    &store,
                    &draft(&format!("memory {i}"), &format!("seedword calibration note {i}")),
                )
                .expect("insert")
            })
            .collect();

        let mut superseded: BTreeSet<ItemId> = BTreeSet::new();
        for (a, b) in edge_seeds {
            let old = a % n;
            let new = b % n;
            // Later supersedes earlier: acyclic by construction.
            let (old, new) = if old < new { (old, new) } else if new < old { (new, old) } else { continue };
            memory_ops::supersede(
                &store,
                ids[old],
                ids[new],
                Some("prop"),
                "prop-test",
                ActorKind::Agent,
            )
            .expect("supersede");
            superseded.insert(ids[old]);
        }

        let expected_heads: BTreeSet<ItemId> =
            ids.iter().copied().filter(|id| !superseded.contains(id)).collect();

        for query in ["seedword", ""] {
            let recalled: BTreeSet<ItemId> = memory_ops::recall(
                &store,
                query,
                &RecallOptions { limit: MAX_RECALL_LIMIT, ..Default::default() },
            )
            .expect("recall")
            .iter()
            .map(|e| e.id.parse().expect("uuid"))
            .collect();

            prop_assert_eq!(
                &recalled,
                &expected_heads,
                "query {:?}: recall must return exactly the heads",
                query
            );

            let widened: BTreeSet<ItemId> = memory_ops::recall(
                &store,
                query,
                &RecallOptions {
                    limit: MAX_RECALL_LIMIT,
                    include_superseded: true,
                    ..Default::default()
                },
            )
            .expect("recall")
            .iter()
            .map(|e| e.id.parse().expect("uuid"))
            .collect();

            prop_assert_eq!(
                widened,
                ids.iter().copied().collect::<BTreeSet<ItemId>>(),
                "query {:?}: include_superseded must return everything",
                query
            );
        }

        // `claim_heads` is the SQL-side spelling of the same predicate and
        // must agree with the Rust-side filter recall applies.
        let heads: BTreeSet<ItemId> =
            memory_ops::claim_heads(&store, MemoryKind::Claim.schema_ref(), MAX_RECALL_LIMIT)
                .expect("heads")
                .into_iter()
                .collect();
        prop_assert_eq!(heads, expected_heads);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(24))]

    /// `no_recall` is the OTHER way a memory leaves the working set, and it is
    /// independent of supersession: `include_superseded` must not lift it.
    #[test]
    fn no_recall_is_never_lifted_by_include_superseded(
        n in 1usize..7,
        withheld_seeds in prop::collection::vec(0usize..64, 0..7),
    ) {
        let store = open();
        let ids: Vec<ItemId> = (0..n)
            .map(|i| {
                memory_ops::insert_memory_item(
                    &store,
                    &draft(&format!("memory {i}"), &format!("seedword residual note {i}")),
                )
                .expect("insert")
            })
            .collect();

        let mut withheld: BTreeSet<ItemId> = BTreeSet::new();
        for seed in withheld_seeds {
            let id = ids[seed % n];
            if withheld.insert(id) {
                store
                    .update(
                        id,
                        vec![FieldMutation::SetPayload("no_recall".into(), Value::Bool(true))],
                    )
                    .expect("withhold");
            }
        }

        for include_superseded in [false, true] {
            let recalled: BTreeSet<ItemId> = memory_ops::recall(
                &store,
                "seedword",
                &RecallOptions {
                    limit: MAX_RECALL_LIMIT,
                    include_superseded,
                    ..Default::default()
                },
            )
            .expect("recall")
            .iter()
            .map(|e| e.id.parse().expect("uuid"))
            .collect();

            prop_assert!(
                recalled.is_disjoint(&withheld),
                "include_superseded={include_superseded} leaked a withheld memory"
            );
            prop_assert_eq!(recalled.len(), n - withheld.len());
        }
    }
}

// ---------------------------------------------------------------------------
// 3. Ranking is a deterministic, id-tie-broken function
// ---------------------------------------------------------------------------

prop_compose! {
    /// A candidate whose id is derived from its index, so ids are unique and
    /// their ORDER is known independently of the scores.
    fn candidate_strategy(index: usize)(
        fts in prop::option::of(0.0f32..50.0),
        vector in prop::option::of(0.0f32..1.0),
        confirmations in 0u32..40,
        age_ms in 0i64..90_000_000_000,
        human in any::<bool>(),
        confidence in prop::option::of(0.0f32..1.0),
    ) -> MemoryCandidate {
        MemoryCandidate {
            id: format!("{index:04}"),
            fts_score: fts,
            vector_similarity: vector,
            confirmations,
            modified_ms: -age_ms,
            author_kind_human: human,
            confidence,
        }
    }
}

fn candidates_strategy() -> impl Strategy<Value = Vec<MemoryCandidate>> {
    // `Vec<S: Strategy>` is itself a Strategy producing `Vec<S::Value>`, so
    // one strategy per index gives unique ids without a post-hoc dedup.
    (1usize..12).prop_flat_map(|n| (0..n).map(candidate_strategy).collect::<Vec<_>>())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// Permuting the input must not permute the output. Without this, the same
    /// corpus ranks two ways between calls and no golden test can exist.
    #[test]
    fn ranking_is_invariant_under_input_permutation(
        candidates in candidates_strategy(),
        rotation in 0usize..12,
    ) {
        let weights = MemoryWeights::default();
        let baseline = memory_ops::rank_memory_candidates(&candidates, &weights, 0);

        let mut rotated = candidates.clone();
        rotated.rotate_left(rotation % candidates.len().max(1));
        prop_assert_eq!(
            memory_ops::rank_memory_candidates(&rotated, &weights, 0),
            baseline.clone()
        );

        let mut reversed = candidates.clone();
        reversed.reverse();
        prop_assert_eq!(
            memory_ops::rank_memory_candidates(&reversed, &weights, 0),
            baseline.clone()
        );

        // Total: every input appears exactly once in the output.
        prop_assert_eq!(baseline.len(), candidates.len());
        let ranked_ids: BTreeSet<&String> = baseline.iter().map(|(id, _)| id).collect();
        prop_assert_eq!(ranked_ids.len(), candidates.len());

        // Ordered: scores never increase down the list.
        for pair in baseline.windows(2) {
            prop_assert!(
                pair[0].1 >= pair[1].1,
                "{:?} then {:?} is not descending",
                pair[0],
                pair[1]
            );
            if pair[0].1 == pair[1].1 {
                prop_assert!(pair[0].0 < pair[1].0, "equal scores must break on id");
            }
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(32))]

    /// Candidates that differ ONLY by id all score identically, so the whole
    /// ordering is the tie-break — ascending id, with no dependence on the
    /// order they arrived in.
    #[test]
    fn identical_candidates_order_purely_by_ascending_id(n in 1usize..10) {
        let template = MemoryCandidate {
            id: String::new(),
            fts_score: Some(2.0),
            vector_similarity: Some(0.5),
            confirmations: 3,
            modified_ms: 0,
            author_kind_human: true,
            confidence: Some(0.7),
        };
        // Built in DESCENDING id order so a stable sort that did nothing would
        // fail this rather than pass it by accident.
        let candidates: Vec<MemoryCandidate> = (0..n)
            .rev()
            .map(|i| MemoryCandidate { id: format!("{i:04}"), ..template.clone() })
            .collect();

        let ranked = memory_ops::rank_memory_candidates(&candidates, &MemoryWeights::default(), 0);
        let ids: Vec<&str> = ranked.iter().map(|(id, _)| id.as_str()).collect();
        let expected: Vec<String> = (0..n).map(|i| format!("{i:04}")).collect();
        prop_assert_eq!(ids, expected.iter().map(String::as_str).collect::<Vec<_>>());

        let scores: BTreeSet<String> = ranked.iter().map(|(_, s)| format!("{s:.6}")).collect();
        prop_assert_eq!(scores.len(), 1, "identical candidates must score identically");
    }
}
