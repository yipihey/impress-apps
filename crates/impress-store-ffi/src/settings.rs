//! UniFFI surface over the settings registry (ADR-0036 D5, plan R1).
//!
//! One object, [`SharedSettings`], is Swift's whole view of a setting: the
//! registry as JSON, a value by key, `set`/`reset`, the one-time legacy import
//! (`@ImpressSetting` in ImpressKit calls it on a first read that finds no
//! stored value, and never deletes the `UserDefaults` key — D-R5), a change
//! cursor for the host's poll, and the generated pane per section. The same
//! `SettingsStore` the `settings-service` verbs use in this process, so a
//! `settings-service_set` from the CLI and a toggle in the pane write one
//! file — `open` installs it as the service crate's instance (first wins).

use std::sync::Arc;

use impress_core::item::ActorKind;
use impress_settings::{
    registry, section_surface, Resolved, SettingsError, SettingsStore, ValueSource,
};
use impress_store_service::{install_settings, resolved_dto, setting_dto, StoreSyncedBackend};

use crate::surface::SharedSurface;

/// One case per `SettingsError` family.
#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, Clone, thiserror::Error)]
pub enum SharedSettingsError {
    /// The key (or section) is not declared in the registry.
    #[error("{message}")]
    NotFound { message: String },
    /// The value has the wrong type, or an argument would not parse.
    #[error("{message}")]
    InvalidArgument { message: String },
    /// A file or the synced row could not be read or written.
    #[error("{message}")]
    Storage { message: String },
}

impl From<SettingsError> for SharedSettingsError {
    fn from(error: SettingsError) -> Self {
        let message = error.to_string();
        match error {
            SettingsError::UnknownKey(_) => Self::NotFound { message },
            SettingsError::TypeMismatch { .. } => Self::InvalidArgument { message },
            SettingsError::NoSyncedBackend(_) | SettingsError::Io(_) => Self::Storage { message },
        }
    }
}

fn json_error(what: &str, error: impl std::fmt::Display) -> SharedSettingsError {
    SharedSettingsError::InvalidArgument {
        message: format!("{what} is not valid JSON: {error}"),
    }
}

/// A setting with its current value, as Swift reads it. `value_json` and
/// `default_json` are JSON texts (`30`, `true`, `"…"`), typed by `ty`, so
/// the Swift wrapper decodes into the property's own type and a misspelt key
/// never reaches this record at all (`NotFound`).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedSettingValue {
    pub key: String,
    /// `bool`, `integer`, `number` or `string`.
    pub ty: String,
    pub value_json: String,
    pub default_json: String,
    /// `stored` or `default`.
    pub source: String,
    /// `device`, `app:<id>`, `library` or `synced`.
    pub scope: String,
    /// The `UserDefaults` keys to import from, in order, when nothing is stored.
    pub legacy: Vec<String>,
    pub section: String,
    pub label: String,
    pub doc: String,
}

fn value_record(resolved: &Resolved) -> SharedSettingValue {
    SharedSettingValue {
        key: resolved.def.key.clone(),
        ty: resolved.def.ty.label().into(),
        value_json: resolved.value.to_string(),
        default_json: resolved.def.default.to_json().to_string(),
        source: match resolved.source {
            ValueSource::Stored => "stored",
            ValueSource::Default => "default",
        }
        .into(),
        scope: resolved.def.scope.label(),
        legacy: resolved.def.legacy.clone(),
        section: resolved.def.section.clone(),
        label: resolved.def.label.clone(),
        doc: resolved.def.doc.clone(),
    }
}

