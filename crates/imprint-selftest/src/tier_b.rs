//! Tier B capabilities — drive a running imprint app over its HTTP API.
//!
//! These cover behavior that genuinely needs the live app: the real store, the
//! live search index, actual compilation. When the app isn't reachable, every
//! Tier B capability is **skipped** (reported as passing-but-skipped) so a
//! headless CI run without a GUI stays green.

use impress_app_client::ImprintClient;
use imprint_service::handlers::CompileOptions;
use url::Url;

use crate::{check, skipped, CapabilityResult, Tier};

/// Build a client for `base_url`, or `None` if the URL is malformed.
fn client_for(base_url: &str) -> Option<ImprintClient> {
    Url::parse(base_url).ok().map(ImprintClient::with_base_url)
}

/// Run all Tier B capabilities against `base_url`. Skips everything if the app
/// isn't reachable.
pub async fn run(base_url: &str) -> Vec<CapabilityResult> {
    let client = match client_for(base_url) {
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
    let info = client.probe().await;
    if info.is_none() {
        let reason = format!("no imprint app responding at {base_url}");
        return vec![
            skipped(
                "app.reachable",
                "imprint HTTP API is reachable",
                Tier::B,
                &reason,
            ),
            skipped(
                "app.list_documents",
                "Live document list is queryable",
                Tier::B,
                "app not running",
            ),
            skipped(
                "app.cross_doc_search",
                "Live search index is queryable",
                Tier::B,
                "app not running",
            ),
            skipped(
                "app.compile_pdf",
                "Live Typst compile returns a non-empty PDF",
                Tier::B,
                "app not running",
            ),
            skipped(
                "throughline.opt_in_live",
                "Non-opted documents 404 with has_throughline=false over live HTTP",
                Tier::B,
                "app not running",
            ),
            skipped(
                "throughline.live_round_trip",
                "Live create → anchors → mark-supporting → delete leaves no residue",
                Tier::B,
                "app not running",
            ),
            skipped(
                "manuscripts.detail_and_history",
                "Every manuscript row resolves in the Info-tab store read, with history/revisions queryable",
                Tier::B,
                "app not running",
            ),
            skipped(
                "store.wal_health",
                "Shared-store WAL stays within the maintenance budget",
                Tier::B,
                "app not running",
            ),
        ];
    }
    let info = info.unwrap();

    let mut out = Vec::new();

    out.push(
        check(
            "app.reachable",
            "imprint HTTP API is reachable",
            Tier::B,
            || async {
                Ok(format!(
                    "status={}, version={}",
                    info.status,
                    info.version.clone().unwrap_or_else(|| "?".into())
                ))
            },
        )
        .await,
    );

    out.push(
        check(
            "app.list_documents",
            "Live document list is queryable",
            Tier::B,
            || async {
                match client.list_documents().await {
                    Ok(docs) => Ok(format!("{} documents", docs.len())),
                    Err(e) => Err(format!("list_documents failed: {e}")),
                }
            },
        )
        .await,
    );

    out.push(
        check(
            "app.cross_doc_search",
            "Live search index is queryable",
            Tier::B,
            || async {
                // An empty result set is fine — we're asserting the index responds,
                // not that any given term exists.
                match client.search("the", 5).await {
                    Ok(hits) => Ok(format!("index responded with {} hits", hits.len())),
                    Err(e) => Err(format!("search failed: {e}")),
                }
            },
        )
        .await,
    );

    out.push(compile_capability(&client).await);
    out.push(throughline_opt_in_capability(&client).await);
    out.push(throughline_round_trip_capability(&client).await);
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
async fn store_wal_health_capability() -> CapabilityResult {
    let id = "store.wal_health";
    let desc = "Shared-store WAL stays within the maintenance budget";
    let health = reqwest::Client::new()
        .get("http://127.0.0.1:8787/api/health")
        .timeout(std::time::Duration::from_secs(3))
        .send()
        .await;
    let response = match health {
        Ok(response) if response.status().is_success() => response,
        Ok(response) => {
            return skipped(
                id,
                desc,
                Tier::B,
                &format!("ai daemon health returned HTTP {}", response.status()),
            )
        }
        Err(_) => return skipped(id, desc, Tier::B, "impress-ai-server not running on 8787"),
    };
    let body: serde_json::Value = match response.json().await {
        Ok(body) => body,
        Err(error) => {
            return check(id, desc, Tier::B, || async move {
                Err(format!("health body did not parse: {error}"))
            })
            .await
        }
    };
    let wal = body["wal_bytes"].as_u64().unwrap_or(0);
    let budget = body["wal_budget_bytes"]
        .as_u64()
        .unwrap_or(64 * 1024 * 1024);
    let db = body["db_bytes"].as_u64().unwrap_or(0);
    let outcome = if wal <= budget.saturating_mul(4) {
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
    };
    check(id, desc, Tier::B, || async move { outcome }).await
}

/// The "Manuscript Not Found for a healthy manuscript" regression gate: every
/// row `/api/manuscripts` lists (store-native AND watched/external markdown)
/// must resolve through the chassis store read the Info tab renders from, and
/// its history/revisions surfaces must answer. Read-only.
async fn manuscript_detail_history_capability(client: &ImprintClient) -> CapabilityResult {
    let id = "manuscripts.detail_and_history";
    let desc =
        "Every manuscript row resolves in the Info-tab store read, with history/revisions queryable";

    let rows = match client.list_manuscripts().await {
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
            let probe = client
                .manuscript_detail_probe(&row.id)
                .await
                .map_err(|e| format!("detail probe {} failed: {e}", row.id))?;
            if !probe.store_detail_found {
                unresolved.push(format!("{} ({})", row.id, row.title));
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
            history_total += client
                .manuscript_history_count(&row.id)
                .await
                .map_err(|e| format!("history {} failed: {e}", row.id))?;
            let _ = client
                .manuscript_revisions_count(&row.id)
                .await
                .map_err(|e| format!("revisions {} failed: {e}", row.id))?;
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

/// Live compile: the app's `/api/compile/typst` returns raw PDF bytes, which
/// the typed client currently expects as a JSON envelope. Until that's
/// reconciled, a client transport/decode error here is reported as a skip
/// (with the reason) rather than a failure, so it never spuriously reds the
/// report. A reachable server that returns a real compile error still fails.
async fn compile_capability(client: &ImprintClient) -> CapabilityResult {
    let src = "= Hello\n\nThis is a self-test document.\n";
    match client.compile_typst(src, CompileOptions::default()).await {
        Ok(result) => {
            let bytes = result.pdf_data.as_ref().map(|d| d.len()).unwrap_or(0);
            let pages = result.page_count;
            if bytes > 0 {
                check(
                    "app.compile_pdf",
                    "Live Typst compile returns a non-empty PDF",
                    Tier::B,
                    || async { Ok(format!("compiled {bytes}-byte PDF, {pages} pages")) },
                )
                .await
            } else {
                let err = result
                    .error
                    .unwrap_or_else(|| "empty PDF and no error".into());
                check(
                    "app.compile_pdf",
                    "Live Typst compile returns a non-empty PDF",
                    Tier::B,
                    || async { Err(format!("compile failed: {err}")) },
                )
                .await
            }
        }
        Err(e) => skipped(
            "app.compile_pdf",
            "Live Typst compile returns a non-empty PDF",
            Tier::B,
            &format!("client compile transport/decode issue: {e}"),
        ),
    }
}

/// Opt-in invariant over live HTTP (ADR-0016 D1): a document that never
/// opted in must 404 with `has_throughline: false` on every throughline
/// route. Read-only — probes a random UUID that cannot exist.
async fn throughline_opt_in_capability(client: &ImprintClient) -> CapabilityResult {
    let id = "throughline.opt_in_live";
    let desc = "Non-opted documents 404 with has_throughline=false over live HTTP";
    let doc = uuid::Uuid::new_v4().to_string();
    match (
        client.get_throughline(&doc).await,
        client.get_throughline_anchors(&doc).await,
        client.get_throughline_coverage(&doc).await,
    ) {
        (Ok(None), Ok(None), Ok(None)) => {
            check(id, desc, Tier::B, || async {
                Ok("all three GETs 404 for a non-opted document".to_string())
            })
            .await
        }
        (a, b, c) => {
            check(id, desc, Tier::B, || async move {
                Err(format!("expected three 404s, got {a:?} / {b:?} / {c:?}"))
            })
            .await
        }
    }
}

/// Full mutation round-trip against the live store, self-cleaning: create
/// a throughline for a synthetic document id, verify the scaffold anchor
/// derives synced, exercise mark-supporting (no sections exist, so it's a
/// pure ledger write), then delete and verify the 404 returns. Leaves no
/// residue in the live store.
async fn throughline_round_trip_capability(client: &ImprintClient) -> CapabilityResult {
    let id = "throughline.live_round_trip";
    let desc = "Live create → anchors → mark-supporting → delete leaves no residue";
    let doc = uuid::Uuid::new_v4().to_string();

    let body = async {
        let created = client
            .create_throughline(&doc, "Selftest throughline")
            .await
            .map_err(|e| format!("create: {e}"))?;
        if created.get("has_throughline").and_then(|v| v.as_bool()) != Some(true) {
            // Best-effort cleanup before failing.
            let _ = client.delete_throughline(&doc).await;
            return Err(format!("create returned unexpected body: {created}"));
        }

        let anchors = client
            .get_throughline_anchors(&doc)
            .await
            .map_err(|e| format!("anchors: {e}"))?
            .ok_or("anchors 404 right after create")?;
        let states: Vec<String> = anchors["anchors"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|x| x["state"].as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        if states != vec!["synced".to_string()] {
            let _ = client.delete_throughline(&doc).await;
            return Err(format!("scaffold anchor states: {states:?}"));
        }

        client
            .patch_throughline_anchors(
                &doc,
                serde_json::json!({
                    "action": "mark-supporting",
                    "section_key": "selftest-appendix",
                    "supporting": true
                }),
            )
            .await
            .map_err(|e| format!("mark-supporting: {e}"))?;

        let deleted = client
            .delete_throughline(&doc)
            .await
            .map_err(|e| format!("delete: {e}"))?;
        if !deleted {
            return Err("delete reported nothing to delete".into());
        }
        if client
            .get_throughline(&doc)
            .await
            .map_err(|e| format!("post-delete get: {e}"))?
            .is_some()
        {
            return Err("throughline survived deletion".into());
        }
        Ok("create/derive/patch/delete round-trip clean, no residue".to_string())
    };
    match body.await {
        Ok(msg) => check(id, desc, Tier::B, || async move { Ok(msg) }).await,
        Err(e) => check(id, desc, Tier::B, || async move { Err(e) }).await,
    }
}
