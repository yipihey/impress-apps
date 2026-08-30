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
// Trait import needed for method-call syntax on `DefaultMemoryService` in
// `memory_brief_markdown` below — same requirement the codegen macro itself
// has (`impress-service-macros`' expansion comment: "Requires the trait to
// be in scope at the macro call site").
use impress_memory_service::MemoryService;

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
            "resources/list" => handle_resources_list(&id),
            "resources/read" => handle_resources_read(&id, &request),
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
            "capabilities": { "tools": {}, "resources": {} },
            "serverInfo": {
                "name": "impress-mcp",
                "version": env!("CARGO_PKG_VERSION")
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

/// The orientation document a fresh agent should read first.
///
/// Without it, an agent connecting to this server sees ~130 tool names and no
/// map: nothing says what impress is, that the apps share one store, which of
/// the overlapping search tools to reach for, or that mutations are
/// asynchronous. Ported from the TypeScript server during its retirement; tool
/// names inside were repointed at their generated Rust equivalents.
const GUIDE_URI: &str = "impress://guide";
const GUIDE_MARKDOWN: &str = include_str!("guide.md");

/// Store-browse resources (ADR-0022 WP G6).
///
/// A tool answers a question the agent already knew to ask. These answer the
/// question it cannot ask yet: *what is in this store?* Both are live reads
/// over the same `impress.sqlite` the tools mutate — `--store-path` included,
/// because `main.rs` hands that path to `impress-store-service` before the
/// first dispatch, and these go through the same lazily-opened handle.
const STORE_SCHEMAS_URI: &str = "impress://store/schemas";
const STORE_COLLECTIONS_URI: &str = "impress://store/collections";

/// Suite memory briefing (ADR-0028 P7).
///
/// `memory-service_memory-brief` is a tool call; an agent that wants the same
/// digest at the start of a session without spending a round trip on it can
/// read this resource instead. Served through the identical code path — a
/// fresh `DefaultMemoryService` over the shared store, see
/// `memory_brief_markdown` — so the two can never drift apart.
const MEMORY_BRIEF_URI: &str = "impress://memory/brief";

/// Every resource URI a client can read, in listing order. Public so the
/// end-to-end smoke test can assert the shipped binary lists exactly these.
pub const RESOURCE_URIS: [&str; 4] = [
    GUIDE_URI,
    STORE_SCHEMAS_URI,
    STORE_COLLECTIONS_URI,
    MEMORY_BRIEF_URI,
];

fn handle_resources_list(id: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "resources": [
                {
                    "uri": GUIDE_URI,
                    "name": "impress: agent guide",
                    "mimeType": "text/markdown",
                    "description": "Read this first. What impress is, what each app does, \
                                    which search tool to use when, and how asynchronous \
                                    operations and review checkpoints work.",
                },
                {
                    "uri": STORE_SCHEMAS_URI,
                    "name": "impress store: record kinds",
                    "mimeType": "application/json",
                    "description": "Every record kind in the shared store with a live item \
                                    count and its payload field names. Read this before \
                                    browsing: it names the exact `schema_ref` values \
                                    store-query-service_list-items takes.",
                },
                {
                    "uri": STORE_COLLECTIONS_URI,
                    "name": "impress store: collections",
                    "mimeType": "application/json",
                    "description": "All four collection hierarchies (imbib publications, \
                                    imprint manuscripts, implore figures, and the generic \
                                    mixed-kind kernel) with nesting and live member counts — \
                                    the ids every collection-service_* tool takes.",
                },
                {
                    "uri": MEMORY_BRIEF_URI,
                    "name": "Memory brief",
                    "mimeType": "text/markdown",
                    "description": "Current standing instructions, claims, and episodes from \
                                    the suite memory (ADR-0028), rendered as markdown with \
                                    `[impress-item:<id>]` references back to the source rows. \
                                    The same digest memory-service_memory-brief returns, \
                                    readable without a tool call.",
                },
            ]
        }
    })
}

