//! What comes back from the tablet: the rendition with the handwriting
//! drawn in (a second linked file), and — from the raw archive — the
//! highlights, typed text and ink groups as `imbib/annotation` rows on the
//! primary file, keyed so a re-import updates rather than duplicates.

pub mod convert;
pub mod documents;
pub mod geometry;
pub mod ink_render;
pub mod notes_merge;
pub mod reconcile;
pub mod store_ops;
pub mod variant;

use std::path::Path;

use impress_remarkable::rm::parse_rm;
use impress_remarkable::rmdoc::{read_rmdoc, RmDocumentArchive};

use super::apply::{EinkImportSink, ImportHandoff, ImportOutcome};
use super::config::EinkDeviceConfig;
use super::transport::EinkError;
use crate::unified::store_api::ImbibStore;
use convert::{AnnotationDraft, ConvertOptions};
use geometry::{PageFrame, SceneToPdf};

pub use documents::{EinkDocumentImportOutcome, EinkUnmatchedDocument, ImportDocumentRequest};
pub use store_ops::EinkOcrJob;

/// Everything one import needs.
pub struct ImportRequest<'a> {
    pub device: &'a EinkDeviceConfig,
    pub mirror_id: &'a str,
    pub publication_id: &'a str,
    pub library_dir: &'a Path,
    /// The primary file's id and filename; rows attach to it.
    pub primary_file: Option<(String, String)>,
    pub remote_id: &'a str,
    pub remote_name: &'a str,
    pub remote_modified_ms: i64,
    pub rendered_pdf: &'a Path,
    pub rmdoc: Option<&'a Path>,
}

/// The size of a PDF page in points, from the first `/MediaBox` in the
/// file (every page of a paper shares it); US Letter when none is found.
pub fn pdf_page_size(bytes: &[u8]) -> (f64, f64) {
    let text = String::from_utf8_lossy(&bytes[..bytes.len().min(2_000_000)]);
    if let Some(start) = text.find("/MediaBox") {
        let rest = &text[start + 9..];
        if let (Some(open), Some(close)) = (rest.find('['), rest.find(']')) {
            let numbers: Vec<f64> = rest[open + 1..close]
                .split_whitespace()
                .filter_map(|n| n.parse().ok())
                .collect();
            if numbers.len() == 4 {
                let width = (numbers[2] - numbers[0]).abs();
                let height = (numbers[3] - numbers[1]).abs();
                if width > 10.0 && height > 10.0 {
                    return (width, height);
                }
            }
        }
    }
    (612.0, 792.0)
}

/// Every page of an archive as annotation drafts, under the device's
/// import switches. A page with a PDF behind it is mapped with the
/// `bestFit` frame; a notebook page with the screen frame. Parse failures
/// become warnings, never errors — one bad page must not lose the rest.
pub fn convert_archive(
    archive: &RmDocumentArchive,
    device: &EinkDeviceConfig,
    remote_id: &str,
    rendered_pdf: &Path,
    warnings: &mut Vec<String>,
) -> Vec<AnnotationDraft> {
    let (pdf_w, pdf_h) = match &archive.source {
        Some(source) => pdf_page_size(&source.bytes),
        None => {
            let rendered = std::fs::read(rendered_pdf).unwrap_or_default();
            pdf_page_size(&rendered)
        }
    };
    let options = ConvertOptions {
        highlights: device.import_highlights,
        ink: device.import_ink,
        typed_text: device.import_typed_text,
        render_ink: device.import_ink,
    };
    let mut drafts = Vec::new();
    for page in &archive.pages {
        let Some(bytes) = &page.rm_bytes else {
            continue;
        };
        let scene = match parse_rm(bytes) {
            Ok(scene) => scene,
            Err(error) => {
                warnings.push(format!("page {} ({}): {error}", page.index, page.page_id));
                continue;
            }
        };
        if scene.is_empty() {
            continue;
        }
        let page_number = page
            .redirect_pdf_index
            .map(i64::from)
            .unwrap_or(page.index as i64);
        let frame = if archive.source.is_some() {
            PageFrame::best_fit(pdf_w, pdf_h, scene.version >= 6)
        } else {
            PageFrame::notebook(pdf_w, pdf_h, scene.version >= 6)
        };
        let map = SceneToPdf::fit(frame);
        warnings.extend(scene.warnings.iter().cloned());
        drafts.extend(convert::convert_page(
            remote_id,
            &page.page_id,
            page_number,
            &scene,
            Some(&map),
            &options,
        ));
    }
    fill_highlight_text(archive, &mut drafts, warnings);
    drafts
}

