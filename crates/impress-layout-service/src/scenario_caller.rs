//! The shared Tier B [`impress_scenario::Caller`], relocated here from
//! `impress-scenario-service` (docs/plan-self-reflective-layer.md S2b).
//!
//! # Why it lives here, not in `impress-scenario-service`
//!
//! `impress-scenario` (the spec + interpreter) joined the kit S2b (Tom's
//! decision, 2026-09-27, `docs/kit-manifest.md`) so `impress-layout-service`
//! and `impress-surface-service` could run their own non-dynamic Tier B
//! catalogue entries as stored `impress/scenario@1.0.0` documents. But the
//! *caller* that drives those documents over `/api/layout/*` and
//! `/api/surface/*` needs the per-launch loopback token
//! (`impress_core::loopback_token`), and `impress-core` is off-limits to a
//! `pure`-tier kit crate (`docs/kit-manifest.md`'s tier rule) — so it cannot
//! live in `impress-scenario` itself. `impress-scenario-service` is not in
//! the kit at all (S1's session log: "not the layout+surface kit"), so a kit
//! crate cannot depend on it either without a second, bigger manifest
//! change. `impress-layout-service` is the pure-enough spot: it is already
//! `store`-tier (it depends on `impress-core` for its own persistence) and
//! already carries the exact `reqwest` + loopback-token client this caller
//! needs (this module used to be its private `tier_b.rs` `Http`).
//! `impress-surface-service` already depends on `impress-layout-service` for
//! its own `surface_show` (see that crate's `Cargo.toml`), so it reuses this
//! module for free rather than gaining a new kit-crate dependency.
//! `impress-scenario-service` also depends on `impress-layout-service`
//! already, so its own `tier_b` module is now a one-line re-export of this
//! one instead of a second copy (SC-1's whole point: one runner, not three).
//!
//! # The `call` → `/api/layout/verb` fix this move made
//!
//! The generic `layout-service_*` arm used to forward a `call` step's `args`
//! verbatim as the wire body of `POST /api/layout/verb` — which only ever
//! worked for a `gesture` step, whose JSON already carries the `"verb"` tag
//! by hand. A `call` step names the verb in `call`, not in `args` (matching
//! Tier A, where the pipeline dispatches on the call name), so the arm now
//! injects `"verb": "<the call name with `layout-service_` stripped>"` into
//! the body before posting — the same kebab-case spelling
//! `impress_layout::Verb`'s `#[serde(tag = "verb", rename_all =
//! "kebab-case")]` already expects. Nothing using `gesture` (which already
//! carried its own `"verb"` field) changes.
//!
//! P5a's `POST /api/verb/<name>` now carries every other `call` step. The
//! route decides caller identity from its own transport; a scenario's `as`
//! label never travels in the request body.

use std::time::Duration;

use async_trait::async_trait;
use impress_scenario::{CallOutcome, Caller, EventBody, WaitBody};
use serde_json::{json, Value};

/// A loopback JSON client over one app's automation surface.
pub struct LoopbackClient {
    client: reqwest::Client,
    base: String,
}

impl LoopbackClient {
    pub fn new(base: &str) -> Self {
        // `no_proxy`: every request here goes to 127.0.0.1 (asking macOS for
        // the proxy config from a sandboxed process can abort). The app
        // bearer (P0, SEC-2) comes from the per-launch loopback token file,
        // or `IMPRESS_APP_TOKEN`.
        let mut builder = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(10));
        if let Some(token) = impress_core::loopback_token::client_token_for_url(base) {
            let mut headers = reqwest::header::HeaderMap::new();
            if let Ok(mut value) =
                reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))
            {
                value.set_sensitive(true);
                headers.insert(reqwest::header::AUTHORIZATION, value);
                builder = builder.default_headers(headers);
            }
        }
        let client = builder.build().unwrap_or_else(|_| reqwest::Client::new());
        Self {
            client,
            base: base.trim_end_matches('/').to_string(),
        }
    }

    pub async fn get(&self, path: &str) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("GET {path}: {e}"))?;
        read(path, response).await
    }

    pub async fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .post(&url)
            .json(body)
            .send()
            .await
            .map_err(|e| format!("POST {path}: {e}"))?;
        read(path, response).await
    }

    pub async fn put(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .put(&url)
            .json(body)
            .send()
            .await
            .map_err(|e| format!("PUT {path}: {e}"))?;
        read(path, response).await
    }

    pub async fn delete(&self, path: &str) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .delete(&url)
            .send()
            .await
            .map_err(|e| format!("DELETE {path}: {e}"))?;
        read(path, response).await
    }
}

