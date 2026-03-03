//! MCP (Model Context Protocol) server for im-identifiers
//!
//! Implements a JSON-RPC 2.0 server over stdin/stdout exposing identifier
//! extraction, validation, normalization, cite key generation, and resolution.

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

use crate::{
    extract_all, extract_arxiv_ids, extract_dois, extract_isbns, generate_cite_key,
    generate_unique_cite_key, identifier_url, is_valid_arxiv_id, is_valid_doi, is_valid_isbn,
    normalize_doi, sanitize_cite_key, IdentifierType,
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
                "name": "im-identifiers",
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
            "name": "id_extract_all",
            "description": "Extract all academic identifiers (DOI, arXiv, ISBN) from text with position information",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "Text to extract identifiers from" }
                },
                "required": ["text"]
            }
        },
        {
            "name": "id_extract_dois",
            "description": "Extract DOIs from text",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "Text to extract DOIs from" }
                },
                "required": ["text"]
            }
        },
        {
            "name": "id_extract_arxiv",
            "description": "Extract arXiv IDs from text (both old and new formats)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "Text to extract arXiv IDs from" }
                },
                "required": ["text"]
            }
        },
        {
            "name": "id_extract_isbns",
            "description": "Extract ISBNs from text (ISBN-10 and ISBN-13 with checksum validation)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": { "type": "string", "description": "Text to extract ISBNs from" }
                },
                "required": ["text"]
            }
        },
        {
            "name": "id_validate",
            "description": "Validate an identifier (DOI, arXiv ID, or ISBN)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": "Identifier type: doi, arxiv, isbn",
                        "enum": ["doi", "arxiv", "isbn"]
                    },
                    "value": { "type": "string", "description": "The identifier value to validate" }
                },
                "required": ["type", "value"]
            }
        },
        {
            "name": "id_normalize_doi",
            "description": "Normalize a DOI by stripping URL prefixes and trailing punctuation",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "doi": { "type": "string", "description": "DOI to normalize (may include URL prefix)" }
                },
                "required": ["doi"]
            }
        },
        {
            "name": "id_generate_cite_key",
            "description": "Generate a BibTeX citation key from author, year, and title metadata",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "author": { "type": "string", "description": "Author name(s)" },
                    "year": { "type": "string", "description": "Publication year" },
                    "title": { "type": "string", "description": "Paper title" },
                    "existing_keys": {
                        "type": "array",
                        "items": { "type": "string" },
                        "description": "Existing keys to avoid collisions with"
                    }
                }
            }
        },
        {
            "name": "id_identifier_url",
            "description": "Get the canonical URL for an identifier",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": "Identifier type: doi, arxiv, pmid, pmcid, bibcode, semanticscholar, openalex, dblp"
                    },
                    "value": { "type": "string", "description": "The identifier value" }
                },
                "required": ["type", "value"]
            }
        },
        {
            "name": "id_sanitize_cite_key",
            "description": "Sanitize a citation key by removing invalid BibTeX characters",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": { "type": "string", "description": "Citation key to sanitize" }
                },
                "required": ["key"]
            }
        }
    ])
}

