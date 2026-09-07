//! What the engine needs from a tablet, and the two things that provide it:
//! the USB web interface (through `impress-remarkable`) and a scripted mock
//! for tests.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

use impress_remarkable::rmdoc::parse_rmdoc;
use impress_remarkable::{blocking, DocumentKind, DownloadKind, RemarkableDocument, UploadReceipt};

use crate::unified::store_api::StoreApiError;

/// Everything a sync can fail with, kept coarse: the caller shows the text.
#[derive(Debug, thiserror::Error)]
pub enum EinkError {
    #[error("no e-ink device is configured (Settings › E-Ink Devices)")]
    NoDevice,
    #[error("{0}")]
    Store(#[from] StoreApiError),
    #[error("the tablet is not reachable: {0}")]
    Unreachable(String),
    #[error("{0}")]
    Transport(String),
    #[error("{0}")]
    Misplaced(String),
    #[error("{0}")]
    Io(String),
    #[error("another sync holds the device: {0}")]
    Locked(String),
    #[error("{0}")]
    Invalid(String),
}

impl From<impress_remarkable::Error> for EinkError {
    fn from(error: impress_remarkable::Error) -> Self {
        let message = error.to_string();
        match error {
            impress_remarkable::Error::Unreachable { .. }
            | impress_remarkable::Error::Timeout { .. } => Self::Unreachable(message),
            impress_remarkable::Error::Misplaced { .. } => Self::Misplaced(message),
            impress_remarkable::Error::Io { .. } => Self::Io(message),
            _ => Self::Transport(message),
        }
    }
}

/// The tablet as the engine sees it. Blocking on purpose: the engine runs
/// on a background thread (Swift) or inside `spawn_blocking` (services).
pub trait EinkTransport: Send + Sync {
    /// A fast probe (≤ 2 s); never an error.
    fn reachable(&self) -> bool;
    /// One folder's entries (`None` = the top level).
    fn list_folder(&self, folder_id: Option<&str>) -> Result<Vec<RemarkableDocument>, EinkError>;
    /// List the folder, upload `file` under `upload_name`, list again.
    fn upload_into(
        &self,
        folder_id: Option<&str>,
        file: &Path,
        upload_name: &str,
    ) -> Result<UploadReceipt, EinkError>;
    /// Download one rendition into `dest_dir`; returns the file written.
    fn download(&self, id: &str, kind: DownloadKind, dest_dir: &Path)
        -> Result<PathBuf, EinkError>;
}

/// The USB web interface.
pub struct UsbWebTransport {
    pub base_url: String,
}

impl UsbWebTransport {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
        }
    }
}

impl EinkTransport for UsbWebTransport {
    fn reachable(&self) -> bool {
        blocking::usb_reachable(&self.base_url)
    }

    fn list_folder(&self, folder_id: Option<&str>) -> Result<Vec<RemarkableDocument>, EinkError> {
        Ok(blocking::usb_list_folder(&self.base_url, folder_id)?)
    }

    fn upload_into(
        &self,
        folder_id: Option<&str>,
        file: &Path,
        upload_name: &str,
    ) -> Result<UploadReceipt, EinkError> {
        Ok(blocking::usb_upload_document_into(
            &self.base_url,
            folder_id,
            file,
            upload_name,
        )?)
    }

    fn download(
        &self,
        id: &str,
        kind: DownloadKind,
        dest_dir: &Path,
    ) -> Result<PathBuf, EinkError> {
        Ok(blocking::usb_download_document_as(
            &self.base_url,
            id,
            kind,
            dest_dir,
        )?)
    }
}

