//! Bidirectional source ↔ render mapping for direct manipulation editing
//!
//! This module provides the infrastructure for mapping between Typst source code
//! positions and rendered PDF/output positions. This enables "Mode A" direct PDF
//! editing where users click on the rendered document and edit at that location.
//!
//! # Architecture
//!
//! The source map maintains a spatial index (conceptually an R-tree) that maps:
//! - **Source → Render**: A span of source code maps to one or more rendered regions
//! - **Render → Source**: A position in the PDF maps back to source code location
//!
//! This bidirectional mapping enables:
//! - Click-to-edit in the PDF preview
//! - Synchronized scrolling between source and preview
//! - Highlighting corresponding regions in both views
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::sourcemap::{SourceMap, SourceSpan, RenderPosition};
//!
//! let map = SourceMap::new();
//!
//! // User clicks on PDF at page 1, position (100, 200)
//! let click_pos = RenderPosition { page: 1, x: 100.0, y: 200.0 };
//! if let Some(span) = map.render_to_source(click_pos) {
//!     // Move cursor to source position span.start
//! }
//! ```

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::ops::Range;

/// A span in the source code (byte offsets).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SourceSpan {
    /// Start byte offset (inclusive)
    pub start: usize,
    /// End byte offset (exclusive)
    pub end: usize,
}

impl SourceSpan {
    /// Create a new source span.
    pub fn new(start: usize, end: usize) -> Self {
        Self { start, end }
    }

    /// Create a span representing a cursor position (zero-width).
    pub fn cursor(pos: usize) -> Self {
        Self { start: pos, end: pos }
    }

    /// Get the length of the span.
    pub fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }

    /// Check if this is a zero-width span (cursor position).
    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }

    /// Check if this span contains a position.
    pub fn contains(&self, pos: usize) -> bool {
        pos >= self.start && pos < self.end
    }

    /// Check if this span overlaps with another.
    pub fn overlaps(&self, other: &SourceSpan) -> bool {
        self.start < other.end && other.start < self.end
    }

    /// Get the intersection of two spans.
    pub fn intersection(&self, other: &SourceSpan) -> Option<SourceSpan> {
        if self.overlaps(other) {
            Some(SourceSpan {
                start: self.start.max(other.start),
                end: self.end.min(other.end),
            })
        } else {
            None
        }
    }

    /// Extend this span to include another.
    pub fn union(&self, other: &SourceSpan) -> SourceSpan {
        SourceSpan {
            start: self.start.min(other.start),
            end: self.end.max(other.end),
        }
    }

    /// Convert to a Range.
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }
}

impl From<Range<usize>> for SourceSpan {
    fn from(range: Range<usize>) -> Self {
        SourceSpan::new(range.start, range.end)
    }
}

impl From<SourceSpan> for Range<usize> {
    fn from(span: SourceSpan) -> Self {
        span.start..span.end
    }
}

/// A position in the rendered output (PDF coordinates).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RenderPosition {
    /// Page number (1-indexed)
    pub page: u32,
    /// X coordinate in points from left edge
    pub x: f64,
    /// Y coordinate in points from top edge
    pub y: f64,
}

impl RenderPosition {
    /// Create a new render position.
    pub fn new(page: u32, x: f64, y: f64) -> Self {
        Self { page, x, y }
    }

    /// Calculate distance to another position (on the same page).
    pub fn distance_to(&self, other: &RenderPosition) -> f64 {
        if self.page != other.page {
            return f64::INFINITY;
        }
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        (dx * dx + dy * dy).sqrt()
    }
}

impl Default for RenderPosition {
    fn default() -> Self {
        Self { page: 1, x: 0.0, y: 0.0 }
    }
}

/// A bounding box in rendered coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct BoundingBox {
    /// Left edge (x minimum)
    pub x: f64,
    /// Top edge (y minimum)
    pub y: f64,
    /// Width
    pub width: f64,
    /// Height
    pub height: f64,
}

