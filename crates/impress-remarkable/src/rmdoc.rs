//! The `.rmdoc` archive: what `GET /download/{id}/rmdoc` hands back and what
//! the tablet accepts on upload.
//!
//! It is a zip of the document's on-disk files, named by one uuid:
//! `<id>.metadata`, `<id>.content`, the imported `<id>.pdf` or `<id>.epub`,
//! and `<id>/<page>.rm` — one stroke file per page — with a sibling
//! `<page>-metadata.json` describing layers. Everything this module does not
//! recognise is listed in [`RmDocumentArchive::other_entries`] rather than
//! rejected, because firmware adds files without notice.
//!
//! Two callers: the annotation import reads archives; the mirror engine
//! builds them, because uploading an archive is the only way the USB web
//! interface lets a client choose a document's id and parent (there is no
//! folder-creation endpoint).

use std::io::{Cursor, Read, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::documents::XochitlMetadata;
use crate::error::{Error, Result};

/// A value the tablet stores with a CRDT timestamp (`{"timestamp":"1:2","value":…}`).
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct CrdtValue<T> {
    #[serde(default)]
    pub timestamp: String,
    pub value: T,
}

/// One page in the firmware-3 `cPages` list.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CPage {
    pub id: String,
    #[serde(default)]
    pub idx: Option<CrdtValue<String>>,
    /// The 0-based page of the source PDF this page shows; absent or
    /// negative for a page the user inserted.
    #[serde(default)]
    pub redir: Option<CrdtValue<i64>>,
    #[serde(default)]
    pub template: Option<CrdtValue<String>>,
    #[serde(default)]
    pub deleted: Option<CrdtValue<i64>>,
}

impl CPage {
    pub fn is_deleted(&self) -> bool {
        self.deleted.as_ref().is_some_and(|flag| flag.value != 0)
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CPages {
    #[serde(default)]
    pub pages: Vec<CPage>,
    #[serde(default)]
    pub last_opened: Option<CrdtValue<String>>,
}

/// `<id>.content` with the fields an import needs: the page list (either
/// spelling), the source-page redirection, and the zoom the reader used,
/// which decides how stroke coordinates map onto PDF points.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RmContent {
    #[serde(default)]
    pub file_type: String,
    #[serde(default)]
    pub page_count: u32,
    /// Firmware-2 page list.
    #[serde(default)]
    pub pages: Vec<String>,
    /// Firmware-3 page list, with per-page redirection into the source.
    #[serde(default)]
    pub c_pages: Option<CPages>,
    /// Firmware-2 companion of `pages`: source page per entry, -1 = inserted.
    #[serde(default)]
    pub redirection_page_map: Vec<i64>,
    #[serde(default)]
    pub orientation: String,
    #[serde(default)]
    pub zoom_mode: String,
    #[serde(default)]
    pub custom_zoom_scale: f64,
    #[serde(default)]
    pub custom_zoom_center_x: f64,
    #[serde(default)]
    pub custom_zoom_center_y: f64,
    #[serde(default)]
    pub custom_zoom_page_width: f64,
    #[serde(default)]
    pub custom_zoom_page_height: f64,
}

impl RmContent {
    /// Page ids in reading order with their source-page redirection,
    /// whichever firmware wrote the file. Deleted pages are skipped.
    pub fn page_order(&self) -> Vec<(String, Option<u32>)> {
        if let Some(c_pages) = &self.c_pages {
            if !c_pages.pages.is_empty() {
                return c_pages
                    .pages
                    .iter()
                    .filter(|page| !page.is_deleted())
                    .map(|page| {
                        let redirect = page
                            .redir
                            .as_ref()
                            .map(|redir| redir.value)
                            .filter(|value| *value >= 0)
                            .map(|value| value as u32);
                        (page.id.clone(), redirect)
                    })
                    .collect();
            }
        }
        self.pages
            .iter()
            .enumerate()
            .map(|(index, id)| {
                let redirect = self
                    .redirection_page_map
                    .get(index)
                    .copied()
                    .filter(|value| *value >= 0)
                    .map(|value| value as u32);
                (id.clone(), redirect)
            })
            .collect()
    }
}

/// The imported file the document was made from, if any.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SourceKind {
    Pdf,
    Epub,
}

impl SourceKind {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Pdf => "pdf",
            Self::Epub => "epub",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceDocument {
    pub kind: SourceKind,
    pub bytes: Vec<u8>,
}

/// One page as the archive holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RmPage {
    /// Position in reading order.
    pub index: usize,
    pub page_id: String,
    /// The `.rm` stroke file; `None` for a page never written on.
    pub rm_bytes: Option<Vec<u8>>,
    /// The 0-based page of the source PDF this page annotates.
    pub redirect_pdf_index: Option<u32>,
    /// `<page>-metadata.json`, verbatim.
    pub layers_json: Option<String>,
}

