//! The tablet's own USB web interface.
//!
//! Turned on under Settings → Storage → "USB web interface", the tablet
//! serves a small HTTP API on `http://10.11.99.1` over the USB network. It is
//! the only transport reMarkable supports that needs **no credential at all**:
//! no cloud token, no device password, no developer mode. On current firmware
//! that matters, because SSH sits behind Developer mode (which erases a Paper
//! Pro when enabled) and the cloud's document endpoints are closed to
//! third-party clients.
//!
//! The whole API, learned from the interface's own client bundle:
//!
//! * `GET /documents/` — the top level; `GET /documents/{folder}` descends.
//!   Entries carry `ID`, `VissibleName` (the tablet's long-standing typo),
//!   `Parent`, `Type` (`DocumentType` | `CollectionType`), `ModifiedClient`,
//!   `Bookmarked`, `CurrentPage` and `fileType` (`pdf` | `epub` | `notebook`).
//! * `POST /upload` — multipart, field `file`; `.pdf`, `.epub` and `.rmdoc`.
//!   The upload lands in **whatever folder was listed last**: the server keeps
//!   "current folder" as session state, and the tablet's client always issues
//!   `GET /documents/{folder}` immediately before the POST. Callers must
//!   serialize list → upload → list per device (imbib's engine holds a mutex
//!   per base URL); [`upload_document_into`] does the three calls itself.
//! * `GET /download/{id}/pdf` (or `/placeholder`) — the document as a PDF
//!   **with the handwriting rendered into the pages**; `/rmdoc` — the raw
//!   archive with the stroke files, which is what an annotation import wants.
//!
//! There is no endpoint to create, rename, move or delete anything. Unknown
//! paths hang instead of answering 404, hence the generous timeouts.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;

use crate::documents::{DocumentKind, RemarkableDocument};
use crate::error::{Error, Result};

/// Where the tablet answers when connected by USB.
pub const DEFAULT_BASE_URL: &str = "http://10.11.99.1";

/// The interface enumerates instantly but a large PDF takes a while, and the
/// tablet's own client allows 30 s for a listing.
const LIST_TIMEOUT: Duration = Duration::from_secs(30);
const TRANSFER_TIMEOUT: Duration = Duration::from_secs(600);
/// A reachability probe must answer fast enough to poll from a UI.
pub const REACHABLE_TIMEOUT: Duration = Duration::from_secs(2);

/// One row of `GET /documents/…`.
#[derive(Debug, Clone, Deserialize)]
struct WebEntry {
    #[serde(rename = "ID")]
    id: String,
    /// Current firmware sends the name under BOTH spellings — the historical
    /// typo `VissibleName` and the corrected `VisibleName` — so an alias
    /// would trip on a duplicate field. Read both, prefer whichever is set.
    #[serde(rename = "VisibleName", default)]
    visible_name: String,
    #[serde(rename = "VissibleName", default)]
    vissible_name: String,
    #[serde(rename = "Parent", default)]
    parent: String,
    #[serde(rename = "Type", default)]
    kind: String,
    #[serde(rename = "ModifiedClient", default)]
    modified_client: String,
    #[serde(rename = "Bookmarked", default)]
    bookmarked: bool,
    #[serde(rename = "CurrentPage", default)]
    current_page: u32,
    #[serde(rename = "fileType", default)]
    file_type: String,
}

impl WebEntry {
    fn into_document(self) -> RemarkableDocument {
        RemarkableDocument {
            kind: match self.kind.as_str() {
                "DocumentType" => DocumentKind::Document,
                "CollectionType" => DocumentKind::Folder,
                _ => DocumentKind::Unknown,
            },
            // The interface reports an ISO-8601 stamp rather than millis.
            last_modified_ms: chrono::DateTime::parse_from_rfc3339(&self.modified_client)
                .map(|stamp| stamp.timestamp_millis())
                .unwrap_or(0),
            id: self.id,
            visible_name: if self.visible_name.is_empty() {
                self.vissible_name
            } else {
                self.visible_name
            },
            parent: self.parent,
            pinned: self.bookmarked,
            file_type: self.file_type,
            // The interface exposes the page the reader is on, not the length,
            // and says nothing about annotations — they arrive rendered into
            // the downloaded PDF instead.
            page_count: self.current_page,
            has_annotations: false,
        }
    }
}

/// Which rendition of a document to download.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownloadKind {
    /// `/download/{id}/placeholder`: the PDF with annotations rendered in
    /// (the spelling imbib used first; kept because it is known to work).
    Placeholder,
    /// `/download/{id}/pdf`: the same rendition under the name the tablet's
    /// own client uses.
    Pdf,
    /// `/download/{id}/rmdoc`: the raw reMarkable archive (metadata, content,
    /// source file and one `.rm` stroke file per page).
    Rmdoc,
}

