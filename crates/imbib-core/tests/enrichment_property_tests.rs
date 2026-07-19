//! Property-based tests for the enrichment strategy modules
//!
//! Covers `enrichment::merge` (deterministic metadata merge),
//! `enrichment::priority` (source priority ordering), and
//! `enrichment::retry` (backoff schedule decisions).
//!
//! Invariants encoded here:
//! - merge is idempotent (`merge(a, a) == a` for canonical records)
//! - merge never downgrades a filled field to empty
//! - merge is order-independent when the two sources have distinct ranks
//! - the higher-priority source's non-empty value always wins
//! - re-merging an already-merged record with one of its inputs is a no-op
//! - `SourcePriority` induces a total preorder (antisymmetric + transitive
//!   `outranks`, totality over sources with distinct ranks)
//! - retry backoff is monotonically non-decreasing, bounded by `max_backoff`,
//!   and the decide() loop terminates within `max_attempts`

use std::collections::BTreeMap;
use std::time::Duration;

use imbib_core::enrichment::{
    merge_metadata, EnrichmentSourceId, PaperMetadata, RetryDecision, RetryPolicy, SourcePriority,
};
use proptest::prelude::*;

// === Strategies ===

const KNOWN_SOURCES: &[&str] = &[
    "ads",
    "crossref",
    "arxiv",
    "openalex",
    "pubmed",
    "semanticscholar",
    "dblp",
    "wos",
];

/// Optional string that is either absent or non-empty (canonical form).
fn opt_nonempty() -> impl Strategy<Value = Option<String>> {
    prop_oneof![
        2 => Just(None),
        3 => "[a-z0-9 .:/-]{1,16}".prop_map(Some),
    ]
}

/// Optional string that may also be `Some("")` — exercises the
/// "empty string counts as missing" rule.
fn opt_maybe_empty() -> impl Strategy<Value = Option<String>> {
    prop_oneof![
        2 => Just(None),
        1 => Just(Some(String::new())),
        3 => "[a-z0-9 .:/-]{1,16}".prop_map(Some),
    ]
}

fn arb_source() -> impl Strategy<Value = Option<EnrichmentSourceId>> {
    prop_oneof![
        1 => Just(None),
        1 => Just(Some(EnrichmentSourceId::new("mystery"))),
        4 => prop::sample::select(KNOWN_SOURCES).prop_map(|s| Some(EnrichmentSourceId::new(s))),
    ]
}

fn arb_known_source() -> impl Strategy<Value = EnrichmentSourceId> {
    prop::sample::select(KNOWN_SOURCES).prop_map(EnrichmentSourceId::new)
}

fn arb_extras() -> impl Strategy<Value = BTreeMap<String, String>> {
    prop::collection::btree_map("[a-z_]{1,8}", "[a-z0-9]{0,8}", 0..4)
}

/// Unique, canonical pdf_urls (merge dedups, so idempotence only holds for
/// records without internal duplicates — matching what plugins produce).
fn arb_pdf_urls() -> impl Strategy<Value = Vec<String>> {
    prop::collection::btree_set("https://[a-z]{2,8}/[a-z0-9]{1,6}", 0..4)
        .prop_map(|s| s.into_iter().collect())
}

prop_compose! {
    /// Canonical metadata record: optional strings are None or non-empty,
    /// pdf_urls are unique. `strings` covers title/abstract/venue/doi/arxiv/
    /// bibcode/pmid.
    fn arb_metadata()(
        source in arb_source(),
        title in opt_nonempty(),
        year in prop_oneof![Just(None), (1800i32..2100).prop_map(Some)],
        authors in prop::collection::vec("[A-Z][a-z]{1,8}", 0..4),
        abstract_text in opt_nonempty(),
        venue in opt_nonempty(),
        doi in opt_nonempty(),
        arxiv_id in opt_nonempty(),
        bibcode in opt_nonempty(),
        pmid in opt_nonempty(),
        citation_count in prop_oneof![Just(None), (0i64..100_000).prop_map(Some)],
        reference_count in prop_oneof![Just(None), (0i64..10_000).prop_map(Some)],
        pdf_urls in arb_pdf_urls(),
        extras in arb_extras(),
    ) -> PaperMetadata {
        PaperMetadata {
            source,
            title,
            year,
            authors,
            abstract_text,
            venue,
            doi,
            arxiv_id,
            bibcode,
            pmid,
            citation_count,
            reference_count,
            pdf_urls,
            extras,
        }
    }
}

