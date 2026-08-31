//! `sidebar_snapshot()` parity (sidebar plan P3).
//!
//! The one-call snapshot is PURE COMPOSITION of the per-shape verbs — that is
//! its whole safety argument, and this test is what keeps it true: every
//! field must equal the corresponding point read on the same store, so the
//! Swift maintainer's one-crossing sweep can never drift from what direct
//! callers see. A field that starts being computed "its own way" fails here
//! before it ships as a sidebar that disagrees with its own detail views.

#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;
use impress_core::schemas::ARTIFACT_SCHEMA_REFS;

#[test]
fn sidebar_snapshot_matches_the_point_reads() {
    let store = ImbibStore::open_in_memory().unwrap();

    // A real-ish shape: two libraries, collections in each, a feed, papers
    // with unread/starred/flag states.
    let lib_a = store.create_library("Alpha".into()).unwrap();
    let lib_b = store.create_library("Beta".into()).unwrap();
    let _c1 = store
        .create_collection("A/One".into(), lib_a.id.clone(), false, None)
        .unwrap();
    let _c2 = store
        .create_collection(
            "A/Two".into(),
            lib_a.id.clone(),
            true,
            Some("year>2020".into()),
        )
        .unwrap();
    let _c3 = store
        .create_collection("B/One".into(), lib_b.id.clone(), false, None)
        .unwrap();

    let bib = r#"@article{snapshot2026, title={Snapshot Parity}, author={Test}, year={2026}}
@article{snapshot2026b, title={Second}, author={Test}, year={2026}}"#;
    let imported = store
        .import_bibtex_into(bib.into(), lib_a.id.clone(), None)
        .unwrap();
    assert!(!imported.imported.is_empty());

    let snapshot = store.sidebar_snapshot().unwrap();

    // Libraries: same rows as the point read.
    let libraries = store.list_libraries().unwrap();
    assert_eq!(
        snapshot.libraries.iter().map(|l| &l.id).collect::<Vec<_>>(),
        libraries.iter().map(|l| &l.id).collect::<Vec<_>>()
    );

    // Per library: collections, feeds and starred equal the point reads.
    assert_eq!(snapshot.per_library.len(), libraries.len());
    for per in &snapshot.per_library {
        let collections = store.list_collections(per.library_id.clone()).unwrap();
        assert_eq!(
            per.collections.iter().map(|c| &c.id).collect::<Vec<_>>(),
            collections.iter().map(|c| &c.id).collect::<Vec<_>>(),
            "collections diverged for library {}",
            per.library_id
        );
        let feeds = store
            .list_smart_searches(Some(per.library_id.clone()))
            .unwrap();
        assert_eq!(
            per.feeds.iter().map(|f| &f.id).collect::<Vec<_>>(),
            feeds.iter().map(|f| &f.id).collect::<Vec<_>>()
        );
        assert_eq!(
            per.starred,
            store.count_starred(Some(per.library_id.clone())).unwrap()
        );
    }

    // Artifact counts cover the None total plus EVERY exported schema ref,
    // each equal to its point read.
    assert_eq!(
        snapshot.artifact_counts.len(),
        1 + ARTIFACT_SCHEMA_REFS.len()
    );
    for entry in &snapshot.artifact_counts {
        assert_eq!(
            entry.count,
            store.count_artifacts(entry.schema_ref.clone()).unwrap(),
            "artifact count diverged for {:?}",
            entry.schema_ref
        );
    }

    // Badge counts are the same struct the point verb returns.
    let counts = store.sidebar_unread_and_flag_counts().unwrap();
    assert_eq!(
        snapshot.counts.unread_by_container.len(),
        counts.unread_by_container.len()
    );
    assert_eq!(snapshot.counts.flag_counts.len(), counts.flag_counts.len());

    // Totals.
    assert_eq!(snapshot.starred_total, store.count_starred(None).unwrap());
    assert_eq!(
        snapshot.all_feeds.len(),
        store.list_smart_searches(None).unwrap().len()
    );
}
