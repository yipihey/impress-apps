//! Opt-in Tier B proof against the real MCP binary and stdlib Python provider.
//! Every child, socket, credential, database, and workspace belongs to this
//! test's temporary directory. Normal workspace tests never launch them.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use impress_service_core::registry_runtime;
use impress_service_core::report::tier_a::{run_provider_examples, Outcome};
use serde_json::{json, Value};

const PROVIDER_ID: &str = "python-reference";
const VERB: &str = "python-reference-service_echo";

struct OwnedChild(Child);

impl OwnedChild {
    fn alive(&mut self) -> bool {
        self.0.try_wait().expect("inspect owned child").is_none()
    }

    fn stop(&mut self) {
        if self.alive() {
            self.0.kill().expect("stop owned child");
        }
        self.0.wait().expect("reap owned child");
    }
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.alive() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

fn free_loopback_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .expect("reserve owned loopback port")
        .local_addr()
        .unwrap()
        .port()
}

fn private_file(path: &Path, value: &str) {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .expect("create private scratch token file");
    file.write_all(value.as_bytes())
        .expect("write scratch token");
}

fn scratch_env(command: &mut Command, root: &Path, store: &Path, workspace: &Path, device: &str) {
    command
        .env("IMPRESS_STORE_PATH", store)
        .env("IMBIB_STORE_PATH", store)
        .env("IMPRESS_WORKSPACE", workspace)
        .env("IMPRINT_COMPILE_CACHE_DIR", root.join("compile-cache"))
        .env("IMPRESS_DEVICE_ID", device)
        // Keep any future linked reachability checks away from workstation
        // app ports as well as relying on --http startup's no-probe guard.
        .env("IMBIB_BACKEND", "off")
        .env("IMPRINT_BACKEND", "off")
        .env("IMPLORE_BACKEND", "off")
        .env("IMPART_BACKEND", "off")
        // A caller cannot silently inherit a workstation's different policy.
        .env("IMPRESS_VERB_POLICY", "review-agent-destructive");
}

/// Small HTTP/1.1 client for an owned loopback server. This test deliberately
/// adds no HTTP dev dependency or proxy configuration to the MCP crate.
fn http_json(
    port: u16,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&Value>,
) -> (u16, Value) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("connect owned MCP host");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let payload = body.map(Value::to_string).unwrap_or_default();
    let authorization = token
        .map(|token| format!("Authorization: Bearer {token}\r\n"))
        .unwrap_or_default();
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{authorization}\r\n{payload}",
        payload.len()
    );
    stream
        .write_all(request.as_bytes())
        .expect("send owned MCP request");
    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .expect("read owned MCP response");
    let split = response
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("HTTP header boundary");
    let head = std::str::from_utf8(&response[..split]).expect("UTF-8 HTTP headers");
    let status = head
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse::<u16>()
        .unwrap();
    assert!(
        !head
            .to_ascii_lowercase()
            .contains("transfer-encoding: chunked"),
        "unexpected chunked response"
    );
    let body = &response[split + 4..];
    let value = if body.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(body).expect("JSON HTTP body")
    };
    (status, value)
}

fn mcp(port: u16, token: &str, id: u64, method: &str, params: Value) -> Value {
    let (status, response) = http_json(
        port,
        "POST",
        "/mcp",
        Some(token),
        Some(&json!({"jsonrpc":"2.0", "id":id, "method":method, "params":params})),
    );
    assert_eq!(status, 200, "MCP HTTP response: {response}");
    assert!(
        response.get("error").is_none(),
        "MCP JSON-RPC error: {response}"
    );
    response
}

fn wait_for_host(port: u16, host: &mut OwnedChild, log: &Path) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        assert!(
            host.alive(),
            "MCP host exited: {}",
            fs::read_to_string(log).unwrap_or_default()
        );
        if TcpStream::connect_timeout(
            &format!("127.0.0.1:{port}").parse().unwrap(),
            Duration::from_millis(100),
        )
        .is_ok()
        {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!(
        "scratch MCP host did not listen: {}",
        fs::read_to_string(log).unwrap_or_default()
    );
}

