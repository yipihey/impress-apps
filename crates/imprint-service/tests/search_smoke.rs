//! Smoke tests for the tantivy-backed `ManuscriptSearchIndex` and for the
//! `DefaultImprintHttpHandlers::search` trait method.

use std::sync::Arc;

use imprint_service::{
    DefaultImprintHttpHandlers, ImprintHttpHandlers, ManuscriptSearchIndex, ManuscriptService,
    SectionMetadata, SectionStore,
};
use tempfile::TempDir;
use uuid::Uuid;

fn fresh() -> (DefaultImprintHttpHandlers, TempDir, Uuid) {
    let dir = TempDir::new().unwrap();
    let sections = Arc::new(SectionStore::open_in_memory(dir.path().join("content")).unwrap());
    let idx = Arc::new(ManuscriptSearchIndex::in_memory().unwrap());
    let h = DefaultImprintHttpHandlers::new(sections.clone(), idx.clone());
    (h, dir, Uuid::new_v4())
}

#[tokio::test]
async fn round_trip_index_and_search() {
    let (h, _dir, doc) = fresh();

    h.put_section(
        doc,
        "intro",
        "The cosmic microwave background constrains halo bias.",
        SectionMetadata {
            title: Some("Introduction".into()),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    h.put_section(
        doc,
        "methods",
        "Numerical N-body simulations are run with gevolution.",
        SectionMetadata {
            title: Some("Methods".into()),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    h.put_section(
        doc,
        "results",
        "We find consistent halo statistics across runs.",
        SectionMetadata {
            title: Some("Results".into()),
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // Single-term: matches both intro and results.
    let hits = h.search("halo", 10).await.unwrap();
    assert_eq!(hits.len(), 2);

    // Multi-term AND: intro only.
    let hits = h.search("halo bias", 10).await.unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].section_key, "intro");

    // Title boost: section titles are searchable too.
    let hits = h.search("introduction", 10).await.unwrap();
    assert!(
        hits.iter().any(|h| h.section_key == "intro"),
        "title match should surface section 'intro'"
    );
}

#[tokio::test]
async fn rebuild_from_section_store_picks_up_existing_sections() {
    // Populate the section store BEFORE the search index is built. Confirms
    // that `ManuscriptService::open` rebuild populates the index.
    let dir = TempDir::new().unwrap();
    let workspace = dir.path();

    {
        let store = SectionStore::open(workspace).unwrap();
        let doc = Uuid::new_v4();
        store
            .put_section(
                doc,
                "intro",
                "Quantum entanglement experiments.",
                SectionMetadata::default(),
            )
            .unwrap();
        store
            .put_section(
                doc,
                "discussion",
                "Classical correlations only.",
                SectionMetadata::default(),
            )
            .unwrap();
    }

    let svc: ManuscriptService = imprint_service::open(workspace).unwrap();
    let hits = svc.handlers.search("quantum", 10).await.unwrap();
    assert_eq!(hits.len(), 1);
    assert!(hits[0].excerpt.is_some());
}
