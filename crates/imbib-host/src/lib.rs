//! imbib on koine's web frontend.
//!
//! `koine-host` serves every linked verb over HTTP, the koine-web page at
//! `/ui`, MCP at `/mcp`, and the layout and surface verbs; this crate gives it
//! imbib: the verbs (through `impress-capabilities`, the one linked
//! inventory), the suite's SQLite library as the store, and imbib's own pages
//! as a package ([`package`]). Nothing here is a view: a page is a surface
//! document over verbs, drawn by koine-web.

pub mod package;

use std::path::Path;
use std::sync::Arc;

use impress_core::SqliteItemStore;
use impress_item::store::{AttributedStore, BlobStore, StoreError};
use impress_item::ItemId;

/// Link everything the host serves and register the `sqlite:` store scheme.
/// Call first in `main`: the linker drops a crate nothing refers to.
pub fn link() {
    koine_host::ensure_linked();
    impress_capabilities::force_link();
    koine_store::register("sqlite", open_sqlite);
    koine_store::register_blobs("sqlite", open_linked_files);
}

/// The blob view of `sqlite:`: the library's linked files (PDFs and other
/// attachments), read-only, as `/api/blob/<linked-file id>/<filename>`.
/// They live as files beside the database, not in it, so the view finds
/// each through `ImbibStore::resolve_linked_file` — the same ladder the
/// app's `AttachmentManager` climbs.
fn open_linked_files(_rest: &str) -> Result<Option<Arc<dyn BlobStore>>, StoreError> {
    Ok(Some(Arc::new(LinkedFiles)))
}

/// imbib's linked files as a read-only blob store; see [`open_linked_files`].
pub struct LinkedFiles;

impl LinkedFiles {
    /// The file's path, when `item` is a linked file named `name` that
    /// resolves on this Mac.
    fn path_of(&self, item: ItemId, name: &str) -> Result<Option<std::path::PathBuf>, StoreError> {
        let store = imbib_service::store_singleton::store_instance();
        let path = store
            .resolve_linked_file(item.to_string())
            .map_err(|e| StoreError::Validation(e.to_string()))?;
        Ok(path
            .map(std::path::PathBuf::from)
            .filter(|p| p.file_name().and_then(|f| f.to_str()) == Some(name)))
    }
}

impl BlobStore for LinkedFiles {
    fn put_blob(&self, _item: ItemId, _name: &str, _bytes: &[u8]) -> Result<(), StoreError> {
        Err(StoreError::Validation(
            "imbib's linked files are read-only here; attach a file in imbib".into(),
        ))
    }

    fn get_blob(&self, item: ItemId, name: &str) -> Result<Option<Vec<u8>>, StoreError> {
        match self.path_of(item, name)? {
            Some(path) => std::fs::read(&path)
                .map(Some)
                .map_err(|e| StoreError::Validation(format!("{}: {e}", path.display()))),
            None => Ok(None),
        }
    }

    fn delete_blob(&self, _item: ItemId, _name: &str) -> Result<(), StoreError> {
        Err(StoreError::Validation(
            "imbib's linked files are read-only here; remove a file in imbib".into(),
        ))
    }

    fn list_blobs(&self, item: ItemId) -> Result<Vec<String>, StoreError> {
        let store = imbib_service::store_singleton::store_instance();
        let path = store
            .resolve_linked_file(item.to_string())
            .map_err(|e| StoreError::Validation(e.to_string()))?;
        Ok(path
            .as_deref()
            .and_then(|p| std::path::Path::new(p).file_name())
            .and_then(|f| f.to_str())
            .map(|f| vec![f.to_string()])
            .unwrap_or_default())
    }
}

/// `sqlite:<path>`, or `sqlite:` for the suite's store (`IMPRESS_STORE_PATH`,
/// else the app group under `HOME`) — the file every impress app and daemon
/// opens. The host installs it as koine's process store, so koine's own verbs
/// (store query, triage, collections, surfaces) read the same records imbib's
/// verbs do.
fn open_sqlite(rest: &str) -> Result<Box<dyn AttributedStore>, StoreError> {
    let path = if rest.is_empty() {
        impress_store_service::store_path()
    } else {
        Path::new(rest).to_path_buf()
    };
    let store = SqliteItemStore::open(&path)?;
    Ok(Box::new(store))
}

