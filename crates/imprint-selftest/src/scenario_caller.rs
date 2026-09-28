//! Tier B scenario aliases backed by imprint's native verb route.
//!
//! The stored scenarios predate the verb inventory. Keep their call names and
//! assertions stable while deriving assertion fields from canonical results.
//! The route, not a scenario's `as` label, supplies caller identity.

use async_trait::async_trait;
use impress_layout_service::scenario_caller::LoopbackClient;
use impress_scenario::{CallOutcome, Caller, EventBody, WaitBody};
use serde_json::{json, Value};

pub struct ImprintTierBCaller {
    http: LoopbackClient,
}

impl ImprintTierBCaller {
    pub fn new(base_url: &str) -> Self {
        Self {
            http: LoopbackClient::new(base_url),
        }
    }

    async fn verb(&self, name: &str, args: Value) -> Result<CallOutcome, String> {
        let (status, result) = self.http.post(&format!("/api/verb/{name}"), &args).await?;
        Ok(CallOutcome {
            result,
            status: Some(status),
        })
    }

    async fn throughline_get(&self, args: &Value, kind: GetKind) -> Result<CallOutcome, String> {
        let doc_id = required_str(args, "doc_id")?;
        let request = json!({ "doc_id": doc_id });
        // get-anchor-states returns [] for both an empty throughline and an
        // absent one. Check the keyed throughline before asking for states.
        let name = match kind {
            GetKind::Coverage => "imprint-throughline-service_get-coverage",
            _ => "imprint-throughline-service_get-throughline",
        };
        let mut answer = self.verb(name, request.clone()).await?;
        if !succeeded(&answer) {
            return Ok(answer);
        }
        let absent = match kind {
            GetKind::Coverage => !answer.result["has_throughline"]
                .as_bool()
                .ok_or("get-coverage omitted has_throughline")?,
            _ => answer.result.is_null(),
        };
        if absent {
            return Ok(CallOutcome {
                result: json!({ "doc_id": doc_id, "has_throughline": false }),
                status: Some(404),
            });
        }
        if !matches!(kind, GetKind::Coverage) {
            require_throughline(&answer.result, doc_id)?;
        }
        if matches!(kind, GetKind::Anchors) {
            answer = self
                .verb("imprint-throughline-service_get-anchor-states", request)
                .await?;
            if !succeeded(&answer) {
                return Ok(answer);
            }
            let states = answer
                .result
                .as_array()
                .ok_or("get-anchor-states did not return an array")?
                .iter()
                .map(|anchor| {
                    anchor["state"]
                        .as_str()
                        .map(str::to_string)
                        .ok_or_else(|| "anchor is missing state".to_string())
                })
                .collect::<Result<Vec<_>, _>>()?;
            answer.result = json!({ "doc_id": doc_id, "states": states });
        } else {
            require_object(&answer.result, "throughline read")?;
            merge_field(&mut answer.result, "doc_id", json!(doc_id));
        }
        Ok(answer)
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
                let mut answer = self.verb("imprint-app-service_status", json!({})).await?;
                if !succeeded(&answer) {
                    return Ok(answer);
                }
                let running = answer.result["running"]
                    .as_bool()
                    .ok_or("status verb omitted running")?;
                merge_field(
                    &mut answer.result,
                    "status",
                    json!(if running { "ok" } else { "not-running" }),
                );
                if !running {
                    answer.status = Some(503);
                }
                Ok(answer)
            }
            "imprint_list-documents" => {
                let answer = self
                    .verb("imprint-manuscript-service_list-documents", json!({}))
                    .await?;
                count_array(answer, "count")
            }
            "imprint_search" => {
                let query = required_str(&args, "query")?;
                let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(5);
                let limit = u32::try_from(limit).map_err(|_| "limit exceeds u32".to_string())?;
                let answer = self
                    .verb(
                        "imprint-manuscript-service_search",
                        json!({ "query": query, "limit": limit }),
                    )
                    .await?;
                count_array(answer, "hits")
            }
            "imprint_compile-typst" => {
                let source = required_str(&args, "source")?;
                let options = imprint_service::handlers::CompileOptions::default();
                let mut answer = self
                    .verb(
                        "imprint-manuscript-service_compile-typst",
                        json!({ "source": source, "options": options }),
                    )
                    .await?;
                if !succeeded(&answer) {
                    return Ok(answer);
                }
                let bytes = if let Some(data) = answer.result["pdf_data"].as_array() {
                    data.len() as u64
                } else if let Some(path) = answer.result["pdf_path"].as_str() {
                    std::fs::metadata(path)
                        .map(|metadata| metadata.len())
                        .unwrap_or(0)
                } else {
                    0
                };
                require_object(&answer.result, "compile-typst")?;
                merge_field(&mut answer.result, "bytes", json!(bytes));
                Ok(answer)
            }
            "imprint_throughline-get" => self.throughline_get(&args, GetKind::Doc).await,
            "imprint_throughline-anchors-get" => {
                self.throughline_get(&args, GetKind::Anchors).await
            }
            "imprint_throughline-coverage-get" => {
                self.throughline_get(&args, GetKind::Coverage).await
            }
            "imprint_throughline-create" => {
                let doc_id = required_str(&args, "doc_id")?;
                let title = args
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("Selftest throughline");
                let mut answer = self
                    .verb(
                        "imprint-throughline-service_create-throughline",
                        json!({ "doc_id": doc_id, "title": title }),
                    )
                    .await?;
                if !succeeded(&answer) {
                    return Ok(answer);
                }
                if answer.result.is_null() {
                    return Ok(CallOutcome {
                        result: json!({ "doc_id": doc_id,
                        "has_throughline": false }),
                        status: Some(409),
                    });
                }
                require_throughline(&answer.result, doc_id)?;
                merge_field(&mut answer.result, "doc_id", json!(doc_id));
                merge_field(&mut answer.result, "has_throughline", json!(true));
                Ok(answer)
            }
            "imprint_throughline-anchors-patch" => {
                let doc_id = required_str(&args, "doc_id")?;
                if required_str(&args, "action")? != "mark-supporting" {
                    return Err("only the mark-supporting scenario action is supported".into());
                }
                let section_key = required_str(&args, "section_key")?;
                let supporting = args["supporting"]
                    .as_bool()
                    .ok_or("mark-supporting needs a supporting boolean")?;
                let mut answer = self
                    .verb(
                        "imprint-throughline-service_mark-supporting",
                        json!({ "doc_id": doc_id, "section_key": section_key,
                        "supporting": supporting }),
                    )
                    .await?;
                if !succeeded(&answer) {
                    return Ok(answer);
                }
                if answer.result.is_null() {
                    return Ok(CallOutcome {
                        result: json!({ "doc_id": doc_id,
                        "has_throughline": false }),
                        status: Some(404),
                    });
                }
                require_throughline(&answer.result, doc_id)?;
                merge_field(&mut answer.result, "doc_id", json!(doc_id));
                Ok(answer)
            }
            "imprint_throughline-delete" => {
                let doc_id = required_str(&args, "doc_id")?;
                let answer = self
                    .verb(
                        "imprint-throughline-service_delete-throughline",
                        json!({ "doc_id": doc_id }),
                    )
                    .await?;
                if !succeeded(&answer) {
                    return Ok(answer);
                }
                let deleted = answer
                    .result
                    .as_bool()
                    .ok_or("delete-throughline did not return a boolean")?;
                Ok(CallOutcome {
                    result: json!({ "doc_id": doc_id, "deleted": deleted }),
                    status: answer.status,
                })
            }
            other => Err(format!(
                "`{other}` is not one of imprint's scenario call names"
            )),
        }
    }

    async fn event(&mut self, _event: &EventBody) -> Result<CallOutcome, String> {
        Err("imprint's Tier B scenarios use no event steps".into())
    }
    async fn gesture(&mut self, _gesture: &Value) -> Result<CallOutcome, String> {
        Err("imprint's Tier B scenarios use no gesture steps".into())
    }
    async fn wait(&mut self, wait: &WaitBody) -> Result<(), String> {
        Err(format!(
            "imprint's converted Tier B scenarios use no wait steps: {wait:?}"
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

#[derive(Clone, Copy)]
enum GetKind {
    Doc,
    Anchors,
    Coverage,
}

fn succeeded(outcome: &CallOutcome) -> bool {
    outcome
        .status
        .is_some_and(|status| (200..300).contains(&status))
        && outcome.result.get("ok").and_then(Value::as_bool) != Some(false)
}

fn count_array(mut answer: CallOutcome, field: &str) -> Result<CallOutcome, String> {
    if succeeded(&answer) {
        let len = answer
            .result
            .as_array()
            .ok_or_else(|| format!("native result for `{field}` is not an array"))?
            .len();
        answer.result = json!({ (field): len });
    }
    Ok(answer)
}

fn required_str<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("scenario call needs `{key}`"))
}

fn require_object(value: &Value, name: &str) -> Result<(), String> {
    if value.is_object() {
        Ok(())
    } else {
        Err(format!("{name} did not return an object"))
    }
}

fn require_throughline(value: &Value, doc_id: &str) -> Result<(), String> {
    require_object(value, "throughline")?;
    if value["document_id"] == doc_id {
        Ok(())
    } else {
        Err(format!(
            "throughline result did not identify document {doc_id}"
        ))
    }
}

fn merge_field(value: &mut Value, key: &str, field: Value) {
    if let Some(map) = value.as_object_mut() {
        map.insert(key.to_string(), field);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::time::Duration;

    fn mock(
        responses: Vec<(u16, Value)>,
    ) -> (String, std::thread::JoinHandle<Vec<(String, Value)>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for (status, result) in responses {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut bytes = Vec::new();
                let end = loop {
                    let mut chunk = [0; 1024];
                    let n = stream.read(&mut chunk).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&chunk[..n]);
                    if let Some(pos) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        break pos + 4;
                    }
                };
                let header = String::from_utf8(bytes[..end].to_vec()).unwrap();
                let len: usize = header
                    .lines()
                    .find_map(|line| {
                        line.split_once(':').and_then(|(key, value)| {
                            key.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse().unwrap())
                        })
                    })
                    .unwrap();
                while bytes.len() - end < len {
                    let mut chunk = [0; 1024];
                    let n = stream.read(&mut chunk).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&chunk[..n]);
                }
                let body = serde_json::from_slice(&bytes[end..end + len]).unwrap();
                requests.push((header.lines().next().unwrap().to_string(), body));
                let wire = result.to_string();
                write!(stream,
                    "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{wire}",
                    wire.len()).unwrap();
            }
            requests
        });
        (base, handle)
    }

    #[tokio::test]
    async fn native_calls_use_canonical_names_and_real_argument_shapes() {
        let pdf = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(pdf.path(), b"%PDF-1.4").unwrap();
        let (base, server) = mock(vec![
            (200, json!({"running": true, "detail": "native"})),
            (200, json!([{"id": "doc-1"}, {"id": "doc-2"}])),
            (200, json!([])),
            (
                200,
                json!({"pdf_path": pdf.path(), "pdf_data": null,
                "error": null, "warnings": [], "page_count": 1}),
            ),
        ]);
        let mut caller = ImprintTierBCaller::new(&base);
        assert_eq!(
            caller
                .call("imprint_status", json!({}), "person")
                .await
                .unwrap()
                .result["status"],
            "ok"
        );
        assert_eq!(
            caller
                .call("imprint_list-documents", json!({}), "person")
                .await
                .unwrap()
                .result["count"],
            2
        );
        assert_eq!(
            caller
                .call("imprint_search", json!({"query":"the","limit":5}), "person")
                .await
                .unwrap()
                .result["hits"],
            0
        );
        assert_eq!(
            caller
                .call(
                    "imprint_compile-typst",
                    json!({"source":"= Hello"}),
                    "person"
                )
                .await
                .unwrap()
                .result["bytes"],
            8
        );
        let requests = server.join().unwrap();
        assert_eq!(
            requests[0].0,
            "POST /api/verb/imprint-app-service_status HTTP/1.1"
        );
        assert_eq!(
            requests[1].0,
            "POST /api/verb/imprint-manuscript-service_list-documents HTTP/1.1"
        );
        assert_eq!(
            requests[2],
            (
                "POST /api/verb/imprint-manuscript-service_search HTTP/1.1".into(),
                json!({"query":"the","limit":5})
            )
        );
        assert_eq!(
            requests[3].0,
            "POST /api/verb/imprint-manuscript-service_compile-typst HTTP/1.1"
        );
        assert_eq!(requests[3].1["source"], "= Hello");
        assert!(requests[3].1["options"].is_object());
    }

    #[tokio::test]
    async fn missing_throughline_and_refusal_are_not_successes() {
        let refusal = json!({"ok":false,"code":"forbidden","message":"denied"});
        let (base, server) = mock(vec![
            (200, Value::Null),
            (
                200,
                json!({"has_throughline": false, "uncovered_section_keys": []}),
            ),
            (403, refusal.clone()),
        ]);
        let mut caller = ImprintTierBCaller::new(&base);
        let absent = caller
            .call(
                "imprint_throughline-anchors-get",
                json!({"doc_id":"doc-1"}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(absent.status, Some(404));
        assert_eq!(absent.result["doc_id"], "doc-1");
        let coverage = caller
            .call(
                "imprint_throughline-coverage-get",
                json!({"doc_id":"doc-1"}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(coverage.status, Some(404));
        let refused = caller
            .call(
                "imprint_throughline-create",
                json!({"doc_id":"doc-1","title":"Test"}),
                "person",
            )
            .await
            .unwrap();
        assert_eq!(refused.status, Some(403));
        assert_eq!(refused.result, refusal);
        let requests = server.join().unwrap();
        assert_eq!(
            requests[0].0,
            "POST /api/verb/imprint-throughline-service_get-throughline HTTP/1.1"
        );
        assert_eq!(
            requests[1].0,
            "POST /api/verb/imprint-throughline-service_get-coverage HTTP/1.1"
        );
        assert_eq!(
            requests[2],
            (
                "POST /api/verb/imprint-throughline-service_create-throughline HTTP/1.1".into(),
                json!({"doc_id":"doc-1","title":"Test"})
            )
        );
    }

    #[tokio::test]
    async fn throughline_round_trip_preserves_scenario_assertions() {
        let throughline = json!({"document_id":"doc-1","item_id":"item-1","title":"Test"});
        let (base, server) = mock(vec![
            (200, throughline.clone()), // create
            (200, throughline.clone()), // get before anchor states
            (200, json!([{"label":"tl-overview","state":"synced"}])),
            (200, throughline), // mark supporting
            (200, json!(true)), // delete
            (200, Value::Null), // absent after delete
        ]);
        let mut caller = ImprintTierBCaller::new(&base);
        let created = caller
            .call(
                "imprint_throughline-create",
                json!({"doc_id":"doc-1","title":"Test"}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(created.status, Some(200));
        assert_eq!(created.result["has_throughline"], true);
        assert_eq!(created.result["doc_id"], "doc-1");
        let anchors = caller
            .call(
                "imprint_throughline-anchors-get",
                json!({"doc_id":"doc-1"}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(anchors.result["states"], json!(["synced"]));
        let marked = caller
            .call(
                "imprint_throughline-anchors-patch",
                json!({"doc_id":"doc-1","action":"mark-supporting",
                "section_key":"selftest-appendix","supporting":true}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(marked.status, Some(200));
        let deleted = caller
            .call(
                "imprint_throughline-delete",
                json!({"doc_id":"doc-1"}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(deleted.result["deleted"], true);
        let absent = caller
            .call(
                "imprint_throughline-get",
                json!({"doc_id":"doc-1"}),
                "agent:scenario",
            )
            .await
            .unwrap();
        assert_eq!(absent.status, Some(404));
        let requests = server.join().unwrap();
        assert_eq!(
            requests[2].0,
            "POST /api/verb/imprint-throughline-service_get-anchor-states HTTP/1.1"
        );
        assert_eq!(
            requests[3],
            (
                "POST /api/verb/imprint-throughline-service_mark-supporting HTTP/1.1".into(),
                json!({"doc_id":"doc-1","section_key":"selftest-appendix",
                "supporting":true})
            )
        );
        assert_eq!(
            requests[4].0,
            "POST /api/verb/imprint-throughline-service_delete-throughline HTTP/1.1"
        );
    }
}
