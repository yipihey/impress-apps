//! Small, product-neutral MCP host over the generated Impress service inventory.
//!
//! Product binaries choose which service crates to link and which tool-name
//! prefixes to expose. The host owns JSON-RPC/MCP mechanics only.

use std::io::{BufRead, Write};
use std::net::SocketAddr;
use std::sync::Arc;

use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use impress_service_core::McpToolDescriptor;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resource {
    pub uri: String,
    pub name: String,
    pub description: String,
    pub mime_type: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostConfig {
    pub server_name: String,
    pub server_version: String,
    pub instructions: String,
    /// A descriptor is exposed when its name starts with one of these. Empty
    /// means expose the full linked inventory.
    pub allowed_tool_prefixes: Vec<String>,
    pub resources: Vec<Resource>,
}

impl HostConfig {
    pub fn allows(&self, name: &str) -> bool {
        self.allowed_tool_prefixes.is_empty()
            || self
                .allowed_tool_prefixes
                .iter()
                .any(|prefix| name.starts_with(prefix))
    }
}

pub fn run_stdio(config: HostConfig) -> Result<(), Box<dyn std::error::Error>> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                writeln!(
                    stdout,
                    "{}",
                    json_rpc_error(Value::Null, -32700, format!("Parse error: {error}"))
                )?;
                stdout.flush()?;
                continue;
            }
        };
        if let Some(response) = dispatch_message(&config, &request) {
            writeln!(stdout, "{response}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

/// Triage one parsed top-level message for either transport. Returns the
/// single response to send, or `None` for a notification (a message without
/// an `id` — JSON-RPC 2.0 forbids replying to those, and clients do send
/// them: Claude Code emits `notifications/roots/list_changed`).
///
/// A top-level array is a JSON-RPC batch, which this host does not implement
/// — the reason it pins protocolVersion 2024-11-05 rather than 2025-03-26,
/// whose batch support is mandatory. Dropping a batch silently left the
/// client waiting forever; refuse it loudly instead, with the null id
/// JSON-RPC prescribes when no single request id can be extracted.
fn dispatch_message(config: &HostConfig, request: &Value) -> Option<Value> {
    if request.is_array() {
        return Some(json_rpc_error(
            Value::Null,
            -32600,
            "JSON-RPC batch requests are not supported".into(),
        ));
    }
    request.get("id")?;
    Some(handle_request(config, request))
}

/// Run the same focused MCP surface as a stateless Streamable HTTP endpoint.
///
/// Authentication is intentionally owned by the transport rather than domain
/// services. The caller supplies a high-entropy bearer token and may safely
/// place this endpoint behind a public HTTPS reverse proxy.
pub fn run_http(
    config: HostConfig,
    bind: &str,
    bearer_token: String,
) -> Result<(), Box<dyn std::error::Error>> {
    if bearer_token.trim().is_empty() {
        return Err("the MCP HTTP bearer token must not be empty".into());
    }
    let address: SocketAddr = bind.parse()?;
    let state = HttpState {
        config: Arc::new(config),
        bearer_token: Arc::from(bearer_token),
    };
    impress_service_core::runtime::block_on(async move {
        let app = Router::new()
            // Serving both paths makes the host work directly and behind a
            // reverse proxy that strips its configured path prefix.
            .route("/", post(http_mcp))
            .route("/mcp", post(http_mcp))
            .route("/healthz", get(http_health))
            .with_state(state);
        let listener = tokio::net::TcpListener::bind(address).await?;
        eprintln!("impress-mcp-host: listening on http://{address}/mcp");
        axum::serve(listener, app).await?;
        Ok::<(), Box<dyn std::error::Error>>(())
    })
}

#[derive(Clone)]
struct HttpState {
    config: Arc<HostConfig>,
    bearer_token: Arc<str>,
}

async fn http_health() -> impl IntoResponse {
    Json(json!({ "service": "impress-mcp", "status": "ok" }))
}

async fn http_mcp(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Json(request): Json<Value>,
) -> Response {
    if !has_bearer_token(&headers, &state.bearer_token) {
        return (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"))],
            Json(json!({ "error": "unauthorized" })),
        )
            .into_response();
    }
    let config = state.config.clone();
    // Same triage as stdio (`dispatch_message`): a batch gets its one error
    // response, a notification gets the bodiless 202 Streamable HTTP
    // prescribes, everything else is handled.
    match tokio::task::spawn_blocking(move || dispatch_message(&config, &request)).await {
        Ok(Some(response)) => (StatusCode::OK, Json(response)).into_response(),
        Ok(None) => StatusCode::ACCEPTED.into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("MCP request task failed: {error}") })),
        )
            .into_response(),
    }
}

