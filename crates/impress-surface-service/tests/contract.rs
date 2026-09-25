//! Wave 7 T6a: the surface verbs' written contract — strict arguments, a
//! spec validated wherever it is stored, verb arguments checked against the
//! verb's own schema, params bound from the pane, the app a pane lives in
//! taken from the pane, and `wire_version` on every result. Each test names
//! the review finding it closes.

use std::sync::Arc;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_layout_service::dto::PaneRefDto;
use impress_layout_service::{DefaultLayoutService, LayoutService};
use impress_service_core::{runtime::block_on, McpToolDescriptor};
use impress_surface::{Event, EventKind, Severity};
use impress_surface_service::dto::{ShowTargetDto, SpecArg, SplitTargetDto};
use impress_surface_service::{DefaultImpressSurfaceService, ImpressSurfaceService};
use serde_json::{json, Value};

// The demo verbs the examples name, linked into this test binary.
use surface_demo_service as _;

const HOST: &str = "contract-device";

fn world() -> (Arc<SqliteItemStore>, DefaultImpressSurfaceService) {
    let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let service = DefaultImpressSurfaceService::with_store(store.clone());
    (store, service)
}

/// Call a verb the way MCP and the CLI do: through its inventory handler.
fn call(tool: &str, args: Value) -> Value {
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == tool)
        .unwrap_or_else(|| panic!("{tool} is not in the inventory"));
    block_on((descriptor.handler)(args)).expect("a strict verb never fails in transport")
}

fn split() -> ShowTargetDto {
    ShowTargetDto {
        role: None,
        tile: None,
        split: Some(SplitTargetDto {
            direction: "vertical".into(),
            from_focused: true,
        }),
    }
}

// ─── Strict arguments (AC-F3, RL-L3's surface half) ─────────────────────────

/// `{"id": 7}` — the layout verbs' spelling of a pane — used to be read as
/// `{}` and open a new split. It is refused, naming the field.
#[test]
fn an_unknown_field_in_a_target_is_refused_naming_it() {
    let answer = call(
        "impress-surface-service_surface-show",
        json!({ "id": "00000000-0000-4000-8000-000000000000",
                "target": { "id": 7 }, "app_id": "impress" }),
    );
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["code"], "invalid-argument", "{answer}");
    assert!(
        answer["message"]
            .as_str()
            .unwrap()
            .contains("unknown field `id`"),
        "{answer}"
    );
    assert_eq!(answer["wire_version"], 1);
}

#[test]
fn an_unknown_top_level_argument_is_refused_naming_it() {
    for (tool, args, field) in [
        (
            "impress-surface-service_surface-get",
            json!({ "id": "x", "bogus": 1 }),
            "bogus",
        ),
        (
            "impress-surface-service_surface-wait",
            json!({ "id": "x", "after": 0, "timeout_ms": 1 }),
            "after",
        ),
        (
            "impress-surface-service_surface-dispatch",
            json!({ "id": "x", "event": { "widget": "a", "kind": "click", "valeu": 1 } }),
            "valeu",
        ),
    ] {
        let answer = call(tool, args);
        assert_eq!(answer["code"], "invalid-argument", "{tool}: {answer}");
        assert!(
            answer["message"].as_str().unwrap().contains(field),
            "{tool} must name `{field}`: {answer}"
        );
    }
    // No arguments at all is `{}` for a verb that takes none.
    assert_eq!(
        call("impress-surface-service_surface-examples", Value::Null)["ok"],
        true
    );
}

