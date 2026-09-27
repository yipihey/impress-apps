//! The performance aggregator: a `tracing` layer that keeps per-name
//! latency buckets for the pipeline's own spans (G7b, plan-auto-gui-and-self-docs.md
//! § Profiling, G7 row).
//!
//! P2's per-call span (`pipeline::mod`, target `"verb"`) already carries
//! `name`, `ok`, `code`, `duration_us`, `result_bytes` — this layer is a
//! second [`tracing_subscriber::Layer`] on the same spans (installed
//! alongside `impress-store-ffi`'s `tracing_bridge`, which only forwards
//! lines to the Console) that folds every closed span into a running bucket
//! keyed `"{target}:{name}"`, e.g. `verb:t-service_echo`. The same scheme
//! covers an `io:*` seam span, should one ever open one (target `"io"`) —
//! today none exists in this workspace (PF-3's `with_write` chokepoint,
//! which would be the first, is deliberately left for a later package), so
//! only `verb:*` buckets are populated in this build.
//!
//! Buckets are exposed as [`PerfBucketStat`] — field-for-field the shape
//! `packages/ImpressLogging/Sources/ImpressLogging/PerfMetrics.swift`
//! already uses, serialized under the same JSON keys (`camelCase`, via
//! `#[serde(rename_all = "camelCase")]`) — so `perf-service_summary`'s rows
//! slot into the Console's Performance tab next to Swift's own, with no
//! second schema. `main_thread_count` is always 0 (the FFI is off the main
//! actor since wave 7 T2) and `budget_nanos`/`breach_count` are always
//! `None`/`0` here — Tier A budgets on examples are G7c.
//!
//! # What this layer must never record
//!
//! Only what the `verb` span itself already carries: name, ok, code,
//! duration, result size. No argument value ever reaches a span field
//! (P7), so no argument value can reach a bucket either.
//!
//! # Self vs total time
//!
//! A call that invokes another call inherits a `parent_call` (nested verb
//! spans exist — see `pipeline::mod`'s identity layer). On close, a span's
//! own duration is added to its bucket's `total`, and to its *parent's*
//! `child_us` counter (tracked in the span's extensions while it is open);
//! `self` is `total - child_us`, tracked per bucket as `self_total_ns`
//! alongside `total_nanos`, and is not currently exposed as its own
//! `PerfBucketStat` field (the Swift shape has none) — it is folded into
//! `total_nanos`/percentiles exactly as `duration_us` always has been,
//! and self-time bookkeeping exists so a later trace-tree export (G7c) has
//! it precomputed rather than needing a second pass over the span log.
//!
//! # Reservoir
//!
//! Each bucket keeps a fixed-size ring of up to [`RESERVOIR_CAP`] recent
//! sample durations; `p50`/`p95` are the nearest-rank percentile over
//! whatever is currently in the ring (matches `PerfMetrics.swift`'s own
//! 1024-sample ring and nearest-rank arithmetic, `:265-270`). `count` and
//! `total_nanos`/`min_nanos`/`max_nanos` are exact over every call ever
//! seen, not just the retained samples.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};
use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Level, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

/// The `tracing` targets this layer folds into buckets. `verb` is P2's
/// per-call span; `io` is reserved for a future I/O seam span (none exists
/// in this workspace yet — see the module doc).
pub const AGGREGATED_TARGETS: &[&str] = &["verb", "io"];

/// Samples retained per bucket for the percentile estimate.
pub const RESERVOIR_CAP: usize = 1024;

/// One bucket's live state.
struct Bucket {
    count: u64,
    total_nanos: u64,
    self_total_nanos: u64,
    min_nanos: u64,
    max_nanos: u64,
    /// A ring buffer: `samples[write_pos % cap]`, oldest overwritten first.
    samples: Vec<u64>,
    write_pos: usize,
}

impl Bucket {
    fn new() -> Self {
        Bucket {
            count: 0,
            total_nanos: 0,
            self_total_nanos: 0,
            min_nanos: u64::MAX,
            max_nanos: 0,
            samples: Vec::new(),
            write_pos: 0,
        }
    }

    fn record(&mut self, total_nanos: u64, self_nanos: u64) {
        self.count += 1;
        self.total_nanos += total_nanos;
        self.self_total_nanos += self_nanos;
        self.min_nanos = self.min_nanos.min(total_nanos);
        self.max_nanos = self.max_nanos.max(total_nanos);
        if self.samples.len() < RESERVOIR_CAP {
            self.samples.push(total_nanos);
        } else {
            self.samples[self.write_pos % RESERVOIR_CAP] = total_nanos;
        }
        self.write_pos = self.write_pos.wrapping_add(1);
    }

