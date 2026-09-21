//! Identifiers and the small string-ish newtypes the layout is built from.
//!
//! Every one of these is a plain value with a stable serde form: the layout is
//! the payload of an `impress/ui/layout` item (ADR-0019 D1), so the wire shape
//! here is a compatibility surface, pinned by `tests/golden/three_column.json`.

use std::borrow::Cow;
use std::fmt;

use serde::{Deserialize, Serialize};

/// A tile's identity inside one [`crate::Layout`] arena.
///
/// Sequential `u64` rather than a UUID: the ids are dense (a window has tens of
/// tiles, not millions), they make the golden JSON and every test assertion
/// readable, and [`crate::Layout::next_tile`] makes allocation deterministic —
/// which is what lets a preset serialize byte-identically on every device. Ids
/// are never reused within a layout, so a stale reference in a log is always
/// detectably stale rather than silently pointing at a different pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(transparent)]
pub struct TileId(pub u64);

impl TileId {
    pub const fn new(raw: u64) -> Self {
        Self(raw)
    }

    pub const fn raw(self) -> u64 {
        self.0
    }
}

impl fmt::Display for TileId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<u64> for TileId {
    fn from(raw: u64) -> Self {
        Self(raw)
    }
}

/// A window's identity inside one [`crate::Layout`]. Sequential, like
/// [`TileId`], and for the same reasons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(transparent)]
pub struct WindowId(pub u64);

impl WindowId {
    pub const fn new(raw: u64) -> Self {
        Self(raw)
    }

    pub const fn raw(self) -> u64 {
        self.0
    }
}

impl fmt::Display for WindowId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<u64> for WindowId {
    fn from(raw: u64) -> Self {
        Self(raw)
    }
}

/// A coordination channel (ADR-0031 D3): eight numbered channels plus the
/// reserved `follow`, meaning "whatever this pane's window says its default
/// channel is" ([`crate::Window::default_channel`]).
///
/// A channel carries one current selection *per record kind*, so a pane
/// publishing a manuscript on channel 2 leaves a `publication` parameter on the
/// same channel untouched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "kebab-case")]
pub enum ChannelId {
    /// One of the eight numbered channels, `1..=8`.
    Number(u8),
    /// The window's default channel.
    Follow,
}

impl ChannelId {
    /// The lowest numbered channel; the one every preset uses.
    pub const ONE: ChannelId = ChannelId::Number(1);
    /// Channels are numbered `1..=MAX`.
    pub const MAX: u8 = 8;

    /// A numbered channel, clamped into `1..=8`. Out-of-range numbers are
    /// clamped rather than rejected: a channel is a coordination convenience,
    /// and no gesture should fail because a caller said "channel 9".
    pub fn number(n: u8) -> Self {
        ChannelId::Number(n.clamp(1, Self::MAX))
    }

    /// The concrete channel number this id denotes, resolving `Follow` against
    /// a window default (itself resolved, defensively, in case a window default
    /// was persisted as `Follow`).
    pub fn resolve(self, window_default: ChannelId) -> u8 {
        match self {
            ChannelId::Number(n) => n.clamp(1, Self::MAX),
            ChannelId::Follow => match window_default {
                ChannelId::Number(n) => n.clamp(1, Self::MAX),
                ChannelId::Follow => 1,
            },
        }
    }
}

impl Default for ChannelId {
    fn default() -> Self {
        ChannelId::ONE
    }
}

impl fmt::Display for ChannelId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChannelId::Number(n) => write!(f, "{n}"),
            ChannelId::Follow => write!(f, "follow"),
        }
    }
}

