//! The one place the `#[impress_service]` inventory is linked (ADR-0033 D4).
//!
//! Every `*-service` crate registers its verbs into two process-wide
//! `inventory` collections — `McpToolDescriptor` and `CliSubcommand` — as a
//! side effect of being *linked into the final binary*, not of anyone calling
//! it. Before this crate existed, `crates/impress-mcp` and `crates/impress-cli`
//! each kept their own list of `#[allow(unused_imports)] use X as _force_link_X;`
//! lines to make sure the linker didn't drop the whole rlib for lack of a real
//! reference — and they disagreed: impress-mcp linked fourteen service crates,
//! impress-cli linked seven, and the running app binary linked only one
//! (`impress-layout-service`). Three copies of "which capabilities exist,"
//! never checked against each other. This crate is the one list.
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
//! this crate — or, transitively, the service crates it re-exports below —
//! stripped from the link.
//!
//! # Feature sets
//!
//! One feature per domain service crate (`imbib`, `impart`, `impel`,
//! `implore`, `imprint`, `ai`, `bridges`, `memory`, `parsers`,
//! `smart-search`, `vw`), each gating one optional dependency (`imprint`
//! gates two: `imprint-service` and `imprint-selftest` are one capability
//! family). `full` (the default) is every domain feature plus `kit`, for
//! `impress-mcp` and `impress-cli`, which must see everything. `kit` is the
//! ADR-0033 D7 standalone cut — store, layout and the two surface crates.
//! Native bindings select `default-features = false, features = ["kit"]`;
//! clients select their domain features or `full`. Domain services use the
//! Rust store directly, so the FFI no longer needs a separate inventory crate.

#![forbid(unsafe_code)]

// ---------------------------------------------------------------------------
// Force-link
// ---------------------------------------------------------------------------
//
// One `use X as _;` per enabled service crate — the exact mechanism
// `crates/impress-mcp/src/main.rs` used before this crate existed (see that
// file's history), preserved here rather than reinvented so there is one
// documented idiom for it in the workspace. `#[allow(unused_imports)]`
// because the alias is never read; its only job is to be a real reference
// the linker cannot ignore.

#[cfg(feature = "impact")]
#[allow(unused_imports)]
use capabilities_service as _force_link_capabilities_service;
#[cfg(feature = "imbib")]
#[allow(unused_imports)]
use imbib_service as _force_link_imbib_service;
#[cfg(feature = "impart")]
#[allow(unused_imports)]
use impart_service as _force_link_impart_service;
#[cfg(feature = "impel")]
#[allow(unused_imports)]
use impel_service as _force_link_impel_service;
#[cfg(feature = "implore")]
#[allow(unused_imports)]
use implore_service as _force_link_implore_service;
#[cfg(feature = "ai")]
#[allow(unused_imports)]
use impress_ai_service as _force_link_ai_service;
#[cfg(feature = "bridges")]
#[allow(unused_imports)]
use impress_bridges_service as _force_link_bridges_service;
#[cfg(feature = "memory")]
#[allow(unused_imports)]
use impress_memory_service as _force_link_memory_service;
#[cfg(feature = "parsers")]
#[allow(unused_imports)]
use impress_parsers_service as _force_link_parsers_service;
#[cfg(feature = "scenario")]
#[allow(unused_imports)]
use impress_scenario_service as _force_link_scenario_service;
#[cfg(feature = "smart-search")]
#[allow(unused_imports)]
use impress_smart_search_service as _force_link_smart_search_service;
#[cfg(feature = "workflow")]
#[allow(unused_imports)]
use impress_workflow_service as _force_link_workflow_service;
#[cfg(feature = "imprint")]
#[allow(unused_imports)]
use imprint_selftest as _force_link_imprint_selftest;
#[cfg(feature = "imprint")]
#[allow(unused_imports)]
use imprint_service as _force_link_imprint_service;
#[cfg(feature = "perf")]
#[allow(unused_imports)]
use perf_service as _force_link_perf_service;
#[cfg(feature = "vw")]
#[allow(unused_imports)]
use vw_impress_adapter as _force_link_vw_impress_adapter;
// P3c step 1: NOT part of `full` — only `impress-mcp` enables this feature.
// See the `semantic-search` feature's doc comment in Cargo.toml.
#[cfg(feature = "semantic-search")]
#[allow(unused_imports)]
use imbib_semantic_service as _force_link_imbib_semantic_service;

/// Force the linker to retain every enabled service crate's `inventory::submit!`
/// entries.
///
/// Call this once, early, from any binary that links this crate — a plain
/// dependency edge in Cargo.toml is not enough by itself, for the same reason
/// the module docs give for the `use X as _;` statements above one level
/// down: if nothing in the FINAL BINARY's own compiled code ever calls
/// anything `impress-capabilities` exports, the linker is free to drop this
/// whole crate, taking every service crate it force-links with it.
/// `impress-mcp` needs no separate call: `inventory_bridge.rs` already calls
/// `descriptors()`/`call()` for real, and that is itself the needed
/// reference. `impress-cli` calls this explicitly in `main()`, because its
/// own dispatch reads the process-wide `CliSubcommand` inventory through
/// `impress_service_core::cli` rather than through anything this crate
/// exports, so without an explicit call it would make no reference to
/// this inventory at all.
pub fn force_link() {
    #[cfg(feature = "kit")]
    {
        // Real relocations retain kit registrations even when no caller
        // otherwise names their constructors (the S6 surface-demo regression).
        let anchors: [*const (); 4] = [
            impress_store_service::DefaultStoreQueryService::new as *const (),
            impress_layout_service::DefaultLayoutService::new as *const (),
            impress_surface_service::DefaultImpressSurfaceService::new as *const (),
            surface_demo_service::DefaultSurfaceDemoService::new as *const (),
        ];
        std::hint::black_box(anchors);
    }
}

// ---------------------------------------------------------------------------
// Descriptor lookup and call
// ---------------------------------------------------------------------------
//
// Lookup and calls belong to service-core so every invocation uses the
// same pipeline, including a kit-only embedding.
pub use impress_service_core::call::{
    call, call_as, call_async, call_async_as, descriptors, find, CallError,
};

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// `full` (the default feature set) must link at least one real tool —
    /// an empty inventory here would mean every service crate's features
    /// silently failed to enable, the exact failure this crate exists to
    /// prevent.
    #[cfg(feature = "kit")]
    #[test]
    fn kit_force_link_keeps_surface_demo_and_surface_verbs() {
        force_link();
        assert!(find("impress-surface-service_surface-schema").is_some());
        let answer = call("surface-demo-service_series", json!({"freq":1.0,"n":16})).unwrap();
        assert_eq!(answer["values"].as_array().unwrap().len(), 16);
    }

    #[test]
    fn descriptors_are_non_empty() {
        assert!(
            descriptors().next().is_some(),
            "no McpToolDescriptor is linked in — check this build's enabled features"
        );
    }

    /// The same cheap tool `impress-mcp`'s own bridge test called before the
    /// move (`imbib-text-service_decode-latex`), round-tripped through the
    /// moved function.
    #[cfg(feature = "imbib")]
    #[test]
    fn call_decode_latex_round_trips() {
        let result = call(
            "imbib-text-service_decode-latex",
            json!({ "input": "Caf\\'{e}" }),
        )
        .expect("decode-latex succeeded");
        assert_eq!(result.as_str(), Some("Café"));
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
