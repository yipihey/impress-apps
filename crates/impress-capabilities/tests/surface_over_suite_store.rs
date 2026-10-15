//! The two surface cases that need the suite's own store service.
//!
//! They were Tier A cases of `impress-surface-service` until that crate moved
//! to koine (docs/plan-koine-host.md K3b): a koine crate cannot depend on
//! `impress-store-service`, and both cases drive its verbs. They live here
//! because this crate is where the linked inventory is (`force_link`), which
//! is what the `triage-service_*` and `settings-service_*` verbs a surface's
//! effects call need.
//!
//! * `the_paper_triage_loop_*`: a paper-triage surface over real
//!   `imbib/bibliography-entry` rows, starring through the real
//!   `triage-service_set-starred` verb (wave 5 V3).
//! * `the_generated_settings_pane_*`: `settings-service_surface` generates a
//!   pane, `surface_create` stores it, a field `change` runs
//!   `settings-service_set`, and `settings-service_get` answers the value the
//!   pane set (ADR-0036 D5). The catalogue version of this skipped itself when
//!   a settings store was already installed; here the test owns the process
//!   and installs a scratch one first.

use std::sync::Arc;

use impress_item::store::AttributedStore;
use impress_surface::{Event, EventKind, SurfaceSpec};
use impress_surface_service::dto::{ShowTargetDto, SplitTargetDto};
use impress_surface_service::{DefaultImpressSurfaceService, ImpressSurfaceService};
use serde_json::{json, Value};

const APP: &str = "surface-selftest";
/// Fixed, so the case never depends on the host's name.
const DEVICE: &str = "surface-selftest-device";

struct World {
    store: Arc<dyn AttributedStore>,
    service: DefaultImpressSurfaceService,
}

impl World {
    fn over(store: Arc<dyn AttributedStore>) -> Self {
        // `surface_show` composes the layout verbs through the inventory,
        // which read the process's kind manifest and subtree resolver.
        impress_store_service::register_process_ports();
        impress_capabilities::force_link();
        Self {
            service: DefaultImpressSurfaceService::with_store(
                store.clone(),
                impress_core::pane_query::builtin_manifest(),
            ),
            store,
        }
    }
}

use std::collections::BTreeMap;

use impress_item::item::{
    ActorKind as ItemActorKind, Item, Priority, Value as ItemValue, Visibility,
};
use impress_item::store::ItemStore;

#[allow(unused_imports)]
use impress_store_service::triage_service as _force_link_triage_service;

fn paper_triage() -> SurfaceSpec {
    impress_surface::example_paper_triage()
}

/// A bare `imbib/bibliography-entry` row, built the same way
/// `impress-store-service::test_support::make_item_named` and
/// `impress-core`'s own fixtures do (that helper is `#[cfg(test)]`-only
/// in ITS crate, so private to it — this is the same shape, copied, not
/// a new writer). The schema ref is copied verbatim from
/// `crates/impress-core/src/manuscript_reading_list.rs`'s `ENTRY_SCHEMA`
/// constant; the payload field names (`title`, `year`, `author_text`)
/// from `crates/imbib-core/src/unified/schemas.rs`'s
/// `bibliography_entry_schema` — the schema that actually defines them
/// (CLAUDE.md "Definition of done — schema refs": copy the spelling from
/// the manifest/schema, never guess).
fn seed_publication(store: &dyn ItemStore, title: &str, year: i64, author_text: &str) -> String {
    let now = chrono::Utc::now();
    let mut payload: BTreeMap<String, ItemValue> = BTreeMap::new();
    payload.insert("title".to_string(), ItemValue::String(title.to_string()));
    payload.insert("year".to_string(), ItemValue::Int(year));
    payload.insert(
        "author_text".to_string(),
        ItemValue::String(author_text.to_string()),
    );
    let item = Item {
        id: uuid::Uuid::new_v4(),
        schema: impress_item::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY,
        payload,
        created: now,
        modified: now,
        author: "impress-surface-service-tests".to_string(),
        author_kind: ItemActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    };
    store.insert(item).expect("insert publication").to_string()
}

