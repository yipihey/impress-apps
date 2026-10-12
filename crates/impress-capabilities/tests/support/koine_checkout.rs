//! The koine checkout this workspace pins in `Cargo.lock`, for the source
//! scans that read files which now live there (`impress_service_impl!`
//! blocks, the CLI and the pipeline seat). The Rust twin of
//! `packages/ImpressLayout/Tests/.../KoineCheckout.swift`: the revision is
//! the one `Cargo.lock` pins, the checkout is cargo's own
//! (`$CARGO_HOME/git/checkouts/koine-*/<short rev>`), which any build of this
//! workspace has already fetched. `KOINE_CHECKOUT` names a working tree
//! instead, for a change made in both repositories at once.

use std::fs;
use std::path::{Path, PathBuf};

/// The root of the koine checkout (the directory holding `crates/`).
pub fn koine_root() -> PathBuf {
    if let Ok(dir) = std::env::var("KOINE_CHECKOUT") {
        return PathBuf::from(dir);
    }
    let lock_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Cargo.lock");
    let lock = fs::read_to_string(&lock_path).expect("Cargo.lock");
    let rev = lock
        .split("git+https://github.com/yipihey/koine?rev=")
        .nth(1)
        .and_then(|rest| rest.split('#').nth(1))
        .map(|rest| {
            rest.chars()
                .take_while(char::is_ascii_hexdigit)
                .collect::<String>()
        })
        .filter(|rev| !rev.is_empty())
        .expect("Cargo.lock pins https://github.com/yipihey/koine");
    let cargo_home = std::env::var("CARGO_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").expect("HOME")).join(".cargo"));
    let checkouts = cargo_home.join("git/checkouts");
    for entry in fs::read_dir(&checkouts).into_iter().flatten().flatten() {
        if !entry.file_name().to_string_lossy().starts_with("koine-") {
            continue;
        }
        for sub in fs::read_dir(entry.path()).into_iter().flatten().flatten() {
            let short = sub.file_name().to_string_lossy().to_string();
            if rev.starts_with(&short) && sub.path().join("crates").is_dir() {
                return sub.path();
            }
        }
    }
    panic!("no checkout of koine {rev} under {checkouts:?}; run `cargo fetch` in this workspace")
}
