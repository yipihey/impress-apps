//! The `.rm` stroke file: one per page, `reMarkable .lines file, version=N`.
//!
//! Versions 3 and 5 are a flat layer/stroke/point layout (firmware 2);
//! version 6 (firmware 3) is a stream of tagged CRDT blocks that also
//! carries text highlights (`GlyphRange`, with the highlighted text) and
//! typed text (`RootText`). Both decode into the same [`RmScene`], which
//! is all an import needs: strokes with bounds, highlights with text and
//! rectangles, typed paragraphs.
//!
//! Coordinates are the tablet's scene units: on firmware 2 the page is
//! 1404 × 1872 with the origin top-left; firmware 3 keeps the same frame
//! for x with the origin in the middle of the top edge (x from −702 to
//! 702) and y growing downwards. `.content` says how a PDF page was fitted
//! into that frame (see `rmdoc::RmContent`).

mod v5;
mod v6;

use std::fmt;

use crate::error::{Error, Result};

const HEADER_PREFIX: &[u8] = b"reMarkable .lines file, version=";
/// Every version pads its header to this length.
pub const HEADER_LEN: usize = 43;

/// The CRDT id firmware 3 gives every item: `part1:part2`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct CrdtId {
    pub part1: u8,
    pub part2: u64,
}

impl fmt::Display for CrdtId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.part1, self.part2)
    }
}

/// The pen the stroke was drawn with. Firmware 2 and 3 use different ids
/// for the same pens; both map here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tool {
    Brush,
    Pencil,
    Ballpoint,
    Marker,
    Fineliner,
    Highlighter,
    Eraser,
    EraseArea,
    MechanicalPencil,
    Calligraphy,
    Shader,
    Unknown(u32),
}

impl Tool {
    pub fn from_id(id: u32) -> Self {
        match id {
            0 | 12 => Self::Brush,
            1 | 14 => Self::Pencil,
            2 | 15 => Self::Ballpoint,
            3 | 16 => Self::Marker,
            4 | 17 => Self::Fineliner,
            5 | 18 => Self::Highlighter,
            6 => Self::Eraser,
            8 => Self::EraseArea,
            7 | 13 => Self::MechanicalPencil,
            21 => Self::Calligraphy,
            22 => Self::Shader,
            other => Self::Unknown(other),
        }
    }

    pub fn name(self) -> String {
        match self {
            Self::Brush => "brush".into(),
            Self::Pencil => "pencil".into(),
            Self::Ballpoint => "ballpoint".into(),
            Self::Marker => "marker".into(),
            Self::Fineliner => "fineliner".into(),
            Self::Highlighter => "highlighter".into(),
            Self::Eraser => "eraser".into(),
            Self::EraseArea => "erase-area".into(),
            Self::MechanicalPencil => "mechanical-pencil".into(),
            Self::Calligraphy => "calligraphy".into(),
            Self::Shader => "shader".into(),
            Self::Unknown(id) => format!("tool-{id}"),
        }
    }

    pub fn is_eraser(self) -> bool {
        matches!(self, Self::Eraser | Self::EraseArea)
    }
}

/// A hex colour for the tablet's palette ids (firmware 3 names).
pub fn color_hex(color_id: u32) -> &'static str {
    match color_id {
        0 => "#000000",
        1 => "#808080",
        2 => "#ffffff",
        3 | 9 => "#ffff00",
        4 | 10 => "#00ff00",
        5 => "#ff00ff",
        6 => "#0000ff",
        7 => "#ff0000",
        8 => "#a0a0a0",
        11 => "#00ffff",
        12 => "#ff80ff",
        13 => "#ffd700",
        _ => "#000000",
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    pub x: f32,
    pub y: f32,
    pub speed: f32,
    pub direction: f32,
    pub width: f32,
    pub pressure: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn union(self, other: Rect) -> Rect {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = (self.x + self.w).max(other.x + other.w);
        let y1 = (self.y + self.h).max(other.y + other.h);
        Rect {
            x: x0,
            y: y0,
            w: x1 - x0,
            h: y1 - y0,
        }
    }
}

/// One stroke.
#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    /// Firmware-3 item id; `None` for firmware-2 files (where the index in
    /// the file is the only identity).
    pub id: Option<CrdtId>,
    pub layer: usize,
    pub tool: Tool,
    pub color: u32,
    /// An explicit RGBA colour (firmware 3.x with colour support).
    pub rgba: Option<u32>,
    pub thickness_scale: f64,
    pub points: Vec<Point>,
}

impl Line {
    pub fn is_highlighter(&self) -> bool {
        self.tool == Tool::Highlighter
    }

    pub fn bounds(&self) -> Option<Rect> {
        let first = self.points.first()?;
        let (mut x0, mut y0, mut x1, mut y1) = (first.x, first.y, first.x, first.y);
        for point in &self.points {
            x0 = x0.min(point.x);
            y0 = y0.min(point.y);
            x1 = x1.max(point.x);
            y1 = y1.max(point.y);
        }
        Some(Rect {
            x: f64::from(x0),
            y: f64::from(y0),
            w: f64::from(x1 - x0),
            h: f64::from(y1 - y0),
        })
    }
}

