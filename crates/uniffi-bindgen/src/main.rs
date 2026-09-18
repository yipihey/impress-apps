//! The one binding generator for the workspace.
//!
//! Invoked by every `crates/*/build-xcframework.sh` in `--library` mode, which
//! reads the UniFFI metadata straight out of the built static archive:
//!
//!     cargo run --release -p uniffi-bindgen -- generate \
//!         --library target/aarch64-apple-darwin/release/libimbib_core.a \
//!         --language swift --out-dir <dir>
//!
//! Library mode resolves each crate's `uniffi.toml` by running `cargo metadata`
//! in the current directory, so run it from anywhere inside this workspace.
fn main() {
    uniffi::uniffi_bindgen_main()
}
