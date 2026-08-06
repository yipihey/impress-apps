use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_vw-mcp"))
}

#[test]
fn focused_server_lists_and_calls_only_semantic_profile() {
    let store = std::env::temp_dir().join(format!(
        "vw-mcp-test-{}.sqlite",
        uuid::Uuid::new_v4().simple()
    ));
    let mut child = Command::new(binary_path())
        .args(["--store-path"])
        .arg(&store)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn vw-mcp");
    let requests = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"vw-diagnostic-service_get-capabilities\",\"arguments\":{}}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/list\"}\n",
    );
    child
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(requests.as_bytes())
        .expect("write MCP requests");
    drop(child.stdin.take());
    let output = child.wait_with_output().expect("wait for server");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let lines: Vec<serde_json::Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| serde_json::from_str(line).expect("JSON-RPC response"))
        .collect();
    assert_eq!(lines.len(), 4);
    assert_eq!(lines[0]["result"]["serverInfo"]["name"], "vw-diagnostic");

    let names: Vec<&str> = lines[1]["result"]["tools"]
        .as_array()
        .expect("tools")
        .iter()
        .filter_map(|tool| tool["name"].as_str())
        .collect();
    assert!(names.contains(&"vw-diagnostic-service_create-session"));
    assert!(names.contains(&"vw-diagnostic-service_evaluate-session"));
    assert!(names.contains(&"source-service_get-citation"));
    assert!(names.contains(&"source-service_get-content-chunk"));
    assert!(names.contains(&"source-service_search-content-chunks"));
    assert!(!names.contains(&"source-service_put-citation"));
    assert!(!names
        .iter()
        .any(|name| name.starts_with("store-query-service_")));

    assert_eq!(lines[2]["result"]["isError"], false);
    let body = lines[2]["result"]["content"][0]["text"]
        .as_str()
        .expect("capabilities text");
    let capabilities: serde_json::Value = serde_json::from_str(body).expect("capabilities JSON");
    assert_eq!(capabilities["published_rules"], 0);

    let uris: Vec<&str> = lines[3]["result"]["resources"]
        .as_array()
        .expect("resources")
        .iter()
        .filter_map(|resource| resource["uri"].as_str())
        .collect();
    assert!(uris.contains(&"impress://expert/vw/guide"));
    assert!(uris.contains(&"impress://expert/vw/schema"));

    let _ = std::fs::remove_file(store);
}
