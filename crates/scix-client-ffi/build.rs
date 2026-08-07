// No UDL scaffolding needed — proc-macro based UniFFI.
// uniffi::setup_scaffolding!() in lib.rs handles everything.
fn main() {
    // Without this pin cargo fingerprints every unignored file in the crate
    // dir, so editing build-xcframework.sh (or any stray file here) relinks
    // the whole crate for nothing.
    println!("cargo::rerun-if-changed=build.rs");
}
