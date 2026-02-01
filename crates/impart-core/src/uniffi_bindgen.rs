//! UniFFI binding generator binary.
//!
//! Run with: cargo run --bin uniffi-bindgen --features native -- generate ...

fn main() {
    uniffi::uniffi_bindgen_main()
}
