//! Property tests for the throughline invariants (ADR-0016) — the
//! invariant-fortress suite for the anchor ledger and staleness derivation:
//!
//!  1. Anchor-map JSON round-trips exactly (the ledger must never mutate
//!     through serialization).
//!  2. Staleness derivation is deterministic, pure, and exhaustive: every
//!     ledger anchor yields exactly one assessment; hash-equal state is
//!     `synced`; an unresolvable key is `broken`.
//!  3. Paragraph extraction is deterministic and duplicate-label-stable.
//!  4. Derivation never writes: deriving twice against the same inputs
//!     (including through the store facade) leaves the ledger untouched.
//!  5. `rebind_candidate` never proposes an ambiguous or self target.

use std::collections::BTreeMap;
use std::sync::Arc;

use imprint_service::throughline::{
    derive_anchor_states, derive_coverage, extract_paragraphs, rebind_candidate, AnchorEntry,
    AnchorMap, ThroughlineStore,
};
use imprint_service::{BlobStore, SectionMetadata, SectionRecord, SectionStore};
use proptest::prelude::*;
use uuid::Uuid;

// ─── Generators ────────────────────────────────────────────────────────────

fn arb_label() -> impl Strategy<Value = String> {
    "[a-z][a-z0-9-]{0,12}".prop_map(|s| format!("tl-{s}"))
}

fn arb_key() -> impl Strategy<Value = String> {
    "[a-z][a-z0-9-]{0,12}"
}

fn arb_hash() -> impl Strategy<Value = String> {
    "[0-9a-f]{8}"
}

prop_compose! {
    fn arb_entry()(
        keys in proptest::collection::btree_set(arb_key(), 0..4),
        hashes in proptest::collection::vec(arb_hash(), 0..4),
        tl_hash in arb_hash(),
    ) -> AnchorEntry {
        let keys: Vec<String> = keys.into_iter().collect();
        let manuscript_hashes: BTreeMap<String, String> = keys
            .iter()
            .zip(hashes)
            .map(|(k, h)| (k.clone(), h))
            .collect();
        AnchorEntry { section_keys: keys, manuscript_hashes, throughline_hash: tl_hash }
    }
}

prop_compose! {
    fn arb_map()(
        anchors in proptest::collection::btree_map(arb_label(), arb_entry(), 0..6),
        supporting in proptest::collection::btree_set(arb_key(), 0..4),
    ) -> AnchorMap {
        let mut map = AnchorMap::new(Uuid::nil());
        map.anchors = anchors;
        map.supporting = supporting.into_iter().collect();
        map
    }
}

fn record(key: &str, body: &str) -> SectionRecord {
    SectionRecord {
        item_id: Uuid::nil(),
        document_id: Uuid::nil(),
        section_key: key.into(),
        title: key.into(),
        body: body.into(),
        section_type: None,
        order_index: None,
        word_count: 0,
        content_hash: None,
        created_ms: 0,
    }
}

// ─── 1. Ledger round-trip ──────────────────────────────────────────────────

proptest! {
    #[test]
    fn anchor_map_round_trips(map in arb_map()) {
        let json = map.serialize().unwrap();
        let back = AnchorMap::parse(&json).unwrap();
        prop_assert_eq!(&map, &back);
        // Serialization is deterministic (ledger diffs must be stable).
        prop_assert_eq!(json, back.serialize().unwrap());
    }
}

// ─── 2. Derivation: deterministic, exhaustive, correct on the extremes ─────

proptest! {
    #[test]
    fn derivation_is_deterministic_and_exhaustive(
        map in arb_map(),
        bodies in proptest::collection::vec(("[a-z]{1,12}", "[a-zA-Z .]{0,40}"), 0..6),
    ) {
        let sections: Vec<SectionRecord> =
            bodies.iter().map(|(k, b)| record(k, b)).collect();
        let paragraphs = extract_paragraphs("Body. <tl-x>\n");

        let a = derive_anchor_states(&map, &sections, &paragraphs);
        let b = derive_anchor_states(&map, &sections, &paragraphs);
        prop_assert_eq!(&a, &b, "derivation must be deterministic");
        prop_assert_eq!(a.len(), map.anchors.len(), "every anchor is assessed");

        for assessment in &a {
            let entry = &map.anchors[&assessment.label];
            // broken ⊆ ledger keys, and broken ∩ resolvable = ∅
            for k in &assessment.broken {
                prop_assert!(entry.section_keys.contains(k));
                prop_assert!(!sections.iter().any(|s| &s.section_key == k));
            }
            // manuscript_ahead only over resolvable keys
            for k in &assessment.manuscript_ahead {
                prop_assert!(sections.iter().any(|s| &s.section_key == k));
            }
        }
    }

    #[test]
    fn hash_equal_state_is_synced(
        keys in proptest::collection::btree_set("[a-z]{1,8}", 1..4),
        bodies in proptest::collection::vec("[a-zA-Z .]{1,30}", 4),
    ) {
        let keys: Vec<String> = keys.into_iter().collect();
        let source = "The story. <tl-a>\n";
        let paragraphs = extract_paragraphs(source);
        let sections: Vec<SectionRecord> = keys
            .iter()
            .zip(bodies.iter().cycle())
            .map(|(k, b)| record(k, b))
            .collect();

        // Ledger baselined to exactly the current hashes → synced.
        let mut map = AnchorMap::new(Uuid::nil());
        map.anchors.insert("tl-a".into(), AnchorEntry {
            section_keys: keys.clone(),
            manuscript_hashes: sections
                .iter()
                .map(|s| (s.section_key.clone(), BlobStore::sha256_hex(&s.body)))
                .collect(),
            throughline_hash: paragraphs[0].content_hash.clone(),
        });
        let states = derive_anchor_states(&map, &sections, &paragraphs);
        prop_assert_eq!(states[0].state(), "synced");
    }
}

