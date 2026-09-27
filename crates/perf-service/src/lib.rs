//! `PerfService` — the agent-facing read of the pipeline's own performance
//! aggregator (G7b, plan-auto-gui-and-self-docs.md § Profiling, G7 row,
//! D-G2).
//!
//! Both verbs are thin, read-only wrappers over
//! `impress_service_core::pipeline::perf`: `summary` returns the bucket
//! table [`perf::summary`] keeps, field-for-field
//! `PerfBucketStat` (`packages/ImpressLogging/Sources/ImpressLogging/PerfMetrics.swift:47`)
//! so the Console's Performance tab can show a Rust row next to a Swift one
//! with no second schema; `trace` would return the recorded span tree for
//! one trace id, but no bounded span log exists yet in this workspace — only
//! the aggregated buckets do (`perf::summary`'s reservoir keeps sample
//! *durations*, not a per-call, per-trace record) — so it refuses
//! `unavailable` naming what is missing, rather than pretend a tree it does
//! not have. A per-trace span log (and the trace export this unlocks:
//! Chrome/Perfetto JSON, folded stacks) is G7c.
//!
//! Neither verb takes or returns an argument value from a verb call — only
//! names, counts and durations the pipeline's own `verb`-target span
//! already carries (P7: a span records the verb name, `ok`, `code`, sizes
//! and id-shaped arguments only). `summary`'s `prefix` argument is an
//! operator-supplied filter string (e.g. `"verb:imbib"`), never echoed
//! anywhere but this call's own result.

use impress_service_core::async_trait;
use impress_service_core::pipeline::perf;
use impress_service_macros::{impress_service, impress_service_impl};

#[allow(unused_imports)]
use impress_service_macros::{impress_example, impress_method};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub use perf::PerfBucketStat;

/// Result of [`PerfService::summary`].
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PerfSummaryResult {
    pub ok: bool,
    /// One row per bucket whose key starts with the call's `prefix`
    /// (default `""`, matching everything), sorted by key
    /// (`"verb:<name>"` or `"io:<name>"`).
    pub buckets: Vec<PerfBucketStat>,
}

/// Result of [`PerfService::trace`].
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PerfTraceResult {
    pub ok: bool,
    /// Always empty in this build — see the crate doc: no bounded span log
    /// is kept yet (G7c), only aggregated buckets.
    pub message: String,
}

/// `PerfService` — a read of the in-process performance aggregator that
/// folds the pipeline's own `verb`-target spans into per-name latency
/// buckets. Never records or returns an argument value.
#[impress_service]
pub trait PerfService: Send + Sync + 'static {
    /// The aggregator's bucket rows: count, total/min/max/p50/p95
    /// duration, keyed `"verb:<name>"` (and `"io:<name>"` for an I/O seam
    /// span, once one exists). Pass `prefix` to narrow the rows returned,
    /// e.g. `"verb:imbib"` for one service's verbs; the default (empty)
    /// returns every bucket. A fresh process with no verb calls yet
    /// returns an empty list, not an error.
    #[impress_method(safety = read_only)]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(name = "prefixed", args = r#"{"prefix": "verb:perf-service"}"#)]
    async fn summary(&self, prefix: Option<String>) -> PerfSummaryResult;

    /// The recorded span tree for one trace id. Refuses `unavailable`: no
    /// bounded span log is kept in this build (see the crate doc) — only
    /// the aggregated buckets `summary` reads are, which have no per-trace
    /// or per-call identity to look up. G7c adds the span log this verb
    /// needs.
    #[impress_method(safety = read_only)]
    #[impress_example(
        name = "no-span-log",
        args = r#"{"trace_id": "00000000-0000-0000-0000-000000000000"}"#,
        expect = r#"{"ok": false}"#
    )]
    async fn trace(&self, trace_id: String) -> PerfTraceResult;
}

/// The default (and only) implementation: reads
/// [`impress_service_core::pipeline::perf`]'s process-wide bucket table.
/// Holds no state of its own — the aggregator is already process-wide, kept
/// by the installed `tracing` layer (`impress-store-ffi`'s log-sink
/// install, `impress-mcp`/`impress-cli`'s `main`), not by this service.
#[derive(Clone, Default)]
pub struct DefaultPerfService;

impl DefaultPerfService {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait::async_trait]
impl PerfService for DefaultPerfService {
    async fn summary(&self, prefix: Option<String>) -> PerfSummaryResult {
        let buckets = perf::summary(prefix.as_deref().unwrap_or(""));
        PerfSummaryResult { ok: true, buckets }
    }

    async fn trace(&self, _trace_id: String) -> PerfTraceResult {
        PerfTraceResult {
            ok: false,
            message: "unavailable: no bounded span log is kept in this build — only \
                      aggregated buckets (see perf-service_summary); a per-trace span \
                      log is G7c"
                .to_string(),
        }
    }
}

