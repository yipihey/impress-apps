//! UniFFI bindgen binary for generating Swift bindings
//!
//! Run with: cargo run --features native --bin uniffi-bindgen

fn main() {
    uniffi::uniffi_bindgen_main()
}
