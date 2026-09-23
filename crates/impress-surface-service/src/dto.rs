//! Wire types the surface verbs take and return.
//!
//! As `impress-layout-service/src/dto.rs`'s module docs put it: a crate type
//! that already derives `serde` **and** `schemars::JsonSchema` is used
//! **directly** on the trait — [`impress_surface::SurfaceSpec`],
//! [`impress_surface::RenderTree`], [`impress_surface::Event`]. What is here
//! is only the shapes those crates do not have: how a caller names a pane to
//! show a surface in, and the result envelopes.

use impress_surface::{Problem, SurfaceSpec};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// surface_show's target
// ---------------------------------------------------------------------------

/// Which pane `surface_show` should put the surface in (`docs/agent-surfaces.md`
/// "5. surface-show"): a tile id, a role, or a fresh split beside the focused
/// pane. Exactly one of the three should be set; `role` wins over `tile` wins
/// over `split` if more than one is (mirroring the precedence
/// [`impress_layout_service::dto::PaneRefDto`] documents for the same reason
/// — an argument, not a tagged enum, because a chat-authored call names
/// whichever field it means).
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ShowTargetDto {
    /// `navigator` | `list` | `detail` | `preview` | `console` | any role a
    /// preset assigned. The surface replaces whatever that pane currently
    /// shows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// A tile id from a prior `get_layout` / `surface_show` result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tile: Option<u64>,
    /// Open a NEW pane beside the focused one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub split: Option<SplitTargetDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SplitTargetDto {
    /// `horizontal` (side by side) or `vertical` (stacked).
    pub direction: String,
    /// Split the currently focused pane. This is the only target the
    /// composed `layout-service_split` verb can resolve without more state
    /// than a surface pane tracks (ADR-0033 leaves the exact shape of a
    /// non-focused split target open); `false` behaves the same as `true`
    /// today and is accepted rather than refused so a spec authored against
    /// a future host that CAN resolve one still validates.
    #[serde(default)]
    pub from_focused: bool,
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// `surface_schema`'s answer: the JSON Schema plus a worked example, so an
/// agent never has to read Rust source to learn the vocabulary (ADR-0033 D8).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceSchemaResult {
    pub schema: serde_json::Value,
    pub example: SurfaceSpec,
}

/// `surface_validate`'s answer: every problem, named by path — the S1
/// [`Problem`]s plus S4's own check that every named verb exists in the
/// linked inventory (ADR-0033 D4).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceValidateResult {
    pub problems: Vec<Problem>,
}

impl SurfaceValidateResult {
    pub fn ok(&self) -> bool {
        self.problems.is_empty()
    }
}

/// One surface row, in full — `surface_get`, and what `surface_create` /
/// `surface_update` echo back.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceResult {
    pub ok: bool,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spec: Option<SurfaceSpec>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,
}

impl SurfaceResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            id: None,
            name: None,
            version: None,
            spec: None,
            tags: Vec::new(),
            created: None,
            modified: None,
        }
    }

    pub fn from_row(row: &crate::store::SurfaceRow) -> Self {
        Self {
            ok: true,
            message: format!("surface '{}' ({})", row.name, row.id),
            id: Some(row.id.to_string()),
            name: Some(row.name.clone()),
            version: row.version.clone(),
            spec: Some(row.spec.clone()),
            tags: row.tags.clone(),
            created: Some(row.created.to_rfc3339()),
            modified: Some(row.modified.to_rfc3339()),
        }
    }
}

/// One row as `surface_list` shows it — no `spec` (an agent lists to pick an
/// id, not to re-download every document at once; `surface_get` has the
/// spec).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceSummaryDto {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub created: String,
    pub modified: String,
}

impl From<&crate::store::SurfaceRow> for SurfaceSummaryDto {
    fn from(row: &crate::store::SurfaceRow) -> Self {
        Self {
            id: row.id.to_string(),
            name: row.name.clone(),
            version: row.version.clone(),
            tags: row.tags.clone(),
            created: row.created.to_rfc3339(),
            modified: row.modified.to_rfc3339(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceListResult {
    pub ok: bool,
    pub message: String,
    pub surfaces: Vec<SurfaceSummaryDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceDeleteResult {
    pub ok: bool,
    pub message: String,
}

/// `surface_show`'s answer: which pane now shows the surface.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceShowResult {
    pub ok: bool,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tile: Option<u64>,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub affected_panes: Vec<u64>,
}

impl SurfaceShowResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            tile: None,
            focused: false,
            affected_panes: Vec::new(),
        }
    }
}

/// `surface_render`'s answer: the resolved tree, or a reason it could not be
/// built (a `surface_get`-style not-found, rather than a partial tree —
/// `impress_surface::resolve` itself never fails, so the only failure mode
/// here is "no such surface").
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceRenderResult {
    pub ok: bool,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree: Option<impress_surface::RenderTree>,
}

impl SurfaceRenderResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            tree: None,
        }
    }
}

/// `surface_state_get`'s answer.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceStateResult {
    pub ok: bool,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<serde_json::Value>,
}

impl SurfaceStateResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            state: None,
        }
    }
}

/// One effect the runtime carried out (or tried to) while dispatching an
/// event — named so a caller can tell "done" from "nobody was listening"
/// (root CLAUDE.md, ADR-0032) instead of a dispatch silently swallowing a
/// failed `call`/`publish`/`open`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct EffectOutcomeDto {
    /// `call` | `publish` | `emit` | `open` | `refresh`.
    pub kind: String,
    pub ok: bool,
    pub message: String,
}

/// `surface_dispatch`'s answer: the re-rendered tree plus what each effect
/// did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceDispatchResult {
    pub ok: bool,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree: Option<impress_surface::RenderTree>,
    #[serde(default)]
    pub effects: Vec<EffectOutcomeDto>,
}

impl SurfaceDispatchResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            tree: None,
            effects: Vec::new(),
        }
    }
}

/// One row as `surface_events` / `surface_wait` show it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceEventDto {
    pub surface: String,
    pub host: String,
    pub seq: u64,
    pub name: String,
    pub payload: serde_json::Value,
    pub at: String,
}

impl From<&crate::store::EventRow> for SurfaceEventDto {
    fn from(row: &crate::store::EventRow) -> Self {
        Self {
            surface: row.surface.to_string(),
            host: row.host.clone(),
            seq: row.seq,
            name: row.name.clone(),
            payload: row.payload.clone(),
            at: row.at.to_rfc3339(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceEventsResult {
    pub ok: bool,
    pub message: String,
    #[serde(default)]
    pub events: Vec<SurfaceEventDto>,
    /// The cursor to pass as `after_seq` on the next call.
    pub next_seq: u64,
}

impl SurfaceEventsResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            events: Vec::new(),
            next_seq: 0,
        }
    }
}

/// `surface_wait`'s answer: the same shape as [`SurfaceEventsResult`] plus
/// `timed_out`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceWaitResult {
    pub ok: bool,
    pub message: String,
    #[serde(default)]
    pub events: Vec<SurfaceEventDto>,
    pub next_seq: u64,
    pub timed_out: bool,
}

impl SurfaceWaitResult {
    pub fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            events: Vec::new(),
            next_seq: 0,
            timed_out: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceExamplesResult {
    pub examples: Vec<SurfaceSpec>,
}