impl BoundingBox {
    /// Create a new bounding box.
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    /// Create a bounding box from corner coordinates.
    pub fn from_corners(x1: f64, y1: f64, x2: f64, y2: f64) -> Self {
        Self {
            x: x1.min(x2),
            y: y1.min(y2),
            width: (x2 - x1).abs(),
            height: (y2 - y1).abs(),
        }
    }

    /// Get the right edge (x maximum).
    pub fn right(&self) -> f64 {
        self.x + self.width
    }

    /// Get the bottom edge (y maximum).
    pub fn bottom(&self) -> f64 {
        self.y + self.height
    }

    /// Get the center point.
    pub fn center(&self) -> (f64, f64) {
        (self.x + self.width / 2.0, self.y + self.height / 2.0)
    }

    /// Check if this box contains a point.
    pub fn contains_point(&self, x: f64, y: f64) -> bool {
        x >= self.x && x <= self.right() && y >= self.y && y <= self.bottom()
    }

    /// Check if this box overlaps with another.
    pub fn overlaps(&self, other: &BoundingBox) -> bool {
        self.x < other.right()
            && self.right() > other.x
            && self.y < other.bottom()
            && self.bottom() > other.y
    }

    /// Get the intersection of two bounding boxes.
    pub fn intersection(&self, other: &BoundingBox) -> Option<BoundingBox> {
        if !self.overlaps(other) {
            return None;
        }

        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self.right().min(other.right());
        let bottom = self.bottom().min(other.bottom());

        Some(BoundingBox::new(x, y, right - x, bottom - y))
    }

    /// Get the union of two bounding boxes.
    pub fn union(&self, other: &BoundingBox) -> BoundingBox {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        let right = self.right().max(other.right());
        let bottom = self.bottom().max(other.bottom());

        BoundingBox::new(x, y, right - x, bottom - y)
    }

    /// Expand the bounding box by a margin.
    pub fn expand(&self, margin: f64) -> BoundingBox {
        BoundingBox::new(
            self.x - margin,
            self.y - margin,
            self.width + 2.0 * margin,
            self.height + 2.0 * margin,
        )
    }

    /// Get the area of the bounding box.
    pub fn area(&self) -> f64 {
        self.width * self.height
    }
}

impl Default for BoundingBox {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        }
    }
}

/// A region in the rendered output (page + bounding box).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderRegion {
    /// Page number (1-indexed)
    pub page: u32,
    /// Bounding box on the page
    pub bbox: BoundingBox,
}

impl RenderRegion {
    /// Create a new render region.
    pub fn new(page: u32, bbox: BoundingBox) -> Self {
        Self { page, bbox }
    }

    /// Check if this region contains a position.
    pub fn contains(&self, pos: &RenderPosition) -> bool {
        self.page == pos.page && self.bbox.contains_point(pos.x, pos.y)
    }

    /// Check if this region overlaps with another.
    pub fn overlaps(&self, other: &RenderRegion) -> bool {
        self.page == other.page && self.bbox.overlaps(&other.bbox)
    }
}

/// A mapping entry connecting source span to rendered region(s).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceMapEntry {
    /// The source span
    pub source: SourceSpan,
    /// The rendered regions (may span multiple pages)
    pub regions: Vec<RenderRegion>,
    /// Type of content (for cursor placement hints)
    pub content_type: ContentType,
}

/// Type of content for cursor placement decisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ContentType {
    /// Normal text content
    Text,
    /// Heading (section, subsection, etc.)
    Heading,
    /// Math content (inline or display)
    Math,
    /// Code block
    Code,
    /// Figure or image
    Figure,
    /// Table content
    Table,
    /// Citation reference
    Citation,
    /// List item
    ListItem,
    /// Paragraph break
    ParagraphBreak,
    /// Other content
    Other,
}

impl Default for ContentType {
    fn default() -> Self {
        ContentType::Text
    }
}

/// Cursor position information after snapping to a valid location.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CursorPosition {
    /// Source offset for the cursor
    pub source_offset: usize,
    /// Visual position in the rendered output
    pub render_pos: RenderPosition,
    /// Type of content at this position
    pub content_type: ContentType,
    /// Whether this is at the start of the content
    pub at_start: bool,
    /// Whether this is at the end of the content
    pub at_end: bool,
}