    /// Nearest-rank percentile (`p` in `0.0..=1.0`) over the retained
    /// samples — the same arithmetic `PerfMetrics.swift` uses.
    fn percentile(&self, p: f64) -> u64 {
        if self.samples.is_empty() {
            return 0;
        }
        let mut sorted = self.samples.clone();
        sorted.sort_unstable();
        let rank = ((p * sorted.len() as f64).ceil() as usize)
            .saturating_sub(1)
            .min(sorted.len() - 1);
        sorted[rank]
    }
}

/// One bucket, snapshotted — field-for-field `PerfBucketStat`
/// (`packages/ImpressLogging/Sources/ImpressLogging/PerfMetrics.swift:47`),
/// serialized under the same JSON keys.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PerfBucketStat {
    pub name: String,
    pub count: u64,
    pub total_nanos: u64,
    pub min_nanos: u64,
    pub max_nanos: u64,
    /// Always 0 for a Rust-side bucket: the FFI is off the main actor
    /// since wave 7 T2.
    pub main_thread_count: u64,
    pub p50_nanos: u64,
    pub p95_nanos: u64,
    /// Tier A budgets on examples are G7c; always `None` here.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget_nanos: Option<u64>,
    /// Always 0 here — see `budget_nanos`.
    pub breach_count: u64,
}

impl Bucket {
    fn snapshot(&self, name: &str) -> PerfBucketStat {
        PerfBucketStat {
            name: name.to_string(),
            count: self.count,
            total_nanos: self.total_nanos,
            min_nanos: if self.count == 0 { 0 } else { self.min_nanos },
            max_nanos: self.max_nanos,
            main_thread_count: 0,
            p50_nanos: self.percentile(0.50),
            p95_nanos: self.percentile(0.95),
            budget_nanos: None,
            breach_count: 0,
        }
    }
}

static BUCKETS: OnceLock<RwLock<BTreeMap<String, Bucket>>> = OnceLock::new();

fn buckets() -> &'static RwLock<BTreeMap<String, Bucket>> {
    BUCKETS.get_or_init(|| RwLock::new(BTreeMap::new()))
}

/// Every bucket whose key starts with `prefix` (an empty prefix matches
/// all), sorted by key.
pub fn summary(prefix: &str) -> Vec<PerfBucketStat> {
    let guard = buckets().read().unwrap_or_else(|p| p.into_inner());
    guard
        .iter()
        .filter(|(key, _)| key.starts_with(prefix))
        .map(|(key, bucket)| bucket.snapshot(key))
        .collect()
}

/// Clears every bucket. Test-only — a process has no verb to reset the
/// live aggregator (the point is an honest running history).
#[cfg(any(test, feature = "test-support"))]
pub fn reset_for_test() {
    buckets().write().unwrap_or_else(|p| p.into_inner()).clear();
}

// ---------------------------------------------------------------------------
// The layer
// ---------------------------------------------------------------------------

/// Fields captured off an aggregated span while it is open: `name` (the
/// bucket key's suffix) and, at close, `duration_us`.
#[derive(Default, Clone)]
struct SpanFields {
    name: Option<String>,
    duration_us: Option<u64>,
}

/// A closed child's contribution to its still-open parent's self time.
#[derive(Default)]
struct ChildNanos(AtomicU64);

struct FieldVisitor<'a>(&'a mut SpanFields);

impl Visit for FieldVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        match field.name() {
            "name" => self.0.name = Some(format!("{value:?}").trim_matches('"').to_string()),
            "duration_us" => {
                let text = format!("{value:?}");
                self.0.duration_us = text.trim_matches('"').parse().ok();
            }
            _ => {}
        }
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        if field.name() == "duration_us" {
            self.0.duration_us = Some(value);
        }
    }
}

fn is_aggregated(target: &str) -> bool {
    AGGREGATED_TARGETS.contains(&target)
}

/// The aggregator layer. Install with [`layer`] alongside whatever other
/// `tracing_subscriber::Layer`s the process runs (the FFI's log bridge,
/// an `env-filter` fmt layer, …) — this one never blocks and never talks
/// to a sink; it only updates the in-process bucket table `summary` reads.
pub struct PerfAggregatorLayer;

/// A fresh layer instance. Stateless — the buckets themselves live in a
/// process-wide table (`summary`/`reset_for_test`), so multiple installed
/// instances (e.g. one per test harness within the same process) share one
/// history; that mirrors the audit/log bridges' own process-wide state.
pub fn layer() -> PerfAggregatorLayer {
    PerfAggregatorLayer
}

