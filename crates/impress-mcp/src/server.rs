//! MCP (Model Context Protocol) server for impress-mcp.
//!
//! Implements a JSON-RPC 2.0 server over stdin/stdout exposing semantic search
//! over locally indexed PDF publications.

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

use crate::inventory_bridge::{call_inventory_tool, inventory_tool_definitions, is_inventory_tool};
use crate::tools::{
    tool_get_paper_chunks, tool_list_indexed_papers, tool_search_papers, ToolContext,
};

/// Run the MCP server, reading JSON-RPC requests from stdin and writing responses to stdout.
pub fn run_server(ctx: ToolContext) -> Result<(), Box<dyn std::error::Error>> {
    let stdin = io::stdin();
    let stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let request: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => {
                let response = json!({
                    "jsonrpc": "2.0",
                    "id": null,
                    "error": { "code": -32700, "message": "Parse error" }
                });
                writeln!(stdout.lock(), "{}", response)?;
                stdout.lock().flush()?;
                continue;
            }
        };

        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request["method"].as_str().unwrap_or("");

        let response = match method {
            "initialize" => handle_initialize(&id),
            "notifications/initialized" | "notifications/cancelled" => continue,
            "tools/list" => handle_tools_list(&id),
            "tools/call" => handle_tool_call(&ctx, &id, &request),
            _ => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("Method not found: {}", method) }
            }),
        };

        writeln!(stdout.lock(), "{}", response)?;
        stdout.lock().flush()?;
    }

    Ok(())
}

fn handle_initialize(id: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": { "tools": {} },
            "serverInfo": {
                "name": "impress-mcp",
                "version": env!("CARGO_PKG_VERSION")
            }
        }
    })
}

fn handle_tools_list(id: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": { "tools": tool_definitions() }
    })
}

/// Build the combined `tools/list` payload: legacy hand-written tools
/// (semantic search over indexed PDFs) followed by every tool
/// auto-registered via the `#[impress_service]` codegen pipeline.
fn tool_definitions() -> Value {
    let mut tools: Vec<Value> = match legacy_tool_definitions() {
        Value::Array(items) => items,
        other => vec![other],
    };
    tools.extend(inventory_tool_definitions());
    Value::Array(tools)
}

fn legacy_tool_definitions() -> Value {
    json!([
        {
            "name": "search_papers",
            "description": "Semantic search across all indexed PDFs in the local library. Finds relevant passages by meaning, not just keywords. Returns publications with matching text excerpts, page numbers, and similarity scores.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural language search query (e.g. 'stellar feedback mechanisms', 'dark matter halo profiles')"
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Maximum number of publications to return (default: 10)",
                        "default": 10
                    }
                },
                "required": ["query"]
            }
        },
        {
            "name": "get_paper_chunks",
            "description": "Get all text chunks for a specific publication. Use this for full-context RAG after finding a paper via search_papers. Chunks are ordered by position in the document.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "publication_id": {
                        "type": "string",
                        "description": "Publication UUID (from search_papers results)"
                    }
                },
                "required": ["publication_id"]
            }
        },
        {
            "name": "list_indexed_papers",
            "description": "List all publications that have been chunk-indexed for semantic search. Shows title, authors, year, and chunk count for each paper.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of publications to return (default: 50)",
                        "default": 50
                    }
                }
            }
        }
    ])
}

