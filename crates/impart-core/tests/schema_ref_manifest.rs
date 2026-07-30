//! Registry ↔ manifest parity for impart-core. See
//! `crates/impress-core/tests/schema_ref_manifest.rs` for the rationale.
//!
//! impart re-registers `chat-message` / `email-message` with the same ids
//! impress-core uses, which is deliberate (one vocabulary, two registries) and
//! is exactly the situation where a well-meaning namespace prefix would break
//! every reader in the suite. This test makes that a decision rather than an
//! accident.

use std::collections::BTreeSet;

#[path = "../../impress-core/tests/support/schema_ref_manifest_support.rs"]
mod manifest;

#[test]
fn impart_core_registry_matches_manifest() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    impart_core::schemas::register_impart_schemas(&mut registry);

    let registered: BTreeSet<String> = registry.list().iter().map(|s| s.id.clone()).collect();
    let declared = manifest::registry_ids("impart-core");

    manifest::assert_same_set("impart-core", &registered, &declared);
}

#[test]
fn every_registered_id_is_classified() {
    let m = manifest::load();
    let classified = manifest::classified_refs(&m);
    for id in manifest::registry_ids("impart-core") {
        assert!(
            classified.contains(&id),
            "impart-core registers {id:?} but schema-refs.json lists it in \
             neither `canonical` nor `registeredButUnwritten`."
        );
    }
}

/// Message refs are BARE and UNNAMESPACED on purpose: imbib's chassis reads
/// the same rows impart writes (`MailStoreReader`, the Messages record kind).
/// Prefixing them `impart/` would empty every message surface outside impart.
#[test]
fn message_refs_stay_unnamespaced() {
    for id in manifest::registry_ids("impart-core") {
        assert!(
            !id.contains('/'),
            "{id:?} gained a namespace; imbib's MailStoreReader queries the \
             bare form and would silently return zero rows"
        );
    }
}
