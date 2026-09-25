//! Why a verb did not apply.
//!
//! Every variant is a *typed* refusal that leaves the layout untouched: verbs
//! are applied to a scratch clone and committed only on success, so a failed
//! verb can never leave a half-mutated tree (which, in a tree whose whole point
//! is legibility, would be worse than the failure).

use crate::ids::{ChannelId, Role, TileId, WindowId};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(tag = "error", rename_all = "kebab-case")]
pub enum LayoutError {
    #[error("no tile {tile} in this layout")]
    UnknownTile { tile: TileId },

    #[error("no window {window} in this layout")]
    UnknownWindow { window: WindowId },

    #[error("no pane carries the role '{role}'")]
    NoPaneWithRole { role: Role },

    #[error("tile {tile} is a container, not a pane")]
    NotAPane { tile: TileId },

    #[error("tile {tile} is a pane, not a container")]
    NotAContainer { tile: TileId },

    #[error("a window must keep at least one pane")]
    CannotCloseLastPane,

    #[error("window {window} has no focused pane")]
    NoFocus { window: WindowId },

    #[error("channel '{channel}' cannot be used here")]
    InvalidChannel { channel: ChannelId },

    #[error("invalid shares: {reason}")]
    InvalidShares { reason: String },

    #[error("cannot move tile {tile} into its own subtree")]
    CyclicMove { tile: TileId },

    #[error("pane {tile} declares no parameter named '{name}'")]
    UnknownParam { tile: TileId, name: String },

    /// A verb that would leave two panes of one window carrying the same role
    /// (a swap or move across windows, a `set-pane` naming a role another
    /// pane holds). Roles are unique per window (ADR-0031 D5) because the
    /// universal chords act on "the" pane with a role; `set-role` is the verb
    /// that moves one.
    #[error(
        "the role '{role}' would be held by two panes in window {window}; use set-role to move it"
    )]
    RoleHeldTwice { role: Role, window: WindowId },

    /// An undo or redo step whose recorded value is no longer what the layout
    /// holds: something else changed it since (another ring, another pane,
    /// another writer). Refused rather than replayed, because replaying would
    /// silently undo that later change too (review RL-L4).
    #[error("{what} changed since this step was recorded, so the step was dropped and nothing was changed")]
    UndoConflict { what: String },
}