/// Bidirectional mapping between source and rendered positions.
///
/// The source map is built from Typst compilation output and provides
/// efficient lookup in both directions:
/// - Source position → Rendered region(s)
/// - Rendered position → Source position
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct SourceMap {
    /// Entries sorted by source start position
    entries: Vec<SourceMapEntry>,
    /// Index of entries by page for spatial queries
    page_index: BTreeMap<u32, Vec<usize>>,
    /// Total pages in the document
    page_count: u32,
    /// Document length in source bytes
    source_length: usize,
    /// Whether the map has been invalidated and needs rebuild
    dirty: bool,
}

impl SourceMap {
    /// Create a new empty source map.
    pub fn new() -> Self {
        Self::default()
    }

    /// Build a source map from entries.
    pub fn from_entries(entries: Vec<SourceMapEntry>) -> Self {
        let mut map = Self {
            entries,
            page_index: BTreeMap::new(),
            page_count: 0,
            source_length: 0,
            dirty: false,
        };
        map.rebuild_index();
        map
    }

    /// Add an entry to the source map.
    pub fn add_entry(&mut self, entry: SourceMapEntry) {
        // Update source length
        self.source_length = self.source_length.max(entry.source.end);

        // Update page count
        for region in &entry.regions {
            self.page_count = self.page_count.max(region.page);
        }

        // Insert entry maintaining sort order
        let pos = self.entries
            .binary_search_by_key(&entry.source.start, |e| e.source.start)
            .unwrap_or_else(|i| i);
        self.entries.insert(pos, entry);

        // Mark for index rebuild
        self.dirty = true;
    }

    /// Rebuild the spatial index.
    fn rebuild_index(&mut self) {
        self.page_index.clear();
        self.page_count = 0;
        self.source_length = 0;

        for (idx, entry) in self.entries.iter().enumerate() {
            self.source_length = self.source_length.max(entry.source.end);

            for region in &entry.regions {
                self.page_count = self.page_count.max(region.page);
                self.page_index
                    .entry(region.page)
                    .or_default()
                    .push(idx);
            }
        }

        self.dirty = false;
    }

    /// Ensure the index is up to date.
    fn ensure_index(&mut self) {
        if self.dirty {
            self.rebuild_index();
        }
    }

    /// Map a source span to rendered regions.
    ///
    /// A source span may map to multiple regions if it spans multiple
    /// pages or if the content wraps.
    pub fn source_to_render(&mut self, span: SourceSpan) -> Vec<RenderRegion> {
        self.ensure_index();

        let mut regions = Vec::new();

        for entry in &self.entries {
            if entry.source.overlaps(&span) {
                regions.extend(entry.regions.iter().cloned());
            }
        }

        // Sort by page, then by y position
        regions.sort_by(|a, b| {
            a.page.cmp(&b.page)
                .then_with(|| a.bbox.y.partial_cmp(&b.bbox.y).unwrap_or(std::cmp::Ordering::Equal))
        });

        // Remove duplicates
        regions.dedup_by(|a, b| a.page == b.page && a.bbox == b.bbox);

        regions
    }

    /// Map a render position to a source span.
    ///
    /// Returns the source span containing the clicked position, if any.
    pub fn render_to_source(&mut self, pos: RenderPosition) -> Option<SourceSpan> {
        self.ensure_index();

        // Get entries on this page
        let entry_indices = self.page_index.get(&pos.page)?;

        // Find entries whose regions contain the position
        let mut best_entry: Option<&SourceMapEntry> = None;
        let mut best_area = f64::INFINITY;

        for &idx in entry_indices {
            let entry = &self.entries[idx];
            for region in &entry.regions {
                if region.contains(&pos) {
                    // Prefer smaller regions (more specific)
                    let area = region.bbox.area();
                    if area < best_area {
                        best_area = area;
                        best_entry = Some(entry);
                    }
                }
            }
        }

        best_entry.map(|e| e.source)
    }

