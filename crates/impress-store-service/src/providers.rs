//! Private, workspace-local persistence for P8 runtime providers, now
//! koine's (`koine_providers::persistence`, docs/plan-koine-kit-moves.md
//! KM12). This module keeps what is this suite's: provider rows stay out of
//! the SQLite store's sync, and the "selected store" entry points, which find
//! the suite's store and refuse its in-memory stand-in.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::schemas::PROVIDER_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::provider::{RegistrationError, Registry, SchemaValidator};

pub use koine_providers::persistence::StoreProviderPersistence;

/// Keep this device's provider rows out of the store's sync.
fn exclude_from_sync(store: &SqliteItemStore) -> Result<(), RegistrationError> {
    store
        .add_sync_excluded_schemas(&[PROVIDER_SCHEMA.to_string()])
        .map_err(|error| {
            RegistrationError::Persistence(format!(
                "exclude local provider rows from sync: {error}"
            ))
        })
}

/// Construct a registry over `store` without selecting or opening a
/// process-default store; see [`koine_providers::build_registry`].
pub fn build_registry(
    store: Arc<SqliteItemStore>,
    workspace: &Path,
    validator: Arc<dyn SchemaValidator>,
) -> Result<Registry, RegistrationError> {
    exclude_from_sync(&store)?;
    koine_providers::build_registry(store, workspace, validator)
}

/// Explicit startup hook for a host that already owns its exact store path;
/// see [`koine_providers::install_for_store`].
pub fn install_for_store(
    store: Arc<SqliteItemStore>,
    workspace: &Path,
    validator: Arc<dyn SchemaValidator>,
) -> Result<Arc<Registry>, RegistrationError> {
    exclude_from_sync(&store)?;
    koine_providers::install_for_store(store, workspace, validator)
}

/// Workspace attached to the selected store. An explicit workspace override is
/// shared with the job and settings hosts; otherwise credentials live beside
/// that store, never beside an unrelated default database.
pub fn selected_workspace() -> PathBuf {
    std::env::var_os("IMPRESS_WORKSPACE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            crate::store_path()
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| Path::new("."))
                .to_path_buf()
        })
}

/// Explicit host startup, after selecting its store. A fallback database must
/// never accept a registration or silently replace durable trust decisions.
pub fn install_for_selected_store(
    validator: Arc<dyn SchemaValidator>,
) -> Result<Arc<Registry>, RegistrationError> {
    let store = crate::store_instance();
    if crate::is_fallback_store(&store) {
        return Err(RegistrationError::Persistence(
            "the selected provider store is unavailable".into(),
        ));
    }
    install_for_store(store, &selected_workspace(), validator)
}

/// Read-only consumers need no database startup cost in workspaces that have
/// never registered a provider. HTTP registration hosts use the explicit
/// installer above so the first registration has durable persistence too.
pub fn install_if_registered(
    validator: Arc<dyn SchemaValidator>,
) -> Result<bool, RegistrationError> {
    if !selected_workspace().join("providers/credentials").exists() {
        return Ok(false);
    }
    install_for_selected_store(validator)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    struct AnySchema;

    impl SchemaValidator for AnySchema {
        fn validate(&self, _: &Value) -> Result<(), String> {
            Ok(())
        }
        fn validate_instance(&self, _: &Value, _: &Value) -> Result<(), String> {
            Ok(())
        }
    }

    /// Provider rows are this device's: building the registry over the
    /// SQLite store keeps them out of its sync outbox.
    #[test]
    fn provider_rows_stay_out_of_sync() {
        let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
        let workspace = tempfile::tempdir().unwrap();
        let registry =
            build_registry(store.clone(), workspace.path(), Arc::new(AnySchema)).unwrap();
        let request = serde_json::from_value(serde_json::json!({
            "provider": {"id": "sync-fixture", "language": "Python", "version": "1.0.0",
                         "endpoint": "http://127.0.0.1:1"},
            "verbs": [{"name": "sync-fixture-service_read", "description": "Read a value",
                       "input_schema": {"type": "object", "properties": {}, "additionalProperties": false},
                       "output_schema": {"type": "object"},
                       "safety": {"class": "read_only"}, "since": "1.0.0", "examples": [{"name": "read", "args": {}}]}]
        }))
        .unwrap();
        registry.register(request).unwrap();
        assert!(store.sync_outbox_entries(10).unwrap().is_empty());
    }
}
