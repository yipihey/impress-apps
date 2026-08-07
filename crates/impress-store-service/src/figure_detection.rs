//! Conservative figure-boundary detection from OCR layout plus page pixels.
//!
//! Captions supply semantic identity; rendered pixels supply the boundary.
//! Neither signal is accepted alone. Competing or visually empty candidates
//! become explicit ambiguous evidence instead of a guessed crop.

use std::collections::BTreeMap;

use impress_core::source::{ExtractedTextRegion, FigureRegionStatus, NormalizedRect};

pub const EXTRACTOR_NAME: &str = "impress-figure-boundary";
pub const EXTRACTOR_VERSION: &str = "1.0.0";

const PAGE_MARGIN: f64 = 0.035;
const CAPTION_GAP: f64 = 0.010;
const BODY_GAP: f64 = 0.008;
const MAX_CAPTION_DEPTH: f64 = 0.038;
const MIN_REGION_WIDTH: f64 = 0.12;
const MIN_REGION_HEIGHT: f64 = 0.055;
const MAX_REGION_HEIGHT: f64 = 0.70;

#[derive(Debug, Clone, PartialEq)]
pub struct DetectedFigureRegion {
    pub figure_label: String,
    pub caption_text: String,
    pub caption_region: NormalizedRect,
    pub image_region: Option<NormalizedRect>,
    pub status: FigureRegionStatus,
    pub confidence: f64,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone)]
struct CaptionCandidate {
    label: String,
    text: String,
    region: NormalizedRect,
}

#[derive(Debug, Clone)]
struct VisualCandidate {
    region: NormalizedRect,
    score: f64,
    ink_density: f64,
    row_coverage: f64,
    column_coverage: f64,
    text_coverage: f64,
    direction: &'static str,
}

/// Fast preflight used by importers to avoid rendering pages with no caption
/// candidates at all.
pub fn has_figure_caption(regions: &[ExtractedTextRegion]) -> bool {
    regions
        .iter()
        .any(|region| parse_caption_label(&region.text).is_some())
}

pub fn detect_figure_regions(
    regions: &[ExtractedTextRegion],
    page_png: &[u8],
) -> Result<Vec<DetectedFigureRegion>, String> {
    let image = image::load_from_memory_with_format(page_png, image::ImageFormat::Png)
        .map_err(|error| format!("decode page PNG for figure detection: {error}"))?
        .to_luma8();
    let captions = caption_candidates(regions);
    let mut grouped = BTreeMap::<String, Vec<DetectedFigureRegion>>::new();

    for caption in captions {
        let mut visual = Vec::new();
        if let Some(region) = candidate_above(&caption, regions) {
            if let Some(candidate) = analyze_candidate(&image, region, regions, &caption, "above") {
                visual.push(candidate);
            }
        }
        if let Some(region) = candidate_below(&caption, regions) {
            if let Some(candidate) = analyze_candidate(&image, region, regions, &caption, "below") {
                visual.push(candidate);
            }
        }
        visual.sort_by(|left, right| right.score.total_cmp(&left.score));

        let detection = match visual.as_slice() {
            [] => ambiguous(
                &caption,
                "no visually substantial image region adjoins the caption",
            ),
            [best, ..] if best.score < 0.34 => ambiguous(
                &caption,
                &format!(
                    "best {direction} candidate has insufficient visual support (score {score:.3})",
                    direction = best.direction,
                    score = best.score
                ),
            ),
            [best, second, ..]
                if second.score >= 0.30 && second.score >= best.score * 0.82 =>
            {
                ambiguous(
                    &caption,
                    &format!(
                        "competing {first} and {second_direction} image regions are too similar ({first_score:.3} vs {second_score:.3})",
                        first = best.direction,
                        second_direction = second.direction,
                        first_score = best.score,
                        second_score = second.score,
                    ),
                )
            }
            [best, ..] => DetectedFigureRegion {
                figure_label: caption.label.clone(),
                caption_text: caption.text.clone(),
                caption_region: caption.region,
                image_region: Some(best.region),
                status: FigureRegionStatus::Extracted,
                confidence: best.score.clamp(0.0, 1.0),
                warnings: vec![format!(
                    "automatic {direction} crop; confidence={score:.3}; ink_density={density:.3}; row_coverage={rows:.3}; column_coverage={columns:.3}; text_coverage={text:.3}",
                    direction = best.direction,
                    score = best.score,
                    density = best.ink_density,
                    rows = best.row_coverage,
                    columns = best.column_coverage,
                    text = best.text_coverage,
                )],
            },
        };
        grouped
            .entry(normalize_label_key(&detection.figure_label))
            .or_default()
            .push(detection);
    }

    Ok(grouped
        .into_values()
        .map(|mut candidates| {
            if candidates.len() == 1 {
                return candidates.remove(0);
            }
            let first = candidates.remove(0);
            DetectedFigureRegion {
                image_region: None,
                status: FigureRegionStatus::Ambiguous,
                confidence: 0.0,
                warnings: vec![format!(
                    "{} caption candidates share this label on one page",
                    candidates.len() + 1
                )],
                ..first
            }
        })
        .collect())
}

