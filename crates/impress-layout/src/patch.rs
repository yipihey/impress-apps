//! What a verb did, in a form that undoes exactly.
//!
//! # Why a computed diff and not an explicit inverse op
//!
//! The obvious design is an inverse-op enum — `Split` records "remove tile 7,
//! unwrap container 6", and so on. It is compact and semantically legible, and
//! it is wrong here for one reason: **every verb is followed by
//! normalization** ([`crate::Layout::normalize`]), which may collapse a
//! container three levels away, rescale the shares of a joined linear, retarget
//! a tabs `active`, move focus and garbage-collect tiles the verb never
//! mentioned. An inverse op would have to predict all of that, and the first
//! normalization rule added later would silently make old inverses inexact —
//! a class of bug that only shows up as "undo put my layout somewhere else",
//! long after the change that caused it.
//!
//! So a [`Patch`] is a **diff of the whole layout value, computed after the
//! fact**: only the entries that actually differ are stored, and reverting
//! restores exactly those. It is exact by construction for any verb and any
//! future normalization rule, and the property test
//! (`apply(v); revert()` == original, over random verb sequences) is a real
//! test rather than a restatement of the implementation.
//!
//! The cost is one clone of the layout per verb (layouts are tens of tiles,
//! not thousands) and a patch that names no gesture — so the verb that produced
//! it rides along in [`Patch::verb`], which is what the operation log and the
//! undo-stack classifier read.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::channels::ChannelState;
use crate::ids::TileId;
use crate::tree::{Tile, Window};
use crate::verb::Verb;
use crate::Layout;

/// What happened to one arena slot. `None` on a side means the tile did not
/// exist then.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct TileChange {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<Tile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Tile>,
}

/// A before/after pair for one of the layout's non-arena fields.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Change<T> {
    pub before: T,
    pub after: T,
}

/// The reversible record of one verb.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Patch {
    /// The gesture that produced this patch. Carried for the operation log and
    /// for [`crate::UndoStacks`] routing; never read when reverting.
    pub verb: Verb,
    /// Arena slots that differ, keyed by tile id.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tiles: BTreeMap<TileId, TileChange>,
    /// The window list, when any window changed (root, focus, geometry,
    /// default channel, maximized, or the set of windows itself).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows: Option<Change<Vec<Window>>>,
    /// Channel state, when a selection was published.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<Change<ChannelState>>,
    /// The tile-id allocator, when tiles were created.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_tile: Option<Change<u64>>,
}

impl Patch {
    /// Compute the patch from the two layout values around a verb.
    pub fn diff(verb: Verb, before: &Layout, after: &Layout) -> Patch {
        let mut tiles = BTreeMap::new();
        let keys: BTreeSet<TileId> = before
            .tiles
            .keys()
            .chain(after.tiles.keys())
            .copied()
            .collect();
        for id in keys {
            let b = before.tiles.get(&id);
            let a = after.tiles.get(&id);
            if b != a {
                tiles.insert(
                    id,
                    TileChange {
                        before: b.cloned(),
                        after: a.cloned(),
                    },
                );
            }
        }
        let windows = if before.windows == after.windows {
            None
        } else {
            Some(Change {
                before: before.windows.clone(),
                after: after.windows.clone(),
            })
        };
        let channels = if before.channels == after.channels {
            None
        } else {
            Some(Change {
                before: before.channels.clone(),
                after: after.channels.clone(),
            })
        };
        let next_tile = if before.next_tile == after.next_tile {
            None
        } else {
            Some(Change {
                before: before.next_tile,
                after: after.next_tile,
            })
        };
        Patch {
            verb,
            tiles,
            windows,
            channels,
            next_tile,
        }
    }

    /// Whether the verb changed nothing at all (a `Restore` with nothing
    /// maximized, a `Focus` on the already-focused pane). The service does not
    /// push these onto a ring.
    pub fn is_empty(&self) -> bool {
        self.tiles.is_empty()
            && self.windows.is_none()
            && self.channels.is_none()
            && self.next_tile.is_none()
    }
}

impl Layout {
    /// Undo a patch: restore exactly the entries it recorded.
    ///
    /// Exact by construction — `apply(v)` then `revert(&patch)` is the identity
    /// for every verb (`tests/properties.rs`).
    pub fn revert(&mut self, patch: &Patch) {
        self.restore(patch, true);
    }

    /// Redo a patch: re-apply exactly the entries it recorded, without
    /// re-running the verb (which might not resolve the same way twice).
    pub fn reapply(&mut self, patch: &Patch) {
        self.restore(patch, false);
    }

    fn restore(&mut self, patch: &Patch, to_before: bool) {
        for (id, change) in &patch.tiles {
            let target = if to_before {
                &change.before
            } else {
                &change.after
            };
            match target {
                Some(tile) => {
                    self.tiles.insert(*id, tile.clone());
                }
                None => {
                    self.tiles.remove(id);
                }
            }
        }
        if let Some(change) = &patch.windows {
            self.windows = if to_before {
                change.before.clone()
            } else {
                change.after.clone()
            };
        }
        if let Some(change) = &patch.channels {
            self.channels = if to_before {
                change.before.clone()
            } else {
                change.after.clone()
            };
        }
        if let Some(change) = &patch.next_tile {
            self.next_tile = if to_before {
                change.before
            } else {
                change.after
            };
        }
    }
}
