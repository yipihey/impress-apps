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

/// Path used when the singleton auto-initializes. Override with the
/// `IMBIB_STORE_PATH` environment variable.
fn default_store_path() -> PathBuf {
    if let Ok(p) = std::env::var("IMBIB_STORE_PATH") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
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

/// Get (or auto-initialize) the shared `Arc<ImbibStore>`. On open failure
/// falls back to an in-memory store so service methods don't panic — they'll
/// just return empty results and log via stderr.
pub fn store_instance() -> Arc<ImbibStore> {
    STORE
        .get_or_init(|| {
            let path = default_store_path();
            let store = ImbibStore::open(path.to_string_lossy().into_owned()).unwrap_or_else(|e| {
                eprintln!(
                    "[imbib-service] failed to open store at {}: {e}",
                    path.display()
                );
                ImbibStore::open(":memory:".to_string()).expect("in-memory ImbibStore always opens")
            });
            (store, path)
        })
        .0
        .clone()
}
