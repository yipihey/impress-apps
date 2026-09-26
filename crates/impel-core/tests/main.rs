//! One integration-test binary for impel-core (plan-verb-pipeline-and-transport
//! § Build cost, B1): every file in this directory is a module here, so the
//! crate's tests compile and link once instead of once per file. A test keeps
//! its file's name as its module path: `cargo test -p impel-core -- <file>::<test>`.

mod schema_ref_manifest;
mod task_kernel_loop;
