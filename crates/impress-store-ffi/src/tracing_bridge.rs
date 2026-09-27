//! The Rust half of the layer, in the host's Console.
//!
//! `impress-layout-service`, `impress-surface-service` and this crate log
//! through `tracing` under two targets, `layout` and `surface` — the same
//! category names the Swift half passes to `ImpressLogging` (G7a moved these
//! off the `log` facade, D-P1; before wave 7 nothing received those lines: a
//! refused verb, a cold start, a failed source or effect, an external write
//! the feed picked up, all left no trace in `/api/logs`, so the Rust half had
//! to be debugged from Swift alone — reviews RL-L6, RS-S11, AC-F18).
//!
//! This crate's own `impress-service-core` invoker also opens one
//! `tracing::info_span!(target: "verb", ...)` per call (P2 of the profiling
//! addendum) and records `ok`/`code`/`duration_us`/`result_bytes` on it as
//! the call finishes. This layer forwards that span's fields to the same
//! Console, at `info`, when the span closes — a third bridged category,
//! `verb`.
//!
//! The host installs a [`SharedLogSink`] once per process with
//! [`install_log_sink`]; from then on every `tracing` event or closed `verb`
//! span whose target is a bridged category (or starts with `<category>::`)
//! at or above the chosen level reaches the sink as `(level, category,
//! message)`, and the Swift sink appends it to the Console, so
//! `/api/logs?category=layout`, `?category=surface` and `?category=verb`
//! carry Rust's lines next to Swift's. Records of any other target are not
//! forwarded: the store and the AI crates keep their own reporting, and a
//! flood of them would bury these.
//!
//! [`tracing_log::LogTracer`] is installed alongside this layer so a `log`
//! call anywhere in a dependency still reaches whatever `tracing` subscriber
//! is live — it will not be bridged into the Console (its target will not be
//! `layout`/`surface`/`verb`), but it will not be silently dropped either.
//!
//! The layer is called on whatever thread logged — a Tokio worker, a feed
//! thread, the caller's — and must not block or call back into Rust.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, OnceLock, RwLock};

use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

/// The categories bridged into the host's Console: the `tracing` targets the
/// layout and surface crates use (spelled as the Swift half spells them),
/// plus `verb`, this crate's own per-call span (P2).
pub const BRIDGED_CATEGORIES: &[&str] = &["layout", "surface", "verb"];

/// What the host implements to receive the Rust half's log lines.
#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedLogSink: Send + Sync {
    /// One line. `level` is `error` | `warning` | `info` | `debug` (the
    /// Console's own spellings); `category` is one of
    /// [`BRIDGED_CATEGORIES`].
    fn log(&self, level: String, category: String, message: String);
}

static SINK: RwLock<Option<Arc<dyn SharedLogSink>>> = RwLock::new(None);
static SUBSCRIBER_INSTALLED: OnceLock<bool> = OnceLock::new();
/// 0 = nothing forwarded ("off"); otherwise the rank of the least severe
/// level still forwarded ([`level_rank`]).
static LEVEL_RANK: AtomicU8 = AtomicU8::new(3); // default: info

/// Fields recorded on a `verb` span as it runs, kept on the span's
/// extensions until it closes.
#[derive(Default, Clone)]
struct SpanFields(BTreeMap<&'static str, String>);

/// Collects a `tracing` value set into a map, or (for events) just the
/// `message` field — `format_args!`'s `Debug` impl already renders the
/// formatted text with no added quoting, the same text `log::Record::args()`
/// gave the old bridge.
struct FieldVisitor<'a>(&'a mut dyn FnMut(&'static str, String));

impl Visit for FieldVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        (self.0)(field.name(), format!("{value:?}"));
    }
}

struct BridgeLayer;

