//! Helix-inspired transaction model for atomic document changes
//!
//! This module provides a transaction-based editing model inspired by the Helix
//! editor. Transactions encapsulate a sequence of operations and selection changes,
//! enabling:
//!
//! - **Atomic changes**: Multiple operations applied as a single unit
//! - **Undo/redo**: Transactions can be inverted for undo support
//! - **CRDT compatibility**: The `transform` method enables conflict resolution
//! - **Selection tracking**: Selection state before and after the transaction
//!
//! # Architecture
//!
//! Each transaction contains:
//! - A list of `Operation`s (inserts and deletes)
//! - The selection state before the transaction
//! - The selection state after the transaction
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::transaction::{Transaction, Operation};
//! use imprint_core::selection::{Selection, SelectionSet};
//!
//! let mut txn = Transaction::new(SelectionSet::single(Selection::cursor(0)));
//! txn.insert(0, "Hello, ");
//! txn.insert(7, "world!");
//!
//! // Apply to document...
//! ```

use crate::selection::{Selection, SelectionSet};
use serde::{Deserialize, Serialize};
use std::ops::Range;

/// An atomic editing operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Operation {
    /// Insert text at a position
    Insert {
        /// Position to insert at (byte offset)
        pos: usize,
        /// Text to insert
        text: String,
    },
    /// Delete text in a range
    Delete {
        /// Range to delete (byte offsets)
        range: Range<usize>,
        /// The deleted text (for undo)
        deleted: String,
    },
}

impl Operation {
    /// Create an insert operation.
    pub fn insert(pos: usize, text: impl Into<String>) -> Self {
        Operation::Insert {
            pos,
            text: text.into(),
        }
    }

    /// Create a delete operation.
    pub fn delete(range: Range<usize>, deleted: impl Into<String>) -> Self {
        Operation::Delete {
            range,
            deleted: deleted.into(),
        }
    }

    /// Get the position where this operation begins.
    pub fn position(&self) -> usize {
        match self {
            Operation::Insert { pos, .. } => *pos,
            Operation::Delete { range, .. } => range.start,
        }
    }

    /// Get the length change caused by this operation.
    ///
    /// Positive for insertions, negative for deletions.
    pub fn length_change(&self) -> isize {
        match self {
            Operation::Insert { text, .. } => text.len() as isize,
            Operation::Delete { range, .. } => -((range.end - range.start) as isize),
        }
    }

    /// Invert this operation (for undo).
    pub fn invert(&self) -> Operation {
        match self {
            Operation::Insert { pos, text } => Operation::Delete {
                range: *pos..*pos + text.len(),
                deleted: text.clone(),
            },
            Operation::Delete { range, deleted } => Operation::Insert {
                pos: range.start,
                text: deleted.clone(),
            },
        }
    }