fn caption_candidates(regions: &[ExtractedTextRegion]) -> Vec<CaptionCandidate> {
    let mut captions = Vec::new();
    for start in regions {
        let Some(label) = parse_caption_label(&start.text) else {
            continue;
        };
        let mut lines = regions
            .iter()
            .filter(|candidate| {
                candidate.region.y <= start.region.y + 0.004
                    && start.region.y - candidate.region.y <= MAX_CAPTION_DEPTH
                    && horizontally_related_rect(start.region, candidate.region)
                    && parse_caption_label(&candidate.text)
                        .is_none_or(|candidate_label| candidate_label == label)
            })
            .collect::<Vec<_>>();
        lines.sort_by(|left, right| {
            right
                .region
                .y
                .total_cmp(&left.region.y)
                .then_with(|| left.region.x.total_cmp(&right.region.x))
        });
        let region = lines
            .iter()
            .fold(start.region, |union, line| union_rect(union, line.region));
        let text = lines
            .iter()
            .map(|line| line.text.trim())
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        captions.push(CaptionCandidate {
            label,
            text,
            region,
        });
    }
    captions
}

fn parse_caption_label(text: &str) -> Option<String> {
    let trimmed = text.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    let (canonical, rest) = if lower.starts_with("fig.") {
        ("Fig.", &trimmed[4..])
    } else if lower.starts_with("fig ") {
        ("Fig.", &trimmed[3..])
    } else if lower.starts_with("figure ") {
        ("Fig.", &trimmed[6..])
    } else if lower.starts_with("table ") {
        ("Table", &trimmed[5..])
    } else {
        return None;
    };
    let token = rest
        .split_whitespace()
        .next()?
        .trim_matches(|character: char| matches!(character, '.' | ':' | ';' | ',' | '(' | ')'));
    if token.is_empty()
        || !token.chars().any(|character| character.is_ascii_digit())
        || !token.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '–' | '—' | '.')
        })
    {
        return None;
    }
    Some(format!("{canonical} {token}"))
}

fn candidate_above(
    caption: &CaptionCandidate,
    regions: &[ExtractedTextRegion],
) -> Option<NormalizedRect> {
    let bottom = (caption.region.y + caption.region.height + CAPTION_GAP).min(1.0);
    let top = regions
        .iter()
        .filter(|region| is_body_boundary(region, caption))
        .filter(|region| region.region.y > bottom + MIN_REGION_HEIGHT)
        .map(|region| region.region.y - BODY_GAP)
        .filter(|top| *top > bottom)
        .min_by(f64::total_cmp)
        .unwrap_or(1.0 - PAGE_MARGIN);
    candidate_rect(caption.region, bottom, top)
}

fn candidate_below(
    caption: &CaptionCandidate,
    regions: &[ExtractedTextRegion],
) -> Option<NormalizedRect> {
    let top = (caption.region.y - CAPTION_GAP).max(0.0);
    let bottom = regions
        .iter()
        .filter(|region| is_body_boundary(region, caption))
        .map(|region| region.region.y + region.region.height + BODY_GAP)
        .filter(|bottom| *bottom < top - MIN_REGION_HEIGHT)
        .max_by(f64::total_cmp)
        .unwrap_or(PAGE_MARGIN);
    candidate_rect(caption.region, bottom, top)
}

