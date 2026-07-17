//! SyncTeX `.synctex` / `.synctex.gz` parser and lookup.
//!
//! Ported from `apps/imprint/macOS/Services/SyncTeXService.swift`.
//!
//! SyncTeX is a small text-based format emitted by `pdftex`/`xelatex`/
//! `lualatex` (with `-synctex=1`) that records bidirectional mappings
//! between source positions (file/line/column) and rendered PDF positions
//! (page/x/y/width/height/depth). The format itself is a plain text body
//! optionally gzipped.
//!
//! ## Coordinate units
//!
//! Raw SyncTeX coordinates are in **scaled points** (sp): 65536 sp = 1 pt.
//! The file's header carries `Magnification:` (default 1000, parts per 1000)
//! and `Unit:` (default 1). The effective conversion factor matches the
//! Swift implementation:
//!
//! ```text
//! scale = unit * magnification / 1000 * (1 / 65536)
//! ```
//!
//! ## API
//!
//! - [`parse_synctex`] handles both raw and gzipped input.
//! - [`lookup_source`] takes a PDF (page, x, y) and finds the nearest
//!   source location.
//! - [`lookup_pdf`] takes a source (file, line, column) and returns matching
//!   PDF positions.

use std::io::Read;

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// One file referenced in the SyncTeX `Input:` declarations.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncTexInput {
    pub id: i32,
    pub path: String,
}

/// One position record from a sheet.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncTexNode {
    pub file_id: i32,
    pub line: u32,
    pub column: u32,
    /// PDF x in points (already converted from sp).
    pub x: f64,
    /// PDF y in points (already converted from sp).
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub depth: f64,
}

/// One PDF page's worth of nodes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncTexSheet {
    pub page: u32,
    pub nodes: Vec<SyncTexNode>,
}

/// A parsed SyncTeX document.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SyncTexFile {
    pub inputs: Vec<SyncTexInput>,
    pub sheets: Vec<SyncTexSheet>,
    pub magnification: f64,
    pub unit: f64,
}

impl SyncTexFile {
    /// Resolve a source path to its `Input:` id.
    ///
    /// Matches Swift's `inputID(for:)` precedence: exact path → filename →
    /// `hasSuffix` fallback.
    pub fn input_id_for(&self, file: &str) -> Option<i32> {
        let filename = file_name(file);
        for input in &self.inputs {
            if input.path == file {
                return Some(input.id);
            }
        }
        for input in &self.inputs {
            if file_name(&input.path) == filename {
                return Some(input.id);
            }
        }
        for input in &self.inputs {
            if input.path.ends_with(file) {
                return Some(input.id);
            }
        }
        None
    }

    /// Reverse of `input_id_for`.
    pub fn path_for_input(&self, id: i32) -> Option<&str> {
        self.inputs
            .iter()
            .find(|i| i.id == id)
            .map(|i| i.path.as_str())
    }
}

/// A source location identified by inverse sync.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceLocation {
    pub file: String,
    pub line: u32,
    pub column: u32,
}

/// A PDF position identified by forward sync.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PdfLocation {
    pub page: u32,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Errors from parsing.
