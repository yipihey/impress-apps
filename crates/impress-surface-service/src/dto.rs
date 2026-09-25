//! Wire types the surface verbs take and return.
//!
//! As `impress-layout-service/src/dto.rs`'s module docs put it: a crate type
//! that already derives `serde` **and** `schemars::JsonSchema` is used
//! **directly** on the trait — [`impress_surface::SurfaceSpec`],
//! [`impress_surface::RenderTree`], [`impress_surface::Event`]. What is here
//! is only the shapes those crates do not have: how a caller names a pane to
//! show a surface in, and the result envelopes.

use impress_service_core::refusal::codes;
use impress_service_core::Refusal;
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
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The row's revision: 1 on create, +1 on every update. Pass it back as
    /// `surface_update`'s `expected_revision` to refuse a lost update.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
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
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
            id: None,
            name: None,
            version: None,
            revision: None,
            spec: None,
            tags: Vec::new(),
            created: None,
            modified: None,
        }
    }

    pub fn from_row(row: &crate::store::SurfaceRow) -> Self {
        Self {
            ok: true,
            code: None,
            message: format!("surface '{}' ({})", row.name, row.id),
            id: Some(row.id.to_string()),
            name: Some(row.name.clone()),
            version: row.version.clone(),
            revision: Some(row.revision),
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
    /// See [`SurfaceResult::revision`].
    #[serde(default)]
    pub revision: u64,
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
            revision: row.revision,
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
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub surfaces: Vec<SurfaceSummaryDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceDeleteResult {
    pub ok: bool,
    pub message: String,
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

/// `surface_show`'s answer: which pane now shows the surface.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceShowResult {
    pub ok: bool,
    pub message: String,
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tile: Option<u64>,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub affected_panes: Vec<u64>,
}

impl SurfaceShowResult {
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
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
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree: Option<impress_surface::RenderTree>,
    /// Every source whose fetch failed on this render, with the reason. The
    /// tree is still returned — a failed source only empties the paths it
    /// fed, and the placeholders drawn for those paths carry the same
    /// message as their `reason`. This field is the machine-readable copy,
    /// for an agent calling `surface_render` directly rather than reading
    /// the rendered pane. Empty on a render where every source answered.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub source_errors: Vec<SourceError>,
}

impl SurfaceRenderResult {
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
            tree: None,
            source_errors: Vec::new(),
        }
    }
}

/// One source that did not answer, and why — the wire form of
/// [`crate::runtime::SurfaceRuntime`]'s `source_errors` map.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SourceError {
    /// The source's name as the spec declares it.
    pub name: String,
    /// What the failed fetch said — a refusal from the verb, a transport
    /// error, or "imprint is not running".
    pub message: String,
}

/// `surface_state_get`'s answer.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceStateResult {
    pub ok: bool,
    pub message: String,
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<serde_json::Value>,
}

impl SurfaceStateResult {
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
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
    /// Why this effect failed, machine-readable: `unknown-verb`,
    /// `verb-failed`, `no-pane`, a layout refusal's own code (`unknown-tile`,
    /// …), `store-error`. Absent when it succeeded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

impl EffectOutcomeDto {
    pub fn done(kind: &str, message: impl Into<String>) -> Self {
        Self {
            kind: kind.to_string(),
            ok: true,
            message: message.into(),
            code: None,
        }
    }