/// How long a resource read may take before we answer with an error instead.
///
/// A resource read reaches `impress-store-service`, which opens the shared
/// store through `SqliteItemStore::open` — a WRITE path that runs schema init
/// and migrations. Against the live store (~317 MB, 167 MB WAL) with the app
/// writing concurrently, that has taken minutes. stdio dispatch is sequential,
/// so one slow read stalls every later request in the session: the client sees
/// a dead server, not a slow resource.
const RESOURCE_DEADLINE: std::time::Duration = std::time::Duration::from_secs(10);

/// Run a store read on a worker thread and give up after `RESOURCE_DEADLINE`.
///
/// The thread is left running rather than killed — SQLite is mid-operation and
/// there is no safe way to interrupt it from outside — but the session stays
/// responsive, which is the point.
fn with_deadline<T: Send + 'static>(
    what: &str,
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(work());
    });
    match rx.recv_timeout(RESOURCE_DEADLINE) {
        Ok(result) => result,
        Err(_) => Err(format!(
            "{what} did not finish within {}s. The shared store is busy or \
             recovering a large WAL; the app may be writing to it. Other tools \
             are unaffected — retry this read shortly.",
            RESOURCE_DEADLINE.as_secs()
        )),
    }
}

/// Serialize a store overview as JSON resource contents.
fn json_resource(id: &Value, uri: &str, body: Result<Value, String>) -> Value {
    match body {
        Ok(value) => {
            let text = serde_json::to_string_pretty(&value).unwrap_or_else(|e| e.to_string());
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "contents": [{ "uri": uri, "mimeType": "application/json", "text": text }]
                }
            })
        }
        // A store that will not open is a real failure, and a resource that
        // answered `{}` would look like an empty store instead.
        Err(e) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32603, "message": format!("Could not read {uri}: {e}") }
        }),
    }
}

fn store_schemas_body() -> Result<Value, String> {
    with_deadline("impress://store/schemas", || {
        let store = impress_store_service::store_instance();
        let path = impress_store_service::store_path();
        let overview = impress_store_service::schema_overview(&store, &path.to_string_lossy())
            .map_err(|e| e.to_string())?;
        serde_json::to_value(overview).map_err(|e| e.to_string())
    })
}

fn store_collections_body() -> Result<Value, String> {
    with_deadline("impress://store/collections", || {
        let store = impress_store_service::store_instance();
        let path = impress_store_service::store_path();
        let overview = impress_store_service::collection_overview(&store, &path.to_string_lossy());
        serde_json::to_value(overview).map_err(|e| e.to_string())
    })
}

/// Slightly above the kernel default of 8 (see `MemoryService::memory_brief`'s
/// doc comment): this resource is read passively rather than as a follow-up
/// to a narrower `recall`, so a fuller brief is worth the extra tokens.
const MEMORY_BRIEF_MAX_ENTRIES: i64 = 12;

/// Render the current memory brief for the `impress://memory/brief` resource
/// body.
///
/// Calls the exact code path `memory-service_memory-brief` uses — a fresh
/// `DefaultMemoryService` (its `new()` falls back to the shared
/// `store_instance()`, same singleton the store resources above read) — via
/// `#[impress_service]`'s own `block_on` helper, since resource handlers are
/// synchronous. Guarded by the same open-stall deadline as the store
/// resources, since the first touch of the singleton in a session pays the
/// same potential store-open cost.
///
/// Unlike the store resources, this never turns a store failure into an RPC
/// error: `memory_brief` already reports failure as `ok: false` plus a
/// message (the established shape for every memory-kernel call), so an
/// unavailable store degrades to body text here too, prefixed so it reads as
/// a status rather than as the brief itself.
fn memory_brief_markdown() -> String {
    let outcome = with_deadline(MEMORY_BRIEF_URI, || {
        let service = impress_memory_service::DefaultMemoryService::new();
        Ok(impress_service_core::runtime::block_on(
            service.memory_brief(String::new(), String::new(), MEMORY_BRIEF_MAX_ENTRIES),
        ))
    });
    match outcome {
        Ok(brief) if brief.ok => brief.text,
        Ok(brief) => format!("memory brief unavailable: {}", brief.message),
        Err(e) => format!("memory brief unavailable: {e}"),
    }
}

