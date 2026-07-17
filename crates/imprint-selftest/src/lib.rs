//! Declarative capability self-tests for imprint.
//!
//! Development on imprint has been slowed by having to click the GUI to
//! confirm a feature works. This crate turns "does feature X work?" into an
//! executable catalog an agent can run headlessly:
//!
//! * **Tier A** ([`tier_a`]) — pure Rust against the `imprint-service` traits.
//!   No app, no UI, no network. These run as ordinary `cargo test` and are the
//!   payoff of pushing logic into Rust: a capability becomes a fast assertion
//!   instead of a manual click-through.
//! * **Tier B** ([`tier_b`]) — drives a *running* imprint app over its HTTP
//!   automation API (localhost:23121). Covers the parts that genuinely need the
//!   live app (real compile to PDF, cross-document search over the live index).
//!   When no app is running, Tier B checks are **skipped**, not failed.
//!
//! Everything funnels into a single [`SelfTestReport`] that is `Serialize`, so
//! the same report is surfaced by the CLI, over HTTP, and through MCP.

use std::future::Future;
use std::time::Instant;

pub mod report;
pub mod service;
pub mod tier_a;
pub mod tier_b;

pub use report::{CapabilityResult, SelfTestReport, Tier};
pub use service::{DefaultImprintSelftestService, ImprintSelftestService};

/// Run one capability check, timing it and packaging the outcome.
///
/// The check returns `Ok(detail)` on success or `Err(reason)` on failure.
/// `detail`/`reason` become the human-readable evidence in the report.
pub async fn check<F, Fut>(id: &str, description: &str, tier: Tier, body: F) -> CapabilityResult
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<String, String>>,
{
    let start = Instant::now();
    let outcome = body().await;
    let duration_ms = start.elapsed().as_millis() as u64;
    let (pass, detail) = match outcome {
        Ok(d) => (true, d),
        Err(e) => (false, e),
    };
    CapabilityResult {
        id: id.to_string(),
        description: description.to_string(),
        tier,
        pass,
        detail,
        duration_ms,
        skipped: false,
    }
}

/// Convenience for a skipped capability (e.g. Tier B with no app running).
pub fn skipped(id: &str, description: &str, tier: Tier, reason: &str) -> CapabilityResult {
    CapabilityResult {
        id: id.to_string(),
        description: description.to_string(),
        tier,
        pass: true,
        detail: reason.to_string(),
        duration_ms: 0,
        skipped: true,
    }
}

/// Run only the Tier A (pure-Rust) capabilities. Fast; safe in CI without a UI.
pub async fn run_tier_a() -> SelfTestReport {
    SelfTestReport::from_results(tier_a::run().await)
}

/// Run Tier B (live-app) capabilities against `base_url` (e.g.
/// `http://127.0.0.1:23121`). If the app isn't reachable, all Tier B
/// capabilities are reported as skipped.
pub async fn run_tier_b(base_url: &str) -> SelfTestReport {
    SelfTestReport::from_results(tier_b::run(base_url).await)
}

/// Run both tiers and merge into one report.
pub async fn run_all(base_url: &str) -> SelfTestReport {
    let mut results = tier_a::run().await;
    results.extend(tier_b::run(base_url).await);
    SelfTestReport::from_results(results)
}

/// The default imprint automation base URL.
pub const DEFAULT_BASE_URL: &str = "http://127.0.0.1:23121";
