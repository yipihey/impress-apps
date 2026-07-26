//! PDF page rasterisation, with no new dependency.
//!
//! MCP image content is raster only, so a PDF can never be returned directly.
//! The workflow that needs this — the user on a phone, the agent on the Mac,
//! the conversation as the only display surface — needs the page as a PNG or
//! the result is unviewable. Before this, `get_pdf` could only report a path
//! and a byte count, which is useless to anyone not sitting at that Mac.
//!
//! Rather than pull in a PDF renderer (pdfium plus a native build, tens of
//! megabytes), this shells out to `osascript -l JavaScript`, which ships with
//! macOS and bridges to PDFKit and AppKit. The whole suite is macOS-native and
//! this binary always runs on the user's Mac, so the trade is a good one.
//!
//! Ported from `packages/impress-mcp/src/raster.ts` during the TypeScript
//! retirement; the JXA below is that file's, unchanged, because it was already
//! doing the right thing.
//!
//! Spawning a subprocess is fine *here*: this is a standalone CLI. The
//! no-`Process()` invariant that binds impel applies to the sandboxed app, not
//! to this binary.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Longest edge, in pixels, of a rendered page. ~1100px keeps body text legible
/// while keeping a typical page small enough to inline.
pub const DEFAULT_PAGE_MAX_DIM: u32 = 1100;

/// JXA: open the PDF with PDFKit, render one page to PNG, report the page
/// count. `boundsForBox(0)` is kPDFDisplayBoxMediaBox; `4` is
/// NSBitmapImageFileTypePNG — the named constants are not on the JXA bridge.
const RASTER_JXA: &str = r#"
function run(argv) {
  ObjC.import('Foundation');
  ObjC.import('AppKit');
  ObjC.import('Quartz');
  var inPath = argv[0], outPath = argv[1];
  var pageArg = parseInt(argv[2], 10) || 1;
  var maxDim = parseInt(argv[3], 10) || 1100;

  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath($(inPath)));
  if (!doc || doc.isNil()) return JSON.stringify({ error: 'not a readable PDF' });
  var count = parseInt(doc.pageCount, 10);
  if (!count) return JSON.stringify({ error: 'PDF has no pages' });
  var idx = pageArg < 1 ? 1 : (pageArg > count ? count : pageArg);
  var page = doc.pageAtIndex(idx - 1);
  if (!page || page.isNil()) return JSON.stringify({ error: 'page ' + idx + ' not readable' });

  var bounds = page.boundsForBox(0);
  var w = bounds.size.width, h = bounds.size.height;
  if (!w || !h) return JSON.stringify({ error: 'page has zero bounds' });
  var scale = Math.min(maxDim / w, maxDim / h, 4);
  if (!isFinite(scale) || scale <= 0) scale = 1;
  var tw = Math.max(1, Math.round(w * scale)), th = Math.max(1, Math.round(h * scale));

  var img = page.thumbnailOfSizeForBox({ width: tw, height: th }, 0);
  var rep = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
  var png = rep.representationUsingTypeProperties(4, $());
  if (!png || png.isNil()) return JSON.stringify({ error: 'PNG encoding failed' });
  png.writeToFileAtomically($(outPath), true);
  return JSON.stringify({ pageCount: count, page: idx, width: tw, height: th });
}
"#;

/// A rendered page.
pub struct Raster {
    /// Raw PNG bytes.
    pub png: Vec<u8>,
    pub page_count: u32,
    /// 1-based page actually rendered, clamped into range.
    pub page: u32,
    pub width: u32,
    pub height: u32,
}

/// Where rasterised output is parked, so a caption can quote a real path.
pub fn scratch_dir() -> PathBuf {
    std::env::temp_dir().join("impress-mcp")
}

/// Render one page of a PDF on disk to PNG.
///
/// Never panics and never returns a partial success: every failure path yields
/// `Err(reason)` so the caller can degrade to text plus the path rather than
/// losing the tool call.
pub fn rasterize_pdf_page(pdf_path: &Path, page: u32, max_dim: u32) -> Result<Raster, String> {
    if !pdf_path.exists() {
        return Err(format!("no PDF at {}", pdf_path.display()));
    }
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("could not create {}: {e}", dir.display()))?;

    let slug: String = pdf_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".into())
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .take(64)
        .collect();
    let png_path = dir.join(format!("{slug}-p{page}.png"));

    let page = page.max(1);
    let max_dim = if max_dim == 0 {
        DEFAULT_PAGE_MAX_DIM
    } else {
        max_dim
    };

    let output = Command::new("osascript")
        .args([
            "-l",
            "JavaScript",
            "-e",
            RASTER_JXA,
            &pdf_path.to_string_lossy(),
            &png_path.to_string_lossy(),
            &page.to_string(),
            &max_dim.to_string(),
        ])
        .output()
        .map_err(|e| format!("could not run osascript: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "osascript failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let meta: serde_json::Value =
        serde_json::from_str(stdout.trim()).map_err(|e| format!("unreadable JXA output: {e}"))?;
    if let Some(err) = meta.get("error").and_then(|e| e.as_str()) {
        return Err(err.to_string());
    }

    let png = std::fs::read(&png_path)
        .map_err(|e| format!("could not read {}: {e}", png_path.display()))?;
    // Best-effort cleanup: the PNG has been read into memory, and leaving
    // scratch files behind across a long session adds up.
    let _ = std::fs::remove_file(&png_path);

    let u = |k: &str| meta.get(k).and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    Ok(Raster {
        png,
        page_count: u("pageCount"),
        page: u("page"),
        width: u("width"),
        height: u("height"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_pdf_is_an_error_not_a_panic() {
        let err = rasterize_pdf_page(Path::new("/nonexistent/nope.pdf"), 1, 800).unwrap_err();
        assert!(err.contains("no PDF at"), "got {err}");
    }

    #[test]
    fn a_non_pdf_is_rejected_by_pdfkit() {
        // Only meaningful on macOS, where osascript exists.
        if Command::new("osascript")
            .arg("-e")
            .arg("1")
            .output()
            .is_err()
        {
            return;
        }
        let dir = scratch_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let fake = dir.join("not-a-pdf-test.pdf");
        std::fs::write(&fake, b"this is not a PDF").unwrap();
        let err = rasterize_pdf_page(&fake, 1, 400).unwrap_err();
        let _ = std::fs::remove_file(&fake);
        assert!(!err.is_empty(), "expected a reason");
    }
}
