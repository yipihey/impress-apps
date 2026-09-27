//! implore's own per-app UniFFI target (plan-verb-pipeline-and-transport.md
//! § P5, ADR-0034 D2, session log P5a).
//!
//! `impress-store-ffi` is a **kit** crate (`docs/kit-manifest.md`) and
//! `scripts/check-kit-deps.sh` refuses it a dependency on any domain core —
//! confirmed live: adding `implore-service` there fails the check with "ASK
//! FIRST… this is not a dependency to allowlist". The plan's own design
//! anticipates exactly this (§ P5: "App side: a per-app UniFFI target …
//! linking the app's own `*-service` crate"), so this crate is that target:
//! it links `implore-service` directly and is not part of the kit, so the
//! check does not apply to it.
//!
//! The async native dispatch and host callback keep the app's live viewer
//! state in Swift while the Rust service remains the sole verb definition.
//! [`dispatch_verb`] remains available for non-native callers and tests.
//! Both exports have the same result shape as
//! `impress-store-ffi::verb::dispatch_verb`, and the same underlying
//! function (`impress_service_core::dispatch::dispatch`), so implore's
//! binary answers `/api/verb/<name>` for its own five previously-dead verbs
//! (`plot-series`, `plot-histogram`, `rg-statistics`, `rg-slice-raw`,
//! `rg-slice-png`) the identical way the kit's own verbs answer through the
//! shared crate.
//!
//! **What P5a finishes, and what it leaves (session log has the detail):**
//! this crate compiles, is unit-tested
//! (`crates/impress-app-transport/tests/implore_parity.rs` proves the five
//! verbs answer through it end to end, stub server included), and is a
//! real workspace member. What it does **not** yet have is its own
//! xcframework, SwiftPM package and Xcode wiring into `apps/implore` — the
//! Swift half `ImpressAutomation`'s `/api/verb/<name>` route would need to
//! call into it (today that route only calls `impress-store-ffi`'s kit
//! dispatch, so implore's live HTTP route still answers `not-found` for
//! these five until that packaging lands). That is P5b's to finish; this
//! crate's existence and its tests are the proof the Rust half is correct
//! and ready for it.

use impress_service_core::dispatch;
mod native;
pub use native::{install_native_host, ImploreVerbHost, NativeReply};

// Force the linker to keep `implore-service`'s `inventory::submit!` entries.
// Nothing in this crate calls it by name — the whole point of `dispatch` is
// to find a verb by string — so without this the linker is free to drop
// them, same reasoning as `impress-store-ffi`'s `force_link_kit`.
#[allow(unused_imports)]
use implore_service as _force_link_implore_service;

/// What [`dispatch_verb`] answers — the same shape as
/// `impress-store-ffi::verb::SharedVerbDispatchResult` (kept as its own
/// type, not a shared one, because each is a distinct UniFFI crate with its
/// own generated Swift binding; see the module doc for why two crates exist
/// at all).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedVerbDispatchResult {
    pub status: u16,
    pub body_json: String,
}

impl From<dispatch::DispatchResult> for SharedVerbDispatchResult {
    fn from(result: dispatch::DispatchResult) -> Self {
        Self {
            status: result.status,
            body_json: result.body_json,
        }
    }
}

#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

/// Dispatch one verb by its qualified name (`<service>_<method>`) through
/// the invoker pipeline, on whatever this binary links — `implore-service`
/// and the kit both, once this crate and `impress-store-ffi` are linked
/// into the same app.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn dispatch_verb(
    name: String,
    args_json: String,
    caller_json: String,
) -> SharedVerbDispatchResult {
    dispatch::dispatch(&name, &args_json, &caller_json).into()
}

/// Native app dispatch must not block the Swift main actor while a service
/// method calls back into the app's live viewer or figure state.
#[cfg_attr(feature = "native", uniffi::export)]
pub async fn dispatch_verb_async(
    name: String,
    args_json: String,
    caller_json: String,
) -> SharedVerbDispatchResult {
    dispatch::dispatch_async(&name, &args_json, &caller_json)
        .await
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn every_previously_dead_implore_verb_is_reachable_by_name() {
        for name in [
            "implore-service_plot-series",
            "implore-service_plot-histogram",
            "implore-service_rg-statistics",
            "implore-service_rg-slice-raw",
            "implore-service_rg-slice-png",
        ] {
            let answer = dispatch_verb(
                name.into(),
                "{}".into(),
                r#"{"kind":"app","name":"implore"}"#.into(),
            );
            let body: Value = serde_json::from_str(&answer.body_json).unwrap();
            assert_ne!(
                body.get("code").and_then(Value::as_str),
                Some("not-found"),
                "{name} should be in implore's own inventory"
            );
        }
    }

    #[test]
    fn an_unknown_verb_is_not_found() {
        let answer = dispatch_verb(
            "nonexistent-service_nope".into(),
            "{}".into(),
            r#"{"kind":"app","name":"implore"}"#.into(),
        );
        assert_eq!(answer.status, 404);
    }
}
