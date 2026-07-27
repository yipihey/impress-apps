//! Store-generic `#[impress_service]` traits (ADR-0022 WP G1).
//!
//! Two services live here, and they have one thing in common that decides
//! where they belong: **they know nothing about any app**. They open the
//! shared `impress.sqlite` directly, so they answer with every app closed, and
//! they are therefore never withheld by `impress-mcp`'s reachability gate the
//! way `imbib-app-service` or `implore-service` are.
//!
//! * [`CollectionService`] — the agent-facing twin of the collection kernel
//!   (`impress_core::collection_ops`), mirroring
//!   `impress_store_ffi::SharedStore::collection_*` verb for verb so Swift,
//!   the CLI and an agent share one vocabulary.
//! * [`TriageService`] — star / flag / tag / status over any item, over
//!   `impress_core::triage_ops`.
//!
//! ADR-0022 D5's rule is that every GUI verb gets a Rust service twin and
//! *only* service-backed ops are exposed. These are the collection and triage
//! halves of that; `docs/chassis-capability-matrix.md` § "MCP surface" records
//! which matrix cells they automate.

pub mod collection_service;
pub mod store;
pub mod triage_service;

#[cfg(test)]
mod test_support;

pub use collection_service::{
    binding_for, CollectionListResult, CollectionMutationResult, CollectionResult,
    CollectionRowDto, CollectionService, DefaultCollectionService, MemberCountsResult,
    BINDING_NAMES,
};
pub use store::{default_store_path, install_store, set_store_path, store_instance, store_path};
pub use triage_service::{DefaultTriageService, TriageResult, TriageService};

#[cfg(test)]
mod inventory_tests {
    use impress_service_core::McpToolDescriptor;

    /// Every method of both traits must reach the MCP inventory — that is the
    /// entire point of the crate, and a missing `#[impress_method]` is
    /// otherwise invisible until an agent cannot find the tool.
    #[test]
    fn both_services_register_every_tool() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "collection-service_tree",
            "collection-service_create",
            "collection-service_rename",
            "collection-service_reparent",
            "collection-service_reorder",
            "collection-service_delete",
            "collection-service_add-members",
            "collection-service_remove-members",
            "collection-service_member-counts",
            "triage-service_set-starred",
            "triage-service_set-flag",
            "triage-service_add-tag",
            "triage-service_remove-tag",
            "triage-service_set-status",
        ] {
            assert!(
                names.contains(&expected),
                "{expected} missing from the inventory; have: {names:?}"
            );
        }
    }

    /// Descriptions come from the trait's doc comments. A tool that ships
    /// "Invoke Service.method" is a tool the model will misuse.
    #[test]
    fn descriptions_are_real() {
        for d in McpToolDescriptor::iter() {
            assert!(
                !d.description.starts_with("Invoke "),
                "{} has a placeholder description",
                d.name
            );
            assert!(
                (d.input_schema)().get("properties").is_some(),
                "{} has no input schema properties",
                d.name
            );
        }
    }
}
