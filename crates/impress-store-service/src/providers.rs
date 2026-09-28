//! Private, workspace-local persistence for P8 runtime providers.
//!
//! The store row holds descriptors, the host trust decision, and only a
//! credential hash. A token is written first to a private hash-addressed file;
//! the row switches to that hash only after the file is durable. A failed row
//! write may leave an unreferenced file, but never points to a missing token.

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::item::{ItemId, Value as ItemValue};
use impress_core::query::ItemQuery;
use impress_core::schemas::PROVIDER_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{FieldMutation, ItemStore};
use impress_service_core::provider::{
    PersistedProvider, PersistedVerb, ProviderPersistence, RegistrationError, Registry,
    SchemaValidator,
};
use sha2::{Digest, Sha256};

/// The adapter never opens a default store. Its caller supplies the exact
/// already-open GUI/CLI store and the workspace that owns its credential files.
pub struct StoreProviderPersistence {
    store: Arc<SqliteItemStore>,
    credential_dir: PathBuf,
}

impl StoreProviderPersistence {
    pub fn new(store: Arc<SqliteItemStore>, workspace: &Path) -> Result<Self, String> {
        store
            .add_sync_excluded_schemas(&[PROVIDER_SCHEMA.to_string()])
            .map_err(|error| format!("exclude local provider rows from sync: {error}"))?;
        let provider_dir = private_directory(&workspace.join("providers"))?;
        let credential_dir = private_directory(&provider_dir.join("credentials"))?;
        Ok(Self {
            store,
            credential_dir,
        })
    }

    fn row(&self, id: &str) -> Result<Option<PersistedProvider>, String> {
        let item = self
            .store
            .get(row_id(id)?)
            .map_err(|error| format!("read provider row: {error}"))?;
        item.map(|item| {
            if item.schema != PROVIDER_SCHEMA {
                return Err(format!("provider {id} row has an unexpected schema"));
            }
            let row = decode_row(&item.payload)?;
            if row.id != id {
                return Err(format!("provider {id} row has an inconsistent id"));
            }
            Ok(row)
        })
        .transpose()
    }

    fn credential_path(&self, hash: &str) -> Result<PathBuf, String> {
        validate_hash(hash)?;
        let parent = self
            .credential_dir
            .parent()
            .ok_or_else(|| "provider credential directory has no parent".to_string())?;
        private_directory(parent)?;
        private_directory(&self.credential_dir)?;
        Ok(self.credential_dir.join(hash))
    }

    fn write_token(&self, row: &PersistedProvider, token: &str) -> Result<(), String> {
        validate_row_identity(row)?;
        if token.is_empty() || token_hash(token) != row.token_hash {
            return Err("provider credential does not match its row hash".into());
        }
        let path = self.credential_path(&row.token_hash)?;
        // create_new refuses an existing regular file or symlink. An existing
        // hash is safe only when its private contents are the same credential.
        let mut file = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                return if self.read_token(&row.token_hash)?.as_deref() == Some(token) {
                    Ok(())
                } else {
                    Err("provider credential path is occupied".into())
                };
            }
            Err(error) => return Err(format!("create private provider credential: {error}")),
        };
        if let Err(error) = file
            .write_all(token.as_bytes())
            .and_then(|()| file.sync_all())
        {
            drop(file);
            let _ = fs::remove_file(&path);
            return Err(format!("write private provider credential: {error}"));
        }
        File::open(&self.credential_dir)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync private provider credential directory: {error}"))?;
        Ok(())
    }

    fn read_token(&self, hash: &str) -> Result<Option<String>, String> {
        let path = self.credential_path(hash)?;
        let before = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(format!("inspect provider credential: {error}")),
        };
        if !before.file_type().is_file() || before.permissions().mode() & 0o077 != 0 {
            return Err("provider credential is not a private regular file".into());
        }
        let mut file =
            File::open(&path).map_err(|error| format!("open provider credential: {error}"))?;
        let opened = file
            .metadata()
            .map_err(|error| format!("inspect open provider credential: {error}"))?;
        if !opened.is_file()
            || opened.permissions().mode() & 0o077 != 0
            || opened.len() > 256
            || opened.dev() != before.dev()
            || opened.ino() != before.ino()
        {
            return Err("provider credential changed or is not private".into());
        }
        let mut token = String::new();
        file.read_to_string(&mut token)
            .map_err(|error| format!("read provider credential: {error}"))?;
        if token.is_empty() || token_hash(&token) != hash {
            return Err("provider credential does not match its row hash".into());
        }
        Ok(Some(token))
    }

    fn update_flag(&self, row: &PersistedProvider, name: &str) -> Result<(), String> {
        validate_row_identity(row)?;
        let existing = self
            .row(&row.id)?
            .ok_or_else(|| format!("provider {} is not stored", row.id))?;
        let mut expected = row.clone();
        match name {
            "trusted" => expected.trusted = existing.trusted,
            "deregistered" => expected.deregistered = existing.deregistered,
            _ => return Err("unknown provider status field".into()),
        }
        if serde_json::to_value(&expected).map_err(|error| error.to_string())?
            != serde_json::to_value(&existing).map_err(|error| error.to_string())?
        {
            return Err("provider status update changed descriptor or credential facts".into());
        }
        let value = if name == "trusted" {
            row.trusted
        } else {
            row.deregistered
        };
        self.store
            .update(
                row_id(&row.id)?,
                vec![FieldMutation::SetPayload(
                    name.into(),
                    ItemValue::Bool(value),
                )],
            )
            .map_err(|error| format!("update provider {name}: {error}"))
    }
}