/// Walk a `RenderTree`'s JSON (as `surface_render` returns it) for the
/// widget named `wanted_id` and return its `table.rows`, if any — the
/// same shape `flatten_payloads` (`runtime.rs`) hands `resolve`, now
/// round-tripped through the real store and the real render.
fn table_rows(tree: &Value, wanted_id: &str) -> Option<Vec<Value>> {
    fn walk(node_wrapper: &Value, wanted_id: &str) -> Option<Vec<Value>> {
        let id = node_wrapper.get("id")?.as_str()?;
        let node = node_wrapper.get("node")?;
        if id == wanted_id {
            if let Some(rows) = node.get("rows").and_then(Value::as_array) {
                return Some(rows.clone());
            }
        }
        if let Some(items) = node.get("items").and_then(Value::as_array) {
            for item in items {
                if let Some(found) = walk(item, wanted_id) {
                    return Some(found);
                }
            }
        }
        None
    }
    walk(tree.get("root")?, wanted_id)
}

#[tokio::test]
async fn the_paper_triage_loop_stars_the_selected_row_via_the_real_triage_verb() {
    // SQLite, not the memory store: the real triage verb resolves its
    // store through `impress_store_service::store_instance`, which takes
    // a call-scoped override only when it is a `SqliteItemStore`.
    let sqlite = Arc::new(
        impress_core::sqlite_store::SqliteItemStore::open_in_memory()
            .expect("open in-memory store for test"),
    );
    let world = World::over(sqlite.clone());
    // Nested inventory calls inherit the store override from this task
    // context. Keep this test's real triage verb on its scratch store
    // without installing a process-wide store: other Tier A tests may
    // have already initialized that singleton.
    let context = std::sync::Arc::new(impress_service_core::pipeline::context::CallContext {
        call_id: uuid::Uuid::new_v4().to_string(),
        trace_id: uuid::Uuid::new_v4().to_string(),
        parent_call: None,
        caller: impress_service_core::pipeline::CallerIdentity::agent("surface-test"),
        verb: "surface-test".into(),
        store_override: Some(sqlite),
        mutation_ids: Default::default(),
        adverbs: Default::default(),
        inverse: Default::default(),
        notes: Default::default(),
    });
    impress_service_core::pipeline::context::scope(context, paper_triage_loop_body(world)).await;
}

