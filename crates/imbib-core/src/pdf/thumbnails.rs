//! PDF thumbnail generation

use super::extract::PdfError;
use pdfium_render::prelude::*;

/// Thumbnail configuration
#[derive(uniffi::Record, Clone, Debug)]
pub struct ThumbnailConfig {
    pub width: u32,
    pub height: u32,
    pub page_number: u32,
}

impl Default for ThumbnailConfig {
    fn default() -> Self {
        Self {
            width: 200,
            height: 280,
            page_number: 1,
        }
    }
}

/// Generate a thumbnail for a PDF page
///
/// Returns RGBA pixel data
#[cfg(not(target_arch = "wasm32"))]
pub fn generate_thumbnail(pdf_bytes: &[u8], config: &ThumbnailConfig) -> Result<Vec<u8>, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let page = document
        .pages()
        .get((config.page_number - 1) as u16)
        .map_err(|e| PdfError::LoadError(format!("Page not found: {}", e)))?;

    // Calculate scale to fit within dimensions while preserving aspect ratio
    let page_width = page.width().value;
    let page_height = page.height().value;

    let scale_x = config.width as f32 / page_width;
    let scale_y = config.height as f32 / page_height;
    let scale = scale_x.min(scale_y);

    let render_width = (page_width * scale) as i32;
    let render_height = (page_height * scale) as i32;

    let render_config = PdfRenderConfig::new()
        .set_target_width(render_width)
        .set_target_height(render_height);

    let bitmap = page
        .render_with_config(&render_config)
        .map_err(|e| PdfError::ExtractionError(format!("Render failed: {}", e)))?;

    // Convert to RGBA bytes
    Ok(bitmap.as_raw_bytes().to_vec())
}

/// Generate thumbnails for multiple pages
#[cfg(not(target_arch = "wasm32"))]
pub fn generate_thumbnails(
    pdf_bytes: &[u8],
    pages: &[u32],
    width: u32,
    height: u32,
) -> Result<Vec<(u32, Vec<u8>)>, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let mut results = Vec::new();

    for &page_num in pages {
        let config = ThumbnailConfig {
            width,
            height,
            page_number: page_num,
        };

        if let Ok(thumbnail) = generate_thumbnail_from_doc(&pdfium, &document, &config) {
            results.push((page_num, thumbnail));
        }
    }

    Ok(results)
}

#[cfg(not(target_arch = "wasm32"))]
fn generate_thumbnail_from_doc(
    _pdfium: &Pdfium,
    document: &PdfDocument,
    config: &ThumbnailConfig,
) -> Result<Vec<u8>, PdfError> {
    let page = document
        .pages()
        .get((config.page_number - 1) as u16)
        .map_err(|e| PdfError::LoadError(format!("Page not found: {}", e)))?;

    let page_width = page.width().value;
    let page_height = page.height().value;

    let scale_x = config.width as f32 / page_width;
    let scale_y = config.height as f32 / page_height;
    let scale = scale_x.min(scale_y);

    let render_width = (page_width * scale) as i32;
    let render_height = (page_height * scale) as i32;

    let render_config = PdfRenderConfig::new()
        .set_target_width(render_width)
        .set_target_height(render_height);

    let bitmap = page
        .render_with_config(&render_config)
        .map_err(|e| PdfError::ExtractionError(format!("Render failed: {}", e)))?;

    Ok(bitmap.as_raw_bytes().to_vec())
}
