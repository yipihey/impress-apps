//! MCP surface parity (ADR-0022 D5) — the seed test.
//!
//! D5's rule is that every GUI verb gets a Rust service twin and only
//! service-backed ops are exposed. This asserts the first two halves of that
//! surface — collections and generic triage — are actually enumerable as MCP
//! tools, by name.
//!
//! Why by name and not by count: the failure this catches is a capability
//! silently *disappearing* — a dropped `#[impress_method]`, a renamed method,
//! or the linker eliding a service crate whose entries are only registered
//! through `inventory::submit!` at static-init time. Any of those leaves the
//! GUI able to do something an agent cannot, which is precisely the gap
//! ADR-0022 D5 exists to close. A count would go green on a rename.
//!
//! This links the service crates the same way `main.rs` does; the end-to-end
//! `inventory_smoke.rs` test then proves the shipped *binary* lists them too.

use impress_service_core::McpToolDescriptor;

#[allow(unused_imports)]
use impress_store_service as _force_link_store_service;

/// Every tool the collection kernel (ADR-0022 D1) exposes, mirroring
/// `impress_store_ffi::SharedStore::collection_*`.
pub const COLLECTION_TOOLS: [&str; 9] = [
    "collection-service_tree",
    "collection-service_create",
    "collection-service_rename",
    "collection-service_reparent",
    "collection-service_reorder",
    "collection-service_delete",
    "collection-service_add-members",
    "collection-service_remove-members",
    "collection-service_member-counts",
];

/// Every generic triage tool (ADR-0022 D5).
pub const TRIAGE_TOOLS: [&str; 5] = [
    "triage-service_set-starred",
    "triage-service_set-flag",
    "triage-service_add-tag",
    "triage-service_remove-tag",
    "triage-service_set-status",
];

fn tool_names() -> Vec<&'static str> {
    McpToolDescriptor::iter().map(|d| d.name).collect()
}

#[test]
fn collection_tools_are_enumerated() {
    let names = tool_names();
    for expected in COLLECTION_TOOLS {
        assert!(
            names.contains(&expected),
            "collection tool {expected} is not in the MCP inventory"
        );
    }
}

#[test]
fn triage_tools_are_enumerated() {
    let names = tool_names();
    for expected in TRIAGE_TOOLS {
        assert!(
            names.contains(&expected),
            "triage tool {expected} is not in the MCP inventory"
        );
    }
}

/// Store-generic tools must not land in an app's namespace: `impress-mcp`
/// gates tools by the namespace before the first `_`, and anything matching a
/// running-app namespace would be withheld whenever that app is closed —
/// even though these read and write the sqlite store directly.
#[test]
fn store_generic_namespaces_are_not_app_namespaces() {
    const APP_NAMESPACES: [&str; 4] = [
        "imbib-app-service",
        "imprint-app-service",
        "implore-service",
        "impart-service",
    ];
    for name in COLLECTION_TOOLS.iter().chain(TRIAGE_TOOLS.iter()) {
        let namespace = name.split_once('_').expect("tool names are ns_verb").0;
        assert!(
            !APP_NAMESPACES.contains(&namespace),
            "{name} sits in the app-gated namespace {namespace}"
        );
    }
}

/// Descriptions reach the model from the trait's doc comments. A tool
/// describing itself as "Invoke Service.method" is one the model will misuse,
/// and 119 of 133 tools were in that state once.
#[test]
fn new_tools_describe_themselves() {
    for d in McpToolDescriptor::iter() {
        if !COLLECTION_TOOLS.contains(&d.name) && !TRIAGE_TOOLS.contains(&d.name) {
            continue;
        }
        assert!(
            !d.description.starts_with("Invoke ") && !d.description.is_empty(),
            "{} has a placeholder description: {:?}",
            d.name,
            d.description
        );
    }
}
