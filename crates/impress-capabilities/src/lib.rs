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
//! ADR-0033 D7 standalone cut — store, layout and the two surface crates —
//! and is a single dependency on `impress-capabilities-kit`, which holds
//! those four crates directly (see that crate's module docs for why they
//! live there and not here: `impress-store-ffi`, the crate `kit` exists for,
//! cannot depend on this crate at all without a package cycle). This crate
//! re-exports `impress-capabilities-kit`'s [`descriptors`], [`find`],
//! [`call`], [`call_async`] and [`CallError`] behind the `kit` feature so
//! every existing caller (`impress-mcp`'s `inventory_bridge`,
//! `impress-cli`) compiles unchanged.

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
#[cfg(feature = "smart-search")]
#[allow(unused_imports)]
use impress_smart_search_service as _force_link_smart_search_service;
#[cfg(feature = "imprint")]
#[allow(unused_imports)]
use imprint_selftest as _force_link_imprint_selftest;
#[cfg(feature = "imprint")]
#[allow(unused_imports)]
use imprint_service as _force_link_imprint_service;
#[cfg(feature = "vw")]
#[allow(unused_imports)]
use vw_impress_adapter as _force_link_vw_impress_adapter;

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
/// `impress-capabilities` at all. Delegates to
/// [`impress_capabilities_kit::force_link`] (behind the `kit` feature) for
/// the four kit crates, on top of the domain `use X as _;` links above — its
/// own body does nothing else observable; its only job is to exist as a
/// real, callable symbol.
pub fn force_link() {
    #[cfg(feature = "kit")]
    impress_capabilities_kit::force_link();
}

// ---------------------------------------------------------------------------
// Descriptor lookup and call
// ---------------------------------------------------------------------------
//
// Moved to `impress-capabilities-kit` (ADR-0033 D7 / plan S6) so
// `impress-store-ffi` can call them without depending on this crate at all —
// see that crate's module docs for why. Re-exported here, verbatim, behind
// the `kit` feature so every existing caller (`impress-mcp`'s
// `inventory_bridge`, `impress-cli`) compiles unchanged.
#[cfg(feature = "kit")]
pub use impress_capabilities_kit::{call, call_async, descriptors, find, CallError};

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// `full` (the default feature set) must link at least one real tool —
    /// an empty inventory here would mean every service crate's features
    /// silently failed to enable, the exact failure this crate exists to
    /// prevent.
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