fn wait_for_provider_registration(
    port: u16,
    token: &str,
    provider: &mut OwnedChild,
    token_file: &Path,
    log: &Path,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        assert!(
            provider.alive(),
            "Python provider exited: {}",
            fs::read_to_string(log).unwrap_or_default()
        );
        if token_file.exists() {
            let listed = mcp(port, token, 1, "tools/list", json!({}));
            if listed["result"]["tools"]
                .as_array()
                .is_some_and(|tools| tools.iter().any(|tool| tool["name"] == VERB))
            {
                return listed;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!(
        "scratch Python provider did not register: {}",
        fs::read_to_string(log).unwrap_or_default()
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "starts only owned scratch MCP and Python-provider subprocesses"]
async fn reference_python_provider_registers_reviews_runs_and_becomes_unavailable() {
    let scratch = tempfile::tempdir().expect("owned scratch directory");
    let root = scratch.path();
    let workspace = root.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let store = workspace.join("impress.sqlite");
    let host_token_file = root.join("host-token");
    let provider_token_file = root.join("provider-token");
    let host_token = format!(
        "codex-p8-owned-host-token-{}-{}",
        std::process::id(),
        free_loopback_port()
    );
    private_file(&host_token_file, &host_token);
    let host_port = free_loopback_port();
    let device = format!("codex-p8-{}-{host_port}", std::process::id());
    let host_log = root.join("mcp-host.log");
    let mut host_command = Command::new(env!("CARGO_BIN_EXE_impress-mcp"));
    host_command
        .arg("--http")
        .arg(format!("127.0.0.1:{host_port}"))
        .arg("--token-file")
        .arg(&host_token_file)
        .arg("--store-path")
        .arg(&store)
        .stdout(Stdio::from(File::create(&host_log).unwrap()))
        .stderr(Stdio::from(
            OpenOptions::new().append(true).open(&host_log).unwrap(),
        ));
    scratch_env(&mut host_command, root, &store, &workspace, &device);
    let mut host = OwnedChild(host_command.spawn().expect("start owned MCP host"));
    wait_for_host(host_port, &mut host, &host_log);

    let provider_log = root.join("python-provider.log");
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/runtime-provider.py");
    let mut provider_command = Command::new("python3");
    provider_command
        .arg(&script)
        .arg("--host")
        .arg(format!("http://127.0.0.1:{host_port}"))
        .arg("--host-token-file")
        .arg(&host_token_file)
        .arg("--token-file")
        .arg(&provider_token_file)
        .arg("--port")
        .arg("0")
        .stdout(Stdio::from(File::create(&provider_log).unwrap()))
        .stderr(Stdio::from(
            OpenOptions::new().append(true).open(&provider_log).unwrap(),
        ));
    scratch_env(&mut provider_command, root, &store, &workspace, &device);
    let mut provider = OwnedChild(
        provider_command
            .spawn()
            .expect("start owned reference provider"),
    );
    let listed = wait_for_provider_registration(
        host_port,
        &host_token,
        &mut provider,
        &provider_token_file,
        &provider_log,
    );
    let tool = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tool| tool["name"] == VERB)
        .unwrap();
    assert_eq!(tool["inputSchema"]["required"], json!(["text"]));
    assert_eq!(
        tool["annotations"]["readOnlyHint"], false,
        "untrusted provider must advertise effective external safety"
    );

    let catalogue = mcp(
        host_port,
        &host_token,
        2,
        "tools/call",
        json!({
            "name":"capabilities-service_list-verbs",
            "arguments":{"search":VERB}
        }),
    );
    let entries = catalogue["result"]["structuredContent"]["verbs"]
        .as_array()
        .expect("catalogue verb entries");
    let entry = entries
        .iter()
        .find(|entry| entry["name"] == VERB)
        .expect("provider in generated catalogue");
    assert_eq!(entry["provider_id"], PROVIDER_ID);
    assert_eq!(entry["source"], "provider");
    assert_eq!(entry["declared_safety"], "read_only");
    assert_eq!(entry["effective_safety"], "external");

    let untrusted = mcp(
        host_port,
        &host_token,
        3,
        "tools/call",
        json!({
            "name":VERB, "arguments":{"text":"hello"}
        }),
    );
    assert_eq!(
        untrusted["result"]["isError"], true,
        "untrusted call must not execute"
    );
    assert_eq!(
        untrusted["result"]["structuredContent"]["code"],
        "review-pending"
    );

    // This isolated fixture represents a person's review decision. There is
    // intentionally no HTTP trust route for the agent/provider credentials.
    std::env::set_var("IMPRESS_STORE_PATH", &store);
    std::env::set_var("IMPRESS_WORKSPACE", &workspace);
    std::env::set_var("IMPRESS_DEVICE_ID", &device);
    for app in ["IMBIB", "IMPRINT", "IMPLORE", "IMPART"] {
        std::env::set_var(format!("{app}_BACKEND"), "off");
    }
    impress_capabilities::force_link();
    impress_app_transport::install(false);
    impress_store_service::set_store_path(&store)
        .expect("select exact scratch store in test process");
    let registry = impress_store_service::providers::install_for_selected_store(Arc::new(
        impress_app_transport::provider::JsonSchemaValidator,
    ))
    .expect("reload persisted scratch provider with real validator");
    let restored = registry.find(VERB).expect("restored provider retained");
    assert_eq!(
        restored.provider_status(),
        Some(impress_service_core::ProviderStatus::Unavailable)
    );
    registry_runtime::refresh_health().await;
    assert_eq!(
        registry.find(VERB).unwrap().provider_status(),
        Some(impress_service_core::ProviderStatus::Available)
    );
    registry
        .set_trusted(PROVIDER_ID, true)
        .expect("isolated person-review fixture");
    let trusted = registry.find(VERB).unwrap();
    assert_eq!(trusted.safety().class.as_str(), "read_only");
    let docs = impress_capabilities::verb_docs::render(registry.descriptors());
    let page = docs
        .pages
        .get("python-reference-service")
        .expect("provider reference page");
    assert!(page.contains(VERB) && page.contains("provider `python-reference`"));
    assert!(docs.index.contains("python-reference-service.md"));

    let examples = run_provider_examples(&trusted)
        .await
        .expect("provider Tier B runner");
    assert_eq!(
        examples.len(),
        1,
        "the reference provider declares one example"
    );
    assert!(
        matches!(&examples[0].outcome, Outcome::Passed { result } if result["echo"] == "hello"),
        "real Python example failed: {examples:?}"
    );

    provider.stop();
    registry_runtime::refresh_health().await;
    let unavailable = registry
        .find(VERB)
        .expect("departed provider stays in catalogue");
    assert_eq!(
        unavailable.provider_status(),
        Some(impress_service_core::ProviderStatus::Unavailable)
    );
    let refusal = impress_service_core::call::call_async_as(
        VERB,
        impress_service_core::pipeline::CallerIdentity::agent("tier-b-departed-provider"),
        json!({"text":"after shutdown"}),
    )
    .await
    .expect("pipeline returns a named refusal value");
    assert_eq!(refusal["code"], "host-unavailable");
    assert!(refusal["message"].as_str().unwrap().contains(PROVIDER_ID));
    host.stop();
}