impl ProviderPersistence for StoreProviderPersistence {
    fn load(&self) -> Result<Vec<PersistedProvider>, String> {
        let query = ItemQuery {
            schema: Some(PROVIDER_SCHEMA),
            ..Default::default()
        };
        let rows: Vec<PersistedProvider> = self
            .store
            .query(&query)
            .map_err(|error| format!("list provider rows: {error}"))?
            .into_iter()
            .map(|item| {
                let row = decode_row(&item.payload)?;
                validate_row_identity(&row)?;
                if item.id != row_id(&row.id)? {
                    return Err(format!("provider {} has an inconsistent row id", row.id));
                }
                Ok(row)
            })
            .collect::<Result<_, _>>()?;
        log::info!(
            "provider restore: {} registrations, {} descriptors",
            rows.len(),
            rows.iter().map(|row| row.verbs.len()).sum::<usize>()
        );
        Ok(rows)
    }

    fn save_registration(&self, row: &PersistedProvider, token: &str) -> Result<(), String> {
        log::info!(
            "provider registration requested: id={} descriptors={}",
            row.id,
            row.verbs.len()
        );
        // upsert_payload updates by id on AlreadyExists; refuse a collision
        // with any other schema before it can overwrite that row's payload.
        let _ = self.row(&row.id)?;
        self.write_token(row, token)?;
        self.store
            .upsert_payload(row_id(&row.id)?, PROVIDER_SCHEMA, encode_row(row)?)
            .map_err(|error| format!("save provider registration: {error}"))?;
        log::info!("provider registration saved: id={}", row.id);
        Ok(())
    }

    fn save_trust(&self, row: &PersistedProvider) -> Result<(), String> {
        log::info!("provider trust change requested: id={}", row.id);
        self.update_flag(row, "trusted")?;
        log::info!("provider trust change saved: id={}", row.id);
        Ok(())
    }

    fn load_token(&self, provider_id: &str) -> Result<Option<String>, String> {
        self.row(provider_id)?
            .map(|row| self.read_token(&row.token_hash))
            .transpose()
            .map(Option::flatten)
    }

    fn save_status(&self, row: &PersistedProvider) -> Result<(), String> {
        log::info!("provider status change requested: id={}", row.id);
        self.update_flag(row, "deregistered")?;
        log::info!("provider status change saved: id={}", row.id);
        Ok(())
    }
}

/// Construct a registry without ever selecting or opening a process-default
/// store. The caller injects the JSON Schema definition validator until the
/// host's chosen validator boundary is installed.
pub fn build_registry(
    store: Arc<SqliteItemStore>,
    workspace: &Path,
    validator: Arc<dyn SchemaValidator>,
) -> Result<Registry, RegistrationError> {
    let persistence = Arc::new(
        StoreProviderPersistence::new(store, workspace).map_err(RegistrationError::Persistence)?,
    );
    Registry::new()
        .with_validator(validator)
        .with_persistence(persistence)
}

/// Explicit startup hook for a host that already owns its exact store path.
/// Inventory enumeration and documentation generation never call this.
pub fn install_for_store(
    store: Arc<SqliteItemStore>,
    workspace: &Path,
    validator: Arc<dyn SchemaValidator>,
) -> Result<Arc<Registry>, RegistrationError> {
    let registry = Arc::new(build_registry(store, workspace, validator)?);
    impress_service_core::registry_runtime::install(registry.clone());
    Ok(registry)
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

fn row_id(id: &str) -> Result<ItemId, String> {
    validate_id(id)?;
    Ok(uuid::Uuid::new_v5(
        &uuid::Uuid::NAMESPACE_OID,
        format!("provider:{id}").as_bytes(),
    ))
}

fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty()
        || !id.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
    {
        return Err("provider id must be kebab-case".into());
    }
    Ok(())
}

