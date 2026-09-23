//! `LayoutSelftestService` — the capability catalogue through the codegen
//! pipeline, so `run_selftest` shows up as the MCP tool
//! `layout-selftest-service_run-selftest` and as a CLI subcommand with no
//! hand-written glue.
//!
//! This is the headless entry point the root briefing asks every feature to
//! have: confirming the layout verbs work must not require clicking a GUI, and
//! after L6 it must not require a Mac either.

use std::sync::Arc;

use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use crate::report::SelfTestReport;

/// Run the layout tree's capability self-tests and return a structured report.
#[impress_service]
pub trait LayoutSelftestService: Send + Sync + 'static {
    /// Run the layout capability self-tests and return the report.
    ///
    /// `tier` accepts:
    ///
    /// * `"a"` — pure Rust over a private in-memory store: every D8 verb,
    ///   both undo rings, the cold start and the one-live-row invariant.
    ///   Nothing here touches the user's store.
    /// * `"b"` — drives the RUNNING impress app over `/api/layout/*` and
    ///   `/api/surface/*` (port 23125). Skips cleanly when no app answers, so
    ///   a headless box stays green. It restores the arrangement it found.
    /// * `"all"`/`""` — both, Tier A first.
    #[impress_method]
    async fn run_selftest(&self, tier: String) -> SelfTestReport;
}

/// Default implementation. Stateless.
#[derive(Default, Clone, Copy)]
pub struct DefaultLayoutSelftestService;

#[async_trait::async_trait]
impl LayoutSelftestService for DefaultLayoutSelftestService {
    async fn run_selftest(&self, tier: String) -> SelfTestReport {
        match tier.trim().to_ascii_lowercase().as_str() {
            "b" => crate::run_tier_b().await,
            // `all` is both catalogues in one report: Tier A's headless proof
            // that the verbs are right, then Tier B's proof that the app
            // actually performs them. One report, because a caller asking for
            // "everything" wants one pass/fail, not two.
            "all" | "" => {
                let mut results = crate::tier_a::run().await;
                results.extend(crate::tier_b::run(crate::tier_b::IMPRESS_BASE_URL).await);
                SelfTestReport::from_results(results)
            }
            _ => crate::run_tier_a().await,
        }
    }
}

fn selftest_instance() -> Arc<dyn LayoutSelftestService> {
    Arc::new(DefaultLayoutSelftestService)
}

impress_service_impl! {
    service = LayoutSelftestService,
    impl = DefaultLayoutSelftestService,
    instance = || selftest_instance(),
    methods = [
        /// Run the layout tree's capability self-tests (`tier` = a | b | all).
        run_selftest(tier: String) -> SelfTestReport,
    ],
}