/// A scripted tablet for tests: a flat list of entries, uploads that mint
/// ids, and a call log for asserting order. Uploading a folder archive
/// creates a folder with the archive's own id and parent, which is how the
/// "rmdoc" folder strategy is exercised without a device.
#[derive(Default)]
pub struct MockTransport {
    entries: Mutex<Vec<RemarkableDocument>>,
    pub calls: Mutex<Vec<String>>,
    reachable: AtomicBool,
    next_id: AtomicUsize,
    fail_next_upload: Mutex<Option<String>>,
    downloads: Mutex<HashMap<(String, String), Vec<u8>>>,
    /// When set, plain uploads are filed at the top level regardless of the
    /// folder listed — the failure mode the engine must detect.
    pub misfile_uploads: AtomicBool,
}

impl MockTransport {
    pub fn new() -> Self {
        let mock = Self::default();
        mock.reachable.store(true, Ordering::SeqCst);
        mock
    }

    pub fn set_reachable(&self, reachable: bool) {
        self.reachable.store(reachable, Ordering::SeqCst);
    }

    pub fn add_folder(&self, id: &str, parent: &str, name: &str) {
        self.entries.lock().unwrap().push(RemarkableDocument {
            id: id.into(),
            visible_name: name.into(),
            kind: DocumentKind::Folder,
            parent: parent.into(),
            last_modified_ms: 1,
            pinned: false,
            file_type: String::new(),
            page_count: 0,
            has_annotations: false,
        });
    }

    pub fn add_document(
        &self,
        id: &str,
        parent: &str,
        name: &str,
        file_type: &str,
        modified_ms: i64,
    ) {
        self.entries.lock().unwrap().push(RemarkableDocument {
            id: id.into(),
            visible_name: name.into(),
            kind: DocumentKind::Document,
            parent: parent.into(),
            last_modified_ms: modified_ms,
            pinned: false,
            file_type: file_type.into(),
            page_count: 0,
            has_annotations: false,
        });
    }

    pub fn remove(&self, id: &str) {
        self.entries.lock().unwrap().retain(|entry| entry.id != id);
    }

    /// Pretend the user wrote on a document at `modified_ms`.
    pub fn touch(&self, id: &str, modified_ms: i64) {
        for entry in self.entries.lock().unwrap().iter_mut() {
            if entry.id == id {
                entry.last_modified_ms = modified_ms;
            }
        }
    }

    pub fn fail_next_upload(&self, message: &str) {
        *self.fail_next_upload.lock().unwrap() = Some(message.into());
    }

    pub fn set_download(&self, id: &str, kind: DownloadKind, bytes: Vec<u8>) {
        self.downloads
            .lock()
            .unwrap()
            .insert((id.into(), format!("{kind:?}")), bytes);
    }

    pub fn entries(&self) -> Vec<RemarkableDocument> {
        self.entries.lock().unwrap().clone()
    }

    pub fn find_by_name(&self, name: &str) -> Option<RemarkableDocument> {
        self.entries()
            .into_iter()
            .find(|entry| entry.visible_name == name)
    }

    fn mint_id(&self) -> String {
        format!("mock-{}", self.next_id.fetch_add(1, Ordering::SeqCst) + 1)
    }
}

impl EinkTransport for MockTransport {
    fn reachable(&self) -> bool {
        self.calls.lock().unwrap().push("reachable".into());
        self.reachable.load(Ordering::SeqCst)
    }

    fn list_folder(&self, folder_id: Option<&str>) -> Result<Vec<RemarkableDocument>, EinkError> {
        if !self.reachable.load(Ordering::SeqCst) {
            return Err(EinkError::Unreachable("mock unplugged".into()));
        }
        let parent = folder_id.unwrap_or("");
        self.calls.lock().unwrap().push(format!("list:{parent}"));
        Ok(self
            .entries
            .lock()
            .unwrap()
            .iter()
            .filter(|entry| entry.parent == parent)
            .cloned()
            .collect())
    }

