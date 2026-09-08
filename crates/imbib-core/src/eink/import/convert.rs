//! A parsed page → the annotation rows it implies.
//!
//! Highlights (`GlyphRange`, and highlighter strokes) become `highlight`
//! rows on the source PDF page; typed text becomes a `note`; every other
//! pen stroke is clustered into ink groups, one `ink` row each, with a PNG
//! for the OCR pass. Ids are derived from the tablet's own item ids so a
//! re-import updates rather than duplicates.

use impress_remarkable::rm::{color_hex, GlyphRange, Line, Rect, RmScene, Tool};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::geometry::{PdfRect, SceneToPdf};
use super::ink_render;

/// Namespace for the stable ids: `uuid5(EINK_NS, "{remote}|{page}|{kind}|{item}")`.
pub fn eink_namespace() -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, b"imbib://eink/annotation")
}

pub fn stable_id(remote_id: &str, page_id: &str, kind: &str, item: &str) -> Uuid {
    Uuid::new_v5(
        &eink_namespace(),
        format!("{remote_id}|{page_id}|{kind}|{item}").as_bytes(),
    )
}

/// What to import from a page.
#[derive(Debug, Clone, Copy)]
pub struct ConvertOptions {
    pub highlights: bool,
    pub ink: bool,
    pub typed_text: bool,
    pub render_ink: bool,
}

impl Default for ConvertOptions {
    fn default() -> Self {
        Self {
            highlights: true,
            ink: true,
            typed_text: true,
            render_ink: true,
        }
    }
}

/// One row-to-be.
#[derive(Debug, Clone, PartialEq)]
pub struct AnnotationDraft {
    pub id: Uuid,
    /// `highlight`, `ink` or `note`.
    pub annotation_type: &'static str,
    /// 0-based page of the source PDF.
    pub page_number: i64,
    pub bounds: Option<PdfRect>,
    pub color: Option<String>,
    pub contents: Option<String>,
    pub selected_text: Option<String>,
    pub source_page_id: String,
    pub source_item_id: String,
    pub pen: Option<String>,
    /// Fingerprint of the strokes behind an ink row; unchanged strokes keep
    /// their OCR text across re-imports.
    pub strokes_hash: Option<String>,
    pub png: Option<Vec<u8>>,
}

fn scene_bounds(lines: &[&Line]) -> Option<Rect> {
    let mut iter = lines.iter().filter_map(|l| l.bounds());
    let first = iter.next()?;
    Some(iter.fold(first, Rect::union))
}

fn expanded(rect: Rect, by: f64) -> Rect {
    Rect {
        x: rect.x - by,
        y: rect.y - by,
        w: rect.w + 2.0 * by,
        h: rect.h + 2.0 * by,
    }
}

fn intersects(a: Rect, b: Rect) -> bool {
    a.x <= b.x + b.w && b.x <= a.x + a.w && a.y <= b.y + b.h && b.y <= a.y + a.h
}

/// Cluster strokes whose (padded) bounds touch — a word or a line of
/// handwriting ends up in one group. Returns indices into `lines`.
pub fn ink_groups(lines: &[&Line]) -> Vec<Vec<usize>> {
    let n = lines.len();
    if n == 0 {
        return Vec::new();
    }
    let bounds: Vec<Rect> = lines
        .iter()
        .map(|l| l.bounds().unwrap_or_default())
        .collect();
    let heights: Vec<f64> = bounds.iter().map(|b| b.h.max(b.w).max(4.0)).collect();
    let mut sorted = heights.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = sorted[sorted.len() / 2];
    let pad = (median * 0.75).clamp(6.0, 60.0);

    let mut parent: Vec<usize> = (0..n).collect();
    fn find(parent: &mut [usize], i: usize) -> usize {
        let mut root = i;
        while parent[root] != root {
            root = parent[root];
        }
        let mut j = i;
        while parent[j] != root {
            let next = parent[j];
            parent[j] = root;
            j = next;
        }
        root
    }
    for i in 0..n {
        for j in (i + 1)..n {
            if intersects(expanded(bounds[i], pad), expanded(bounds[j], pad)) {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                if a != b {
                    parent[a] = b;
                }
            }
        }
    }
    let mut groups: Vec<(usize, Vec<usize>)> = Vec::new();
    for i in 0..n {
        let root = find(&mut parent, i);
        match groups.iter_mut().find(|(r, _)| *r == root) {
            Some((_, members)) => members.push(i),
            None => groups.push((root, vec![i])),
        }
    }
    groups.into_iter().map(|(_, members)| members).collect()
}

fn line_key(line: &Line, index: usize) -> String {
    match line.id {
        Some(id) => id.to_string(),
        None => format!("stroke-{index}"),
    }
}

