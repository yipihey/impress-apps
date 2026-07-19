//! Property tests for THE critical inbox invariant:
//!
//!   "Dismissed papers never re-enter the inbox."
//!
//! `ImbibStore::batch_import_search_results` is the single funnel through
//! which search/smart-search results land in a library (including the inbox
//! library). These properties drive it with arbitrary import batches and
//! arbitrary dismissed sets — including mixed-case identifier renderings —
//! and assert that no result matching a dismissed identifier is ever
//! imported or surfaced as "existing".
//!
//! See also `dismiss_paper_case_insensitive` in the store_api unit tests and
//! the historical regression: batch_import must check the dismissed set for
//! *existing* papers too, not just new ones.

use std::collections::BTreeSet;

use imbib_core::unified::shaped_queries::SearchResultInput;
use imbib_core::unified::store_api::ImbibStore;
use proptest::prelude::*;

// === Paper universe helpers ===

const MAX_PAPERS: usize = 6;

fn doi(i: usize) -> String {
    format!("10.5555/propx{}", i)
}

fn arxiv(i: usize) -> String {
    format!("2405.100{}", i)
}

fn bibcode(i: usize) -> String {
    format!("2024test.900..{}0p", i)
}

fn bibtex(i: usize) -> String {
    format!(
        "@article{{Prop{i}, title={{Prop Paper {i}}}, author={{Smith, J.}}, year={{2024}}, \
         doi={{{doi}}}, eprint={{{arxiv}}}, archiveprefix={{arXiv}}, bibcode={{{bibcode}}}}}",
        i = i,
        doi = doi(i),
        arxiv = arxiv(i),
        bibcode = bibcode(i),
    )
}

fn cased(s: String, upper: bool) -> String {
    if upper {
        s.to_uppercase()
    } else {
        s
    }
}

fn result_for(idx: usize, upper_doi: bool, upper_arxiv: bool, upper_bibcode: bool) -> SearchResultInput {
    SearchResultInput {
        bibtex: bibtex(idx),
        doi: Some(cased(doi(idx), upper_doi)),
        arxiv_id: Some(cased(arxiv(idx), upper_arxiv)),
        bibcode: Some(cased(bibcode(idx), upper_bibcode)),
    }
}

/// All identifiers of paper `i`, lowercased, for post-import scanning.
fn lowered_identifiers(i: usize) -> [String; 3] {
    [
        doi(i).to_lowercase(),
        arxiv(i).to_lowercase(),
        bibcode(i).to_lowercase(),
    ]
}

// === Strategies ===

/// (paper index, case flags for doi/arxiv/bibcode)
fn arb_batch() -> impl Strategy<Value = Vec<(usize, bool, bool, bool)>> {
    prop::collection::vec(
        (0..MAX_PAPERS, any::<bool>(), any::<bool>(), any::<bool>()),
        0..2 * MAX_PAPERS,
    )
}

fn arb_dismissed() -> impl Strategy<Value = Vec<(usize, bool)>> {
    // subset of the universe, each with a case flag used when dismissing
    prop::collection::btree_set(0..MAX_PAPERS, 0..=MAX_PAPERS).prop_flat_map(|set| {
        let indices: Vec<usize> = set.into_iter().collect();
        let len = indices.len();
        (
            Just(indices),
            prop::collection::vec(any::<bool>(), len..=len),
        )
            .prop_map(|(idx, flags)| idx.into_iter().zip(flags).collect())
    })
}

