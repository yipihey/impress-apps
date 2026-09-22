//! The `RenderTree` wire format is pinned.
//!
//! A `RenderTree` is what `surface_render` (S4) returns to an agent and what a
//! renderer (Swift today) maps to pixels one to one (ADR-0033 D2) — its JSON is
//! a compatibility surface the same way the layout tree's is (see
//! `impress-layout/tests/golden.rs`, which this test follows). A deliberate
//! shape change is made by re-blessing the file
//! (`UPDATE_GOLDEN=1 cargo test -p impress-surface --test golden`) *and* saying
//! in the PR what reads the old shape.

use serde_json::{json, Value};

use impress_surface::{example_signal_explorer, resolve, RenderTree};

const GOLDEN: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/golden/signal-explorer.render.json"
);

/// A fixed, fake `SourceData` standing in for what `impress-surface-service`'s
/// executor would have fetched — this crate never calls a verb or runs a query
/// itself, so the golden is pinned against data a human hand-writes here, not
/// against anything live.
fn fake_source_data() -> Value {
    json!({
        "series": { "values": [0.0, 1.0, 0.0, -1.0] },
        "hist": { "plot": { "kind": "plot-spec@1.0.0", "bars": [1, 2, 1] } },
        "papers": [
            { "title": "A dark matter survey", "year": 2024 },
            { "title": "Signal processing notes", "year": 2023 }
        ]
    })
}

fn golden_tree() -> RenderTree {
    let spec = example_signal_explorer();
    let state = json!({ "freq": 2.0, "bins": 16 });
    let params = json!({});
    resolve(&spec, &state, &params, &fake_source_data())
}

#[test]
fn the_signal_explorer_render_tree_serializes_exactly_as_committed() {
    let tree = golden_tree();
    let actual = serde_json::to_value(&tree).unwrap();

    if std::env::var("UPDATE_GOLDEN").is_ok() {
        let pretty = serde_json::to_string_pretty(&actual).unwrap();
        std::fs::write(GOLDEN, format!("{pretty}\n")).unwrap();
    }

    let committed: Value =
        serde_json::from_str(&std::fs::read_to_string(GOLDEN).expect("golden file")).unwrap();
    assert_eq!(
        actual,
        committed,
        "the RenderTree wire format changed.\nactual:\n{}",
        serde_json::to_string_pretty(&actual).unwrap()
    );
}

#[test]
fn the_committed_json_deserializes_back_to_a_render_tree() {
    let committed: RenderTree =
        serde_json::from_str(&std::fs::read_to_string(GOLDEN).expect("golden file")).unwrap();
    assert_eq!(committed, golden_tree());
}
