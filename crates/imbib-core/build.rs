//! Build script for imbib-core
//!
//! Using proc-macro based UniFFI, no UDL scaffolding needed.

fn main() {
    // No UDL scaffolding needed when using proc macros exclusively
    // The uniffi::setup_scaffolding!() macro handles everything
    //
    // Without this pin cargo fingerprints every unignored file in the crate
    // dir, so editing build-xcframework.sh (or any stray file here) relinks
    // the whole crate for nothing.
    println!("cargo::rerun-if-changed=build.rs");
}
