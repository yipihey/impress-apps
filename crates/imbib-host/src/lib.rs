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

use impress_core::SqliteItemStore;
use impress_item::store::{AttributedStore, StoreError};

/// Link everything the host serves and register the `sqlite:` store scheme.
/// Call first in `main`: the linker drops a crate nothing refers to.
pub fn link() {
    koine_host::ensure_linked();
    impress_capabilities::force_link();
    koine_store::register("sqlite", open_sqlite);
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

/// The store URL the host opens when no `--store` was given: koine-host's
/// own default is a `dir:` store under the workspace, which for imbib would
/// be an empty library beside the real one.
pub fn default_store_url() -> String {
    format!("sqlite:{}", impress_store_service::store_path().display())
}
