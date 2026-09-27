//! The row's proof, headless (plan G4): the catalogue renders through
//! `surface_render` on a scratch store and opens a form; that form's Run on
//! `surface-demo-service_series` returns a result into its `kv`.
//!
//! Every verb call in this test goes through the one pipeline
//! (`impress_service_core::pipeline::invoke_blocking`) — never a direct
//! Rust call to `SurfaceDemoService::series` — because `surface_dispatch`'s
//! own `call` effect does exactly that, and this test would not notice the
//! difference if it cheated. `pipeline_goes_through_the_inventory_not_a_direct_call`
//! below makes that explicit.

use std::sync::Arc;

use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::descriptor::VerbDescriptor;
use impress_service_core::McpToolDescriptor;
use impress_surface::{Event, EventKind};
use impress_surface_service::dto::SpecArg;
use impress_surface_service::{DefaultImpressSurfaceService, ImpressSurfaceService};

// Linked so `surface-demo-service_series` is in the inventory this test's
// binary sees, and so `capabilities-service_list-verbs`'s own build (a
// dev-dependency of this crate) is unaffected — see Cargo.toml's comment on
// why the completeness test above excludes it.
use surface_demo_service as _;
// Linked so `capabilities-service_list-verbs`/`verb-surface`, which the
// catalogue names, resolve against the inventory `surface_create` checks.
use capabilities_service as _;

const HOST: &str = "verb-surface-proof";

fn world() -> (Arc<SqliteItemStore>, DefaultImpressSurfaceService) {
    let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let service = DefaultImpressSurfaceService::with_store(store.clone());
    (store, service)
}

#[tokio::test]
async fn the_catalogue_renders_and_the_generated_form_runs_a_verb_into_its_result_view() {
    let (_store, service) = world();

    // 1. The catalogue renders headlessly.
    let catalogue_spec = impress_verb_surface::catalogue();
    let created_catalogue = service
        .surface_create(SpecArg::of(&catalogue_spec), Some("catalogue".into()), None)
        .await;
    assert!(created_catalogue.ok, "{created_catalogue:?}");
    let catalogue_id = created_catalogue.id.clone().expect("an id");
    let rendered_catalogue = service
        .surface_render(catalogue_id, Some(HOST.into()), None)
        .await;
    assert!(rendered_catalogue.ok, "{rendered_catalogue:?}");
    assert!(
        rendered_catalogue.tree.is_some(),
        "the catalogue must render a tree headlessly"
    );

    // 2. "Opens a form": the generated form for surface-demo-service_series.
    let descriptor = VerbDescriptor::find("surface-demo-service_series")
        .expect("surface-demo-service_series is linked into this test binary");
    let form_spec = impress_verb_surface::verb_surface(descriptor);
    let created_form = service
        .surface_create(SpecArg::of(&form_spec), Some("series form".into()), None)
        .await;
    assert!(created_form.ok, "{created_form:?}");
    let form_id = created_form.id.clone().expect("an id");
    let rendered_form = service
        .surface_render(form_id.clone(), Some(HOST.into()), None)
        .await;
    assert!(rendered_form.ok, "{rendered_form:?}");

    // 3. Seed the form's `freq`/`n` state (the generated defaults are empty
    // scalars for a required numeric field), then click Run — through
    // `surface_dispatch`, which itself reaches `surface-demo-service_series`
    // only through the pipeline (see the module docs).
    let seed = service
        .surface_state_set(
            form_id.clone(),
            serde_json::json!({"freq": 2.0, "n": 16, "result": serde_json::Value::Null}),
            Some(HOST.into()),
        )
        .await;
    assert!(seed.ok, "{seed:?}");

    let click_run = Event {
        widget: "run".to_string(),
        kind: EventKind::Click,
        value: serde_json::Value::Null,
    };
    let dispatched = service
        .surface_dispatch(form_id.clone(), click_run, Some(HOST.into()), None)
        .await;
    assert!(dispatched.ok, "Run must succeed: {dispatched:?}");

    // 4. The result landed in state.result, and the result view (a `kv`
    // node, per table 3's flat-object rule for SeriesResult) resolves it.
    let state = service.surface_state_get(form_id, Some(HOST.into())).await;
    assert!(state.ok, "{state:?}");
    let result = state
        .state
        .as_ref()
        .and_then(|s| s.get("result"))
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    let values = result
        .get("values")
        .and_then(|v| v.as_array())
        .unwrap_or_else(|| panic!("state.result should be SeriesResult, got {result:?}"));
    assert_eq!(
        values.len(),
        16,
        "series(freq=2.0, n=16) returns 16 samples"
    );

    let tree_text = dispatched
        .tree
        .as_ref()
        .map(|t| serde_json::to_string(t).unwrap_or_default())
        .unwrap_or_default();
    assert!(
        tree_text.contains("result-view"),
        "the rendered tree should still carry the result-view node: {tree_text}"
    );
}

/// Every handler call goes through the pipeline (CLAUDE.md § "Rust
/// decides"; plan G4's rule): `surface_dispatch`'s `call` effect resolves
/// `surface-demo-service_series` the same way MCP and the CLI do, through
/// `impress_service_core::pipeline`, never a direct Rust method call on
/// `SurfaceDemoService`. This test proves the verb is reachable ONLY that
/// way from this binary — there is no `use surface_demo_service::...Series`
/// import anywhere in this file, only the inventory lookup below and the
/// `as _` link above.
#[test]
fn the_series_verb_is_reached_only_through_the_pipeline() {
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == "surface-demo-service_series")
        .expect("linked");
    let result = impress_service_core::pipeline::invoke_blocking(
        descriptor.verb,
        impress_service_core::pipeline::Call::agent(
            "test",
            serde_json::json!({"freq": 1.0, "n": 8}),
        ),
    )
    .expect("a strict-free verb never fails in transport");
    assert_eq!(
        result
            .get("values")
            .and_then(|v| v.as_array())
            .map(|a| a.len()),
        Some(8)
    );
}
