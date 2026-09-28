//! One integration-test binary for impress-core (plan-verb-pipeline-and-transport
//! § Build cost, B1): every file in this directory is a module here, so the
//! crate's tests compile and link once instead of once per file. A test keeps
//! its file's name as its module path: `cargo test -p impress-core -- <file>::<test>`.

mod collection_container_axis;
mod compaction_retention;
mod manuscript_project;
mod prop_collab_convergence;
mod prop_memory_ops;
mod prop_schema_validation;
mod prop_store_graph;
mod schema_ref_construction;
mod schema_ref_manifest;
mod sync_convergence;

#[path = "support/schema_fixture.rs"]
mod schema_fixture;
