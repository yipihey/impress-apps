//! UniFFI binding generator binary
//!
//! Generates Swift/Kotlin bindings from the impress-store-ffi library.
//! Run with: cargo run --bin uniffi-bindgen generate --library <path> --language swift --out-dir <dir>

fn main() {
    uniffi::uniffi_bindgen_main()
}