/// The target is exactly one of tile, role, split; `from_focused: false` is
/// refused rather than read as true.
#[tokio::test]
async fn a_target_must_name_exactly_one_pane() {
    let (_, service) = world();
    let spec = impress_surface::example_signal_explorer();
    let id = service
        .surface_create(SpecArg::of(&spec), None, None)
        .await
        .id
        .unwrap();
    for (target, says) in [
        (ShowTargetDto::default(), "names no pane"),
        (
            ShowTargetDto {
                role: Some("detail".into()),
                tile: Some(3),
                split: None,
            },
            "role and tile",
        ),
        (
            ShowTargetDto {
                split: Some(SplitTargetDto {
                    direction: "vertical".into(),
                    from_focused: false,
                }),
                ..ShowTargetDto::default()
            },
            "from_focused",
        ),
        (
            ShowTargetDto {
                split: Some(SplitTargetDto {
                    direction: "beside".into(),
                    from_focused: true,
                }),
                ..ShowTargetDto::default()
            },
            "beside",
        ),
    ] {
        let shown = service
            .surface_show(id.clone(), target, "impress".into(), Some(HOST.into()))
            .await;
        assert!(!shown.ok);
        assert_eq!(shown.code.as_deref(), Some("invalid-argument"));
        assert!(shown.message.contains(says), "{}", shown.message);
    }
    let shown = service
        .surface_show(id, split(), " ".into(), Some(HOST.into()))
        .await;
    assert_eq!(
        shown.code.as_deref(),
        Some("invalid-argument"),
        "an empty app_id"
    );
}

// ─── A spec is validated wherever it is stored (RS-S6 = AC-F7) ──────────────

#[tokio::test]
async fn create_and_update_refuse_an_invalid_spec_listing_every_problem() {
    let (_, service) = world();
    let bad = json!({ "surface": "1.0", "name": "bad", "state": {},
        "root": { "column": [ { "id": "t", "table": { "rows": [] } },
                              { "id": "b", "button": { "label": "x", "on_click": [
                                  { "call": { "verb": "nobody-service_nothing" } } ] } } ] } });
    let created = service
        .surface_create(SpecArg(bad.clone()), None, None)
        .await;
    assert!(!created.ok);
    assert_eq!(created.code.as_deref(), Some("invalid-spec"));
    let paths: Vec<&str> = created.problems.iter().map(|p| p.path.as_str()).collect();
    assert!(paths.contains(&"/root/column/0"), "{paths:?}");
    assert!(
        paths.contains(&"/root/column/1/button/on_click/0/call/verb"),
        "{paths:?}"
    );
    assert!(created.id.is_none());
    assert_eq!(
        service.surface_list().await.surfaces.len(),
        0,
        "nothing stored"
    );

    let good = impress_surface::example_signal_explorer();
    let id = service
        .surface_create(SpecArg::of(&good), None, None)
        .await
        .id
        .unwrap();
    let updated = service
        .surface_update(id.clone(), SpecArg(bad), None, None)
        .await;
    assert_eq!(updated.code.as_deref(), Some("invalid-spec"));
    let row = service.surface_get(id).await;
    assert_eq!(row.revision, Some(1), "the refused update wrote nothing");
}

/// A spec with warnings only is stored, and the warnings come back.
#[tokio::test]
async fn a_spec_with_warnings_only_is_stored_with_them() {
    let (_, service) = world();
    let spec = json!({ "surface": "1.0", "name": "future", "state": {},
        "root": { "column": [ { "sparkline": { "values": [1] } } ] } });
    let validated = service.surface_validate(SpecArg(spec.clone())).await;
    assert!(validated.ok, "{:?}", validated.problems);
    assert_eq!(validated.problems[0].severity, Severity::Warning);
    let created = service.surface_create(SpecArg(spec), None, None).await;
    assert!(created.ok, "{}", created.message);
    assert_eq!(created.problems.len(), 1);
}

/// AC-F13: a structurally wrong spec is a located problem, not an argument
/// parse failure.
#[tokio::test]
async fn validate_locates_a_structural_mistake() {
    let (_, service) = world();
    let result = service
        .surface_validate(SpecArg(json!({ "surface": "1.0", "name": "x" })))
        .await;
    assert!(!result.ok);
    assert_eq!(result.code.as_deref(), Some("invalid-spec"));
    assert!(
        result.problems.iter().any(|p| p.message.contains("`root`")),
        "{:?}",
        result.problems
    );
}

// ─── Verb arguments against the verb's own schema (AC-F14) ──────────────────