fn handle_resources_read(id: &Value, request: &Value) -> Value {
    let uri = request["params"]["uri"].as_str().unwrap_or("");
    match uri {
        GUIDE_URI => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "contents": [{
                    "uri": GUIDE_URI,
                    "mimeType": "text/markdown",
                    "text": GUIDE_MARKDOWN,
                }]
            }
        }),
        STORE_SCHEMAS_URI => json_resource(id, STORE_SCHEMAS_URI, store_schemas_body()),
        STORE_COLLECTIONS_URI => json_resource(id, STORE_COLLECTIONS_URI, store_collections_body()),
        MEMORY_BRIEF_URI => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "contents": [{
                    "uri": MEMORY_BRIEF_URI,
                    "mimeType": "text/markdown",
                    "text": memory_brief_markdown(),
                }]
            }
        }),
        _ => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {
                "code": -32602,
                "message": format!(
                    "Unknown resource: {uri}. Available: {}",
                    RESOURCE_URIS.join(", ")
                ),
            }
        }),
    }
}

#[cfg(test)]
mod resource_tests {
    use super::*;

    fn listed_uris() -> Vec<String> {
        handle_resources_list(&json!(1))["result"]["resources"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["uri"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn guide_is_listed_and_readable() {
        assert_eq!(listed_uris()[0], GUIDE_URI, "the guide leads the listing");

        let read = handle_resources_read(&json!(2), &json!({"params": {"uri": GUIDE_URI}}));
        let text = read["result"]["contents"][0]["text"].as_str().unwrap();
        assert!(
            text.starts_with("# impress"),
            "guide should open with its title"
        );
        assert!(
            text.len() > 4000,
            "guide looks truncated: {} chars",
            text.len()
        );
    }

    /// A resource a client cannot discover is a resource nobody reads.
    #[test]
    fn every_resource_is_listed_and_described() {
        let uris = listed_uris();
        assert_eq!(uris, RESOURCE_URIS, "listing must match the declared set");

        for r in handle_resources_list(&json!(1))["result"]["resources"]
            .as_array()
            .unwrap()
        {
            for field in ["uri", "name", "mimeType", "description"] {
                let value = r[field].as_str().unwrap_or("");
                assert!(!value.is_empty(), "{field} missing from {r}");
            }
        }
    }

    /// Point the services at a scratch database for the rest of this test
    /// binary.
    ///
    /// The store resources must NOT read the developer's real store: it lives
    /// in a TCC-protected app-group container, and a sandboxed or launchd-run
    /// process (the self-hosted CI runner) blocks indefinitely opening it —
    /// `cargo test --workspace` hung for three hours on exactly that. A
    /// scratch path also makes the assertions deterministic instead of
    /// dependent on whatever the user happens to have imported.
    fn use_scratch_store() {
        use std::sync::Once;
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            let path = std::env::temp_dir().join(format!(
                "impress-mcp-resource-tests-{}.sqlite",
                std::process::id()
            ));
            let _ = std::fs::remove_file(&path);
            let _ = impress_store_service::set_store_path(&path);
        });
    }

    /// Asserts the SHAPE of the store resources and that they never fail
    /// open: `store_instance` degrades to an empty in-memory store rather
    /// than erroring, which is what makes the server usable before the apps
    /// have ever run.
    #[test]
    fn store_resources_answer_with_json_of_the_documented_shape() {
        use_scratch_store();
        let schemas =
            handle_resources_read(&json!(4), &json!({"params": {"uri": STORE_SCHEMAS_URI}}));
        let contents = &schemas["result"]["contents"][0];
        assert_eq!(contents["mimeType"], "application/json");
        let body: Value = serde_json::from_str(contents["text"].as_str().unwrap())
            .expect("the schemas resource must be parseable JSON");
        assert!(body["store_path"].is_string(), "{body}");
        assert!(body["total_items"].is_number());
        let schema_rows = body["schemas"].as_array().expect("schemas array");
        assert!(
            schema_rows.len() > 10,
            "the registered kinds are listed even against an empty store"
        );
        assert!(schema_rows
            .iter()
            .any(|s| s["schema_ref"] == "manuscript" && s["registered"] == true));

        let collections = handle_resources_read(
            &json!(5),
            &json!({"params": {"uri": STORE_COLLECTIONS_URI}}),
        );
        let contents = &collections["result"]["contents"][0];
        assert_eq!(contents["mimeType"], "application/json");
        let body: Value = serde_json::from_str(contents["text"].as_str().unwrap())
            .expect("the collections resource must be parseable JSON");
        let bindings: Vec<&str> = body["bindings"]
            .as_array()
            .expect("bindings array")
            .iter()
            .map(|b| b["binding"].as_str().unwrap())
            .collect();
        assert_eq!(
            bindings,
            vec!["imbib", "manuscript", "figure", "generic"],
            "every binding the collection tools accept must appear"
        );
    }

    /// The memory-brief resource must be discoverable via `resources/list`
    /// and must actually read live memory through `resources/read` — not a
    /// hardcoded stub.
    ///
    /// Seeding goes through `DefaultMemoryService::new()` rather than
    /// `with_store`: the resource handler itself constructs `new()` (falling
    /// back to the shared `store_instance()`), so only seeding through that
    /// SAME global singleton — after `use_scratch_store` points it at a
    /// throwaway file, exactly as `store_resources_answer_with_json_of_the_documented_shape`
    /// does above — actually exercises the code path under test. A store
    /// built with `with_store` would be a different store the handler never
    /// reads from.
    #[test]
    fn memory_brief_resource_is_listed_and_serves_a_seeded_instruction() {
        use_scratch_store();
        assert!(
            listed_uris().contains(&MEMORY_BRIEF_URI.to_string()),
            "impress://memory/brief must be discoverable via resources/list"
        );

        let service = impress_memory_service::DefaultMemoryService::new();
        let remembered = impress_service_core::runtime::block_on(service.remember(
            "instruction".into(),
            "No shell scans".into(),
            "Never scan the shared container from a shell.".into(),
            String::new(),
            -1.0,
            vec![],
            vec![],
        ));
        assert!(remembered.ok, "{}", remembered.message);

        let read = handle_resources_read(&json!(6), &json!({"params": {"uri": MEMORY_BRIEF_URI}}));
        let contents = &read["result"]["contents"][0];
        assert_eq!(contents["mimeType"], "text/markdown");
        let text = contents["text"].as_str().unwrap();
        assert!(text.contains("### Instructions"), "{text}");
        assert!(text.contains("No shell scans"), "{text}");
        assert!(
            text.contains(&format!("[impress-item:{}]", remembered.claim_id)),
            "{text}"
        );
    }

    #[test]
    fn unknown_resource_is_an_error_not_an_empty_success() {
        let read = handle_resources_read(&json!(3), &json!({"params": {"uri": "impress://nope"}}));
        assert!(read["error"].is_object(), "expected an error, got {read}");
        // The error names the alternatives, so a wrong guess is self-correcting.
        let message = read["error"]["message"].as_str().unwrap();
        assert!(message.contains(STORE_SCHEMAS_URI), "{message}");
    }
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
///
/// Which *rendering* of that inventory a client gets is `surface::projection`
/// (ADR-0024). `Flat` is the historical shape and what impel consumes;
/// `Grouped` folds the long tail behind domain tools. Both are views of the
/// same descriptors — see `surface` for why that distinction matters.
fn tool_definitions() -> Value {
    tool_definitions_in(crate::surface::projection())
}

/// The rendering, with the projection passed in rather than read from the
/// environment. Tests take this path: `IMPRESS_MCP_SURFACE` is process-global,
/// and a test that set it would change what every other test in the binary sees.
fn tool_definitions_in(projection: crate::surface::Projection) -> Value {
    let legacy: Vec<Value> = match legacy_tool_definitions() {
        Value::Array(items) => items,
        other => vec![other],
    };

    match projection {
        crate::surface::Projection::Grouped => {
            Value::Array(crate::surface::grouped_definitions(legacy))
        }
        crate::surface::Projection::Flat => {
            let mut tools = legacy;
            // Withhold tools whose app is closed — see `reachability`.
            tools.extend(inventory_tool_definitions().into_iter().filter(|t| {
                t.get("name")
                    .and_then(|n| n.as_str())
                    .map(crate::reachability::is_available)
                    .unwrap_or(true)
            }));
            Value::Array(tools)
        }
    }
}

/// How many tools a client would see right now — after withholding.
pub fn exposed_tool_count() -> usize {
    match tool_definitions() {
        Value::Array(items) => items.len(),
        _ => 0,
    }
}

/// How many tools exist in total, ignoring reachability.
pub fn total_tool_count() -> usize {
    let legacy = match legacy_tool_definitions() {
        Value::Array(items) => items.len(),
        _ => 0,
    };
    legacy + inventory_tool_definitions().len()
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
        },
        {
            "name": "render_pdf_page",
            "description": "Render one page of a PDF on disk to a PNG and return it as an image, so it can actually be SEEN in the conversation. MCP carries raster images, not PDFs, which is why a compiled manuscript otherwise arrives as a path and a byte count. Feed it the path from imprint-manuscript-service_compile-typst (works with every app closed), imbib-manuscripts-service_compile-manuscript, or imprint-app-service_get-pdf. Pages are 1-based and clamped to the document.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "pdf_path": {
                        "type": "string",
                        "description": "Absolute path to the PDF, as returned by a compile tool"
                    },
                    "page": {
                        "type": "integer",
                        "description": "1-based page number (default: 1)",
                        "default": 1
                    },
                    "max_dim": {
                        "type": "integer",
                        "description": "Longest edge in pixels (default: 1100, readable for body text)",
                        "default": 1100
                    }
                },
                "required": ["pdf_path"]
            }
        }
    ])
}