impress_service_impl! {
    service = PerfService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [],
    },
    impl = DefaultPerfService,
    instance = DefaultPerfService::new,
    strict_args = true,
    methods = [
        /// The aggregator's bucket rows: count, total/min/max/p50/p95
        /// duration, keyed `"verb:<name>"` (and `"io:<name>"` once an I/O
        /// seam span exists). Narrow with `prefix`; empty (default) returns
        /// every bucket.
        summary(prefix: Option<String>) -> PerfSummaryResult,
        /// The recorded span tree for one trace id. Refuses `unavailable` —
        /// no bounded span log is kept in this build; G7c adds it.
        trace(trace_id: String) -> PerfTraceResult,
    ],
}

#[cfg(test)]
mod tests {
    use impress_service_core::pipeline::{identity::CallerIdentity, invoke_blocking, Call};
    use impress_service_core::McpToolDescriptor;
    use serde_json::json;
    use std::sync::Once;

    /// The pipeline's `verb` span is a no-op with no `tracing` subscriber
    /// installed — this test binary installs the same aggregator layer
    /// `impress-store-ffi`'s `install()` and the MCP/CLI `main`s install in
    /// a real process, once per process, so `perf::summary` sees the calls
    /// this test makes through the linked inventory.
    fn ensure_subscriber() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            use tracing_subscriber::layer::SubscriberExt;
            let subscriber =
                tracing_subscriber::registry().with(impress_service_core::pipeline::perf::layer());
            let _ = tracing::subscriber::set_global_default(subscriber);
        });
    }

    /// Calls `name` the way MCP, the CLI and impel actually do: through
    /// `pipeline::invoke` — not `tool.handler` directly, which bypasses the
    /// pipeline entirely (span, policy, audit) and so would never populate
    /// the aggregator this crate reads.
    fn call(name: &str, args: serde_json::Value) -> serde_json::Value {
        ensure_subscriber();
        let tool = McpToolDescriptor::iter()
            .find(|t| t.name == name)
            .unwrap_or_else(|| panic!("{name} should be registered in the inventory"));
        invoke_blocking(tool.verb, Call::new(CallerIdentity::agent("test"), args))
            .unwrap_or_else(|e| panic!("{name} failed: {e:?}"))
    }

    /// The proof the work package asks for: after a few verbs run through
    /// the pipeline (this test's own two calls, at minimum — `summary`
    /// and `trace` are themselves invoked through the linked inventory,
    /// so they are `verb:*` spans too by the time `summary` reads them),
    /// `perf-service_summary` lists `verb:*` rows with nonzero counts.
    #[test]
    fn summary_lists_verb_rows_with_nonzero_counts_after_a_few_calls() {
        // Warm the aggregator: a handful of real inventory calls, through
        // the pipeline, the same way MCP/CLI/impel dispatch — not the trait
        // directly, which would bypass the `verb`-target span entirely.
        for _ in 0..3 {
            call("perf-service_trace", json!({"trace_id": "warm-up"}));
        }

        let result = call(
            "perf-service_summary",
            json!({"prefix": "verb:perf-service"}),
        );
        assert_eq!(result["ok"], json!(true));
        let buckets = result["buckets"].as_array().expect("buckets array");
        assert!(
            !buckets.is_empty(),
            "expected at least one verb:* bucket after warming the aggregator, got {buckets:?}"
        );
        let trace_bucket = buckets
            .iter()
            .find(|b| b["name"] == json!("verb:perf-service_trace"))
            .unwrap_or_else(|| panic!("no verb:perf-service_trace bucket in {buckets:?}"));
        assert!(
            trace_bucket["count"].as_u64().unwrap_or(0) >= 3,
            "expected count >= 3, got {trace_bucket:?}"
        );
        assert!(trace_bucket["totalNanos"].as_u64().unwrap_or(0) > 0);
        assert_eq!(trace_bucket["mainThreadCount"], json!(0));
        assert_eq!(trace_bucket["breachCount"], json!(0));
        assert!(trace_bucket.get("budgetNanos").is_none());
    }

    #[test]
    fn trace_refuses_clearly_with_no_span_log() {
        let result = call(
            "perf-service_trace",
            json!({"trace_id": "00000000-0000-0000-0000-000000000000"}),
        );
        assert_eq!(result["ok"], json!(false));
        assert!(result["message"]
            .as_str()
            .unwrap_or("")
            .contains("no bounded span log"));
    }

    #[test]
    fn an_empty_prefix_matches_every_bucket() {
        call("perf-service_trace", json!({"trace_id": "prefix-test"}));
        let all = call("perf-service_summary", json!({}));
        let scoped = call(
            "perf-service_summary",
            json!({"prefix": "verb:perf-service_trace"}),
        );
        let all_buckets = all["buckets"].as_array().unwrap();
        let scoped_buckets = scoped["buckets"].as_array().unwrap();
        assert!(all_buckets.len() >= scoped_buckets.len());
        assert!(scoped_buckets.iter().all(|b| b["name"]
            .as_str()
            .unwrap()
            .starts_with("verb:perf-service_trace")));
    }
}
