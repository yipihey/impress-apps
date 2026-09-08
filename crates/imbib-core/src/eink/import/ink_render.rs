//! Strokes → PNG, for the handwriting OCR pass (Vision, on the Swift side).

use impress_remarkable::rm::{Line, Rect, Tool};

/// Pixels per scene unit: ≈ 250 dpi on a 1404-unit-wide page.
pub const PIXELS_PER_UNIT: f32 = 1.5;
const MARGIN_UNITS: f32 = 12.0;

/// The pen's nominal width in scene units before `thickness_scale`.
fn base_width(tool: Tool) -> f32 {
    match tool {
        Tool::Ballpoint => 2.0,
        Tool::Fineliner => 2.0,
        Tool::Marker => 6.0,
        Tool::Pencil => 3.0,
        Tool::MechanicalPencil => 2.0,
        Tool::Brush => 6.0,
        Tool::Highlighter => 20.0,
        Tool::Calligraphy => 4.0,
        Tool::Shader => 8.0,
        _ => 2.0,
    }
}

/// Render a group of strokes on white and encode it as PNG. `bounds` is the
/// group's union in scene units; the image is that box plus a margin.
pub fn render_png(lines: &[&Line], bounds: Rect) -> Option<Vec<u8>> {
    let width_units = bounds.w as f32 + 2.0 * MARGIN_UNITS;
    let height_units = bounds.h as f32 + 2.0 * MARGIN_UNITS;
    let width = (width_units * PIXELS_PER_UNIT).ceil().max(1.0) as u32;
    let height = (height_units * PIXELS_PER_UNIT).ceil().max(1.0) as u32;
    if width > 8192 || height > 8192 {
        return None;
    }
    let mut pixmap = tiny_skia::Pixmap::new(width, height)?;
    pixmap.fill(tiny_skia::Color::WHITE);
    let origin_x = bounds.x as f32 - MARGIN_UNITS;
    let origin_y = bounds.y as f32 - MARGIN_UNITS;

    for line in lines {
        if line.points.len() < 2 || line.tool.is_eraser() {
            continue;
        }
        let mut path = tiny_skia::PathBuilder::new();
        let first = line.points[0];
        path.move_to(
            (first.x - origin_x) * PIXELS_PER_UNIT,
            (first.y - origin_y) * PIXELS_PER_UNIT,
        );
        for point in &line.points[1..] {
            path.line_to(
                (point.x - origin_x) * PIXELS_PER_UNIT,
                (point.y - origin_y) * PIXELS_PER_UNIT,
            );
        }
        let Some(path) = path.finish() else { continue };
        let mut paint = tiny_skia::Paint::default();
        paint.set_color(tiny_skia::Color::BLACK);
        paint.anti_alias = true;
        let stroke = tiny_skia::Stroke {
            width: (base_width(line.tool) * line.thickness_scale as f32 * PIXELS_PER_UNIT).max(1.0),
            line_cap: tiny_skia::LineCap::Round,
            line_join: tiny_skia::LineJoin::Round,
            ..Default::default()
        };
        pixmap.stroke_path(
            &path,
            &paint,
            &stroke,
            tiny_skia::Transform::identity(),
            None,
        );
    }
    pixmap.encode_png().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_remarkable::rm::Point;

    #[test]
    fn a_stroke_renders_to_a_png_with_dark_pixels() {
        let line = Line {
            id: None,
            layer: 0,
            tool: Tool::Ballpoint,
            color: 0,
            rgba: None,
            thickness_scale: 1.0,
            points: (0..20)
                .map(|i| Point {
                    x: 100.0 + i as f32 * 5.0,
                    y: 200.0 + (i as f32 * 0.7).sin() * 10.0,
                    ..Default::default()
                })
                .collect(),
        };
        let bounds = line.bounds().unwrap();
        let png = render_png(&[&line], bounds).expect("png");
        assert!(png.starts_with(b"\x89PNG"));
        // Decode back and count dark pixels.
        let pixmap = tiny_skia::Pixmap::decode_png(&png).unwrap();
        let dark = pixmap.pixels().iter().filter(|p| p.red() < 128).count();
        assert!(dark > 50, "{dark} dark pixels");
        assert!(dark < pixmap.pixels().len() / 2, "mostly white");
    }
}