impl<S> Layer<S> for BridgeLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        if attrs.metadata().target() != "verb" {
            return;
        }
        let mut fields = SpanFields::default();
        attrs.record(&mut FieldVisitor(&mut |name, value| {
            fields.0.insert(name, value);
        }));
        if let Some(span) = ctx.span(id) {
            span.extensions_mut().insert(fields);
        }
    }

    fn on_record(&self, id: &Id, values: &Record<'_>, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(id) else { return };
        let mut ext = span.extensions_mut();
        let Some(fields) = ext.get_mut::<SpanFields>() else {
            return;
        };
        values.record(&mut FieldVisitor(&mut |name, value| {
            fields.0.insert(name, value);
        }));
    }

    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let meta = event.metadata();
        let Some(category) = category_of(meta.target()) else {
            return;
        };
        if !enabled(*meta.level()) {
            return;
        }
        let mut message = String::new();
        event.record(&mut FieldVisitor(&mut |name, value| {
            if name == "message" {
                message = value;
            }
        }));
        forward(level_name(*meta.level()), category, message);
    }

    fn on_close(&self, id: Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(&id) else { return };
        if span.metadata().target() != "verb" {
            return;
        }
        if !enabled(Level::INFO) {
            return;
        }
        let fields = span
            .extensions()
            .get::<SpanFields>()
            .cloned()
            .unwrap_or_default();
        let field = |name: &str| fields.0.get(name).map(String::as_str).unwrap_or("");
        let message = format!(
            "{name} ok={ok} code={code} duration_us={duration_us} result_bytes={result_bytes}",
            name = field("name"),
            ok = field("ok"),
            code = field("code"),
            duration_us = field("duration_us"),
            result_bytes = field("result_bytes"),
        );
        forward("info", "verb", message);
    }
}

fn forward(level: &str, category: &'static str, message: String) {
    let sink = match SINK.read() {
        Ok(guard) => guard.clone(),
        Err(poisoned) => poisoned.into_inner().clone(),
    };
    if let Some(sink) = sink {
        sink.log(level.to_string(), category.to_string(), message);
    }
}

/// The Console category a `tracing` target belongs to, if it is bridged.
fn category_of(target: &str) -> Option<&'static str> {
    BRIDGED_CATEGORIES.iter().copied().find(|category| {
        target == *category
            || target
                .strip_prefix(category)
                .is_some_and(|rest| rest.starts_with("::"))
    })
}

fn level_name(level: Level) -> &'static str {
    match level {
        Level::ERROR => "error",
        Level::WARN => "warning",
        Level::INFO => "info",
        Level::DEBUG | Level::TRACE => "debug",
    }
}

/// `tracing::Level` ranked by verbosity, `error` least (1) to `trace` most
/// (5) — mirrors the old `log::LevelFilter` ordering the bridge relied on.
fn level_rank(level: Level) -> u8 {
    match level {
        Level::ERROR => 1,
        Level::WARN => 2,
        Level::INFO => 3,
        Level::DEBUG => 4,
        Level::TRACE => 5,
    }
}

fn rank_from_str(raw: &str) -> u8 {
    match raw.trim().to_ascii_lowercase().as_str() {
        "error" => 1,
        "warning" | "warn" => 2,
        "debug" => 4,
        "trace" => 5,
        "off" | "none" => 0,
        _ => 3, // info
    }
}

fn enabled(level: Level) -> bool {
    level_rank(level) <= LEVEL_RANK.load(Ordering::Relaxed)
}

/// Install `sink` as the destination of the layout, surface and verb-span
/// lines, at `level` (`error` | `warning` | `info` | `debug`; anything else
/// is `info`). Installing again replaces the sink and the level. Returns
/// false when this process already had a different global `tracing`
/// subscriber, in which case nothing is bridged — the host logs that.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn install_log_sink(sink: Box<dyn SharedLogSink>, level: String) -> bool {
    install(Arc::from(sink), &level)
}

pub(crate) fn install(sink: Arc<dyn SharedLogSink>, level: &str) -> bool {
    let installed = *SUBSCRIBER_INSTALLED.get_or_init(|| {
        // The G7b perf aggregator rides the same global subscriber as this
        // bridge, on the same `verb`-target spans — it folds them into
        // per-name buckets (`perf-service_summary`) while this layer only
        // forwards lines to the Console; installing both here means every
        // process that installs a log sink (every app, the FFI verb host)
        // also gets bucketed span history for free.
        let subscriber = tracing_subscriber::registry()
            .with(BridgeLayer)
            .with(impress_service_core::pipeline::perf::layer());
        let set = tracing::subscriber::set_global_default(subscriber).is_ok();
        if set {
            // Any `log` caller in a dependency still reaches this
            // subscriber, in case it ever logs under a bridged target.
            let _ = tracing_log::LogTracer::init();
        }
        set
    });
    if !installed {
        return false;
    }
    match SINK.write() {
        Ok(mut slot) => *slot = Some(sink),
        Err(poisoned) => *poisoned.into_inner() = Some(sink),
    }
    LEVEL_RANK.store(rank_from_str(level), Ordering::Relaxed);
    true
}