    /// Find the nearest valid cursor position to a click.
    ///
    /// This is used for Mode A editing where the user clicks on the PDF
    /// and we need to find where to place the cursor.
    pub fn snap_to_cursor(&mut self, pos: RenderPosition) -> Option<CursorPosition> {
        self.ensure_index();

        // First try exact hit
        if let Some(span) = self.render_to_source(pos) {
            // Find the entry to get content type
            let entry = self.entries.iter().find(|e| e.source == span)?;

            // Calculate cursor position within the span
            // For simplicity, place at the start
            return Some(CursorPosition {
                source_offset: span.start,
                render_pos: pos,
                content_type: entry.content_type,
                at_start: true,
                at_end: span.is_empty(),
            });
        }

        // No exact hit - find nearest entry on this page
        let entry_indices = self.page_index.get(&pos.page)?;

        let mut best_entry: Option<&SourceMapEntry> = None;
        let mut best_distance = f64::INFINITY;
        let mut best_region_center = (0.0, 0.0);

        for &idx in entry_indices {
            let entry = &self.entries[idx];
            for region in &entry.regions {
                if region.page != pos.page {
                    continue;
                }

                let center = region.bbox.center();
                let dist = ((pos.x - center.0).powi(2) + (pos.y - center.1).powi(2)).sqrt();

                if dist < best_distance {
                    best_distance = dist;
                    best_entry = Some(entry);
                    best_region_center = center;
                }
            }
        }

        let entry = best_entry?;

        // Determine if we're closer to the start or end
        let at_start = pos.x <= best_region_center.0;

        Some(CursorPosition {
            source_offset: if at_start { entry.source.start } else { entry.source.end },
            render_pos: RenderPosition::new(pos.page, best_region_center.0, best_region_center.1),
            content_type: entry.content_type,
            at_start,
            at_end: !at_start,
        })
    }

    /// Invalidate regions affected by an edit.
    ///
    /// After editing, the source map becomes partially invalid. This method
    /// marks the affected entries for recalculation.
    pub fn invalidate(&mut self, edit_range: Range<usize>) {
        // Remove entries that overlap with the edit range
        self.entries.retain(|entry| {
            !entry.source.overlaps(&SourceSpan::from(edit_range.clone()))
        });

        // Shift entries after the edit
        let edit_len = edit_range.end - edit_range.start;

        for entry in &mut self.entries {
            if entry.source.start >= edit_range.end {
                // Entry is entirely after the edit - shift back
                entry.source.start -= edit_len;
                entry.source.end -= edit_len;
            }
        }

        self.dirty = true;
    }

    /// Get the total number of pages.
    pub fn page_count(&self) -> u32 {
        self.page_count
    }

    /// Get the source document length.
    pub fn source_length(&self) -> usize {
        self.source_length
    }

    /// Get all entries.
    pub fn entries(&self) -> &[SourceMapEntry] {
        &self.entries
    }

    /// Check if the map is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Clear the source map.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.page_index.clear();
        self.page_count = 0;
        self.source_length = 0;
        self.dirty = false;
    }

    /// Get entries for a specific page.
    pub fn entries_for_page(&mut self, page: u32) -> Vec<&SourceMapEntry> {
        self.ensure_index();

        self.page_index
            .get(&page)
            .map(|indices| {
                indices.iter().map(|&i| &self.entries[i]).collect()
            })
            .unwrap_or_default()
    }
}

