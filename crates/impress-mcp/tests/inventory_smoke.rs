//! End-to-end smoke test for the Phase 3B inventory bridge.
//!
//! Spawns the `impress-mcp` binary, pipes JSON-RPC requests at it
//! (`initialize`, `tools/list`, `tools/call`, `resources/list`,
//! `resources/read`), and asserts that:
//!
//! * `tools/list` returns the legacy semantic-search tools AND the
//!   `#[impress_service]`-registered tools from `imbib-service` and the
//!   store-generic crate;
//! * `tools/call` for `imbib-text-service_decode-latex` produces
//!   `"Café"` from `"Caf\\'{e}"`;
//! * `resources/list` offers the guide plus the two store-browse resources
//!   (ADR-0022 WP G6), and reading them yields JSON that honours
//!   `--store-path` rather than the default app-group container.
//!
//! This complements the unit tests in `src/inventory_bridge.rs` and
//! `src/server.rs`: those exercise the bridge and the resource handlers
//! in-process, this one verifies that the real binary's static-init wiring
//! lights up so the shipped tool actually surfaces the inventory — and, for
//! the resources, that the store path parsed from argv is the one they read.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    // Cargo sets CARGO_BIN_EXE_<name> for [[bin]] targets of the same
    // package when building integration tests — no need to walk paths.
    PathBuf::from(env!("CARGO_BIN_EXE_impress-mcp"))
}

