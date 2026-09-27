//! The Tier B `Caller` for imprint's converted scenario documents (SC-1:
//! "the single shared runner", `impress_scenario::run`).
//!
//! imprint's Tier B catalogue never called a named `#[impress_method]` verb
//! — it drove the app's own bespoke REST routes (`/api/documents`,
//! `/api/search`, `/api/compile/typst`, `/api/documents/{id}/throughline*`)
//! through `impress_app_client::ImprintClient`. A scenario's `call` step
//! names a string, not necessarily an inventory verb, so this `Caller`
//! defines a small vocabulary (`imprint_status`, `imprint_list-documents`,
//! …) and maps each to the matching `ImprintClient` method, translating the
//! typed result into the plain JSON `CallOutcome` the interpreter checks
//! expectations against. Every result echoes back the fields a later step's
//! `capture` needs (e.g. `doc_id`), since nothing else in the response would
//! carry it.

use async_trait::async_trait;
use impress_app_client::ImprintClient;
use impress_scenario::{CallOutcome, Caller, EventBody, WaitBody};
use serde_json::{json, Value};

pub struct ImprintTierBCaller {
    client: ImprintClient,
}

impl ImprintTierBCaller {
    pub fn new(client: ImprintClient) -> Self {
        Self { client }
    }
}

#[async_trait]
impl Caller for ImprintTierBCaller {
    async fn call(
        &mut self,
        verb: &str,
        args: Value,
        _as_ident: &str,
    ) -> Result<CallOutcome, String> {
        match verb {
            "imprint_status" => {
                let info = self
                    .client
                    .probe()
                    .await
                    .ok_or_else(|| "no imprint app responding".to_string())?;
                Ok(CallOutcome {
                    result: json!({
                        "status": info.status,
                        "version": info.version,
                    }),
                    status: Some(200),
                })
            }
            "imprint_list-documents" => {
                let docs = self
                    .client
                    .list_documents()
                    .await
                    .map_err(|e| format!("list_documents: {e}"))?;
                Ok(CallOutcome {
                    result: json!({ "count": docs.len() }),
                    status: Some(200),
                })
            }
            "imprint_search" => {
                let query = args
                    .get("query")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "`imprint_search` needs `query`".to_string())?;
                let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(5) as u32;
                let hits = self
                    .client
                    .search(query, limit)
                    .await
                    .map_err(|e| format!("search: {e}"))?;
                Ok(CallOutcome {
                    result: json!({ "hits": hits.len() }),
                    status: Some(200),
                })
            }
            "imprint_compile-typst" => {
                let source = args
                    .get("source")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "`imprint_compile-typst` needs `source`".to_string())?;
                let result = self
                    .client
                    .compile_typst(source, imprint_service::handlers::CompileOptions::default())
                    .await
                    .map_err(|e| format!("compile: {e}"))?;
                let bytes = result.pdf_data.as_ref().map(|d| d.len()).unwrap_or(0);
                Ok(CallOutcome {
                    result: json!({
                        "bytes": bytes,
                        "pages": result.page_count,
                        "error": result.error,
                    }),
                    status: Some(200),
                })
            }
            "imprint_throughline-get" => self.throughline_get(&args, GetKind::Doc).await,
            "imprint_throughline-anchors-get" => {
                self.throughline_get(&args, GetKind::Anchors).await
            }
            "imprint_throughline-coverage-get" => {
                self.throughline_get(&args, GetKind::Coverage).await
            }
            "imprint_throughline-create" => {
                let doc_id = doc_id_of(&args)?;
                let title = args
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("Selftest throughline");
                match self.client.create_throughline(&doc_id, title).await {
                    Ok(mut value) => {
                        merge_doc_id(&mut value, &doc_id);
                        Ok(CallOutcome {
                            result: value,
                            status: Some(200),
                        })
                    }
                    Err(e) => Ok(CallOutcome {
                        result: json!({ "doc_id": doc_id, "error": e.to_string() }),
                        status: Some(409),
                    }),
                }
            }
            "imprint_throughline-anchors-patch" => {
                let doc_id = doc_id_of(&args)?;
                let body = json!({
                    "action": args.get("action").cloned().unwrap_or(Value::Null),
                    "section_key": args.get("section_key").cloned().unwrap_or(Value::Null),
                    "supporting": args.get("supporting").cloned().unwrap_or(Value::Null),
                });
                let mut value = self
                    .client
                    .patch_throughline_anchors(&doc_id, body)
                    .await
                    .map_err(|e| format!("mark-supporting: {e}"))?;
                merge_doc_id(&mut value, &doc_id);
                Ok(CallOutcome {
                    result: value,
                    status: Some(200),
                })
            }
            "imprint_throughline-delete" => {
                let doc_id = doc_id_of(&args)?;
                let deleted = self
                    .client
                    .delete_throughline(&doc_id)
                    .await
                    .map_err(|e| format!("delete: {e}"))?;
                Ok(CallOutcome {
                    result: json!({ "doc_id": doc_id, "deleted": deleted }),
                    status: Some(200),
                })
            }
            other => Err(format!(
                "`{other}` is not one of imprint's scenario call names"
            )),
        }
    }

    async fn event(&mut self, _event: &EventBody) -> Result<CallOutcome, String> {
        Err("imprint's Tier B scenarios use no `event` steps".to_string())
    }

    async fn gesture(&mut self, _gesture: &Value) -> Result<CallOutcome, String> {
        Err("imprint's Tier B scenarios use no `gesture` steps".to_string())
    }

    async fn wait(&mut self, wait: &WaitBody) -> Result<(), String> {
        Err(format!(
            "imprint's converted Tier B scenarios use no `wait` steps: {wait:?}"
        ))
    }

    async fn seed(&mut self, kind: &str, _payload: &Value) -> Result<Value, String> {
        Err(format!(
            "seeding a live imprint app's store is out of scope (kind `{kind}`)"
        ))
    }

    fn wrote(&self, _kind: &str) -> bool {
        false
    }
}

enum GetKind {
    Doc,
    Anchors,
    Coverage,
}

impl ImprintTierBCaller {
    async fn throughline_get(&self, args: &Value, kind: GetKind) -> Result<CallOutcome, String> {
        let doc_id = doc_id_of(args)?;
        let fetched = match kind {
            GetKind::Doc => self.client.get_throughline(&doc_id).await,
            GetKind::Anchors => self.client.get_throughline_anchors(&doc_id).await,
            GetKind::Coverage => self.client.get_throughline_coverage(&doc_id).await,
        }
        .map_err(|e| format!("throughline get: {e}"))?;
        match fetched {
            None => Ok(CallOutcome {
                result: json!({ "doc_id": doc_id, "has_throughline": false }),
                status: Some(404),
            }),
            Some(mut value) => {
                merge_doc_id(&mut value, &doc_id);
                if matches!(kind, GetKind::Anchors) {
                    let states: Vec<String> = value["anchors"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x["state"].as_str().map(String::from))
                                .collect()
                        })
                        .unwrap_or_default();
                    merge_field(&mut value, "states", json!(states));
                }
                Ok(CallOutcome {
                    result: value,
                    status: Some(200),
                })
            }
        }
    }
}

fn doc_id_of(args: &Value) -> Result<String, String> {
    args.get("doc_id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| "a throughline call needs `doc_id`".to_string())
}

fn merge_doc_id(value: &mut Value, doc_id: &str) {
    merge_field(value, "doc_id", json!(doc_id));
}

fn merge_field(value: &mut Value, key: &str, field: Value) {
    if let Some(map) = value.as_object_mut() {
        map.insert(key.to_string(), field);
    }
}
