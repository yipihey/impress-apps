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

use impress_service_core::{runtime, McpToolDescriptor};
use serde_json::Value;

// ---------------------------------------------------------------------------
// Force-link
// ---------------------------------------------------------------------------
//
// One `use X as _;` per kit crate — all four are plain (non-optional)
// dependencies of this crate, so all four are always linked when this crate
// is. See the module docs above for why a `use` alone is not sufficient on
// its own to keep them in the FINAL BINARY's link: [`force_link`] is the real
// reference a binary must call.

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
pub fn force_link() {}

// ---------------------------------------------------------------------------
// Descriptor lookup
// ---------------------------------------------------------------------------

/// Every MCP tool descriptor linked into this binary by the four kit crates
/// (plus anything else the binary separately links — this reads the one
/// process-wide `inventory` collection, not a kit-scoped subset of it).
///
/// Moved here from `impress-capabilities` (ADR-0033 D7 / plan S6) so
/// `impress-store-ffi` can call it without depending on
/// `impress-capabilities` itself. `impress-capabilities` re-exports this
/// function verbatim behind its `kit` feature so every existing caller
/// (`impress-mcp`'s `inventory_bridge`, `impress-cli`) compiles unchanged.
pub fn descriptors() -> impl Iterator<Item = &'static McpToolDescriptor> {
    McpToolDescriptor::iter()
}

/// Look up one descriptor by its exact MCP tool name
/// (`"surface-demo-service_series"`, kebab-case method ident).
pub fn find(name: &str) -> Option<&'static McpToolDescriptor> {
    McpToolDescriptor::iter().find(|d| d.name == name)
}

// ---------------------------------------------------------------------------
// Call
// ---------------------------------------------------------------------------

/// Error from [`call`] / [`call_async`].
///
/// Mirrors the two failure modes `impress-mcp::inventory_bridge` returned as
/// plain strings before the `impress-capabilities` move (ADR-0033 D4 plan
/// S2), preserved again here (`"Unknown tool: {name}"` and
/// `"{descriptor}: {handler error}"`); `Display` on this type reproduces
/// those exact strings so callers that used to `.to_string()` the old
/// `Result<Value, String>` see byte-identical error text.
#[derive(Debug, thiserror::Error)]
pub enum CallError {
    /// No descriptor with this name is registered — either a typo, or the
    /// crate that would have linked it is not linked into this binary.
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
/// Use this from a synchronous context (CLI dispatch, an FFI shim); use
/// [`call_async`] from a context already running on a Tokio runtime, where
/// `block_on` would panic.
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
