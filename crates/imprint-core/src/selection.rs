//! Multi-cursor selection support for collaborative editing
//!
//! This module provides the selection primitives needed for multi-cursor editing,
//! inspired by the Helix editor's selection model. It supports multiple simultaneous
//! selections, each with an anchor (fixed point) and head (cursor position).
//!
//! # Architecture
//!
//! The selection model uses:
//! - **Selection**: A single selection with anchor and head positions
//! - **SelectionSet**: A collection of selections with a designated primary
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::selection::{Selection, SelectionSet};
//!
//! // Single cursor at position 10
//! let sel = Selection::cursor(10);
//!
//! // Selection from position 5 to 15
//! let sel = Selection::new(5, 15);
//!
//! // Multiple cursors
//! let mut set = SelectionSet::single(Selection::cursor(10));
//! set.push(Selection::cursor(20));
//! set.push(Selection::cursor(30));
//! ```

use serde::{Deserialize, Serialize};
use std::cmp::{max, min};
use std::ops::Range;

/// A single selection in the document.
///
/// A selection has two positions:
/// - **anchor**: The start of the selection (stays fixed during extension)
/// - **head**: The cursor position (moves during selection extension)
///
/// When anchor == head, this represents a cursor with no selected text.
/// When anchor < head, the selection extends forward from anchor to head.
/// When anchor > head, the selection extends backward from head to anchor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Selection {
    /// The anchor point (fixed end of selection)
    pub anchor: usize,
    /// The head/cursor position (moving end of selection)
    pub head: usize,
}

impl Selection {
    /// Create a new selection from anchor to head.
    pub fn new(anchor: usize, head: usize) -> Self {
        Self { anchor, head }
    }

    /// Create a cursor (zero-width selection) at the given position.
    pub fn cursor(pos: usize) -> Self {
        Self {
            anchor: pos,
            head: pos,
        }
    }

    /// Create a selection covering a range, with the head at the end.
    pub fn from_range(range: Range<usize>) -> Self {
        Self {
            anchor: range.start,
            head: range.end,
        }
    }

    /// Check if this selection is a cursor (zero-width).
    pub fn is_cursor(&self) -> bool {
        self.anchor == self.head
    }

    /// Get the starting position (minimum of anchor and head).
    pub fn start(&self) -> usize {
        min(self.anchor, self.head)
    }

    /// Get the ending position (maximum of anchor and head).
    pub fn end(&self) -> usize {
        max(self.anchor, self.head)
    }

    /// Get the length of the selection.
    pub fn len(&self) -> usize {
        self.end() - self.start()
    }

    /// Check if the selection is empty (cursor).
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Get the selection as a Range.
    pub fn range(&self) -> Range<usize> {
        self.start()..self.end()
    }

    /// Check if this selection contains a position.
    pub fn contains(&self, pos: usize) -> bool {
        pos >= self.start() && pos < self.end()
    }

    /// Check if this selection overlaps with another.
    pub fn overlaps(&self, other: &Selection) -> bool {
        self.start() < other.end() && other.start() < self.end()
    }

    /// Check if this selection touches or overlaps with another.
    pub fn touches(&self, other: &Selection) -> bool {
        self.start() <= other.end() && other.start() <= self.end()
    }

    /// Merge this selection with another, returning a selection covering both.
    ///
    /// The anchor is preserved from `self`, and the head is at the far end.
    pub fn merge(&self, other: &Selection) -> Selection {
        let start = min(self.start(), other.start());
        let end = max(self.end(), other.end());

        // Preserve direction based on original anchor
        if self.anchor <= self.head {
            Selection::new(start, end)
        } else {
            Selection::new(end, start)
        }
    }

    /// Extend the selection to include a position.
    pub fn extend_to(&self, pos: usize) -> Selection {
        Selection::new(self.anchor, pos)
    }

    /// Move both anchor and head by a delta, clamping at 0.
    pub fn translate(&self, delta: isize) -> Selection {
        let translate_pos = |p: usize| -> usize {
            if delta < 0 {
                p.saturating_sub((-delta) as usize)
            } else {
                p.saturating_add(delta as usize)
            }
        };

        Selection::new(translate_pos(self.anchor), translate_pos(self.head))
    }

    /// Flip the selection direction (swap anchor and head).
    pub fn flip(&self) -> Selection {
        Selection::new(self.head, self.anchor)
    }

