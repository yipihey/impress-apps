//! The ADR-0033 D7 standalone-kit slice of the linked inventory.
//!
//! `impress-capabilities` (ADR-0033 D4) is the one place the whole suite's
//! `#[impress_service]` inventory is linked — but `impress-store-ffi` (the
//! app binary's Rust) cannot depend on it: Cargo's cyclic-package check walks
//! every dependency a manifest lists, even an optional one behind a feature
//! that is off, and `impress-capabilities` reaches back around to
//! `impress-store-ffi` through `impress-bridges-service -> imprint-service ->
//! impress-app-client -> imbib-service-http -> impress-store-ffi`. See
//! `crates/impress-store-ffi/Cargo.toml`'s module comment for the exact edge.
//!
//! This crate is the fix: it holds exactly the four `*-service` crates
//! ADR-0033 D7 calls "the kit" (`impress-store-service`,
//! `impress-layout-service`, `impress-surface-service`,
//! `surface-demo-service`), plus `impress-service-core`, and nothing that
//! reaches back to `impress-store-ffi` — verified with
//! `cargo tree -p impress-capabilities-kit -e normal | grep -c impress-store-ffi`
//! (must print `0`; `scripts/check-kit-deps.sh` is the sibling check for D7's
//! "no kit crate depends on impress-core's domain modules" rule). Both
//! `impress-store-ffi` and `impress-capabilities` (behind its `kit` feature,
//! see that crate's docs) depend on this crate directly, so the four kit
//! crates are named in exactly one place instead of two force-link lists
//! drifting against each other — the same "one list" problem ADR-0033 D4's
//! module docs on `impress-capabilities` describe for the pre-existing
//! `impress-mcp`/`impress-cli` split, one level down the tree.
//!
//! # Why a linker workaround at all
//!
//! `inventory::submit!` registers a `static` at link time via a platform
//! link-section trick (akin to `ctor`). If nothing in the dependency graph
//! that reaches the final binary ever *references* a symbol from a crate that
//! only contains such statics, the linker is free to drop that crate's object
//! code entirely — dead-code elimination has no way to know the statics
//! matter, because nothing calls them by name. [`force_link`] exists to be
//! that reference: it is a real, callable, non-generic function, so a binary
//! that calls it (even though the call does nothing observable) cannot have
//! this crate — or, transitively, the four service crates it force-links —
//! stripped from the link.
//!
//! `impress-layout-service` and `impress-surface-service` also get real,
//! ordinary references from most consumers (`impress-store-ffi`'s
//! `layout.rs`/`surface.rs` name their types directly), so [`force_link`]'s
//! main job in practice is `impress-store-service` and `surface-demo-service`,
//! which nothing outside their own tests calls by name — but all four are
//! force-linked unconditionally here so no caller of this crate has to know
//! which two need the help.

#![forbid(unsafe_code)]

// ---------------------------------------------------------------------------
// Force-link
// ---------------------------------------------------------------------------
//
// One `use X as _;` per kit crate — all four are plain (non-optional)
// dependencies of this crate, so all four are always linked when this crate
// is. See the module docs above for why a `use` alone is not sufficient on
// its own to keep them in the FINAL BINARY's link: [`force_link`] is the real
// reference a binary must call — and, since 2026-09-22, the real reference
// force_link itself must make. An empty `force_link()` retained this crate
// and nothing else.

#[allow(unused_imports)]
use impress_layout_service as _force_link_layout_service;
#[allow(unused_imports)]
use impress_store_service as _force_link_store_service;
#[allow(unused_imports)]
use impress_surface_service as _force_link_surface_service;
#[allow(unused_imports)]
use surface_demo_service as _force_link_surface_demo_service;