/// The status and JSON body of one response — the caller decides whether a
/// non-2xx or an `{"ok": false}` envelope is a step failure (a scenario may
/// deliberately expect a refusal).
async fn read(path: &str, response: reqwest::Response) -> Result<(u16, Value), String> {
    let status = response.status().as_u16();
    let text = response
        .text()
        .await
        .map_err(|e| format!("{path}: reading body: {e}"))?;
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| format!("{path}: HTTP {status}, body is not JSON ({e}): {text}"))?;
    Ok((status, value))
}

pub struct TierBCaller {
    surface_routes: bool,
    http: LoopbackClient,
    /// A very small effects proxy: every kind this caller wrote via a
    /// layout/surface call it recognized, by name.
    /// Tier B has no store to re-query, so this is the only signal
    /// available without H-P5-1's generic route naming its own effects.
    wrote: std::collections::BTreeSet<String>,
}

impl TierBCaller {
    pub fn new(base_url: &str) -> Self {
        Self {
            surface_routes: false,
            http: LoopbackClient::new(base_url),
            wrote: std::collections::BTreeSet::new(),
        }
    }
    /// The surface catalogue also proves its REST projection. Stored documents
    /// retain canonical verb names so they validate and run through other callers.
    pub fn for_surface_routes(base_url: &str) -> Self {
        Self {
            surface_routes: true,
            ..Self::new(base_url)
        }
    }
}

/// Which `impress/ui/*` kind a recognized verb writes, for the effects
/// proxy above.
fn kind_for(verb: &str) -> Option<&'static str> {
    if verb.starts_with("layout-service_") || verb.starts_with("impress-layout-service_") {
        Some("impress/ui/layout@1.0.0")
    } else if verb.starts_with("surface-service_") || verb.starts_with("impress-surface-service_") {
        Some("impress/ui/surface@1.0.0")
    } else {
        None
    }
}

#[async_trait]
impl Caller for TierBCaller {
    async fn call(
        &mut self,
        verb: &str,
        args: Value,
        _as_ident: &str,
    ) -> Result<CallOutcome, String> {
        let outcome = match verb {
            "layout-service_apply-layout-by-ordinal" => {
                let ordinal = args
                    .get("ordinal")
                    .cloned()
                    .ok_or_else(|| "`apply-layout-by-ordinal` needs `ordinal`".to_string())?;
                self.op(json!({"op": "apply-layout", "ordinal": ordinal}))
                    .await?
            }
            "layout-service_apply-layout" => {
                let mut body = json!({"op": "apply-layout"});
                merge_args(&mut body, &args);
                self.op(body).await?
            }
            "layout-service_save-layout" => {
                let mut body = json!({"op": "save-layout"});
                merge_args(&mut body, &args);
                self.op(body).await?
            }
            "layout-service_delete-layout" => {
                let mut body = json!({"op": "delete-layout"});
                merge_args(&mut body, &args);
                self.op(body).await?
            }
            "layout-service_commit" => self.op(json!({"op": "commit"})).await?,
            "layout-service_get-layout" => {
                let (status, value) = self.http.get("/api/layout/tree").await?;
                CallOutcome {
                    result: value,
                    status: Some(status),
                }
            }
            "layout-service_list-layouts" => {
                let (status, value) = self.http.get("/api/layout/layouts").await?;
                CallOutcome {
                    result: value,
                    status: Some(status),
                }
            }
            other if other.starts_with("layout-service_") => {
                // Every other `layout-service_*` verb is a `Verb`
                // (split/resize/swap/close/focus/…). `args` is the verb's
                // OWN argument shape (matching Tier A, and a `call` step's
                // own doc — the caller names the verb, `args` does not
                // repeat it), so the wire tag is injected here rather than
                // required of every scenario author.
                let verb_name = &other["layout-service_".len()..];
                let mut body = args.clone();
                if let Some(obj) = body.as_object_mut() {
                    obj.entry("verb").or_insert_with(|| json!(verb_name));
                } else {
                    body = json!({ "verb": verb_name });
                }
                self.verb(body).await?
            }
            other
                if other.starts_with("surface-service_")
                    || (self.surface_routes && other.starts_with("impress-surface-service_")) =>
            {
                self.surface_route(other, args).await?
            }
            other => {
                // P5a's generic route accepts the verb's own argument object
                // and returns its pipeline result unchanged, including a
                // refusal body and HTTP status. The scenario's `as` label is
                // never sent as caller identity: the app's transport owns it.
                if !other
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                {
                    return Err(format!("invalid verb name `{other}` for /api/verb"));
                }
                let (status, value) = self.http.post(&format!("/api/verb/{other}"), &args).await?;
                CallOutcome {
                    result: value,
                    status: Some(status),
                }
            }
        };
        if let Some(kind) = kind_for(verb) {
            self.wrote.insert(kind.to_string());
        }
        Ok(outcome)
    }