/// A free-hand highlighter stroke carries a rectangle and no text; when
/// the archive holds the source PDF and pdfium is at hand, the characters
/// under the rectangle become the highlight's text. Text-snapping
/// highlights (`GlyphRange`) already carry theirs and are left alone.
pub fn fill_highlight_text(
    archive: &RmDocumentArchive,
    drafts: &mut [AnnotationDraft],
    warnings: &mut Vec<String>,
) {
    let Some(source) = archive.source.as_ref() else {
        return;
    };
    if source.kind != impress_remarkable::rmdoc::SourceKind::Pdf {
        return;
    }
    let wanted: Vec<usize> = drafts
        .iter()
        .enumerate()
        .filter(|(_, d)| {
            d.annotation_type == "highlight" && d.selected_text.is_none() && d.bounds.is_some()
        })
        .map(|(i, _)| i)
        .collect();
    if wanted.is_empty() {
        return;
    }
    let mut pages: std::collections::HashMap<i64, Option<Vec<crate::pdf::extract::CharBox>>> =
        std::collections::HashMap::new();
    let mut filled = 0;
    for index in wanted {
        let page = drafts[index].page_number;
        let boxes =
            pages.entry(page).or_insert_with(|| {
                match crate::pdf::extract::page_char_boxes(&source.bytes, page.max(0) as u32) {
                    Ok(boxes) => Some(boxes),
                    Err(crate::pdf::extract::PdfError::PdfiumNotAvailable) => None,
                    Err(error) => {
                        warnings.push(format!("page {page}: no character boxes ({error})"));
                        None
                    }
                }
            });
        let Some(boxes) = boxes else {
            continue;
        };
        let rect = drafts[index].bounds.expect("filtered on bounds");
        let text =
            crate::pdf::extract::text_in_rect(boxes, rect.x, rect.y, rect.width, rect.height);
        if !text.is_empty() {
            drafts[index].selected_text = Some(text);
            filled += 1;
        }
    }
    if filled > 0 {
        warnings.push(format!(
            "{filled} highlighter stroke(s) got their text from the page"
        ));
    }
}

/// Run one import: the rendition first (always — as a second linked file,
/// or in place when the primary file *is* the tablet's rendition), then
/// the structured rows when an archive is at hand and the device asks for
/// them.
pub fn import_annotated_document(
    store: &ImbibStore,
    req: &ImportRequest<'_>,
) -> Result<ImportOutcome, EinkError> {
    let mut outcome = ImportOutcome::default();
    let primary_filename = req
        .primary_file
        .as_ref()
        .map(|(_, name)| name.clone())
        .unwrap_or_else(|| format!("{}.pdf", req.remote_name));
    // A primary file that came from this very document on the tablet (a
    // notebook imported as a publication) is refreshed rather than
    // shadowed by a variant.
    let primary_is_render = match &req.primary_file {
        Some((id, _)) => store
            .get_linked_file(id.clone())?
            .map(|row| row.source_remote_id.as_deref() == Some(req.remote_id))
            .unwrap_or(false),
        None => false,
    };
    let mut rows_file: Option<String> = req.primary_file.as_ref().map(|(id, _)| id.clone());
    if primary_is_render {
        let (id, _) = req.primary_file.as_ref().expect("checked above");
        let (sha, _) =
            variant::refresh_primary_render(store, id, req.rendered_pdf, req.remote_modified_ms)?;
        outcome.primary_sha256 = Some(sha);
    } else {
        let variant = variant::upsert_annotated_variant(
            store,
            req.publication_id,
            req.library_dir,
            &primary_filename,
            req.rendered_pdf,
            &req.device.id,
            req.remote_id,
            req.remote_modified_ms,
        )?;
        outcome.annotated_file_id = Some(variant.linked_file_id.clone());
        rows_file.get_or_insert(variant.linked_file_id);
    }

    let Some(rmdoc_path) = req.rmdoc else {
        return Ok(outcome);
    };
    if !req.device.import_rmdoc {
        return Ok(outcome);
    }
    let archive = read_rmdoc(rmdoc_path)?;
    let drafts = convert_archive(
        &archive,
        req.device,
        req.remote_id,
        req.rendered_pdf,
        &mut outcome.warnings,
    );
    let target_file = rows_file.expect("a file to attach rows to");
    let reconciled = reconcile::reconcile(
        store,
        &target_file,
        &req.device.id,
        req.remote_id,
        req.library_dir,
        drafts,
    )?;
    outcome.created = reconciled.created;
    outcome.updated = reconciled.updated;
    outcome.deleted = reconciled.deleted;
    outcome.ink_pending_ocr = reconciled.ink_pending_ocr;
    Ok(outcome)
}

/// The sink the engine uses by default.
pub struct StoreImportSink;

impl EinkImportSink for StoreImportSink {
    fn ingest(
        &self,
        store: &ImbibStore,
        handoff: &ImportHandoff,
    ) -> Result<ImportOutcome, EinkError> {
        let primary_file = match &handoff.source_linked_file_id {
            Some(id) => store
                .get_linked_file(id.clone())?
                .map(|row| (row.id, row.filename)),
            None => None,
        };
        let request = ImportRequest {
            device: &handoff.device,
            mirror_id: &handoff.mirror_id,
            publication_id: &handoff.publication_id,
            library_dir: &handoff.library_dir,
            primary_file,
            remote_id: &handoff.remote_id,
            remote_name: &handoff.remote_name,
            remote_modified_ms: handoff.remote_modified_ms,
            rendered_pdf: &handoff.annotated_pdf,
            rmdoc: handoff.rmdoc.as_deref(),
        };
        import_annotated_document(store, &request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_media_box_gives_the_page_size() {
        let a4 = b"%PDF-1.4\n1 0 obj << /Type /Page /MediaBox [0 0 595 842] >> endobj";
        assert_eq!(pdf_page_size(a4), (595.0, 842.0));
        assert_eq!(pdf_page_size(b"%PDF-1.4 nothing here"), (612.0, 792.0));
    }
}