    /// Transform this operation against another concurrent operation.
    ///
    /// When two users make concurrent edits, their operations need to be
    /// transformed so they can both be applied in either order.
    ///
    /// The `priority` parameter determines tie-breaking when operations
    /// occur at the same position. If true, this operation takes priority.
    pub fn transform(&self, other: &Operation, priority: bool) -> Operation {
        match (self, other) {
            // Insert vs Insert
            (Operation::Insert { pos, text }, Operation::Insert { pos: other_pos, text: other_text }) => {
                if *pos < *other_pos || (*pos == *other_pos && priority) {
                    // Our insert is before or has priority, no change needed
                    self.clone()
                } else {
                    // Shift our position by the other insert's length
                    Operation::Insert {
                        pos: pos + other_text.len(),
                        text: text.clone(),
                    }
                }
            }

            // Insert vs Delete
            (Operation::Insert { pos, text }, Operation::Delete { range, .. }) => {
                if *pos <= range.start {
                    // Insert is before the deleted range, no change
                    self.clone()
                } else if *pos >= range.end {
                    // Insert is after the deleted range, shift backward
                    Operation::Insert {
                        pos: pos - (range.end - range.start),
                        text: text.clone(),
                    }
                } else {
                    // Insert is within the deleted range - put it at the delete position
                    Operation::Insert {
                        pos: range.start,
                        text: text.clone(),
                    }
                }
            }

            // Delete vs Insert
            (Operation::Delete { range, deleted }, Operation::Insert { pos: insert_pos, text: insert_text }) => {
                if range.end <= *insert_pos {
                    // Delete is entirely before the insert, no change
                    self.clone()
                } else if range.start >= *insert_pos {
                    // Delete is entirely after the insert, shift forward
                    Operation::Delete {
                        range: (range.start + insert_text.len())..(range.end + insert_text.len()),
                        deleted: deleted.clone(),
                    }
                } else {
                    // Delete spans the insert position - expand the delete range
                    Operation::Delete {
                        range: range.start..(range.end + insert_text.len()),
                        deleted: format!(
                            "{}{}{}",
                            &deleted[..insert_pos - range.start],
                            insert_text,
                            &deleted[insert_pos - range.start..]
                        ),
                    }
                }
            }

            // Delete vs Delete
            (Operation::Delete { range, deleted }, Operation::Delete { range: other_range, .. }) => {
                if range.end <= other_range.start {
                    // Our delete is entirely before, no change
                    self.clone()
                } else if range.start >= other_range.end {
                    // Our delete is entirely after, shift backward
                    let shift = other_range.end - other_range.start;
                    Operation::Delete {
                        range: (range.start - shift)..(range.end - shift),
                        deleted: deleted.clone(),
                    }
                } else if range.start >= other_range.start && range.end <= other_range.end {
                    // Our delete is entirely within the other delete - becomes a no-op
                    // We represent this as a zero-length delete
                    Operation::Delete {
                        range: other_range.start..other_range.start,
                        deleted: String::new(),
                    }
                } else if other_range.start >= range.start && other_range.end <= range.end {
                    // Other delete is entirely within our delete
                    let shift = other_range.end - other_range.start;
                    let start_offset = other_range.start - range.start;
                    let end_offset = other_range.end - range.start;
                    let new_deleted = format!(
                        "{}{}",
                        &deleted[..start_offset],
                        &deleted[end_offset..]
                    );
                    Operation::Delete {
                        range: range.start..(range.end - shift),
                        deleted: new_deleted,
                    }
                } else if range.start < other_range.start {
                    // Partial overlap: our delete starts before
                    let overlap = range.end - other_range.start;
                    Operation::Delete {
                        range: range.start..other_range.start,
                        deleted: deleted[..deleted.len() - overlap].to_string(),
                    }
                } else {
                    // Partial overlap: our delete starts after
                    let new_start = range.start - (range.start - other_range.start).min(other_range.end - other_range.start);
                    let new_end = new_start + (range.end - range.start) - (other_range.end.min(range.end) - range.start.max(other_range.start));
                    Operation::Delete {
                        range: new_start..new_end,
                        deleted: deleted.clone(), // Simplified - in practice might need adjustment
                    }
                }
            }
        }
    }
}

/// A transaction representing a sequence of atomic changes.
///
/// Transactions are the primary unit of change in the editing model.
/// They can be composed, inverted, and transformed for CRDT support.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transaction {
    /// Operations in this transaction (in order)
    operations: Vec<Operation>,
    /// Selection state before this transaction
    selection_before: SelectionSet,
    /// Selection state after this transaction
    selection_after: SelectionSet,
}

impl Transaction {
    /// Create a new empty transaction with the given initial selection.
    pub fn new(selection: SelectionSet) -> Self {
        Self {
            operations: Vec::new(),
            selection_before: selection.clone(),
            selection_after: selection,
        }
    }

    /// Get the operations in this transaction.
    pub fn operations(&self) -> &[Operation] {
        &self.operations
    }