fn candidate_rect(column: NormalizedRect, bottom: f64, top: f64) -> Option<NormalizedRect> {
    let height = top - bottom;
    if !(MIN_REGION_HEIGHT..=MAX_REGION_HEIGHT).contains(&height) {
        return None;
    }
    let x = (column.x - 0.012).max(PAGE_MARGIN);
    let right = (column.x + column.width + 0.012).min(1.0 - PAGE_MARGIN);
    NormalizedRect::new(x, bottom, right - x, height).ok()
}

fn is_body_boundary(region: &ExtractedTextRegion, caption: &CaptionCandidate) -> bool {
    if parse_caption_label(&region.text).is_some()
        || is_minor_figure_text(&region.text, region.region)
        || !horizontally_related_rect(caption.region, region.region)
    {
        return false;
    }
    region.text.trim().chars().count() >= 14 || region.region.width >= MIN_REGION_WIDTH
}

fn is_minor_figure_text(text: &str, region: NormalizedRect) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("vwoa")
        || lower.contains("copyright")
        || text.contains('©')
        || (text
            .trim()
            .chars()
            .all(|character| character.is_ascii_digit())
            && region.width < 0.08)
}

fn analyze_candidate(
    image: &image::GrayImage,
    region: NormalizedRect,
    text_regions: &[ExtractedTextRegion],
    caption: &CaptionCandidate,
    direction: &'static str,
) -> Option<VisualCandidate> {
    let (page_width, page_height) = image.dimensions();
    let (x, y, width, height) = normalized_to_pixel(region, page_width, page_height);
    if width < 8 || height < 8 {
        return None;
    }
    let step = ((u64::from(width) * u64::from(height) / 250_000).max(1) as f64)
        .sqrt()
        .ceil() as u32;
    let sampled_width = width.div_ceil(step) as usize;
    let sampled_height = height.div_ceil(step) as usize;
    let mut rows = vec![false; sampled_height];
    let mut columns = vec![false; sampled_width];
    let mut ink = 0_u64;
    let mut samples = 0_u64;
    let mut min_x = width;
    let mut min_y = height;
    let mut max_x = 0_u32;
    let mut max_y = 0_u32;
    for (sample_y, py) in (0..height).step_by(step as usize).enumerate() {
        for (sample_x, px) in (0..width).step_by(step as usize).enumerate() {
            samples += 1;
            if image.get_pixel(x + px, y + py).0[0] < 238 {
                ink += 1;
                rows[sample_y] = true;
                columns[sample_x] = true;
                min_x = min_x.min(px);
                min_y = min_y.min(py);
                max_x = max_x.max(px);
                max_y = max_y.max(py);
            }
        }
    }
    if ink == 0 || samples == 0 {
        return None;
    }
    let density = ink as f64 / samples as f64;
    let row_coverage = rows.iter().filter(|value| **value).count() as f64 / rows.len() as f64;
    let column_coverage =
        columns.iter().filter(|value| **value).count() as f64 / columns.len() as f64;
    let visual_score = (density * 1.8 + row_coverage * 0.45 + column_coverage * 0.35).min(1.0);
    // Ordinary prose can look just as dark and spatially complete as a line
    // drawing. OCR geometry distinguishes it: a column of body text occupies
    // much more of the candidate rectangle than incidental labels inside a
    // diagram. This signal only reduces confidence; it can never manufacture
    // visual support that is absent from the rendered page.
    let text_coverage = text_coverage(region, text_regions, caption);
    let prose_penalty = 1.0 - 0.85 * (text_coverage / 0.35).min(1.0);
    let score = visual_score * prose_penalty;
    if density < 0.004 || row_coverage < 0.10 || column_coverage < 0.10 {
        return Some(VisualCandidate {
            region,
            score,
            ink_density: density,
            row_coverage,
            column_coverage,
            text_coverage,
            direction,
        });
    }

    let padding = (4 * step).max(2);
    let refined_x = x + min_x.saturating_sub(padding);
    let refined_y = y + min_y.saturating_sub(padding);
    let refined_right = (x + max_x + padding).min(page_width);
    let refined_bottom = (y + max_y + padding).min(page_height);
    let refined = pixel_to_normalized(
        refined_x,
        refined_y,
        refined_right.saturating_sub(refined_x).max(1),
        refined_bottom.saturating_sub(refined_y).max(1),
        page_width,
        page_height,
    )?;
    Some(VisualCandidate {
        region: refined,
        score,
        ink_density: density,
        row_coverage,
        column_coverage,
        text_coverage,
        direction,
    })
}

