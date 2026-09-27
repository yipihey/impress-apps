//! W1 (plan-self-reflective-layer.md): the workflow spec, its validator and
//! its pure planner — `pure` tier (`docs/kit-manifest.md`).
//!
//! A workflow (`impress/workflow@1.0.0`) is a stored, reviewable action
//! sequence: a trigger instead of a widget, the surface action vocabulary
//! for its `steps` (reused, never forked — WF-2), guards and review
//! metadata (D-R6). This crate owns:
//!
//! - [`spec`] — [`spec::WorkflowSpec`], [`spec::Trigger`], [`spec::Guards`],
//!   [`spec::Review`], serde + (behind `schema`) `JsonSchema`.
//! - [`validate::validate`] — every structural and workflow-only problem a
//!   spec can have.
//! - [`plan::plan`] — given one trigger event already fired, what the
//!   workflow's steps do: `impress_surface::reduce` over a synthetic
//!   single-node spec, returning the same `Effect`s a surface's own
//!   `reduce` would (a `Call` is returned, never executed here).
//!
//! **No I/O, no store, no async, no time, no verb inventory.** Running a
//! workflow *on a schedule* — turning `(workflows, clock, cursors)` into
//! which ones fire right now — is W2's planner in `impel-taskd`, not this
//! crate; storing, dry-running and reviewing a workflow is
//! `impress-workflow-service` (a sibling `store`-tier crate), which calls
//! into this one exactly as `impress-surface-service` calls into
//! `impress-surface`.

pub mod plan;
pub mod spec;
pub mod validate;

pub use plan::{plan, to_surface_spec, Effect, ReduceError};
pub use spec::{
    Author, Guards, Review, Trigger, WorkflowSpec, WorkflowState, WORKFLOW_SCHEMA_REF,
    WORKFLOW_WIRE_VERSION,
};
pub use validate::{validate, validate_with, Problem, Severity, VerbEffects};
