//! Tier B: the surface verbs over a running app's HTTP mirror
//! (`/api/surface/*`, `docs/agent-surfaces.md` "HTTP").
//!
//! Tier A proves the verbs; this proves that an app serves them as the same
//! wire — every route answering its verb's result with `wire_version`, an
//! argument the verb does not take refused naming it, an invalid spec
//! refused at create — against the app actually running. It creates one
//! scratch surface, shows it nowhere, and deletes it. Every capability is
//! skipped (and the report is not `ok`) when no app answers.
//!
//! The base url is `IMPRESS_SURFACE_SELFTEST_BASE_URL`, else
//! `IMPRESS_LAYOUT_SELFTEST_BASE_URL` (so one variable points both
//! self-tests at one app), else impress's own port.

use std::time::Duration;

use serde_json::{json, Value};

use crate::report::{CapabilityResult, Tier};
use crate::{check, skipped};

/// See the module docs.
pub const BASE_URL_ENV: &str = "IMPRESS_SURFACE_SELFTEST_BASE_URL";
const FALLBACK_ENV: &str = "IMPRESS_LAYOUT_SELFTEST_BASE_URL";
const DEFAULT_BASE_URL: &str = "http://127.0.0.1:23125";
const SCRATCH: &str = "surface-selftest tier-b scratch";

pub fn configured_base_url() -> String {
    [BASE_URL_ENV, FALLBACK_ENV]
        .iter()
        .find_map(|key| std::env::var(key).ok().filter(|v| !v.trim().is_empty()))
        .unwrap_or_else(|| DEFAULT_BASE_URL.to_string())
}

const CATALOGUE: &[(&str, &str)] = &[
    (
        "surface.http.routes",
        "Every /api/surface route answers its verb's result, with wire_version 1",
    ),
    (
        "surface.http.strict",
        "An argument a verb does not take is refused over HTTP, naming it",
    ),
    (
        "surface.http.invalid_spec",
        "An invalid spec is refused at create with every problem, and nothing is stored",
    ),
];

struct Http {
    client: reqwest::Client,
    base: String,
}

impl Http {
    /// `(status, body)`; a transport failure is an `Err`.
    async fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.base);
        let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| e.to_string())?;
        let mut request = self.client.request(method.clone(), &url);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .await
            .map_err(|e| format!("{method} {path}: {e}"))?;
        let status = response.status().as_u16();
        let text = response
            .text()
            .await
            .map_err(|e| format!("{method} {path}: {e}"))?;
        let value = serde_json::from_str(&text)
            .map_err(|e| format!("{method} {path}: HTTP {status}, not JSON ({e}): {text}"))?;
        Ok((status, value))
    }
}

/// `status` and `wire_version: 1`, or why not.
fn expect(what: &str, got: &(u16, Value), status: u16) -> Result<(), String> {
    let (actual, body) = got;
    if *actual != status {
        return Err(format!("{what}: HTTP {actual}, expected {status}: {body}"));
    }
    if body.get("wire_version").and_then(Value::as_u64) != Some(1) {
        return Err(format!("{what}: no wire_version 1: {body}"));
    }
    Ok(())
}

fn scratch_spec() -> Value {
    json!({
        "surface": "1.0", "name": SCRATCH, "state": { "bins": 4 },
        "root": { "column": [
            { "id": "bins", "field": { "slider": { "min": 1, "max": 64, "step": 1 } },
              "label": "Bins", "bind": "state.bins" },
            { "id": "choose", "button": { "label": "Use", "on_click": [
                { "emit": { "name": "chosen", "payload": { "bins": "{{state.bins}}" } } } ] } }
        ] }
    })
}

pub async fn run() -> Vec<CapabilityResult> {
    let base = configured_base_url();
    let http = Http {
        client: reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(15))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new()),
        base: base.trim_end_matches('/').to_string(),
    };
    if http.call("GET", "/api/surface", None).await.is_err() {
        return CATALOGUE
            .iter()
            .map(|(id, description)| {
                skipped(
                    id,
                    description,
                    Tier::B,
                    &format!("no app answered on {base}"),
                )
            })
            .collect();
    }
    vec![
        check(CATALOGUE[0].0, CATALOGUE[0].1, Tier::B, || routes(&http)).await,
        check(CATALOGUE[1].0, CATALOGUE[1].1, Tier::B, || strict(&http)).await,
        check(CATALOGUE[2].0, CATALOGUE[2].1, Tier::B, || {
            invalid_spec(&http)
        })
        .await,
    ]
}

