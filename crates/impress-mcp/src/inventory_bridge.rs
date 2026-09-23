//! Bridge between the `impress-capabilities` inventory (ADR-0033 D4) and the
//! MCP JSON-RPC server.
//!
//! Phase 3B linked the `#[impress_service]` inventory directly into this
//! binary; ADR-0033 D4 / plan S2 moved that linking — and the lookup/dispatch
//! logic that used to live in this file — into `crates/impress-capabilities`,
//! the one place it happens now, shared with `impress-cli` (and, later, the
//! FFI's `kit` build). This file is a thin wrapper: same function names, same
//! signatures, same error strings, so `server.rs` needed no change for the
//! move.
//!
//! * [`inventory_tool_definitions`] — returns the MCP-protocol JSON shape
//!   (`{name, description, inputSchema}`) for every descriptor registered
//!   in this binary, suitable for splicing into `tools/list`.
//! * [`call_inventory_tool`] — looks up a descriptor by name and invokes
//!   its async handler synchronously via `impress_capabilities::call`.

use serde_json::{json, Value};

/// Build the `tools/list` JSON for every inventory-registered descriptor.
///
/// The shape matches the MCP protocol's tool descriptor:
/// `{ "name", "description", "inputSchema" }`.
pub fn inventory_tool_definitions() -> Vec<Value> {
    impress_capabilities::descriptors()
        .map(|d| {
            json!({
                "name": d.name,
                "description": d.description,
                "inputSchema": (d.input_schema)(),
            })
        })
        .collect()
}

/// Names of all inventory-registered tools, mostly useful for testing /
/// diagnostics.
#[allow(dead_code)]
pub fn inventory_tool_names() -> Vec<&'static str> {
    impress_capabilities::descriptors()
        .map(|d| d.name)
        .collect()
}

/// True if `name` matches an inventory-registered tool.
pub fn is_inventory_tool(name: &str) -> bool {
    impress_capabilities::find(name).is_some()
}

/// Invoke an inventory tool synchronously.
///
/// Returns the handler's `serde_json::Value` result (which the caller is
/// expected to wrap in the MCP `{content: [{type:"text", text: ...}]}`
/// envelope), or an error string suitable for the MCP `isError` payload.
///
/// Errors:
/// * `"Unknown tool: <name>"` — no descriptor with that name is registered.
/// * `"<descriptor>: <handler error>"` — the handler future returned `Err`.
///
/// These are exactly [`impress_capabilities::CallError`]'s two `Display`
/// forms; this function stays `Result<Value, String>` (rather than
/// `Result<Value, CallError>`) because `server.rs` threads the error straight
/// into `wrap_text_result`, which wants a `String`.
pub fn call_inventory_tool(name: &str, args: Value) -> Result<Value, String> {
    impress_capabilities::call(name, args).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imbib_service_tools_are_linked_in() {
        // Pulling in `impress-capabilities` with `features = ["full"]`
        // (Cargo.toml) should cause imbib-service's five `#[impress_method]`
        // entries to appear in the inventory.
        let names = inventory_tool_names();
        for expected in [
            "imbib-text-service_decode-latex",
            "imbib-text-service_expand-journal-macro",
            "imbib-text-service_generate-cite-key",
            "imbib-text-service_normalize-tag-segment",
            "imbib-text-service_normalize-tag-path",
        ] {
            assert!(
                names.contains(&expected),
                "expected {expected} in inventory; have: {names:?}",
            );
        }
    }

    #[test]
    fn definitions_have_required_keys() {
        let defs = inventory_tool_definitions();
        assert!(!defs.is_empty(), "no inventory definitions produced");
        for d in &defs {
            assert!(d.get("name").is_some(), "missing name in {d}");
            assert!(d.get("description").is_some(), "missing description in {d}");
            assert!(d.get("inputSchema").is_some(), "missing inputSchema in {d}");
        }
    }

    #[test]
    fn call_decode_latex_through_bridge() {
        let result = call_inventory_tool(
            "imbib-text-service_decode-latex",
            json!({ "input": "Caf\\'{e}" }),
        )
        .expect("decode-latex succeeded");
        assert_eq!(result.as_str(), Some("Café"));
    }

    #[test]
    fn unknown_tool_returns_error() {
        let err =
            call_inventory_tool("not-a-real-tool", json!({})).expect_err("unknown tool errors");
        assert!(err.contains("Unknown tool"), "unexpected error: {err}");
    }
}