#[tokio::test]
async fn a_verbs_literal_arguments_are_checked_against_its_schema() {
    let (_, service) = world();
    let spec = json!({ "surface": "1.0", "name": "x", "state": { "f": 1 },
        "sources": {
            "missing": { "verb": "surface-demo-service_series", "args": { "freq": 1.0 } },
            "typed": { "verb": "surface-demo-service_series", "args": { "freq": "fast", "n": 8 } },
            "extra": { "verb": "surface-demo-service_series",
                       "args": { "freq": "{{state.f}}", "n": 8, "count": 3 } }
        },
        "root": { "spacer": {} } });
    let problems = service.surface_validate(SpecArg(spec)).await.problems;
    let at = |path: &str| problems.iter().find(|p| p.path == path).cloned();
    assert!(
        at("/sources/missing/args/n").is_some_and(|p| p.is_error()),
        "{problems:?}"
    );
    assert!(
        at("/sources/typed/args/freq").is_some_and(|p| p.is_error()),
        "{problems:?}"
    );
    // A template-valued argument only has to be present.
    assert!(at("/sources/extra/args/freq").is_none(), "{problems:?}");
    // The demo verbs are not strict, so an unknown argument would be ignored:
    // a warning, not an error.
    assert_eq!(
        at("/sources/extra/args/count").map(|p| p.severity),
        Some(Severity::Warning)
    );
}

// ─── Params bound from the pane; the app from the pane (RS-S3, RS-S4) ───────

fn insert_paper(store: &SqliteItemStore, title: &str) -> ItemId {
    let id = uuid::Uuid::new_v4();
    let now = chrono::Utc::now();
    let mut payload = std::collections::BTreeMap::new();
    payload.insert("title".to_string(), ItemValue::String(title.into()));
    store
        .insert(Item {
            id,
            schema: "imbib/bibliography-entry".into(),
            payload,
            created: now,
            modified: now,
            author: "test".into(),
            author_kind: ActorKind::Human,
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
        })
        .unwrap();
    id
}

/// A surface that shows the paper its `paper` param names, through a query
/// source, and publishes a row it is given.
fn paper_view() -> Value {
    json!({ "surface": "1.0", "name": "Paper view",
        "params": [ { "name": "paper", "kind": "imbib/bibliography-entry", "required": true } ],
        "state": {},
        "sources": {
            "picked": { "query": { "kinds": ["publication"],
                                   "scope": { "scope": "item", "id": { "ref": "param", "name": "paper" } } } },
            "others": { "value": [ { "id": "2b995442-c45a-4922-8c22-600d98900fc1" } ] }
        },
        "root": { "column": [
            { "id": "shown", "table": { "columns": ["title"], "rows": "{{source.picked}}" } },
            { "id": "picker", "table": { "columns": ["id"], "rows": "{{source.others}}",
                                        "on_select": [ { "publish": {} } ] } }
        ] } })
}

