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
        if request.get("id").is_none() {
            continue;
        }
        let response = handle_request(&config, &request);
        writeln!(stdout, "{response}")?;
        stdout.flush()?;
    }
    Ok(())
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
    if request.get("id").is_none() {
        return StatusCode::ACCEPTED.into_response();
    }
    let config = state.config.clone();
    match tokio::task::spawn_blocking(move || handle_request(&config, &request)).await {
        Ok(response) => (StatusCode::OK, Json(response)).into_response(),
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
                "protocolVersion": "2025-03-26",
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
    let arguments = request
        .pointer("/params/arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let result = impress_service_core::runtime::block_on((descriptor.handler)(arguments))
        .map_err(|error| error.to_string())
        .and_then(|value| serde_json::to_string_pretty(&value).map_err(|error| error.to_string()));
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

fn tool_result(id: Value, result: Result<String, String>) -> Value {
    match result {
        Ok(text) => success(
            id,
            json!({
                "content": [{ "type": "text", "text": text }],
                "isError": false,
            }),
        ),
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
}
