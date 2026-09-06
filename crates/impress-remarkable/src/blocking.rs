//! Synchronous entry points for FFI callers.
//!
//! The work runs on a private runtime driven from a scoped helper thread, so
//! this is safe to call from a plain thread and from inside another runtime's
//! blocking pool — the same arrangement `impress_ai::blocking` uses.

use std::path::Path;
use std::sync::OnceLock;

use crate::documents::RemarkableDocument;
use crate::error::{Error, Result};
use crate::transport::{DeviceCredentials, DeviceInfo, DownloadedDocument};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("impress-remarkable")
            .enable_all()
            .build()
            .expect("build the impress-remarkable runtime")
    })
}

fn block_on<F, T>(future: F) -> Result<T>
where
    F: std::future::Future<Output = Result<T>> + Send,
    T: Send,
{
    std::thread::scope(|scope| {
        scope
            .spawn(|| runtime().block_on(future))
            .join()
            .map_err(|_| Error::Io {
                path: "<runtime>".into(),
                detail: "the reMarkable transport panicked".into(),
            })?
    })
}

pub fn probe(credentials: &DeviceCredentials) -> Result<DeviceInfo> {
    block_on(crate::transport::probe(credentials))
}

pub fn list_documents(credentials: &DeviceCredentials) -> Result<Vec<RemarkableDocument>> {
    block_on(crate::transport::list_documents(credentials))
}

pub fn download_document(
    credentials: &DeviceCredentials,
    id: &str,
    destination: &Path,
) -> Result<DownloadedDocument> {
    block_on(crate::transport::download_document(
        credentials,
        id,
        destination,
    ))
}

pub fn restart_ui(credentials: &DeviceCredentials) -> Result<()> {
    block_on(crate::transport::restart_ui(credentials))
}