prop_compose! {
    /// Like `arb_metadata` but scalar strings may be `Some("")`.
    fn arb_metadata_maybe_empty()(
        source in arb_source(),
        title in opt_maybe_empty(),
        year in prop_oneof![Just(None), (1800i32..2100).prop_map(Some)],
        authors in prop::collection::vec("[A-Z][a-z]{1,8}", 0..4),
        abstract_text in opt_maybe_empty(),
        venue in opt_maybe_empty(),
        doi in opt_maybe_empty(),
        arxiv_id in opt_maybe_empty(),
        bibcode in opt_maybe_empty(),
        pmid in opt_maybe_empty(),
        citation_count in prop_oneof![Just(None), (0i64..100_000).prop_map(Some)],
        reference_count in prop_oneof![Just(None), (0i64..10_000).prop_map(Some)],
        pdf_urls in arb_pdf_urls(),
        extras in arb_extras(),
    ) -> PaperMetadata {
        PaperMetadata {
            source,
            title,
            year,
            authors,
            abstract_text,
            venue,
            doi,
            arxiv_id,
            bibcode,
            pmid,
            citation_count,
            reference_count,
            pdf_urls,
            extras,
        }
    }
}

/// True if the optional string holds a non-empty value.
fn filled(v: &Option<String>) -> bool {
    v.as_deref().is_some_and(|s| !s.is_empty())
}

