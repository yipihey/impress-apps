//! The one place the `#[impress_service]` inventory is linked (ADR-0033 D4).
//!
//! Every `*-service` crate registers its verbs into two process-wide
//! `inventory` collections — [`McpToolDescriptor`] and `CliSubcommand` — as a
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
//! One feature per service crate (`imbib`, `impart`, `impel`, `implore`,
//! `imprint`, `ai`, `bridges`, `layout`, `memory`, `parsers`,
//! `smart-search`, `store`, `vw`, `surface`, `surface-demo`), each gating one
//! optional dependency (`imprint` gates two: `imprint-service` and
//! `imprint-selftest` are one capability family). `full` (the default) is
//! every feature, for `impress-mcp` and `impress-cli`, which must see
//! everything. `kit` is the ADR-0033 D7 standalone cut: `store`, `layout` and
//! the two surface crates — never a per-app domain core, which already ships
//! as its own xcframework and must not be linked into the FFI a second time
//! (see that ADR's D4/D7 and `impress-store-ffi`, the crate `kit` exists for).
//!
//! `impress-surface-service` and `surface-demo-service` are stub crates as of
//! this writing (ADR-0033 wave 1): they define no `#[impress_service]`
//! methods yet, so linking them force-links nothing extra — but the feature
//! and the dependency exist now so S4/S9 register their verbs with zero
//! Cargo.toml edits here.

#![forbid(unsafe_code)]

use impress_service_core::{runtime, McpToolDescriptor};
use serde_json::Value;

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
#[cfg(feature = "layout")]
#[allow(unused_imports)]
use impress_layout_service as _force_link_layout_service;
#[cfg(feature = "memory")]
#[allow(unused_imports)]
use impress_memory_service as _force_link_memory_service;
#[cfg(feature = "parsers")]
#[allow(unused_imports)]
use impress_parsers_service as _force_link_parsers_service;
#[cfg(feature = "smart-search")]
#[allow(unused_imports)]
use impress_smart_search_service as _force_link_smart_search_service;
#[cfg(feature = "store")]
#[allow(unused_imports)]
use impress_store_service as _force_link_store_service;
#[cfg(feature = "surface")]
#[allow(unused_imports)]
use impress_surface_service as _force_link_surface_service;
#[cfg(feature = "imprint")]
#[allow(unused_imports)]
use imprint_selftest as _force_link_imprint_selftest;
#[cfg(feature = "imprint")]
#[allow(unused_imports)]
use imprint_service as _force_link_imprint_service;
#[cfg(feature = "surface-demo")]
#[allow(unused_imports)]
use surface_demo_service as _force_link_surface_demo_service;
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
/// `impress-capabilities` at all. Its body does nothing observable; its only
/// job is to exist as a real, callable symbol.
pub fn force_link() {}

// ---------------------------------------------------------------------------
// Descriptor lookup
// ---------------------------------------------------------------------------

/// Every MCP tool descriptor linked into this binary by the enabled features.
///
/// The one list `impress-mcp` (`tools/list`), `impress-cli` (subcommand
/// enumeration, via the sibling `CliSubcommand` inventory) and any future
/// consumer (`impress-store-ffi`'s `kit` build) read from — see the module
/// docs for why "linked into this binary" depends on which features were
/// enabled at compile time, not on anything runtime-configurable.
pub fn descriptors() -> impl Iterator<Item = &'static McpToolDescriptor> {
    McpToolDescriptor::iter()
}

/// Look up one descriptor by its exact MCP tool name
/// (`"imbib-text-service_decode-latex"`, kebab-case method ident).
pub fn find(name: &str) -> Option<&'static McpToolDescriptor> {
    McpToolDescriptor::iter().find(|d| d.name == name)
}

// ---------------------------------------------------------------------------
// Call
// ---------------------------------------------------------------------------

/// Error from [`call`] / [`call_async`].
///
/// Mirrors the two failure modes the former `impress-mcp::inventory_bridge`
/// returned as plain strings (`"Unknown tool: {name}"` and
/// `"{descriptor}: {handler error}"`); `Display` on this type reproduces
/// those exact strings so callers that used to `.to_string()` the old
/// `Result<Value, String>` see byte-identical error text.
#[derive(Debug, thiserror::Error)]
pub enum CallError {
    /// No descriptor with this name is registered — either a typo, or the
    /// feature that would have linked it was not enabled.
    #[error("Unknown tool: {0}")]
    UnknownTool(String),
    /// The descriptor's handler future resolved to `Err`. The message is
    /// already formatted as `"{descriptor.name}: {handler error}"`.
    #[error("{0}")]
    Handler(String),
}

/// Invoke an inventory tool synchronously, running its handler future to
/// completion on the shared `impress-service` runtime
/// ([`impress_service_core::runtime::block_on`]).
///
/// Moved here from `impress-mcp`'s `inventory_bridge::call_inventory_tool`
/// (ADR-0033 D4 plan S2) — the same function, same error strings, so every
/// caller of the old bridge function is unaffected by the move. Use this from
/// a synchronous context (CLI dispatch, an FFI shim); use [`call_async`] from
/// a context already running on a Tokio runtime, where `block_on` would
/// panic.
pub fn call(name: &str, args: Value) -> Result<Value, CallError> {
    let descriptor = find(name).ok_or_else(|| CallError::UnknownTool(name.to_string()))?;
    let future = (descriptor.handler)(args);
    runtime::block_on(future).map_err(|e| CallError::Handler(format!("{}: {}", descriptor.name, e)))
}

/// The `async` counterpart to [`call`], for callers already on the runtime.
pub async fn call_async(name: &str, args: Value) -> Result<Value, CallError> {
    let descriptor = find(name).ok_or_else(|| CallError::UnknownTool(name.to_string()))?;
    (descriptor.handler)(args)
        .await
        .map_err(|e| CallError::Handler(format!("{}: {}", descriptor.name, e)))
}

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
