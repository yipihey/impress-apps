//! `ImprintSelftestService` — exposes the capability self-tests through the
//! impress service codegen pipeline, so `run_selftest` shows up automatically
//! as an MCP tool (`imprint-selftest-service_run-selftest`) and an
//! `imprint-cli` subcommand — no hand-written glue.
//!
//! This is the headless agent entry point: an agent (or CI) invokes the MCP
//! tool / CLI subcommand and gets back a structured [`SelfTestReport`]. Tier A
//! runs in-process; Tier B drives the running imprint app over HTTP.

use std::sync::Arc;

use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use crate::report::SelfTestReport;
use crate::DEFAULT_BASE_URL;

/// Run imprint's capability self-tests and return a structured report.
#[impress_service]
pub trait ImprintSelftestService: Send + Sync + 'static {
    /// Run the capability self-tests and return the report.
    ///
    /// `tier` accepts `"a"` (pure-Rust, headless), `"b"` (live app over HTTP),
    /// or `"all"`/`""` for both. Tier B targets the default imprint automation
    /// port (23121); unreachable → those capabilities are skipped, not failed.
    #[impress_method]
    async fn run_selftest(&self, tier: String) -> SelfTestReport;
}

/// Default implementation. Stateless.
#[derive(Default, Clone, Copy)]
pub struct DefaultImprintSelftestService;

#[async_trait::async_trait]
impl ImprintSelftestService for DefaultImprintSelftestService {
    async fn run_selftest(&self, tier: String) -> SelfTestReport {
        match tier.to_ascii_lowercase().as_str() {
            "a" => crate::run_tier_a().await,
            "b" => crate::run_tier_b(DEFAULT_BASE_URL).await,
            _ => crate::run_all(DEFAULT_BASE_URL).await,
        }
    }
}

fn selftest_instance() -> Arc<dyn ImprintSelftestService> {
    Arc::new(DefaultImprintSelftestService)
}

impress_service_impl! {
    service = ImprintSelftestService,
    impl = DefaultImprintSelftestService,
    instance = || selftest_instance(),
    methods = [
        /// Run imprint's capability self-tests (`tier` = a | b | all).
        run_selftest(tier: String) -> SelfTestReport,
    ],
}

#[cfg(test)]
mod tests {
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    #[test]
    fn run_selftest_registered_in_mcp_inventory() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        assert!(
            names.iter().any(|n| n.contains("run-selftest")),
            "MCP inventory missing run-selftest; have: {names:?}"
        );
    }

    #[test]
    fn run_selftest_registered_in_cli_inventory() {
        let names: Vec<&str> = CliSubcommand::iter().map(|c| c.name).collect();
        assert!(
            names.iter().any(|n| *n == "run-selftest"),
            "CLI inventory missing run-selftest; have: {names:?}"
        );
    }
}
