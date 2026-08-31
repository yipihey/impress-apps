use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;

use base64::Engine;
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use sha2::{Digest, Sha256};
use vw_impress_adapter::{PhotoDescription, PhotoEvidenceStore};
use vw_service::ChatGptFile;

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
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://vw/evidence-image-v1.html\"}}\n",
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
    assert_eq!(lines.len(), 5);
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
    assert!(names.contains(&"vw-diagnostic-service_ingest-photo"));
    assert!(names.contains(&"vw-diagnostic-service_search-photos"));
    assert!(names.contains(&"vw-diagnostic-service_get-photo"));
    assert!(!names.contains(&"source-service_put-citation"));
    assert!(!names
        .iter()
        .any(|name| name.starts_with("store-query-service_")));

    for image_tool_name in [
        "source-service_get-page-image",
        "source-service_get-figure-image",
        "vw-diagnostic-service_ingest-photo",
        "vw-diagnostic-service_get-photo",
    ] {
        let image_tool = lines[1]["result"]["tools"]
            .as_array()
            .expect("tools")
            .iter()
            .find(|tool| tool["name"] == image_tool_name)
            .expect("image tool");
        assert_eq!(
            image_tool["_meta"]["ui"]["resourceUri"],
            "ui://vw/evidence-image-v1.html"
        );
        assert_eq!(
            image_tool["_meta"]["openai/outputTemplate"],
            "ui://vw/evidence-image-v1.html"
        );
    }

    let ingest_photo = lines[1]["result"]["tools"]
        .as_array()
        .expect("tools")
        .iter()
        .find(|tool| tool["name"] == "vw-diagnostic-service_ingest-photo")
        .expect("ingest-photo tool");
    assert_eq!(
        ingest_photo["_meta"]["openai/fileParams"],
        serde_json::json!(["photo"])
    );
    assert_eq!(ingest_photo["annotations"]["readOnlyHint"], false);
    assert_eq!(ingest_photo["annotations"]["openWorldHint"], true);
    let file_schema = &ingest_photo["inputSchema"]["definitions"]["OpenAIFile"];
    assert_eq!(
        file_schema["required"],
        serde_json::json!(["download_url", "file_id"])
    );
    for property in ["download_url", "file_id", "mime_type", "file_name"] {
        assert_eq!(file_schema["properties"][property]["type"], "string");
    }
    assert_eq!(file_schema["additionalProperties"], false);

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
    assert!(uris.contains(&"ui://vw/evidence-image-v1.html"));
    assert_eq!(
        lines[4]["result"]["contents"][0]["mimeType"],
        "text/html;profile=mcp-app"
    );
    assert!(lines[4]["result"]["contents"][0]["text"]
        .as_str()
        .expect("viewer HTML")
        .contains("ui/notifications/tool-result"));

    let _ = std::fs::remove_file(store);
}

