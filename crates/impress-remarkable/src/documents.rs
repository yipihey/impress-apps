//! The tablet's on-disk document model.
//!
//! xochitl keeps every document as a set of sibling files named by one uuid:
//! `<id>.metadata` (name, parent, deletion), `<id>.content` (file type and
//! page count), `<id>.pdf` or `<id>.epub` for an imported document, and a
//! `<id>/` directory holding one `.rm` stroke file per annotated page. There
//! is no database, which is what makes a plain file transport sufficient.

use serde::{Deserialize, Serialize};

/// Whether an entry is a document or one of the tablet's folders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DocumentKind {
    Document,
    Folder,
    Unknown,
}

impl DocumentKind {
    fn from_type(value: &str) -> Self {
        match value {
            "DocumentType" => Self::Document,
            "CollectionType" => Self::Folder,
            _ => Self::Unknown,
        }
    }
}

/// `<id>.metadata` as xochitl writes it.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct XochitlMetadata {
    #[serde(default)]
    pub deleted: bool,
    /// Milliseconds since the epoch, written as a string.
    #[serde(default)]
    pub last_modified: String,
    #[serde(default)]
    pub parent: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub visible_name: String,
}

/// The fields of `<id>.content` this crate uses.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct XochitlContent {
    #[serde(default)]
    pub file_type: String,
    #[serde(default)]
    pub page_count: u32,
}

/// One entry as a caller sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemarkableDocument {
    pub id: String,
    pub visible_name: String,
    pub kind: DocumentKind,
    /// Parent folder id; empty at the top level.
    pub parent: String,
    /// Milliseconds since the epoch, 0 when the tablet wrote nothing usable.
    pub last_modified_ms: i64,
    pub pinned: bool,
    /// `pdf`, `epub`, or empty for a notebook the tablet created itself.
    pub file_type: String,
    pub page_count: u32,
    /// Whether a `<id>/` directory of `.rm` stroke files exists.
    pub has_annotations: bool,
}

impl RemarkableDocument {
    /// Build an entry from the two JSON files, tolerating a missing or
    /// unparseable `.content` — a document with no content file is still a
    /// document, and refusing to list it would hide it from the researcher.
    pub fn from_files(
        id: &str,
        metadata: &XochitlMetadata,
        content: Option<&XochitlContent>,
        has_annotations: bool,
    ) -> Self {
        Self {
            id: id.to_string(),
            visible_name: metadata.visible_name.clone(),
            kind: DocumentKind::from_type(&metadata.kind),
            parent: metadata.parent.clone(),
            last_modified_ms: metadata.last_modified.parse().unwrap_or(0),
            pinned: metadata.pinned,
            file_type: content.map(|c| c.file_type.clone()).unwrap_or_default(),
            page_count: content.map(|c| c.page_count).unwrap_or(0),
            has_annotations,
        }
    }

    /// Whether this is a PDF the researcher imported (as opposed to a
    /// notebook the tablet created), which is what imbib syncs.
    pub fn is_pdf(&self) -> bool {
        self.file_type.eq_ignore_ascii_case("pdf")
    }
}

/// Parse `<id>.metadata`; a document the tablet has deleted returns `None`,
/// so a caller never lists something the researcher put in the bin.
pub fn parse_metadata(bytes: &[u8]) -> Option<XochitlMetadata> {
    let metadata: XochitlMetadata = serde_json::from_slice(bytes).ok()?;
    if metadata.deleted {
        return None;
    }
    Some(metadata)
}

/// Parse `<id>.content`, tolerating anything unexpected.
pub fn parse_content(bytes: &[u8]) -> Option<XochitlContent> {
    serde_json::from_slice(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const METADATA: &[u8] = br#"{
        "deleted": false,
        "lastModified": "1757000000000",
        "parent": "",
        "pinned": true,
        "type": "DocumentType",
        "visibleName": "Cosmological simulations"
    }"#;

    #[test]
    fn a_document_is_built_from_both_files() {
        let metadata = parse_metadata(METADATA).unwrap();
        let content = parse_content(br#"{"fileType":"pdf","pageCount":24}"#).unwrap();
        let document = RemarkableDocument::from_files("abc", &metadata, Some(&content), true);

        assert_eq!(document.visible_name, "Cosmological simulations");
        assert_eq!(document.kind, DocumentKind::Document);
        assert_eq!(document.last_modified_ms, 1_757_000_000_000);
        assert_eq!(document.page_count, 24);
        assert!(document.is_pdf());
        assert!(document.has_annotations);
        assert!(document.pinned);
    }

    #[test]
    fn a_deleted_document_is_not_listed() {
        assert!(parse_metadata(br#"{"deleted":true,"visibleName":"Gone"}"#).is_none());
    }

    #[test]
    fn a_missing_content_file_still_yields_a_document() {
        let metadata = parse_metadata(METADATA).unwrap();
        let document = RemarkableDocument::from_files("abc", &metadata, None, false);
        assert_eq!(document.page_count, 0);
        assert!(
            !document.is_pdf(),
            "an unknown file type is not claimed to be a PDF"
        );
        assert_eq!(document.visible_name, "Cosmological simulations");
    }

    #[test]
    fn a_folder_is_distinguished_from_a_document() {
        let metadata =
            parse_metadata(br#"{"type":"CollectionType","visibleName":"Papers"}"#).unwrap();
        let folder = RemarkableDocument::from_files("f1", &metadata, None, false);
        assert_eq!(folder.kind, DocumentKind::Folder);
        assert_eq!(
            folder.last_modified_ms, 0,
            "a tablet that wrote no stamp is not guessed at"
        );
    }
}