#[derive(Debug, Error)]
pub enum SyncTexError {
    #[error("invalid SyncTeX format: {0}")]
    InvalidFormat(String),
    #[error("gzip decompression failed: {0}")]
    Decompression(String),
    #[error("utf-8 decode failed: {0}")]
    Utf8(#[from] std::str::Utf8Error),
}

/// Parse a SyncTeX file. Accepts either raw text or gzipped bytes; the
/// gzip magic bytes `1f 8b` trigger decompression via `flate2`.
pub fn parse_synctex(bytes: &[u8]) -> Result<SyncTexFile, SyncTexError> {
    let text_owned;
    let text: &str = if bytes.len() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b {
        let mut decoder = flate2::read::GzDecoder::new(bytes);
        let mut s = String::new();
        decoder
            .read_to_string(&mut s)
            .map_err(|e| SyncTexError::Decompression(e.to_string()))?;
        text_owned = s;
        &text_owned
    } else {
        std::str::from_utf8(bytes)?
    };

    parse_text(text)
}

/// PDF → source.
///
/// Mirrors Swift's `inverseSync(page:x:y:)` algorithm: first prefer any node
/// whose bounding box (using `y..(y+height+depth)`) contains the click; if
/// none, fall back to the nearest node by centre-to-centre euclidean
/// distance.
pub fn lookup_source(file: &SyncTexFile, page: u32, x: f64, y: f64) -> Option<SourceLocation> {
    let sheet = file.sheets.iter().find(|s| s.page == page)?;
    if sheet.nodes.is_empty() {
        return None;
    }

    let mut best: Option<&SyncTexNode> = None;
    let mut best_area = f64::INFINITY;
    for node in &sheet.nodes {
        let node_bottom = node.y + node.height + node.depth;
        if x >= node.x && x <= node.x + node.width && y >= node.y && y <= node_bottom {
            let area = node.width * (node.height + node.depth);
            if best.is_none() || area < best_area {
                best_area = area;
                best = Some(node);
            }
        }
    }

    if best.is_none() {
        let mut best_dist = f64::INFINITY;
        for node in &sheet.nodes {
            let cx = node.x + node.width / 2.0;
            let cy = node.y + node.height / 2.0;
            let d = (x - cx).powi(2) + (y - cy).powi(2);
            if d < best_dist {
                best_dist = d;
                best = Some(node);
            }
        }
    }

    let node = best?;
    let path = file.path_for_input(node.file_id)?;
    Some(SourceLocation {
        file: path.to_string(),
        line: node.line,
        column: node.column,
    })
}

/// Source → PDF.
///
/// Matches Swift's `forwardSync(file:line:column:)` semantics, including the
/// "nearest line at or after the target" fallback when the requested line
/// has no exact node.
pub fn lookup_pdf(
    file: &SyncTexFile,
    source_path: &str,
    line: u32,
    _column: u32,
) -> Option<PdfLocation> {
    let input_id = file.input_id_for(source_path)?;

    // First pass: exact line match.
    let mut all_lines: std::collections::BTreeSet<u32> = std::collections::BTreeSet::new();
    let mut exact: Vec<&SyncTexNode> = Vec::new();
    let mut exact_page: u32 = 0;
    for sheet in &file.sheets {
        for node in &sheet.nodes {
            if node.file_id != input_id {
                continue;
            }
            all_lines.insert(node.line);
            if node.line == line {
                if exact.is_empty() {
                    exact_page = sheet.page;
                }
                exact.push(node);
            }
        }
    }

    if !exact.is_empty() {
        let n = exact[0];
        return Some(PdfLocation {
            page: exact_page,
            x: n.x,
            y: n.y,
            width: n.width,
            height: n.height,
        });
    }

    // Fallback: nearest line ≥ target, else max line.
    if all_lines.is_empty() {
        return None;
    }
    let nearest = all_lines
        .iter()
        .find(|&&l| l >= line)
        .copied()
        .unwrap_or_else(|| *all_lines.iter().next_back().unwrap());

    for sheet in &file.sheets {
        for node in &sheet.nodes {
            if node.file_id == input_id && node.line == nearest {
                return Some(PdfLocation {
                    page: sheet.page,
                    x: node.x,
                    y: node.y,
                    width: node.width,
                    height: node.height,
                });
            }
        }
    }
    None
}

/// All PDF positions for a source line (Swift's `forwardSync` returns an
/// array). Exposed for callers that want every occurrence (e.g. a TUI that
/// highlights all of them).
pub fn lookup_pdf_all(file: &SyncTexFile, source_path: &str, line: u32) -> Vec<PdfLocation> {
    let mut out = Vec::new();
    let Some(input_id) = file.input_id_for(source_path) else {
        return out;
    };
    for sheet in &file.sheets {
        for node in &sheet.nodes {
            if node.file_id == input_id && node.line == line {
                out.push(PdfLocation {
                    page: sheet.page,
                    x: node.x,
                    y: node.y,
                    width: node.width,
                    height: node.height,
                });
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

fn parse_text(text: &str) -> Result<SyncTexFile, SyncTexError> {
    let mut inputs: Vec<SyncTexInput> = Vec::new();
    let mut sheets: Vec<SyncTexSheet> = Vec::new();
    let mut current_sheet: Option<SyncTexSheet> = None;
    let mut magnification: f64 = 1000.0;
    let mut unit: f64 = 1.0;

    const SP_TO_POINTS: f64 = 1.0 / 65536.0;

    for line in text.split('\n') {
        if line.is_empty() {
            continue;
        }

        if let Some(rest) = line.strip_prefix("Input:") {
            let mut parts = rest.splitn(2, ':');
            if let (Some(id_s), Some(path)) = (parts.next(), parts.next()) {
                if let Ok(id) = id_s.parse() {
                    inputs.push(SyncTexInput {
                        id,
                        path: path.to_string(),
                    });
                }
            }
            continue;
        }

        if let Some(rest) = line.strip_prefix("Magnification:") {
            if let Ok(v) = rest.trim().parse() {
                magnification = v;
            }
            continue;
        }

        if let Some(rest) = line.strip_prefix("Unit:") {
            if let Ok(v) = rest.trim().parse() {
                unit = v;
            }
            continue;
        }

        // Sheet open: "{<PAGE>"
        if let Some(rest) = line.strip_prefix('{') {
            if let Ok(page) = rest.trim().parse() {
                if let Some(s) = current_sheet.take() {
                    sheets.push(s);
                }
                current_sheet = Some(SyncTexSheet {
                    page,
                    nodes: Vec::new(),
                });
                continue;
            }
        }

        // Sheet close: "}"
        if line == "}" {
            if let Some(s) = current_sheet.take() {
                sheets.push(s);
            }
            continue;
        }

        // Node records start with one of: h v k g x $ [ ] ( )
        let first = match line.chars().next() {
            Some(c) => c,
            None => continue,
        };
        // Per Swift: only h/v/k/g/x records carry position info we want.
        if !matches!(first, 'h' | 'v' | 'k' | 'g' | 'x') {
            continue;
        }

        // Data starts after the type character.
        let data = &line[1..];

        // Groups separated by ':', sub-fields by ','.
        let groups: Vec<&str> = data.splitn(3, ':').collect();
        if groups.len() < 2 {
            continue;
        }
        let id_line_parts: Vec<&str> = groups[0].split(',').collect();
        if id_line_parts.len() < 2 {
            continue;
        }
        let file_id: i32 = match id_line_parts[0].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let line_num: u32 = match id_line_parts[1].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let column: u32 = if id_line_parts.len() >= 3 {
            id_line_parts[2].parse().unwrap_or(0)
        } else {
            0
        };

        let xy_parts: Vec<&str> = groups[1].split(',').collect();
        if xy_parts.len() < 2 {
            continue;
        }
        let raw_x: f64 = match xy_parts[0].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let raw_y: f64 = match xy_parts[1].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };

        let (mut raw_w, mut raw_h, mut raw_d) = (0.0f64, 0.0f64, 0.0f64);
        if groups.len() >= 3 {
            let whd: Vec<&str> = groups[2].split(',').collect();
            if let Some(v) = whd.first() {
                raw_w = v.parse().unwrap_or(0.0);
            }
            if let Some(v) = whd.get(1) {
                raw_h = v.parse().unwrap_or(0.0);
            }
            if let Some(v) = whd.get(2) {
                raw_d = v.parse().unwrap_or(0.0);
            }
        }

        let scale = unit * magnification / 1000.0 * SP_TO_POINTS;
        let node = SyncTexNode {
            file_id,
            line: line_num,
            column,
            x: raw_x * scale,
            y: raw_y * scale,
            width: raw_w * scale,
            height: raw_h * scale,
            depth: raw_d * scale,
        };

        if let Some(sheet) = current_sheet.as_mut() {
            sheet.nodes.push(node);
        }
    }

    if let Some(s) = current_sheet.take() {
        sheets.push(s);
    }

    Ok(SyncTexFile {
        inputs,
        sheets,
        magnification,
        unit,
    })
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// A small handcrafted SyncTeX fixture that exercises every header field
    /// and one h-record per sheet. The numeric values were chosen so the
    /// post-scale coordinates are easy round numbers:
    ///
    /// magnification=1000, unit=1 → scale = 1/65536. With raw x=65536 → 1pt.
    fn fixture_text() -> &'static str {
        "SyncTeX Version: 1.21\n\
         Magnification:1000\n\
         Unit:1\n\
         Input:1:./paper.tex\n\
         Input:2:./section.tex\n\
         Content:\n\
         {1\n\
         h1,10:65536,131072:65536,65536,0\n\
         h2,5:131072,196608:131072,65536,0\n\
         }\n\
         {2\n\
         h1,20:65536,262144:65536,65536,0\n\
         }\n\
         Postamble:\n"
    }

    #[test]
    fn parses_minimal_synctex() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        assert_eq!(f.inputs.len(), 2);
        assert_eq!(f.inputs[0].path, "./paper.tex");
        assert_eq!(f.inputs[1].id, 2);
        assert_eq!(f.sheets.len(), 2);
        assert_eq!(f.sheets[0].page, 1);
        assert_eq!(f.sheets[0].nodes.len(), 2);
        assert_eq!(f.sheets[1].page, 2);
        assert_eq!(f.magnification, 1000.0);
        assert_eq!(f.unit, 1.0);
    }

    #[test]
    fn scales_coordinates_correctly() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        let n = &f.sheets[0].nodes[0];
        assert!((n.x - 1.0).abs() < 1e-9, "x should be 1pt, got {}", n.x);
        assert!((n.y - 2.0).abs() < 1e-9, "y should be 2pt, got {}", n.y);
        assert!((n.width - 1.0).abs() < 1e-9);
        assert!((n.height - 1.0).abs() < 1e-9);
    }

    #[test]
    fn forward_sync_exact_line() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        let loc = lookup_pdf(&f, "./paper.tex", 10, 0).unwrap();
        assert_eq!(loc.page, 1);
        assert!((loc.x - 1.0).abs() < 1e-9);
    }