    /// Collapse the selection to a cursor at the head position.
    pub fn collapse_to_head(&self) -> Selection {
        Selection::cursor(self.head)
    }

    /// Collapse the selection to a cursor at the anchor position.
    pub fn collapse_to_anchor(&self) -> Selection {
        Selection::cursor(self.anchor)
    }

    /// Collapse the selection to a cursor at the start position.
    pub fn collapse_to_start(&self) -> Selection {
        Selection::cursor(self.start())
    }

    /// Collapse the selection to a cursor at the end position.
    pub fn collapse_to_end(&self) -> Selection {
        Selection::cursor(self.end())
    }
}

impl Default for Selection {
    fn default() -> Self {
        Selection::cursor(0)
    }
}

impl From<Range<usize>> for Selection {
    fn from(range: Range<usize>) -> Self {
        Selection::from_range(range)
    }
}

impl From<usize> for Selection {
    fn from(pos: usize) -> Self {
        Selection::cursor(pos)
    }
}

/// A set of selections, supporting multiple cursors.
///
/// One selection in the set is designated as the "primary" selection,
/// which is typically the most recently active one. Operations often
/// operate on all selections, with the primary determining where
/// results are displayed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectionSet {
    /// Index of the primary selection
    primary: usize,
    /// All selections in the set
    selections: Vec<Selection>,
}

impl SelectionSet {
    /// Create a selection set with a single selection.
    pub fn single(sel: Selection) -> Self {
        Self {
            primary: 0,
            selections: vec![sel],
        }
    }

    /// Create a selection set from multiple selections.
    ///
    /// The first selection becomes the primary.
    pub fn from_selections(selections: Vec<Selection>) -> Self {
        assert!(!selections.is_empty(), "SelectionSet cannot be empty");
        Self {
            primary: 0,
            selections,
        }
    }

    /// Create a selection set with a cursor at position 0.
    pub fn new() -> Self {
        Self::single(Selection::cursor(0))
    }

    /// Get the primary selection.
    pub fn primary(&self) -> Selection {
        self.selections[self.primary]
    }

    /// Get the primary selection index.
    pub fn primary_index(&self) -> usize {
        self.primary
    }

    /// Set the primary selection by index.
    ///
    /// Panics if index is out of bounds.
    pub fn set_primary(&mut self, index: usize) {
        assert!(index < self.selections.len(), "primary index out of bounds");
        self.primary = index;
    }

    /// Get a reference to all selections.
    pub fn selections(&self) -> &[Selection] {
        &self.selections
    }

    /// Iterate over all selections.
    pub fn iter(&self) -> impl Iterator<Item = &Selection> {
        self.selections.iter()
    }

    /// Get the number of selections.
    pub fn len(&self) -> usize {
        self.selections.len()
    }

    /// Check if there's only one selection.
    pub fn is_single(&self) -> bool {
        self.selections.len() == 1
    }

    /// Check if the set is empty (should never be true for valid sets).
    pub fn is_empty(&self) -> bool {
        self.selections.is_empty()
    }

    /// Add a new selection, making it the primary.
    pub fn push(&mut self, sel: Selection) {
        self.selections.push(sel);
        self.primary = self.selections.len() - 1;
    }

    /// Replace all selections with a single selection.
    pub fn replace(&mut self, sel: Selection) {
        self.selections.clear();
        self.selections.push(sel);
        self.primary = 0;
    }

    /// Map a function over all selections.
    pub fn map<F>(&self, mut f: F) -> Self
    where
        F: FnMut(Selection) -> Selection,
    {
        Self {
            primary: self.primary,
            selections: self.selections.iter().copied().map(&mut f).collect(),
        }
    }

    /// Transform selections by applying a function that may return multiple selections.
    pub fn flat_map<F>(&self, mut f: F) -> Self
    where
        F: FnMut(Selection) -> Vec<Selection>,
    {
        let mut new_selections = Vec::new();
        let mut new_primary = 0;

        for (i, sel) in self.selections.iter().enumerate() {
            let results = f(*sel);
            if i == self.primary {
                new_primary = new_selections.len();
            }
            new_selections.extend(results);
        }

        if new_selections.is_empty() {
            // Fallback: keep at least the primary
            new_selections.push(self.primary());
            new_primary = 0;
        }

        Self {
            primary: new_primary,
            selections: new_selections,
        }
    }

