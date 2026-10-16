//! Parity test (P5a scope item 4): every verb `implore-service-http`
//! reached before P5 now reaches through `POST /api/verb/<name>`, including
//! the five the plan found dead on the wire (Rust POSTing where Swift
//! served GET — `docs/plan-verb-pipeline-and-transport.md` Table TR).
//!
//! This runs against a stub server, not a real app: the stub's one route
//! calls `implore_verbs_ffi::dispatch_verb` directly — implore's own
//! per-app UniFFI target (P5a; see that crate's module doc for why it
//! exists separately from `impress-store-ffi`'s kit-only dispatch). A pass
//! here proves the Rust half of the transport end to end, including the
//! five previously-dead verbs, without a Swift build or a running app.
//! Wiring implore's real `/api/verb/<name>` route to call into this crate
//! (rather than only the kit's) is Swift/Xcode packaging left for P5b —
//! see the session log and `implore-verbs-ffi`'s module doc for exactly
//! what remains.

use axum::extract::Path as AxumPath;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};

async fn status_route() -> Json<Value> {
    Json(json!({"status": "ok", "app": "implore-stub"}))
}

/// Every verb `implore-service-http` forwarded before P5 (Table TR: "implore
/// (client embedded) … 32 [methods] … 22 [routes]"). Not exhaustive of every
/// method — the point is the five dead ones plus a sample of the rest that
/// were already reachable, so a regression in one does not hide in the
/// other's pass.
const PREVIOUSLY_LIVE: &[(&str, &str)] = &[
    ("implore-service_status", "{}"),
    ("implore-service_list-datasets", "{}"),
    ("implore-service_list-figures", "{}"),
];

/// The five the plan found dead: Rust POSTed a body Swift's GET-only route
/// never read (`implore-service-http/src/lib.rs`; `ImploreHTTPRouter.swift`
/// registered these under `routeGET`, not `routePOST`).
const PREVIOUSLY_DEAD: &[(&str, &str)] = &[
    (
        "implore-service_plot-series",
        r#"{"series": ["a", "b"], "title": null}"#,
    ),
    (
        "implore-service_plot-histogram",
        r#"{"quantity": null, "bins": null}"#,
    ),
    ("implore-service_rg-statistics", r#"{"params_json": null}"#),
    ("implore-service_rg-slice-raw", r#"{"params_json": null}"#),
    ("implore-service_rg-slice-png", r#"{"format": null}"#),
];

async fn dispatch_route(
    AxumPath(name): AxumPath<String>,
    body: String,
) -> (StatusCode, Json<Value>) {
    let caller = json!({"kind": "app", "name": "implore"}).to_string();
    // `dispatch_verb` runs the pipeline through `invoke_blocking`, which
    // blocks on its own Tokio runtime — illegal from inside a task already
    // driven by one (the axum handler), so it runs on a blocking thread,
    // exactly as the real Swift caller's own non-Tokio thread would.
    let result =
        tokio::task::spawn_blocking(move || implore_verbs_ffi::dispatch_verb(name, body, caller))
            .await
            .expect("dispatch_verb should not panic");
    let status = StatusCode::from_u16(result.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let body: Value = serde_json::from_str(&result.body_json).unwrap_or(json!({}));
    (status, Json(body))
}

async fn start_stub() -> String {
    let app = Router::new()
        .route("/api/status", get(status_route))
        .route("/api/verb/{name}", post(dispatch_route));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind a free loopback port");
    let addr = listener.local_addr().expect("local_addr");
    tokio::spawn(async move {
        axum::serve(listener, app).await.expect("stub server");
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn every_verb_the_http_adapter_reached_now_reaches_through_api_verb() {
    let base_url = start_stub().await;
    std::env::set_var("IMPRESS_IMPLORE_HTTP_URL", &base_url);

    for (name, args) in PREVIOUSLY_LIVE.iter().chain(PREVIOUSLY_DEAD.iter()) {
        let args: Value = serde_json::from_str(args).expect("literal test args parse");
        let answer = impress_app_transport::call("implore", name, args)
            .await
            .unwrap_or_else(|refusal| {
                panic!("{name} should be reachable through /api/verb, got refusal: {refusal:?}")
            });
        // Reachable and answered — never `not-found` (the verb-lookup
        // refusal `dispatch_verb` gives an unknown name), which is the
        // specific failure a route that still 404s on these five would
        // reproduce.
        assert_ne!(
            answer.get("code").and_then(Value::as_str),
            Some("not-found"),
            "{name} answered not-found — it is still dead on the wire"
        );
    }

    std::env::remove_var("IMPRESS_IMPLORE_HTTP_URL");
}

#[tokio::test]
async fn an_unknown_verb_name_is_still_not_found_through_the_transport() {
    let base_url = start_stub().await;
    std::env::set_var("IMPRESS_IMPLORE_HTTP_URL2", &base_url);
    // A distinct env var so this test does not race the port-caching test
    // above under `cargo test`'s default parallelism; use a distinct app
    // name too.
    std::env::set_var("IMPRESS_PARITY_TEST_APP_HTTP_URL", &base_url);
    let error = impress_app_transport::call(
        "parity-test-app",
        "implore-service_does-not-exist",
        json!({}),
    )
    .await
    .expect_err("an unknown verb name must refuse, not invent an answer");
    assert_eq!(error.code, "not-found");
    std::env::remove_var("IMPRESS_IMPLORE_HTTP_URL2");
    std::env::remove_var("IMPRESS_PARITY_TEST_APP_HTTP_URL");
}