/// Put imbib's secret source in front of the host's. koine-host installs its
/// own (the environment, then `<workspace>/secrets`, what `PUT /api/secret`
/// writes) when it starts serving, which replaced the one imbib installs at
/// link time — so ADS and SciX answered "missing key" in the host though the
/// keys are in imbib's keychain items. Call once the host is bound: imbib's
/// layer (app memory, `KOINE_SECRET_*`, imbib's keychain items) answers
/// first, the host's after it.
pub fn layer_imbib_secrets() {
    let host = impress_service_core::secrets::installed();
    impress_service_core::secrets::install(std::sync::Arc::new(
        koine_host::secrets::LayeredSource::new(vec![
            (
                "imbib",
                std::sync::Arc::new(imbib_service::sources::ImbibSecretSource),
            ),
            ("host", host),
        ]),
    ));
}

/// Wake the pages a write by imbib's own verbs changes, as koine-host's
/// store feed wakes them for its own writes.
///
/// The host opens the library through its handle (`sqlite:`) and imbib's
/// verbs through theirs (`imbib_service::store_singleton`): two connections
/// to one file, and a SQLite store tells only its own subscribers. So the
/// host's feed never heard a paper marked read, dismissed or filed by an
/// imbib verb, and a page showed it only once something else redrew it —
/// most visibly the read mark `imbib-triage-service_viewing` makes two
/// seconds after the page asked. This thread listens to imbib's handle and
/// hands the schema refs each write touched to the same registry the feed
/// uses (`SessionRegistry::shared`), which marks the pages that read them.
/// Call once, after the host is serving.
pub fn wake_pages_on_imbib_writes() {
    let store = imbib_service::store_singleton::store_instance();
    let receiver = match store.subscribe_events() {
        Ok(receiver) => receiver,
        Err(error) => {
            tracing::warn!(target: "koine-host", "imbib feed: cannot subscribe ({error}); \
                pages will not redraw on imbib's own writes");
            return;
        }
    };
    let spawned = std::thread::Builder::new()
        .name("imbib-host-feed".into())
        .spawn(move || {
            let registry = impress_surface_service::SessionRegistry::shared();
            let mut schemas: std::collections::HashMap<ItemId, String> = Default::default();
            while let Ok(first) = receiver.recv() {
                let mut touched = std::collections::BTreeSet::new();
                let mut unknown_delete = false;
                let mut event = Some(first);
                while let Some(current) = event.take() {
                    use impress_item::ItemEvent;
                    match current {
                        ItemEvent::Created(item) => {
                            let schema = item.schema.as_str().to_string();
                            schemas.insert(item.id, schema.clone());
                            touched.insert(schema);
                        }
                        ItemEvent::Updated { id, .. }
                        | ItemEvent::OperationApplied { target_id: id, .. } => {
                            let schema = match schemas.get(&id) {
                                Some(schema) => Some(schema.clone()),
                                None => store.schema_of(id),
                            };
                            if let Some(schema) = schema {
                                schemas.insert(id, schema.clone());
                                touched.insert(schema);
                            }
                        }
                        ItemEvent::Deleted(id) => match schemas.remove(&id) {
                            Some(schema) => {
                                touched.insert(schema);
                            }
                            None => unknown_delete = true,
                        },
                    }
                    event = receiver.try_recv().ok();
                }
                // A row gone before its kind was learned: every kind a page
                // reads, as koine-host's feed does.
                if unknown_delete {
                    touched.extend(registry.watched_refs());
                }
                if !touched.is_empty() {
                    registry.invalidate_refs(&touched);
                }
            }
        });
    if let Err(error) = spawned {
        tracing::warn!(target: "koine-host", "imbib feed: {error}");
    }
}

/// The store URL the host opens when no `--store` was given: koine-host's
/// own default is a `dir:` store under the workspace, which for imbib would
/// be an empty library beside the real one.
pub fn default_store_url() -> String {
    format!("sqlite:{}", impress_store_service::store_path().display())
}
