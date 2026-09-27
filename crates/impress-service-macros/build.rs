//! Embed the canonical schema refs so `effects = { reads: ["…"] }` can be
//! checked at expansion time (ADR-0036 D1: a misspelt ref is a compile error,
//! which is what the manifest rule exists for — see CLAUDE.md § schema refs).
//!
//! The manifest is read from the repository root. When it is absent (the
//! kit's standalone scratch workspace, `scripts/check-kit-standalone.sh`,
//! copies crates and `docs/` only) the list is empty and the check is
//! skipped there; the descriptor test in `impress-capabilities` checks every
//! linked declaration against the same file, so nothing is unchecked in CI.

use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let manifest = Path::new(&manifest_dir).join("../../schema-refs.json");
    println!("cargo:rerun-if-changed={}", manifest.display());
    println!("cargo:rerun-if-changed=build.rs");

    let mut refs: Vec<String> = Vec::new();
    if let Ok(text) = fs::read_to_string(&manifest) {
        let json: serde_json::Value =
            serde_json::from_str(&text).expect("schema-refs.json is JSON");
        if let Some(canonical) = json.get("canonical").and_then(|c| c.as_object()) {
            refs.extend(canonical.keys().cloned());
        }
        refs.sort();
    }

    let out = Path::new(&env::var("OUT_DIR").expect("OUT_DIR")).join("schema_refs.rs");
    let mut body = String::from(
        "/// The manifest's `canonical` keys, or empty when the manifest was not beside the \
         workspace at build time.\npub const CANONICAL_SCHEMA_REFS: &[&str] = &[\n",
    );
    for r in &refs {
        body.push_str(&format!("    {r:?},\n"));
    }
    body.push_str("];\n");
    fs::write(&out, body).expect("write schema_refs.rs");
}