    async fn event(&mut self, event: &EventBody) -> Result<CallOutcome, String> {
        let body = json!({"widget": event.widget, "kind": event.kind, "value": event.value});
        let (status, value) = self
            .http
            .post(&format!("/api/surface/{}/dispatch", event.surface), &body)
            .await?;
        if !(200..300).contains(&status) {
            return Err(format!("surface event dispatch returned HTTP {status}"));
        }
        if value.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err("surface event dispatch did not return ok=true".to_string());
        }
        self.wrote.insert("impress/ui/surface@1.0.0".to_string());
        Ok(CallOutcome {
            result: value,
            status: Some(status),
        })
    }

    async fn gesture(&mut self, gesture: &Value) -> Result<CallOutcome, String> {
        self.verb(gesture.clone()).await
    }

    async fn wait(&mut self, wait: &WaitBody) -> Result<(), String> {
        match wait {
            WaitBody::Log { log } => {
                let deadline =
                    tokio::time::Instant::now() + std::time::Duration::from_millis(log.timeout_ms);
                loop {
                    let (status, value) = self
                        .http
                        .get(&format!("/api/logs?category={}", log.category))
                        .await?;
                    if status == 200 {
                        if let Some(entries) = value.get("entries").and_then(Value::as_array) {
                            if entries.iter().any(|e| {
                                e.get("message")
                                    .and_then(Value::as_str)
                                    .is_some_and(|m| m.contains(&log.contains))
                            }) {
                                return Ok(());
                            }
                        }
                    }
                    if tokio::time::Instant::now() >= deadline {
                        return Err(format!(
                            "no log line under `{}` containing \"{}\" within {}ms",
                            log.category, log.contains, log.timeout_ms
                        ));
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                }
            }
            WaitBody::Job {
                job,
                state,
                timeout_ms,
            } => Err(format!(
                "`wait.job` is not supported yet (no job endpoint this caller reaches): \
                 job={job} state={state} timeout_ms={timeout_ms}"
            )),
        }
    }

    async fn seed(&mut self, kind: &str, _payload: &Value) -> Result<Value, String> {
        Err(format!(
            "seeding a live app's store is out of S1's scope (kind `{kind}`); Tier B scenarios \
             must not declare `seed`"
        ))
    }

    fn wrote(&self, kind: &str) -> bool {
        self.wrote.contains(kind)
    }
}

