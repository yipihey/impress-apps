//! UniFFI surface over `impress-remarkable`.
//!
//! The transports (the USB web interface and SFTP to the tablet's own SSH
//! server) live in `impress-remarkable`; what lives here is the mirror records and the
//! `#[uniffi::export]` shims, because imbib-core is the crate that ships a
//! framework to Swift — the same split `embeddings_ffi` uses.
//!
//! Every call is synchronous and blocks on the transport's own runtime, so
//! Swift must call it off the main thread.

use impress_remarkable::{blocking, DeviceCredentials, DocumentKind};

/// How to reach one tablet. The password comes from the app's keychain and
/// is never written to the item graph or a log.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RmCredentials {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    /// Pinned host-key fingerprint; `None` on the first connection only.
    pub fingerprint: Option<String>,
}

impl From<RmCredentials> for DeviceCredentials {
    fn from(credentials: RmCredentials) -> Self {
        Self {
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            fingerprint: credentials.fingerprint,
        }
    }
}

/// What answered on that address.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RmDeviceInfo {
    pub host: String,
    pub fingerprint: String,
    pub firmware: Option<String>,
    pub document_count: u32,
}

/// One entry on the tablet.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RmDocument {
    pub id: String,
    pub visible_name: String,
    /// `document`, `folder` or `unknown`.
    pub kind: String,
    pub parent: String,
    pub last_modified_ms: i64,
    pub pinned: bool,
    /// `pdf`, `epub`, or empty for a notebook.
    pub file_type: String,
    pub page_count: u32,
    pub has_annotations: bool,
}

/// What the tablet did with an upload, learned by listing the folder again.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RmUploadReceipt {
    /// The id the tablet assigned, when the re-listing showed our entry.
    pub id: Option<String>,
    /// The folder listed before the upload (`""` for the top level).
    pub parent: String,
    /// The name the tablet shows, from the filename stem.
    pub visible_name: String,
}

/// Files pulled off the tablet.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RmDownload {
    pub id: String,
    pub source_path: Option<String>,
    pub annotation_paths: Vec<String>,
}

/// Mirrors `impress_remarkable::Error` so Swift can tell a sleeping tablet
/// from a wrong password from a changed host key.
#[derive(uniffi::Error, Debug, thiserror::Error)]
pub enum RmError {
    #[error("{message}")]
    Unreachable { message: String },
    #[error("{message}")]
    Authentication { message: String },
    #[error("{message}")]
    HostKeyChanged { message: String },
    #[error("{message}")]
    Transport { message: String },
    #[error("{message}")]
    NotARemarkable { message: String },
    #[error("{message}")]
    DocumentNotFound { message: String },
    #[error("{message}")]
    Io { message: String },
    #[error("{message}")]
    Misplaced { message: String },
    #[error("{message}")]
    Timeout { message: String },
    #[error("{message}")]
    Archive { message: String },
    #[error("{message}")]
    Format { message: String },
    #[error("{message}")]
    Invalid { message: String },
}

impl From<impress_remarkable::Error> for RmError {
    fn from(error: impress_remarkable::Error) -> Self {
        let message = error.to_string();
        match error {
            impress_remarkable::Error::Unreachable { .. } => Self::Unreachable { message },
            impress_remarkable::Error::Authentication { .. } => Self::Authentication { message },
            impress_remarkable::Error::HostKeyChanged { .. } => Self::HostKeyChanged { message },
            impress_remarkable::Error::Transport { .. } => Self::Transport { message },
            impress_remarkable::Error::NotARemarkable { .. } => Self::NotARemarkable { message },
            impress_remarkable::Error::DocumentNotFound { .. } => {
                Self::DocumentNotFound { message }
            }
            impress_remarkable::Error::Io { .. } => Self::Io { message },
            impress_remarkable::Error::Misplaced { .. } => Self::Misplaced { message },
            impress_remarkable::Error::Timeout { .. } => Self::Timeout { message },
            impress_remarkable::Error::Archive { .. } => Self::Archive { message },
            impress_remarkable::Error::Format { .. } => Self::Format { message },
        }
    }
}

fn rm_document(document: impress_remarkable::RemarkableDocument) -> RmDocument {
    RmDocument {
        id: document.id,
        visible_name: document.visible_name,
        kind: document_kind(document.kind),
        parent: document.parent,
        last_modified_ms: document.last_modified_ms,
        pinned: document.pinned,
        file_type: document.file_type,
        page_count: document.page_count,
        has_annotations: document.has_annotations,
    }
}

fn document_kind(kind: DocumentKind) -> String {
    match kind {
        DocumentKind::Document => "document",
        DocumentKind::Folder => "folder",
        DocumentKind::Unknown => "unknown",
    }
    .to_string()
}

/// Reach the tablet and report its host key, firmware and document count.
#[uniffi::export]
pub fn remarkable_probe(credentials: RmCredentials) -> Result<RmDeviceInfo, RmError> {
    let info = blocking::probe(&credentials.into())?;
    Ok(RmDeviceInfo {
        host: info.host,
        fingerprint: info.fingerprint,
        firmware: info.firmware,
        document_count: info.document_count,
    })
}

