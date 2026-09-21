//! The undo rings (ADR-0031 D7).
//!
//! There are three undo stacks and ⌘Z is routed by the focused leaf. The first
//! — the editor session's own undo manager — is not ours and is never touched.
//! The other two are here:
//!
//! 1. **arrangement**: split, move, close, swap, resize, retype, maximize,
//!    restore, role, window geometry — one ring for the whole layout, on its
//!    own chord;
//! 2. **exploration**: query, view kind, parameter bindings, channel and
//!    selection — **one ring per pane**, because exploring in one pane must
//!    not undo exploring in another.
//!
//! Focus verbs record nothing: undoing a focus move is what the opposite focus
//! move is for, and putting them on a ring means every ⌘Z spends a step on
//! where the cursor was.
//!
//! Undo never crosses a commit (D7); commits are `Durable` operations on the
//! store and are reverted item-wise, which is the service's business, not this
//! crate's.

use std::collections::{BTreeMap, VecDeque};

use serde::{Deserialize, Serialize};

use crate::error::LayoutError;
use crate::ids::TileId;
use crate::patch::Patch;
use crate::verb::{PaneRef, Verb};
use crate::Layout;

/// How many gestures a ring remembers by default.
pub const DEFAULT_CAPACITY: usize = 64;

/// A bounded ring of patches with a redo side.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UndoRing {
    /// The oldest patch is dropped once this many are held.
    pub capacity: usize,
    /// Applied patches, oldest first.
    pub done: VecDeque<Patch>,
    /// Patches undone and not yet re-applied, most recently undone last.
    pub undone: Vec<Patch>,
}

impl Default for UndoRing {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }
}

impl UndoRing {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            done: VecDeque::new(),
            undone: Vec::new(),
        }
    }

    /// Record a patch. A patch that changed nothing is dropped: a no-op
    /// gesture must not cost the user a ⌘Z.
    pub fn push(&mut self, patch: Patch) {
        if patch.is_empty() {
            return;
        }
        self.undone.clear();
        self.done.push_back(patch);
        while self.done.len() > self.capacity {
            self.done.pop_front();
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.done.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.undone.is_empty()
    }

    /// Revert the most recent patch, returning it.
    pub fn undo(&mut self, layout: &mut Layout) -> Option<Patch> {
        let patch = self.done.pop_back()?;
        layout.revert(&patch);
        self.undone.push(patch.clone());
        Some(patch)
    }

    /// Re-apply the most recently undone patch, returning it.
    pub fn redo(&mut self, layout: &mut Layout) -> Option<Patch> {
        let patch = self.undone.pop()?;
        layout.reapply(&patch);
        self.done.push_back(patch.clone());
        Some(patch)
    }
}

/// Which ring a verb belongs on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StackKind {
    /// The arrangement ring.
    Arrangement,
    /// The exploration ring of the pane this reference names. The reference,
    /// not a tile id: classification is a property of the *verb*, and the
    /// reference only resolves against a layout ([`UndoStacks::apply`] does
    /// that, before the verb runs, since applying can change what `Focused`
    /// or a direction means).
    Exploration(PaneRef),
    /// Not recorded.
    None,
}

/// Which ring a verb belongs on (ADR-0031 D7).
pub fn stack_for(verb: &Verb) -> StackKind {
    match verb {
        Verb::Split { .. }
        | Verb::MoveTile { .. }
        | Verb::Close { .. }
        | Verb::Swap { .. }
        | Verb::Resize { .. }
        | Verb::SetContainerKind { .. }
        | Verb::Maximize { .. }
        | Verb::Restore
        | Verb::Detach { .. }
        // Where a role lives is arrangement, not exploration: it changes what
        // every universal chord in the window points at.
        | Verb::SetRole { .. }
        | Verb::SetWindowGeometry { .. }
        | Verb::SetDefaultChannel { .. } => StackKind::Arrangement,

        Verb::SetPane { target, .. }
        | Verb::SetQuery { target, .. }
        | Verb::SetViewKind { target, .. }
        | Verb::BindParam { target, .. }
        | Verb::SetChannel { target, .. }
        | Verb::Select { target, .. } => StackKind::Exploration(target.clone()),

        Verb::Focus { .. } | Verb::FocusDirection { .. } => StackKind::None,
    }
}

/// The two rings this crate owns, with the routing that puts a patch on the
/// right one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UndoStacks {
    pub arrangement: UndoRing,
    /// One ring per pane, created on first exploration in that pane and
    /// dropped when the pane closes ([`UndoStacks::forget_closed_panes`]).
    pub exploration: BTreeMap<TileId, UndoRing>,
    /// Capacity for rings created later.
    pub capacity: usize,
}

impl Default for UndoStacks {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }
}

impl UndoStacks {
    pub fn new(capacity: usize) -> Self {
        Self {
            arrangement: UndoRing::new(capacity),
            exploration: BTreeMap::new(),
            capacity: capacity.max(1),
        }
    }

    /// Apply a verb and record its patch on the ring [`stack_for`] chooses.
    ///
    /// The exploration target is resolved **before** the verb runs: after a
    /// split or a move, `Focused` and a direction mean something else.
    pub fn apply(&mut self, layout: &mut Layout, verb: Verb) -> Result<Patch, LayoutError> {
        let window = layout.current_window()?;
        let destination = match stack_for(&verb) {
            StackKind::Arrangement => Destination::Arrangement,
            StackKind::Exploration(reference) => match layout.resolve(window, &reference) {
                Ok(tile) => Destination::Pane(tile),
                // Unresolvable: the verb is about to fail anyway.
                Err(_) => Destination::Unrecorded,
            },
            StackKind::None => Destination::Unrecorded,
        };
        let patch = layout.apply_in(window, verb)?;
        match destination {
            Destination::Arrangement => self.arrangement.push(patch.clone()),
            Destination::Pane(tile) => {
                let capacity = self.capacity;
                self.exploration
                    .entry(tile)
                    .or_insert_with(|| UndoRing::new(capacity))
                    .push(patch.clone());
            }
            Destination::Unrecorded => {}
        }
        Ok(patch)
    }

    /// The exploration ring of one pane, created if absent.
    pub fn exploration_ring(&mut self, pane: TileId) -> &mut UndoRing {
        let capacity = self.capacity;
        self.exploration
            .entry(pane)
            .or_insert_with(|| UndoRing::new(capacity))
    }

    /// Undo the last arrangement gesture.
    pub fn undo_arrangement(&mut self, layout: &mut Layout) -> Option<Patch> {
        self.arrangement.undo(layout)
    }

    /// Undo the last exploration in one pane.
    pub fn undo_exploration(&mut self, layout: &mut Layout, pane: TileId) -> Option<Patch> {
        self.exploration.get_mut(&pane)?.undo(layout)
    }

    /// Drop the exploration rings of panes the layout no longer has. The
    /// service calls this after a close; it is not automatic, because undoing
    /// the close should bring the pane's ring back with it.
    pub fn forget_closed_panes(&mut self, layout: &Layout) {
        self.exploration
            .retain(|tile, _| layout.pane(*tile).is_some());
    }
}

/// Where a patch landed, once the reference has been resolved.
enum Destination {
    Arrangement,
    Pane(TileId),
    Unrecorded,
}