    pub fn failed(kind: &str, refusal: Refusal) -> Self {
        Self {
            kind: kind.to_string(),
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
        }
    }
}

/// `surface_dispatch`'s answer: the re-rendered tree plus what each effect
/// did.
///
/// **When `ok` is true.** A dispatch is `ok` only when the event was reduced
/// AND every effect it produced succeeded. Three outcomes:
///
/// * the event could not be reduced (no such widget, a template that does not
///   resolve, no such surface): `ok: false`, the refusal's own `code`, no
///   `tree`, no `effects`, and nothing was written;
/// * the event was reduced and its state saved, but at least one effect
///   failed (a `call` the verb refused, a `publish` with no pane to publish
///   from): `ok: false`, `code: "effect-failed"`, `effects_failed` > 0, the
///   message naming each failure, and the re-rendered `tree` and every
///   per-effect outcome in `effects` — the state change stands, and the
///   caller can see exactly which effect did not happen (review RS-S12,
///   AC-F11);
/// * everything happened: `ok: true`.
///
/// A source that fails while re-rendering does not make a dispatch fail — the
/// event was handled — but it is listed in `source_errors`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceDispatchResult {
    pub ok: bool,
    pub message: String,
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree: Option<impress_surface::RenderTree>,
    /// What each effect did, in the order the reducer produced them.
    #[serde(default)]
    pub effects: Vec<EffectOutcomeDto>,
    /// How many of `effects` failed. Non-zero means `ok` is false.
    #[serde(default)]
    pub effects_failed: u32,
    /// Sources that failed while re-rendering after the dispatch. See
    /// [`SurfaceRenderResult::source_errors`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub source_errors: Vec<SourceError>,
}

impl SurfaceDispatchResult {
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
            tree: None,
            effects: Vec::new(),
            effects_failed: 0,
            source_errors: Vec::new(),
        }
    }

    /// The answer for a dispatch that was reduced: `ok` only when every
    /// effect succeeded (see the type's docs).
    pub fn dispatched(
        tree: impress_surface::RenderTree,
        effects: Vec<EffectOutcomeDto>,
        source_errors: Vec<SourceError>,
    ) -> Self {
        let failed: Vec<&EffectOutcomeDto> = effects.iter().filter(|e| !e.ok).collect();
        let (ok, code, message) = if failed.is_empty() {
            (
                true,
                None,
                format!("dispatched; {} effect(s)", effects.len()),
            )
        } else {
            let reasons: Vec<String> = failed
                .iter()
                .map(|e| format!("{}: {}", e.kind, e.message))
                .collect();
            (
                false,
                Some(codes::EFFECT_FAILED.to_string()),
                format!(
                    "dispatched; {} effect(s), {} failed — {}",
                    effects.len(),
                    failed.len(),
                    reasons.join("; ")
                ),
            )
        };
        let effects_failed = failed.len() as u32;
        Self {
            ok,
            message,
            code,
            tree: Some(tree),
            effects,
            effects_failed,
            source_errors,
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
    /// Who caused it: `human` for a click or edit in the pane, `agent` for a
    /// dispatch over MCP or HTTP (review SK-K5, AC-F5). An agent waiting on
    /// `surface_wait` tells the person's action from its own by this.
    pub actor: String,
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
            actor: crate::runtime::actor_name(row.actor).to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceEventsResult {
    pub ok: bool,
    pub message: String,
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default)]
    pub events: Vec<SurfaceEventDto>,
    /// The cursor to pass as `after_seq` on the next call — the `seq` of the
    /// last event returned, or `after_seq` itself when none were.
    pub next_seq: u64,
    /// True when the ring (the last 200 events) was pruned past `after_seq`:
    /// events between it and the first one returned are gone.
    #[serde(default)]
    pub gap: bool,
}

impl SurfaceEventsResult {
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
            events: Vec::new(),
            next_seq: 0,
            gap: false,
        }
    }
}

/// `surface_wait`'s answer: the same shape as [`SurfaceEventsResult`] plus
/// `timed_out`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceWaitResult {
    pub ok: bool,
    pub message: String,
    /// Why it was refused, machine-readable (`not-found`, `conflict`,
    /// `invalid-argument`, `store-error`, `effect-failed`, a reduce error's
    /// own code, …). Absent when `ok` is true. See
    /// `impress_service_core::refusal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default)]
    pub events: Vec<SurfaceEventDto>,
    pub next_seq: u64,
    pub timed_out: bool,
    /// See [`SurfaceEventsResult::gap`].
    #[serde(default)]
    pub gap: bool,
}

impl SurfaceWaitResult {
    /// A refusal: `ok: false`, the refusal's `code` and `message`.
    pub fn refused(refusal: Refusal) -> Self {
        Self {
            ok: false,
            message: refusal.message,
            code: Some(refusal.code),
            events: Vec::new(),
            next_seq: 0,
            timed_out: false,
            gap: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SurfaceExamplesResult {
    pub examples: Vec<SurfaceSpec>,
}
