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
    koine_store::register_shared("sqlite", open_sqlite);
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
///
/// It is imbib's own handle, not a second connection: the opener opens
/// imbib's store at this path (`init_imbib_store`) and hands koine that
/// `SqliteItemStore`. A SQLite store tells only its own subscribers of a
/// write, so with two handles the host's store feed never heard a paper
/// marked read, dismissed or filed by an imbib verb, and a page showed it
/// only at its next redraw. Should imbib's store already be open on another
/// file, the host gets a handle of its own to the one it asked for.
fn open_sqlite(rest: &str) -> Result<Arc<dyn AttributedStore>, StoreError> {
    let path = if rest.is_empty() {
        impress_store_service::store_path()
    } else {
        Path::new(rest).to_path_buf()
    };
    let _ = imbib_service::store_singleton::init_imbib_store(path.clone());
    let same = imbib_service::store_singleton::opened_store_path()
        .is_some_and(|opened| same_file(&opened, &path));
    if same {
        return Ok(imbib_service::store_singleton::store_instance().item_store());
    }
    tracing::warn!(
        target: "koine-host",
        "imbib's store is open on another file than {}; the host opens its own handle, \
         and pages will not redraw on imbib's writes",
        path.display()
    );
    Ok(Arc::new(SqliteItemStore::open(&path)?))
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
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

/// The store URL the host opens when no `--store` was given: koine-host's
/// own default is a `dir:` store under the workspace, which for imbib would
/// be an empty library beside the real one.
pub fn default_store_url() -> String {
    format!("sqlite:{}", impress_store_service::store_path().display())
}
