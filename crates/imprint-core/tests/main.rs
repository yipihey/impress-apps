//! One integration-test binary for imprint-core (plan-verb-pipeline-and-transport
//! § Build cost, B1): every file in this directory is a module here, so the
//! crate's tests compile and link once instead of once per file. A test keeps
//! its file's name as its module path: `cargo test -p imprint-core -- <file>::<test>`.

mod golden_parity;
mod plot_render_typst;
mod project_graph;
mod source_map_pagination;
mod synctex_fixture;
mod tectonic_spike;
mod typst_render;