async fn routes(http: &Http) -> Result<String, String> {
    let created = http
        .call(
            "POST",
            "/api/surface",
            Some(json!({ "spec": scratch_spec() })),
        )
        .await?;
    expect("POST /api/surface", &created, 200)?;
    let id = created
        .1
        .get("id")
        .and_then(Value::as_str)
        .ok_or("create answered no id")?
        .to_string();
    let result = async {
        let steps: Vec<(&str, String, Option<Value>, &str)> = vec![
            ("GET", "/api/surface".into(), None, "surfaces"),
            ("GET", "/api/surface/schema".into(), None, "rules"),
            ("GET", "/api/surface/examples".into(), None, "examples"),
            (
                "POST",
                "/api/surface/validate".into(),
                Some(json!({ "spec": scratch_spec() })),
                "problems",
            ),
            ("GET", format!("/api/surface/{id}"), None, "spec"),
            ("GET", format!("/api/surface/{id}/render"), None, "tree"),
            ("GET", format!("/api/surface/{id}/state"), None, "state"),
            (
                "PUT",
                format!("/api/surface/{id}/state"),
                Some(json!({ "state": { "bins": 9 } })),
                "state",
            ),
            (
                "POST",
                format!("/api/surface/{id}/dispatch"),
                Some(json!({ "event": { "widget": "choose", "kind": "click" } })),
                "effects",
            ),
            (
                "GET",
                format!("/api/surface/{id}/events?after_seq=0"),
                None,
                "events",
            ),
            (
                "GET",
                format!("/api/surface/{id}/wait?after_seq=0&timeout_ms=10"),
                None,
                "events",
            ),
            (
                "PUT",
                format!("/api/surface/{id}?expected_revision=1"),
                Some(json!({ "spec": scratch_spec() })),
                "revision",
            ),
        ];
        let mut seen = Vec::new();
        for (method, path, body, key) in steps {
            let got = http.call(method, &path, body).await?;
            expect(&format!("{method} {path}"), &got, 200)?;
            if got.1.get(key).is_none() {
                return Err(format!("{method} {path} has no `{key}`: {}", got.1));
            }
            seen.push(format!("{method} {}", path.replace(&id, "<id>")));
        }
        // The dispatch's emit reached the ring.
        let events = http
            .call("GET", &format!("/api/surface/{id}/events"), None)
            .await?;
        let names: Vec<&str> = events.1["events"]
            .as_array()
            .map(|a| a.iter().filter_map(|e| e["name"].as_str()).collect())
            .unwrap_or_default();
        if !names.contains(&"chosen") {
            return Err(format!("the click emitted nothing: {}", events.1));
        }
        Ok(format!(
            "{} routes answered 200 with wire_version 1: {}",
            seen.len() + 2,
            seen.join(", ")
        ))
    }
    .await;
    let deleted = http
        .call("DELETE", &format!("/api/surface/{id}"), None)
        .await;
    let deleted = deleted.and_then(|d| expect("DELETE", &d, 200));
    match (result, deleted) {
        (Ok(detail), Ok(())) => Ok(format!("{detail}; scratch surface {id} deleted")),
        (Err(e), _) => Err(format!("{e} (scratch surface {id} delete attempted)")),
        (Ok(_), Err(e)) => Err(format!("the scratch surface {id} was not deleted: {e}")),
    }
}

async fn strict(http: &Http) -> Result<String, String> {
    let none = "00000000-0000-4000-8000-000000000000";
    let cases = [
        (
            "POST",
            format!("/api/surface/{none}/show"),
            Some(json!({ "target": { "id": 7 } })),
            "id",
        ),
        (
            "GET",
            format!("/api/surface/{none}/events?after=0"),
            None,
            "after",
        ),
        (
            "GET",
            format!("/api/surface/{none}/render?pane=3"),
            None,
            "pane",
        ),
    ];
    for (method, path, body, field) in cases {
        let got = http.call(method, &path, body).await?;
        expect(&format!("{method} {path}"), &got, 400)?;
        let message = got.1["message"].as_str().unwrap_or_default();
        if got.1["code"] != "invalid-argument" || !message.contains(field) {
            return Err(format!(
                "{method} {path} must refuse `{field}` by name: {}",
                got.1
            ));
        }
    }
    Ok("target {\"id\": 7}, ?after= and ?pane= each refused 400 invalid-argument, naming the field".into())
}

async fn invalid_spec(http: &Http) -> Result<String, String> {
    let spec = json!({ "surface": "1.0", "name": SCRATCH, "root": { "table": { "rows": [] } } });
    let got = http.call("POST", "/api/surface", Some(spec)).await?;
    expect("POST /api/surface (invalid)", &got, 422)?;
    if got.1["code"] != "invalid-spec" || got.1["problems"].as_array().is_none_or(|p| p.is_empty())
    {
        return Err(format!(
            "not refused as invalid-spec with problems: {}",
            got.1
        ));
    }
    let listed = http.call("GET", "/api/surface", None).await?;
    let stored = listed.1["surfaces"]
        .as_array()
        .map(|rows| rows.iter().any(|r| r["name"] == SCRATCH))
        .unwrap_or(false);
    if stored {
        return Err("the refused spec was stored anyway".into());
    }
    Ok(format!(
        "422 invalid-spec, first problem {} — nothing stored",
        got.1["problems"][0]
    ))
}