/// RS-S3 = AC-F15: shown in a pane, the surface's params are the pane's
/// bindings — here, the paper selected on the window's channel — and they
/// reach a query source. RS-S4 = AC-F6: the pane lives in implore's layout,
/// and the surface's publish lands on implore's channel, never impress's.
#[tokio::test]
async fn params_come_from_the_pane_and_effects_land_in_the_panes_app() {
    let (store, service) = world();
    let layout = DefaultLayoutService::with_store(store.clone());
    let app = "implore";
    let paper = insert_paper(&store, "Bound through the pane");

    let id = service
        .surface_create(SpecArg(paper_view()), None, None)
        .await
        .id
        .unwrap();
    let shown = service
        .surface_show(id.clone(), split(), app.into(), Some(HOST.into()))
        .await;
    assert!(shown.ok, "{}", shown.message);
    assert_eq!(shown.app_id.as_deref(), Some(app));

    // Unbound: the required param is refused by the query, and says so.
    let before = service
        .surface_render(id.clone(), Some(HOST.into()), None)
        .await;
    assert!(before.ok);
    assert!(before.revisions.params.is_empty());
    assert!(
        !before.source_errors.is_empty(),
        "an unbound required param is not 'no filter'"
    );

    // Someone selects the paper on implore's channel 1 (from another pane).
    let selected = layout
        .select(
            app.into(),
            Some(HOST.into()),
            PaneRefDto::tile(impress_layout::TileId::new(shown.tile.unwrap())),
            "publication".into(),
            vec![paper.to_string()],
            None,
        )
        .await;
    assert!(selected.ok, "{}", selected.message);

    let after = service
        .surface_render(id.clone(), Some(HOST.into()), None)
        .await;
    assert_eq!(
        after.revisions.params.get("paper"),
        Some(&paper.to_string())
    );
    let tree = serde_json::to_string(&after.tree).unwrap();
    assert!(tree.contains("Bound through the pane"), "{tree}");

    // Explicit params win, and a name the spec does not declare is refused.
    let other = insert_paper(&store, "Passed explicitly");
    let explicit = service
        .surface_render(
            id.clone(),
            Some(HOST.into()),
            Some([("paper".to_string(), other.to_string())].into()),
        )
        .await;
    assert!(serde_json::to_string(&explicit.tree)
        .unwrap()
        .contains("Passed explicitly"));
    let refused = service
        .surface_render(
            id.clone(),
            Some(HOST.into()),
            Some([("nope".to_string(), "x".to_string())].into()),
        )
        .await;
    assert_eq!(
        refused.code.as_deref(),
        Some("invalid-argument"),
        "{}",
        refused.message
    );

    // The publish lands in implore's layout.
    let select = Event {
        widget: "picker".into(),
        kind: EventKind::Select,
        value: json!(["2b995442-c45a-4922-8c22-600d98900fc1"]),
    };
    let dispatched = service
        .surface_dispatch(id, select, Some(HOST.into()), None)
        .await;
    assert!(
        dispatched.ok,
        "{}: {:?}",
        dispatched.message, dispatched.effects
    );
    let channel = layout
        .get_channel(
            app.into(),
            Some(HOST.into()),
            "1".into(),
            Some("publication".into()),
        )
        .await;
    assert!(
        serde_json::to_string(&channel)
            .unwrap()
            .contains("2b995442-c45a-4922-8c22-600d98900fc1"),
        "{channel:?}"
    );
    // impress's layout was never touched: it has no row at all.
    let impress_rows = store
        .query(&impress_core::query::ItemQuery {
            schema: Some(impress_core::schemas::LAYOUT_SCHEMA_REF.into()),
            predicates: vec![impress_core::query::Predicate::Eq(
                "app_id".into(),
                ItemValue::String("impress".into()),
            )],
            ..Default::default()
        })
        .unwrap();
    assert!(
        impress_rows.is_empty(),
        "a surface in implore must not write impress's layout"
    );
}

// ─── The wire (T6 "Complete & versioned wire") ─────────────────────────────

#[test]
fn every_surface_verb_answers_with_wire_version_one() {
    for descriptor in
        McpToolDescriptor::iter().filter(|d| d.name.starts_with("impress-surface-service_"))
    {
        // Arguments that are wrong on purpose still get an envelope.
        let answer = block_on((descriptor.handler)(
            json!({ "id": "not-an-id", "no_such_argument": 0 }),
        ))
        .unwrap();
        assert_eq!(answer["wire_version"], 1, "{}: {answer}", descriptor.name);
        assert_eq!(answer["ok"], false, "{}: {answer}", descriptor.name);
    }
}

/// The HTTP mirror's router covers every verb in the inventory — a verb added
/// to the trait but not to `call_verb_on` would be an MCP tool with no route.
#[tokio::test]
async fn the_verb_router_covers_every_surface_verb() {
    let (_, service) = world();
    for descriptor in
        McpToolDescriptor::iter().filter(|d| d.name.starts_with("impress-surface-service_"))
    {
        let method = descriptor
            .name
            .trim_start_matches("impress-surface-service_")
            .replace('-', "_");
        let answer = impress_surface_service::call_verb_on(&service, &method, json!({ "zzz": 1 }))
            .await
            .unwrap_or_else(|| panic!("no route for {method}"));
        assert_eq!(answer["code"], "invalid-argument", "{method}: {answer}");
        assert!(
            answer["message"].as_str().unwrap().contains("zzz"),
            "{answer}"
        );
    }
}

/// AC-F25: a typo in the tier is refused, not quietly Tier A.
#[tokio::test]
async fn an_unknown_selftest_tier_is_refused() {
    use impress_surface_service::{DefaultSurfaceSelftestService, SurfaceSelftestService};
    let report = DefaultSurfaceSelftestService.run_selftest("x".into()).await;
    assert!(!report.ok());
    assert!(report.results[0].detail.contains("unknown tier 'x'"));
}
