//! Compile real downstream fixtures: these errors must reach rustc callers.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn proc_macro_library(deps: &Path) -> PathBuf {
    fs::read_dir(deps)
        .expect("test dependencies directory")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("libimpress_service_macros-"))
                && matches!(
                    path.extension().and_then(|ext| ext.to_str()),
                    Some("dylib" | "so" | "dll")
                )
        })
        .expect("compiled impress-service-macros dynamic library")
}

#[test]
fn missing_construction_declarations_fail_in_downstream_crates() {
    let deps = std::env::current_exe()
        .expect("test binary path")
        .parent()
        .expect("test dependency directory")
        .to_path_buf();
    let macro_library = proc_macro_library(&deps);
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/ui");
    for (fixture, expected) in [
        ("missing_method_doc.rs", "UndocumentedService::run"),
        ("missing_safety.rs", "missing `safety ="),
        ("missing_since.rs", "missing `since ="),
    ] {
        let source = fixtures.join(fixture);
        let result = Command::new(std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
            .arg("--edition=2021")
            .arg("--crate-type=lib")
            .arg("--emit=metadata")
            .arg("-L")
            .arg(format!("dependency={}", deps.display()))
            .arg("--extern")
            .arg(format!(
                "impress_service_macros={}",
                macro_library.display()
            ))
            .arg(&source)
            .output()
            .expect("rustc runs for fixture");
        let stderr = String::from_utf8_lossy(&result.stderr);
        assert!(!result.status.success(), "{fixture} unexpectedly compiled");
        assert!(
            stderr.contains(expected),
            "{fixture} missed its diagnostic:\n{stderr}"
        );
    }
}
