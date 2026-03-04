//! UniFFI binding generator binary.
//!
//! Run with: cargo run --bin uniffi-bindgen --features native -- generate \
//!     --library target/<target>/release/libscix_client_ffi.dylib \
//!     --language swift \
//!     --out-dir <dir>

fn main() {
    uniffi::uniffi_bindgen_main()
}
