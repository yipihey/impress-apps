//! Generate checked-in linked-verb pages without opening a store. An explicit
//! host with an initialized provider registry calls `impress_capabilities::verb_docs`
//! to render runtime providers into its own output directory.

use std::fs;
use std::path::{Path, PathBuf};

use impress_service_core::{call, VerbHandle};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("crates/impress-capabilities has two parents")
        .to_path_buf()
}

fn main() {
    // Retain every linked service's inventory submissions in this binary.
    impress_capabilities::force_link();

    let mut out_dir: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out-dir" => {
                let path = args.next().expect("--out-dir requires a path");
                out_dir = Some(PathBuf::from(path));
            }
            other => panic!("unknown argument {other}"),
        }
    }

    let checked_in = out_dir.is_none();
    let out_dir = out_dir.unwrap_or_else(|| repo_root().join("docs/verbs"));
    let docs = impress_capabilities::verb_docs::render(
        call::descriptors().filter(|verb| matches!(verb, VerbHandle::Linked(_))),
    );
    let count = docs.write_to_dir(&out_dir).expect("write verb pages");

    if checked_in {
        // Retire pages for services no longer linked. An explicit output
        // directory may contain other files and is never pruned.
        if let Ok(entries) = fs::read_dir(&out_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.ends_with(".md")
                    && name != "README.md"
                    && !docs.pages.contains_key(name.trim_end_matches(".md"))
                {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
    }
    eprintln!("wrote {count} service pages to {}", out_dir.display());
}
