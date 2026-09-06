//! UniFFI surface over `impress-remarkable`.
//!
//! The transport (SFTP to the tablet's own SSH server) lives in
//! `impress-remarkable`; what lives here is the mirror records and the
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
        }
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
    Ok(documents
        .into_iter()
        .map(|document| RmDocument {
            id: document.id,
            visible_name: document.visible_name,
            kind: document_kind(document.kind),
            parent: document.parent,
            last_modified_ms: document.last_modified_ms,
            pinned: document.pinned,
            file_type: document.file_type,
            page_count: document.page_count,
            has_annotations: document.has_annotations,
        })
        .collect())
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

/// Restart the tablet's UI so it notices files written underneath it.
#[uniffi::export]
pub fn remarkable_restart_ui(credentials: RmCredentials) -> Result<(), RmError> {
    blocking::restart_ui(&credentials.into())?;
    Ok(())
}
