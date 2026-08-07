use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use base64::Engine;
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use sha2::{Digest, Sha256};

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
    assert!(names.contains(&"source-service_get-page-image"));
    assert!(names.contains(&"source-service_get-figure-image"));
    assert!(!names.contains(&"source-service_put-citation"));
    assert!(!names
        .iter()
        .any(|name| name.starts_with("store-query-service_")));

    let measurement_tool = lines[1]["result"]["tools"]
        .as_array()
        .expect("tools")
        .iter()
        .find(|tool| tool["name"] == "vw-diagnostic-service_record-measurement")
        .expect("record-measurement tool");
    let measurement_schema = &measurement_tool["inputSchema"];
    assert_eq!(
        measurement_schema["definitions"]["TerminalPair"]["type"], "object",
        "terminal endpoints must use a portable object schema, not tuple-style items"
    );
    assert_eq!(
        measurement_schema["definitions"]["TerminalPair"]["required"],
        serde_json::json!(["first", "second"])
    );

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

fn synthetic_pdf() -> Vec<u8> {
    let stream = "0.2 0.7 0.3 rg 20 20 160 160 re f\n";
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>"
            .to_string(),
        format!(
            "<< /Length {} >>\nstream\n{}endstream",
            stream.len(),
            stream
        ),
    ];
    let mut pdf = b"%PDF-1.4\n% synthetic MCP fixture\n".to_vec();
    let mut offsets = vec![0usize];
    for (index, object) in objects.iter().enumerate() {
        offsets.push(pdf.len());
        pdf.extend_from_slice(format!("{} 0 obj\n{}\nendobj\n", index + 1, object).as_bytes());
    }
    let xref = pdf.len();
    pdf.extend_from_slice(
        format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes(),
    );
    for offset in offsets.iter().skip(1) {
        pdf.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    pdf.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    pdf
}

#[test]
fn page_image_crosses_the_actual_stdio_boundary_as_mcp_image_content() {
    let temp = tempfile::tempdir().expect("tempdir");
    let store_path = temp.path().join("impress.sqlite");
    let asset_root = temp.path().join("assets");
    let cache_root = temp.path().join("cache");
    let pdf = synthetic_pdf();
    let hash = format!("{:x}", Sha256::digest(&pdf));
    let source_file = temp.path().join("fixture.pdf");
    std::fs::write(&source_file, pdf).expect("write fixture PDF");
    impress_store_service::install_source_pdf(&asset_root, &source_file, &hash)
        .expect("install asset");
    let store = SqliteItemStore::open(&store_path).expect("open store");
    let source = uuid::Uuid::new_v4();
    let now = chrono::Utc::now();
    store
        .insert(Item {
            id: source,
            schema: "impress/artifact/general".into(),
            payload: std::collections::BTreeMap::from([
                ("title".into(), Value::String("Synthetic MCP Manual".into())),
                ("file_hash".into(), Value::String(hash.clone())),
                (
                    "file_mime_type".into(),
                    Value::String("application/pdf".into()),
                ),
            ]),
            created: now,
            modified: now,
            author: "fixture".into(),
            author_kind: ActorKind::System,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec!["vw/knowledge-source".into()],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: Some("1.0.0".into()),
            batch_id: None,
            references: vec![],
            parent: None,
        })
        .expect("insert source");
    drop(store);

    let mut child = Command::new(binary_path())
        .arg("--store-path")
        .arg(&store_path)
        .arg("--asset-root")
        .arg(&asset_root)
        .arg("--cache-root")
        .arg(&cache_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn vw-mcp");
    let request = serde_json::json!({
        "jsonrpc":"2.0", "id":1, "method":"tools/call",
        "params":{"name":"source-service_get-page-image","arguments":{
            "source_item_id":source.to_string(), "page_index":0, "page_label":null,
            "resolution_dpi":144, "format":"png"
        }}
    });
    writeln!(child.stdin.as_mut().expect("stdin"), "{request}").expect("write request");
    drop(child.stdin.take());
    let output = child.wait_with_output().expect("wait");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON-RPC response");
    assert_eq!(response["result"]["isError"], false);
    let image = response["result"]["content"]
        .as_array()
        .unwrap()
        .iter()
        .find(|block| block["type"] == "image")
        .expect("MCP image content block");
    assert_eq!(image["mimeType"], "image/png");
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(image["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    assert_eq!(
        response["result"]["structuredContent"]["metadata"]["source_content_hash"],
        hash
    );
    assert!(response["result"]["structuredContent"]
        .get("_mcp_content")
        .is_none());
}
