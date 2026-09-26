//! One integration-test binary for imbib-core (plan-verb-pipeline-and-transport
//! § Build cost, B1): every file in this directory is a module here, so the
//! crate's tests compile and link once instead of once per file. A test keeps
//! its file's name as its module path: `cargo test -p imbib-core -- <file>::<test>`.

mod bibtex_tests;
mod citation_search_repro;
mod collection_migration_legacy_readers;
mod common;
mod deduplication_tests;
mod eink_documents;
mod eink_end_to_end;
mod eink_import;
mod eink_store;
mod enrichment_property_tests;
mod golden_parity;
mod identifier_tests;
mod manuscript_unification;
mod pdf_match_golden;
mod ris_tests;
mod schema_ref_manifest;
mod search_property_tests;
mod sidebar_snapshot_parity;
mod snapshot_tests;
mod stage7_abstract_parity;
mod stage7_parser_parity;
mod stage7_pdf_parity;
mod store_dismissed_property_tests;
mod sync_outbox_facade;
mod tags_with_counts_semantics;