/// Every document on the tablet, newest first, deleted ones excluded.
#[uniffi::export]
pub fn remarkable_list_documents(credentials: RmCredentials) -> Result<Vec<RmDocument>, RmError> {
    let documents = blocking::list_documents(&credentials.into())?;
    Ok(documents.into_iter().map(rm_document).collect())
}

/// Pull one document's source file and stroke files into `destination`.
#[uniffi::export]
pub fn remarkable_download_document(
    credentials: RmCredentials,
    id: String,
    destination: String,
) -> Result<RmDownload, RmError> {
    let download =
        blocking::download_document(&credentials.into(), &id, std::path::Path::new(&destination))?;
    Ok(RmDownload {
        id: download.id,
        source_path: download.source_path,
        annotation_paths: download.annotation_paths,
    })
}

// --- USB web interface -------------------------------------------------
//
// The transport that needs no credential: the tablet's own HTTP server over
// the USB network. Preferred on current firmware, where SSH is behind
// Developer mode and the cloud's document endpoints are closed.

/// Where the tablet answers over USB.
#[uniffi::export]
pub fn remarkable_usb_default_url() -> String {
    impress_remarkable::usb_web::DEFAULT_BASE_URL.to_string()
}

/// How many entries the tablet is serving; also the reachability check.
#[uniffi::export]
pub fn remarkable_usb_probe(base_url: String) -> Result<u32, RmError> {
    Ok(blocking::usb_probe(&base_url)?)
}

/// Everything on the tablet, newest first.
#[uniffi::export]
pub fn remarkable_usb_list_documents(base_url: String) -> Result<Vec<RmDocument>, RmError> {
    let documents = blocking::usb_list_documents(&base_url)?;
    Ok(documents.into_iter().map(rm_document).collect())
}

/// Download one document as a PDF with its annotations rendered in.
#[uniffi::export]
pub fn remarkable_usb_download_document(
    base_url: String,
    id: String,
    destination: String,
) -> Result<String, RmError> {
    let path = blocking::usb_download_document(&base_url, &id, std::path::Path::new(&destination))?;
    Ok(path.display().to_string())
}

/// Send a document to the tablet's current folder. Prefer
/// `remarkable_usb_upload_document_into`, which chooses the folder and
/// reports the id.
#[uniffi::export]
pub fn remarkable_usb_upload_document(base_url: String, file: String) -> Result<(), RmError> {
    blocking::usb_upload_document(&base_url, std::path::Path::new(&file))?;
    Ok(())
}

/// A two-second TCP probe: is the tablet plugged in and serving? Never
/// throws, so a UI can poll it.
#[uniffi::export]
pub fn remarkable_usb_reachable(base_url: String) -> bool {
    blocking::usb_reachable(&base_url)
}

/// One folder's entries (`None` = the top level), newest first.
#[uniffi::export]
pub fn remarkable_usb_list_folder(
    base_url: String,
    folder_id: Option<String>,
) -> Result<Vec<RmDocument>, RmError> {
    let documents = blocking::usb_list_folder(&base_url, folder_id.as_deref())?;
    Ok(documents.into_iter().map(rm_document).collect())
}

/// Download one document as `pdf`, `placeholder` (the same rendition) or
/// `rmdoc` (the raw archive) into `dest_dir`; returns the file written.
#[uniffi::export]
pub fn remarkable_usb_download_document_as(
    base_url: String,
    id: String,
    kind: String,
    dest_dir: String,
) -> Result<String, RmError> {
    let kind = impress_remarkable::DownloadKind::parse(&kind).ok_or_else(|| RmError::Invalid {
        message: format!("unknown download kind {kind:?}; use pdf, placeholder or rmdoc"),
    })?;
    let path =
        blocking::usb_download_document_as(&base_url, &id, kind, std::path::Path::new(&dest_dir))?;
    Ok(path.display().to_string())
}

/// List the folder, upload `file` under `upload_name`, list again, and
/// report the id the tablet assigned.
#[uniffi::export]
pub fn remarkable_usb_upload_document_into(
    base_url: String,
    folder_id: Option<String>,
    file: String,
    upload_name: String,
) -> Result<RmUploadReceipt, RmError> {
    let receipt = blocking::usb_upload_document_into(
        &base_url,
        folder_id.as_deref(),
        std::path::Path::new(&file),
        &upload_name,
    )?;
    Ok(RmUploadReceipt {
        id: receipt.id,
        parent: receipt.parent,
        visible_name: receipt.visible_name,
    })
}

/// Restart the tablet's UI so it notices files written underneath it.
#[uniffi::export]
pub fn remarkable_restart_ui(credentials: RmCredentials) -> Result<(), RmError> {
    blocking::restart_ui(&credentials.into())?;
    Ok(())
}
