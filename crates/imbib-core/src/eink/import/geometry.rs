//! Scene units → PDF points.
//!
//! Calibrated against a Paper Pro (firmware 3.x, 2026-09-07): with
//! `zoomMode: bestFit` the tablet fits the page WIDTH into a frame of
//! [`PageFrame::PAPER_PRO_WIDTH`] scene units (3.115 units per point for
//! an A4 page), stroke x is measured from the page's centre line and y
//! from the page's top edge, growing downwards; a page taller than the
//! screen scrolls, so y runs past the screen height. An rM2 uses the same
//! rule with a 1404-unit frame. PDF points have their origin bottom-left.
//! `tests/fixtures/calibration` pins this: the strokes in
//! `calibration_page_v6.rm` land where `calibration-rendered.pdf` drew them.

use impress_remarkable::rm::Rect as SceneRect;

/// A rectangle in PDF points, origin bottom-left (what `bounds_json` carries).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PdfRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl PdfRect {
    pub fn union(self, other: PdfRect) -> PdfRect {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = (self.x + self.width).max(other.x + other.width);
        let y1 = (self.y + self.height).max(other.y + other.height);
        PdfRect {
            x: x0,
            y: y0,
            width: x1 - x0,
            height: y1 - y0,
        }
    }

    pub fn to_json(self) -> String {
        format!(
            "{{\"x\":{:.2},\"y\":{:.2},\"width\":{:.2},\"height\":{:.2}}}",
            self.x, self.y, self.width, self.height
        )
    }
}

/// The frame a page was drawn into.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PageFrame {
    /// Width of the frame the page is fitted into, in scene units.
    pub frame_width: f64,
    /// Where the page's top edge sits below the scene origin, in units
    /// (measured: the Paper Pro draws the page ≈ 7 pt below y = 0).
    pub top_offset: f64,
    pub pdf_w: f64,
    pub pdf_h: f64,
    /// Firmware 3: x counts from the middle of the top edge.
    pub centered_x: bool,
}

impl PageFrame {
    /// The rM2 / firmware-2 frame.
    pub const RM2_WIDTH: f64 = 1404.0;
    /// The Paper Pro frame, measured (595 pt → 1853.5 units).
    pub const PAPER_PRO_WIDTH: f64 = 1853.5;
    /// The Paper Pro's page-top offset, measured (≈ 6.9 pt × 3.115).
    pub const PAPER_PRO_TOP_OFFSET: f64 = 21.7;

    /// The Paper Pro screen, in scene units, for a page with no PDF
    /// behind it (a notebook the tablet created): 1620 × 2160 px drawn
    /// 1:1. ASSUMPTION — not yet pinned by a fixture; typed text and ink
    /// OCR do not depend on it, only where ink rows land on the rendered
    /// page.
    pub const PAPER_PRO_SCREEN_WIDTH: f64 = 1620.0;

    /// A notebook page: the tablet renders the screen as the PDF page, so
    /// the screen width maps onto the page width with no offset and, on
    /// firmware 3, x centred like everything else in the scene.
    pub fn notebook(pdf_w: f64, pdf_h: f64, centered_x: bool) -> Self {
        Self {
            frame_width: if centered_x {
                Self::PAPER_PRO_SCREEN_WIDTH
            } else {
                Self::RM2_WIDTH
            },
            top_offset: 0.0,
            pdf_w,
            pdf_h,
            centered_x,
        }
    }

    /// `bestFit` as the tablet applies it to a PDF page: fit to width.
    pub fn best_fit(pdf_w: f64, pdf_h: f64, centered_x: bool) -> Self {
        Self {
            frame_width: Self::PAPER_PRO_WIDTH,
            top_offset: if centered_x {
                Self::PAPER_PRO_TOP_OFFSET
            } else {
                0.0
            },
            pdf_w,
            pdf_h,
            centered_x,
        }
    }

    pub fn with_frame_width(mut self, frame_width: f64) -> Self {
        self.frame_width = frame_width;
        self
    }
}

/// The affine map for one page.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SceneToPdf {
    /// Scene units per PDF point.
    scale: f64,
    frame: PageFrame,
}

impl SceneToPdf {
    pub fn fit(frame: PageFrame) -> Self {
        Self {
            scale: frame.frame_width / frame.pdf_w,
            frame,
        }
    }

    /// Scene units per point.
    pub fn scale(&self) -> f64 {
        self.scale
    }