/// The HTTP status a refusal `code` answers with — the one table
/// (`impress_service_core::refusal::http_status`), so a Swift route that
/// reports a `SharedLayoutError` maps it exactly as the Rust routes do
/// (`invalid-argument` 400, `not-found` 404, `conflict` 409, a tree refusal
/// 422, `store-error` 500, …) instead of keeping a second copy.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn refusal_http_status(code: String) -> u16 {
    impress_service_core::refusal::http_status(&code)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;

    /// A sink that keeps what it was given, for tests of the lines a verb
    /// logs. One per process (the subscriber is global), shared by every
    /// test that reads it; each test filters for its own marker.
    #[derive(Default)]
    pub(crate) struct Captured(pub Mutex<Vec<(String, String, String)>>);

    impl SharedLogSink for Captured {
        fn log(&self, level: String, category: String, message: String) {
            self.0.lock().unwrap().push((level, category, message));
        }
    }

    pub(crate) fn captured() -> Arc<Captured> {
        static CAPTURED: OnceLock<Arc<Captured>> = OnceLock::new();
        CAPTURED
            .get_or_init(|| {
                let sink = Arc::new(Captured::default());
                assert!(install(sink.clone(), "debug"), "the bridge installs");
                sink
            })
            .clone()
    }

    #[test]
    fn a_bridged_target_reaches_the_sink_and_others_do_not() {
        let sink = captured();
        tracing::warn!(target: "layout", "bridge-test layout line");
        tracing::info!(target: "surface::feed", "bridge-test surface line");
        tracing::info!(target: "impress_core::store", "bridge-test other line");
        let lines = sink.0.lock().unwrap().clone();
        assert!(lines.contains(&(
            "warning".into(),
            "layout".into(),
            "bridge-test layout line".into()
        )));
        assert!(lines.contains(&(
            "info".into(),
            "surface".into(),
            "bridge-test surface line".into()
        )));
        assert!(!lines.iter().any(|l| l.2 == "bridge-test other line"));
    }

    /// One event from each bridged target — `layout`, `surface`, and a
    /// closed `verb` span — reaches the bridge callback.
    #[test]
    fn an_event_from_each_target_reaches_the_bridge() {
        let sink = captured();
        tracing::info!(target: "layout", "each-target layout line");
        tracing::info!(target: "surface", "each-target surface line");
        {
            let span = tracing::info_span!(
                target: "verb",
                "verb",
                name = "each-target-test_verb",
                ok = tracing::field::Empty,
                code = tracing::field::Empty,
                duration_us = tracing::field::Empty,
                result_bytes = tracing::field::Empty,
            );
            let _entered = span.enter();
            span.record("ok", true);
            span.record("code", "");
            span.record("duration_us", 42u64);
            span.record("result_bytes", 7usize);
        }
        let lines = sink.0.lock().unwrap().clone();
        assert!(lines
            .iter()
            .any(|l| l.1 == "layout" && l.2 == "each-target layout line"));
        assert!(lines
            .iter()
            .any(|l| l.1 == "surface" && l.2 == "each-target surface line"));
        assert!(lines.iter().any(|l| l.1 == "verb"
            && l.0 == "info"
            && l.2.contains("each-target-test_verb")
            && l.2.contains("duration_us=42")));
    }

    #[test]
    fn categories_match_whole_segments() {
        assert_eq!(category_of("layout"), Some("layout"));
        assert_eq!(category_of("layout::feed"), Some("layout"));
        assert_eq!(category_of("layouts"), None);
        assert_eq!(category_of("surface"), Some("surface"));
        assert_eq!(category_of("verb"), Some("verb"));
    }
}
