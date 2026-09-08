//! Where a linked file lives on disk.
//!
//! The store records a `relative_path` per linked file but no library root:
//! `imbib/library.papers_directory_path` is never written. Swift resolves
//! the root through `AttachmentManager.resolveURL(for:in:)`, a ladder that
//! tries the app's Application Support directory, its sandbox twin, and a
//! legacy layout. A headless process (the `impress` CLI, the MCP server)
//! must find the same file, so the ladder is mirrored here.
//!
//! `HOME` inside a sandboxed app is the container's data directory
//! (`~/Library/Containers/<bundle>/Data`); the user's real home is derived
//! from it so both sides of the sandbox are searched from either process.

use std::path::{Path, PathBuf};

/// Bundle ids whose sandbox containers have held imbib's libraries.
const SANDBOX_BUNDLES: [&str; 2] = ["com.impress.imbib", "com.imbib.app"];
const LIBRARIES_SUFFIX: &str = "Library/Application Support/imbib/Libraries";
const LEGACY_SUFFIX: &str = "Library/Application Support/imbib";

/// The user's real home directory, even when `HOME` points into a sandbox
/// container.
pub fn user_home() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(real_home(&home))
}

/// Strip a `/Library/Containers/<bundle>/Data` suffix.
pub fn real_home(home: &Path) -> PathBuf {
    let components: Vec<&std::ffi::OsStr> = home.iter().collect::<Vec<_>>();
    if let Some(index) = components.windows(4).position(|window| {
        window[0] == "Library" && window[1] == "Containers" && window[3] == "Data"
    }) {
        let mut trimmed = PathBuf::new();
        for component in &components[..index] {
            trimmed.push(component);
        }
        return trimmed;
    }
    home.to_path_buf()
}

/// Every `…/imbib/Libraries` directory a library folder could sit under,
/// most likely first: the app's own Application Support, then each sandbox
/// container that has held imbib's data.
pub fn library_roots(home: &Path) -> Vec<PathBuf> {
    let mut roots = vec![home.join(LIBRARIES_SUFFIX)];
    for bundle in SANDBOX_BUNDLES {
        roots.push(
            home.join("Library")
                .join("Containers")
                .join(bundle)
                .join("Data")
                .join(LIBRARIES_SUFFIX),
        );
    }
    roots
}

/// The directory names a library folder may carry (Swift's `uuidString`
/// is uppercase; be lenient).
fn library_dir_names(library_id: &str) -> [String; 2] {
    [
        library_id.to_ascii_uppercase(),
        library_id.to_ascii_lowercase(),
    ]
}

/// Resolve a linked file's absolute path, or `None` when nothing exists at
/// any candidate location. An absolute `relative_path` (watched-folder
/// attachments) is honoured as-is.
pub fn resolve_relative(
    library_id: Option<&str>,
    relative_path: &str,
    home: &Path,
) -> Option<PathBuf> {
    let relative = relative_path.trim();
    if relative.is_empty() {
        return None;
    }
    if relative.starts_with('/') {
        let absolute = PathBuf::from(relative);
        return absolute.is_file().then_some(absolute);
    }
    candidates(library_id, relative, home)
        .into_iter()
        .find(|candidate| candidate.is_file())
}

/// Every path the ladder would try, in order (for diagnostics and tests).
pub fn candidates(library_id: Option<&str>, relative_path: &str, home: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(id) = library_id {
        for root in library_roots(home) {
            for name in library_dir_names(id) {
                out.push(root.join(&name).join(relative_path));
            }
        }
    }
    out.push(home.join(LEGACY_SUFFIX).join(relative_path));
    out
}

/// The library folder a new file should be written into: the first one that
/// already exists, else the app's own Application Support layout.
pub fn library_dir_for_write(library_id: &str, home: &Path) -> PathBuf {
    for root in library_roots(home) {
        for name in library_dir_names(library_id) {
            let dir = root.join(&name);
            if dir.is_dir() {
                return dir;
            }
        }
    }
    home.join(LIBRARIES_SUFFIX)
        .join(library_id.to_ascii_uppercase())
}

/// How to record a file that lives under `library_dir`: relative to it
/// when the folder is one of the known library roots (so every process
/// resolves it through the ladder), absolute otherwise.
pub fn relative_or_absolute(library_dir: &Path, file: &Path) -> String {
    let known_root = user_home()
        .map(|home| library_roots(&home))
        .unwrap_or_default()
        .iter()
        .any(|root| library_dir.starts_with(root));
    if known_root {
        file.strip_prefix(library_dir)
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| file.display().to_string())
    } else {
        file.display().to_string()
    }
}

/// Lowercase hex SHA-256 of bytes already in memory.
pub fn sha256_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}

/// Lowercase hex SHA-256 of a file's bytes, streamed.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_real_home_is_derived_from_a_sandbox_home() {
        assert_eq!(
            real_home(Path::new(
                "/Users/tom/Library/Containers/com.impress.imbib/Data"
            )),
            PathBuf::from("/Users/tom")
        );
        assert_eq!(
            real_home(Path::new("/Users/tom")),
            PathBuf::from("/Users/tom")
        );
    }

    #[test]
    fn the_ladder_finds_a_file_in_either_layout() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let library = "6206C0F5-C678-4A02-9060-E9C1785FD80D";

        // Sandbox twin holds the file; the plain layout does not.
        let sandbox_dir = home
            .join("Library/Containers/com.imbib.app/Data")
            .join(LIBRARIES_SUFFIX)
            .join(library)
            .join("Papers");
        std::fs::create_dir_all(&sandbox_dir).unwrap();
        std::fs::write(sandbox_dir.join("Abel_2002.pdf"), b"%PDF").unwrap();

        let found = resolve_relative(Some(&library.to_lowercase()), "Papers/Abel_2002.pdf", home)
            .expect("found via the sandbox twin, case-insensitively");
        assert!(found.ends_with("com.imbib.app/Data/Library/Application Support/imbib/Libraries/6206C0F5-C678-4A02-9060-E9C1785FD80D/Papers/Abel_2002.pdf"));

        assert!(resolve_relative(Some(library), "Papers/missing.pdf", home).is_none());

        // An absolute relative_path is taken as-is.
        let absolute = sandbox_dir.join("Abel_2002.pdf");
        assert_eq!(
            resolve_relative(None, absolute.to_str().unwrap(), home),
            Some(absolute)
        );

        // Writes go to the existing library folder, not a fresh one.
        assert!(library_dir_for_write(library, home)
            .ends_with(format!("com.imbib.app/Data/{LIBRARIES_SUFFIX}/{library}")));
        assert!(library_dir_for_write("nope", home).ends_with(format!("{LIBRARIES_SUFFIX}/NOPE")));
    }

    #[test]
    fn sha256_matches_the_reference_digest() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("x.bin");
        std::fs::write(&file, b"abc").unwrap();
        assert_eq!(
            sha256_file(&file).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