#[cfg(feature = "typst-render")]
impl SourceMap {
    /// Build a source map from a Typst PagedDocument.
    ///
    /// This extracts source location information from the compiled Typst
    /// document to build the bidirectional mapping.
    pub fn from_typst_document<T>(_doc: &T) -> Self {
        // This would iterate through the document's frames and elements,
        // extracting source spans and their rendered positions.
        // The implementation depends on Typst's internal API.
        //
        // In Typst 0.14+, the document type is typst::layout::PagedDocument
        // but we use a generic here to avoid coupling to specific API versions.

        // Placeholder implementation
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_span_basic() {
        let span = SourceSpan::new(10, 20);
        assert_eq!(span.len(), 10);
        assert!(!span.is_empty());
        assert!(span.contains(10));
        assert!(span.contains(15));
        assert!(!span.contains(20));
    }

    #[test]
    fn test_source_span_cursor() {
        let span = SourceSpan::cursor(10);
        assert!(span.is_empty());
        assert_eq!(span.len(), 0);
    }

    #[test]
    fn test_source_span_overlaps() {
        let span1 = SourceSpan::new(10, 20);
        let span2 = SourceSpan::new(15, 25);
        let span3 = SourceSpan::new(20, 30);

        assert!(span1.overlaps(&span2));
        assert!(!span1.overlaps(&span3));
    }

    #[test]
    fn test_bounding_box_contains() {
        let bbox = BoundingBox::new(10.0, 20.0, 100.0, 50.0);

        assert!(bbox.contains_point(10.0, 20.0));
        assert!(bbox.contains_point(50.0, 40.0));
        assert!(bbox.contains_point(110.0, 70.0));
        assert!(!bbox.contains_point(5.0, 20.0));
        assert!(!bbox.contains_point(50.0, 100.0));
    }

    #[test]
    fn test_bounding_box_overlaps() {
        let bbox1 = BoundingBox::new(0.0, 0.0, 100.0, 100.0);
        let bbox2 = BoundingBox::new(50.0, 50.0, 100.0, 100.0);
        let bbox3 = BoundingBox::new(200.0, 0.0, 100.0, 100.0);

        assert!(bbox1.overlaps(&bbox2));
        assert!(!bbox1.overlaps(&bbox3));
    }

    #[test]
    fn test_render_region_contains() {
        let region = RenderRegion::new(1, BoundingBox::new(0.0, 0.0, 100.0, 100.0));

        assert!(region.contains(&RenderPosition::new(1, 50.0, 50.0)));
        assert!(!region.contains(&RenderPosition::new(2, 50.0, 50.0)));
        assert!(!region.contains(&RenderPosition::new(1, 150.0, 50.0)));
    }

    #[test]
    fn test_source_map_basic() {
        let mut map = SourceMap::new();

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(0, 10),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 72.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(10, 20),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 92.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        assert_eq!(map.entries().len(), 2);
        assert_eq!(map.page_count(), 1);
    }

    #[test]
    fn test_source_map_source_to_render() {
        let mut map = SourceMap::new();

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(0, 10),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 72.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        let regions = map.source_to_render(SourceSpan::new(0, 5));
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].page, 1);
    }

    #[test]
    fn test_source_map_render_to_source() {
        let mut map = SourceMap::new();

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(0, 10),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 72.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        let span = map.render_to_source(RenderPosition::new(1, 100.0, 80.0));
        assert!(span.is_some());
        assert_eq!(span.unwrap(), SourceSpan::new(0, 10));

        let span = map.render_to_source(RenderPosition::new(2, 100.0, 80.0));
        assert!(span.is_none());
    }

    #[test]
    fn test_source_map_snap_to_cursor() {
        let mut map = SourceMap::new();

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(0, 10),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 72.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        let cursor = map.snap_to_cursor(RenderPosition::new(1, 80.0, 80.0));
        assert!(cursor.is_some());
        let cursor = cursor.unwrap();
        assert_eq!(cursor.content_type, ContentType::Text);
    }

    #[test]
    fn test_source_map_invalidate() {
        let mut map = SourceMap::new();

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(0, 10),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 72.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        map.add_entry(SourceMapEntry {
            source: SourceSpan::new(20, 30),
            regions: vec![RenderRegion::new(1, BoundingBox::new(72.0, 92.0, 100.0, 20.0))],
            content_type: ContentType::Text,
        });

        // Edit range overlaps first entry
        map.invalidate(5..15);

        // First entry should be removed, second should be shifted
        assert_eq!(map.entries().len(), 1);
        assert_eq!(map.entries()[0].source.start, 10); // 20 - 10 = 10
        assert_eq!(map.entries()[0].source.end, 20);   // 30 - 10 = 20
    }
}
