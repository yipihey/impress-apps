//! Tier B capabilities — drive a running imprint app over its HTTP API.
//!
//! These cover behavior that genuinely needs the live app: the real store, the
//! live search index, actual compilation. When the app isn't reachable, every
//! Tier B capability is **skipped** so a headless CI run without a GUI stays
//! green.
//!
//! **SC-1 (docs/plan-self-reflective-layer.md § Scenarios, table SC-1):** the
//! six class-(i) "pure call sequence" entries below (`app.reachable`,
//! `app.list_documents`, `app.cross_doc_search`, `app.compile_pdf`,
//! `throughline.opt_in_live`, `throughline.live_round_trip`) are no longer
//! hand-coded closures. They are stored `impress/scenario@1.0.0` documents
//! under `scenarios/` (embedded at compile time), run through the one shared
//! runner (`impress_scenario::run`) against this crate's own
//! [`crate::scenario_caller::ImprintTierBCaller`] — not a bespoke loop.
//!
//! `manuscripts.detail_and_history` and `store.wal_health` are **kept as
//! hand-written code**, each marked below with why (SC-1's own
//! classification): the former is class (iii) — it needs real manuscripts in
//! the store and loops over however many rows are there, which is app state a
//! closed scenario spec (ADR-0033 D3: no expressions, no loops) cannot
//! express; the latter is class (iv) — it reads a second daemon's
//! (`impress-ai-server`) unauthenticated health route, a different app
//! entirely from the one this catalogue's `requires.app` names.

use impress_layout_service::scenario_caller::LoopbackClient;
use impress_scenario::Scenario;
use serde_json::Value;
use url::Url;

use crate::scenario_caller::ImprintTierBCaller;
use crate::{check, skipped, CapabilityResult, Tier};

/// Build a client for `base_url`, or `None` if the URL is malformed.
fn client_for(base_url: &str) -> Option<(String, LoopbackClient)> {
    let url = Url::parse(base_url).ok()?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return None;
    }
    let origin = url.origin().ascii_serialization();
    Some((origin.clone(), LoopbackClient::new(&origin)))
}

/// The six converted scenario documents, embedded at compile time (SC-1: they
/// are stored documents, not closures — `include_str!` just gets the bytes
/// into the binary without a runtime file read, the same way
/// `impress-scenario-service`'s own fixtures are not read from disk at
/// runtime either).
const SCENARIO_DOCS: &[&str] = &[
    include_str!("../scenarios/app.reachable.json"),
    include_str!("../scenarios/app.list_documents.json"),
    include_str!("../scenarios/app.cross_doc_search.json"),
    include_str!("../scenarios/app.compile_pdf.json"),
    include_str!("../scenarios/throughline.opt_in_live.json"),
    include_str!("../scenarios/throughline.live_round_trip.json"),
];

/// Parse every embedded scenario document. Panics on a malformed document —
/// these are compiled into the binary, so a bad one is a build-time bug, not
/// a runtime condition.
pub fn scenarios() -> Vec<Scenario> {
    SCENARIO_DOCS
        .iter()
        .map(|doc| serde_json::from_str(doc).expect("embedded scenario document is valid JSON"))
        .collect()
}

/// Run all Tier B capabilities against `base_url`. Skips everything if the app
/// isn't reachable.
pub async fn run(base_url: &str) -> Vec<CapabilityResult> {
    let (origin, client) = match client_for(base_url) {
        Some(c) => c,
        None => {
            return vec![skipped(
                "app.reachable",
                "imprint HTTP API is reachable",
                Tier::B,
                &format!("invalid base url: {base_url}"),
            )]
        }
    };

    // One probe gates the whole tier: no app → skip, don't fail.
    let info = client
        .post(
            "/api/verb/imprint-app-service_status",
            &serde_json::json!({}),
        )
        .await;
    if !matches!(info, Ok((200, ref value)) if value["running"] == true) {
        let reason = format!("no imprint app responding at {base_url}");
        let mut out = vec![skipped(
            "app.reachable",
            "imprint HTTP API is reachable",
            Tier::B,
            &reason,
        )];
        for scenario in scenarios().iter().filter(|s| s.id != "app.reachable") {
            out.push(skipped(
                &scenario.id,
                &scenario.description,
                Tier::B,
                "app not running",
            ));
        }
        out.push(skipped(
            "manuscripts.detail_and_history",
            "Every manuscript row resolves in the Info-tab store read, with history/revisions queryable",
            Tier::B,
            "app not running",
        ));
        out.push(skipped(
            "store.wal_health",
            "Shared-store WAL stays within the maintenance budget",
            Tier::B,
            "app not running",
        ));
        return out;
    }

    let mut out = Vec::new();

    for scenario in scenarios() {
        let mut caller = ImprintTierBCaller::new(&origin);
        out.push(impress_scenario::run(&scenario, &mut caller).await);
    }

    out.push(manuscript_detail_history_capability(&client).await);
    out.push(store_wal_health_capability().await);

    out
}

