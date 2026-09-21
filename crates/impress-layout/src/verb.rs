//! The closed verb vocabulary (ADR-0031 D8) and the pane references every verb
//! takes.
//!
//! What is *not* here is as deliberate as what is: `commit`, `save_layout`,
//! `apply_layout`, `undo` and `redo` are service verbs (L3) because they touch
//! the store or a ring, and this crate is pure. The rings themselves live here
//! ([`crate::UndoRing`]) so the service only has to route.

use impress_core::item::ItemId;
use impress_core::pane_query::{PaneQuery, ParamName, RecordKindId};
use serde::{Deserialize, Serialize};

use crate::ids::{ChannelId, Role, TileId, ViewKindId, WindowId};
use crate::spec::{PaneSpec, ParamSource};
use crate::tree::{ContainerKind, Geometry, LinearDir};

/// How a verb names a pane. Resolution happens once, in Rust
/// ([`crate::Layout::resolve`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "ref", rename_all = "kebab-case")]
pub enum PaneRef {
    /// Canonical: what the operation log and the tests use.
    Id { tile: TileId },
    /// What chords and agents say: "the detail pane", whichever tile that is.
    Role { role: Role },
    /// What h / l and drag gestures produce: a step from the focused leaf.
    Direction { direction: Direction },
    /// The focused leaf itself.
    Focused,
}

impl PaneRef {
    pub fn id(tile: TileId) -> Self {
        PaneRef::Id { tile }
    }

    pub fn role(role: Role) -> Self {
        PaneRef::Role { role }
    }

    pub fn direction(direction: Direction) -> Self {
        PaneRef::Direction { direction }
    }
}

/// A step from the focused leaf.
///
/// `Next` / `Prev` walk the window's leaves in tree order and wrap, which is
/// exactly what `PaneFocusCycler` does today. `Left` / `Right` / `Up` / `Down`
/// are spatial-ish rather than spatial: see [`crate::Layout::resolve`] for the
/// rule, which is stated there once and holds for every caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "kebab-case")]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
    Next,
    Prev,
}

impl Direction {
    /// The linear axis this direction steps along, if any.
    pub fn axis(self) -> Option<LinearDir> {
        match self {
            Direction::Left | Direction::Right => Some(LinearDir::Horizontal),
            Direction::Up | Direction::Down => Some(LinearDir::Vertical),
            Direction::Next | Direction::Prev => None,
        }
    }

    /// Whether the step goes towards later siblings.
    pub fn is_forward(self) -> bool {
        matches!(self, Direction::Right | Direction::Down | Direction::Next)
    }
}

/// Where a moved tile lands relative to its target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "kebab-case")]
pub enum Placement {
    Left,
    Right,
    Above,
    Below,
    /// Tab the moved tile alongside the target (pyqtgraph's centre drop zone).
    IntoTabs,
}

impl Placement {
    pub(crate) fn linear(self) -> Option<(LinearDir, bool)> {
        match self {
            Placement::Left => Some((LinearDir::Horizontal, false)),
            Placement::Right => Some((LinearDir::Horizontal, true)),
            Placement::Above => Some((LinearDir::Vertical, false)),
            Placement::Below => Some((LinearDir::Vertical, true)),
            Placement::IntoTabs => None,
        }
    }
}

/// Every gesture, as a value (ADR-0031 D8, invariant 6: no Swift-only layout
/// operation).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "verb", rename_all = "kebab-case")]
pub enum Verb {
    // ---- arrangement ----
    /// Split `target` along `dir`, putting `new` after it (or before, when
    /// `after` is false). Focus follows the new pane.
    Split {
        target: PaneRef,
        dir: LinearDir,
        #[serde(default)]
        after: bool,
        new: PaneSpec,
    },
    /// Move `tile` next to (or into the tabs of) `target`.
    MoveTile {
        tile: PaneRef,
        target: PaneRef,
        placement: Placement,
    },
    /// Close a pane or a whole subtree. Never the last pane of a window.
    Close {
        target: PaneRef,
    },
    /// Exchange two tiles' positions, keeping each position's share.
    Swap {
        a: PaneRef,
        b: PaneRef,
    },
    /// Set a linear container's relative shares.
    Resize {
        container: TileId,
        shares: Vec<f32>,
    },
    /// Retype a container, keeping its children in order.
    SetContainerKind {
        container: TileId,
        kind: ContainerKind,
    },
    /// Show `target` alone in its window. Does not mutate the tree.
    Maximize {
        target: PaneRef,
    },
    /// Undo a maximize. A no-op when nothing is maximized.
    Restore,
    /// Move a pane (or a whole subtree) out into a **new window** whose root
    /// it becomes — D4's detached PDF. Focus follows it; the window it left
    /// re-normalizes. Refused when the tile is the whole source window: that
    /// would be a rename, not a detach.
    Detach {
        target: PaneRef,
    },

    // ---- content ----
    /// Replace a pane's whole spec.
    SetPane {
        target: PaneRef,
        spec: PaneSpec,
    },
    SetQuery {
        target: PaneRef,
        query: PaneQuery,
    },
    SetViewKind {
        target: PaneRef,
        view_kind: ViewKindId,
    },
    /// Re-point one declared parameter at a different source.
    BindParam {
        target: PaneRef,
        name: ParamName,
        source: ParamSource,
    },
    /// Change the channel a pane publishes on.
    SetChannel {
        target: PaneRef,
        channel: ChannelId,
    },
    /// Give, move or clear a role.
    SetRole {
        target: PaneRef,
        #[serde(default)]
        role: Option<Role>,
    },

    // ---- focus / selection ----
    Focus {
        target: PaneRef,
    },
    FocusDirection {
        direction: Direction,
    },
    /// Publish a selection of `kind` on the pane's channel.
    Select {
        target: PaneRef,
        kind: RecordKindId,
        #[cfg_attr(feature = "schema", schemars(with = "Vec<String>"))]
        ids: Vec<ItemId>,
    },

    // ---- window ----
    /// Replace (or clear) a window's device-scoped frame.
    SetWindowGeometry {
        window: WindowId,
        #[serde(default)]
        geometry: Option<Geometry>,
    },
    /// Set what [`ChannelId::Follow`] means in one window. `Follow` itself is
    /// refused: a window default that follows itself is not a value.
    SetDefaultChannel {
        window: WindowId,
        channel: ChannelId,
    },
}
