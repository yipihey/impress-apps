//! Registry ↔ manifest parity for imbib-core. See
//! `crates/impress-core/tests/schema_ref_manifest.rs` for the rationale.
//!
//! imbib-core is where the bug class first bit: it registers and writes
//! `imbib/bibliography-entry`, while impress-core registers a bare
//! `bibliography-entry` that nothing writes. The iOS citation picker asked for
//! the bare form and reported an empty library 100% of the time, with no error
//! anywhere. This test keeps the manifest's record of that split honest.

use std::collections::BTreeSet;

#[path = "../../impress-core/tests/support/schema_ref_manifest_support.rs"]
mod manifest;

#[test]
fn imbib_core_registry_matches_manifest() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    imbib_core::unified::schemas::register_all(&mut registry);

    let registered: BTreeSet<String> = registry.list().iter().map(|s| s.id.clone()).collect();
    let declared = manifest::registry_ids("imbib-core");

    manifest::assert_same_set("imbib-core", &registered, &declared);
}

#[test]
fn every_registered_id_is_classified() {
    let m = manifest::load();
    let classified = manifest::classified_refs(&m);
    for id in manifest::registry_ids("imbib-core") {
        assert!(
            classified.contains(&id),
            "imbib-core registers {id:?} but schema-refs.json lists it in \
             neither `canonical` nor `registeredButUnwritten`."
        );
    }
}

/// The publication ref is namespaced, and the bare form is NOT a synonym.
/// Pinned explicitly because this is the exact pair a reader guesses wrong.
#[test]
fn publication_ref_is_namespaced_and_bare_form_is_not_canonical_for_imbib() {
    let declared = manifest::registry_ids("imbib-core");
    assert!(
        declared.contains("imbib/bibliography-entry"),
        "imbib publications are written as `imbib/bibliography-entry`"
    );
    assert!(
        !declared.contains("bibliography-entry"),
        "imbib-core must not register the bare `bibliography-entry` — that \
         spelling belongs to impress-core and nothing writes it"
    );
}
