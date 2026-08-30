//! Offline, cache-backed resolution of Typst packages (`@preview/...`).
//!
//! The editor engine (`PersistentTypstRenderer`) and the project/bundle path
//! previously had no package resolver at all, so any manuscript importing a
//! universe package failed with `file not found (searched at typst.toml)` on
//! its first `#import "@preview/..."` line. This resolver serves package files
//! from on-disk package trees that already exist — it performs **no network
//! I/O**, so compiles stay deterministic and offline-capable. Populating the
//! cache is the typst CLI's (or a future vendoring step's) job:
//! `typst compile` of any file importing the package fills
//! `~/Library/Caches/typst/packages` (macOS) / `~/.cache/typst/packages`.
//!
//! Search roots, in order:
//! 1. `IMPRESS_TYPST_PACKAGE_DIR` (explicit override; also how the sandboxed
//!    app or tests point at a vendored tree),
//! 2. the typst-kit data dir (`~/Library/Application Support/typst/packages`,
//!    `$XDG_DATA_HOME/typst/packages`) — where `typst` treats local packages
//!    as authoritative,
//! 3. the typst CLI download cache (`~/Library/Caches/typst/packages`,
//!    `$XDG_CACHE_HOME/typst/packages`).
//!
//! Layout inside a root is the typst-kit convention:
//! `<root>/<namespace>/<name>/<version>/<file path within the package>`.

use std::borrow::Cow;
use std::path::PathBuf;

use typst::diag::{FileError, FileResult};
use typst::foundations::Bytes;
use typst::syntax::{FileId, Source};
use typst_as_lib::file_resolver::FileResolver;

/// Resolves `FileId`s that carry a package spec against local package trees.
/// Non-package ids are declined (`FileError::NotFound`) so the next resolver
/// in the engine's chain handles them.
pub struct CachedPackageResolver {
    roots: Vec<PathBuf>,
}

impl CachedPackageResolver {
    /// Discover the standard local package roots (see module docs). Roots that
    /// do not exist are kept out of the list; an empty list is fine — the
    /// resolver then declines everything, which reproduces today's behavior.
    pub fn discover() -> Self {
        let mut roots = Vec::new();
        if let Ok(dir) = std::env::var("IMPRESS_TYPST_PACKAGE_DIR") {
            if !dir.is_empty() {
                roots.push(PathBuf::from(dir));
            }
        }
        // Vendored tree inside the host app bundle: a sandboxed app can
        // always read its own Resources, and nothing else on a locked-down
        // machine is guaranteed readable (group containers kernel-hang for
        // unentitled writers, other containers are TCC-protected). Hosts ship
        // it at Contents/Resources/typst-packages (exe is Contents/MacOS/…).
        if let Ok(exe) = std::env::current_exe() {
            if let Some(macos_dir) = exe.parent() {
                if let Some(contents) = macos_dir.parent() {
                    roots.push(contents.join("Resources").join("typst-packages"));
                }
            }
        }
        // The suite group container, same convention as the shared store's
        // `Group Containers/QG3MEYVHMS.com.impress.suite/workspace`. The typst
        // CLI cannot populate it; a suite app has to stage it.
        if let Some(home) = Self::real_home() {
            roots.push(
                home.join("Library/Group Containers/QG3MEYVHMS.com.impress.suite")
                    .join("typst")
                    .join("packages"),
            );
            // Outside the sandbox this duplicates dirs::cache_dir below;
            // inside it, it is the CLI cache the sandbox may still deny —
            // harmless either way, the probe just fails.
            roots.push(home.join("Library/Caches/typst/packages"));
        }
        if let Some(data) = dirs::data_dir() {
            roots.push(data.join("typst").join("packages"));
        }
        if let Some(cache) = dirs::cache_dir() {
            roots.push(cache.join("typst").join("packages"));
        }
        roots.retain(|r| r.is_dir());
        roots.dedup();
        Self { roots }
    }

    /// The user's real home directory, seen through the App Sandbox if
    /// present: a sandboxed macOS process gets
    /// `HOME=<real>/Library/Containers/<bundle>/Data`, and the group
    /// container lives under `<real>/Library/Group Containers/…`.
    fn real_home() -> Option<PathBuf> {
        let home = dirs::home_dir()?;
        let text = home.to_string_lossy();
        if let Some(idx) = text.find("/Library/Containers/") {
            return Some(PathBuf::from(&text[..idx]));
        }
        Some(home)
    }

    /// A resolver over explicit roots (tests, vendored trees).
    pub fn with_roots(roots: Vec<PathBuf>) -> Self {
        Self { roots }
    }

    /// True if any root holds the given package version (cheap preflight used
    /// by diagnostics and selftests).
    pub fn has_package(&self, namespace: &str, name: &str, version: &str) -> bool {
        self.roots
            .iter()
            .any(|r| r.join(namespace).join(name).join(version).is_dir())
    }

    fn file_path(&self, id: FileId) -> Option<PathBuf> {
        let spec = id.package()?;
        let namespace = spec.namespace.as_str();
        let name = spec.name.as_str();
        let version = spec.version.to_string();
        let vpath = id.vpath().as_rootless_path();
        self.roots
            .iter()
            .map(|root| root.join(namespace).join(name).join(&version).join(vpath))
            .find(|p| p.is_file())
    }

    fn read(&self, id: FileId) -> FileResult<Vec<u8>> {
        let Some(spec) = id.package() else {
            // Not a package file — decline so the next resolver runs.
            return Err(FileError::NotFound(
                id.vpath().as_rootless_path().to_path_buf(),
            ));
        };
        match self.file_path(id) {
            Some(path) => std::fs::read(&path).map_err(|e| FileError::from_io(e, &path)),
            None => Err(FileError::Package(typst::diag::PackageError::NotFound(
                spec.clone(),
            ))),
        }
    }
}

impl FileResolver for CachedPackageResolver {
    fn resolve_binary(&self, id: FileId) -> FileResult<Cow<'_, Bytes>> {
        Ok(Cow::Owned(Bytes::new(self.read(id)?)))
    }

    fn resolve_source(&self, id: FileId) -> FileResult<Cow<'_, Source>> {
        let bytes = self.read(id)?;
        let text = String::from_utf8(bytes).map_err(|_| FileError::InvalidUtf8)?;
        Ok(Cow::Owned(Source::new(id, text)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use typst::syntax::VirtualPath;

    fn lilaq_available() -> bool {
        CachedPackageResolver::discover().has_package("preview", "lilaq", "0.6.0")
    }

    #[test]
    fn declines_non_package_ids() {
        let resolver = CachedPackageResolver::discover();
        let id = FileId::new(None, VirtualPath::new("/main.typ"));
        assert!(resolver.resolve_source(id).is_err());
        assert!(resolver.resolve_binary(id).is_err());
    }

    #[test]
    fn resolves_cached_package_entrypoint() {
        if !lilaq_available() {
            eprintln!("skipping: lilaq 0.6.0 not in any local typst package root");
            return;
        }
        use typst::syntax::package::PackageSpec;
        let spec: PackageSpec = "@preview/lilaq:0.6.0".parse().expect("spec parses");
        // Entry point per typst.toml.
        let id = FileId::new(Some(spec), VirtualPath::new("/src/lilaq.typ"));
        let resolver = CachedPackageResolver::discover();
        let source = resolver
            .resolve_source(id)
            .expect("lilaq entrypoint resolves from local cache");
        assert!(!source.text().is_empty());
    }
}
