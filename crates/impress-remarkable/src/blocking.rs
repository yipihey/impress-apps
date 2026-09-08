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

// --- the USB web interface (no credential of any kind) ---

pub fn usb_list_documents(base_url: &str) -> Result<Vec<RemarkableDocument>> {
    block_on(crate::usb_web::list_documents(base_url))
}

pub fn usb_probe(base_url: &str) -> Result<u32> {
    block_on(crate::usb_web::probe(base_url))
}

pub fn usb_download_document(
    base_url: &str,
    id: &str,
    destination: &Path,
) -> Result<std::path::PathBuf> {
    block_on(crate::usb_web::download_document(base_url, id, destination))
}

pub fn usb_upload_document(base_url: &str, file: &Path) -> Result<()> {
    block_on(crate::usb_web::upload_document(base_url, file))
}

/// One folder's entries (`None` = the top level).
pub fn usb_list_folder(base_url: &str, folder_id: Option<&str>) -> Result<Vec<RemarkableDocument>> {
    block_on(crate::usb_web::list_folder(base_url, folder_id))
}

/// A short TCP probe; never an error, just an answer.
pub fn usb_reachable(base_url: &str) -> bool {
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                runtime().block_on(crate::usb_web::reachable(
                    base_url,
                    crate::usb_web::REACHABLE_TIMEOUT,
                ))
            })
            .join()
            .unwrap_or(false)
    })
}

pub fn usb_download_document_as(
    base_url: &str,
    id: &str,
    kind: crate::usb_web::DownloadKind,
    dest_dir: &Path,
) -> Result<std::path::PathBuf> {
    block_on(crate::usb_web::download_document_as(
        base_url, id, kind, dest_dir,
    ))
}

/// List the folder, upload, list again; see `usb_web::upload_document_into`.
pub fn usb_upload_document_into(
    base_url: &str,
    folder_id: Option<&str>,
    file: &Path,
    upload_name: &str,
) -> Result<crate::usb_web::UploadReceipt> {
    block_on(crate::usb_web::upload_document_into(
        base_url,
        folder_id,
        file,
        upload_name,
    ))
}
