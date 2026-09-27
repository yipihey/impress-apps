//! R2: the FFI export for `impress-keymap`'s registry. Thin on purpose — this
//! crate translates, it never decides anything about a chord (same division
//! `layout.rs` draws for the layout tree). See `impress-keymap`'s crate docs
//! for the JSON shape.

/// The keymap registry as JSON: `{"wire_version": 1, "bindings": [...]}`.
/// Settings ▸ Keyboard and the ⌘/ window read this instead of a Swift-side
/// table, and `docs/keyboard.md` is generated from the same registry this
/// serializes (`impress-keymap`'s `render_markdown`). Already a JSON string
/// from `impress-keymap::keymap_json` — passed through, not re-encoded.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn keymap_json() -> String {
    impress_keymap::keymap_json()
}