/// The 2026-08-06 WAL-starvation regression gate: the shared store's WAL must
/// stay near the maintenance budget. Reads the AI daemon's unauthenticated
/// `/api/health` (the maintenance owner's own telemetry); skips when the
/// daemon isn't running. The threshold is 4× the daemon's declared budget so
/// a checkpoint-in-progress never flaps the gate — the incident state was
/// 200× over.
///
/// SC-1 class (iv): reads a second daemon entirely, not this catalogue's app.
/// It must be an explicitly supplied test-owned endpoint: never probe the
/// default AI daemon on this machine.
async fn store_wal_health_capability() -> CapabilityResult {
    let id = "store.wal_health";
    let desc = "Shared-store WAL stays within the maintenance budget";
    let endpoint = match std::env::var("IMPRINT_SELFTEST_WAL_HEALTH_URL") {
        Ok(value) => value,
        Err(_) => return skipped(id, desc, Tier::B, "no explicit test-owned WAL health URL"),
    };
    let url = match Url::parse(&endpoint) {
        Ok(url)
            if url.scheme() == "http"
                && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"))
                && url.path() == "/api/health" =>
        {
            url
        }
        _ => {
            return skipped(
                id,
                desc,
                Tier::B,
                "IMPRINT_SELFTEST_WAL_HEALTH_URL must be a loopback /api/health URL",
            )
        }
    };
    let result = LoopbackClient::new(&url.origin().ascii_serialization())
        .get("/api/health")
        .await;
    let outcome = match result {
        Ok((200, body)) => wal_health_result(&body),
        Ok((status, body)) => Err(format!("WAL health returned HTTP {status}: {body}")),
        Err(error) => Err(format!("explicit WAL health endpoint failed: {error}")),
    };
    check(id, desc, Tier::B, || async move { outcome }).await
}

fn wal_health_result(body: &Value) -> Result<String, String> {
    let wal = body["wal_bytes"]
        .as_u64()
        .ok_or("WAL health omitted numeric wal_bytes")?;
    let budget = body["wal_budget_bytes"]
        .as_u64()
        .ok_or("WAL health omitted numeric wal_budget_bytes")?;
    let db = body["db_bytes"].as_u64().unwrap_or(0);
    if wal <= budget.saturating_mul(4) {
        Ok(format!(
            "WAL {} MB (budget {} MB), db {} MB",
            wal / (1024 * 1024),
            budget / (1024 * 1024),
            db / (1024 * 1024)
        ))
    } else {
        Err(format!(
            "WAL {} MB exceeds 4x the {} MB budget — checkpoint starvation is back",
            wal / (1024 * 1024),
            budget / (1024 * 1024)
        ))
    }
}