fn handle_tool_call(id: &Value, request: &Value) -> Value {
    let tool_name = request["params"]["name"].as_str().unwrap_or("");
    let args = &request["params"]["arguments"];

    let result = match tool_name {
        "id_extract_all" => tool_extract_all(args),
        "id_extract_dois" => tool_extract_dois(args),
        "id_extract_arxiv" => tool_extract_arxiv(args),
        "id_extract_isbns" => tool_extract_isbns(args),
        "id_validate" => tool_validate(args),
        "id_normalize_doi" => tool_normalize_doi(args),
        "id_generate_cite_key" => tool_generate_cite_key(args),
        "id_identifier_url" => tool_identifier_url(args),
        "id_sanitize_cite_key" => tool_sanitize_cite_key(args),
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

fn tool_extract_all(args: &Value) -> Result<String, String> {
    let text = get_string_arg(args, "text")?;
    let ids = extract_all(text.to_string());
    serde_json::to_string_pretty(&ids).map_err(|e| e.to_string())
}

fn tool_extract_dois(args: &Value) -> Result<String, String> {
    let text = get_string_arg(args, "text")?;
    let dois = extract_dois(text.to_string());
    serde_json::to_string_pretty(&dois).map_err(|e| e.to_string())
}

fn tool_extract_arxiv(args: &Value) -> Result<String, String> {
    let text = get_string_arg(args, "text")?;
    let ids = extract_arxiv_ids(text.to_string());
    serde_json::to_string_pretty(&ids).map_err(|e| e.to_string())
}

fn tool_extract_isbns(args: &Value) -> Result<String, String> {
    let text = get_string_arg(args, "text")?;
    let isbns = extract_isbns(text.to_string());
    serde_json::to_string_pretty(&isbns).map_err(|e| e.to_string())
}

fn tool_validate(args: &Value) -> Result<String, String> {
    let id_type = get_string_arg(args, "type")?;
    let value = get_string_arg(args, "value")?;

    let valid = match id_type {
        "doi" => is_valid_doi(value.to_string()),
        "arxiv" => is_valid_arxiv_id(value.to_string()),
        "isbn" => is_valid_isbn(value.to_string()),
        other => return Err(format!("Unknown identifier type: {other}. Supported: doi, arxiv, isbn")),
    };

    Ok(json!({ "valid": valid, "type": id_type, "value": value }).to_string())
}

fn tool_normalize_doi(args: &Value) -> Result<String, String> {
    let doi = get_string_arg(args, "doi")?;
    Ok(normalize_doi(doi.to_string()))
}

fn tool_generate_cite_key(args: &Value) -> Result<String, String> {
    let author = args.get("author").and_then(|v| v.as_str()).map(String::from);
    let year = args.get("year").and_then(|v| v.as_str()).map(String::from);
    let title = args.get("title").and_then(|v| v.as_str()).map(String::from);

    if let Some(existing) = args.get("existing_keys").and_then(|v| v.as_array()) {
        let existing_keys: Vec<String> = existing
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect();
        Ok(generate_unique_cite_key(author, year, title, existing_keys))
    } else {
        Ok(generate_cite_key(author, year, title))
    }
}

fn tool_identifier_url(args: &Value) -> Result<String, String> {
    let id_type_str = get_string_arg(args, "type")?;
    let value = get_string_arg(args, "value")?;

    let id_type = parse_identifier_type(id_type_str)?;
    identifier_url(id_type, value.to_string())
        .ok_or_else(|| format!("Cannot construct URL for identifier type: {id_type_str}"))
}

fn tool_sanitize_cite_key(args: &Value) -> Result<String, String> {
    let key = get_string_arg(args, "key")?;
    Ok(sanitize_cite_key(key.to_string()))
}

fn parse_identifier_type(s: &str) -> Result<IdentifierType, String> {
    match s.to_lowercase().as_str() {
        "doi" => Ok(IdentifierType::Doi),
        "arxiv" => Ok(IdentifierType::Arxiv),
        "pmid" => Ok(IdentifierType::Pmid),
        "pmcid" => Ok(IdentifierType::Pmcid),
        "bibcode" => Ok(IdentifierType::Bibcode),
        "semanticscholar" | "s2" => Ok(IdentifierType::SemanticScholar),
        "openalex" => Ok(IdentifierType::OpenAlex),
        "dblp" => Ok(IdentifierType::Dblp),
        other => Err(format!(
            "Unknown identifier type: {other}. Supported: doi, arxiv, pmid, pmcid, bibcode, semanticscholar, openalex, dblp"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tool_definitions_valid_json() {
        let tools = tool_definitions();
        assert!(tools.is_array());
        assert_eq!(tools.as_array().unwrap().len(), 9);
    }

    #[test]
    fn test_tool_extract_all() {
        let args = json!({ "text": "DOI: 10.1038/nature12373 and arXiv:2301.12345" });
        let result = tool_extract_all(&args).unwrap();
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed.as_array().unwrap().len(), 2);
    }

    #[test]
    fn test_tool_validate_doi() {
        let args = json!({ "type": "doi", "value": "10.1038/nature12373" });
        let result = tool_validate(&args).unwrap();
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["valid"], true);
    }

    #[test]
    fn test_tool_normalize_doi() {
        let args = json!({ "doi": "https://doi.org/10.1038/nature12373" });
        let result = tool_normalize_doi(&args).unwrap();
        assert_eq!(result, "10.1038/nature12373");
    }

    #[test]
    fn test_tool_generate_cite_key() {
        let args = json!({ "author": "Einstein, Albert", "year": "1905", "title": "On the Electrodynamics" });
        let result = tool_generate_cite_key(&args).unwrap();
        assert_eq!(result, "Einstein1905Electrodynamics");
    }

    #[test]
    fn test_tool_identifier_url() {
        let args = json!({ "type": "doi", "value": "10.1038/nature12373" });
        let result = tool_identifier_url(&args).unwrap();
        assert_eq!(result, "https://doi.org/10.1038/nature12373");
    }

    #[test]
    fn test_handle_initialize() {
        let resp = handle_initialize(&json!(1));
        assert_eq!(resp["result"]["serverInfo"]["name"], "im-identifiers");
    }
}