/// The GUI's handle on the settings registry. One per process; `open` also
/// makes it the `settings-service` verbs' store.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedSettings {
    store: Arc<SettingsStore>,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedSettings {
    /// `workspace_path` is the directory holding `impress.sqlite`
    /// (`SharedWorkspace.workspaceDirectory` in Swift); the files live beside
    /// it under `settings/`. The synced scope reaches the process-wide store
    /// the app's `SharedStore.open` installed.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(workspace_path: String) -> Result<Arc<Self>, SharedSettingsError> {
        if workspace_path.trim().is_empty() {
            return Err(SharedSettingsError::InvalidArgument {
                message: "workspace path must not be empty".into(),
            });
        }
        let store = Arc::new(SettingsStore::open(workspace_path.trim()));
        store.set_synced_backend(Arc::new(StoreSyncedBackend::lazy()));
        // First wins: a second handle in one process (tests) reads the same
        // files anyway.
        let _ = install_settings(store.clone());
        Ok(Arc::new(Self { store }))
    }

    /// Where the scope files live.
    pub fn directory(&self) -> String {
        self.store.directory().display().to_string()
    }

    /// The registry as JSON: `{"settings": [SettingDto…]}` — every declared
    /// key with its type, default, scope, section, legacy keys and doc.
    pub fn schema_json(&self) -> String {
        let settings: Vec<_> = registry().iter().map(setting_dto).collect();
        serde_json::json!({ "settings": settings }).to_string()
    }

    /// Every declared key, in registry order.
    pub fn known_keys(&self) -> Vec<String> {
        registry().iter().map(|def| def.key.clone()).collect()
    }

    /// The current value of `key`: what is stored, else the default.
    pub fn get(&self, key: String) -> Result<SharedSettingValue, SharedSettingsError> {
        Ok(value_record(&self.store.get(key.trim())?))
    }

    /// Every setting of `section` (or all, when empty) as `[SettingDto…]`
    /// JSON with values — what a pane or a debugger lists.
    pub fn list_json(&self, section: String) -> Result<String, SharedSettingsError> {
        let section = section.trim();
        let resolved = self.store.list((!section.is_empty()).then_some(section))?;
        let dtos: Vec<_> = resolved.iter().map(resolved_dto).collect();
        serde_json::to_string(&dtos).map_err(|e| SharedSettingsError::Storage {
            message: e.to_string(),
        })
    }

    /// Store `value_json` (a JSON text: `30`, `true`, `"1 Month"`) for `key`.
    /// The wrong type is refused and nothing is written.
    pub fn set_json(
        &self,
        key: String,
        value_json: String,
    ) -> Result<SharedSettingValue, SharedSettingsError> {
        let value: serde_json::Value =
            serde_json::from_str(&value_json).map_err(|e| json_error("value", e))?;
        let resolved = self.store.set(key.trim(), &value)?;
        tracing::info!(
            target: "settings",
            "set {} = {} (stored in {})",
            resolved.def.key,
            resolved.value,
            resolved.def.scope.label()
        );
        Ok(value_record(&resolved))
    }

    /// Forget the stored value so `key` answers its default.
    pub fn reset(&self, key: String) -> Result<SharedSettingValue, SharedSettingsError> {
        let resolved = self.store.reset(key.trim())?;
        tracing::info!(target: "settings", "reset {} (now default {})", resolved.def.key, resolved.value);
        Ok(value_record(&resolved))
    }

    /// Copy a legacy `UserDefaults` value in, once: writes only when nothing
    /// is stored for `key` yet and answers whether it did. The caller leaves
    /// the `UserDefaults` value where it is (D-R5). A value the type cannot
    /// read is not imported (`false`); the default stands.
    pub fn import_legacy_json(
        &self,
        key: String,
        value_json: String,
    ) -> Result<bool, SharedSettingsError> {
        let value: serde_json::Value =
            serde_json::from_str(&value_json).map_err(|e| json_error("value", e))?;
        let imported = self.store.import_legacy(key.trim(), &value)?;
        if imported {
            tracing::info!(target: "settings", "migrated legacy value → {} = {}", key.trim(), value);
        }
        Ok(imported)
    }

    /// The newest write across the scope files — the cursor a poller keeps.
    pub fn updated_at_ms(&self) -> i64 {
        self.store.updated_at_ms()
    }

    /// Has any scope file been written since `updated_at_ms`? Cheap (a
    /// `stat` per file); the host polls it and re-reads on `true`.
    pub fn changed_since(&self, updated_at_ms: i64) -> bool {
        self.store.changed_since(updated_at_ms)
    }

    /// The generated pane for `section` as `SurfaceSpec` JSON, seeded with
    /// the current values.
    pub fn section_surface_json(&self, section: String) -> Result<String, SharedSettingsError> {
        let section = section.trim();
        let values = self.store.list(Some(section))?;
        let spec =
            section_surface(section, &values).ok_or_else(|| SharedSettingsError::NotFound {
                message: format!("no settings section `{section}` is declared"),
            })?;
        serde_json::to_string(&spec).map_err(|e| SharedSettingsError::Storage {
            message: e.to_string(),
        })
    }

    /// Store (or refresh) the generated pane for `section` as an
    /// `impress/ui/surface@1.0.0` row the `surface` view kind renders, and
    /// reseed this host's state row with the current values, so the pane
    /// opens on what the files say even after a CLI `set`. The row is found
    /// by its `settings:<section>` tag, so there is one per section per
    /// store. Answers the surface id.
    pub fn install_section_surface(
        &self,
        surface: Arc<SharedSurface>,
        section: String,
    ) -> Result<String, SharedSettingsError> {
        let section = section.trim();
        let values = self.store.list(Some(section))?;
        let spec =
            section_surface(section, &values).ok_or_else(|| SharedSettingsError::NotFound {
                message: format!("no settings section `{section}` is declared"),
            })?;
        let tag = format!("settings:{section}");
        let surfaces = surface.surface_store();
        let storage =
            |e: impress_service_core::Refusal| SharedSettingsError::Storage { message: e.message };
        let existing = surfaces
            .list()
            .map_err(storage)?
            .into_iter()
            .find(|row| row.tags.iter().any(|t| t == &tag));
        let row = match existing {
            Some(row) if row.spec == spec => row,
            Some(row) => surfaces
                .update(row.id, &spec, None, None, ActorKind::Human)
                .map_err(storage)?,
            None => surfaces
                .create(&spec, None, std::slice::from_ref(&tag), ActorKind::Human)
                .map_err(storage)?,
        };
        surfaces
            .set_state(row.id, &surface.host(), &spec.state, ActorKind::Human)
            .map_err(storage)?;
        tracing::info!(
            target: "settings",
            "installed settings surface {} for {section} (revision {}, {} fields)",
            row.id,
            row.revision,
            values.len()
        );
        Ok(row.id.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SharedStore;

    #[test]
    fn get_set_import_and_poll_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let settings = SharedSettings::open(dir.path().to_string_lossy().into_owned()).unwrap();
        assert!(settings.directory().ends_with("settings"));
        assert!(settings
            .known_keys()
            .contains(&"imbib.retention.inbox_days".to_string()));
        let schema: serde_json::Value = serde_json::from_str(&settings.schema_json()).unwrap();
        assert_eq!(
            schema["settings"].as_array().unwrap().len(),
            registry().len()
        );

        let got = settings.get("imbib.retention.inbox_days".into()).unwrap();
        assert_eq!(got.value_json, "30");
        assert_eq!(got.source, "default");
        assert_eq!(got.legacy, ["inbox.retentionDays"]);
        assert!(matches!(
            settings.get("imbib.retention.inboxDays".into()),
            Err(SharedSettingsError::NotFound { .. })
        ));

        let cursor = settings.updated_at_ms();
        assert!(!settings.changed_since(cursor));
        assert!(settings
            .import_legacy_json("imbib.retention.inbox_days".into(), "90".into())
            .unwrap());
        assert!(!settings
            .import_legacy_json("imbib.retention.inbox_days".into(), "7".into())
            .unwrap());
        assert_eq!(
            settings
                .get("imbib.retention.inbox_days".into())
                .unwrap()
                .value_json,
            "90"
        );
        assert!(settings.changed_since(cursor));

        let set = settings
            .set_json("imbib.retention.auto_remove_read".into(), "true".into())
            .unwrap();
        assert_eq!(set.value_json, "true");
        assert!(matches!(
            settings.set_json(
                "imbib.retention.auto_remove_read".into(),
                "\"maybe\"".into()
            ),
            Err(SharedSettingsError::InvalidArgument { .. })
        ));
        assert!(matches!(
            settings.set_json("imbib.retention.auto_remove_read".into(), "not json".into()),
            Err(SharedSettingsError::InvalidArgument { .. })
        ));
        let reset = settings.reset("imbib.retention.inbox_days".into()).unwrap();
        assert_eq!(reset.source, "default");
        let listed: serde_json::Value =
            serde_json::from_str(&settings.list_json("imbib.retention".into()).unwrap()).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 4);
    }

    #[test]
    fn section_surface_is_installed_once_and_reseeded() {
        let dir = tempfile::tempdir().unwrap();
        let settings = SharedSettings::open(dir.path().to_string_lossy().into_owned()).unwrap();
        let store = SharedStore::open_in_memory().unwrap();
        let surface = SharedSurface::open(store, "test-host".into(), "imbib".into());
        let spec = settings
            .section_surface_json("imbib.retention".into())
            .unwrap();
        assert!(spec.contains("settings-service_set"));

        let first = settings
            .install_section_surface(surface.clone(), "imbib.retention".into())
            .unwrap();
        let again = settings
            .install_section_surface(surface.clone(), "imbib.retention".into())
            .unwrap();
        assert_eq!(first, again, "one row per section");
        assert_eq!(surface.surface_store().list().unwrap().len(), 1);

        settings
            .set_json("imbib.retention.inbox_days".into(), "\"1 Week\"".into())
            .unwrap();
        let refreshed = settings
            .install_section_surface(surface.clone(), "imbib.retention".into())
            .unwrap();
        assert_eq!(refreshed, first);
        let id = first.parse().unwrap();
        let state = surface
            .surface_store()
            .get_state(id, &surface.host())
            .unwrap()
            .unwrap();
        assert_eq!(state["imbib_retention_inbox_days"], "1 Week");
        assert!(matches!(
            settings.install_section_surface(surface, "nowhere".into()),
            Err(SharedSettingsError::NotFound { .. })
        ));
    }
}