    /// Normalize the selection set by merging overlapping selections
    /// and sorting by position.
    pub fn normalize(&mut self) {
        if self.selections.len() <= 1 {
            return;
        }

        // Sort by start position
        let primary_sel = self.primary();
        self.selections.sort_by_key(|s| s.start());

        // Merge overlapping or touching selections
        let mut merged: Vec<Selection> = Vec::new();
        for sel in self.selections.drain(..) {
            if let Some(last) = merged.last_mut() {
                if last.touches(&sel) {
                    *last = last.merge(&sel);
                    continue;
                }
            }
            merged.push(sel);
        }

        self.selections = merged;

        // Update primary to the selection containing the original primary's head
        self.primary = self
            .selections
            .iter()
            .position(|s| s.contains(primary_sel.head) || s.end() == primary_sel.head)
            .unwrap_or(0);
    }

    /// Remove the primary selection, if there are multiple selections.
    ///
    /// Returns the removed selection, or None if this is the only selection.
    pub fn remove_primary(&mut self) -> Option<Selection> {
        if self.selections.len() <= 1 {
            return None;
        }

        let removed = self.selections.remove(self.primary);

        // Adjust primary index
        if self.primary >= self.selections.len() {
            self.primary = self.selections.len() - 1;
        }

        Some(removed)
    }

    /// Keep only the primary selection, removing all others.
    pub fn keep_primary_only(&mut self) {
        let primary = self.primary();
        self.selections.clear();
        self.selections.push(primary);
        self.primary = 0;
    }

    /// Cycle the primary selection to the next one.
    pub fn cycle_primary_forward(&mut self) {
        self.primary = (self.primary + 1) % self.selections.len();
    }

    /// Cycle the primary selection to the previous one.
    pub fn cycle_primary_backward(&mut self) {
        if self.primary == 0 {
            self.primary = self.selections.len() - 1;
        } else {
            self.primary -= 1;
        }
    }

    /// Translate all selections by a delta.
    pub fn translate(&self, delta: isize) -> Self {
        self.map(|s| s.translate(delta))
    }

    /// Collapse all selections to cursors at their head positions.
    pub fn collapse_to_heads(&self) -> Self {
        self.map(|s| s.collapse_to_head())
    }

    /// Collapse all selections to cursors at their start positions.
    pub fn collapse_to_starts(&self) -> Self {
        self.map(|s| s.collapse_to_start())
    }

    /// Flip all selections (swap anchor and head).
    pub fn flip(&self) -> Self {
        self.map(|s| s.flip())
    }

    /// Get the minimum position across all selections.
    pub fn min_position(&self) -> usize {
        self.selections.iter().map(|s| s.start()).min().unwrap_or(0)
    }

    /// Get the maximum position across all selections.
    pub fn max_position(&self) -> usize {
        self.selections.iter().map(|s| s.end()).max().unwrap_or(0)
    }

    /// Check if any selection contains the given position.
    pub fn contains(&self, pos: usize) -> bool {
        self.selections.iter().any(|s| s.contains(pos))
    }
}

impl Default for SelectionSet {
    fn default() -> Self {
        Self::new()
    }
}

impl From<Selection> for SelectionSet {
    fn from(sel: Selection) -> Self {
        SelectionSet::single(sel)
    }
}

impl From<Vec<Selection>> for SelectionSet {
    fn from(selections: Vec<Selection>) -> Self {
        SelectionSet::from_selections(selections)
    }
}

