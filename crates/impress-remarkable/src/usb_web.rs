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
//! Three endpoints, learned from the interface's own client bundle:
//!
//! * `GET /documents/` — the top level; `GET /documents/{folder}` descends.
//! * `GET /download/{id}/placeholder` — the document as a PDF **with the
//!   handwritten annotations rendered into it**, which is what imbib wants.
//! * `POST /upload` — multipart, field `file`.

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

/// One row of `GET /documents/`.
#[derive(Debug, Clone, Deserialize)]
struct WebEntry {
    #[serde(rename = "ID")]
    id: String,
    #[serde(rename = "VisibleName", default)]
    visible_name: String,
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
            visible_name: self.visible_name,
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

/// Every entry the tablet lists, documents and folders, newest first.
pub async fn list_documents(base_url: &str) -> Result<Vec<RemarkableDocument>> {
    let response = client(LIST_TIMEOUT)?
        .get(format!("{base_url}/documents/"))
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

/// Whether the interface is up, and how much it holds.
pub async fn probe(base_url: &str) -> Result<u32> {
    Ok(list_documents(base_url).await?.len() as u32)
}

/// Download one document as a PDF with its annotations rendered in.
pub async fn download_document(base_url: &str, id: &str, destination: &Path) -> Result<PathBuf> {
    let response = client(TRANSFER_TIMEOUT)?
        .get(format!("{base_url}/download/{id}/placeholder"))
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

    std::fs::create_dir_all(destination).map_err(|error| Error::Io {
        path: destination.display().to_string(),
        detail: error.to_string(),
    })?;
    let path = destination.join(format!("{id}.pdf"));
    std::fs::write(&path, &bytes).map_err(|error| Error::Io {
        path: path.display().to_string(),
        detail: error.to_string(),
    })?;
    Ok(path)
}

/// Send a document to the tablet.
pub async fn upload_document(base_url: &str, file: &Path) -> Result<()> {
    let bytes = std::fs::read(file).map_err(|error| Error::Io {
        path: file.display().to_string(),
        detail: error.to_string(),
    })?;
    let name = file
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "document.pdf".into());
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name(name)
        .mime_str("application/pdf")
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

#[cfg(test)]
mod tests {
    use super::*;

    const LISTING: &str = r#"[
        {"Bookmarked": false, "CurrentPage": 8, "ID": "doc-1",
         "ModifiedClient": "2024-11-14T22:24:07.498Z", "Parent": "",
         "Type": "DocumentType", "VisibleName": "Gaussian splatting.pdf", "fileType": "pdf"},
        {"Bookmarked": true, "CurrentPage": 0, "ID": "fold-1",
         "ModifiedClient": "2025-01-02T10:00:00.000Z", "Parent": "",
         "Type": "CollectionType", "VisibleName": "Papers", "fileType": ""}
    ]"#;

    #[test]
    fn the_listing_maps_onto_the_shared_document_type() {
        let entries: Vec<WebEntry> = serde_json::from_str(LISTING).unwrap();
        let documents: Vec<RemarkableDocument> =
            entries.into_iter().map(WebEntry::into_document).collect();

        let document = &documents[0];
        assert_eq!(document.id, "doc-1");
        assert_eq!(document.visible_name, "Gaussian splatting.pdf");
        assert_eq!(document.kind, DocumentKind::Document);
        assert!(document.is_pdf());
        assert_eq!(document.last_modified_ms, 1_731_623_047_498);

        let folder = &documents[1];
        assert_eq!(folder.kind, DocumentKind::Folder);
        assert!(folder.pinned, "Bookmarked is the tablet's word for pinned");
    }

    #[test]
    fn an_unparseable_timestamp_is_zero_rather_than_a_guess() {
        let entries: Vec<WebEntry> =
            serde_json::from_str(r#"[{"ID":"x","ModifiedClient":"not a date"}]"#).unwrap();
        assert_eq!(entries[0].clone().into_document().last_modified_ms, 0);
    }
}