async fn paper_triage_loop_body(world: World) {
    let paper_a = seed_publication(&*world.store, "A dark matter survey", 2024, "Zwicky, F.");
    let paper_b = seed_publication(
        &*world.store,
        "Signal processing notes",
        2023,
        "Shannon, C.",
    );
    let paper_c = seed_publication(
        &*world.store,
        "An information theory primer",
        1948,
        "Wiener, N.",
    );

    // 0. The example validates clean against the REAL linked inventory
    // now that `triage-service` is force-linked above — this is the one
    // assertion that would fail loudly if the force-link were ever
    // removed by accident.
    let validated = world.service.surface_validate(paper_triage().into()).await;
    assert!(
        validated.ok,
        "unexpected problems: {:?}",
        validated.problems
    );

    // 1. create
    let created = world
        .service
        .surface_create(paper_triage().into(), None, None)
        .await;
    assert!(created.ok, "{}", created.message);
    let id = created.id.expect("created surface has an id");

    // 2. show into a split
    let shown = world
        .service
        .surface_show(
            id.clone(),
            ShowTargetDto {
                split: Some(SplitTargetDto {
                    direction: "vertical".to_string(),
                    from_focused: true,
                }),
                ..ShowTargetDto::default()
            },
            APP.to_string(),
            Some(DEVICE.to_string()),
        )
        .await;
    assert!(shown.ok, "{}", shown.message);

    // Render: the table shows the seeded titles, through the REAL
    // `papers` query against the REAL store.
    let first_render = world.service.surface_render(id.clone(), None, None).await;
    assert!(first_render.ok, "{}", first_render.message);
    let first_tree = serde_json::to_value(first_render.tree.unwrap()).unwrap();
    let rows = table_rows(&first_tree, "papers-table").expect("papers-table in render tree");
    assert_eq!(rows.len(), 3, "expected all three seeded papers: {rows:?}");
    let titles: Vec<&str> = rows
        .iter()
        .filter_map(|r| r.get("title").and_then(Value::as_str))
        .collect();
    assert!(titles.contains(&"A dark matter survey"), "{titles:?}");
    assert!(titles.contains(&"Signal processing notes"), "{titles:?}");
    assert!(
        titles.contains(&"An information theory primer"),
        "{titles:?}"
    );
    let first_tree_json = first_tree.to_string();
    assert!(
        !first_tree_json.contains("\"placeholder\""),
        "first render has a placeholder: {first_tree_json}"
    );

    // 3. dispatch a `select` on the table, then a `click` on the star
    // button. `event.value` carries an ARRAY of ids — the uniform shape
    // every widget's `select` event has (V5: the real Swift table sends
    // this, never a single id), with `paper_c` left out of it: it stays
    // the untouched control row through the rest of this test.
    // `on_select` still just does `state.selected = event.value`
    // (`{"set": {"path": "state.selected", "value": "{{event.value}}"}}`);
    // the buttons are what bridge a multi-id selection to the verbs'
    // own one-id signature, via `each`/`{{item}}` (see this crate's V5
    // report and `example.rs`'s doc comment on `example_paper_triage`).
    let select = Event {
        widget: "papers-table".to_string(),
        kind: EventKind::Select,
        value: json!([paper_a, paper_b]),
    };
    let selected = world
        .service
        .surface_dispatch(id.clone(), select, None, None)
        .await;
    assert!(selected.ok, "{}", selected.message);
    let state_after_select = world.service.surface_state_get(id.clone(), None).await;
    assert_eq!(
        state_after_select
            .state
            .as_ref()
            .and_then(|s| s.get("selected"))
            .and_then(Value::as_array)
            .map(|a| a
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()),
        Some(vec![paper_a.clone(), paper_b.clone()]),
        "state.selected was not set by the select event: {:?}",
        state_after_select.state
    );

    // 4. click "Star" — `on_click` fans out over `state.selected`
    // (`each: "state.selected"`), so this ONE click runs
    // `triage-service_set-starred` and emits `triaged` once per selected
    // id: two `call` outcomes, one `refresh`, two `emit`s, in that
    // order (`reduce.rs`'s fan-out preserves the action list's order,
    // and appends one effect per element for each fanned-out action).
    let click = Event {
        widget: "star-btn".to_string(),
        kind: EventKind::Click,
        value: Value::Null,
    };
    let clicked = world
        .service
        .surface_dispatch(id.clone(), click, None, None)
        .await;
    assert!(clicked.ok, "{}", clicked.message);
    let call_outcomes: Vec<_> = clicked
        .effects
        .iter()
        .filter(|e| e.kind == "call")
        .collect();
    assert_eq!(
        call_outcomes.len(),
        2,
        "expected one 'call' outcome per selected id: {:?}",
        clicked.effects
    );
    for outcome in &call_outcomes {
        assert!(outcome.ok, "star call failed: {}", outcome.message);
    }
    let refresh_outcome = clicked
        .effects
        .iter()
        .find(|e| e.kind == "refresh")
        .unwrap_or_else(|| panic!("no 'refresh' effect among {:?}", clicked.effects));
    assert!(
        refresh_outcome.ok,
        "refresh failed: {}",
        refresh_outcome.message
    );
    let emit_outcomes: Vec<_> = clicked
        .effects
        .iter()
        .filter(|e| e.kind == "emit")
        .collect();
    assert_eq!(
        emit_outcomes.len(),
        2,
        "expected one 'emit' outcome per selected id: {:?}",
        clicked.effects
    );
    for outcome in &emit_outcomes {
        assert!(outcome.ok, "emit failed: {}", outcome.message);
    }

    // 5. re-render: `is_starred: true` on BOTH selected rows, and still
    // `false` on the untouched third row — the fan-out really reached
    // the store once per id, not just the dispatch response.
    let rendered = world.service.surface_render(id.clone(), None, None).await;
    assert!(rendered.ok, "{}", rendered.message);
    let tree = serde_json::to_value(rendered.tree.unwrap()).unwrap();
    let rows = table_rows(&tree, "papers-table").expect("papers-table in render tree");
    for selected_id in [&paper_a, &paper_b] {
        let starred = rows
            .iter()
            .find(|r| r.get("id").and_then(Value::as_str) == Some(selected_id.as_str()))
            .unwrap_or_else(|| panic!("starred row {selected_id} missing from {rows:?}"));
        assert_eq!(
            starred.get("is_starred"),
            Some(&Value::Bool(true)),
            "starred row {selected_id}: {starred:?}"
        );
    }
    let untouched = rows
        .iter()
        .find(|r| r.get("id").and_then(Value::as_str) == Some(paper_c.as_str()))
        .unwrap_or_else(|| panic!("untouched row missing from {rows:?}"));
    assert_eq!(
        untouched.get("is_starred"),
        Some(&Value::Bool(false)),
        "untouched row: {untouched:?}"
    );

    // 6. surface_events carries a 'triaged' event for each selected id.
    let events = world.service.surface_events(id, Some(0), None).await;
    assert!(events.ok, "{}", events.message);
    let mut triaged_ids: Vec<&str> = events
        .events
        .iter()
        .filter(|e| e.name == "triaged")
        .filter_map(|e| e.payload.get("id").and_then(Value::as_str))
        .collect();
    triaged_ids.sort_unstable();
    let mut expected_ids = vec![paper_a.as_str(), paper_b.as_str()];
    expected_ids.sort_unstable();
    assert_eq!(
        triaged_ids, expected_ids,
        "expected a 'triaged' event per selected id among {:?}",
        events.events
    );
}

