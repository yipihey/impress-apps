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

/// Try to initialize a `Pdfium` instance without panicking.
///
/// `Pdfium::default()` panics when the `libpdfium` dynamic library can't
/// be loaded — which is the current situation on macOS bundles that don't
/// ship the dylib. This helper returns `PdfError::PdfiumNotAvailable`
/// instead, letting Swift callers gracefully fall back to PDFKit.
///
/// Tries, in order:
///   1. The statically-linked library (if the crate was built with that feature)
///   2. A dylib next to the executable or in the standard search path
///
/// The first attempt that succeeds wins.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn try_init_pdfium() -> Result<Pdfium, PdfError> {
    // `bind_to_system_library` is the safe, non-panicking entry point.
    // On macOS with no bundled dylib it returns LoadLibraryError; we map
    // that to `PdfiumNotAvailable` so Swift can select its PDFKit
    // fallback path without the scary `.unwrap()` panic text in logs.
    match Pdfium::bind_to_system_library() {
        Ok(bindings) => Ok(Pdfium::new(bindings)),
        Err(_) => Err(PdfError::PdfiumNotAvailable),
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
    let pdfium = try_init_pdfium()?;
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
    let pdfium = try_init_pdfium()?;
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

/// One character of a page with its box, in PDF points (origin bottom-left).
#[derive(Clone, Debug, PartialEq)]
pub struct CharBox {
    pub ch: char,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Every character of one page (0-based) with its loose bounds, in the
/// order pdfium reads them. Used to recover the text under a free-hand
/// highlighter stroke coming back from an e-ink tablet, which carries a
/// rectangle but no text. `PdfiumNotAvailable` when the library is absent.
#[cfg(not(target_arch = "wasm32"))]
pub fn page_char_boxes(pdf_bytes: &[u8], page_index: u32) -> Result<Vec<CharBox>, PdfError> {
    let pdfium = try_init_pdfium()?;
    let document = pdfium.load_pdf_from_byte_slice(pdf_bytes, None)?;
    let page = document
        .pages()
        .get(page_index as u16)
        .map_err(|e| PdfError::ExtractionError(e.to_string()))?;
    let text = page
        .text()
        .map_err(|e| PdfError::ExtractionError(e.to_string()))?;
    let mut boxes = Vec::new();
    for c in text.chars().iter() {
        let Some(ch) = c.unicode_char() else {
            continue;
        };
        let Ok(bounds) = c.loose_bounds() else {
            continue;
        };
        boxes.push(CharBox {
            ch,
            x: bounds.left().value as f64,
            y: bounds.bottom().value as f64,
            width: bounds.width().value as f64,
            height: bounds.height().value as f64,
        });
    }
    Ok(boxes)
}

/// The characters whose centre lies inside the rectangle (PDF points,
/// origin bottom-left), in reading order, with runs of whitespace
/// collapsed. Empty when nothing is inside.
pub fn text_in_rect(boxes: &[CharBox], x: f64, y: f64, width: f64, height: f64) -> String {
    let (x1, y1) = (x + width, y + height);
    let inside: String = boxes
        .iter()
        .filter(|b| {
            let cx = b.x + b.width / 2.0;
            let cy = b.y + b.height / 2.0;
            cx >= x && cx <= x1 && cy >= y && cy <= y1
        })
        .map(|b| b.ch)
        .collect();
    inside.split_whitespace().collect::<Vec<_>>().join(" ")
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
    let pdfium = try_init_pdfium()?;
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
mod char_box_tests {
    use super::*;

    #[test]
    fn text_in_rect_takes_characters_whose_centre_is_inside() {
        let word = |s: &str, x0: f64| -> Vec<CharBox> {
            s.chars()
                .enumerate()
                .map(|(i, ch)| CharBox {
                    ch,
                    x: x0 + i as f64 * 6.0,
                    y: 100.0,
                    width: 6.0,
                    height: 10.0,
                })
                .collect()
        };
        let mut boxes = word("CALIBRATION", 50.0);
        boxes.push(CharBox {
            ch: ' ',
            x: 116.0,
            y: 100.0,
            width: 6.0,
            height: 10.0,
        });
        boxes.extend(word("SCALE", 122.0));
        assert_eq!(text_in_rect(&boxes, 48.0, 98.0, 68.0, 14.0), "CALIBRATION");
        assert_eq!(
            text_in_rect(&boxes, 48.0, 98.0, 110.0, 14.0),
            "CALIBRATION SCALE"
        );
        assert_eq!(text_in_rect(&boxes, 0.0, 0.0, 10.0, 10.0), "");
    }
}

#[cfg(test)]
mod tests {
    // Note: PDF tests require the pdfium library to be installed.
    // These tests are disabled by default as they depend on native library availability.
    // To run these tests, install pdfium and use: cargo test --features test-pdf
}