    fn upload_into(
        &self,
        folder_id: Option<&str>,
        file: &Path,
        upload_name: &str,
    ) -> Result<UploadReceipt, EinkError> {
        if !self.reachable.load(Ordering::SeqCst) {
            return Err(EinkError::Unreachable("mock unplugged".into()));
        }
        let parent = folder_id.unwrap_or("").to_string();
        self.calls
            .lock()
            .unwrap()
            .push(format!("upload:{parent}:{upload_name}"));
        if let Some(message) = self.fail_next_upload.lock().unwrap().take() {
            return Err(EinkError::Transport(message));
        }
        let bytes = std::fs::read(file).map_err(|e| EinkError::Io(e.to_string()))?;
        let stem = upload_name
            .rsplit_once('.')
            .map(|(stem, _)| stem)
            .unwrap_or(upload_name)
            .to_string();

        if upload_name.to_ascii_lowercase().ends_with(".rmdoc") {
            // Honour the archive's identity, like a firmware that imports
            // the files as they are.
            let archive = parse_rmdoc(&bytes).map_err(EinkError::from)?;
            let is_folder = archive.metadata.kind == "CollectionType";
            let filed_under = if self.misfile_uploads.load(Ordering::SeqCst) {
                String::new()
            } else {
                archive.metadata.parent.clone()
            };
            let entry = RemarkableDocument {
                id: archive.id.clone(),
                visible_name: archive.metadata.visible_name.clone(),
                kind: if is_folder {
                    DocumentKind::Folder
                } else {
                    DocumentKind::Document
                },
                parent: filed_under,
                last_modified_ms: archive.metadata.last_modified.parse().unwrap_or(1),
                pinned: false,
                file_type: archive.content.file_type.clone(),
                page_count: 0,
                has_annotations: false,
            };
            let actual_parent = entry.parent.clone();
            self.entries.lock().unwrap().push(entry);
            if actual_parent != parent {
                return Err(EinkError::Misplaced(format!(
                    "mock filed {} under {actual_parent:?} instead of {parent:?}",
                    archive.id
                )));
            }
            return Ok(UploadReceipt {
                id: Some(archive.id),
                parent: actual_parent,
                visible_name: archive.metadata.visible_name,
            });
        }

        let id = self.mint_id();
        let actual_parent = if self.misfile_uploads.load(Ordering::SeqCst) {
            String::new()
        } else {
            parent.clone()
        };
        let file_type = upload_name
            .rsplit_once('.')
            .map(|(_, ext)| ext.to_ascii_lowercase())
            .unwrap_or_default();
        self.entries.lock().unwrap().push(RemarkableDocument {
            id: id.clone(),
            visible_name: stem.clone(),
            kind: DocumentKind::Document,
            parent: actual_parent.clone(),
            last_modified_ms: 1_000 + self.next_id.load(Ordering::SeqCst) as i64,
            pinned: false,
            file_type,
            page_count: 0,
            has_annotations: false,
        });
        if actual_parent != parent {
            return Err(EinkError::Misplaced(format!(
                "mock filed {id} under {actual_parent:?} instead of {parent:?}"
            )));
        }
        Ok(UploadReceipt {
            id: Some(id),
            parent,
            visible_name: stem,
        })
    }

    fn download(
        &self,
        id: &str,
        kind: DownloadKind,
        dest_dir: &Path,
    ) -> Result<PathBuf, EinkError> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("download:{id}:{kind:?}"));
        std::fs::create_dir_all(dest_dir).map_err(|e| EinkError::Io(e.to_string()))?;
        let extension = match kind {
            DownloadKind::Rmdoc => "rmdoc",
            DownloadKind::Pdf | DownloadKind::Placeholder => "pdf",
        };
        let path = dest_dir.join(format!("{id}.{extension}"));
        let bytes = self
            .downloads
            .lock()
            .unwrap()
            .get(&(id.to_string(), format!("{kind:?}")))
            .cloned()
            .unwrap_or_else(|| format!("%PDF-mock {id} {kind:?}").into_bytes());
        std::fs::write(&path, bytes).map_err(|e| EinkError::Io(e.to_string()))?;
        Ok(path)
    }
}
