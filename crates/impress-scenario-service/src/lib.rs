//! S1: the scenario verbs, `impress/scenario@1.0.0` records, and the Tier
//! A/B runners (docs/plan-self-reflective-layer.md § Scenarios).
//!
//! * [`store`] — `ScenarioStore`, the store side of a stored scenario.
//! * [`tier_a`] — [`tier_a::TierACaller`], the pipeline against a
//!   per-scenario scratch store (H-P2-3).
//! * [`tier_b`] — [`tier_b::TierBCaller`], the shared loopback client
//!   ([`shared_client`]) against a running app.
//! * [`service`] — `ImpressScenarioService`, the five verbs.

pub mod dto;
pub mod service;
pub mod shared_client;
pub mod store;
pub mod tier_a;
pub mod tier_b;

pub use service::{DefaultImpressScenarioService, ImpressScenarioService};
pub use shared_client::LoopbackClient;
pub use store::{ScenarioRow, ScenarioStore};
pub use tier_a::TierACaller;
pub use tier_b::TierBCaller;
