//! MCP (Model Context Protocol) server for impress-mcp.
//!
//! Implements a JSON-RPC 2.0 server over stdin/stdout exposing semantic search
//! over locally indexed PDF publications.

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

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

fn tool_definitions() -> Value {
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

    let result = match tool_name {
        "search_papers" => tool_search_papers(ctx, args),
        "get_paper_chunks" => tool_get_paper_chunks(ctx, args),
        "list_indexed_papers" => tool_list_indexed_papers(ctx, args),
        _ => Err(format!("Unknown tool: {tool_name}")),
    };

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
    fn test_tool_definitions_valid_json() {
        let tools = tool_definitions();
        assert!(tools.is_array());
        assert_eq!(tools.as_array().unwrap().len(), 3);
    }

    #[test]
    fn test_handle_initialize() {
        let resp = handle_initialize(&json!(1));
        assert_eq!(resp["result"]["serverInfo"]["name"], "impress-mcp");
        assert_eq!(resp["result"]["protocolVersion"], "2024-11-05");
    }

    #[test]
    fn test_tools_list_has_correct_names() {
        let resp = handle_tools_list(&json!(1));
        let tools = resp["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            vec!["search_papers", "get_paper_chunks", "list_indexed_papers"]
        );
    }
}
