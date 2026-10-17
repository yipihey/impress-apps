//! The xcframework shell around koine's `impress-helix` (Helix-style modal
//! editing; docs/plan-koine-kit-moves.md KM6). The crate itself, and its
//! UniFFI interface behind `ffi`, are koine's; this package exists so this
//! workspace can build that interface as the `ImpressHelix` staticlib
//! (`build-xcframework.sh`). A staticlib carries every dependency's object
//! code, so the koine crate's exports are in it unchanged.

pub use impress_helix::*;