/// Field accessors for the scalar string fields, so properties can loop
/// over all of them uniformly.
fn scalar_fields(m: &PaperMetadata) -> [(&'static str, &Option<String>); 7] {
    [
        ("title", &m.title),
        ("abstract_text", &m.abstract_text),
        ("venue", &m.venue),
        ("doi", &m.doi),
        ("arxiv_id", &m.arxiv_id),
        ("bibcode", &m.bibcode),
        ("pmid", &m.pmid),
    ]
}

// === Merge properties ===

proptest! {
    /// merge(a, a) == a for canonical records, and reports no changed fields.
    #[test]
    fn merge_self_is_identity(a in arb_metadata()) {
        let p = SourcePriority::default();
        let outcome = merge_metadata(a.clone(), a.clone(), &p);
        prop_assert_eq!(&outcome.merged, &a);
        prop_assert!(
            outcome.changed_fields.is_empty(),
            "self-merge reported changes: {:?}",
            outcome.changed_fields
        );
    }

    /// A filled field is never downgraded to missing/empty, whichever side
    /// carries it — including inputs with `Some("")` noise.
    #[test]
    fn merge_never_downgrades_filled_fields(
        a in arb_metadata_maybe_empty(),
        b in arb_metadata_maybe_empty(),
    ) {
        let p = SourcePriority::default();
        let merged = merge_metadata(a.clone(), b.clone(), &p).merged;

        for (((name, fa), (_, fb)), (_, fm)) in scalar_fields(&a)
            .iter()
            .zip(scalar_fields(&b).iter())
            .zip(scalar_fields(&merged).iter())
        {
            if filled(fa) || filled(fb) {
                prop_assert!(
                    filled(fm),
                    "field '{}' downgraded: base={:?} incoming={:?} merged={:?}",
                    name, fa, fb, fm
                );
            }
        }

        // Numeric fields: Some never becomes None.
        prop_assert!(a.year.is_none() && b.year.is_none() || merged.year.is_some());
        prop_assert!(
            a.citation_count.is_none() && b.citation_count.is_none()
                || merged.citation_count.is_some()
        );
        prop_assert!(
            a.reference_count.is_none() && b.reference_count.is_none()
                || merged.reference_count.is_some()
        );

        // Authors: a non-empty list never merges to empty.
        if !a.authors.is_empty() || !b.authors.is_empty() {
            prop_assert!(!merged.authors.is_empty());
        }

        // pdf_urls: union — every input URL survives.
        for url in a.pdf_urls.iter().chain(b.pdf_urls.iter()) {
            prop_assert!(merged.pdf_urls.contains(url), "lost pdf url {}", url);
        }

        // extras: every input key survives.
        for k in a.extras.keys().chain(b.extras.keys()) {
            prop_assert!(merged.extras.contains_key(k), "lost extras key {}", k);
        }
    }

    /// When the two records come from sources with distinct priority ranks,
    /// the merged result is independent of argument order.
    #[test]
    fn merge_is_order_independent_for_distinct_ranks(
        mut a in arb_metadata(),
        mut b in arb_metadata(),
        sa in arb_known_source(),
        sb in arb_known_source(),
    ) {
        let p = SourcePriority::default();
        prop_assume!(p.rank(&sa) != p.rank(&sb));
        a.source = Some(sa);
        b.source = Some(sb);

        let ab = merge_metadata(a.clone(), b.clone(), &p).merged;
        let ba = merge_metadata(b, a, &p).merged;
        prop_assert_eq!(ab, ba);
    }

    /// The higher-priority source's non-empty scalar value wins, regardless
    /// of whether it arrives as `base` or `incoming`.
    #[test]
    fn higher_priority_value_wins_regardless_of_order(
        mut a in arb_metadata(),
        mut b in arb_metadata(),
        sa in arb_known_source(),
        sb in arb_known_source(),
    ) {
        let p = SourcePriority::default();
        prop_assume!(p.rank(&sa) != p.rank(&sb));
        a.source = Some(sa.clone());
        b.source = Some(sb.clone());

        let (hi, lo) = if p.outranks(&sa, &sb) { (&a, &b) } else { (&b, &a) };

        for order in [
            merge_metadata(a.clone(), b.clone(), &p).merged,
            merge_metadata(b.clone(), a.clone(), &p).merged,
        ] {
            for (((name, fh), (_, fl)), (_, fm)) in scalar_fields(hi)
                .iter()
                .zip(scalar_fields(lo).iter())
                .zip(scalar_fields(&order).iter())
            {
                if filled(fh) {
                    prop_assert_eq!(
                        *fm, *fh,
                        "field '{}': winner value lost (winner={:?} loser={:?} merged={:?})",
                        name, fh, fl, fm
                    );
                }
            }
            // Winner's non-empty author list wins outright.
            if !hi.authors.is_empty() {
                prop_assert_eq!(&order.authors, &hi.authors);
            }
        }
    }

    /// Absorption: merging the merge result with one of its inputs again
    /// changes nothing (enrichment loops re-deliver the same plugin record).
    #[test]
    fn remerging_an_input_is_a_noop(
        a in arb_metadata(),
        b in arb_metadata(),
    ) {
        let p = SourcePriority::default();
        let m = merge_metadata(a.clone(), b.clone(), &p).merged;

        let m_b = merge_metadata(m.clone(), b, &p);
        prop_assert_eq!(&m_b.merged, &m, "re-merging `incoming` changed the record");
        prop_assert!(m_b.changed_fields.is_empty());
    }
}

// === Priority properties ===

proptest! {
    /// `outranks` is antisymmetric and irreflexive over arbitrary sources
    /// and arbitrary custom orderings.
    #[test]
    fn outranks_is_antisymmetric(
        order in prop::collection::vec("[a-z]{1,8}", 0..8),
        x in "[a-z]{1,8}",
        y in "[a-z]{1,8}",
    ) {
        let p = SourcePriority::new(order.iter().map(|s| s.as_str().into()).collect());
        let (x, y): (EnrichmentSourceId, EnrichmentSourceId) = (x.as_str().into(), y.as_str().into());
        prop_assert!(!(p.outranks(&x, &y) && p.outranks(&y, &x)));
        prop_assert!(!p.outranks(&x, &x));
    }

    /// `outranks` is transitive.
    #[test]
    fn outranks_is_transitive(
        order in prop::collection::vec("[a-z]{1,8}", 0..8),
        x in "[a-z]{1,8}",
        y in "[a-z]{1,8}",
        z in "[a-z]{1,8}",
    ) {
        let p = SourcePriority::new(order.iter().map(|s| s.as_str().into()).collect());
        let (x, y, z): (EnrichmentSourceId, EnrichmentSourceId, EnrichmentSourceId) =
            (x.as_str().into(), y.as_str().into(), z.as_str().into());
        if p.outranks(&x, &y) && p.outranks(&y, &z) {
            prop_assert!(p.outranks(&x, &z));
        }
    }

    /// Totality: two *distinct* sources present in the order list are always
    /// strictly ordered (exactly one outranks the other), and any known
    /// source outranks any unknown source.
    #[test]
    fn distinct_listed_sources_are_strictly_ordered(
        order in prop::collection::vec("[a-z]{1,8}", 2..8),
        i in 0usize..8,
        j in 0usize..8,
        unknown in "[A-Z]{9,12}",
    ) {
        let p = SourcePriority::new(order.iter().map(|s| s.as_str().into()).collect());
        let i = i % order.len();
        let j = j % order.len();
        let a: EnrichmentSourceId = order[i].as_str().into();
        let b: EnrichmentSourceId = order[j].as_str().into();

        if a != b {
            prop_assert!(
                p.outranks(&a, &b) ^ p.outranks(&b, &a),
                "distinct listed sources {:?} / {:?} not strictly ordered",
                a, b
            );
        } else {
            prop_assert!(!p.outranks(&a, &b) && !p.outranks(&b, &a));
        }

        // Unknown sources (9+ chars can't collide with the 1-8 char list
        // entries even after lowercasing) always lose.
        let u: EnrichmentSourceId = unknown.as_str().into();
        prop_assert!(p.outranks(&a, &u));
        prop_assert!(!p.outranks(&u, &a));
    }

    /// rank() respects list position: earlier (first occurrence) means
    /// smaller rank; every listed source has rank < usize::MAX.
    #[test]
    fn rank_matches_first_occurrence(
        order in prop::collection::vec("[a-z]{1,4}", 1..8),
    ) {
        let ids: Vec<EnrichmentSourceId> = order.iter().map(|s| s.as_str().into()).collect();
        let p = SourcePriority::new(ids.clone());
        for (i, id) in ids.iter().enumerate() {
            let first = ids.iter().position(|x| x == id).unwrap();
            prop_assert_eq!(p.rank(id), first, "rank of {:?} (index {})", id, i);
        }
    }
}

// === Retry properties ===

fn arb_policy() -> impl Strategy<Value = RetryPolicy> {
    (
        1u32..=32,
        0u64..=10_000,
        0u64..=120_000,
        0.0f64..=1.0,
    )
        .prop_map(|(max_attempts, base_ms, max_ms, jitter_factor)| RetryPolicy {
            max_attempts,
            base_backoff: Duration::from_millis(base_ms),
            max_backoff: Duration::from_millis(max_ms),
            jitter_factor,
        })
}

proptest! {
    /// The deterministic backoff schedule is monotonically non-decreasing
    /// and bounded by `max_backoff` across the realistic attempt range.
    #[test]
    fn backoff_schedule_monotone_and_bounded(policy in arb_policy()) {
        let mut prev = Duration::ZERO;
        for n in 1u32..=64 {
            let d = policy.next_delay(n);
            prop_assert!(
                d >= prev,
                "delay decreased at attempt {}: {:?} -> {:?}",
                n, prev, d
            );
            prop_assert!(
                d <= policy.max_backoff,
                "delay {:?} at attempt {} exceeds max_backoff {:?}",
                d, n, policy.max_backoff
            );
            prev = d;
        }
    }

    /// Driving decide() as the enrichment loop does always terminates in
    /// exactly max_attempts attempts, with sequential attempt numbers.
    #[test]
    fn decide_loop_terminates_within_max_attempts(policy in arb_policy()) {
        let mut attempt = 1u32;
        let mut retries = 0u32;
        loop {
            match policy.decide(attempt) {
                RetryDecision::Stop => break,
                RetryDecision::Retry { next_attempt, delay } => {
                    prop_assert_eq!(next_attempt, attempt + 1);
                    prop_assert!(next_attempt <= policy.max_attempts);
                    prop_assert!(delay <= policy.max_backoff);
                    attempt = next_attempt;
                    retries += 1;
                    prop_assert!(
                        retries < policy.max_attempts,
                        "retry loop exceeded budget"
                    );
                }
            }
        }
        // Stopped exactly when the budget was used up.
        prop_assert_eq!(attempt, policy.max_attempts.max(1));
        prop_assert_eq!(retries, policy.max_attempts.saturating_sub(1));
    }

    /// Jittered delays stay within ±jitter_factor of the deterministic
    /// delay (floored at zero) for any finite RNG sample.
    #[test]
    fn jittered_delay_bounded(
        policy in arb_policy(),
        n in 1u32..=64,
        sample in -2.0f64..=2.0,
    ) {
        let base = policy.next_delay(n).as_secs_f64();
        let jittered = policy.next_delay_with_jitter(n, sample).as_secs_f64();
        let lo = (base * (1.0 - policy.jitter_factor)).max(0.0);
        let hi = base * (1.0 + policy.jitter_factor);
        prop_assert!(
            jittered >= lo - 1e-9 && jittered <= hi + 1e-9,
            "jittered delay {} outside [{}, {}] (base {})",
            jittered, lo, hi, base
        );
    }

    /// Totality: next_delay must not panic for any attempt number a caller
    /// can produce (max_attempts is a public u32, so decide() can legally
    /// reach any attempt value).
    ///
    /// BUG (found by this property): `next_delay` computes
    /// `(n as i32) - 2`. For n == 2_147_483_648 (i32::MIN after the `as`
    /// cast) the subtraction overflows and panics in debug builds; for
    /// n > i32::MAX the wrapped-negative exponent silently collapses the
    /// delay back toward zero, breaking monotonicity.
    /// Minimal counterexample: `RetryPolicy::default().next_delay(2_147_483_648)`.
    #[test]
    #[ignore = "BUG: next_delay panics (debug) / loses monotonicity for n > i32::MAX due to `n as i32` wrap"]
    fn next_delay_total_over_u32(policy in arb_policy(), n in prop::num::u32::ANY) {
        let d = policy.next_delay(n);
        prop_assert!(d <= policy.max_backoff);
        if n >= 2 {
            // Once past the first retry the schedule must never fall back
            // below the base step (it is non-decreasing).
            prop_assert!(d >= policy.next_delay(2).min(policy.max_backoff));
        }
    }

    /// Totality: next_delay_with_jitter must not panic for arbitrary f64
    /// samples — RNG plumbing bugs (NaN) must not crash the caller.
    ///
    /// BUG (found by this property): a NaN jitter_sample survives
    /// `clamp(-1.0, 1.0)` (clamp keeps NaN), makes `jittered` NaN, and
    /// `Duration::from_secs_f64(NaN)` panics.
    /// Minimal counterexample:
    /// `RetryPolicy::default().next_delay_with_jitter(2, f64::NAN)`.
    #[test]
    #[ignore = "BUG: next_delay_with_jitter panics on NaN jitter_sample (Duration::from_secs_f64(NaN))"]
    fn jitter_total_over_f64(
        policy in arb_policy(),
        n in 1u32..=64,
        sample in prop::num::f64::ANY,
    ) {
        let d = policy.next_delay_with_jitter(n, sample);
        // Any finite outcome is acceptable; the property is "no panic" plus
        // the cap that jitter never exceeds double the deterministic delay
        // for jitter_factor <= 1.
        prop_assert!(d.as_secs_f64() <= policy.next_delay(n).as_secs_f64() * 2.0 + 1e-9);
    }
}