/// The "Manuscript Not Found for a healthy manuscript" regression gate: every
/// row `/api/manuscripts` lists (store-native AND watched/external markdown)
/// must resolve through the chassis store read the Info tab renders from, and
/// its history/revisions surfaces must answer. Read-only.
///
/// SC-1 class (iii): needs real manuscripts in the store and loops over
/// however many rows are there — app state, not a closed call sequence.
async fn manuscript_detail_history_capability(client: &LoopbackClient) -> CapabilityResult {
    let id = "manuscripts.detail_and_history";
    let desc =
        "Every manuscript row resolves in the Info-tab store read, with history/revisions queryable";

    let rows = match client
        .get("/api/manuscripts")
        .await
        .and_then(|(status, body)| {
            ensure_ok(status, &body, "list_manuscripts")?;
            body["manuscripts"]
                .as_array()
                .cloned()
                .ok_or("list_manuscripts omitted manuscripts array".into())
        }) {
        Ok(rows) => rows,
        Err(e) => {
            return check(id, desc, Tier::B, || async move {
                Err(format!("list_manuscripts failed: {e}"))
            })
            .await
        }
    };
    if rows.is_empty() {
        return skipped(id, desc, Tier::B, "no manuscripts in the store");
    }

    // Probe every row's detail (cheap), plus history/revisions on the first
    // few — enough to catch a facade split without hammering the app.
    let body = async {
        let mut unresolved: Vec<String> = Vec::new();
        for row in &rows {
            let id = required_row_string(row, "id")?;
            let title = required_row_string(row, "title")?;
            let path = format!("/api/manuscripts/{id}");
            let (status, body) = client.get(&path).await?;
            ensure_ok(status, &body, &format!("detail probe {id}"))?;
            let found = body["manuscript"]["storeDetailFound"]
                .as_bool()
                .ok_or_else(|| format!("detail probe {id} omitted storeDetailFound"))?;
            if !found {
                unresolved.push(format!("{id} ({title})"));
            }
        }
        if !unresolved.is_empty() {
            return Err(format!(
                "{} of {} rows missing from the Info-tab store read: {}",
                unresolved.len(),
                rows.len(),
                unresolved.join(", ")
            ));
        }
        let mut history_total = 0u64;
        for row in rows.iter().take(3) {
            let id = required_row_string(row, "id")?;
            for (suffix, total) in [("history", true), ("revisions", false)] {
                let path = format!("/api/manuscripts/{id}/{suffix}");
                let (status, body) = client.get(&path).await?;
                ensure_ok(status, &body, &format!("{suffix} {id}"))?;
                let count = body["count"]
                    .as_u64()
                    .ok_or_else(|| format!("{suffix} {id} omitted count"))?;
                if total {
                    history_total += count;
                }
            }
        }
        Ok(format!(
            "{} rows all resolve; {} history ops across first 3",
            rows.len(),
            history_total
        ))
    };
    let outcome = body.await;
    check(id, desc, Tier::B, || async move { outcome }).await
}

fn ensure_ok(status: u16, body: &Value, operation: &str) -> Result<(), String> {
    if status == 200 && body["status"] == "ok" {
        Ok(())
    } else {
        Err(format!("{operation}: HTTP {status}: {body}"))
    }
}

fn required_row_string<'a>(row: &'a Value, key: &str) -> Result<&'a str, String> {
    row[key]
        .as_str()
        .ok_or_else(|| format!("manuscript row omitted {key}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_scenario::validate;

    #[test]
    fn embedded_scenarios_parse_and_validate() {
        let docs = scenarios();
        assert_eq!(docs.len(), 6, "expected the six SC-1 converted entries");
        let expected_ids = [
            "app.reachable",
            "app.list_documents",
            "app.cross_doc_search",
            "app.compile_pdf",
            "throughline.opt_in_live",
            "throughline.live_round_trip",
        ];
        for (doc, expected) in docs.iter().zip(expected_ids) {
            assert_eq!(doc.id, expected);
            let problems = validate::validate(doc);
            assert!(problems.is_empty(), "{}: {problems:?}", doc.id);
        }
    }

    #[tokio::test]
    async fn unreachable_app_skips_every_capability_with_stable_ids() {
        let results = run("http://127.0.0.1:1").await;
        let ids: Vec<&str> = results.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "app.reachable",
                "app.list_documents",
                "app.cross_doc_search",
                "app.compile_pdf",
                "throughline.opt_in_live",
                "throughline.live_round_trip",
                "manuscripts.detail_and_history",
                "store.wal_health",
            ]
        );
        assert!(results.iter().all(|r| r.skipped && !r.pass));
    }

    #[test]
    fn wal_health_requires_actual_telemetry() {
        assert!(wal_health_result(&serde_json::json!({})).is_err());
        assert!(wal_health_result(&serde_json::json!({
            "wal_bytes": 5, "wal_budget_bytes": 1
        }))
        .is_err());
        assert!(wal_health_result(&serde_json::json!({
            "wal_bytes": 4, "wal_budget_bytes": 1, "db_bytes": 9
        }))
        .is_ok());
    }
}