/// A text highlight on a PDF/ePUB page (firmware 3): the highlighted text
/// itself plus the rectangles it covers, in scene units.
#[derive(Debug, Clone, PartialEq)]
pub struct GlyphRange {
    pub id: CrdtId,
    pub start: u32,
    pub length: u32,
    pub color: u32,
    pub text: String,
    pub rects: Vec<Rect>,
}

impl GlyphRange {
    pub fn bounds(&self) -> Option<Rect> {
        let mut iter = self.rects.iter().copied();
        let first = iter.next()?;
        Some(iter.fold(first, Rect::union))
    }
}

/// A paragraph of typed text with its style code (0 plain, 1 basic, 2
/// heading, 3 bold, 4 bullet, 5 bullet 2, 6 checkbox, 7 checked).
#[derive(Debug, Clone, PartialEq)]
pub struct Paragraph {
    pub style: u8,
    pub text: String,
}

/// The page's typed text (firmware 3, keyboard or on-screen).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RootText {
    pub id: CrdtId,
    pub paragraphs: Vec<Paragraph>,
    pub pos_x: f64,
    pub pos_y: f64,
    pub width: f32,
}

impl RootText {
    pub fn text(&self) -> String {
        self.paragraphs
            .iter()
            .map(|p| p.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// Everything an import wants from one page.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RmScene {
    pub version: u8,
    pub lines: Vec<Line>,
    pub glyph_ranges: Vec<GlyphRange>,
    pub root_text: Option<RootText>,
    /// Layer names when the file carries them (firmware 2 has none).
    pub layer_count: usize,
    /// Block types the reader did not interpret (firmware 3).
    pub skipped_blocks: Vec<u8>,
    pub warnings: Vec<String>,
}

impl RmScene {
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty() && self.glyph_ranges.is_empty() && self.root_text.is_none()
    }
}

/// The version in the header, or an error for anything else.
pub fn header_version(bytes: &[u8]) -> Result<u8> {
    if bytes.len() < HEADER_LEN || !bytes.starts_with(HEADER_PREFIX) {
        return Err(Error::Format {
            path: "<rm>".into(),
            detail: "not a reMarkable .lines file".into(),
        });
    }
    let version_text = String::from_utf8_lossy(&bytes[HEADER_PREFIX.len()..HEADER_LEN]);
    version_text
        .trim()
        .parse::<u8>()
        .map_err(|_| Error::Format {
            path: "<rm>".into(),
            detail: format!("unreadable version {version_text:?}"),
        })
}

/// Parse a page. Firmware-2 files (versions 3 and 5) and firmware-3 files
/// (version 6) both work; anything else is refused.
pub fn parse_rm(bytes: &[u8]) -> Result<RmScene> {
    let version = header_version(bytes)?;
    let body = &bytes[HEADER_LEN..];
    match version {
        3 | 5 => v5::parse(version, body),
        6 => v6::parse(body),
        other => Err(Error::Format {
            path: "<rm>".into(),
            detail: format!("unsupported .lines version {other}"),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_names_the_version() {
        let mut bytes = b"reMarkable .lines file, version=6          ".to_vec();
        bytes.extend_from_slice(&[0; 8]);
        assert_eq!(header_version(&bytes).unwrap(), 6);
        assert!(header_version(b"not a lines file").is_err());
        let mut v9 = b"reMarkable .lines file, version=9          ".to_vec();
        v9.extend_from_slice(&[0; 8]);
        assert!(matches!(parse_rm(&v9), Err(Error::Format { .. })));
    }

    #[test]
    fn tools_map_from_both_firmware_generations() {
        assert_eq!(Tool::from_id(5), Tool::Highlighter);
        assert_eq!(Tool::from_id(18), Tool::Highlighter);
        assert_eq!(Tool::from_id(2), Tool::Ballpoint);
        assert_eq!(Tool::from_id(15), Tool::Ballpoint);
        assert_eq!(Tool::from_id(99), Tool::Unknown(99));
        assert!(Tool::EraseArea.is_eraser());
    }

    #[test]
    fn a_real_firmware_2_page_parses() {
        let bytes = include_bytes!("../../tests/fixtures/rm/notebook_page_v5.rm");
        let scene = parse_rm(bytes).expect("a page the tablet wrote");
        assert_eq!(scene.version, 5);
        assert!(scene.layer_count >= 1);
        assert!(!scene.lines.is_empty(), "a written page has strokes");
        let points: usize = scene.lines.iter().map(|l| l.points.len()).sum();
        assert!(points > 100, "{points} points");
        for line in &scene.lines {
            let bounds = line.bounds().unwrap();
            assert!(
                bounds.x >= -1.0 && bounds.x + bounds.w <= 1405.0,
                "{bounds:?}"
            );
            assert!(
                bounds.y >= -1.0 && bounds.y + bounds.h <= 1873.0,
                "{bounds:?}"
            );
            assert!(!matches!(line.tool, Tool::Unknown(_)), "{:?}", line.tool);
        }
        assert!(scene.warnings.is_empty(), "{:?}", scene.warnings);
    }
}