/// A parsed archive.
#[derive(Debug, Clone)]
pub struct RmDocumentArchive {
    pub id: String,
    pub metadata: XochitlMetadata,
    pub content: RmContent,
    pub pages: Vec<RmPage>,
    pub source: Option<SourceDocument>,
    /// Entry names this module did not interpret.
    pub other_entries: Vec<String>,
}

fn archive_error(detail: impl std::fmt::Display) -> Error {
    Error::Archive {
        detail: detail.to_string(),
    }
}

/// Parse an archive from its bytes.
pub fn parse_rmdoc(bytes: &[u8]) -> Result<RmDocumentArchive> {
    let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).map_err(archive_error)?;

    // Read everything once; archives are a few MB at most.
    let mut entries: Vec<(String, Vec<u8>)> = Vec::with_capacity(zip.len());
    for index in 0..zip.len() {
        let mut file = zip.by_index(index).map_err(archive_error)?;
        if file.is_dir() {
            continue;
        }
        let mut data = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut data).map_err(archive_error)?;
        entries.push((file.name().to_string(), data));
    }

    // The metadata file names the document; its directory (if any) is the
    // prefix every other entry hangs under.
    let metadata_name = entries
        .iter()
        .map(|(name, _)| name.as_str())
        .find(|name| name.ends_with(".metadata"))
        .ok_or_else(|| archive_error("no <id>.metadata entry"))?
        .to_string();
    let (prefix, metadata_base) = match metadata_name.rsplit_once('/') {
        Some((dir, base)) => (format!("{dir}/"), base.to_string()),
        None => (String::new(), metadata_name.clone()),
    };
    let id = metadata_base
        .strip_suffix(".metadata")
        .unwrap_or(&metadata_base)
        .to_string();

    let mut metadata: Option<XochitlMetadata> = None;
    let mut content = RmContent::default();
    let mut source: Option<SourceDocument> = None;
    let mut rm_files: Vec<(String, Vec<u8>)> = Vec::new();
    let mut layer_files: Vec<(String, String)> = Vec::new();
    let mut other_entries = Vec::new();

    for (name, data) in entries {
        let Some(relative) = name.strip_prefix(&prefix) else {
            other_entries.push(name);
            continue;
        };
        if relative == format!("{id}.metadata") {
            metadata = Some(
                serde_json::from_slice(&data).map_err(|error| Error::Format {
                    path: name.clone(),
                    detail: error.to_string(),
                })?,
            );
        } else if relative == format!("{id}.content") {
            content = serde_json::from_slice(&data).map_err(|error| Error::Format {
                path: name.clone(),
                detail: error.to_string(),
            })?;
        } else if relative == format!("{id}.pdf") {
            source = Some(SourceDocument {
                kind: SourceKind::Pdf,
                bytes: data,
            });
        } else if relative == format!("{id}.epub") {
            source = Some(SourceDocument {
                kind: SourceKind::Epub,
                bytes: data,
            });
        } else if let Some(page_file) = relative.strip_prefix(&format!("{id}/")) {
            if let Some(page_id) = page_file.strip_suffix(".rm") {
                rm_files.push((page_id.to_string(), data));
            } else if let Some(page_id) = page_file.strip_suffix("-metadata.json") {
                layer_files.push((
                    page_id.to_string(),
                    String::from_utf8_lossy(&data).into_owned(),
                ));
            } else {
                other_entries.push(name);
            }
        } else {
            other_entries.push(name);
        }
    }

    let metadata = metadata.ok_or_else(|| archive_error("metadata entry unreadable"))?;

    let mut order = content.page_order();
    if order.is_empty() {
        // No page list at all: fall back to the stroke files, sorted, so a
        // notebook without a content file still yields its pages.
        let mut ids: Vec<String> = rm_files.iter().map(|(id, _)| id.clone()).collect();
        ids.sort();
        order = ids.into_iter().map(|id| (id, None)).collect();
    }

    let pages = order
        .into_iter()
        .enumerate()
        .map(|(index, (page_id, redirect))| RmPage {
            rm_bytes: rm_files
                .iter()
                .find(|(id, _)| *id == page_id)
                .map(|(_, data)| data.clone()),
            layers_json: layer_files
                .iter()
                .find(|(id, _)| *id == page_id)
                .map(|(_, json)| json.clone()),
            redirect_pdf_index: redirect,
            index,
            page_id,
        })
        .collect();

    Ok(RmDocumentArchive {
        id,
        metadata,
        content,
        pages,
        source,
        other_entries,
    })
}

/// Parse an archive on disk.
pub fn read_rmdoc(path: &Path) -> Result<RmDocumentArchive> {
    let bytes = std::fs::read(path).map_err(|error| Error::Io {
        path: path.display().to_string(),
        detail: error.to_string(),
    })?;
    parse_rmdoc(&bytes)
}

