//! One integration-test binary for imprint-service (plan-verb-pipeline-and-transport
//! § Build cost, B1): every file in this directory is a module here, so the
//! crate's tests compile and link once instead of once per file. A test keeps
//! its file's name as its module path: `cargo test -p imprint-service -- <file>::<test>`.

mod project_service;
mod prop_throughline;
mod search_smoke;
mod sections_roundtrip;