    #[test]
    fn forward_sync_uses_filename_fallback() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        // Path is stored as "./paper.tex" but we look up "paper.tex".
        let loc = lookup_pdf(&f, "paper.tex", 10, 0).unwrap();
        assert_eq!(loc.page, 1);
    }

    #[test]
    fn forward_sync_nearest_line_fallback() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        // We have nodes for paper.tex at line 10 and 20. Asking for 15
        // should snap to 20 (the nearest line at-or-after target).
        let loc = lookup_pdf(&f, "./paper.tex", 15, 0).unwrap();
        assert_eq!(loc.page, 2);
    }

    #[test]
    fn forward_sync_falls_back_to_max_line_when_past_end() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        // Line 999 — no node at or after; we fall back to the largest line (20).
        let loc = lookup_pdf(&f, "./paper.tex", 999, 0).unwrap();
        assert_eq!(loc.page, 2);
    }

    #[test]
    fn forward_sync_unknown_file_returns_none() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        assert!(lookup_pdf(&f, "nope.tex", 1, 0).is_none());
    }

    #[test]
    fn forward_sync_returns_every_occurrence() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        let all = lookup_pdf_all(&f, "./paper.tex", 10);
        assert_eq!(all.len(), 1);
        let none = lookup_pdf_all(&f, "./paper.tex", 999);
        assert!(none.is_empty());
    }

    #[test]
    fn inverse_sync_finds_containing_node() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        // Node at (1pt, 2pt) of size 1x1; click inside.
        let loc = lookup_source(&f, 1, 1.5, 2.5).unwrap();
        assert_eq!(loc.file, "./paper.tex");
        assert_eq!(loc.line, 10);
    }

    #[test]
    fn inverse_sync_falls_back_to_nearest_when_no_container() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        // Click outside all bboxes; should still return *something*.
        let loc = lookup_source(&f, 1, 100.0, 100.0).unwrap();
        assert!(loc.file == "./paper.tex" || loc.file == "./section.tex");
    }

    #[test]
    fn inverse_sync_unknown_page_returns_none() {
        let f = parse_synctex(fixture_text().as_bytes()).unwrap();
        assert!(lookup_source(&f, 99, 0.0, 0.0).is_none());
    }

    #[test]
    fn empty_input_yields_empty_file() {
        let f = parse_synctex(b"").unwrap();
        assert!(f.inputs.is_empty());
        assert!(f.sheets.is_empty());
    }

    #[test]
    fn parses_gzipped_input() {
        use std::io::Write;
        let raw = fixture_text();
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(raw.as_bytes()).unwrap();
        let gz = enc.finish().unwrap();
        let parsed = parse_synctex(&gz).unwrap();
        assert_eq!(parsed.inputs.len(), 2);
        assert_eq!(parsed.sheets.len(), 2);
    }

    #[test]
    fn malformed_records_are_skipped_not_error() {
        // Mix valid records with garbage; parse must succeed and skip junk.
        let text = "Input:1:./a.tex\n\
                    {1\n\
                    h\n\
                    h_not_a_number\n\
                    h1,10:65536,65536:65536,65536,0\n\
                    }\n";
        let f = parse_synctex(text.as_bytes()).unwrap();
        assert_eq!(f.sheets.len(), 1);
        assert_eq!(f.sheets[0].nodes.len(), 1);
    }

    #[test]
    fn respects_magnification_and_unit() {
        // unit=2, magnification=2000 → scale doubled twice (4x).
        let text = "Magnification:2000\n\
                    Unit:2\n\
                    Input:1:./a.tex\n\
                    {1\n\
                    h1,1:65536,0:65536,65536,0\n\
                    }\n";
        let f = parse_synctex(text.as_bytes()).unwrap();
        let n = &f.sheets[0].nodes[0];
        // 65536 * (2 * 2000 / 1000) / 65536 = 4pt
        assert!((n.x - 4.0).abs() < 1e-9, "x={}", n.x);
    }
}