proptest! {
    // Each case spins up an in-memory SQLite store; keep counts moderate.
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// CRITICAL INVARIANT: for an arbitrary import batch and an arbitrary
    /// dismissed set (with arbitrary identifier casing on both sides), no
    /// result matching a dismissed identifier is imported into the inbox
    /// library — while every non-dismissed result still lands.
    #[test]
    fn dismissed_papers_never_reenter_inbox(
        dismissed in arb_dismissed(),
        batch in arb_batch(),
    ) {
        let store = ImbibStore::open_in_memory().unwrap();
        let inbox = store.create_inbox_library("Inbox".into()).unwrap();

        let dismissed_set: BTreeSet<usize> = dismissed.iter().map(|(i, _)| *i).collect();
        for (i, upper) in &dismissed {
            store
                .dismiss_paper(
                    Some(cased(doi(*i), *upper)),
                    Some(cased(arxiv(*i), *upper)),
                    Some(cased(bibcode(*i), *upper)),
                    None,
                )
                .unwrap();
        }

        let results: Vec<SearchResultInput> = batch
            .iter()
            .map(|(idx, ud, ua, ub)| result_for(*idx, *ud, *ua, *ub))
            .collect();

        let outcome = store
            .batch_import_search_results(results, inbox.id.clone(), true)
            .unwrap();

        // Accounting: every occurrence of a dismissed paper is filtered.
        let expected_dismissed = batch
            .iter()
            .filter(|(idx, _, _, _)| dismissed_set.contains(idx))
            .count() as u32;
        prop_assert_eq!(outcome.dismissed_count, expected_dismissed);
        prop_assert_eq!(outcome.failed_count, 0);

        // THE invariant: no publication in the inbox library carries a
        // dismissed identifier.
        let dismissed_idents: BTreeSet<String> = dismissed_set
            .iter()
            .flat_map(|i| lowered_identifiers(*i))
            .collect();
        let rows = store
            .query_publications(inbox.id.clone(), "created".into(), true, None, None)
            .unwrap();
        for row in &rows {
            for ident in [&row.doi, &row.arxiv_id, &row.bibcode].into_iter().flatten() {
                prop_assert!(
                    !dismissed_idents.contains(&ident.to_lowercase()),
                    "dismissed identifier {:?} re-entered the inbox (cite_key {})",
                    ident,
                    row.cite_key
                );
            }
        }

        // Dual invariant (no over-filtering): every non-dismissed batch
        // paper is present in the library afterwards.
        for (idx, _, _, _) in &batch {
            if !dismissed_set.contains(idx) {
                let want = doi(*idx).to_lowercase();
                prop_assert!(
                    rows.iter().any(|r| r
                        .doi
                        .as_deref()
                        .is_some_and(|d| d.to_lowercase() == want)),
                    "non-dismissed paper {} was over-filtered",
                    idx
                );
            }
        }
    }

    /// Regression property (historical bug: dismissed papers that already
    /// exist in the store were resurfaced via `existing_ids`): after papers
    /// are imported and later dismissed, re-importing the same search
    /// results must not report the dismissed papers as existing, must not
    /// re-import them, and must not duplicate anything.
    #[test]
    fn dismissed_existing_papers_are_not_resurfaced(
        dismissed in arb_dismissed(),
        upper_flags in prop::collection::vec(any::<bool>(), MAX_PAPERS),
    ) {
        let store = ImbibStore::open_in_memory().unwrap();
        let inbox = store.create_inbox_library("Inbox".into()).unwrap();

        // Pre-import the full universe (exact-case identifiers).
        let initial: Vec<SearchResultInput> = (0..MAX_PAPERS)
            .map(|i| result_for(i, false, false, false))
            .collect();
        let first = store
            .batch_import_search_results(initial, inbox.id.clone(), true)
            .unwrap();
        prop_assert_eq!(first.imported_ids.len(), MAX_PAPERS);
        prop_assert_eq!(first.dismissed_count, 0);

        // Map paper index -> stored publication id via DOI.
        let rows = store
            .query_publications(inbox.id.clone(), "created".into(), true, None, None)
            .unwrap();
        let id_of = |i: usize| -> String {
            let want = doi(i);
            rows.iter()
                .find(|r| r.doi.as_deref() == Some(want.as_str()))
                .map(|r| r.id.clone())
                .unwrap()
        };

        // Dismiss a subset (mixed-case identifier renderings).
        let dismissed_set: BTreeSet<usize> = dismissed.iter().map(|(i, _)| *i).collect();
        for (i, upper) in &dismissed {
            store
                .dismiss_paper(
                    Some(cased(doi(*i), *upper)),
                    Some(cased(arxiv(*i), *upper)),
                    Some(cased(bibcode(*i), *upper)),
                    None,
                )
                .unwrap();
        }

        // Re-import the whole universe again, dismissed papers rendered in
        // arbitrary case.
        let again: Vec<SearchResultInput> = (0..MAX_PAPERS)
            .map(|i| {
                let flip = dismissed_set.contains(&i) && upper_flags[i];
                result_for(i, flip, flip, flip)
            })
            .collect();
        let second = store
            .batch_import_search_results(again, inbox.id.clone(), true)
            .unwrap();

        // Dismissed papers are neither "existing" nor re-imported.
        prop_assert_eq!(second.dismissed_count, dismissed_set.len() as u32);
        prop_assert_eq!(second.imported_ids.len(), 0, "re-import duplicated papers");
        let dismissed_pub_ids: BTreeSet<String> =
            dismissed_set.iter().map(|i| id_of(*i)).collect();
        for id in &second.existing_ids {
            prop_assert!(
                !dismissed_pub_ids.contains(id),
                "dismissed existing paper resurfaced via existing_ids: {}",
                id
            );
        }
        // All non-dismissed papers ARE reported as existing.
        let existing: BTreeSet<String> = second.existing_ids.iter().cloned().collect();
        for i in 0..MAX_PAPERS {
            if !dismissed_set.contains(&i) {
                prop_assert!(
                    existing.contains(&id_of(i)),
                    "non-dismissed existing paper {} not reported",
                    i
                );
            }
        }

        // Library contents unchanged: still exactly one row per paper.
        let rows_after = store
            .query_publications(inbox.id, "created".into(), true, None, None)
            .unwrap();
        prop_assert_eq!(rows_after.len(), MAX_PAPERS);
    }
}