fn has_bearer_token(headers: &HeaderMap, expected: &str) -> bool {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|value| value == expected)
}

pub fn handle_request(config: &HostConfig, request: &Value) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    match request.get("method").and_then(Value::as_str).unwrap_or("") {
        "initialize" => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                // 2024-11-05, like impress-mcp's stdio server: the 2025-03-26
                // revision makes JSON-RPC batching mandatory, and this host
                // refuses batches (see `dispatch_message`), so claiming it
                // would advertise support that is not there.
                "protocolVersion": "2024-11-05",
                "capabilities": { "tools": {}, "resources": {} },
                "serverInfo": {
                    "name": config.server_name,
                    "version": config.server_version,
                },
                "instructions": config.instructions,
            }
        }),
        "ping" => success(id, json!({})),
        "tools/list" => success(id, json!({ "tools": tool_definitions(config) })),
        "tools/call" => handle_tool_call(config, id, request),
        "resources/list" => success(
            id,
            json!({
                "resources": config.resources.iter().map(|resource| json!({
                    "uri": resource.uri,
                    "name": resource.name,
                    "description": resource.description,
                    "mimeType": resource.mime_type,
                })).collect::<Vec<_>>()
            }),
        ),
        "resources/read" => handle_resource_read(config, id, request),
        method => json_rpc_error(id, -32601, format!("Method not found: {method}")),
    }
}

pub fn tool_definitions(config: &HostConfig) -> Vec<Value> {
    let mut descriptors: Vec<_> = McpToolDescriptor::iter()
        .filter(|descriptor| config.allows(descriptor.name))
        .collect();
    descriptors.sort_by_key(|descriptor| descriptor.name);
    descriptors
        .into_iter()
        .map(|descriptor| {
            json!({
                "name": descriptor.name,
                "description": descriptor.description,
                "inputSchema": (descriptor.input_schema)(),
            })
        })
        .collect()
}

fn handle_tool_call(config: &HostConfig, id: Value, request: &Value) -> Value {
    let Some(name) = request
        .pointer("/params/name")
        .and_then(serde_json::Value::as_str)
    else {
        return json_rpc_error(id, -32602, "params.name is required".into());
    };
    if !config.allows(name) {
        return tool_result(
            id,
            Err(format!("Tool is not exposed by this profile: {name}")),
        );
    }
    let Some(descriptor) = McpToolDescriptor::iter().find(|descriptor| descriptor.name == name)
    else {
        return tool_result(id, Err(format!("Unknown tool: {name}")));
    };
    // MCP clients may omit `arguments` entirely or send an explicit null;
    // the generated deserializers expect an object, so both become `{}` and
    // zero-argument tools work either way — the same coercion impress-mcp's
    // stdio server applies.
    let arguments = match request.pointer("/params/arguments") {
        Some(value) if !value.is_null() => value.clone(),
        _ => json!({}),
    };
    let result = impress_service_core::runtime::block_on((descriptor.handler)(arguments))
        .map_err(|error| error.to_string());
    tool_result(id, result)
}

fn handle_resource_read(config: &HostConfig, id: Value, request: &Value) -> Value {
    let Some(uri) = request
        .pointer("/params/uri")
        .and_then(serde_json::Value::as_str)
    else {
        return json_rpc_error(id, -32602, "params.uri is required".into());
    };
    let Some(resource) = config.resources.iter().find(|resource| resource.uri == uri) else {
        return json_rpc_error(id, -32002, format!("Resource not found: {uri}"));
    };
    success(
        id,
        json!({
            "contents": [{
                "uri": resource.uri,
                "mimeType": resource.mime_type,
                "text": resource.text,
            }]
        }),
    )
}