fn strokes_hash(group: &[&Line], keys: &[String]) -> String {
    let mut hasher = Sha256::new();
    for (line, key) in group.iter().zip(keys) {
        hasher.update(key.as_bytes());
        hasher.update(line.points.len().to_le_bytes());
        if let (Some(first), Some(last)) = (line.points.first(), line.points.last()) {
            hasher.update(first.x.to_le_bytes());
            hasher.update(first.y.to_le_bytes());
            hasher.update(last.x.to_le_bytes());
            hasher.update(last.y.to_le_bytes());
        }
    }
    format!("{:x}", hasher.finalize())
}

/// Convert one page. `map` is `None` for a page with no PDF behind it (a
/// notebook page): rows then carry no bounds.
pub fn convert_page(
    remote_id: &str,
    page_id: &str,
    page_number: i64,
    scene: &RmScene,
    map: Option<&SceneToPdf>,
    options: &ConvertOptions,
) -> Vec<AnnotationDraft> {
    let mut drafts = Vec::new();

    if options.highlights {
        for glyph in &scene.glyph_ranges {
            drafts.push(glyph_draft(remote_id, page_id, page_number, glyph, map));
        }
        for (index, line) in scene
            .lines
            .iter()
            .enumerate()
            .filter(|(_, l)| l.tool == Tool::Highlighter)
        {
            let key = line_key(line, index);
            drafts.push(AnnotationDraft {
                id: stable_id(remote_id, page_id, "highlighter", &key),
                annotation_type: "highlight",
                page_number,
                bounds: line.bounds().map(|b| match map {
                    Some(map) => map.rect(b),
                    None => scene_rect_as_pdf(b),
                }),
                color: Some(color_hex(line.color).to_string()),
                contents: None,
                selected_text: None,
                source_page_id: page_id.to_string(),
                source_item_id: key,
                pen: Some(line.tool.name()),
                strokes_hash: None,
                png: None,
            });
        }
    }

    if options.ink {
        // Keys are the tablet's item ids, or the stroke's position in the
        // page for firmware-2 files (unique per page either way).
        let ink: Vec<(String, &Line)> = scene
            .lines
            .iter()
            .enumerate()
            .filter(|(_, l)| {
                l.tool != Tool::Highlighter && !l.tool.is_eraser() && l.points.len() > 1
            })
            .map(|(index, l)| (line_key(l, index), l))
            .collect();
        let ink_lines: Vec<&Line> = ink.iter().map(|(_, l)| *l).collect();
        for members in ink_groups(&ink_lines) {
            let group: Vec<&Line> = members.iter().map(|&i| ink_lines[i]).collect();
            let keys: Vec<String> = members.iter().map(|&i| ink[i].0.clone()).collect();
            let item_key = keys.iter().min().cloned().unwrap_or_else(|| "ink".into());
            let bounds = scene_bounds(&group);
            let png = if options.render_ink {
                bounds.and_then(|b| ink_render::render_png(&group, b))
            } else {
                None
            };
            let dominant = group
                .iter()
                .map(|l| l.tool)
                .fold(
                    std::collections::BTreeMap::<String, usize>::new(),
                    |mut acc, t| {
                        *acc.entry(t.name()).or_default() += 1;
                        acc
                    },
                )
                .into_iter()
                .max_by_key(|(_, n)| *n)
                .map(|(name, _)| name);
            drafts.push(AnnotationDraft {
                id: stable_id(remote_id, page_id, "ink", &item_key),
                annotation_type: "ink",
                page_number,
                bounds: bounds.map(|b| match map {
                    Some(map) => map.rect(b),
                    None => scene_rect_as_pdf(b),
                }),
                color: group.first().map(|l| color_hex(l.color).to_string()),
                contents: None,
                selected_text: None,
                source_page_id: page_id.to_string(),
                source_item_id: item_key,
                pen: dominant,
                strokes_hash: Some(strokes_hash(&group, &keys)),
                png,
            });
        }
    }

    if options.typed_text {
        if let Some(root) = &scene.root_text {
            let text = root.text();
            if !text.trim().is_empty() {
                let bounds = map.map(|map| {
                    let height = 40.0 * root.paragraphs.len().max(1) as f64;
                    map.rect(Rect {
                        x: root.pos_x,
                        y: root.pos_y,
                        w: f64::from(root.width).max(10.0),
                        h: height,
                    })
                });
                drafts.push(AnnotationDraft {
                    id: stable_id(remote_id, page_id, "text", &root.id.to_string()),
                    annotation_type: "note",
                    page_number,
                    bounds,
                    color: None,
                    contents: Some(text),
                    selected_text: None,
                    source_page_id: page_id.to_string(),
                    source_item_id: root.id.to_string(),
                    pen: Some("keyboard".into()),
                    strokes_hash: None,
                    png: None,
                });
            }
        }
    }

    drafts
}

