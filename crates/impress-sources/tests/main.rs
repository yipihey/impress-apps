//! One integration-test binary for impress-sources (plan-verb-pipeline-and-transport
//! § Build cost, B1): every file in this directory is a module here, so the
//! crate's tests compile and link once instead of once per file. A test keeps
//! its file's name as its module path: `cargo test -p impress-sources -- <file>::<test>`.

mod ads_smoke;
mod arxiv_smoke;
mod crossref_smoke;
mod openalex_smoke;