fn tool_result(id: Value, result: Result<Value, String>) -> Value {
    match result {
        Ok(value) => {
            let (mut content, raw) = impress_service_core::split_mcp_content(value);
            // The human-readable text block keeps the RAW pre-envelope shape
            // (a bare string stays bare, everything else compact JSON) — the
            // rule impress-mcp's stdio server applies, and compact because a
            // pretty print duplicates structuredContent at a 30-80% token
            // premium on every result.
            let text = match &raw {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            };
            // MCP requires `structuredContent` to be an object; generated
            // handlers may return arrays, scalars or null (Vec<T>, counts,
            // Option<T> misses), so envelope at the transport like
            // impress-mcp's stdio server does.
            let structured = impress_service_core::envelope_structured_content(raw);
            content.push(json!({ "type": "text", "text": text }));
            let is_error = structured
                .get("ok")
                .and_then(Value::as_bool)
                .is_some_and(|ok| !ok);
            success(
                id,
                json!({
                    "content": content,
                    "structuredContent": structured,
                    "isError": is_error,
                }),
            )
        }
        Err(message) => success(
            id,
            json!({
                "content": [{ "type": "text", "text": message }],
                "isError": true,
            }),
        ),
    }
}

fn success(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn json_rpc_error(id: Value, code: i64, message: String) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // A test-only inventory entry: this crate deliberately links no service
    // crates, so give `tools/call` something real to dispatch to.
    impress_service_core::inventory::submit! {
        McpToolDescriptor {
            name: "allowed-fixture_echo-arguments",
            description: "Test fixture: echoes the argument object it was handed.",
            input_schema: fixture_schema,
            handler: fixture_echo,
        }
    }

    fn fixture_schema() -> Value {
        json!({ "type": "object" })
    }

    fn fixture_echo(arguments: Value) -> impress_service_core::ServiceFuture {
        Box::pin(async move { Ok(json!({ "ok": true, "arguments": arguments })) })
    }

    fn config() -> HostConfig {
        HostConfig {
            server_name: "test".into(),
            server_version: "1".into(),
            instructions: "test host".into(),
            allowed_tool_prefixes: vec!["allowed-".into()],
            resources: vec![Resource {
                uri: "impress://test/guide".into(),
                name: "Guide".into(),
                description: "Test".into(),
                mime_type: "text/plain".into(),
                text: "hello".into(),
            }],
        }
    }

    #[test]
    fn profile_prefix_is_an_allowlist() {
        let config = config();
        assert!(config.allows("allowed-tool_call"));
        assert!(!config.allows("raw-store_delete"));
    }

    #[test]
    fn initializes_and_reads_profile_resource() {
        let init = handle_request(
            &config(),
            &json!({"jsonrpc":"2.0","id":1,"method":"initialize"}),
        );
        assert_eq!(init["result"]["serverInfo"]["name"], "test");
        // Pinned to impress-mcp's revision: 2025-03-26 makes batching
        // mandatory and this host refuses batches.
        assert_eq!(init["result"]["protocolVersion"], "2024-11-05");
        let read = handle_request(
            &config(),
            &json!({
                "jsonrpc":"2.0",
                "id":2,
                "method":"resources/read",
                "params":{"uri":"impress://test/guide"}
            }),
        );
        assert_eq!(read["result"]["contents"][0]["text"], "hello");
    }

    #[test]
    fn profile_refuses_non_allowlisted_tools_before_lookup() {
        let response = handle_request(
            &config(),
            &json!({
                "jsonrpc":"2.0",
                "id":3,
                "method":"tools/call",
                "params":{"name":"store-query-service_list-items","arguments":{}}
            }),
        );
        assert_eq!(response["result"]["isError"], true);
    }

    #[test]
    fn http_bearer_auth_is_exact() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer secret"),
        );
        assert!(has_bearer_token(&headers, "secret"));
        assert!(!has_bearer_token(&headers, "other"));
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Basic secret"),
        );
        assert!(!has_bearer_token(&headers, "secret"));
    }

    /// A JSON-RPC batch used to be dropped without a byte of output (stdio)
    /// or with a bare 202 (HTTP), leaving the client waiting forever. Both
    /// transports triage through `dispatch_message`, so this covers both.
    #[test]
    fn batches_get_one_invalid_request_error_instead_of_silence() {
        let batch = json!([
            {"jsonrpc":"2.0","id":1,"method":"ping"},
            {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        ]);
        let response =
            dispatch_message(&config(), &batch).expect("a batch is answered, not dropped");
        assert_eq!(response["id"], Value::Null);
        assert_eq!(response["error"]["code"], -32600);
        assert_eq!(
            response["error"]["message"],
            "JSON-RPC batch requests are not supported"
        );
    }

    /// JSON-RPC 2.0 forbids replying to notifications (id-less messages).
    #[test]
    fn notifications_get_no_reply() {
        let notification = json!({"jsonrpc":"2.0","method":"notifications/roots/list_changed"});
        assert_eq!(dispatch_message(&config(), &notification), None);
    }

    /// An explicit `"arguments": null` must reach the generated deserializer
    /// as `{}`, exactly like an omitted `arguments` — `Some(Null)` fails
    /// serde deserialization even for zero-argument tools.
    #[test]
    fn explicit_null_arguments_reach_the_handler_as_an_empty_object() {
        for params in [
            json!({"name": "allowed-fixture_echo-arguments", "arguments": null}),
            json!({"name": "allowed-fixture_echo-arguments"}),
        ] {
            let response = handle_request(
                &config(),
                &json!({"jsonrpc":"2.0","id":7,"method":"tools/call","params": params}),
            );
            assert_eq!(response["result"]["isError"], false, "{response}");
            assert_eq!(
                response["result"]["structuredContent"]["arguments"],
                json!({}),
                "arguments must arrive as an object: {response}"
            );
        }
    }

    /// The text block derives from the RAW pre-envelope value — bare strings
    /// stay bare, everything else compact — matching impress-mcp's stdio
    /// server instead of pretty-reprinting `structuredContent`.
    #[test]
    fn text_block_is_the_raw_value_not_a_pretty_reprint() {
        let response = tool_result(json!(9), Ok(json!("Café")));
        assert_eq!(response["result"]["content"][0]["text"], "Café");
        assert_eq!(
            response["result"]["structuredContent"],
            json!({"value": "Café"})
        );

        let response = tool_result(json!(9), Ok(json!(["a", "b"])));
        assert_eq!(response["result"]["content"][0]["text"], r#"["a","b"]"#);

        let response = tool_result(json!(9), Ok(json!({"ok": false, "message": "m"})));
        let text = response["result"]["content"][0]["text"].as_str().unwrap();
        assert!(!text.contains('\n'), "text must be compact: {text:?}");
        assert_eq!(
            serde_json::from_str::<Value>(text).unwrap(),
            json!({"ok": false, "message": "m"})
        );
        // `isError` keeps reading the post-envelope structured value.
        assert_eq!(response["result"]["isError"], true);
    }

    #[test]
    fn non_object_results_are_enveloped_into_objects() {
        // MCP clients reject a structuredContent that is not an object;
        // Vec<T>-, Option<T>- and scalar-returning generated handlers produce
        // exactly those shapes, so the transport envelopes them.
        for (raw, expected) in [
            (json!(["a", "b"]), json!({"items": ["a", "b"]})),
            (json!(null), json!({"item": null})),
            (json!(3), json!({"value": 3})),
        ] {
            let response = tool_result(json!(9), Ok(raw));
            assert_eq!(response["result"]["structuredContent"], expected);
            assert_eq!(response["result"]["isError"], false);
        }
    }

    #[test]
    fn native_image_content_is_split_from_structured_result() {
        let response = tool_result(
            json!(9),
            Ok(json!({
                "ok": true,
                "status": "resolved",
                "_mcp_content": [{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}]
            })),
        );
        assert_eq!(response["result"]["content"][0]["type"], "image");
        assert_eq!(response["result"]["content"][0]["mimeType"], "image/png");
        assert_eq!(
            response["result"]["structuredContent"]["status"],
            "resolved"
        );
        assert!(response["result"]["structuredContent"]
            .get("_mcp_content")
            .is_none());
    }
}
