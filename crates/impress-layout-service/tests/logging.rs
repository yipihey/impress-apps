//! The layout verbs that persist outside the per-verb path — saving,
//! applying and deleting a layout, and the preset verbs — log under the
//! `layout` target with who asked, at the verb path's levels: `info` when
//! done, `warn` when refused (plan wave 7, T5's finding 3; wave 8 U2).
//!
//! Its own test binary, because the logger is process-wide.

use std::sync::{Arc, Mutex, OnceLock};

use impress_core::sqlite_store::SqliteItemStore;
use impress_layout_service::{DefaultLayoutService, LayoutService};
use log::{Level, Log, Metadata, Record};

const APP: &str = "imbib";

struct Capture(Mutex<Vec<(Level, String, String)>>);

impl Log for Capture {
    fn enabled(&self, _: &Metadata) -> bool {
        true
    }
    fn log(&self, record: &Record) {
        self.0.lock().unwrap().push((
            record.level(),
            record.target().to_string(),
            record.args().to_string(),
        ));
    }
    fn flush(&self) {}
}

fn capture() -> &'static Capture {
    static CAPTURE: OnceLock<&'static Capture> = OnceLock::new();
    CAPTURE.get_or_init(|| {
        let capture: &'static Capture = Box::leak(Box::new(Capture(Mutex::new(Vec::new()))));
        log::set_logger(capture).expect("the only logger in this binary");
        log::set_max_level(log::LevelFilter::Trace);
        capture
    })
}

/// The one `layout` line that mentions `needle`, with its level.
fn line_with(needle: &str) -> (Level, String) {
    let lines = capture().0.lock().unwrap();
    let found: Vec<_> = lines
        .iter()
        .filter(|(_, target, message)| target == "layout" && message.contains(needle))
        .collect();
    assert_eq!(
        found.len(),
        1,
        "expected one `layout` line with {needle:?}; have {:#?}",
        *lines
    );
    (found[0].0, found[0].2.clone())
}

fn device() -> Option<String> {
    Some("logging-device".to_string())
}

#[tokio::test]
async fn save_apply_delete_and_the_preset_refusals_are_logged_with_their_actor() {
    capture();
    let svc =
        DefaultLayoutService::with_store(Arc::new(SqliteItemStore::open_in_memory().unwrap()));
    let human = || Some("human".to_string());
    let agent = || Some("agent".to_string());

    let saved = svc
        .save_layout(APP.into(), device(), "Logged".into(), None, human())
        .await;
    assert!(saved.ok, "{}", saved.message);
    let (level, line) = line_with("save_layout 'Logged'");
    assert_eq!(level, Level::Info, "{line}");
    assert!(line.starts_with("imbib: human save_layout"), "{line}");

    let applied = svc
        .apply_layout(
            APP.into(),
            device(),
            Some("Logged".into()),
            None,
            agent(),
            None,
        )
        .await;
    assert!(applied.ok, "{}", applied.message);
    let (level, line) = line_with("apply_layout 'Logged'");
    assert_eq!(level, Level::Info, "{line}");
    assert!(line.starts_with("imbib: agent apply_layout"), "{line}");

    let deleted = svc
        .delete_layout(APP.into(), "Logged".into(), human())
        .await;
    assert!(deleted.ok, "{}", deleted.message);
    let (level, line) = line_with("delete_layout 'Logged'");
    assert_eq!(level, Level::Info, "{line}");
    assert!(line.starts_with("imbib: human delete_layout"), "{line}");

    // A preset is never deleted: refused, and the refusal is logged.
    let refused = svc
        .delete_layout(APP.into(), "Triage".into(), agent())
        .await;
    assert!(!refused.ok);
    let (level, line) = line_with("delete_layout 'Triage' refused");
    assert_eq!(level, Level::Warn, "{line}");
    assert!(
        line.contains("agent") && line.contains("[preset-not-deletable]"),
        "{line}"
    );

    // `save_preset` refuses anything but the live arrangement before it
    // touches a session; that refusal is logged too.
    let refused = svc
        .save_preset(APP.into(), device(), "Mine".into(), None, false, human())
        .await;
    assert!(!refused.ok);
    let (level, line) = line_with("save_preset 'Mine' refused");
    assert_eq!(level, Level::Warn, "{line}");
    assert!(line.starts_with("imbib: human save_preset"), "{line}");

    // And a commit of a kind nothing can materialize yet.
    let refused = svc
        .commit(
            APP.into(),
            device(),
            "figure".into(),
            "Fig".into(),
            None,
            agent(),
        )
        .await;
    assert!(!refused.ok);
    let (level, line) = line_with("commit 'Fig' as 'figure' refused");
    assert_eq!(level, Level::Warn, "{line}");
    assert!(line.contains("[invalid-argument]"), "{line}");
}