impl TierBCaller {
    /// Preserve the REST route contract, including unknown query arguments:
    /// the server must see and refuse them, rather than this client dropping them.
    /// Canonical `impress-surface-service_*` calls still use `/api/verb` above.
    async fn surface_route(&self, verb: &str, args: Value) -> Result<CallOutcome, String> {
        let (method, suffix, needs_id) = match verb
            .trim_start_matches("impress-")
            .trim_start_matches("surface-service_")
        {
            "surface-list" => ("GET", "", false),
            "surface-create" => ("POST", "", false),
            "surface-schema" => ("GET", "schema", false),
            "surface-examples" => ("GET", "examples", false),
            "surface-validate" => ("POST", "validate", false),
            "surface-get" => ("GET", "", true),
            "surface-update" => ("PUT", "", true),
            "surface-delete" => ("DELETE", "", true),
            "surface-show" | "surface-show-target" => ("POST", "show", true),
            "surface-render" => ("GET", "render", true),
            "surface-dispatch" => ("POST", "dispatch", true),
            "surface-state-get" | "surface-get-state" => ("GET", "state", true),
            "surface-state-set" | "surface-set-state" => ("PUT", "state", true),
            "surface-events" => ("GET", "events", true),
            "surface-wait" => ("GET", "wait", true),
            _ => return Err(format!("no surface REST route for `{verb}`")),
        };
        let mut body = args
            .as_object()
            .cloned()
            .ok_or("surface args must be an object")?;
        let mut url = reqwest::Url::parse("http://localhost/api/surface").expect("static URL");
        if needs_id {
            let id = body.remove("id").ok_or("surface route needs id")?;
            let id = id.as_str().ok_or("surface id must be a string")?;
            // A capture is one path component, never an additional route/query.
            if id.is_empty() || id.contains(['/', '?', '#']) || matches!(id, "." | "..") {
                return Err("invalid surface id for REST route".into());
            }
            url.path_segments_mut().expect("static URL").push(id);
        }
        if !suffix.is_empty() {
            url.path_segments_mut().expect("static URL").push(suffix);
        }
        let mut query = serde_json::Map::new();
        if method == "GET" || method == "DELETE" {
            query = std::mem::take(&mut body);
        } else if method == "PUT" && suffix.is_empty() {
            if let Some(revision) = body.remove("expected_revision") {
                query.insert("expected_revision".into(), revision);
            }
        }
        for (key, value) in query {
            if value.is_null()
                && matches!(
                    key.as_str(),
                    "host" | "after_seq" | "expected_revision" | "params"
                )
            {
                continue;
            }
            let text = value
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| value.to_string());
            url.query_pairs_mut().append_pair(&key, &text);
        }
        let path = format!(
            "{}{}",
            url.path(),
            url.query().map(|q| format!("?{q}")).unwrap_or_default()
        );
        let body = Value::Object(body);
        let (status, result) = match method {
            "GET" => self.http.get(&path).await?,
            "POST" => self.http.post(&path, &body).await?,
            "PUT" => self.http.put(&path, &body).await?,
            "DELETE" => self.http.delete(&path).await?,
            _ => unreachable!("closed route table"),
        };
        Ok(CallOutcome {
            result,
            status: Some(status),
        })
    }

    async fn op(&mut self, body: Value) -> Result<CallOutcome, String> {
        let (status, value) = self.http.post("/api/layout/op", &body).await?;
        Ok(CallOutcome {
            result: value,
            status: Some(status),
        })
    }

    async fn verb(&mut self, body: Value) -> Result<CallOutcome, String> {
        let (status, value) = self.http.post("/api/layout/verb", &body).await?;
        Ok(CallOutcome {
            result: value,
            status: Some(status),
        })
    }
}

fn merge_args(body: &mut Value, args: &Value) {
    if let (Some(b), Some(a)) = (body.as_object_mut(), args.as_object()) {
        for (k, v) in a {
            b.insert(k.clone(), v.clone());
        }
    }
}