impl DownloadKind {
    fn path_segment(self) -> &'static str {
        match self {
            Self::Placeholder => "placeholder",
            Self::Pdf => "pdf",
            Self::Rmdoc => "rmdoc",
        }
    }

    fn extension(self) -> &'static str {
        match self {
            Self::Placeholder | Self::Pdf => "pdf",
            Self::Rmdoc => "rmdoc",
        }
    }

    /// The spelling a caller across FFI uses.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "placeholder" => Some(Self::Placeholder),
            "pdf" => Some(Self::Pdf),
            "rmdoc" => Some(Self::Rmdoc),
            _ => None,
        }
    }
}

/// What [`upload_document_into`] learned by listing the folder again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadReceipt {
    /// The id the tablet assigned, when the re-listing showed exactly the
    /// entry we sent. `None` means the upload was accepted (HTTP 201) but
    /// the entry could not be told apart from what was already there — the
    /// caller should list again later rather than guess.
    pub id: Option<String>,
    /// The folder that was listed before the upload (`""` for the top level).
    pub parent: String,
    /// The name the tablet shows, taken from the filename stem.
    pub visible_name: String,
}

fn client(timeout: Duration) -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|error| Error::transport("usb", "building an HTTP client", error))
}

fn unreachable(base_url: &str, error: impl std::fmt::Display) -> Error {
    Error::Unreachable {
        host: base_url.to_string(),
        port: 80,
        detail: format!(
            "{error} — connect the tablet by USB and turn on Settings → Storage → USB web interface"
        ),
    }
}

fn documents_path(folder_id: Option<&str>) -> String {
    match folder_id.filter(|id| !id.is_empty() && *id != "root") {
        Some(id) => format!("/documents/{id}"),
        None => "/documents/".to_string(),
    }
}

/// The entries of one folder (`None` = the top level), newest first.
///
/// This is also the call that sets the server's "current folder" for the
/// next upload; see the module docs.
pub async fn list_folder(
    base_url: &str,
    folder_id: Option<&str>,
) -> Result<Vec<RemarkableDocument>> {
    let response = client(LIST_TIMEOUT)?
        .get(format!("{base_url}{}", documents_path(folder_id)))
        .send()
        .await
        .map_err(|error| unreachable(base_url, error))?;
    if !response.status().is_success() {
        return Err(Error::transport(
            base_url,
            "listing documents",
            response.status(),
        ));
    }
    let entries: Vec<WebEntry> = response
        .json()
        .await
        .map_err(|error| Error::transport(base_url, "parsing the document list", error))?;
    let mut documents: Vec<RemarkableDocument> =
        entries.into_iter().map(WebEntry::into_document).collect();
    documents.sort_by_key(|document| std::cmp::Reverse(document.last_modified_ms));
    Ok(documents)
}

/// Every entry at the top level, documents and folders, newest first.
pub async fn list_documents(base_url: &str) -> Result<Vec<RemarkableDocument>> {
    list_folder(base_url, None).await
}

/// Whether the interface is up, and how much it holds at the top level.
pub async fn probe(base_url: &str) -> Result<u32> {
    Ok(list_documents(base_url).await?.len() as u32)
}

/// A fast answer to "is the tablet plugged in?": a TCP connect with a short
/// timeout, no request. Cheap enough to poll every few seconds.
pub async fn reachable(base_url: &str, timeout: Duration) -> bool {
    let Some((host, port)) = host_and_port(base_url) else {
        return false;
    };
    matches!(
        tokio::time::timeout(
            timeout,
            tokio::net::TcpStream::connect((host.as_str(), port))
        )
        .await,
        Ok(Ok(_))
    )
}

fn host_and_port(base_url: &str) -> Option<(String, u16)> {
    let rest = base_url
        .strip_prefix("http://")
        .or_else(|| base_url.strip_prefix("https://"))
        .unwrap_or(base_url);
    let authority = rest.split('/').next()?;
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if !host.is_empty() && port.chars().all(|c| c.is_ascii_digit()) => {
            (host, port.parse().ok()?)
        }
        _ => (
            authority,
            if base_url.starts_with("https://") {
                443
            } else {
                80
            },
        ),
    };
    (!host.is_empty()).then(|| (host.to_string(), port))
}

