fn main() {
    // Pinning rerun-if-changed disables cargo's watch-the-whole-crate-dir
    // default (which relinks on any build-xcframework.sh edit). The UDL is
    // a real scaffolding input and must then be listed explicitly, or UDL
    // edits stop regenerating scaffolding and the bindings go stale.
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=src/uniffi.udl");
    #[cfg(feature = "native")]
    uniffi::generate_scaffolding("src/uniffi.udl").unwrap();
}
