//! PDF metadata extraction

use super::extract::PdfError;
use pdfium_render::prelude::*;

/// PDF document metadata
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct PdfMetadata {
    pub page_count: u32,
}

/// Extract metadata from a PDF
#[cfg(not(target_arch = "wasm32"))]
pub fn extract_pdf_metadata(pdf_bytes: &[u8]) -> Result<PdfMetadata, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    Ok(PdfMetadata {
        page_count: document.pages().len() as u32,
    })
}

/// Get page dimensions
#[derive(uniffi::Record, Clone, Debug)]
pub struct PageDimensions {
    pub width: f32,
    pub height: f32,
}

#[cfg(not(target_arch = "wasm32"))]
pub fn get_page_dimensions(pdf_bytes: &[u8], page_number: u32) -> Result<PageDimensions, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let page = document
        .pages()
        .get((page_number - 1) as u16)
        .map_err(|e| PdfError::LoadError(format!("Page {} not found: {}", page_number, e)))?;

    Ok(PageDimensions {
        width: page.width().value,
        height: page.height().value,
    })
}

/// Get the number of pages in a PDF
#[cfg(not(target_arch = "wasm32"))]
pub fn get_page_count(pdf_bytes: &[u8]) -> Result<u32, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;
    Ok(document.pages().len() as u32)
}
