//! UniFFI binding generator binary
//!
//! This binary is used to generate Swift/Kotlin bindings from the Rust library.
//! Run with: cargo run --features ffi --bin uniffi-bindgen generate --library <path> --language swift --out-dir <dir>

fn main() {
    uniffi::uniffi_bindgen_main()
}