/// Download one document in the requested rendition into `dest_dir`,
/// returning the file written (`<id>.pdf` or `<id>.rmdoc`).
pub async fn download_document_as(
    base_url: &str,
    id: &str,
    kind: DownloadKind,
    dest_dir: &Path,
) -> Result<PathBuf> {
    let response = client(TRANSFER_TIMEOUT)?
        .get(format!("{base_url}/download/{id}/{}", kind.path_segment()))
        .send()
        .await
        .map_err(|error| unreachable(base_url, error))?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(Error::DocumentNotFound {
            host: base_url.to_string(),
            id: id.to_string(),
        });
    }
    if !response.status().is_success() {
        return Err(Error::transport(
            base_url,
            "downloading a document",
            response.status(),
        ));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|error| Error::transport(base_url, "reading the document", error))?;

    std::fs::create_dir_all(dest_dir).map_err(|error| Error::Io {
        path: dest_dir.display().to_string(),
        detail: error.to_string(),
    })?;
    let path = dest_dir.join(format!("{id}.{}", kind.extension()));
    std::fs::write(&path, &bytes).map_err(|error| Error::Io {
        path: path.display().to_string(),
        detail: error.to_string(),
    })?;
    Ok(path)
}

/// Download one document as a PDF with its annotations rendered in.
pub async fn download_document(base_url: &str, id: &str, destination: &Path) -> Result<PathBuf> {
    download_document_as(base_url, id, DownloadKind::Placeholder, destination).await
}

fn mime_for(name: &str) -> &'static str {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".epub") {
        "application/epub+zip"
    } else if lower.ends_with(".rmdoc") {
        "application/octet-stream"
    } else {
        "application/pdf"
    }
}

fn stem(name: &str) -> &str {
    name.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(name)
}

/// The tablet names a plain upload after the file and appends `.pdf` or
/// `.epub` when the name lacks one; an archive upload keeps the archive's
/// own name. Compare names with any such suffix removed.
fn same_document_name(listed: &str, expected: &str) -> bool {
    fn bare(name: &str) -> String {
        let lower = name.trim().to_ascii_lowercase();
        for extension in [".pdf", ".epub", ".rmdoc"] {
            if let Some(cut) = lower.strip_suffix(extension) {
                return cut.to_string();
            }
        }
        lower
    }
    bare(listed) == bare(expected)
}

async fn post_upload(base_url: &str, bytes: Vec<u8>, upload_name: &str) -> Result<()> {
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name(upload_name.to_string())
        .mime_str(mime_for(upload_name))
        .map_err(|error| Error::transport(base_url, "preparing the upload", error))?;
    let response = client(TRANSFER_TIMEOUT)?
        .post(format!("{base_url}/upload"))
        .multipart(reqwest::multipart::Form::new().part("file", part))
        .send()
        .await
        .map_err(|error| unreachable(base_url, error))?;
    if !response.status().is_success() {
        return Err(Error::transport(
            base_url,
            "uploading a document",
            response.status(),
        ));
    }
    Ok(())
}

/// Send a document into one folder and learn the id the tablet gave it.
///
/// Lists the folder (which makes it the server's current folder), posts the
/// file under `upload_name`, then lists again and picks the entry that is
/// new, is a document, and carries the name we sent. The caller must not
/// interleave other requests to the same tablet while this runs.
pub async fn upload_document_into(
    base_url: &str,
    folder_id: Option<&str>,
    file: &Path,
    upload_name: &str,
) -> Result<UploadReceipt> {
    let bytes = std::fs::read(file).map_err(|error| Error::Io {
        path: file.display().to_string(),
        detail: error.to_string(),
    })?;
    let parent = folder_id
        .filter(|id| !id.is_empty() && *id != "root")
        .unwrap_or("")
        .to_string();
    let before: HashSet<String> = list_folder(base_url, folder_id)
        .await?
        .into_iter()
        .map(|document| document.id)
        .collect();

    post_upload(base_url, bytes, upload_name).await?;

    let expected = stem(upload_name).to_string();
    let mut found = find_new_entry(base_url, folder_id, &before, &expected, upload_name).await?;
    if found.is_none() {
        // The tablet indexes an upload a moment after answering 201.
        tokio::time::sleep(Duration::from_millis(1500)).await;
        found = find_new_entry(base_url, folder_id, &before, &expected, upload_name).await?;
    }
    if let Some(document) = &found {
        if document.parent != parent {
            return Err(Error::Misplaced {
                host: base_url.to_string(),
                id: document.id.clone(),
                expected_parent: parent,
                actual_parent: document.parent.clone(),
            });
        }
    }
    Ok(UploadReceipt {
        id: found.map(|document| document.id),
        parent,
        visible_name: expected,
    })
}

async fn find_new_entry(
    base_url: &str,
    folder_id: Option<&str>,
    before: &HashSet<String>,
    expected: &str,
    upload_name: &str,
) -> Result<Option<RemarkableDocument>> {
    let after = list_folder(base_url, folder_id).await?;
    Ok(after
        .into_iter()
        .filter(|document| !before.contains(&document.id))
        .filter(|document| document.kind == DocumentKind::Document)
        .filter(|document| {
            same_document_name(&document.visible_name, expected)
                || same_document_name(&document.visible_name, upload_name)
        })
        .max_by_key(|document| document.last_modified_ms))
}