/// What to build an archive for.
#[derive(Debug, Clone)]
pub enum RmdocKind {
    /// A folder: metadata only, an empty content file.
    Folder,
    /// A document wrapping an imported file.
    Document { kind: SourceKind, source: Vec<u8> },
}

/// The identity a built archive carries. Choosing `id` and `parent` here is
/// what makes an upload land deterministically — if the firmware honours
/// them, which the P0 spike establishes.
#[derive(Debug, Clone)]
pub struct RmdocSpec {
    pub id: String,
    pub visible_name: String,
    /// Parent folder id; empty for the top level.
    pub parent: String,
    pub last_modified_ms: i64,
    pub kind: RmdocKind,
    /// Page count of the source, when the caller knows it.
    pub page_count: Option<u32>,
    /// Stroke files to pack as `<id>/<page>.rm` (tests, re-exports); when
    /// non-empty these page ids replace the generated ones.
    pub page_files: Vec<(String, Vec<u8>)>,
}

/// Build an archive the tablet can import.
pub fn build_rmdoc(spec: &RmdocSpec) -> Result<Vec<u8>> {
    let is_folder = matches!(spec.kind, RmdocKind::Folder);
    let metadata = serde_json::json!({
        "createdTime": spec.last_modified_ms.to_string(),
        "deleted": false,
        "lastModified": spec.last_modified_ms.to_string(),
        "lastOpened": "",
        "lastOpenedPage": 0,
        "metadatamodified": false,
        "modified": false,
        "parent": spec.parent,
        "pinned": false,
        "synced": false,
        "type": if is_folder { "CollectionType" } else { "DocumentType" },
        "visibleName": spec.visible_name,
    });
    let content = match &spec.kind {
        RmdocKind::Folder => serde_json::json!({ "tags": [] }),
        RmdocKind::Document { kind, source } => {
            let page_count = if spec.page_files.is_empty() {
                spec.page_count.unwrap_or(0)
            } else {
                spec.page_files.len() as u32
            };
            let pages: Vec<String> = if spec.page_files.is_empty() {
                (0..page_count)
                    .map(|_| uuid::Uuid::new_v4().to_string())
                    .collect()
            } else {
                spec.page_files.iter().map(|(id, _)| id.clone()).collect()
            };
            let redirection: Vec<u32> = (0..page_count).collect();
            // The shape current firmware writes for an imported PDF
            // (captured from a Paper Pro; see tests/fixtures/content).
            serde_json::json!({
                "coverPageNumber": 0,
                "customZoomCenterX": 0,
                "customZoomCenterY": 936,
                "customZoomOrientation": "portrait",
                "customZoomPageHeight": 1872,
                "customZoomPageWidth": 1404,
                "customZoomScale": 1,
                "documentMetadata": {},
                "dummyDocument": false,
                "extraMetadata": {},
                "fileType": kind.extension(),
                "fontName": "",
                "formatVersion": 1,
                "lineHeight": -1,
                "margins": 125,
                "orientation": "portrait",
                "originalPageCount": page_count,
                "pageCount": page_count,
                "pageTags": [],
                "pages": pages,
                "redirectionPageMap": redirection,
                "sizeInBytes": source.len().to_string(),
                "tags": [],
                "textAlignment": "justify",
                "textScale": 1,
                "zoomMode": "bestFit",
            })
        }
    };

    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        let mut put = |name: String, data: &[u8]| -> Result<()> {
            writer
                .start_file(name, options)
                .and_then(|_| writer.write_all(data).map_err(zip::result::ZipError::Io))
                .map_err(archive_error)
        };
        put(
            format!("{}.metadata", spec.id),
            serde_json::to_string_pretty(&metadata)
                .map_err(archive_error)?
                .as_bytes(),
        )?;
        put(
            format!("{}.content", spec.id),
            serde_json::to_string_pretty(&content)
                .map_err(archive_error)?
                .as_bytes(),
        )?;
        if let RmdocKind::Document { kind, source } = &spec.kind {
            put(format!("{}.{}", spec.id, kind.extension()), source)?;
        }
        for (page_id, bytes) in &spec.page_files {
            put(format!("{}/{page_id}.rm", spec.id), bytes)?;
        }
        writer.finish().map_err(archive_error)?;
    }
    Ok(buffer.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn firmware_3_page_order_follows_cpages_and_skips_deleted() {
        let content: RmContent = serde_json::from_str(
            r#"{"fileType":"pdf","cPages":{"pages":[
                {"id":"p1","idx":{"timestamp":"1:2","value":"ba"},"redir":{"timestamp":"1:2","value":0}},
                {"id":"gone","idx":{"timestamp":"1:3","value":"bb"},"deleted":{"timestamp":"1:4","value":1}},
                {"id":"p2","idx":{"timestamp":"1:5","value":"bc"},"redir":{"timestamp":"1:5","value":-1}}
            ]},"pageCount":2,"zoomMode":"bestFit"}"#,
        )
        .unwrap();
        assert_eq!(
            content.page_order(),
            vec![("p1".to_string(), Some(0)), ("p2".to_string(), None)]
        );
        assert_eq!(content.zoom_mode, "bestFit");
    }

    #[test]
    fn firmware_2_page_order_uses_the_redirection_map() {
        let content: RmContent = serde_json::from_str(
            r#"{"fileType":"pdf","pages":["a","b"],"redirectionPageMap":[0,-1]}"#,
        )
        .unwrap();
        assert_eq!(
            content.page_order(),
            vec![("a".to_string(), Some(0)), ("b".to_string(), None)]
        );
    }

    #[test]
    fn a_built_document_archive_round_trips() {
        let spec = RmdocSpec {
            id: "11111111-2222-3333-4444-555555555555".into(),
            visible_name: "Spike".into(),
            parent: "folder-1".into(),
            last_modified_ms: 1_757_000_000_000,
            kind: RmdocKind::Document {
                kind: SourceKind::Pdf,
                source: b"%PDF-1.4\n%%EOF\n".to_vec(),
            },
            page_count: Some(2),
            page_files: Vec::new(),
        };
        let bytes = build_rmdoc(&spec).unwrap();
        let archive = parse_rmdoc(&bytes).unwrap();
        assert_eq!(archive.id, spec.id);
        assert_eq!(archive.metadata.visible_name, "Spike");
        assert_eq!(archive.metadata.parent, "folder-1");
        assert_eq!(archive.metadata.kind, "DocumentType");
        assert_eq!(archive.content.file_type, "pdf");
        assert_eq!(
            archive.source.as_ref().map(|s| s.kind),
            Some(SourceKind::Pdf)
        );
        assert_eq!(archive.pages.len(), 2, "pages come from the content file");
        assert_eq!(archive.pages[1].redirect_pdf_index, Some(1));
        assert!(
            archive.pages[0].rm_bytes.is_none(),
            "no stroke files were packed"
        );
        assert!(archive.other_entries.is_empty());
    }

    #[test]
    fn a_built_folder_archive_is_a_collection() {
        let spec = RmdocSpec {
            id: "f".into(),
            visible_name: "imbib".into(),
            parent: String::new(),
            last_modified_ms: 1,
            kind: RmdocKind::Folder,
            page_count: None,
            page_files: Vec::new(),
        };
        let archive = parse_rmdoc(&build_rmdoc(&spec).unwrap()).unwrap();
        assert_eq!(archive.metadata.kind, "CollectionType");
        assert!(archive.source.is_none());
    }

    #[test]
    fn stroke_files_are_attached_to_their_pages() {
        // Hand-build an archive with one written page and one layers file.
        let mut buffer = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            let options = zip::write::SimpleFileOptions::default();
            writer.start_file("doc.metadata", options).unwrap();
            writer
                .write_all(br#"{"type":"DocumentType","visibleName":"N","parent":""}"#)
                .unwrap();
            writer.start_file("doc.content", options).unwrap();
            writer
                .write_all(
                    br#"{"fileType":"notebook","cPages":{"pages":[{"id":"pg1"},{"id":"pg2"}]}}"#,
                )
                .unwrap();
            writer.start_file("doc/pg1.rm", options).unwrap();
            writer
                .write_all(b"reMarkable .lines file, version=6")
                .unwrap();
            writer.start_file("doc/pg1-metadata.json", options).unwrap();
            writer
                .write_all(br#"{"layers":[{"name":"Layer 1"}]}"#)
                .unwrap();
            writer.start_file("doc.pagedata", options).unwrap();
            writer.write_all(b"Blank\nBlank\n").unwrap();
            writer.finish().unwrap();
        }
        let archive = parse_rmdoc(&buffer.into_inner()).unwrap();
        assert_eq!(archive.pages.len(), 2);
        assert!(archive.pages[0].rm_bytes.is_some());
        assert!(archive.pages[0].layers_json.is_some());
        assert!(
            archive.pages[1].rm_bytes.is_none(),
            "an unwritten page has no .rm"
        );
        assert_eq!(archive.other_entries, vec!["doc.pagedata".to_string()]);
    }

    #[test]
    fn a_zip_without_metadata_is_refused() {
        let mut buffer = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            writer
                .start_file("readme.txt", zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(b"hi").unwrap();
            writer.finish().unwrap();
        }
        assert!(matches!(
            parse_rmdoc(&buffer.into_inner()),
            Err(Error::Archive { .. })
        ));
        assert!(matches!(
            parse_rmdoc(b"not a zip"),
            Err(Error::Archive { .. })
        ));
    }
}
