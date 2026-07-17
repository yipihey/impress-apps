//! End-to-end smoke test for the Phase 3B inventory bridge.
//!
//! Spawns the `impress-mcp` binary, pipes three JSON-RPC requests at it
//! (`initialize`, `tools/list`, `tools/call`), and asserts that:
//!
//! * `tools/list` returns the legacy semantic-search tools AND the
//!   `#[impress_service]`-registered tools from `imbib-service`;
//! * `tools/call` for `imbib-text-service_decode-latex` produces
//!   `"Café"` from `"Caf\\'{e}"`.
//!
//! This complements the unit tests in `src/inventory_bridge.rs` and
//! `src/server.rs`: those exercise the bridge in-process, this one
//! verifies that the real binary's static-init wiring lights up so the
//! shipped tool actually surfaces the inventory.

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
    assert!(lines.len() >= 3, "expected >=3 responses; got: {stdout}");

    // Response 2 is tools/list.
    let v2: serde_json::Value =
        serde_json::from_str(lines[1]).expect("parse tools/list response");
    let tools = v2["result"]["tools"]
        .as_array()
        .expect("tools array present");
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    for legacy in ["search_papers", "get_paper_chunks", "list_indexed_papers"] {
        assert!(names.contains(&legacy), "missing legacy {legacy} in {names:?}");
    }
    for inv in [
        "imbib-text-service_decode-latex",
        "imbib-text-service_normalize-tag-path",
    ] {
        assert!(names.contains(&inv), "missing inventory {inv} in {names:?}");
    }

    // Response 3 is the decode-latex call.
    let v3: serde_json::Value =
        serde_json::from_str(lines[2]).expect("parse tools/call response");
    let text = v3["result"]["content"][0]["text"]
        .as_str()
        .expect("text content");
    assert_eq!(text, "Café", "decode_latex did not decode \\'{{e}}");
}