// ─── 3. Extraction determinism + duplicate stability ───────────────────────

proptest! {
    #[test]
    fn extraction_is_deterministic_and_label_unique(
        chunks in proptest::collection::vec(("[a-z]{1,8}", "[a-zA-Z ,.]{0,40}"), 0..8),
    ) {
        let source: String = chunks
            .iter()
            .map(|(label, body)| format!("{body} <tl-{label}>\n\n"))
            .collect();
        let a = extract_paragraphs(&source);
        let b = extract_paragraphs(&source);
        prop_assert_eq!(&a, &b);
        // Labels are unique even when the generator repeats them.
        let mut labels: Vec<&str> = a.iter().map(|p| p.label.as_str()).collect();
        let before = labels.len();
        labels.dedup();
        labels.sort();
        labels.dedup();
        prop_assert_eq!(labels.len(), before, "duplicate labels must keep first only");
        // Order indexes are 0..n.
        for (i, p) in a.iter().enumerate() {
            prop_assert_eq!(p.order_index, i as i64);
        }
    }
}

// ─── 4. Derivation never writes (store-facade check) ───────────────────────

#[test]
fn derivation_through_store_never_touches_ledger() {
    let tmp = tempfile::tempdir().unwrap();
    let sections =
        Arc::new(SectionStore::open_in_memory(tmp.path().to_path_buf()).unwrap());
    let tl = ThroughlineStore::new(sections.clone());
    let doc = Uuid::new_v4();
    sections
        .put_section(doc, "intro", "body v1", SectionMetadata::default())
        .unwrap();
    tl.create_throughline(doc, "Story").unwrap();
    tl.set_anchor(doc, "tl-overview", &["intro".to_string()]).unwrap();
    let ledger_before = tl.get_throughline(doc).unwrap().unwrap().anchor_map;

    // Drift + derive repeatedly: staleness is read-only.
    sections
        .put_section(doc, "intro", "body v2", SectionMetadata::default())
        .unwrap();
    for _ in 0..3 {
        let _ = tl.anchor_states(doc).unwrap();
        let _ = tl.coverage(doc).unwrap();
        let _ = tl.repair_candidates(doc).unwrap();
    }
    let ledger_after = tl.get_throughline(doc).unwrap().unwrap().anchor_map;
    assert_eq!(ledger_before, ledger_after, "derivation must never write the ledger");
}

// ─── 5. Rebind never ambiguous or self ─────────────────────────────────────

proptest! {
    #[test]
    fn rebind_candidate_is_never_ambiguous_or_self(
        bodies in proptest::collection::vec(("[a-z]{1,8}", "[a-z .]{0,20}"), 0..8),
        target_body in "[a-z .]{1,20}",
    ) {
        let sections: Vec<SectionRecord> =
            bodies.iter().map(|(k, b)| record(k, b)).collect();
        let ledger_hash = BlobStore::sha256_hex(&target_body);
        match rebind_candidate("broken-key", Some(&ledger_hash), &sections) {
            None => {
                let matches = sections
                    .iter()
                    .filter(|s| BlobStore::sha256_hex(&s.body) == ledger_hash)
                    .count();
                prop_assert!(matches != 1 || sections.iter().any(|s|
                    s.section_key == "broken-key"
                    && BlobStore::sha256_hex(&s.body) == ledger_hash));
            }
            Some(candidate) => {
                prop_assert_ne!(&candidate, "broken-key", "never rebind to self");
                let matches = sections
                    .iter()
                    .filter(|s| s.section_key != "broken-key"
                        && BlobStore::sha256_hex(&s.body) == ledger_hash)
                    .count();
                prop_assert_eq!(matches, 1, "candidate only on an unambiguous match");
            }
        }
    }
}

// ─── Coverage is a partition ───────────────────────────────────────────────

proptest! {
    #[test]
    fn coverage_partitions_sections(
        map in arb_map(),
        keys in proptest::collection::btree_set("[a-z]{1,8}", 0..8),
    ) {
        let sections: Vec<SectionRecord> =
            keys.iter().map(|k| record(k, "b")).collect();
        let uncovered = derive_coverage(&map, &sections);
        for k in &uncovered {
            prop_assert!(!map.supporting.contains(k));
            prop_assert!(!map.anchors.values().any(|e| e.section_keys.contains(k)));
        }
        // Everything not uncovered is anchored or supporting.
        for k in keys {
            if !uncovered.contains(&k) {
                prop_assert!(
                    map.supporting.contains(&k)
                        || map.anchors.values().any(|e| e.section_keys.contains(&k))
                );
            }
        }
    }
}
