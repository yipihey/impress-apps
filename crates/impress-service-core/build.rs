#[path = "../impress-core/schema_ref_codegen.rs"]
mod schema_ref_codegen;

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    schema_ref_codegen::generate();
}