    /// One point: (x, y) in scene units → (x, y) in PDF points.
    pub fn point(&self, x: f64, y: f64) -> (f64, f64) {
        let from_left = if self.frame.centered_x {
            x + self.frame.frame_width / 2.0
        } else {
            x
        };
        let pdf_x = from_left / self.scale;
        let pdf_y = self.frame.pdf_h - (y - self.frame.top_offset) / self.scale;
        (pdf_x, pdf_y)
    }

    /// A scene rectangle (top-left origin, y down) → PDF rect (bottom-left).
    pub fn rect(&self, rect: SceneRect) -> PdfRect {
        let (x0, y_top) = self.point(rect.x, rect.y);
        let (x1, y_bottom) = self.point(rect.x + rect.w, rect.y + rect.h);
        PdfRect {
            x: x0.min(x1),
            y: y_bottom.min(y_top),
            width: (x1 - x0).abs(),
            height: (y_top - y_bottom).abs(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_remarkable::rm::parse_rm;

    #[test]
    fn a4_fit_to_width_maps_corners_and_flips_y() {
        let map = SceneToPdf::fit(PageFrame::best_fit(595.0, 842.0, true));
        let scale = PageFrame::PAPER_PRO_WIDTH / 595.0;
        assert!((map.scale() - scale).abs() < 1e-9);
        // Top-left corner of the page sits `top_offset` below the origin.
        let top = PageFrame::PAPER_PRO_TOP_OFFSET;
        let (x, y) = map.point(-PageFrame::PAPER_PRO_WIDTH / 2.0, top);
        assert!(x.abs() < 1e-6 && (y - 842.0).abs() < 1e-6, "{x} {y}");
        // Bottom-right corner: the page bottom is 842 × scale units lower.
        let (x, y) = map.point(PageFrame::PAPER_PRO_WIDTH / 2.0, top + 842.0 * scale);
        assert!((x - 595.0).abs() < 1e-6 && y.abs() < 1e-6, "{x} {y}");
        // A firmware-2 file counts x from the left edge.
        let map2 =
            SceneToPdf::fit(PageFrame::best_fit(595.0, 842.0, false).with_frame_width(1404.0));
        let (x, _) = map2.point(0.0, 100.0);
        assert!(x.abs() < 1e-6);
    }

    #[test]
    fn rects_keep_their_size_and_flip_into_pdf_space() {
        let map = SceneToPdf::fit(PageFrame::best_fit(595.0, 842.0, true));
        let rect = map.rect(SceneRect {
            x: -100.0,
            y: 200.0,
            w: 200.0,
            h: 50.0,
        });
        assert!((rect.width - 200.0 / map.scale()).abs() < 1e-6);
        assert!((rect.height - 50.0 / map.scale()).abs() < 1e-6);
        let expected_top = 842.0 - (200.0 - PageFrame::PAPER_PRO_TOP_OFFSET) / map.scale();
        assert!((rect.y + rect.height - expected_top).abs() < 1e-6);
        assert!(rect.to_json().starts_with("{\"x\":"));
    }

    /// The calibration page: every stroke the Paper Pro recorded must land
    /// where the tablet itself drew it into the rendered PDF (marks span
    /// x 100.45–483.84 and y 104.24–508.64 pt, marker width included).
    #[test]
    fn the_calibration_page_lands_where_the_tablet_rendered_it() {
        let bytes = include_bytes!(
            "../../../../impress-remarkable/tests/fixtures/calibration/calibration_page_v6.rm"
        );
        let scene = parse_rm(bytes).unwrap();
        assert!(!scene.lines.is_empty());
        let map = SceneToPdf::fit(PageFrame::best_fit(595.0, 842.0, true));
        let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        for line in &scene.lines {
            for p in &line.points {
                let (x, y) = map.point(f64::from(p.x), f64::from(p.y));
                x0 = x0.min(x);
                y0 = y0.min(y);
                x1 = x1.max(x);
                y1 = y1.max(y);
            }
        }
        // The tablet draws each stroke point as a dot; centres agree with
        // the dots to well under 2 pt in both axes.
        let tolerance = 2.0;
        assert!((x0 - 100.45).abs() < tolerance, "left {x0}");
        assert!((x1 - 483.84).abs() < tolerance, "right {x1}");
        assert!((y0 - 104.24).abs() < tolerance, "bottom {y0}");
        assert!((y1 - 508.64).abs() < tolerance, "top {y1}");
    }
}
