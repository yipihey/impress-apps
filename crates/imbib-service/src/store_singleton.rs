//! Shared process-wide `Arc<ImbibStore>` consumed by every imbib-service.
//!
//! All services hold a clone of this Arc. Auto-initializes from the default
//! macOS app-group path on first use; bin crates that need a different path
//! must call [`init_imbib_store`] before any service method dispatches.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use imbib_core::unified::store_api::ImbibStore;

// Keep the handle and the path that opened it in one OnceLock. Settings must
// never choose a different workspace between a successful explicit init and
// the first service dispatch.
static STORE: OnceLock<(Arc<ImbibStore>, PathBuf)> = OnceLock::new();

/// Path used when the singleton auto-initializes: `IMBIB_STORE_PATH`, else
/// the suite's `IMPRESS_STORE_PATH`, else the app group under `HOME`.
fn default_store_path() -> PathBuf {
    store_path_from(|name| std::env::var(name).ok())
}

/// [`default_store_path`] over any environment.
///
/// `IMPRESS_STORE_PATH` is the suite store a host names for itself, as
/// impel-taskd's LaunchAgent does. It must come before `HOME`: in a
/// sandboxed process `HOME` is the process's own container, so the app-group
/// path under it does not exist. On 2026-10-15 that made this singleton fall
/// back to an in-memory store inside impel-taskd, and the
/// `imbib.retention-cleanup` workflow ran against an empty scratch store
/// while the daemon itself had the real one open.
fn store_path_from(env: impl Fn(&str) -> Option<String>) -> PathBuf {
    let named = |name| env(name).filter(|p: &String| !p.trim().is_empty());
    if let Some(p) = named("IMBIB_STORE_PATH").or_else(|| named("IMPRESS_STORE_PATH")) {
        return PathBuf::from(p);
    }
    let home = env("HOME").unwrap_or_else(|| ".".into());
    PathBuf::from(home)
        .join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
}

/// The workspace directory (the one holding `impress.sqlite`) the store
/// singleton actually opened, or will open by default — the same directory `SettingsStore::open`
/// wants for the settings files it keeps beside the database
/// (`crates/impress-settings`, R1). Exists so a verb that reads a setting
/// (retention-cleanup) derives the same workspace the store itself uses,
/// without a second copy of the `IMBIB_STORE_PATH` override.
pub fn default_workspace_dir() -> PathBuf {
    STORE
        .get()
        .map(|(_, path)| path.clone())
        .unwrap_or_else(default_store_path)
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Explicit init for callers that need a custom path. Returns `Err` if the
/// singleton has already been initialized.
pub fn init_imbib_store(store_path: PathBuf) -> Result<(), String> {
    if STORE.get().is_some() {
        return Err("imbib store already initialized".to_string());
    }
    let store = ImbibStore::open(store_path.to_string_lossy().into_owned())
        .map_err(|e| format!("ImbibStore::open failed: {e}"))?;
    STORE
        .set((store, store_path))
        .map_err(|_| "imbib store already initialized".to_string())
}

/// The path the singleton opened, once it has initialized.
pub fn opened_store_path() -> Option<PathBuf> {
    STORE.get().map(|(_, path)| path.clone())
}

/// Get (or auto-initialize) the shared `Arc<ImbibStore>`. An explicit
/// `IMBIB_STORE_PATH` that fails to open is fatal: falling back to
/// `:memory:` makes a scratch-store example look like an empty import.
/// The default app-group path may still fall back so a headless process
/// without that file can answer empty reads.
pub fn store_instance() -> Arc<ImbibStore> {
    STORE
        .get_or_init(|| {
            let path = default_store_path();
            let explicit = std::env::var_os("IMBIB_STORE_PATH").is_some();
            let store = match ImbibStore::open(path.to_string_lossy().into_owned()) {
                Ok(store) => store,
                Err(error) if explicit => {
                    panic!(
                        "[imbib-service] IMBIB_STORE_PATH {} failed to open: {error}",
                        path.display()
                    );
                }
                Err(error) => {
                    eprintln!(
                        "[imbib-service] failed to open store at {}: {error}",
                        path.display()
                    );
                    ImbibStore::open(":memory:".to_string())
                        .expect("in-memory ImbibStore always opens")
                }
            };
            (store, path)
        })
        .0
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |name| {
            pairs
                .iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| v.to_string())
        }
    }

    #[test]
    fn the_store_path_prefers_imbib_then_the_suite_store_then_home() {
        let sandboxed = "/Users/x/Library/Containers/com.imbib.impart/Data";
        assert_eq!(
            store_path_from(env(&[
                ("HOME", sandboxed),
                ("IMPRESS_STORE_PATH", "/suite/impress.sqlite")
            ])),
            PathBuf::from("/suite/impress.sqlite")
        );
        assert_eq!(
            store_path_from(env(&[
                ("IMBIB_STORE_PATH", "/imbib.sqlite"),
                ("IMPRESS_STORE_PATH", "/suite/impress.sqlite")
            ])),
            PathBuf::from("/imbib.sqlite")
        );
        assert_eq!(
            store_path_from(env(&[("HOME", "/Users/x"), ("IMPRESS_STORE_PATH", " ")])),
            PathBuf::from(
                "/Users/x/Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite"
            )
        );
    }
}