fn text_coverage(
    candidate: NormalizedRect,
    regions: &[ExtractedTextRegion],
    caption: &CaptionCandidate,
) -> f64 {
    let candidate_area = candidate.width * candidate.height;
    if candidate_area <= f64::EPSILON {
        return 0.0;
    }
    let occupied = regions
        .iter()
        .filter(|region| {
            !is_minor_figure_text(&region.text, region.region)
                && parse_caption_label(&region.text).is_none()
                && region.region != caption.region
        })
        .map(|region| intersection_area(candidate, region.region))
        .sum::<f64>();
    (occupied / candidate_area).clamp(0.0, 1.0)
}

fn intersection_area(a: NormalizedRect, b: NormalizedRect) -> f64 {
    let width = ((a.x + a.width).min(b.x + b.width) - a.x.max(b.x)).max(0.0);
    let height = ((a.y + a.height).min(b.y + b.height) - a.y.max(b.y)).max(0.0);
    width * height
}

fn ambiguous(caption: &CaptionCandidate, warning: &str) -> DetectedFigureRegion {
    DetectedFigureRegion {
        figure_label: caption.label.clone(),
        caption_text: caption.text.clone(),
        caption_region: caption.region,
        image_region: None,
        status: FigureRegionStatus::Ambiguous,
        confidence: 0.0,
        warnings: vec![warning.into()],
    }
}

fn normalized_to_pixel(rect: NormalizedRect, width: u32, height: u32) -> (u32, u32, u32, u32) {
    let x = (rect.x * f64::from(width)).floor() as u32;
    let y = ((1.0 - rect.y - rect.height) * f64::from(height)).floor() as u32;
    let right = ((rect.x + rect.width) * f64::from(width)).ceil() as u32;
    let bottom = ((1.0 - rect.y) * f64::from(height)).ceil() as u32;
    (
        x.min(width.saturating_sub(1)),
        y.min(height.saturating_sub(1)),
        right.saturating_sub(x).min(width.saturating_sub(x)),
        bottom.saturating_sub(y).min(height.saturating_sub(y)),
    )
}

fn pixel_to_normalized(
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    page_width: u32,
    page_height: u32,
) -> Option<NormalizedRect> {
    NormalizedRect::new(
        f64::from(x) / f64::from(page_width),
        1.0 - f64::from(y + height) / f64::from(page_height),
        f64::from(width) / f64::from(page_width),
        f64::from(height) / f64::from(page_height),
    )
    .ok()
}

fn horizontally_related_rect(a: NormalizedRect, b: NormalizedRect) -> bool {
    let overlap = (a.x + a.width).min(b.x + b.width) - a.x.max(b.x);
    overlap > 0.02
        || ((b.x + b.width / 2.0) >= a.x - 0.03 && (b.x + b.width / 2.0) <= a.x + a.width + 0.03)
}

fn union_rect(a: NormalizedRect, b: NormalizedRect) -> NormalizedRect {
    let x = a.x.min(b.x);
    let y = a.y.min(b.y);
    NormalizedRect {
        x,
        y,
        width: (a.x + a.width).max(b.x + b.width) - x,
        height: (a.y + a.height).max(b.y + b.height) - y,
    }
}

