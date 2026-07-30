//! Shared helpers for the per-crate `schema_ref_manifest` parity tests.
//!
//! Included by `#[path]` rather than published as a crate: the four crates that
//! register schemas (impress-core, imbib-core, impel-core, impart-core) have no
//! dependency edges between them, and adding one just to share sixty lines of
//! test support would be a worse trade than the explicit path. Living in
//! `tests/support/` (a subdirectory) keeps cargo from compiling it as its own
//! integration-test binary.

#![allow(dead_code)]

use std::collections::BTreeSet;

/// Repo root, derived from the including crate's manifest dir
/// (`<root>/crates/<crate>` → `<root>`), so the tests are location-independent.
pub fn repo_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("crate dir should be <repo>/crates/<name>")
        .to_path_buf()
}

pub fn load() -> serde_json::Value {
    let path = repo_root().join("schema-refs.json");
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// `"figure@1.0.0"` → `"figure"`.
pub fn base_name(schema_ref: &str) -> String {
    schema_ref
        .split('@')
        .next()
        .unwrap_or(schema_ref)
        .to_string()
}

/// The ids `schema-refs.json` says the named crate registers.
pub fn registry_ids(crate_name: &str) -> BTreeSet<String> {
    let m = load();
    m["registries"][crate_name]
        .as_array()
        .unwrap_or_else(|| panic!("schema-refs.json has no `registries.{crate_name}` array"))
        .iter()
        .map(|v| {
            v.as_str()
                .expect("registry id must be a string")
                .to_string()
        })
        .collect()
}

/// Every ref classified as either usable (`canonical`) or explicitly dead
/// (`registeredButUnwritten`).
pub fn classified_refs(m: &serde_json::Value) -> BTreeSet<String> {
    ["canonical", "registeredButUnwritten"]
        .iter()
        .flat_map(|key| {
            m[key]
                .as_object()
                .unwrap_or_else(|| panic!("schema-refs.json `{key}` must be an object"))
                .keys()
                .cloned()
        })
        .collect()
}

/// Refs named by a `knownDivergences` entry — spellings that genuinely
/// disagree in live data and are tracked rather than silently blessed.
pub fn diverging_refs(m: &serde_json::Value) -> BTreeSet<String> {
    m["knownDivergences"]
        .as_array()
        .expect("knownDivergences must be an array")
        .iter()
        .flat_map(|d| {
            d["refs"]
                .as_array()
                .expect("divergence.refs must be an array")
                .iter()
                .map(|v| v.as_str().expect("ref must be a string").to_string())
        })
        .collect()
}

/// Both-directions set equality with a message that says what to do.
pub fn assert_same_set(
    crate_name: &str,
    registered: &BTreeSet<String>,
    declared: &BTreeSet<String>,
) {
    let unregistered: Vec<_> = declared.difference(registered).cloned().collect();
    let undeclared: Vec<_> = registered.difference(declared).cloned().collect();

    assert!(
        unregistered.is_empty() && undeclared.is_empty(),
        "schema-refs.json `registries.{crate_name}` is out of sync with the live registry.\n\
         \n\
         Declared in the manifest but NOT registered: {unregistered:?}\n\
         Registered but NOT declared in the manifest: {undeclared:?}\n\
         \n\
         Update `registries.{crate_name}` in schema-refs.json in the same change. If a\n\
         schema is new, also classify it under `canonical` (naming its writer) or\n\
         `registeredButUnwritten` — otherwise scripts/check-schema-refs.sh will reject\n\
         every call site that uses it."
    );
}
