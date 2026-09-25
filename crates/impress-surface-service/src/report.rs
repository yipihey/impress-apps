//! Report types for the surface self-test.
//!
//! A copy of `impress-layout-service::report`'s two structs rather than a
//! dependency on that crate for them specifically: this crate already
//! depends on `impress-layout-service` for `surface_show`'s composed verbs,
//! so there is no cycle either way, but the shapes are small enough (and the
//! crate already gives the reasoning for why a THIRD consumer should get a
//! shared `impress-selftest-core` instead of a second copy) that mirroring
//! them here — field-for-field identical — keeps this crate's self-test
//! surface independent of that one's internal report module path.

use serde::{Deserialize, Serialize};

/// Which layer a capability exercises.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// Pure Rust against the `ImpressSurfaceService` trait over an
    /// in-memory store — fast, headless, no UI, no app.
    A,
    /// Drives a running app over its HTTP automation surface
    /// (`impress-layout-service`'s `tier_b`, which covers `/api/layout/*` and
    /// `/api/surface/*`). Every capability is skipped, and the report is not
    /// `ok`, when no app answers.
    B,
}

/// Outcome of a single capability check.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CapabilityResult {
    pub id: String,
    pub description: String,
    pub tier: Tier,
    pub pass: bool,
    /// Human-readable evidence: what was observed. On failure, why.
    pub detail: String,
    pub duration_ms: u64,
    /// True when the check could not run. A skipped capability has `pass:
    /// false` — nothing was shown to work — and counts as neither passed nor
    /// failed; it makes the report not `ok` (review RL-L18).
    #[serde(default)]
    pub skipped: bool,
}

/// The full self-test outcome.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SelfTestReport {
    /// True only when every capability ran and passed. A run that skipped
    /// anything — above all a Tier B run whose app was not reachable — is
    /// not `ok`: green after zero checks would be a pass that lies. The CLI
    /// exits non-zero when this is false.
    pub ok: bool,
    pub results: Vec<CapabilityResult>,
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub skipped: usize,
    pub duration_ms: u64,
}

impl SelfTestReport {
    pub fn from_results(results: Vec<CapabilityResult>) -> Self {
        let total = results.len();
        let passed = results.iter().filter(|r| r.pass && !r.skipped).count();
        let skipped = results.iter().filter(|r| r.skipped).count();
        let failed = results.iter().filter(|r| !r.pass && !r.skipped).count();
        let duration_ms = results.iter().map(|r| r.duration_ms).sum();
        Self {
            ok: failed == 0 && skipped == 0 && total > 0,
            results,
            total,
            passed,
            failed,
            skipped,
            duration_ms,
        }
    }

    /// See the `ok` field: every capability ran and passed.
    pub fn ok(&self) -> bool {
        self.ok
    }

    /// True when capabilities were skipped and none ran — the app was not
    /// there. What a caller prints as SKIPPED rather than as a pass or a
    /// failure.
    pub fn all_skipped(&self) -> bool {
        self.total > 0 && self.skipped == self.total
    }

    /// One-line summary, e.g. "12 passed, 0 failed, 0 skipped (48ms)".
    ///
    /// A run where nothing ran says so first — `SKIPPED: …` with the first
    /// skip's reason, which names the URL it tried.
    pub fn summary(&self) -> String {
        if self.all_skipped() {
            let why = self
                .results
                .first()
                .map(|r| r.detail.as_str())
                .unwrap_or("nothing ran");
            return format!("SKIPPED: {why} ({} capabilities not run)", self.total);
        }
        format!(
            "{} passed, {} failed, {} skipped ({}ms)",
            self.passed, self.failed, self.skipped, self.duration_ms
        )
    }

    /// The ids of the capabilities that failed — what a caller prints first.
    pub fn failures(&self) -> Vec<&str> {
        self.results
            .iter()
            .filter(|r| !r.pass && !r.skipped)
            .map(|r| r.id.as_str())
            .collect()
    }
}
