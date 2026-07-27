//! Bridge between the `impress-service-core` inventory of
//! [`McpToolDescriptor`]s and the MCP JSON-RPC server.
//!
//! Phase 3B: each `#[impress_service]` trait method registers an
//! `McpToolDescriptor` via the `inventory` crate. Simply depending on the
//! per-app `*-service` crates (e.g. `imbib-service`, `imprint-service`)
//! causes those entries to be linked into this binary at compile time.
//!
//! Here we expose two helpers used by `server.rs`:
//!
//! * [`inventory_tool_definitions`] — returns the MCP-protocol JSON shape
//!   (`{name, description, inputSchema}`) for every descriptor registered
//!   in this binary, suitable for splicing into `tools/list`.
//! * [`call_inventory_tool`] — looks up a descriptor by name and invokes
//!   its async handler synchronously via
//!   [`impress_service_core::runtime::block_on`].

use impress_service_core::{runtime, McpToolDescriptor};
use serde_json::{json, Value};

/// Build the `tools/list` JSON for every inventory-registered descriptor.
///
/// The shape matches the MCP protocol's tool descriptor:
/// `{ "name", "description", "inputSchema" }`.
pub fn inventory_tool_definitions() -> Vec<Value> {
    McpToolDescriptor::iter()
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
    McpToolDescriptor::iter().map(|d| d.name).collect()
}

/// True if `name` matches an inventory-registered tool.
pub fn is_inventory_tool(name: &str) -> bool {
    McpToolDescriptor::iter().any(|d| d.name == name)
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
pub fn call_inventory_tool(name: &str, args: Value) -> Result<Value, String> {
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == name)
        .ok_or_else(|| format!("Unknown tool: {name}"))?;

    let future = (descriptor.handler)(args);
    runtime::block_on(future).map_err(|e| format!("{}: {}", descriptor.name, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imbib_service_tools_are_linked_in() {
        // Pulling in `imbib-service` as a dependency should cause its
        // five `#[impress_method]` entries to appear in the inventory.
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
