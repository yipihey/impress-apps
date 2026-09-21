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
}
