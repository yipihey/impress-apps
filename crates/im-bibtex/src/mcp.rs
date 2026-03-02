//! MCP (Model Context Protocol) server for im-bibtex
//!
//! Implements a JSON-RPC 2.0 server over stdin/stdout exposing BibTeX
//! parsing, formatting, and utility functions as MCP tools.

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

use crate::{
    decode_latex, expand_journal_macro, format_complete, format_entry,
    get_all_journal_macro_names, parse, parse_entry,
};

/// Run the MCP server, reading JSON-RPC requests from stdin and writing responses to stdout.
pub fn run_server() -> Result<(), Box<dyn std::error::Error>> {
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
            "tools/call" => handle_tool_call(&id, &request),
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
                "name": "im-bibtex",
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
            "name": "bib_parse",
            "description": "Parse a BibTeX string into structured entries with fields, preambles, and string definitions",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "BibTeX content to parse" }
                },
                "required": ["input"]
            }
        },
        {
            "name": "bib_parse_entry",
            "description": "Parse a single BibTeX entry string into a structured entry",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "Single BibTeX entry to parse" }
                },
                "required": ["input"]
            }
        },
        {
            "name": "bib_format",
            "description": "Parse BibTeX and reformat/normalize it with consistent formatting",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "BibTeX content to format" }
                },
                "required": ["input"]
            }
        },
        {
            "name": "bib_format_entry",
            "description": "Format a single BibTeX entry to a normalized string",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "Single BibTeX entry to format" }
                },
                "required": ["input"]
            }
        },
        {
            "name": "bib_decode_latex",
            "description": "Decode LaTeX commands and accents to Unicode (e.g. Schr\\\"{o}dinger → Schrödinger)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "Text with LaTeX commands to decode" }
                },
                "required": ["input"]
            }
        },
        {
            "name": "bib_expand_journal",
            "description": "Expand a journal abbreviation macro (e.g. \\apj → Astrophysical Journal)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Journal macro name (e.g. apj, mnras, \\apj)" }
                },
                "required": ["name"]
            }
        },
        {
            "name": "bib_list_journals",
            "description": "List all known journal abbreviation macros and their expansions",
            "inputSchema": {
                "type": "object",
                "properties": {}
            }
        },
        {
            "name": "bib_validate",
            "description": "Validate a BibTeX file and report parsing errors and missing fields",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "BibTeX content to validate" }
                },
                "required": ["input"]
            }
        }
    ])
}

fn handle_tool_call(id: &Value, request: &Value) -> Value {
    let tool_name = request["params"]["name"].as_str().unwrap_or("");
    let args = &request["params"]["arguments"];

    let result = match tool_name {
        "bib_parse" => tool_parse(args),
        "bib_parse_entry" => tool_parse_entry(args),
        "bib_format" => tool_format(args),
        "bib_format_entry" => tool_format_entry(args),
        "bib_decode_latex" => tool_decode_latex(args),
        "bib_expand_journal" => tool_expand_journal(args),
        "bib_list_journals" => tool_list_journals(),
        "bib_validate" => tool_validate(args),
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

fn get_string_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("Missing required argument: {key}"))
}

fn tool_parse(args: &Value) -> Result<String, String> {
    let input = get_string_arg(args, "input")?;
    let result = parse(input.to_string()).map_err(|e| e.to_string())?;
    serde_json::to_string_pretty(&result).map_err(|e| e.to_string())
}

fn tool_parse_entry(args: &Value) -> Result<String, String> {
    let input = get_string_arg(args, "input")?;
    let entry = parse_entry(input.to_string()).map_err(|e| e.to_string())?;
    serde_json::to_string_pretty(&entry).map_err(|e| e.to_string())
}

fn tool_format(args: &Value) -> Result<String, String> {
    let input = get_string_arg(args, "input")?;
    let result = parse(input.to_string()).map_err(|e| e.to_string())?;
    let strings: Vec<(String, String)> = result.strings.into_iter().collect();
    Ok(format_complete(&strings, &result.preambles, &result.entries))
}

fn tool_format_entry(args: &Value) -> Result<String, String> {
    let input = get_string_arg(args, "input")?;
    let entry = parse_entry(input.to_string()).map_err(|e| e.to_string())?;
    Ok(format_entry(entry))
}

fn tool_decode_latex(args: &Value) -> Result<String, String> {
    let input = get_string_arg(args, "input")?;
    Ok(decode_latex(input.to_string()))
}

fn tool_expand_journal(args: &Value) -> Result<String, String> {
    let name = get_string_arg(args, "name")?;
    let expanded = expand_journal_macro(name.to_string());
    if expanded == name {
        Err(format!("Unknown journal macro: {name}"))
    } else {
        Ok(expanded)
    }
}

fn tool_list_journals() -> Result<String, String> {
    let mut names = get_all_journal_macro_names();
    names.sort();
    let entries: Vec<Value> = names
        .iter()
        .map(|name| {
            json!({
                "macro": name,
                "expansion": expand_journal_macro(name.clone())
            })
        })
        .collect();
    serde_json::to_string_pretty(&entries).map_err(|e| e.to_string())
}

fn tool_validate(args: &Value) -> Result<String, String> {
    let input = get_string_arg(args, "input")?;
    let result = parse(input.to_string()).map_err(|e| e.to_string())?;

    let mut report = Vec::new();

    if result.errors.is_empty() {
        report.push(format!(
            "OK: {} entries parsed, {} string definitions",
            result.entries.len(),
            result.strings.len()
        ));
    } else {
        for err in &result.errors {
            report.push(format!("Error at line {}: {}", err.line, err.message));
        }
    }

    // Check for missing fields
    for entry in &result.entries {
        if entry.title().is_none() {
            report.push(format!("Warning: {} missing title", entry.cite_key));
        }
        if entry.author().is_none() {
            report.push(format!("Warning: {} missing author", entry.cite_key));
        }
    }

    Ok(report.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tool_definitions_valid_json() {
        let tools = tool_definitions();
        assert!(tools.is_array());
        assert_eq!(tools.as_array().unwrap().len(), 8);
    }

    #[test]
    fn test_tool_parse() {
        let args = json!({ "input": "@article{k, title={Test}}" });
        let result = tool_parse(&args).unwrap();
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["entries"][0]["cite_key"], "k");
    }

    #[test]
    fn test_tool_decode_latex() {
        let args = json!({ "input": r#"Schr\"{o}dinger"# });
        let result = tool_decode_latex(&args).unwrap();
        assert_eq!(result, "Schrödinger");
    }

    #[test]
    fn test_tool_validate_ok() {
        let args = json!({ "input": "@article{k, title={Test}, author={Smith}}" });
        let result = tool_validate(&args).unwrap();
        assert!(result.contains("OK"));
    }

    #[test]
    fn test_handle_initialize() {
        let resp = handle_initialize(&json!(1));
        assert_eq!(resp["result"]["serverInfo"]["name"], "im-bibtex");
    }
}
