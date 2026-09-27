//! The Tier B `Caller`: drives a running app over its loopback HTTP
//! surface, through [`crate::shared_client::LoopbackClient`].
//!
//! # `call`, honestly, before H-P5-1
//!
//! The plan's target shape is `POST /api/verb/<name>` (H-P5-1, P5, queued —
//! not landed as of this crate). Until it lands, a `call` step reaches a
//! verb only through the small, explicit dispatch table below: the layout
//! service's two HTTP surfaces (`/api/layout/verb` for a
//! `impress_layout::Verb`, `/api/layout/op` for the six other operations —
//! `save-layout`, `apply-layout`, `apply-layout-by-ordinal`,
//! `delete-layout`, `commit`, `get-layout`/`list-layouts`/`resolve-reference`
//! read through `GET /api/layout/tree` and `/api/layout/layouts`) and the
//! surface service's dispatch route. A `call` naming any other verb is
//! refused by name, clearly, rather than silently no-op'ing — exactly the
//! failure mode `docs/plan-self-reflective-layer.md` § Scenarios asks a
//! scenario to fail loudly about. `gesture` and `event` need no dispatch
//! table: they always mean the layout verb route and the surface dispatch
//! route respectively.

use async_trait::async_trait;
use impress_scenario::{CallOutcome, Caller, EventBody, WaitBody};
use serde_json::{json, Value};

use crate::shared_client::LoopbackClient;

pub struct TierBCaller {
    http: LoopbackClient,
    /// A very small effects proxy: every kind this caller wrote via a
    /// `layout-service_*`/`surface-service_*` call it recognized, by name.
    /// Nowhere near a real spy (see `tier_a.rs`'s module docs for the same
    /// caveat) — Tier B has no store to re-query, so this is the only
    /// signal available without H-P5-1's generic route naming its own
    /// effects.
    wrote: std::collections::BTreeSet<String>,
}

impl TierBCaller {
    pub fn new(base_url: &str) -> Self {
        Self {
            http: LoopbackClient::new(base_url),
            wrote: std::collections::BTreeSet::new(),
        }
    }
}

/// Which `impress/ui/*` kind a recognized verb writes, for the effects
/// proxy above.
fn kind_for(verb: &str) -> Option<&'static str> {
    if verb.starts_with("layout-service_") {
        Some("impress/ui/layout@1.0.0")
    } else if verb.starts_with("surface-service_") {
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
                // Everything else is a `Verb` (split/resize/swap/close/…):
                // the wire body IS the args, matching `gesture`.
                self.verb(args).await?
            }
            "surface-service_surface-dispatch" => {
                let id = args
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "`surface-dispatch` needs `id`".to_string())?
                    .to_string();
                let (status, value) = self
                    .http
                    .post(&format!("/api/surface/{id}/dispatch"), &args)
                    .await?;
                CallOutcome {
                    result: value,
                    status: Some(status),
                }
            }
            "surface-service_surface-list" => {
                let (status, value) = self.http.get("/api/surface").await?;
                CallOutcome {
                    result: value,
                    status: Some(status),
                }
            }
            other => {
                return Err(format!(
                    "`{other}` cannot be called over Tier B yet — no generic verb route until \
                     H-P5-1 (P5) lands; only layout-service_*/surface-service_* verbs this \
                     dispatch table names are supported"
                ));
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
