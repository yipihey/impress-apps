# Vendored Typst packages

The pinned `@preview` closure the suite's embedded Typst engines resolve
offline (see `crates/imprint-core/src/typst_packages.rs`). Shipped into every
app bundle that compiles Typst via a folder-reference resource in the app's
`project.yml`, landing at `Contents/Resources/typst-packages` (macOS) /
`<bundle>/typst-packages` (iOS).

Update with `scripts/sync-typst-packages.sh` after warming the typst CLI cache
(`typst compile` any file importing the packages). komet ships a `.wasm`
plugin — the sync must preserve it byte-for-byte.