fn validate_hash(hash: &str) -> Result<(), String> {
    if hash.len() != 64
        || !hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("provider credential hash is invalid".into());
    }
    Ok(())
}

fn validate_row_identity(row: &PersistedProvider) -> Result<(), String> {
    validate_id(&row.id)?;
    validate_hash(&row.token_hash)
}

fn token_hash(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

fn encode_row(row: &PersistedProvider) -> Result<BTreeMap<String, ItemValue>, String> {
    validate_row_identity(row)?;
    Ok(BTreeMap::from([
        ("id".into(), ItemValue::String(row.id.clone())),
        ("language".into(), ItemValue::String(row.language.clone())),
        ("version".into(), ItemValue::String(row.version.clone())),
        ("endpoint".into(), ItemValue::String(row.endpoint.clone())),
        ("trusted".into(), ItemValue::Bool(row.trusted)),
        (
            "token_hash".into(),
            ItemValue::String(row.token_hash.clone()),
        ),
        ("deregistered".into(), ItemValue::Bool(row.deregistered)),
        (
            "verbs".into(),
            ItemValue::String(
                serde_json::to_string(&row.verbs)
                    .map_err(|error| format!("encode provider descriptors: {error}"))?,
            ),
        ),
    ]))
}

fn decode_row(payload: &BTreeMap<String, ItemValue>) -> Result<PersistedProvider, String> {
    fn string(payload: &BTreeMap<String, ItemValue>, key: &str) -> Result<String, String> {
        match payload.get(key) {
            Some(ItemValue::String(value)) => Ok(value.clone()),
            _ => Err(format!("provider row lacks string {key}")),
        }
    }
    fn boolean(payload: &BTreeMap<String, ItemValue>, key: &str) -> Result<bool, String> {
        match payload.get(key) {
            Some(ItemValue::Bool(value)) => Ok(*value),
            _ => Err(format!("provider row lacks bool {key}")),
        }
    }
    let verbs: Vec<PersistedVerb> = serde_json::from_str(&string(payload, "verbs")?)
        .map_err(|error| format!("decode provider descriptors: {error}"))?;
    Ok(PersistedProvider {
        id: string(payload, "id")?,
        language: string(payload, "language")?,
        version: string(payload, "version")?,
        endpoint: string(payload, "endpoint")?,
        trusted: boolean(payload, "trusted")?,
        token_hash: string(payload, "token_hash")?,
        deregistered: boolean(payload, "deregistered")?,
        verbs,
    })
}

fn private_directory(path: &Path) -> Result<PathBuf, String> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => return Err(format!("create provider directory: {error}")),
    }
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("inspect provider directory: {error}"))?;
    if !metadata.file_type().is_dir() || metadata.permissions().mode() & 0o077 != 0 {
        return Err("provider credential directory is not private or is a symlink".into());
    }
    Ok(path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::Visibility;
    use impress_service_core::descriptor_handle::VerbHandle;
    use impress_service_core::provider::{
        ProviderExampleInput, ProviderIdentityInput, ProviderStatus, ProviderVerbInput,
        RegistrationRequest, SafetyClaim,
    };
    use serde_json::{json, Value};

    struct TestValidator;

    impl SchemaValidator for TestValidator {
        fn validate(&self, schema: &Value) -> Result<(), String> {
            if schema.is_object() {
                Ok(())
            } else {
                Err("schema must be an object".into())
            }
        }

        fn validate_instance(&self, schema: &Value, value: &Value) -> Result<(), String> {
            let args = value.as_object().ok_or("arguments must be an object")?;
            for required in schema["required"].as_array().into_iter().flatten() {
                let name = required.as_str().ok_or("invalid required field")?;
                if !args.get(name).is_some_and(Value::is_string) {
                    return Err(format!("missing or invalid argument {name}"));
                }
            }
            Ok(())
        }
    }

    fn request(token: Option<String>, version: &str) -> RegistrationRequest {
        RegistrationRequest {
            provider: ProviderIdentityInput {
                id: "python-reference".into(),
                language: "python".into(),
                version: version.into(),
                endpoint: "http://127.0.0.1:23456".into(),
                token,
            },
            verbs: vec![ProviderVerbInput {
                name: "python-reference-service_echo".into(),
                description: "Echo text".into(),
                input_schema: json!({
                    "type":"object",
                    "properties":{"text":{"type":"string","description":"Text to echo"}},
                    "required":["text"],
                    "additionalProperties":false
                }),
                output_schema: json!({
                    "type":"object",
                    "properties":{"echo":{"type":"string"}},
                    "required":["echo"],
                    "additionalProperties":false
                }),
                safety: SafetyClaim {
                    class: "read-only".into(),
                    idempotent: Some(true),
                },
                since: "1.0.0".into(),
                examples: vec![ProviderExampleInput {
                    name: "echo".into(),
                    args: json!({"text":"hello"}),
                    expect: Some(json!({"echo":"hello"})),
                }],
            }],
        }
    }

    #[test]
    fn registration_rotates_private_token_and_persists_trust() {
        let store = Arc::new(SqliteItemStore::open_in_memory().expect("scratch store"));
        let workspace = tempfile::tempdir().expect("scratch workspace");
        let validator: Arc<dyn SchemaValidator> = Arc::new(TestValidator);
        let registry = build_registry(store.clone(), workspace.path(), validator.clone())
            .expect("initial registry");

        let first = registry.register(request(None, "1.0.0")).expect("register");
        assert!(registry.authenticate("python-reference", &first.token));
        let persistence =
            StoreProviderPersistence::new(store.clone(), workspace.path()).expect("persistence");
        let row = persistence.row("python-reference").unwrap().unwrap();
        let path = persistence.credential_path(&row.token_hash).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&persistence.credential_dir)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            persistence.load_token("python-reference").unwrap(),
            Some(first.token.clone())
        );
        let item = store
            .get(row_id("python-reference").unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(item.visibility, Visibility::Private);
        assert!(!item.payload.contains_key("token"));
        assert!(!serde_json::to_string(&item.payload)
            .unwrap()
            .contains(&first.token));
        assert!(store.sync_outbox_entries(10).unwrap().is_empty());

        registry
            .set_trusted("python-reference", true)
            .expect("trust");
        let second = registry
            .register(request(Some(first.token.clone()), "1.1.0"))
            .expect("rotate");
        assert_ne!(first.token, second.token);
        assert!(!registry.authenticate("python-reference", &first.token));
        assert!(registry.authenticate("python-reference", &second.token));
        let restored =
            build_registry(store.clone(), workspace.path(), validator.clone()).expect("restore");
        assert!(!restored.authenticate("python-reference", &first.token));
        assert!(restored.authenticate("python-reference", &second.token));
        assert!(
            persistence
                .row("python-reference")
                .unwrap()
                .unwrap()
                .trusted
        );
        // A restored descriptor exists for catalogues but starts unavailable
        // until the host explicitly probes its endpoint.
        match restored.find("python-reference-service_echo") {
            Some(VerbHandle::Provider(verb)) => {
                assert_eq!(verb.status, ProviderStatus::Unavailable)
            }
            _ => panic!("restored provider descriptor missing"),
        }

        registry
            .deregister("python-reference", &second.token)
            .expect("deregister");
        let restored =
            build_registry(store, workspace.path(), validator).expect("restore tombstone");
        assert!(restored.health_connections().is_empty());
        assert!(!restored.authenticate("python-reference", &second.token));
        assert!(
            persistence
                .row("python-reference")
                .unwrap()
                .unwrap()
                .deregistered
        );
    }

    #[test]
    fn unsafe_credential_directory_and_symlink_are_rejected() {
        let store = Arc::new(SqliteItemStore::open_in_memory().expect("scratch store"));
        let workspace = tempfile::tempdir().expect("scratch workspace");
        let target = tempfile::tempdir().expect("other scratch directory");
        std::os::unix::fs::symlink(target.path(), workspace.path().join("providers"))
            .expect("symlink fixture");
        assert!(StoreProviderPersistence::new(store.clone(), workspace.path()).is_err());
        fs::remove_file(workspace.path().join("providers")).unwrap();

        let registry = build_registry(store, workspace.path(), Arc::new(TestValidator)).unwrap();
        let receipt = registry.register(request(None, "1.0.0")).unwrap();
        let persistence = StoreProviderPersistence::new(
            Arc::new(SqliteItemStore::open_in_memory().unwrap()),
            workspace.path(),
        )
        .unwrap();
        let hash = token_hash(&receipt.token);
        let path = persistence.credential_path(&hash).unwrap();
        fs::remove_file(&path).unwrap();
        let secret = workspace.path().join("other-private-file");
        fs::write(&secret, &receipt.token).unwrap();
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
        std::os::unix::fs::symlink(&secret, &path).unwrap();
        assert!(persistence.read_token(&hash).is_err());
        assert!(persistence.credential_path("../escape").is_err());
    }
}