macro_rules! string_newtype {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
        #[cfg_attr(feature = "schema", schemars(transparent))]
        #[serde(transparent)]
        pub struct $name(
            #[cfg_attr(feature = "schema", schemars(with = "String"))] pub Cow<'static, str>,
        );

        impl $name {
            /// Borrow the underlying string.
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl From<&'static str> for $name {
            fn from(s: &'static str) -> Self {
                Self(Cow::Borrowed(s))
            }
        }

        impl From<String> for $name {
            fn from(s: String) -> Self {
                Self(Cow::Owned(s))
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl PartialEq<str> for $name {
            fn eq(&self, other: &str) -> bool {
                self.0 == other
            }
        }
    };
}

string_newtype! {
    /// What a pane holds the role of (ADR-0031 D5). Roles, not slots, are what
    /// the universal chords act on: ⌃⌘S toggles whichever pane carries
    /// [`Role::NAVIGATOR`], ⌘0 the one carrying [`Role::DETAIL`]. Open-ended by
    /// design — the consts below are the ones the shipped presets assign.
    Role
}

impl Role {
    pub const NAVIGATOR: Role = Role(Cow::Borrowed("navigator"));
    pub const LIST: Role = Role(Cow::Borrowed("list"));
    pub const DETAIL: Role = Role(Cow::Borrowed("detail"));
    pub const PREVIEW: Role = Role(Cow::Borrowed("preview"));
    pub const CONSOLE: Role = Role(Cow::Borrowed("console"));
}

string_newtype! {
    /// How a pane is rendered: the key the Swift `ViewKindRegistry` resolves
    /// (ADR-0031 D1). A view kind the platform cannot render becomes a
    /// placeholder that keeps its spec (D4) — see
    /// [`crate::Layout::placeholder_for_missing_view_kinds`].
    ViewKindId
}

impl ViewKindId {
    pub const OUTLINE: ViewKindId = ViewKindId(Cow::Borrowed("outline"));
    pub const LIST: ViewKindId = ViewKindId(Cow::Borrowed("list"));
    pub const INFO: ViewKindId = ViewKindId(Cow::Borrowed("info"));
    pub const PDF: ViewKindId = ViewKindId(Cow::Borrowed("pdf"));
    pub const EDITOR: ViewKindId = ViewKindId(Cow::Borrowed("editor"));
    pub const PLOT: ViewKindId = ViewKindId(Cow::Borrowed("plot"));
    pub const CONSOLE: ViewKindId = ViewKindId(Cow::Borrowed("console"));
    /// Hosts a legacy `SectionContentView` route unchanged (ADR-0031 D11).
    pub const LEGACY: ViewKindId = ViewKindId(Cow::Borrowed("legacy"));
    pub const PLACEHOLDER: ViewKindId = ViewKindId(Cow::Borrowed("placeholder"));
}

string_newtype! {
    /// The handle of a session-bearing view kind's session (ADR-0031 D6). The
    /// session lives in a registry *outside* the tree; no layout mutation ever
    /// tears one down, which is why the tree stores only this id.
    SessionId
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_follow_resolves_to_the_window_default() {
        assert_eq!(ChannelId::Follow.resolve(ChannelId::Number(3)), 3);
        assert_eq!(ChannelId::Number(2).resolve(ChannelId::Number(3)), 2);
        // A window whose default was persisted as `follow` still resolves.
        assert_eq!(ChannelId::Follow.resolve(ChannelId::Follow), 1);
    }

    #[test]
    fn channel_numbers_are_clamped() {
        assert_eq!(ChannelId::number(0), ChannelId::Number(1));
        assert_eq!(ChannelId::number(99), ChannelId::Number(8));
    }

    #[test]
    fn ids_round_trip_through_json() {
        let json = serde_json::to_string(&TileId(7)).unwrap();
        assert_eq!(json, "7");
        assert_eq!(serde_json::from_str::<TileId>(&json).unwrap(), TileId(7));

        let json = serde_json::to_string(&ChannelId::Follow).unwrap();
        assert_eq!(json, "\"follow\"");
        let json = serde_json::to_string(&ChannelId::Number(2)).unwrap();
        assert_eq!(json, "{\"number\":2}");

        let json = serde_json::to_string(&Role::DETAIL).unwrap();
        assert_eq!(json, "\"detail\"");
        assert_eq!(serde_json::from_str::<Role>(&json).unwrap(), Role::DETAIL);
    }
}