    /// Get the selection before this transaction.
    pub fn selection_before(&self) -> &SelectionSet {
        &self.selection_before
    }

    /// Get the selection after this transaction.
    pub fn selection_after(&self) -> &SelectionSet {
        &self.selection_after
    }

    /// Set the selection after this transaction.
    pub fn set_selection_after(&mut self, selection: SelectionSet) {
        self.selection_after = selection;
    }

    /// Check if this transaction has any operations.
    pub fn is_empty(&self) -> bool {
        self.operations.is_empty()
    }

    /// Add an insert operation.
    pub fn insert(&mut self, pos: usize, text: &str) -> &mut Self {
        if !text.is_empty() {
            self.operations.push(Operation::insert(pos, text));
            // Update selection_after to account for the insert
            self.selection_after = self.selection_after.map(|sel| {
                let new_anchor = if sel.anchor >= pos {
                    sel.anchor + text.len()
                } else {
                    sel.anchor
                };
                let new_head = if sel.head >= pos {
                    sel.head + text.len()
                } else {
                    sel.head
                };
                Selection::new(new_anchor, new_head)
            });
        }
        self
    }

    /// Add a delete operation.
    ///
    /// The `deleted` parameter contains the text that will be deleted (for undo).
    pub fn delete(&mut self, range: Range<usize>, deleted: &str) -> &mut Self {
        if range.start < range.end {
            self.operations.push(Operation::delete(range.clone(), deleted));
            // Update selection_after to account for the delete
            let len = range.end - range.start;
            self.selection_after = self.selection_after.map(|sel| {
                let adjust = |p: usize| {
                    if p <= range.start {
                        p
                    } else if p >= range.end {
                        p - len
                    } else {
                        range.start
                    }
                };
                Selection::new(adjust(sel.anchor), adjust(sel.head))
            });
        }
        self
    }

    /// Replace text in a range with new text.
    ///
    /// This is a convenience method that combines delete and insert.
    pub fn replace(&mut self, range: Range<usize>, deleted: &str, replacement: &str) -> &mut Self {
        self.delete(range.clone(), deleted);
        self.insert(range.start, replacement);
        self
    }

    /// Invert this transaction (for undo).
    ///
    /// Returns a new transaction that undoes all the changes in this one.
    pub fn invert(&self) -> Transaction {
        Transaction {
            operations: self.operations.iter().rev().map(|op| op.invert()).collect(),
            selection_before: self.selection_after.clone(),
            selection_after: self.selection_before.clone(),
        }
    }

    /// Compose this transaction with another.
    ///
    /// The result is a single transaction that has the same effect as
    /// applying this transaction followed by the other.
    pub fn compose(mut self, other: Transaction) -> Transaction {
        // Verify selections match
        debug_assert_eq!(
            self.selection_after, other.selection_before,
            "Composed transactions must have matching selections"
        );

        self.operations.extend(other.operations);
        self.selection_after = other.selection_after;
        self
    }

    /// Transform this transaction against another concurrent transaction.
    ///
    /// This is used for operational transformation in collaborative editing.
    /// When two users make concurrent changes, we need to transform one
    /// against the other so both can be applied.
    ///
    /// The `priority` parameter determines tie-breaking when operations
    /// occur at the same position. Pass true if this transaction should
    /// take priority.
    ///
    /// Returns a new transaction that, when applied after `other`, produces
    /// the same result as if both were applied concurrently.
    pub fn transform(&self, other: &Transaction, priority: bool) -> Transaction {
        let mut transformed_ops = Vec::new();

        for op in &self.operations {
            let mut current_op = op.clone();
            for other_op in &other.operations {
                current_op = current_op.transform(other_op, priority);
            }
            transformed_ops.push(current_op);
        }

        // Transform selection_after against other's operations
        let transformed_selection = transform_selection_set(&self.selection_after, &other.operations);

        Transaction {
            operations: transformed_ops,
            selection_before: transform_selection_set(&self.selection_before, &other.operations),
            selection_after: transformed_selection,
        }
    }