fn glyph_draft(
    remote_id: &str,
    page_id: &str,
    page_number: i64,
    glyph: &GlyphRange,
    map: Option<&SceneToPdf>,
) -> AnnotationDraft {
    let bounds = glyph.bounds().map(|b| match map {
        Some(map) => map.rect(b),
        None => scene_rect_as_pdf(b),
    });
    AnnotationDraft {
        id: stable_id(remote_id, page_id, "glyph", &glyph.id.to_string()),
        annotation_type: "highlight",
        page_number,
        bounds,
        color: Some(color_hex(glyph.color).to_string()),
        contents: None,
        selected_text: (!glyph.text.trim().is_empty()).then(|| glyph.text.trim().to_string()),
        source_page_id: page_id.to_string(),
        source_item_id: glyph.id.to_string(),
        pen: Some("highlighter".into()),
        strokes_hash: None,
        png: None,
    }
}

/// Without a PDF behind the page, keep scene units (top-left origin) so a
/// reader can still place the row relative to the rendered page.
fn scene_rect_as_pdf(rect: Rect) -> PdfRect {
    PdfRect {
        x: rect.x,
        y: rect.y,
        width: rect.w,
        height: rect.h,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_remarkable::rm::{CrdtId, Paragraph, Point, RootText};

    fn stroke(id: u64, x: f32, y: f32, tool: Tool) -> Line {
        Line {
            id: Some(CrdtId {
                part1: 1,
                part2: id,
            }),
            layer: 0,
            tool,
            color: 0,
            rgba: None,
            thickness_scale: 1.0,
            points: vec![
                Point {
                    x,
                    y,
                    ..Default::default()
                },
                Point {
                    x: x + 30.0,
                    y: y + 5.0,
                    ..Default::default()
                },
            ],
        }
    }

    #[test]
    fn nearby_strokes_form_one_group_and_far_ones_another() {
        let a = stroke(1, 0.0, 0.0, Tool::Ballpoint);
        let b = stroke(2, 20.0, 2.0, Tool::Ballpoint);
        let c = stroke(3, 600.0, 900.0, Tool::Fineliner);
        let lines = [&a, &b, &c];
        let groups = ink_groups(&lines);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0], vec![0, 1]);
        assert_eq!(groups[1], vec![2]);
    }

    #[test]
    fn a_page_yields_highlight_ink_and_note_rows_with_stable_ids() {
        let scene = RmScene {
            version: 6,
            lines: vec![
                stroke(1, 0.0, 0.0, Tool::Ballpoint),
                stroke(2, 10.0, 1.0, Tool::Ballpoint),
                stroke(3, 100.0, 500.0, Tool::Highlighter),
                stroke(4, 0.0, 0.0, Tool::Eraser),
            ],
            glyph_ranges: vec![GlyphRange {
                id: CrdtId { part1: 1, part2: 9 },
                start: 0,
                length: 11,
                color: 3,
                text: "CALIBRATION".into(),
                rects: vec![Rect {
                    x: -400.0,
                    y: 300.0,
                    w: 200.0,
                    h: 30.0,
                }],
            }],
            root_text: Some(RootText {
                id: CrdtId { part1: 0, part2: 1 },
                paragraphs: vec![Paragraph {
                    style: 0,
                    text: "typed line one".into(),
                }],
                pos_x: -468.0,
                pos_y: 234.0,
                width: 936.0,
            }),
            ..Default::default()
        };
        let map = SceneToPdf::fit(super::super::geometry::PageFrame::best_fit(
            595.0, 842.0, true,
        ));
        let drafts = convert_page(
            "remote-1",
            "page-a",
            0,
            &scene,
            Some(&map),
            &ConvertOptions::default(),
        );
        let kinds: Vec<&str> = drafts.iter().map(|d| d.annotation_type).collect();
        assert_eq!(kinds, vec!["highlight", "highlight", "ink", "note"]);
        let glyph = &drafts[0];
        assert_eq!(glyph.selected_text.as_deref(), Some("CALIBRATION"));
        assert_eq!(glyph.color.as_deref(), Some("#ffff00"));
        assert!(glyph.bounds.is_some());
        let ink = &drafts[2];
        assert!(ink.png.as_ref().is_some_and(|p| p.starts_with(b"\x89PNG")));
        assert!(ink.strokes_hash.is_some());
        assert_eq!(ink.pen.as_deref(), Some("ballpoint"));
        assert_eq!(drafts[3].contents.as_deref(), Some("typed line one"));

        // Same input, same ids.
        let again = convert_page(
            "remote-1",
            "page-a",
            0,
            &scene,
            Some(&map),
            &ConvertOptions::default(),
        );
        assert_eq!(
            drafts.iter().map(|d| d.id).collect::<Vec<_>>(),
            again.iter().map(|d| d.id).collect::<Vec<_>>()
        );
        assert_ne!(
            stable_id("remote-1", "page-a", "glyph", "1:9"),
            stable_id("remote-2", "page-a", "glyph", "1:9")
        );
    }
}
