use std::collections::BTreeSet;

#[path = "../../impress-core/tests/support/schema_ref_manifest_support.rs"]
mod manifest;

#[test]
fn vw_registry_matches_manifest() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    vw_impress_adapter::register_vw_schemas(&mut registry);

    let registered: BTreeSet<String> = registry
        .list()
        .iter()
        .map(|schema| schema.id.clone())
        .collect();
    let declared = manifest::registry_ids("vw-impress-adapter");
    manifest::assert_same_set("vw-impress-adapter", &registered, &declared);
}
