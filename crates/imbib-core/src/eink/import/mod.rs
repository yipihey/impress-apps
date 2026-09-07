//! What comes back from the tablet: the rendition with the handwriting
//! drawn in (a second linked file), and — from the raw archive — the
//! highlights, typed text and ink groups as `imbib/annotation` rows on the
//! primary file, keyed so a re-import updates rather than duplicates.

pub mod convert;
pub mod geometry;
pub mod ink_render;
pub mod notes_merge;
pub mod reconcile;
pub mod store_ops;
pub mod variant;

use std::path::Path;

use impress_remarkable::rm::parse_rm;
use impress_remarkable::rmdoc::read_rmdoc;

use super::apply::{EinkImportSink, ImportHandoff, ImportOutcome};
use super::config::EinkDeviceConfig;
use super::transport::EinkError;
use crate::unified::store_api::ImbibStore;
use convert::ConvertOptions;
use geometry::{PageFrame, SceneToPdf};

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

/// Run one import: variant first (always), then the structured rows when
/// an archive is at hand and the device asks for them.
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

    let Some(rmdoc_path) = req.rmdoc else {
        return Ok(outcome);
    };
    if !req.device.import_rmdoc {
        return Ok(outcome);
    }
    let archive = read_rmdoc(rmdoc_path)?;
    let (pdf_w, pdf_h) = match &archive.source {
        Some(source) => pdf_page_size(&source.bytes),
        None => {
            let rendered = std::fs::read(req.rendered_pdf).unwrap_or_default();
            pdf_page_size(&rendered)
        }
    };
    let options = ConvertOptions {
        highlights: req.device.import_highlights,
        ink: req.device.import_ink,
        typed_text: req.device.import_typed_text,
        render_ink: req.device.import_ink,
    };
    let mut drafts = Vec::new();
    for page in &archive.pages {
        let Some(bytes) = &page.rm_bytes else {
            continue;
        };
        let scene = match parse_rm(bytes) {
            Ok(scene) => scene,
            Err(error) => {
                outcome
                    .warnings
                    .push(format!("page {} ({}): {error}", page.index, page.page_id));
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
        let map = archive
            .source
            .is_some()
            .then(|| SceneToPdf::fit(PageFrame::best_fit(pdf_w, pdf_h, scene.version >= 6)));
        outcome.warnings.extend(scene.warnings.iter().cloned());
        drafts.extend(convert::convert_page(
            req.remote_id,
            &page.page_id,
            page_number,
            &scene,
            map.as_ref(),
            &options,
        ));
    }
    let target_file = req
        .primary_file
        .as_ref()
        .map(|(id, _)| id.clone())
        .unwrap_or_else(|| variant.linked_file_id.clone());
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
