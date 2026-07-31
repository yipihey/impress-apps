//! The shared `impress.sqlite` handle these services run against.
//!
//! Store-generic services are NOT app-gated: they open the store directly and
//! work with every app closed, which is exactly why they belong in their own
//! crate rather than behind one app's HTTP backend.
//!
//! The path resolves the same way `impress-mcp` resolves it — the app-group
//! container — with two escape hatches for embedders and tests:
//!
//! * [`set_store_path`] records a path *without* opening anything, so a host
//!   that parses `--store-path` can point the services at it with zero startup
//!   cost (the store opens lazily on the first tool call);
//! * [`install_store`] injects an already-open store (tests use a temp or
//!   in-memory one, as does anything embedding this crate in-process).
//!
//! Service structs also accept a store directly (`with_store`), which is how
//! the unit tests avoid the singleton entirely.

use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use impress_core::sqlite_store::SqliteItemStore;

static STORE_PATH: OnceLock<PathBuf> = OnceLock::new();
static STORE: OnceLock<Arc<SqliteItemStore>> = OnceLock::new();

/// Where the shared store lives when nothing overrides it. The
/// `IMPRESS_STORE_PATH` environment variable wins, then the app-group
/// container path every other consumer in the suite uses.
pub fn default_store_path() -> PathBuf {
    if let Ok(p) = std::env::var("IMPRESS_STORE_PATH") {
        return PathBuf::from(p);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
}

/// Point the services at `path`, lazily. Call before the first service
/// dispatch; returns `Err` if a path or store was already fixed.
pub fn set_store_path(path: impl AsRef<Path>) -> Result<(), String> {
    STORE_PATH
        .set(path.as_ref().to_path_buf())
        .map_err(|_| "impress store path already set".to_string())
}

/// The path the services will use (or are using).
pub fn store_path() -> PathBuf {
    STORE_PATH.get().cloned().unwrap_or_else(default_store_path)
}

/// Install an already-open store. Returns `Err` if one is already installed.
pub fn install_store(store: Arc<SqliteItemStore>) -> Result<(), String> {
    STORE
        .set(store)
        .map_err(|_| "impress store already installed".to_string())
}

/// Whether [`store_instance`] had to substitute the in-memory fallback.
/// Read this before any operation whose ANSWER must be about the real store —
/// the collections migration refuses to run when it is `true`, because a
/// migration that "succeeds" against an empty substitute is a lie about the
/// user's data (found live: a TCC-blocked open during the first real flip
/// attempt produced `rows: 0` across the board).
static STORE_IS_FALLBACK: OnceLock<bool> = OnceLock::new();

pub fn store_is_fallback() -> bool {
    STORE_IS_FALLBACK.get().copied().unwrap_or(false)
}

/// Open `path`, or fall back to an empty in-memory store. Returns the store
/// and whether the fallback fired. Pure with respect to the singletons, so the
/// fallback behaviour is unit-testable.
fn open_or_fallback(path: &Path) -> (Arc<SqliteItemStore>, bool) {
    match SqliteItemStore::open(path) {
        Ok(store) => (Arc::new(store), false),
        Err(e) => {
            eprintln!(
                "[impress-store-service] could not open the store at {}: {e} \
                 — falling back to an empty in-memory store",
                path.display()
            );
            (
                Arc::new(
                    SqliteItemStore::open_in_memory()
                        .expect("in-memory SqliteItemStore always opens"),
                ),
                true,
            )
        }
    }
}

/// Get (or lazily open) the shared store.
///
/// On open failure this falls back to a private in-memory store rather than
/// panicking: an MCP tool that answers "no such collection" is recoverable, a
/// server that aborts mid-session is not. The failure is logged to stderr,
/// which is where every other service in this server logs — and recorded in
/// [`store_is_fallback`], which destiny-grade operations (the collections
/// migration) consult and refuse on.
pub fn store_instance() -> Arc<SqliteItemStore> {
    STORE
        .get_or_init(|| {
            let (store, fell_back) = open_or_fallback(&store_path());
            let _ = STORE_IS_FALLBACK.set(fell_back);
            store
        })
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_or_fallback_reports_the_substitution() {
        // A path that cannot exist as a database file: a directory.
        let dir = std::env::temp_dir();
        let (_store, fell_back) = open_or_fallback(&dir);
        assert!(fell_back, "opening a directory must trip the fallback flag");

        let real = tempfile::tempdir().expect("tempdir");
        let (_store, fell_back) = open_or_fallback(&real.path().join("ok.sqlite"));
        assert!(
            !fell_back,
            "a creatable path must not be reported as fallback"
        );
    }

    #[test]
    fn default_path_honours_the_environment_override() {
        // `default_store_path` is pure with respect to the singletons, so this
        // does not disturb whatever the rest of the suite resolved.
        std::env::set_var(
            "IMPRESS_STORE_PATH",
            "/tmp/impress-store-service-test.sqlite",
        );
        assert_eq!(
            default_store_path(),
            PathBuf::from("/tmp/impress-store-service-test.sqlite")
        );
        std::env::remove_var("IMPRESS_STORE_PATH");
        assert!(default_store_path()
            .to_string_lossy()
            .ends_with("workspace/impress.sqlite"));
    }
}