    /// Get the total length change caused by this transaction.
    pub fn length_change(&self) -> isize {
        self.operations.iter().map(|op| op.length_change()).sum()
    }

    /// Create a transaction from a single insert operation.
    pub fn from_insert(pos: usize, text: &str, selection: SelectionSet) -> Self {
        let mut txn = Self::new(selection);
        txn.insert(pos, text);
        txn
    }

    /// Create a transaction from a single delete operation.
    pub fn from_delete(range: Range<usize>, deleted: &str, selection: SelectionSet) -> Self {
        let mut txn = Self::new(selection);
        txn.delete(range, deleted);
        txn
    }
}

/// Transform a selection set against a list of operations.
fn transform_selection_set(selection: &SelectionSet, operations: &[Operation]) -> SelectionSet {
    selection.map(|sel| {
        let mut anchor = sel.anchor;
        let mut head = sel.head;

        for op in operations {
            match op {
                Operation::Insert { pos, text } => {
                    if anchor >= *pos {
                        anchor += text.len();
                    }
                    if head >= *pos {
                        head += text.len();
                    }
                }
                Operation::Delete { range, .. } => {
                    let adjust = |p: usize| {
                        if p <= range.start {
                            p
                        } else if p >= range.end {
                            p - (range.end - range.start)
                        } else {
                            range.start
                        }
                    };
                    anchor = adjust(anchor);
                    head = adjust(head);
                }
            }
        }

        Selection::new(anchor, head)
    })
}

/// A builder for constructing transactions incrementally.
#[derive(Debug)]
pub struct TransactionBuilder {
    transaction: Transaction,
    /// Running offset to track cumulative position changes
    offset: isize,
}

impl TransactionBuilder {
    /// Create a new transaction builder.
    pub fn new(selection: SelectionSet) -> Self {
        Self {
            transaction: Transaction::new(selection),
            offset: 0,
        }
    }

    /// Add an insert operation at the original document position.
    ///
    /// The builder tracks position offsets, so you can specify positions
    /// relative to the original document.
    pub fn insert(mut self, original_pos: usize, text: &str) -> Self {
        let adjusted_pos = (original_pos as isize + self.offset) as usize;
        self.transaction.insert(adjusted_pos, text);
        self.offset += text.len() as isize;
        self
    }

    /// Add a delete operation at the original document position.
    pub fn delete(mut self, original_range: Range<usize>, deleted: &str) -> Self {
        let start = (original_range.start as isize + self.offset) as usize;
        let end = (original_range.end as isize + self.offset) as usize;
        self.transaction.delete(start..end, deleted);
        self.offset -= (original_range.end - original_range.start) as isize;
        self
    }

    /// Set the final selection.
    pub fn with_selection(mut self, selection: SelectionSet) -> Self {
        self.transaction.selection_after = selection;
        self
    }

    /// Build the transaction.
    pub fn build(self) -> Transaction {
        self.transaction
    }
}