impl<S> Layer<S> for PerfAggregatorLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        if !is_aggregated(attrs.metadata().target()) {
            return;
        }
        let mut fields = SpanFields::default();
        attrs.record(&mut FieldVisitor(&mut fields));
        if let Some(span) = ctx.span(id) {
            span.extensions_mut().insert(fields);
        }
    }

    fn on_record(&self, id: &Id, values: &Record<'_>, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(id) else { return };
        if !is_aggregated(span.metadata().target()) {
            return;
        }
        let mut ext = span.extensions_mut();
        let Some(fields) = ext.get_mut::<SpanFields>() else {
            return;
        };
        values.record(&mut FieldVisitor(fields));
    }

    fn on_close(&self, id: Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(&id) else { return };
        let target = span.metadata().target();
        if !is_aggregated(target) {
            return;
        }
        let fields = span
            .extensions()
            .get::<SpanFields>()
            .cloned()
            .unwrap_or_default();
        let Some(name) = fields.name.filter(|n| !n.is_empty()) else {
            return;
        };
        let Some(duration_us) = fields.duration_us else {
            return;
        };
        let total_nanos = duration_us.saturating_mul(1_000);
        let child_nanos = span
            .extensions()
            .get::<ChildNanos>()
            .map(|c| c.0.load(Ordering::Relaxed))
            .unwrap_or(0);
        let self_nanos = total_nanos.saturating_sub(child_nanos);

        let key = format!("{target}:{name}");
        buckets()
            .write()
            .unwrap_or_else(|p| p.into_inner())
            .entry(key)
            .or_insert_with(Bucket::new)
            .record(total_nanos, self_nanos);

        if let Some(parent) = span.parent() {
            if is_aggregated(parent.metadata().target()) {
                let mut ext = parent.extensions_mut();
                if let Some(child) = ext.get_mut::<ChildNanos>() {
                    child.0.fetch_add(total_nanos, Ordering::Relaxed);
                } else {
                    ext.insert(ChildNanos(AtomicU64::new(total_nanos)));
                }
            }
        }
    }
}

/// Which `tracing::Level`s this layer needs to see — `INFO`, where the
/// `verb` span is opened (`pipeline::mod`). A `max_level_hint` keeps a
/// filtered subscriber from paying for `DEBUG`/`TRACE` spans this layer
/// never reads.
pub fn max_level_hint() -> Option<Level> {
    Some(Level::INFO)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::layer::SubscriberExt;

    // `buckets()` is one process-wide table (by design — see the module doc's
    // "process-wide table" note on `layer()`), so these tests race under the
    // default parallel runner: `reset_for_test()` in one test can clear
    // another's in-flight writes, or a concurrently-running test's spans can
    // land in a `summary("")` a sibling test expected to be empty. A
    // module-local mutex serializes just these three tests against each
    // other without reaching for a `serial_test`-style crate dependency for
    // one file.
    static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn with_layer<F: FnOnce()>(f: F) {
        let subscriber = tracing_subscriber::registry().with(PerfAggregatorLayer);
        tracing::subscriber::with_default(subscriber, f);
    }

    #[test]
    fn a_closed_verb_span_updates_its_bucket() {
        let _serial = TEST_SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        reset_for_test();
        with_layer(|| {
            let span = tracing::info_span!(
                target: "verb",
                "verb",
                name = "perf-aggregator-test_alpha",
                ok = tracing::field::Empty,
                code = tracing::field::Empty,
                duration_us = tracing::field::Empty,
                result_bytes = tracing::field::Empty,
            );
            let _entered = span.enter();
            span.record("duration_us", 250u64);
            drop(_entered);
            drop(span);
        });
        let rows = summary("verb:perf-aggregator-test_alpha");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].count, 1);
        assert_eq!(rows[0].total_nanos, 250_000);
        assert_eq!(rows[0].min_nanos, 250_000);
        assert_eq!(rows[0].max_nanos, 250_000);
        assert_eq!(rows[0].p50_nanos, 250_000);
        assert_eq!(rows[0].main_thread_count, 0);
        assert_eq!(rows[0].breach_count, 0);
        assert!(rows[0].budget_nanos.is_none());
    }

    #[test]
    fn a_prefix_filters_the_summary() {
        let _serial = TEST_SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        reset_for_test();
        with_layer(|| {
            for n in 0..3 {
                let span = tracing::info_span!(
                    target: "verb",
                    "verb",
                    name = "perf-aggregator-test_beta",
                    ok = tracing::field::Empty,
                    code = tracing::field::Empty,
                    duration_us = tracing::field::Empty,
                    result_bytes = tracing::field::Empty,
                );
                let _entered = span.enter();
                span.record("duration_us", 10u64 + n);
                drop(_entered);
                drop(span);
            }
        });
        let all = summary("");
        assert!(all
            .iter()
            .any(|b| b.name == "verb:perf-aggregator-test_beta"));
        let none = summary("io:perf-aggregator-test_beta");
        assert!(none.is_empty());
        let row = summary("verb:perf-aggregator-test_beta")
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(row.count, 3);
        assert_eq!(row.total_nanos, (10 + 11 + 12) * 1_000);
    }

    #[test]
    fn a_span_outside_the_aggregated_targets_is_ignored() {
        let _serial = TEST_SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        reset_for_test();
        with_layer(|| {
            let span = tracing::info_span!(target: "layout", "layout-span");
            let _entered = span.enter();
            drop(_entered);
            drop(span);
        });
        assert!(summary("").is_empty());
    }
}