/// Parse and run one embedded `impress/scenario@1.0.0` document (as
/// `include_str!`'d JSON) against a fresh [`TierBCaller`] for `base_url`,
/// returning the same [`crate::report::CapabilityResult`] shape every other
/// Tier B capability in this crate returns.
///
/// `caller` is threaded through by the call site rather than opened here so
/// a whole catalogue run shares one caller (and so one `wrote()` effects
/// proxy) across its scenario-backed and hand-written capabilities alike —
/// matching how `run()` already shares one `Http` across every hand-written
/// capability function.
pub async fn run_embedded(
    document: &str,
    caller: &mut TierBCaller,
) -> impress_service_core::report::CapabilityResult {
    let scenario: impress_scenario::Scenario = match serde_json::from_str(document) {
        Ok(s) => s,
        Err(e) => {
            return impress_service_core::report::CapabilityResult {
                id: "scenario.parse-error".to_string(),
                description: "an embedded scenario document failed to parse".to_string(),
                tier: impress_service_core::report::Tier::B,
                pass: false,
                detail: format!("invalid scenario JSON: {e}"),
                duration_ms: 0,
                skipped: false,
            };
        }
    };
    impress_scenario::run(&scenario, caller).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn mock_once(
        status: u16,
        response: Value,
    ) -> (String, std::thread::JoinHandle<(String, Value)>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("owned loopback port");
        let base = format!("http://{}", listener.local_addr().unwrap());
        let thread = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("one request");
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut bytes = Vec::new();
            let header_end = loop {
                let mut chunk = [0u8; 1024];
                let n = stream.read(&mut chunk).expect("request bytes");
                assert!(n > 0, "request ended before headers");
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    break end + 4;
                }
            };
            let headers = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
            let content_len: usize = headers
                .lines()
                .find_map(|line| {
                    line.split_once(':').and_then(|(name, value)| {
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse().unwrap())
                    })
                })
                .unwrap_or(0);
            while bytes.len() - header_end < content_len {
                let mut chunk = [0u8; 1024];
                let n = stream.read(&mut chunk).expect("request body");
                assert!(n > 0, "request ended before body");
                bytes.extend_from_slice(&chunk[..n]);
            }
            let body = if content_len == 0 {
                Value::Null
            } else {
                serde_json::from_slice(&bytes[header_end..header_end + content_len]).unwrap()
            };
            let wire = response.to_string();
            write!(
                stream,
                "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{wire}",
                wire.len()
            )
            .unwrap();
            (headers.lines().next().unwrap().to_string(), body)
        });
        (base, thread)
    }

    #[tokio::test]
    async fn surface_routes_preserve_method_query_refusals_and_body() {
        for (verb, args, request, body) in [
            (
                "surface-show",
                json!({"id":"owned", "target":{"role":"detail"}}),
                "POST /api/surface/owned/show HTTP/1.1",
                json!({"target":{"role":"detail"}}),
            ),
            (
                "surface-get",
                json!({"id":"owned"}),
                "GET /api/surface/owned HTTP/1.1",
                Value::Null,
            ),
            (
                "surface-events",
                json!({"id":"owned", "after":0}),
                "GET /api/surface/owned/events?after=0 HTTP/1.1",
                Value::Null,
            ),
            (
                "surface-render",
                json!({"id":"owned", "pane":3}),
                "GET /api/surface/owned/render?pane=3 HTTP/1.1",
                Value::Null,
            ),
            (
                "surface-wait",
                json!({"id":"owned", "after_seq":0, "timeout_ms":10}),
                "GET /api/surface/owned/wait?after_seq=0&timeout_ms=10 HTTP/1.1",
                Value::Null,
            ),
            (
                "surface-update",
                json!({"id":"owned", "expected_revision":1, "spec":{"surface":"1.0"}}),
                "PUT /api/surface/owned?expected_revision=1 HTTP/1.1",
                json!({"spec":{"surface":"1.0"}}),
            ),
            (
                "surface-render",
                json!({"id":"owned", "host":"a&b c"}),
                "GET /api/surface/owned/render?host=a%26b+c HTTP/1.1",
                Value::Null,
            ),
        ] {
            let refusal = json!({"ok":false,"code":"invalid-argument","wire_version":1});
            let (base, mock) = mock_once(400, refusal.clone());
            let outcome = TierBCaller::new(&base)
                .call(&format!("surface-service_{verb}"), args, "person")
                .await
                .unwrap();
            assert_eq!(outcome.status, Some(400));
            assert_eq!(outcome.result, refusal);
            assert_eq!(mock.join().unwrap(), (request.into(), body));
        }
    }

    #[tokio::test]
    async fn surface_id_cannot_change_the_route() {
        for id in ["..", "bad?pane=3", "other/events", "bad#fragment", ""] {
            let error = TierBCaller::new("http://127.0.0.1:1")
                .call("surface-service_surface-get", json!({"id":id}), "person")
                .await
                .unwrap_err();
            assert!(error.contains("invalid surface id"), "{error}");
        }
    }

    #[tokio::test]
    async fn catalogue_mode_projects_a_canonical_verb_to_the_rest_route() {
        let (base, mock) = mock_once(200, json!({"ok":true,"events":[]}));
        let mut caller = TierBCaller::for_surface_routes(&base);
        caller
            .call(
                "impress-surface-service_surface-events",
                json!({"id":"owned","host":null,"after_seq":0}),
                "person",
            )
            .await
            .unwrap();
        assert_eq!(
            mock.join().unwrap(),
            (
                "GET /api/surface/owned/events?after_seq=0 HTTP/1.1".into(),
                Value::Null
            )
        );
    }

    #[tokio::test]
    async fn generic_verb_route_preserves_raw_refusal_and_transport_identity() {
        let refusal = json!({"ok": false, "code": "not-found", "wire_version": 1});
        let (base, mock) = mock_once(404, refusal.clone());
        let mut caller = TierBCaller::new(&base);
        let outcome = caller
            .call(
                "imbib-triage-service_set-starred",
                json!({"id": "paper-1", "starred": true}),
                "person",
            )
            .await
            .unwrap();
        assert_eq!(outcome.status, Some(404));
        assert_eq!(outcome.result, refusal);
        let (request, body) = mock.join().unwrap();
        assert_eq!(
            request,
            "POST /api/verb/imbib-triage-service_set-starred HTTP/1.1"
        );
        assert_eq!(body, json!({"id": "paper-1", "starred": true}));
    }

    #[tokio::test]
    async fn generic_verb_name_cannot_escape_the_route() {
        let mut caller = TierBCaller::new("http://127.0.0.1:1");
        let error = caller
            .call("../api/status", json!({}), "person")
            .await
            .unwrap_err();
        assert!(error.contains("invalid verb name"), "{error}");
    }

    #[tokio::test]
    async fn canonical_surface_verb_uses_generic_route_and_keeps_effect_proxy() {
        let (base, mock) = mock_once(200, json!({"ok": true, "wire_version": 1}));
        let mut caller = TierBCaller::new(&base);
        let args =
            json!({"id": "surface-1", "event": {"widget": "go", "kind": "click", "value": null}});
        let outcome = caller
            .call(
                "impress-surface-service_surface-dispatch",
                args.clone(),
                "person",
            )
            .await
            .unwrap();
        assert_eq!(outcome.status, Some(200));
        assert_eq!(outcome.result["ok"], true);
        assert!(caller.wrote("impress/ui/surface@1.0.0"));
        let (request, body) = mock.join().unwrap();
        assert_eq!(
            request,
            "POST /api/verb/impress-surface-service_surface-dispatch HTTP/1.1"
        );
        assert_eq!(body, args);
    }

    #[tokio::test]
    async fn event_requires_success_before_counting_a_surface_effect() {
        let event = EventBody {
            surface: "surface-1".to_string(),
            widget: "go".to_string(),
            kind: "click".to_string(),
            value: Value::Null,
        };
        for (status, response) in [
            (404, json!({"ok": false, "code": "not-found"})),
            (200, json!({"ok": false, "code": "effect-failed"})),
        ] {
            let (base, mock) = mock_once(status, response);
            let mut caller = TierBCaller::new(&base);
            let error = caller.event(&event).await.unwrap_err();
            assert!(error.contains("surface event dispatch"), "{error}");
            assert!(!caller.wrote("impress/ui/surface@1.0.0"));
            let (request, body) = mock.join().unwrap();
            assert_eq!(request, "POST /api/surface/surface-1/dispatch HTTP/1.1");
            assert_eq!(
                body,
                json!({"widget": "go", "kind": "click", "value": null})
            );
        }

        let (base, mock) = mock_once(200, json!({"ok": true}));
        let mut caller = TierBCaller::new(&base);
        assert_eq!(caller.event(&event).await.unwrap().status, Some(200));
        assert!(caller.wrote("impress/ui/surface@1.0.0"));
        mock.join().unwrap();
    }
}
