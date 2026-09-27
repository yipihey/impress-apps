//! The P5 transport's client side (plan-verb-pipeline-and-transport.md § P5,
//! ADR-0034 D2, finding TR-1..3).
//!
//! One function — [`call`] — replaces what the four hand-written
//! `*-service-http` adapters and `impress-app-client` each did their own
//! way: find the app's port, probe it, attach the loopback token, POST the
//! verb's own JSON body, decode the wire envelope. Every adapter carried its
//! own copy of the probe loop (TR-3); this crate is the one copy. Every
//! adapter swallowed a transport error into an empty/default result
//! (`imbib-service-http lib.rs:36-47`); this crate answers a real
//! [`Refusal`] instead, so a dead route reads as `host-unavailable` or
//! `not-found`, never as "no data".
//!
//! The server side is `POST /api/verb/<name>` on `ImpressAutomation`
//! (`packages/ImpressAutomation/Sources/ImpressAutomation/VerbAutomation.swift`),
//! which hands the body to `impress_store_ffi::dispatch_verb` — the same
//! pipeline this crate's caller would have gone through had the verb been
//! linked in-process.
//!
//! P5a scope: this crate exists and is proven against a stub server (see
//! `tests/`); P5b wires it into the actual entry paths that today call the
//! four adapters (impress-mcp, impress-cli, impel-tools, impress-ai-tools)
//! and deletes them (ADR-0034 D7).

pub mod ports;

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use impress_service_core::refusal::{codes, Refusal};
use serde_json::Value;

/// How long a probe itself may take before the app is treated as down.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(1);
/// How long a verb call may take before it is treated as failed. No
/// retries (TR-1's finding: "no retries anywhere" was already the rule
/// every adapter followed; this crate keeps it, deliberately, rather than
/// inventing one four call sites never had).
pub const CALL_TIMEOUT: Duration = Duration::from_secs(30);
/// How long an `Unavailable` verdict stands before a call may re-probe —
/// the same cooldown impel-tools already used (`REPROBE_COOLDOWN`,
/// `impel-tools/src/lib.rs`), so a burst of calls against a closed app pays
/// the probe once, not once per caller.
pub const REPROBE_COOLDOWN: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Verdict {
    Up,
    Down,
}

struct AppState {
    verdict: Verdict,
    at: Instant,
}

fn states() -> &'static Mutex<HashMap<String, AppState>> {
    static STATES: OnceLock<Mutex<HashMap<String, AppState>>> = OnceLock::new();
    STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A loopback-safe client, built once. `no_proxy()` because every request
/// this crate makes is to `127.0.0.1`, and a panicking `.build()` (asking
/// macOS for the system proxy from inside a sandboxed process) would take a
/// whole caller down over a transport detail — see
/// `impress-app-client::loopback_http_client`'s doc comment, which found
/// this failure first; this crate does not depend on that one (it is one of
/// the adapters ADR-0034 D7 deletes) so the same safety is repeated here in
/// one place rather than none.
fn client() -> reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .no_proxy()
                .timeout(CALL_TIMEOUT)
                .build()
                .unwrap_or_else(|_| reqwest::Client::new())
        })
        .clone()
}

fn probe_client() -> reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .no_proxy()
                .timeout(PROBE_TIMEOUT)
                .build()
                .unwrap_or_else(|_| reqwest::Client::new())
        })
        .clone()
}

/// Whether `app` (reachable at `base_url`) answered `GET /api/status`
/// recently enough to trust, re-probing when the cached verdict's cooldown
/// has expired. Exposed so a caller that already knows it wants a fresh
/// probe (impel-tools' "an app that was up and has since quit" case) can
/// call it directly; [`call`] calls it itself.
pub async fn is_reachable(app: &str, base_url: &str) -> bool {
    {
        let cached = states().lock().unwrap();
        if let Some(state) = cached.get(app) {
            if state.at.elapsed() < REPROBE_COOLDOWN {
                return state.verdict == Verdict::Up;
            }
        }
    }
    let up = probe(base_url).await;
    record(app, up);
    up
}

async fn probe(base_url: &str) -> bool {
    let url = format!("{}/api/status", base_url.trim_end_matches('/'));
    probe_client()
        .get(&url)
        .send()
        .await
        .map(|response| response.status().is_success())
        .unwrap_or(false)
}

fn record(app: &str, up: bool) {
    let mut cached = states().lock().unwrap();
    cached.insert(
        app.to_string(),
        AppState {
            verdict: if up { Verdict::Up } else { Verdict::Down },
            at: Instant::now(),
        },
    );
}

/// Call `verb` on `app`'s running automation server: `POST
/// /api/verb/<verb>` with `args` as the JSON body, decoding the wire
/// envelope (`{"ok": true, …}` or `{"ok": false, "code", "message"}`) into
/// `Ok`/`Err`. Attaches the P0 loopback token
/// (`impress_core::loopback_token::client_token_for_url`) and a fresh
/// `traceparent` so the pipeline on the app side joins this call's trace
/// (hook H-P5-1).
///
/// `app` is looked up in [`ports`]; an app this crate does not know is
/// `not-found`, not a panic. A transport failure (connection refused, a
/// timeout) is `host-unavailable` and also flips this app's cached
/// reachability to down, so the very next call re-probes rather than
/// retrying the same dead socket (TR-3).
pub async fn call(app: &str, verb: &str, args: Value) -> Result<Value, Refusal> {
    call_with_trace(app, verb, args, None).await
}