impl From<Range<usize>> for SelectionSet {
    fn from(range: Range<usize>) -> Self {
        SelectionSet::single(Selection::from_range(range))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_selection_cursor() {
        let sel = Selection::cursor(10);
        assert!(sel.is_cursor());
        assert_eq!(sel.start(), 10);
        assert_eq!(sel.end(), 10);
        assert_eq!(sel.len(), 0);
    }

    #[test]
    fn test_selection_range() {
        let sel = Selection::new(5, 15);
        assert!(!sel.is_cursor());
        assert_eq!(sel.start(), 5);
        assert_eq!(sel.end(), 15);
        assert_eq!(sel.len(), 10);
        assert_eq!(sel.range(), 5..15);
    }

    #[test]
    fn test_selection_backward() {
        let sel = Selection::new(15, 5);
        assert_eq!(sel.start(), 5);
        assert_eq!(sel.end(), 15);
        assert_eq!(sel.anchor, 15);
        assert_eq!(sel.head, 5);
    }

    #[test]
    fn test_selection_contains() {
        let sel = Selection::new(5, 15);
        assert!(!sel.contains(4));
        assert!(sel.contains(5));
        assert!(sel.contains(10));
        assert!(sel.contains(14));
        assert!(!sel.contains(15));
    }

    #[test]
    fn test_selection_overlaps() {
        let sel1 = Selection::new(5, 15);
        let sel2 = Selection::new(10, 20);
        let sel3 = Selection::new(15, 25);
        let sel4 = Selection::new(0, 5);

        assert!(sel1.overlaps(&sel2));
        assert!(!sel1.overlaps(&sel3));
        assert!(!sel1.overlaps(&sel4));
    }

    #[test]
    fn test_selection_touches() {
        let sel1 = Selection::new(5, 15);
        let sel2 = Selection::new(15, 25);
        let sel3 = Selection::new(16, 25);

        assert!(sel1.touches(&sel2));
        assert!(!sel1.touches(&sel3));
    }

    #[test]
    fn test_selection_merge() {
        let sel1 = Selection::new(5, 15);
        let sel2 = Selection::new(10, 25);
        let merged = sel1.merge(&sel2);

        assert_eq!(merged.start(), 5);
        assert_eq!(merged.end(), 25);
    }

    #[test]
    fn test_selection_translate() {
        let sel = Selection::new(10, 20);

        let moved = sel.translate(5);
        assert_eq!(moved.anchor, 15);
        assert_eq!(moved.head, 25);

        let moved_back = sel.translate(-5);
        assert_eq!(moved_back.anchor, 5);
        assert_eq!(moved_back.head, 15);

        // Clamp at 0
        let clamped = sel.translate(-15);
        assert_eq!(clamped.anchor, 0);
        assert_eq!(clamped.head, 5);
    }

    #[test]
    fn test_selection_set_single() {
        let set = SelectionSet::single(Selection::cursor(10));
        assert_eq!(set.len(), 1);
        assert!(set.is_single());
        assert_eq!(set.primary().head, 10);
    }

    #[test]
    fn test_selection_set_push() {
        let mut set = SelectionSet::single(Selection::cursor(10));
        set.push(Selection::cursor(20));
        set.push(Selection::cursor(30));

        assert_eq!(set.len(), 3);
        assert!(!set.is_single());
        assert_eq!(set.primary_index(), 2); // Last pushed is primary
        assert_eq!(set.primary().head, 30);
    }

    #[test]
    fn test_selection_set_map() {
        let set = SelectionSet::from_selections(vec![
            Selection::cursor(10),
            Selection::cursor(20),
            Selection::cursor(30),
        ]);

        let translated = set.map(|s| s.translate(5));
        assert_eq!(translated.selections()[0].head, 15);
        assert_eq!(translated.selections()[1].head, 25);
        assert_eq!(translated.selections()[2].head, 35);
    }

    #[test]
    fn test_selection_set_normalize() {
        let mut set = SelectionSet::from_selections(vec![
            Selection::new(10, 20),
            Selection::new(5, 15), // Overlaps with first
            Selection::new(30, 40),
        ]);

        set.normalize();

        assert_eq!(set.len(), 2);
        assert_eq!(set.selections()[0].range(), 5..20); // Merged
        assert_eq!(set.selections()[1].range(), 30..40);
    }

    #[test]
    fn test_selection_set_cycle_primary() {
        let mut set = SelectionSet::from_selections(vec![
            Selection::cursor(10),
            Selection::cursor(20),
            Selection::cursor(30),
        ]);

        assert_eq!(set.primary_index(), 0);
        set.cycle_primary_forward();
        assert_eq!(set.primary_index(), 1);
        set.cycle_primary_forward();
        assert_eq!(set.primary_index(), 2);
        set.cycle_primary_forward();
        assert_eq!(set.primary_index(), 0);

        set.cycle_primary_backward();
        assert_eq!(set.primary_index(), 2);
    }

    #[test]
    fn test_selection_set_keep_primary_only() {
        let mut set = SelectionSet::from_selections(vec![
            Selection::cursor(10),
            Selection::cursor(20),
            Selection::cursor(30),
        ]);
        set.set_primary(1);

        set.keep_primary_only();

        assert_eq!(set.len(), 1);
        assert_eq!(set.primary().head, 20);
    }
}