fn normalize_label_key(label: &str) -> String {
    label
        .chars()
        .filter(|character| !character.is_whitespace() && *character != '.')
        .flat_map(char::to_lowercase)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, GrayImage, ImageFormat, Luma};
    use std::io::Cursor;

    fn region(text: &str, x: f64, y: f64, width: f64, height: f64) -> ExtractedTextRegion {
        ExtractedTextRegion {
            text: text.into(),
            confidence: Some(0.99),
            region: NormalizedRect::new(x, y, width, height).unwrap(),
        }
    }

    fn page_with_ink(rectangles: &[(u32, u32, u32, u32)]) -> Vec<u8> {
        let mut image = GrayImage::from_pixel(800, 1000, Luma([255]));
        for &(x, y, width, height) in rectangles {
            for py in y..y + height {
                for px in x..x + width {
                    let value = if (px + py) % 7 == 0 { 45 } else { 180 };
                    image.put_pixel(px, py, Luma([value]));
                }
            }
        }
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageLuma8(image)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();
        bytes.into_inner()
    }

    #[test]
    fn anchored_caption_is_parsed_but_body_reference_is_not() {
        assert_eq!(
            parse_caption_label("Fig. 4-5. Test lamp"),
            Some("Fig. 4-5".into())
        );
        assert_eq!(
            parse_caption_label("Figure 12: Wiring"),
            Some("Fig. 12".into())
        );
        assert_eq!(parse_caption_label("See Fig. 4-5 for the setup"), None);
    }

    #[test]
    fn pixels_and_layout_produce_a_refined_figure_above_its_caption() {
        let regions = vec![
            region("Procedure text above the figure", 0.54, 0.82, 0.38, 0.02),
            region(
                "Fig. 4-5. Test lamp being used to check",
                0.55,
                0.30,
                0.36,
                0.018,
            ),
            region("thermo-time switch operation.", 0.61, 0.278, 0.25, 0.016),
            region("See Fig. 4-5 in the text", 0.10, 0.70, 0.32, 0.02),
        ];
        // Pixel coordinates are top-left-origin: this is normalized
        // x=.56..=.89, y=.41..=.75 in lower-left page coordinates.
        let png = page_with_ink(&[(448, 250, 264, 340)]);
        let detected = detect_figure_regions(&regions, &png).unwrap();
        assert_eq!(detected.len(), 1);
        assert_eq!(detected[0].figure_label, "Fig. 4-5");
        assert_eq!(detected[0].status, FigureRegionStatus::Extracted);
        let crop = detected[0].image_region.unwrap();
        assert!(crop.x > 0.53 && crop.x < 0.58, "{crop:?}");
        assert!(crop.y > 0.38 && crop.y < 0.44, "{crop:?}");
        assert!(crop.height > 0.30);
        assert!(detected[0].caption_text.contains("switch operation"));
    }

    #[test]
    fn body_text_occupancy_breaks_a_visual_tie_in_favor_of_the_figure() {
        let mut regions = vec![
            region(
                "Procedure text above the illustration",
                0.55,
                0.84,
                0.36,
                0.02,
            ),
            region(
                "Fig. 4-5. Test lamp being used to check",
                0.55,
                0.43,
                0.36,
                0.018,
            ),
            region("switch operation.", 0.64, 0.408, 0.14, 0.016),
        ];
        for line in 0..12 {
            regions.push(region(
                "Dense ordinary prose beneath the caption",
                0.56,
                0.37 - f64::from(line) * 0.025,
                0.35,
                0.014,
            ));
        }
        let png = page_with_ink(&[(445, 180, 270, 360), (445, 580, 270, 330)]);
        let detected = detect_figure_regions(&regions, &png).unwrap();
        assert_eq!(detected[0].status, FigureRegionStatus::Extracted);
        assert!(detected[0].warnings[0].contains("automatic above crop"));
        assert!(detected[0].warnings[0].contains("text_coverage="));
    }

    #[test]
    fn blank_or_competing_regions_are_ambiguous() {
        let regions = vec![
            region("Body text above", 0.55, 0.80, 0.35, 0.02),
            region(
                "Fig. 2-1. A deliberately uncertain figure",
                0.55,
                0.45,
                0.35,
                0.02,
            ),
            region("Body text below", 0.55, 0.12, 0.35, 0.02),
        ];
        let blank = page_with_ink(&[]);
        let detected = detect_figure_regions(&regions, &blank).unwrap();
        assert_eq!(detected[0].status, FigureRegionStatus::Ambiguous);
        assert!(detected[0].image_region.is_none());

        let competing = page_with_ink(&[(450, 220, 250, 250), (450, 560, 250, 250)]);
        let detected = detect_figure_regions(&regions, &competing).unwrap();
        assert_eq!(detected[0].status, FigureRegionStatus::Ambiguous);
        assert!(detected[0].warnings[0].contains("competing"));
    }
}
