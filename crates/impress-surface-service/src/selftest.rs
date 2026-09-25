//! `SurfaceSelftestService` — the capability catalogue through the codegen
//! pipeline, so `run_selftest` shows up as the MCP tool
//! `surface-selftest-service_run-selftest` and as a CLI subcommand with no
//! hand-written glue — mirroring `impress-layout-service::LayoutSelftestService`
//! exactly (including the tool-name precedent: neither trait's kebab name
//! carries an `impress-` prefix, unlike `ImpressSurfaceService` itself, whose
//! prefix `docs/agent-surfaces.md` fixes explicitly).
//!
//! Confirming a surface capability works must not require clicking a GUI —
//! the same rule `imprint-selftest` and `impress-layout-service`'s own
//! catalogue already keep.

use std::sync::Arc;

use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use crate::report::SelfTestReport;

/// Run the surface capability self-tests and return a structured report.
#[impress_service]
pub trait SurfaceSelftestService: Send + Sync + 'static {
    /// Run the surface capability self-tests and return the report.
    ///
    /// `tier` is `"a"` (pure Rust over a private in-memory store — every
    /// verb plus the create → show → dispatch → render → emit → events
    /// loop), `"all"` or `""` (the same), or `"b"`: one skipped entry
    /// pointing at the live surface checks, which are the layout self-test's
    /// Tier B (`layout-selftest-service_run-selftest --tier b`, the
    /// `surface.*` capabilities). Any other value is refused — a report
    /// with one failed `tier` entry — rather than quietly running Tier A
    /// (review AC-F25). Nothing here touches the user's store.
    #[impress_method]
    async fn run_selftest(&self, tier: String) -> SelfTestReport;
}

/// Default implementation. Stateless.
#[derive(Default, Clone, Copy)]
pub struct DefaultSurfaceSelftestService;

#[async_trait::async_trait]
impl SurfaceSelftestService for DefaultSurfaceSelftestService {
    async fn run_selftest(&self, tier: String) -> SelfTestReport {
        match tier.trim().to_ascii_lowercase().as_str() {
            "b" => SelfTestReport::from_results(vec![crate::skipped(
                "tier-b",
                "drive a running app over HTTP",
                crate::report::Tier::B,
                "the live surface checks are Tier B of the layout self-test \
                 (`layout-selftest-service_run-selftest --tier b`, the `surface.*` capabilities)",
            )]),
            "a" | "all" | "" => crate::run_tier_a().await,
            other => SelfTestReport::from_results(vec![crate::CapabilityResult {
                id: "tier".to_string(),
                description: "choose a tier".to_string(),
                tier: crate::report::Tier::A,
                pass: false,
                detail: format!("unknown tier '{other}': use a, b or all"),
                duration_ms: 0,
                skipped: false,
            }]),
        }
    }
}

fn selftest_instance() -> Arc<dyn SurfaceSelftestService> {
    Arc::new(DefaultSurfaceSelftestService)
}

impress_service_impl! {
    service = SurfaceSelftestService,
    impl = DefaultSurfaceSelftestService,
    instance = || selftest_instance(),
    methods = [
        /// Run the surface capability self-tests (`tier` = a | b | all).
        run_selftest(tier: String) -> SelfTestReport,
    ],
}