impl Default for Transaction {
    fn default() -> Self {
        Self::new(SelectionSet::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_operation_insert() {
        let op = Operation::insert(5, "hello");
        assert_eq!(op.position(), 5);
        assert_eq!(op.length_change(), 5);
    }

    #[test]
    fn test_operation_delete() {
        let op = Operation::delete(5..15, "0123456789");
        assert_eq!(op.position(), 5);
        assert_eq!(op.length_change(), -10);
    }

    #[test]
    fn test_operation_invert_insert() {
        let op = Operation::insert(5, "hello");
        let inverted = op.invert();

        match inverted {
            Operation::Delete { range, deleted } => {
                assert_eq!(range, 5..10);
                assert_eq!(deleted, "hello");
            }
            _ => panic!("Expected Delete"),
        }
    }

    #[test]
    fn test_operation_invert_delete() {
        let op = Operation::delete(5..10, "hello");
        let inverted = op.invert();

        match inverted {
            Operation::Insert { pos, text } => {
                assert_eq!(pos, 5);
                assert_eq!(text, "hello");
            }
            _ => panic!("Expected Insert"),
        }
    }

    #[test]
    fn test_transaction_insert() {
        let sel = SelectionSet::single(Selection::cursor(0));
        let mut txn = Transaction::new(sel);
        txn.insert(0, "hello");

        assert_eq!(txn.operations.len(), 1);
        assert_eq!(txn.length_change(), 5);
        // Selection should move
        assert_eq!(txn.selection_after.primary().head, 5);
    }

    #[test]
    fn test_transaction_delete() {
        let sel = SelectionSet::single(Selection::cursor(10));
        let mut txn = Transaction::new(sel);
        txn.delete(0..5, "hello");

        assert_eq!(txn.operations.len(), 1);
        assert_eq!(txn.length_change(), -5);
        // Selection should shift back
        assert_eq!(txn.selection_after.primary().head, 5);
    }

    #[test]
    fn test_transaction_invert() {
        let sel = SelectionSet::single(Selection::cursor(0));
        let mut txn = Transaction::new(sel);
        txn.insert(0, "hello");

        let inverted = txn.invert();
        assert_eq!(inverted.length_change(), -5);
        assert_eq!(inverted.selection_after.primary().head, 0);
    }

    #[test]
    fn test_transaction_compose() {
        let sel = SelectionSet::single(Selection::cursor(0));
        let mut txn1 = Transaction::new(sel);
        txn1.insert(0, "hello");

        let mut txn2 = Transaction::new(txn1.selection_after.clone());
        txn2.insert(5, " world");

        let composed = txn1.compose(txn2);
        assert_eq!(composed.operations.len(), 2);
        assert_eq!(composed.length_change(), 11);
    }

    #[test]
    fn test_operation_transform_insert_insert_before() {
        let op1 = Operation::insert(5, "aaa");
        let op2 = Operation::insert(10, "bbb");

        let transformed = op1.transform(&op2, true);
        // op1 is before op2, should not change
        assert_eq!(transformed.position(), 5);
    }

    #[test]
    fn test_operation_transform_insert_insert_after() {
        let op1 = Operation::insert(15, "aaa");
        let op2 = Operation::insert(10, "bbb");

        let transformed = op1.transform(&op2, true);
        // op1 is after op2, should shift by op2's length
        assert_eq!(transformed.position(), 18);
    }

    #[test]
    fn test_operation_transform_insert_delete() {
        let op1 = Operation::insert(15, "aaa");
        let op2 = Operation::delete(5..10, "xxxxx");

        let transformed = op1.transform(&op2, true);
        // op1 is after op2's range, should shift back
        assert_eq!(transformed.position(), 10);
    }

    #[test]
    fn test_transaction_transform() {
        let sel = SelectionSet::single(Selection::cursor(0));

        let mut txn1 = Transaction::new(sel.clone());
        txn1.insert(5, "aaa");

        let mut txn2 = Transaction::new(sel);
        txn2.insert(10, "bbb");

        let transformed = txn1.transform(&txn2, true);
        // txn1's insert at 5 should not be affected by txn2's insert at 10
        match &transformed.operations[0] {
            Operation::Insert { pos, .. } => assert_eq!(*pos, 5),
            _ => panic!("Expected insert"),
        }
    }

    #[test]
    fn test_transaction_builder() {
        let sel = SelectionSet::single(Selection::cursor(0));
        let txn = TransactionBuilder::new(sel)
            .insert(0, "hello")
            .insert(5, " world")  // Position is original, builder adjusts
            .build();

        // First insert at 0, second at adjusted position (0 + 5 = 5)
        // But builder uses original positions, so second should be at 5 + 5 = 10
        assert_eq!(txn.operations.len(), 2);
    }
}
