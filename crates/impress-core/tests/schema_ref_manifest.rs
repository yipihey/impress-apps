//! Registry ↔ manifest parity for impress-core.
//!
//! The store matches `items.schema_ref` by EXACT EQUALITY, so a schema id that
//! drifts away from what call sites spell produces a silently-empty query
//! rather than an error. `schema-refs.json` at the repo root is the single
//! source of truth for the vocabulary; `scripts/check-schema-refs.sh` holds
//! call sites to it. This test holds the OTHER side to it — the registry — so
//! the manifest cannot quietly describe a registry that no longer exists.
//!
//! Deliberately BOTH directions and per-crate. One direction ("every
//! registered id is in the manifest") would let a manifest entry outlive the
//! schema it names; the reverse alone would let a new schema go undeclared.
//! Per-crate because no single crate depends on every registry, and a
//! partial union assertion is not exhaustive for anybody.

use std::collections::BTreeSet;

#[path = "support/schema_ref_manifest_support.rs"]
mod manifest;

#[test]
fn impress_core_registry_matches_manifest() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    impress_core::schemas::register_core_schemas(&mut registry);

    let registered: BTreeSet<String> = registry.list().iter().map(|s| s.id.clone()).collect();
    let declared = manifest::registry_ids("impress-core");

    manifest::assert_same_set("impress-core", &registered, &declared);
}

/// Every id impress-core registers must be declared usable-or-dead. A schema
/// that is in neither bucket has no documented writer, which is precisely the
/// state `bibliography-entry` was in when the iOS citation picker asked for it.
#[test]
fn every_registered_id_is_classified() {
    let m = manifest::load();
    let classified = manifest::classified_refs(&m);
    for id in manifest::registry_ids("impress-core") {
        assert!(
            classified.contains(&id),
            "impress-core registers {id:?} but schema-refs.json lists it in \
             neither `canonical` nor `registeredButUnwritten`. Classify it: \
             if something writes it, add it to `canonical` naming the writer; \
             if nothing does, add it to `registeredButUnwritten` so the lint \
             rejects querying it."
        );
    }
}

/// The bug class in one assertion: no two canonical refs may differ only by an
/// `@version` suffix. If both `x` and `x@1.0.0` were canonical, a writer and a
/// reader could each pick one, pass the lint, and still never meet.
#[test]
fn canonical_has_one_spelling_per_base_name() {
    let m = manifest::load();
    let diverging = manifest::diverging_refs(&m);
    let mut by_base: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for r in m["canonical"].as_object().expect("canonical").keys() {
        by_base
            .entry(manifest::base_name(r))
            .or_default()
            .push(r.clone());
    }
    for (base, refs) in by_base {
        if refs.len() > 1 && !refs.iter().all(|r| diverging.contains(r)) {
            panic!(
                "{} canonical spellings of {base:?} ({}). A kind gets ONE \
                 canonical ref, or the pair is declared in knownDivergences \
                 with a reason.",
                refs.len(),
                refs.join(", ")
            );
        }
    }
}