fn handle_tool_call(ctx: &ToolContext, id: &Value, request: &Value) -> Value {
    let tool_name = request["params"]["name"].as_str().unwrap_or("");
    let args = &request["params"]["arguments"];

    // Try legacy hand-written tools first.
    let legacy_result: Option<Result<String, String>> = match tool_name {
        "search_papers" => Some(tool_search_papers(ctx, args)),
        "get_paper_chunks" => Some(tool_get_paper_chunks(ctx, args)),
        "list_indexed_papers" => Some(tool_list_indexed_papers(ctx, args)),
        _ => None,
    };

    if let Some(result) = legacy_result {
        return wrap_text_result(id, result);
    }

    // Fall through to the inventory of `#[impress_service]`-generated tools.
    if is_inventory_tool(tool_name) {
        let owned_args = if args.is_null() {
            // MCP clients may omit `arguments` entirely. The inventory
            // deserializer expects an object; default to {} so methods
            // with all-optional args work.
            json!({})
        } else {
            args.clone()
        };
        match call_inventory_tool(tool_name, owned_args) {
            Ok(value) => {
                // Convention: stringify the JSON result so it survives
                // the MCP `content` channel intact. Clients can re-parse.
                let text = match &value {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                return json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "content": [{ "type": "text", "text": text }],
                        "structuredContent": value,
                    }
                });
            }
            Err(e) => return wrap_text_result(id, Err(e)),
        }
    }

    wrap_text_result(id, Err(format!("Unknown tool: {tool_name}")))
}

fn wrap_text_result(id: &Value, result: Result<String, String>) -> Value {
    match result {
        Ok(text) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "content": [{ "type": "text", "text": text }]
            }
        }),
        Err(e) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "content": [{ "type": "text", "text": e }],
                "isError": true
            }
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_legacy_tool_definitions_count() {
        // The three hand-written semantic-search tools always exist.
        let tools = legacy_tool_definitions();
        assert!(tools.is_array());
        assert_eq!(tools.as_array().unwrap().len(), 3);
    }

    #[test]
    fn test_tool_definitions_includes_legacy_and_inventory() {
        // Combined list is legacy (3) + every `#[impress_service]` method.
        // imbib-service contributes 5 ImbibTextService methods at minimum.
        let tools = tool_definitions();
        let arr = tools.as_array().expect("tools is array");
        assert!(
            arr.len() >= 3 + 5,
            "expected legacy + inventory tools; got {}",
            arr.len()
        );
        let names: Vec<&str> = arr.iter().map(|t| t["name"].as_str().unwrap()).collect();
        for legacy in ["search_papers", "get_paper_chunks", "list_indexed_papers"] {
            assert!(names.contains(&legacy), "missing legacy {legacy}");
        }
        for inventory in [
            "imbib-text-service_decode-latex",
            "imbib-text-service_expand-journal-macro",
            "imbib-text-service_generate-cite-key",
            "imbib-text-service_normalize-tag-segment",
            "imbib-text-service_normalize-tag-path",
        ] {
            assert!(names.contains(&inventory), "missing inventory {inventory}");
        }
    }

    #[test]
    fn test_handle_initialize() {
        let resp = handle_initialize(&json!(1));
        assert_eq!(resp["result"]["serverInfo"]["name"], "impress-mcp");
        assert_eq!(resp["result"]["protocolVersion"], "2024-11-05");
    }

    #[test]
    fn test_tools_list_keeps_legacy_names_at_front() {
        let resp = handle_tools_list(&json!(1));
        let tools = resp["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            &names[..3],
            &["search_papers", "get_paper_chunks", "list_indexed_papers"]
        );
    }

    #[test]
    fn test_handle_tool_call_dispatches_inventory_tool() {
        // We can exercise the inventory branch without touching the
        // (mandatory) ToolContext by going through `handle_tool_call`
        // with a stub: the legacy tools won't be invoked because the
        // name routes into the inventory match. Pass a deliberately
        // empty ToolContext-equivalent by constructing the request and
        // bypassing the legacy arm — but `handle_tool_call` takes
        // `&ToolContext` by reference, so we can't avoid creating one
        // here. Instead, drive the inventory bridge directly.
        use crate::inventory_bridge::call_inventory_tool;
        let out = call_inventory_tool(
            "imbib-text-service_decode-latex",
            json!({ "input": "Caf\\'{e}" }),
        )
        .expect("inventory tool returns Ok");
        assert_eq!(out.as_str(), Some("Café"));
    }
}
