//! The Rust half of the layer, in the host's Console.
//!
//! `impress-layout-service`, `impress-surface-service` and this crate log
//! through the `log` facade under two targets, `layout` and `surface` — the
//! same category names the Swift half passes to `ImpressLogging`. Before
//! wave 7 nothing received those lines: a refused verb, a cold start, a
//! failed source or effect, an external write the feed picked up, all left no
//! trace in `/api/logs`, so the Rust half had to be debugged from Swift alone
//! (reviews RL-L6, RS-S11, AC-F18).
//!
//! The host installs a [`SharedLogSink`] once per process with
//! [`install_log_sink`]; from then on every record whose target is a bridged
//! category (or starts with `<category>::`) at or above the chosen level
//! reaches the sink as `(level, category, message)`, and the Swift sink
//! appends it to the Console, so `/api/logs?category=layout` and
//! `?category=surface` carry Rust's lines next to Swift's. Records of any
//! other target are not forwarded: the store and the AI crates keep their
//! own reporting, and a flood of them would bury these.
//!
//! The sink is called on whatever thread logged — a Tokio worker, a feed
//! thread, the caller's — and must not block or call back into Rust.

use std::sync::{Arc, OnceLock, RwLock};

/// The categories bridged into the host's Console: the `log` targets the
/// layout and surface crates use, spelled as the Swift half spells them.
pub const BRIDGED_CATEGORIES: &[&str] = &["layout", "surface"];

/// What the host implements to receive the Rust half's log lines.
#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedLogSink: Send + Sync {
    /// One line. `level` is `error` | `warning` | `info` | `debug` (the
    /// Console's own spellings); `category` is one of
    /// [`BRIDGED_CATEGORIES`].
    fn log(&self, level: String, category: String, message: String);
}

static SINK: RwLock<Option<Arc<dyn SharedLogSink>>> = RwLock::new(None);
static LOGGER: OnceLock<bool> = OnceLock::new();

struct Bridge;

impl log::Log for Bridge {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        category_of(metadata.target()).is_some()
    }

    fn log(&self, record: &log::Record) {
        let Some(category) = category_of(record.target()) else {
            return;
        };
        let sink = match SINK.read() {
            Ok(guard) => guard.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        };
        if let Some(sink) = sink {
            sink.log(
                level_name(record.level()).to_string(),
                category.to_string(),
                record.args().to_string(),
            );
        }
    }

    fn flush(&self) {}
}

static BRIDGE: Bridge = Bridge;

/// The Console category a `log` target belongs to, if it is bridged.
fn category_of(target: &str) -> Option<&'static str> {
    BRIDGED_CATEGORIES.iter().copied().find(|category| {
        target == *category
            || target
                .strip_prefix(category)
                .is_some_and(|rest| rest.starts_with("::"))
    })
}

fn level_name(level: log::Level) -> &'static str {
    match level {
        log::Level::Error => "error",
        log::Level::Warn => "warning",
        log::Level::Info => "info",
        log::Level::Debug | log::Level::Trace => "debug",
    }
}

fn level_filter(raw: &str) -> log::LevelFilter {
    match raw.trim().to_ascii_lowercase().as_str() {
        "error" => log::LevelFilter::Error,
        "warning" | "warn" => log::LevelFilter::Warn,
        "debug" => log::LevelFilter::Debug,
        "trace" => log::LevelFilter::Trace,
        "off" | "none" => log::LevelFilter::Off,
        _ => log::LevelFilter::Info,
    }
}

/// Install `sink` as the destination of the layout and surface crates' log
/// lines, at `level` (`error` | `warning` | `info` | `debug`; anything else
/// is `info`). Installing again replaces the sink and the level. Returns
/// false when this process already had a different `log` logger, in which
/// case nothing is bridged — the host logs that.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn install_log_sink(sink: Box<dyn SharedLogSink>, level: String) -> bool {
    install(Arc::from(sink), &level)
}

pub(crate) fn install(sink: Arc<dyn SharedLogSink>, level: &str) -> bool {
    let installed = *LOGGER.get_or_init(|| log::set_logger(&BRIDGE).is_ok());
    if !installed {
        return false;
    }
    match SINK.write() {
        Ok(mut slot) => *slot = Some(sink),
        Err(poisoned) => *poisoned.into_inner() = Some(sink),
    }
    log::set_max_level(level_filter(level));
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
    /// logs. One per process (the logger is global), shared by every test
    /// that reads it; each test filters for its own marker.
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
        log::warn!(target: "layout", "bridge-test layout line");
        log::info!(target: "surface::feed", "bridge-test surface line");
        log::info!(target: "impress_core::store", "bridge-test other line");
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

    #[test]
    fn categories_match_whole_segments() {
        assert_eq!(category_of("layout"), Some("layout"));
        assert_eq!(category_of("layout::feed"), Some("layout"));
        assert_eq!(category_of("layouts"), None);
        assert_eq!(category_of("surface"), Some("surface"));
    }
}