fn temp_paths() -> (PathBuf, PathBuf, PathBuf) {
    let mut dir = std::env::temp_dir();
    dir.push(format!(
        "impress-mcp-smoke-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let embeddings = dir.join("embeddings.sqlite");
    let store = dir.join("store.sqlite");
    (dir, embeddings, store)
}

#[test]
#[ignore = "spawns full binary (initializes fastembed); run with --ignored"]
fn list_and_call_inventory_tool_via_stdio() {
    let (_tmp, embeddings, store) = temp_paths();

    let mut child = Command::new(binary_path())
        .args(["--embeddings-path"])
        .arg(&embeddings)
        .args(["--store-path"])
        .arg(&store)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn impress-mcp");

    let requests = concat!(
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"imbib-text-service_decode-latex","arguments":{"input":"Caf\\'{e}"}}}"#,
        "\n",
        // ADR-0022 WP G6: the store-browse resources. A resource the client
        // cannot discover is one nobody reads, so list before reading.
        r#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"impress://store/schemas"}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"impress://store/collections"}}"#,
        "\n",
        // WP G6: browse a store that has no rows at all. The interesting
        // answer is a well-formed empty page, not an error.
        r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"store-query-service_list-items","arguments":{"schema_ref":"manuscript","limit":5,"offset":0}}}"#,
        "\n",
    );

    child
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(requests.as_bytes())
        .expect("write requests");

    let output = child.wait_with_output().expect("wait for child");
    let stdout = String::from_utf8_lossy(&output.stdout);

    let lines: Vec<&str> = stdout.lines().filter(|l| !l.trim().is_empty()).collect();
    assert!(lines.len() >= 7, "expected >=7 responses; got: {stdout}");

    // Response 2 is tools/list.
    let v2: serde_json::Value = serde_json::from_str(lines[1]).expect("parse tools/list response");
    let tools = v2["result"]["tools"]
        .as_array()
        .expect("tools array present");
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    for legacy in ["search_papers", "get_paper_chunks", "list_indexed_papers"] {
        assert!(
            names.contains(&legacy),
            "missing legacy {legacy} in {names:?}"
        );
    }
    for inv in [
        "imbib-text-service_decode-latex",
        "imbib-text-service_normalize-tag-path",
        // ADR-0022 WP G1: store-generic services. These are never withheld by
        // the reachability gate, so they must be listed here even with every
        // app closed — which is exactly the state this test runs in.
        "collection-service_tree",
        "collection-service_add-members",
        // ADR-0022 WP G7: the flagged data migration's entry points. Listed
        // with every app closed, like every other store-generic tool.
        "collection-service_migration-status",
        "collection-service_migrate",
        "collection-service_rollback",
        "triage-service_set-starred",
        "triage-service_set-status",
        // ADR-0022 WP G4/G5/G6: the mixed-kind reads. Same crate, same
        // force-link in `main.rs` — a new namespace needs no extra wiring, and
        // this is where that would show up if it did.
        "store-query-service_search-all",
        "store-query-service_related-items",
        "store-query-service_get-item",
        "store-query-service_list-items",
        // Stage 7 item 8: the smart-search core, ported out of the
        // ImpressSmartSearch Swift package. Pure string functions with no app
        // or store dependency, so — like the store-generic namespaces above —
        // they must appear with every app closed and need no reachability
        // entry. Listing them here is what catches a missing force-link `use`
        // in `main.rs`, which would dead-strip all ten silently.
        "smart-search-service_classify-search-input",
        "smart-search-service_normalize-ads-query",
        "smart-search-service_rewrite-free-text-query",
        "smart-search-service_build-ads-query",
        "smart-search-service_clean-ads-query",
        "smart-search-service_split-reference-blocks",
        "smart-search-service_extract-page-identifiers",
        "smart-search-service_validate-parsed-reference",
        "smart-search-service_free-text-extraction-prompt",
        "smart-search-service_reference-parse-prompt",
        // Stage 7 item 9: imbib's archive and publisher parsers, ported out of
        // PMC/{Mbox,Publishers}. Same shape as the smart-search namespace above
        // — pure functions, no store, no app, no network — so they must appear
        // with every app closed and need no reachability entry. Listed here for
        // the same reason: a missing force-link `use` in `main.rs` would
        // dead-strip all six silently.
        "parsers-service_parse-mbox",
        "parsers-service_decode-mime-header",
        "parsers-service_decode-quoted-printable",
        "parsers-service_resolve-publisher-pdf",
        "parsers-service_list-publisher-rules",
        "parsers-service_extract-landing-page-pdf",
    ] {
        assert!(names.contains(&inv), "missing inventory {inv} in {names:?}");
    }

    // Response 3 is the decode-latex call.
    let v3: serde_json::Value = serde_json::from_str(lines[2]).expect("parse tools/call response");
    let text = v3["result"]["content"][0]["text"]
        .as_str()
        .expect("text content");
    assert_eq!(text, "Café", "decode_latex did not decode \\'{{e}}");

    // Response 4 is resources/list — the store-browse resources (WP G6) must
    // be discoverable beside the guide.
    let v4: serde_json::Value =
        serde_json::from_str(lines[3]).expect("parse resources/list response");
    let uris: Vec<&str> = v4["result"]["resources"]
        .as_array()
        .expect("resources array")
        .iter()
        .map(|r| r["uri"].as_str().expect("uri"))
        .collect();
    for uri in [
        "impress://guide",
        "impress://store/schemas",
        "impress://store/collections",
    ] {
        assert!(uris.contains(&uri), "missing resource {uri} in {uris:?}");
    }

    // Response 5 is the schemas resource. `--store-path` points at a file that
    // does not exist, so the interesting assertion is that it still answers
    // well-formed JSON naming the store it looked at, rather than erroring or
    // silently reading the user's real store.
    let v5: serde_json::Value =
        serde_json::from_str(lines[4]).expect("parse resources/read schemas");
    let body: serde_json::Value =
        serde_json::from_str(v5["result"]["contents"][0]["text"].as_str().expect("text"))
            .expect("schemas resource is JSON");
    assert_eq!(
        body["store_path"].as_str().map(std::path::Path::new),
        Some(store.as_path()),
        "the resource must honour --store-path, not the default container"
    );
    assert!(
        body["schemas"]
            .as_array()
            .expect("schemas array")
            .iter()
            .any(|s| s["schema_ref"] == "manuscript"),
        "registered kinds are listed even with an empty store: {body}"
    );

    // Response 6 is the collections resource: all four bindings, always.
    let v6: serde_json::Value =
        serde_json::from_str(lines[5]).expect("parse resources/read collections");
    let body: serde_json::Value =
        serde_json::from_str(v6["result"]["contents"][0]["text"].as_str().expect("text"))
            .expect("collections resource is JSON");
    let bindings: Vec<&str> = body["bindings"]
        .as_array()
        .expect("bindings array")
        .iter()
        .map(|b| b["binding"].as_str().expect("binding"))
        .collect();
    assert_eq!(bindings, vec!["imbib", "manuscript", "figure", "generic"]);

    // Response 7 is the browse tool against an empty store: a well-formed
    // empty page, not an error.
    let v7: serde_json::Value = serde_json::from_str(lines[6]).expect("parse list-items response");
    let listed = &v7["result"]["structuredContent"];
    assert_eq!(listed["ok"], true, "list_items failed: {v7}");
    assert_eq!(listed["total"], 0);
    assert!(listed["items"].as_array().expect("items array").is_empty());
}