fn synthetic_pdf() -> Vec<u8> {
    let stream = "0.2 0.7 0.3 rg 20 70 160 100 re f\n";
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
fn automatic_figure_ingest_resolves_as_image_over_stdio() {
    let temp = tempfile::tempdir().expect("tempdir");
    let store_path = temp.path().join("impress.sqlite");
    let asset_root = temp.path().join("assets");
    let cache_root = temp.path().join("cache");
    let source_path = temp.path().join("automatic-figure.pdf");
    let ocr_path = temp.path().join("ocr.sqlite");
    let pdf = synthetic_pdf();
    let hash = format!("{:x}", Sha256::digest(&pdf));
    std::fs::write(&source_path, pdf).expect("write fixture PDF");

    let ocr = rusqlite::Connection::open(&ocr_path).expect("open OCR fixture");
    ocr.execute_batch(
        "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);\
         CREATE TABLE pages (\
           pdf_page INTEGER PRIMARY KEY, section_hint TEXT NOT NULL,\
           text TEXT NOT NULL, mean_confidence REAL NOT NULL, layout_json TEXT NOT NULL\
         );",
    )
    .expect("create OCR fixture");
    for (key, value) in [
        ("source_sha256", hash.as_str()),
        ("source_pages", "1"),
        ("engine", "synthetic-layout"),
        ("engine_version", "1.0"),
        ("profile", "synthetic-test"),
        ("built_at", "2026-08-07T00:00:00Z"),
    ] {
        ocr.execute(
            "INSERT INTO metadata (key, value) VALUES (?1, ?2)",
            rusqlite::params![key, value],
        )
        .expect("insert OCR metadata");
    }
    let layout = serde_json::json!([
        {
            "text":"Procedure text above the illustration",
            "confidence":1.0,
            "boundingBox":{"x":0.15,"y":0.82,"width":0.70,"height":0.025}
        },
        {
            "text":"Fig. 1-1. Synthetic green diagnostic figure.",
            "confidence":1.0,
            "boundingBox":{"x":0.15,"y":0.20,"width":0.70,"height":0.025}
        },
        {
            "text":"Following procedure text",
            "confidence":1.0,
            "boundingBox":{"x":0.15,"y":0.05,"width":0.70,"height":0.025}
        }
    ]);
    ocr.execute(
        "INSERT INTO pages (pdf_page, section_hint, text, mean_confidence, layout_json) \
         VALUES (1, 'Synthetic', 'Procedure Fig. 1-1.', 1.0, ?1)",
        [layout.to_string()],
    )
    .expect("insert OCR page");
    drop(ocr);

    let ingest = Command::new(env!("CARGO_BIN_EXE_vw-knowledge-ingest"))
        .args(["--store-path"])
        .arg(&store_path)
        .args(["--source-pdf"])
        .arg(&source_path)
        .args(["--ocr-index"])
        .arg(&ocr_path)
        .args([
            "--title",
            "Synthetic Automatic Figure Manual",
            "--source-class",
            "test-manual",
            "--publisher",
            "Impress Tests",
            "--asset-root",
        ])
        .arg(&asset_root)
        .output()
        .expect("run automatic figure ingest");
    assert!(
        ingest.status.success(),
        "ingest stderr: {}",
        String::from_utf8_lossy(&ingest.stderr)
    );

    let store = SqliteItemStore::open(&store_path).expect("open ingested store");
    let source = store
        .query(&ItemQuery {
            schema: Some("impress/artifact/general".into()),
            ..Default::default()
        })
        .expect("query source")
        .into_iter()
        .next()
        .expect("ingested source");
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
        "params":{"name":"source-service_get-figure-image","arguments":{
            "citation_id":null, "source_item_id":source.id.to_string(),
            "figure_label":"Fig. 1-1", "padding":8, "resolution_dpi":144,
            "include_caption":true, "format":"png"
        }}
    });
    writeln!(child.stdin.as_mut().expect("stdin"), "{request}").expect("write request");
    drop(child.stdin.take());
    let output = child.wait_with_output().expect("wait for MCP response");
    assert!(
        output.status.success(),
        "MCP stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON-RPC response");
    assert_eq!(response["result"]["isError"], false);
    assert_eq!(
        response["result"]["structuredContent"]["status"],
        "resolved"
    );
    let metadata = &response["result"]["structuredContent"]["metadata"];
    assert_eq!(metadata["figure_label"], "Fig. 1-1");
    assert_eq!(metadata["crop_status"], "extracted");
    assert_eq!(metadata["page_index"], 0);
    assert_eq!(metadata["page_label"], "1");
    assert!(metadata["extraction_version"]
        .as_str()
        .unwrap()
        .contains("impress-figure-boundary:1.0.0"));
    let image = response["result"]["content"]
        .as_array()
        .unwrap()
        .iter()
        .find(|block| block["type"] == "image")
        .expect("MCP image content block");
    assert_eq!(image["mimeType"], "image/png");
    assert!(image["data"].as_str().unwrap().len() > 100);
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

#[test]
fn stored_user_photo_crosses_the_actual_stdio_boundary_as_mcp_image_content() {
    let temp = tempfile::tempdir().expect("tempdir");
    let store_path = temp.path().join("impress.sqlite");
    let blob_root = temp.path().join("blobs");
    let store = Arc::new(SqliteItemStore::open(&store_path).expect("open store"));
    let photo_bytes = base64::engine::general_purpose::STANDARD
        .decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        .expect("decode PNG fixture");
    let stored = PhotoEvidenceStore::new(blob_root)
        .expect("photo store")
        .ingest_bytes(
            store.clone(),
            ChatGptFile {
                download_url: "https://files.oaiusercontent.com/fixture".into(),
                file_id: "file_stdio_photo_fixture".into(),
                mime_type: Some("image/png".into()),
                file_name: Some("engine.png".into()),
            },
            PhotoDescription {
                title: "Engine compartment photo".into(),
                description: "Synthetic diagnostic photo fixture.".into(),
                component: Some("engine compartment".into()),
                diagnostic_session_id: None,
                captured_at: None,
                tags: vec!["fixture".into()],
            },
            photo_bytes,
        );
    assert!(stored.ok, "{}", stored.message);
    let evidence_id = stored.evidence.expect("photo evidence").id;
    drop(store);

    let mut child = Command::new(binary_path())
        .arg("--store-path")
        .arg(&store_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn vw-mcp");
    let request = serde_json::json!({
        "jsonrpc":"2.0", "id":1, "method":"tools/call",
        "params":{
            "name":"vw-diagnostic-service_get-photo",
            "arguments":{"evidence_id":evidence_id}
        }
    });
    writeln!(child.stdin.as_mut().expect("stdin"), "{request}").expect("write request");
    drop(child.stdin.take());
    let output = child.wait_with_output().expect("wait for MCP response");
    assert!(
        output.status.success(),
        "MCP stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON-RPC response");
    assert_eq!(response["result"]["isError"], false);
    assert_eq!(
        response["result"]["structuredContent"]["status"],
        "retrieved"
    );
    assert_eq!(
        response["result"]["structuredContent"]["evidence"]["title"],
        "Engine compartment photo"
    );
    let image = response["result"]["content"]
        .as_array()
        .expect("MCP content")
        .iter()
        .find(|block| block["type"] == "image")
        .expect("MCP image content block");
    assert_eq!(image["mimeType"], "image/png");
    assert!(image["data"].as_str().expect("base64 image").len() > 40);
}
