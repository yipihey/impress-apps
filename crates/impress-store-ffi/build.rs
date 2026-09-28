//! Build script for impress-store-ffi
//!
//! Using proc-macro based UniFFI — no UDL scaffolding needed.
//! uniffi::setup_scaffolding!() in lib.rs handles everything.

#[path = "../impress-core/schema_ref_codegen.rs"]
mod schema_ref_codegen;

fn main() {
    // Without this pin cargo fingerprints every unignored file in the crate
    // dir, so editing build-xcframework.sh (or any stray file here) relinks
    // the whole crate for nothing.
    println!("cargo::rerun-if-changed=build.rs");
    schema_ref_codegen::generate();
}