/// [`call`], joining `trace_id` instead of generating a fresh one — for a
/// caller that already has a `traceparent` to propagate (a nested verb
/// call, a Tier B scenario runner).
pub async fn call_with_trace(
    app: &str,
    verb: &str,
    args: Value,
    trace_id: Option<&str>,
) -> Result<Value, Refusal> {
    let base_url = ports::base_url(app)
        .ok_or_else(|| Refusal::new(codes::NOT_FOUND, format!("no known app '{app}'")))?;

    if !is_reachable(app, &base_url).await {
        return Err(Refusal::new(
            codes::HOST_UNAVAILABLE,
            format!("{app} is not reachable at {base_url}"),
        ));
    }

    let url = format!("{}/api/verb/{}", base_url.trim_end_matches('/'), verb);
    let mut builder = client().post(&url).json(&args);
    if let Some(token) = impress_core::loopback_token::client_token_for_url(&base_url) {
        builder = builder.bearer_auth(token);
    }
    let traceparent = trace_id
        .map(str::to_string)
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    builder = builder.header("traceparent", traceparent);

    let response = builder.send().await.map_err(|error| {
        record(app, false);
        Refusal::new(codes::HOST_UNAVAILABLE, format!("{app}/{verb}: {error}"))
    })?;

    let status = response.status();
    let bytes = response
        .bytes()
        .await
        .map_err(|error| Refusal::new(codes::VERB_FAILED, error.to_string()))?;
    let body: Value = serde_json::from_slice(&bytes).map_err(|error| {
        Refusal::new(
            codes::VERB_FAILED,
            format!(
                "{app}/{verb}: response did not parse as JSON: {error} ({})",
                String::from_utf8_lossy(&bytes)
            ),
        )
    })?;

    if status.is_success() {
        Ok(body)
    } else {
        let code = body
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or(codes::VERB_FAILED)
            .to_string();
        let message = body
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        Err(Refusal::new(code, message))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn reset_state(app: &str) {
        states().lock().unwrap().remove(app);
    }

    #[tokio::test]
    async fn a_successful_verb_call_decodes_the_ok_envelope() {
        let mut server = mockito::Server::new_async().await;
        let _status = server
            .mock("GET", "/api/status")
            .with_status(200)
            .with_body(r#"{"status":"ok"}"#)
            .create_async()
            .await;
        let _verb = server
            .mock("POST", "/api/verb/implore-service_plot-series")
            .with_status(200)
            .with_body(r#"{"ok":true,"wire_version":1,"svg":"<svg/>"}"#)
            .create_async()
            .await;

        std::env::set_var("IMPRESS_TESTAPP_HTTP_URL", server.url());
        reset_state("testapp");
        let answer = call(
            "testapp",
            "implore-service_plot-series",
            json!({"series": ["a"]}),
        )
        .await
        .expect("the verb should answer ok");
        assert_eq!(answer["ok"], true);
        assert_eq!(answer["svg"], "<svg/>");
        std::env::remove_var("IMPRESS_TESTAPP_HTTP_URL");
    }

    #[tokio::test]
    async fn a_refusal_envelope_is_an_err_not_swallowed_into_a_default() {
        let mut server = mockito::Server::new_async().await;
        let _status = server
            .mock("GET", "/api/status")
            .with_status(200)
            .with_body(r#"{"status":"ok"}"#)
            .create_async()
            .await;
        let _verb = server
            .mock("POST", "/api/verb/implore-service_rg-statistics")
            .with_status(404)
            .with_body(
                r#"{"ok":false,"wire_version":1,"code":"not-found","message":"no such dataset"}"#,
            )
            .create_async()
            .await;

        std::env::set_var("IMPRESS_TESTAPP2_HTTP_URL", server.url());
        reset_state("testapp2");
        let error = call(
            "testapp2",
            "implore-service_rg-statistics",
            json!({"params_json": null}),
        )
        .await
        .expect_err("a 404 refusal should be an Err, not an empty Ok");
        assert_eq!(error.code, "not-found");
        assert_eq!(error.message, "no such dataset");
        std::env::remove_var("IMPRESS_TESTAPP2_HTTP_URL");
    }

    #[tokio::test]
    async fn an_unreachable_app_is_host_unavailable_without_a_call_attempt() {
        reset_state("unreachable-app");
        std::env::set_var(
            "IMPRESS_UNREACHABLE_APP_HTTP_URL",
            "http://127.0.0.1:1", // nothing listens here
        );
        let error = call("unreachable-app", "some-service_verb", json!({}))
            .await
            .expect_err("nothing is listening, so this must refuse");
        assert_eq!(error.code, "host-unavailable");
        std::env::remove_var("IMPRESS_UNREACHABLE_APP_HTTP_URL");
    }

    #[tokio::test]
    async fn an_unknown_app_is_not_found() {
        let error = call("no-such-app", "x_y", json!({}))
            .await
            .expect_err("an app not in the port table must not panic");
        assert_eq!(error.code, "not-found");
    }

    #[tokio::test]
    async fn a_second_call_within_the_cooldown_reuses_the_cached_down_verdict() {
        reset_state("cooldown-app");
        std::env::set_var("IMPRESS_COOLDOWN_APP_HTTP_URL", "http://127.0.0.1:1");
        let first = std::time::Instant::now();
        let _ = call("cooldown-app", "x_y", json!({})).await;
        let second_start = std::time::Instant::now();
        let _ = call("cooldown-app", "x_y", json!({})).await;
        // The second call's own reachability check must not re-probe (no
        // network attempt on a cached-down verdict inside the cooldown):
        // proven indirectly by it returning fast, well under the 1s probe
        // timeout that a fresh probe of a black-hole address would pay.
        assert!(second_start.elapsed() < Duration::from_millis(500));
        assert!(first.elapsed() < Duration::from_secs(2));
        std::env::remove_var("IMPRESS_COOLDOWN_APP_HTTP_URL");
    }
}