/// Send a document to the tablet's current folder (the top level unless
/// something listed a folder just before). Prefer [`upload_document_into`].
pub async fn upload_document(base_url: &str, file: &Path) -> Result<()> {
    let bytes = std::fs::read(file).map_err(|error| Error::Io {
        path: file.display().to_string(),
        detail: error.to_string(),
    })?;
    let name = file
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "document.pdf".into());
    post_upload(base_url, bytes, &name).await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The first row is what current firmware sends (both spellings); the
    /// second carries only the typo, the third only the corrected key.
    const LISTING: &str = r#"[
        {"Bookmarked": false, "CurrentPage": 8, "ID": "doc-1",
         "ModifiedClient": "2024-11-14T22:24:07.498Z", "Parent": "",
         "Type": "DocumentType", "VisibleName": "Gaussian splatting",
         "VissibleName": "Gaussian splatting", "fileType": "pdf"},
        {"Bookmarked": true, "CurrentPage": 0, "ID": "fold-1",
         "ModifiedClient": "2025-01-02T10:00:00.000Z", "Parent": "",
         "Type": "CollectionType", "VissibleName": "Papers", "fileType": ""},
        {"Bookmarked": false, "CurrentPage": 0, "ID": "doc-2",
         "ModifiedClient": "2025-01-03T10:00:00.000Z", "Parent": "fold-1",
         "Type": "DocumentType", "VisibleName": "Only new key", "fileType": "epub"}
    ]"#;

    #[test]
    fn the_listing_maps_onto_the_shared_document_type() {
        let entries: Vec<WebEntry> = serde_json::from_str(LISTING).unwrap();
        let documents: Vec<RemarkableDocument> =
            entries.into_iter().map(WebEntry::into_document).collect();

        let document = &documents[0];
        assert_eq!(document.id, "doc-1");
        assert_eq!(
            document.visible_name, "Gaussian splatting",
            "both spellings present"
        );
        assert_eq!(document.kind, DocumentKind::Document);
        assert!(document.is_pdf());
        assert_eq!(document.last_modified_ms, 1_731_623_047_498);

        let folder = &documents[1];
        assert_eq!(folder.kind, DocumentKind::Folder);
        assert_eq!(
            folder.visible_name, "Papers",
            "the typo alone still names it"
        );
        assert!(folder.pinned, "Bookmarked is the tablet's word for pinned");

        assert_eq!(
            documents[2].visible_name, "Only new key",
            "the corrected key alone works too"
        );
        assert_eq!(documents[2].file_type, "epub");
    }

    #[test]
    fn an_unparseable_timestamp_is_zero_rather_than_a_guess() {
        let entries: Vec<WebEntry> =
            serde_json::from_str(r#"[{"ID":"x","ModifiedClient":"not a date"}]"#).unwrap();
        assert_eq!(entries[0].clone().into_document().last_modified_ms, 0);
    }

    #[test]
    fn folder_paths_and_hosts_are_derived_the_way_the_tablet_expects() {
        assert_eq!(documents_path(None), "/documents/");
        assert_eq!(documents_path(Some("")), "/documents/");
        assert_eq!(documents_path(Some("root")), "/documents/");
        assert_eq!(documents_path(Some("abc")), "/documents/abc");
        assert_eq!(
            host_and_port(DEFAULT_BASE_URL),
            Some(("10.11.99.1".into(), 80))
        );
        assert_eq!(
            host_and_port("http://127.0.0.1:8123/"),
            Some(("127.0.0.1".into(), 8123))
        );
        assert_eq!(
            host_and_port("https://tablet.local"),
            Some(("tablet.local".into(), 443))
        );
        assert_eq!(host_and_port("http://"), None);
    }

    #[test]
    fn listed_names_match_with_or_without_the_tablets_suffix() {
        assert!(same_document_name(
            "Abel 2002 – First star.pdf",
            "Abel 2002 – First star"
        ));
        assert!(same_document_name(
            "Abel 2002 – First star",
            "Abel 2002 – First star.pdf"
        ));
        assert!(same_document_name("Book.EPUB", "Book"));
        assert!(!same_document_name(
            "Abel 2002 – First star [x].pdf",
            "Abel 2002 – First star"
        ));
    }

    #[test]
    fn upload_mime_follows_the_extension() {
        assert_eq!(mime_for("paper.pdf"), "application/pdf");
        assert_eq!(mime_for("Book.EPUB"), "application/epub+zip");
        assert_eq!(mime_for("folder.rmdoc"), "application/octet-stream");
        assert_eq!(stem("Abel 2002 – First star.pdf"), "Abel 2002 – First star");
        assert_eq!(stem("noext"), "noext");
    }
}
