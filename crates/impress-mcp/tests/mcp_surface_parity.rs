//! MCP surface parity (ADR-0022 D5) — the seed test.
//!
//! D5's rule is that every GUI verb gets a Rust service twin and only
//! service-backed ops are exposed. This asserts the store-generic parts of
//! that surface — collections, generic triage, and the mixed-kind reads
//! (grouped search D6, related items D8, get/browse G6) — are actually
//! enumerable as MCP tools, by name, and that each is recorded in the
//! capability matrix.
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
pub const COLLECTION_TOOLS: [&str; 12] = [
    "collection-service_tree",
    "collection-service_create",
    "collection-service_rename",
    "collection-service_reparent",
    "collection-service_reorder",
    "collection-service_delete",
    "collection-service_add-members",
    "collection-service_remove-members",
    "collection-service_member-counts",
    // ADR-0022 WP G7 — the schema-convergence trio. Deliberately tools and
    // not something the store does on open: they rewrite the collection trees
    // users live in, so a human (or an agent a human is watching) has to ask.
    "collection-service_migration-status",
    "collection-service_migrate",
    "collection-service_rollback",
];

/// Every generic triage tool (ADR-0022 D5).
pub const TRIAGE_TOOLS: [&str; 5] = [
    "triage-service_set-starred",
    "triage-service_set-flag",
    "triage-service_add-tag",
    "triage-service_remove-tag",
    "triage-service_set-status",
];

/// The mixed-kind reads over the whole store: grouped global search
/// (ADR-0022 D6), cross-kind relations (D8), and the get/browse pair that
/// makes a search hit openable and the store walkable (D5, WP G6).
pub const STORE_QUERY_TOOLS: [&str; 4] = [
    "store-query-service_search-all",
    "store-query-service_related-items",
    "store-query-service_get-item",
    "store-query-service_list-items",
];

/// The store-browse MCP **resources** (ADR-0022 WP G6).
///
/// Resources are not tools and never reach `McpToolDescriptor`, so they cannot
/// be asserted from here — this crate's integration tests cannot link the
/// binary's `server` module. The listing is asserted twice instead:
/// in-process in `src/server.rs::resource_tests`, and against the shipped
/// binary in `inventory_smoke.rs`. This constant exists so the surface is
/// enumerated in one obvious place with the tools it complements, and so a URI
/// rename shows up as a diff here.
pub const STORE_RESOURCES: [&str; 2] = ["impress://store/schemas", "impress://store/collections"];

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

#[test]
fn store_query_tools_are_enumerated() {
    let names = tool_names();
    for expected in STORE_QUERY_TOOLS {
        assert!(
            names.contains(&expected),
            "store query tool {expected} is not in the MCP inventory"
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
    for name in COLLECTION_TOOLS
        .iter()
        .chain(TRIAGE_TOOLS.iter())
        .chain(STORE_QUERY_TOOLS.iter())
    {
        let namespace = name.split_once('_').expect("tool names are ns_verb").0;
        assert!(
            !APP_NAMESPACES.contains(&namespace),
            "{name} sits in the app-gated namespace {namespace}"
        );
    }
}

/// The capability matrix is where ADR-0022 D5 keeps the MCP surface
/// deliberate ("MCP creep — only service-backed ops; the matrix column keeps
/// the surface deliberate"). A tool or resource that ships without a row there
/// is a capability nobody decided to add, so assert the document names every
/// one of them.
///
/// This is the only reachable check that the *resources* stay enumerated: they
/// are not tools, never appear in `McpToolDescriptor`, and this crate's
/// integration tests cannot link the binary's `server` module.
#[test]
fn the_capability_matrix_documents_every_store_generic_surface() {
    let matrix = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/chassis-capability-matrix.md");
    let text = std::fs::read_to_string(&matrix)
        .unwrap_or_else(|e| panic!("read {}: {e}", matrix.display()));

    for name in COLLECTION_TOOLS
        .iter()
        .chain(TRIAGE_TOOLS.iter())
        .chain(STORE_QUERY_TOOLS.iter())
        .chain(STORE_RESOURCES.iter())
    {
        assert!(
            text.contains(name),
            "{name} is exposed but has no row in docs/chassis-capability-matrix.md"
        );
    }
}

/// Descriptions reach the model from the trait's doc comments. A tool
/// describing itself as "Invoke Service.method" is one the model will misuse,
/// and 119 of 133 tools were in that state once.
#[test]
fn new_tools_describe_themselves() {
    for d in McpToolDescriptor::iter() {
        if !COLLECTION_TOOLS.contains(&d.name)
            && !TRIAGE_TOOLS.contains(&d.name)
            && !STORE_QUERY_TOOLS.contains(&d.name)
        {
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
