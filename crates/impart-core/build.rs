fn main() {
    #[cfg(feature = "native")]
    uniffi::generate_scaffolding("src/uniffi.udl").unwrap();
}
