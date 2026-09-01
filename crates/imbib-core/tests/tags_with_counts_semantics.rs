//! `list_tags_with_counts` semantics (sidebar plan P4).
//!
//! P4 replaced the per-definition `count(HasTag)` loop (T unindexable LIKE
//! subqueries; 14–19 s live) with one pair-fetch plus a Rust rollup. This
//! test pins the semantics the rewrite must preserve, against hand-computed
//! expectations rather than the old code:
//! - a definition counts its exact tag AND every descendant (`path/…`),
//! - an item tagged with several descendants of one definition counts ONCE,
//! - exact match is byte-equal; descendant match is ASCII-case-insensitive
//!   (SQLite LIKE's default folding, which the old shape had),
//! - only bibliography entries count — tags on other kinds are invisible,
//! - a definition with no tagged items reports zero, and an undefined tag
//!   path produces no row of its own (it only rolls up into ancestors).

#![cfg(feature = "native")]

use std::collections::HashMap;

use imbib_core::unified::store_api::ImbibStore;

fn import_one(store: &ImbibStore, lib: &str, key: &str) -> String {
    let bib = format!("@article{{{key}, title={{Paper {key}}}, author={{Test}}, year={{2026}}}}");
    let outcome = store
        .import_bibtex_into(bib, lib.to_string(), None)
        .unwrap();
    assert_eq!(outcome.imported.len(), 1, "expected one import for {key}");
    outcome.imported[0].clone()
}

#[test]
fn tags_with_counts_rolls_up_the_hierarchy_once_per_item() {
    let store = ImbibStore::open_in_memory().unwrap();
    let lib = store.create_library("Tags".into()).unwrap();

    store.create_tag("methods".into(), None, None).unwrap();
    store.create_tag("methods/sims".into(), None, None).unwrap();
    store.create_tag("AI".into(), None, None).unwrap();
    store.create_tag("zzz".into(), None, None).unwrap();

    let p1 = import_one(&store, &lib.id, "p1");
    let p2 = import_one(&store, &lib.id, "p2");
    let p3 = import_one(&store, &lib.id, "p3");
    let p4 = import_one(&store, &lib.id, "p4");
    let p5 = import_one(&store, &lib.id, "p5");
    let p6 = import_one(&store, &lib.id, "p6");

    store
        .add_tag(vec![p1.clone(), p2.clone()], "methods/sims".into())
        .unwrap();
    // p2 also carries a SECOND descendant of `methods` (undefined path —
    // it must roll up, but must not double-count p2).
    store.add_tag(vec![p2], "methods/obs".into()).unwrap();
    // Exact match on the parent definition itself.
    store.add_tag(vec![p3], "methods".into()).unwrap();
    // Descendant of `AI` in a different ASCII case — counts (LIKE folding).
    store.add_tag(vec![p4], "ai/topic".into()).unwrap();
    // Exact match is byte-equal: `AI` counts, bare `ai` does not.
    store.add_tag(vec![p5], "AI".into()).unwrap();
    store.add_tag(vec![p6], "ai".into()).unwrap();

    // A tag on a NON-bibliography item must be invisible to the counts.
    let coll = store
        .create_collection("Noise".into(), lib.id.clone(), false, None)
        .unwrap();
    store.add_tag(vec![coll.id], "methods/sims".into()).unwrap();

    let counts: HashMap<String, i32> = store
        .list_tags_with_counts()
        .unwrap()
        .into_iter()
        .map(|r| (r.path, r.publication_count))
        .collect();

    assert_eq!(
        counts.get("methods"),
        Some(&3),
        "p1+p2 (once)+p3: {counts:?}"
    );
    assert_eq!(counts.get("methods/sims"), Some(&2), "p1+p2: {counts:?}");
    assert_eq!(
        counts.get("AI"),
        Some(&2),
        "p4 (folded)+p5, not p6: {counts:?}"
    );
    assert_eq!(
        counts.get("zzz"),
        Some(&0),
        "defined but untagged: {counts:?}"
    );
    assert!(
        !counts.contains_key("methods/obs"),
        "undefined paths get no row of their own: {counts:?}"
    );
}
