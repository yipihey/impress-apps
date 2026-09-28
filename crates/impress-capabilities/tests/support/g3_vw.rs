//! Fictional VW sessions and local image bytes, prepared before observation.
use impress_core::{sqlite_store::SqliteItemStore, store::ItemStore};
use impress_service_core::{
    pipeline::{self, Call, CallerIdentity},
    VerbDescriptor,
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::Path,
    sync::{Arc, Mutex, OnceLock},
};
fn bindings() -> &'static Mutex<BTreeMap<String, Value>> {
    static MAP: OnceLock<Mutex<BTreeMap<String, Value>>> = OnceLock::new();
    MAP.get_or_init(Default::default)
}
async fn call(method: &str, args: Value) -> Result<Value, String> {
    let verb = VerbDescriptor::find(&format!("vw-diagnostic-service_{method}"))
        .ok_or("VW descriptor missing")?;
    let result = pipeline::invoke(
        verb,
        Call::new(CallerIdentity::system("g3-vw-fixture"), args),
    )
    .await
    .map_err(|e| e.to_string())?;
    if result["ok"] != true {
        return Err(format!("VW fixture {method}: {result}"));
    }
    Ok(result)
}
pub async fn prepare(
    verb: &str,
    _: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("vw-diagnostic-service_") else {
        return Ok(());
    };
    let mut values = serde_json::Map::new();
    if matches!(method, "get-photo" | "search-photos") {
        let photos = vw_impress_adapter::PhotoEvidenceStore::new(root.join("blobs"))?;
        let result = photos.ingest_bytes(store.clone(), serde_json::from_value(json!({"file_id":"g3-owned-photo","download_url":"https://example.invalid/unused.png","mime_type":"image/png","file_name":"g3.png"})).map_err(|e| e.to_string())?, vw_impress_adapter::PhotoDescription { title:"G3 photo".into(), description:"Synthetic one-pixel fixture".into(), component:None, diagnostic_session_id:None, captured_at:None, tags:vec!["g3".into()] }, include_bytes!("g3-ink.png").to_vec());
        if !result.ok {
            return Err(result.message);
        }
        values.insert(
            "{{fixture.vw_photo_id}}".into(),
            json!(result.evidence.ok_or("photo evidence absent")?.id),
        );
    } else if !matches!(
        method,
        "get-capabilities" | "create-session" | "ingest-photo"
    ) {
        let methods = [
            "get-session",
            "list-sessions",
            "record-observation",
            "record-measurement",
            "evaluate-session",
            "recommend-next-test",
            "list-applicable-procedures",
            "start-procedure",
            "record-procedure-step",
            "close-session",
        ];
        let index = methods
            .iter()
            .position(|m| *m == method)
            .ok_or("unknown VW fixture")?
            + 20;
        let mut request: Value =
            serde_json::from_str(include_str!("g3-vw-request.json")).map_err(|e| e.to_string())?;
        request["command_id"] = json!(format!("67000000-0000-4000-8000-{index:012}"));
        request["configuration"]["id"] =
            json!(format!("67000000-0000-4000-8000-{:012}", index + 100));
        let result = call("create-session", json!({"request":request})).await?;
        let session = result["session"]["id"].clone();
        if matches!(method, "start-procedure" | "record-procedure-step") {
            call("close-session", json!({"command":{"session_id":session,"expected_revision":0,"command_id":format!("67000000-0000-4000-8000-{:012}",index+200),"outcome":"Closed fixture rejects further procedure work"}})).await?;
        }
        values.insert("{{fixture.vw_session_id}}".into(), session);
    }
    bindings()
        .lock()
        .map_err(|e| e.to_string())?
        .insert(verb.into(), Value::Object(values));
    Ok(())
}
pub fn resolve_args(verb: &str, args: Value) -> Result<Value, String> {
    if !verb.starts_with("vw-diagnostic-service_") {
        return Ok(args);
    }
    fn walk(value: Value, map: &Value) -> Value {
        match value {
            Value::String(ref text) if map.get(text).is_some() => map[text].clone(),
            Value::Array(items) => Value::Array(items.into_iter().map(|v| walk(v, map)).collect()),
            Value::Object(items) => {
                Value::Object(items.into_iter().map(|(k, v)| (k, walk(v, map))).collect())
            }
            other => other,
        }
    }
    let map = bindings().lock().map_err(|e| e.to_string())?;
    Ok(walk(args, map.get(verb).unwrap_or(&Value::Null)))
}
pub fn verify(
    verb: &str,
    _: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("vw-diagnostic-service_") else {
        return Ok(());
    };
    match method {
        "create-session" | "get-session" | "record-observation" | "record-measurement"
        | "close-session" => {
            let row_id = result["session"]["id"]
                .as_str()
                .ok_or("VW session absent")?
                .parse()
                .map_err(|e| format!("session UUID: {e}"))?;
            if store.get(row_id).map_err(|e| e.to_string())?.is_none() {
                return Err("VW session not persisted".into());
            }
            let field = match method {
                "record-observation" => Some("observations"),
                "record-measurement" => Some("measurements"),
                _ => None,
            };
            if field
                .is_some_and(|field| result["session"][field].as_array().map(Vec::len) != Some(1))
            {
                return Err("evidence command did not append exactly one record".into());
            }
        }
        "start-procedure" | "record-procedure-step" => {
            let id = args["command"]["session_id"]
                .as_str()
                .ok_or("fixture session missing")?
                .parse()
                .map_err(|e| format!("session UUID: {e}"))?;
            if result["ok"] != false || store.get(id).map_err(|e| e.to_string())?.is_none() {
                return Err("closed-session guard did not preserve its record".into());
            }
        }
        "get-photo" if result["_mcp_content"].as_array().map(Vec::len) != Some(1) => {
            return Err("photo image content absent".into());
        }
        "search-photos" if result["hits"].as_array().map(Vec::len) != Some(1) => {
            return Err("owned photo missing from search".into());
        }
        _ => {}
    }
    Ok(())
}