fn handle_tool_call(ctx: &ToolContext, id: &Value, request: &Value) -> Value {
    let tool_name = request["params"]["name"].as_str().unwrap_or("");
    let args = &request["params"]["arguments"];

    if tool_name == "render_pdf_page" {
        return handle_render_pdf_page(id, request);
    }

    // The grouped projection's synthetic tools (ADR-0024). Returns None for
    // everything else, so the flat path below is unchanged.
    if let Some(result) = crate::surface::dispatch(tool_name, args) {
        return match result {
            Ok(value) => {
                let text = match &value {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "content": [{ "type": "text", "text": text }],
                        "structuredContent": value,
                    }
                })
            }
            Err(e) => wrap_text_result(id, Err(e)),
        };
    }

    // Try legacy hand-written tools first.
    let legacy_result: Option<Result<String, String>> = match tool_name {
        // Rasterisation answers with image content, so it returns early
        // rather than going through the text wrapper below.
        "search_papers" => Some(tool_search_papers(ctx, args)),
        "get_paper_chunks" => Some(tool_get_paper_chunks(ctx, args)),
        "list_indexed_papers" => Some(tool_list_indexed_papers(ctx, args)),
        _ => None,
    };

    if let Some(result) = legacy_result {
        return wrap_text_result(id, result);
    }

    // A gated tool called anyway (a stale client list, or a guess) gets a
    // clear error rather than an empty success.
    if let Some(reason) = crate::reachability::unavailable_reason(tool_name) {
        return wrap_text_result(id, Err(reason));
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
                let (mut content, structured) = impress_service_core::split_mcp_content(value);
                let text = match &structured {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                content.push(json!({ "type": "text", "text": text }));
                return json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "content": content,
                        "structuredContent": structured,
                    }
                });
            }
            Err(e) => return wrap_text_result(id, Err(e)),
        }
    }

    wrap_text_result(id, Err(format!("Unknown tool: {tool_name}")))
}

