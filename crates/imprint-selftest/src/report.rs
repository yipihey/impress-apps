//! Report types for the imprint self-test harness.
//!
//! A capability is one testable behavior of imprint ("the outline extractor
//! finds headings", "a section round-trips through the store"). Each produces
//! a [`CapabilityResult`]. The aggregate [`SelfTestReport`] is `Serialize` so
//! it can be surfaced verbatim over HTTP (`/api/selftest`), through an MCP
//! tool, or printed by the CLI — one report shape everywhere.

use serde::{Deserialize, Serialize};

/// Which layer a capability exercises.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// Pure Rust against the `imprint-service` traits — fast, headless, no UI.
    A,
    /// Drives a running imprint app over HTTP.
    B,
}

/// Outcome of a single capability check.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapabilityResult {
    pub id: String,
    pub description: String,
    pub tier: Tier,
    pub pass: bool,
    /// Human-readable evidence: what was observed. On failure, why.
    pub detail: String,
    pub duration_ms: u64,
    /// True when the check could not run (e.g. Tier B with no app running) and
    /// was skipped rather than failed. Skips do not count against `passed`.
    #[serde(default)]
    pub skipped: bool,
}

/// The full self-test outcome.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SelfTestReport {
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
            results,
            total,
            passed,
            failed,
            skipped,
            duration_ms,
        }
    }

    /// True when no capability failed (skips are tolerated).
    pub fn ok(&self) -> bool {
        self.failed == 0
    }

    /// One-line summary, e.g. "12 passed, 0 failed, 3 skipped (48ms)".
    pub fn summary(&self) -> String {
        format!(
            "{} passed, {} failed, {} skipped ({}ms)",
            self.passed, self.failed, self.skipped, self.duration_ms
        )
    }
}