/// The settings registry's pane is a surface: `settings-service_surface`
/// generates it, `surface_create` stores it, a `change` on one of its fields
/// runs `settings-service_set` as an effect, and `settings-service_get`
/// answers the value the pane set — the CLI/MCP and the pane read one file.
///
/// The settings files are the process-wide `impress_store_service`
/// instance's; this test installs a scratch one FIRST. Nothing else in this
/// binary touches the settings store, so the install is the first in the
/// process.
#[tokio::test]
async fn the_generated_settings_pane_writes_through_settings_service_set() {
    use impress_store_service::{DefaultSettingsService, SettingsService};

    let scratch = std::env::temp_dir().join(format!(
        "impress-surface-selftest-settings-{}",
        uuid::Uuid::new_v4().simple()
    ));
    let settings = Arc::new(impress_settings::SettingsStore::open(&scratch));
    impress_store_service::install_settings(settings.clone())
        .expect("no other test in this binary installs a settings store");

    let world = World::over(Arc::new(
        impress_core::sqlite_store::SqliteItemStore::open_in_memory().unwrap(),
    ));
    let settings_service = DefaultSettingsService::with_store(settings.clone());
    let generated = settings_service.surface("imbib.retention".into()).await;
    assert!(
        generated.ok,
        "settings-service_surface refused: {}",
        generated.message
    );
    let spec_json = generated
        .spec
        .expect("settings-service_surface returned no spec");
    let spec: SurfaceSpec = serde_json::from_value(spec_json).expect("spec parses");
    let created = world.service.surface_create(spec.into(), None, None).await;
    assert!(
        created.ok,
        "surface_create refused the generated pane: {}",
        created.message
    );
    let id = created.id.expect("create returned no id");

    let rendered = world.service.surface_render(id.clone(), None, None).await;
    assert!(rendered.ok, "render failed: {}", rendered.message);
    let tree = serde_json::to_string(&rendered.tree).unwrap_or_default();
    assert!(
        tree.contains("imbib.retention.inbox_days"),
        "the rendered pane has no field for imbib.retention.inbox_days"
    );

    let event = Event {
        widget: "imbib.retention.inbox_days".to_string(),
        kind: EventKind::Change,
        value: json!("3 Months"),
    };
    let dispatched = world
        .service
        .surface_dispatch(id.clone(), event, None, None)
        .await;
    assert!(dispatched.ok, "dispatch failed: {}", dispatched.message);
    let failed: Vec<String> = dispatched
        .effects
        .iter()
        .filter(|e| !e.ok)
        .map(|e| format!("{}: {}", e.kind, e.message))
        .collect();
    assert!(failed.is_empty(), "the set effect failed: {failed:?}");

    let got = settings_service
        .get("imbib.retention.inbox_days".into())
        .await;
    assert!(got.ok, "settings-service_get refused: {}", got.message);
    let value = got
        .setting
        .and_then(|s| s.value)
        .expect("get returned no value");
    assert_eq!(
        value,
        json!(90),
        "the pane's change did not reach the file: get answered {value}"
    );
    assert!(
        scratch.join("settings").join("device.json").exists(),
        "no device.json was written under the scratch workspace"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}