/// Wrap a rendered page as MCP image content.
///
/// Tool results were text-only for this server's whole life, which dead-ended
/// every visual capability in the suite: a compiled manuscript could report its
/// filesize and nothing more. MCP carries raster images, so a PDF page has to
/// be rendered before it can be seen — see `crate::raster`.
///
/// The caption travels as a second, text block: an image alone gives the model
/// no page number, no path to open, and no way to ask for page 2.
fn wrap_image_result(id: &Value, png: &[u8], caption: String) -> Value {
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD.encode(png);
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "content": [
                { "type": "image", "data": data, "mimeType": "image/png" },
                { "type": "text", "text": caption },
            ]
        }
    })
}

/// `render_pdf_page` — the one tool that is a property of this transport rather
/// than of any app, which is why it is hand-written here beside the
/// semantic-search trio instead of living in a `*-service` trait. Nothing in
/// the suite needs it; only a client that must *display* a page does.
fn handle_render_pdf_page(id: &Value, request: &Value) -> Value {
    let args = &request["params"]["arguments"];
    let Some(path) = args.get("pdf_path").and_then(|p| p.as_str()) else {
        return wrap_text_result(id, Err("render_pdf_page needs a pdf_path".into()));
    };
    let page = args.get("page").and_then(|p| p.as_u64()).unwrap_or(1) as u32;
    let max_dim = args
        .get("max_dim")
        .and_then(|d| d.as_u64())
        .unwrap_or(crate::raster::DEFAULT_PAGE_MAX_DIM as u64) as u32;

    match crate::raster::rasterize_pdf_page(std::path::Path::new(path), page, max_dim) {
        Ok(r) => {
            let caption = format!(
                "Page {} of {} from {} ({}x{}px). Ask for another page by number.",
                r.page, r.page_count, path, r.width, r.height
            );
            wrap_image_result(id, &r.png, caption)
        }
        // Degrade to text rather than losing the call: the path is still
        // useful to an agent sitting at the user's Mac.
        Err(e) => wrap_text_result(
            id,
            Err(format!(
                "Could not render {path}: {e}. The PDF is still on disk at that path."
            )),
        ),
    }
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
        // Four hand-written tools: the three semantic-search ones, plus
        // render_pdf_page. Everything else in the server is generated from
        // #[impress_service]; this number should only ever grow for something
        // that is a property of the TRANSPORT rather than of an app.
        let tools = legacy_tool_definitions();
        assert!(tools.is_array());
        assert_eq!(tools.as_array().unwrap().len(), 4);
    }

    #[test]
    fn test_tool_definitions_includes_legacy_and_inventory() {
        // Combined list is legacy (3) + every `#[impress_service]` method.
        // imbib-service contributes 5 ImbibTextService methods at minimum.
        // Pinned flat: the grouped projection deliberately folds most of these
        // behind domain tools (ADR-0024), and what this test is about is that
        // the inventory reaches the listing at all.
        let tools = tool_definitions_in(crate::surface::Projection::Flat);
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
        let tools = tool_definitions_in(crate::surface::Projection::Flat);
        let tools = tools.as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            &names[..3],
            &["search_papers", "get_paper_chunks", "list_indexed_papers"]
        );
    }

    /// The grouped projection leads with the root tool, then keeps the legacy
    /// three flat. They are pre-codegen and unclassifiable (ADR-0024 D7), so
    /// folding them away would drop them entirely rather than group them.
    #[test]
    fn grouped_leads_with_the_root_tool_and_keeps_legacy_flat() {
        let tools = tool_definitions_in(crate::surface::Projection::Grouped);
        let tools = tools.as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            &names[..4],
            &[
                crate::surface::CAPABILITIES_TOOL,
                "search_papers",
                "get_paper_chunks",
                "list_indexed_papers"
            ]
        );
        assert!(
            names.len()
                < tool_definitions_in(crate::surface::Projection::Flat)
                    .as_array()
                    .unwrap()
                    .len(),
            "grouped should be smaller than flat: {names:?}"
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
