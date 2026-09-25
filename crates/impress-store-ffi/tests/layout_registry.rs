//! Review RL-L10: one app process, one layout session registry.
//!
//! The window's `SharedLayout` and every in-process inventory call of a
//! `layout-service` verb (a surface effect, `impress_capabilities_kit::call`)
//! must share one registry. With two, both wrote the same row through the same
//! connection — so `data_version` never moved — and each wrote its own stale
//! tree over the other's.
//!
//! Since review RL-L1 a second registry can no longer write a stale tree —
//! it reloads when the row moved — but every reload drops the window's undo
//! rings. With one registry the inventory's verb IS applied to the window's
//! session, and the window's ⌘Z still works afterwards; that is what this
//! pins.
//!
//! Its own test binary on purpose: the registry is shared with the store
//! `install_store` accepted, which is the first one this process opens.

use std::sync::mpsc;
use std::time::Duration;

use impress_store_ffi::{SharedLayout, SharedLayoutListener, SharedStore};

struct Versions(mpsc::Sender<u64>);

impl SharedLayoutListener for Versions {
    fn panes_invalidated(&self, _panes: Vec<u64>) {}
    fn layout_changed(&self, version: u64) {
        let _ = self.0.send(version);
    }
    fn layouts_changed(&self) {}
}

#[test]
fn an_inventory_verb_lands_in_the_windows_session_and_tells_it() {
    let store = SharedStore::open_in_memory().expect("the process's store");
    let layout = SharedLayout::open(store, "registry-test".into(), Some("desk".into()));
    let before = layout.snapshot().expect("snapshot");
    // The window explores first: a step on the list pane's ring.
    layout
        .apply(
            r#"{"verb":"set-query","target":{"role": "list"},
                "query":{"kinds":["manuscript"]}}"#
                .into(),
            "human".into(),
        )
        .expect("set-query");
    let list = layout
        .pane_with_role("list".into())
        .expect("roles")
        .expect("a list pane");

    layout.set_debounce_ms(20);
    layout.set_startup_grace_secs(0);
    let (tx, versions) = mpsc::channel();
    layout
        .subscribe_invalidations(Box::new(Versions(tx)))
        .expect("subscribe");

    // What an agent's verb, or a surface's `open` effect, does in-process.
    let answer = impress_capabilities_kit::call(
        "layout-service_split",
        serde_json::json!({
            "app_id": "registry-test",
            "device": "desk",
            "target": {"role": "detail"},
            "direction": "vertical",
            "after": true,
            "actor": "agent",
        }),
    )
    .expect("the inventory call");
    assert_eq!(answer["ok"], serde_json::json!(true), "{answer}");

    let version = versions
        .recv_timeout(Duration::from_secs(10))
        .expect("the window is told its tree changed");
    assert!(version > before.version);
    let after = layout.snapshot().expect("snapshot after");
    assert_eq!(
        after.leaves.len(),
        before.leaves.len() + 1,
        "the window's session is the one the verb changed"
    );

    // The window's ⌘Z still has its step: the agent's verb was applied to the
    // window's own session, not to a copy that forced a reload.
    layout
        .undo("exploration".into(), Some(list), "human".into())
        .expect("the window's own undo step survived the agent's verb");
    let pane = layout.pane(list).expect("the list pane");
    assert!(
        pane.spec_json.contains("publication"),
        "the list's query is back: {}",
        pane.spec_json
    );
    assert_eq!(
        layout.snapshot().unwrap().leaves.len(),
        before.leaves.len() + 1,
        "and the agent's split is still there"
    );
    layout.unsubscribe_invalidations();
}