/// Force the linker to retain all four kit crates' `inventory::submit!`
/// entries.
///
/// Call this once, early, from any binary that links this crate — a plain
/// dependency edge in Cargo.toml is not enough by itself, for the same reason
/// the module docs give for the `use X as _;` statements above one level
/// down: if nothing in the FINAL BINARY's own compiled code ever calls
/// anything this crate exports, the linker is free to drop this whole crate,
/// taking every service crate it force-links with it.
///
/// `impress-capabilities`'s own `force_link()` (behind its `kit` feature)
/// calls this one; `impress-store-ffi` calls it directly (see that crate's
/// `lib.rs`) since it has no other real reference to `impress-store-service`
/// or `surface-demo-service`.
pub fn force_link() {
    // FUNCTION POINTERS, not calls. `use X as _;` above proves this crate
    // names the crate; it does not make the final binary reference anything
    // IN it, and an empty body here does not either — so the linker was free
    // to drop all four rlibs and, with them, every `inventory::submit!` the
    // `#[impress_service]` macro emits. That is not theoretical: with this
    // body empty, the impress app rendered an agent surface whose `plot`
    // read "template path '{{source.hist.plot}}' did not resolve to a value"
    // — `surface-demo-service_histogram` was simply not in the app's
    // inventory, while the same surface rendered correctly from impress-mcp,
    // which links the services by other paths (verified live 2026-09-22).
    //
    // Taking a constructor's address is a real relocation into each crate and
    // costs nothing at runtime; calling them would build four services for no
    // reason. `black_box` keeps the optimiser from noticing the array is
    // unused. This is the same shape `impress-cli`'s per-crate
    // `_*_FORCE_LINK` consts have always had.
    let anchors: [*const (); 4] = [
        impress_store_service::DefaultStoreQueryService::new as *const (),
        impress_layout_service::DefaultLayoutService::new as *const (),
        impress_surface_service::DefaultImpressSurfaceService::new as *const (),
        surface_demo_service::DefaultSurfaceDemoService::new as *const (),
    ];
    std::hint::black_box(anchors);
}

// ---------------------------------------------------------------------------
// Descriptor lookup and call
// ---------------------------------------------------------------------------
//
// Moved to `impress_service_core::call` (review RS-S21) so
// `impress-surface-service`, which this crate depends on, runs verbs through
// the same code rather than a copy of it. Re-exported here so
// `impress-store-ffi` and `impress-capabilities` (behind its `kit` feature)
// compile unchanged.
pub use impress_service_core::call::{call, call_async, descriptors, find, CallError};

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// All four kit crates must be linked in — an empty inventory here would
    /// mean this crate's own dependency edges silently failed to force-link,
    /// the exact failure this crate exists to prevent.
    #[test]
    fn descriptors_are_non_empty() {
        assert!(
            descriptors().next().is_some(),
            "no McpToolDescriptor is linked in — the kit crates did not force-link"
        );
    }

    /// The two demo/surface verbs D7's plan calls out by name must be
    /// reachable through this crate's own inventory read, independent of
    /// whatever `impress-capabilities` does with its `kit` feature.
    #[test]
    fn descriptors_include_the_kit_verbs() {
        let names: Vec<&str> = descriptors().map(|d| d.name).collect();
        assert!(
            names.contains(&"surface-demo-service_series"),
            "surface-demo-service_series missing; got: {names:?}"
        );
        assert!(
            names.contains(&"impress-surface-service_surface-schema"),
            "impress-surface-service_surface-schema missing; got: {names:?}"
        );
    }

    #[test]
    fn call_series_returns_the_requested_length() {
        let result = call(
            "surface-demo-service_series",
            json!({ "freq": 1.0, "n": 16 }),
        )
        .expect("series succeeded");
        assert_eq!(result["values"].as_array().unwrap().len(), 16);
    }

    #[test]
    fn call_of_unknown_tool_is_unknown_tool() {
        let err = call("no-such-tool", json!({})).expect_err("unknown tool errors");
        assert!(
            matches!(err, CallError::UnknownTool(ref n) if n == "no-such-tool"),
            "unexpected error: {err:?}"
        );
        assert_eq!(err.to_string(), "Unknown tool: no-such-tool");
    }

    #[test]
    fn find_of_unknown_tool_is_none() {
        assert!(find("no-such-tool").is_none());
    }
}
