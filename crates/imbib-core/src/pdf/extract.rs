//! PDF text extraction for search indexing

use pdfium_render::prelude::*;
use thiserror::Error;

/// Error type for PDF operations.
///
/// Exposed to Swift via UniFFI.
#[derive(Error, Debug, uniffi::Error)]
pub enum PdfError {
    #[error("Failed to load PDF: {0}")]
    LoadError(String),
    #[error("Failed to extract text: {0}")]
    ExtractionError(String),
    #[error("Pdfium not available")]
    PdfiumNotAvailable,
}

impl From<PdfiumError> for PdfError {
    fn from(e: PdfiumError) -> Self {
        PdfError::LoadError(e.to_string())
    }
}

/// Result of PDF text extraction
#[derive(uniffi::Record, Clone, Debug)]
pub struct PdfTextResult {
    pub full_text: String,
    pub page_count: u32,
    pub pages: Vec<PageText>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct PageText {
    pub page_number: u32,
    pub text: String,
    pub char_count: u32,
}

/// Extract all text from a PDF
#[cfg(not(target_arch = "wasm32"))]
pub fn extract_pdf_text(pdf_bytes: &[u8]) -> Result<PdfTextResult, PdfError> {
    let pdfium = Pdfium::default();
    extract_with_pdfium(&pdfium, pdf_bytes)
}

fn extract_with_pdfium(pdfium: &Pdfium, pdf_bytes: &[u8]) -> Result<PdfTextResult, PdfError> {
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let page_count = document.pages().len() as u32;
    let mut pages = Vec::with_capacity(page_count as usize);
    let mut full_text = String::new();

    for (i, page) in document.pages().iter().enumerate() {
        let text = page
            .text()
            .map_err(|e| PdfError::ExtractionError(e.to_string()))?;

        let page_text = text.all();
        let char_count = page_text.chars().count() as u32;

        pages.push(PageText {
            page_number: (i + 1) as u32,
            text: page_text.clone(),
            char_count,
        });

        if !full_text.is_empty() {
            full_text.push('\n');
        }
        full_text.push_str(&page_text);
    }

    Ok(PdfTextResult {
        full_text,
        page_count,
        pages,
    })
}

/// Extract text from a specific page range
#[cfg(not(target_arch = "wasm32"))]
pub fn extract_page_range(
    pdf_bytes: &[u8],
    start_page: u32,
    end_page: u32,
) -> Result<String, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let mut text = String::new();

    for i in start_page..=end_page {
        if let Ok(page) = document.pages().get((i - 1) as u16) {
            let page_text = page
                .text()
                .map_err(|e| PdfError::ExtractionError(e.to_string()))?;
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&page_text.all());
        }
    }

    Ok(text)
}

/// Search for text within a PDF and return positions
#[derive(uniffi::Record, Clone, Debug)]
pub struct TextMatch {
    pub page_number: u32,
    pub text: String,
    pub char_index: u32,
}

#[cfg(not(target_arch = "wasm32"))]
pub fn search_in_pdf(
    pdf_bytes: &[u8],
    query: &str,
    max_results: usize,
) -> Result<Vec<TextMatch>, PdfError> {
    let pdfium = Pdfium::default();
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;

    let query_lower = query.to_lowercase();
    let mut matches = Vec::new();

    for (page_idx, page) in document.pages().iter().enumerate() {
        let text = page
            .text()
            .map_err(|e| PdfError::ExtractionError(e.to_string()))?;

        let page_text = text.all();
        let page_lower = page_text.to_lowercase();

        let mut search_start = 0;
        while let Some(pos) = page_lower[search_start..].find(&query_lower) {
            let absolute_pos = search_start + pos;

            // Extract context around match
            let context_start = absolute_pos.saturating_sub(50);
            let context_end = (absolute_pos + query.len() + 50).min(page_text.len());

            let mut context = String::new();
            if context_start > 0 {
                context.push_str("...");
            }
            context.push_str(&page_text[context_start..context_end]);
            if context_end < page_text.len() {
                context.push_str("...");
            }

            matches.push(TextMatch {
                page_number: (page_idx + 1) as u32,
                text: context,
                char_index: absolute_pos as u32,
            });

            if matches.len() >= max_results {
                return Ok(matches);
            }

            search_start = absolute_pos + query.len();
        }
    }

    Ok(matches)
}

#[cfg(test)]
mod tests {
    // Note: PDF tests require the pdfium library to be installed.
    // These tests are disabled by default as they depend on native library availability.
    // To run these tests, install pdfium and use: cargo test --features test-pdf
}
