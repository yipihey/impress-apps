//! HTTP-backed `ImpartService`, routing to the running impart app (port 23122).

use std::sync::Arc;
use std::time::Duration;

use impart_service::{
    register_backend, AppStatus, ConversationRecord, ImpartBackend, ImpartService, LogEntry,
    MessageRecord,
};
use serde::Deserialize;
use serde_json::{json, Value};
use url::Url;

const DEFAULT_BASE_URL: &str = "http://localhost:23122";

fn log_err(method: &str, e: impl std::fmt::Display) {
    eprintln!("[impart-service-http] {method}: {e}");
}

pub struct ImpartClient {
    base_url: Url,
    http: reqwest::Client,
}

impl ImpartClient {
    pub fn new() -> Self {
        Self::with_base_url(Url::parse(DEFAULT_BASE_URL).expect("default URL parses"))
    }

    pub fn with_base_url(base_url: Url) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest client builds");
        Self { base_url, http }
    }

    async fn get_text(&self, path: &str) -> Result<String, String> {
        let url = self.base_url.join(path).map_err(|e| e.to_string())?;
        self.http
            .get(url)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())
    }

    async fn get_json(&self, path: &str) -> Result<Value, String> {
        serde_json::from_str(&self.get_text(path).await?).map_err(|e| e.to_string())
    }

    async fn send_json(&self, method: &str, path: &str, body: Value) -> Result<Value, String> {
        let url = self.base_url.join(path).map_err(|e| e.to_string())?;
        let req = match method {
            "POST" => self.http.post(url),
            "PATCH" => self.http.patch(url),
            _ => self.http.post(url),
        };
        let text = req
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())?;
        serde_json::from_str(&text).map_err(|e| e.to_string())
    }

    async fn send_ok(&self, method: &str, path: &str, body: Value) -> Result<bool, String> {
        let url = self.base_url.join(path).map_err(|e| e.to_string())?;
        let req = match method {
            "PATCH" => self.http.patch(url),
            _ => self.http.post(url),
        };
        Ok(req
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .status()
            .is_success())
    }
}

impl Default for ImpartClient {
    fn default() -> Self {
        Self::new()
    }
}

fn array_field<T: for<'de> Deserialize<'de>>(v: &Value, keys: &[&str]) -> Vec<T> {
    for key in keys {
        if let Some(arr) = v.get(key) {
            if let Ok(parsed) = serde_json::from_value::<Vec<T>>(arr.clone()) {
                return parsed;
            }
        }
    }
    Vec::new()
}

fn object_field<T: for<'de> Deserialize<'de>>(v: &Value, keys: &[&str]) -> Option<T> {
    for key in keys {
        if let Some(obj) = v.get(key) {
            if let Ok(parsed) = serde_json::from_value::<T>(obj.clone()) {
                return Some(parsed);
            }
        }
    }
    None
}

pub struct HttpImpartService {
    client: Arc<ImpartClient>,
}

impl HttpImpartService {
    pub fn new(client: Arc<ImpartClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImpartService for HttpImpartService {
    async fn status(&self) -> AppStatus {
        match self.client.get_text("/api/status").await {
            Ok(detail) => AppStatus {
                running: true,
                detail,
            },
            Err(e) => {
                log_err("status", &e);
                AppStatus {
                    running: false,
                    detail: format!("impart did not answer: {e}"),
                }
            }
        }
    }

    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry> {
        let mut path = format!("/api/logs?limit={}", if limit == 0 { 50 } else { limit });
        if let Some(l) = level.as_deref().filter(|l| !l.is_empty()) {
            path.push_str(&format!("&level={}", urlencoding::encode(l)));
        }
        match self.client.get_json(&path).await {
            Ok(v) => {
                let nested = v.get("data").map(|d| array_field(d, &["entries"]));
                match nested {
                    Some(e) if !e.is_empty() => e,
                    _ => array_field(&v, &["entries", "logs"]),
                }
            }
            Err(e) => {
                log_err("get_logs", e);
                vec![]
            }
        }
    }

    async fn list_conversations(
        &self,
        limit: u32,
        include_archived: bool,
    ) -> Vec<ConversationRecord> {
        let path = format!(
            "/api/research/conversations?limit={}&includeArchived={}",
            if limit == 0 { 20 } else { limit },
            include_archived
        );
        match self.client.get_json(&path).await {
            Ok(v) => array_field(&v, &["conversations"]),
            Err(e) => {
                log_err("list_conversations", e);
                vec![]
            }
        }
    }

    async fn get_conversation(&self, conversation_id: String) -> Option<ConversationRecord> {
        let path = format!(
            "/api/research/conversations/{}",
            urlencoding::encode(&conversation_id)
        );
        match self.client.get_json(&path).await {
            Ok(v) => object_field(&v, &["conversation"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("get_conversation", e);
                None
            }
        }
    }

    async fn create_conversation(
        &self,
        title: String,
        summary: Option<String>,
    ) -> Option<ConversationRecord> {
        let body = json!({ "title": title, "summary": summary });
        match self
            .client
            .send_json("POST", "/api/research/conversations", body)
            .await
        {
            Ok(v) => object_field(&v, &["conversation"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("create_conversation", e);
                None
            }
        }
    }

    async fn update_conversation(
        &self,
        conversation_id: String,
        title: Option<String>,
        summary: Option<String>,
    ) -> bool {
        let path = format!(
            "/api/research/conversations/{}",
            urlencoding::encode(&conversation_id)
        );
        self.client
            .send_ok(
                "PATCH",
                &path,
                json!({ "title": title, "summary": summary }),
            )
            .await
            .unwrap_or_else(|e| {
                log_err("update_conversation", e);
                false
            })
    }

    async fn add_message(
        &self,
        conversation_id: String,
        content: String,
        role: Option<String>,
    ) -> Option<MessageRecord> {
        let path = format!(
            "/api/research/conversations/{}/messages",
            urlencoding::encode(&conversation_id)
        );
        match self
            .client
            .send_json("POST", &path, json!({ "content": content, "role": role }))
            .await
        {
            Ok(v) => object_field(&v, &["message"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("add_message", e);
                None
            }
        }
    }

    async fn record_decision(
        &self,
        conversation_id: String,
        decision: String,
        rationale: Option<String>,
    ) -> bool {
        let path = format!(
            "/api/research/conversations/{}/decisions",
            urlencoding::encode(&conversation_id)
        );
        self.client
            .send_ok(
                "POST",
                &path,
                json!({ "decision": decision, "rationale": rationale }),
            )
            .await
            .unwrap_or_else(|e| {
                log_err("record_decision", e);
                false
            })
    }

    async fn record_artifact(
        &self,
        conversation_id: String,
        title: String,
        kind: Option<String>,
        reference: Option<String>,
    ) -> bool {
        let path = format!(
            "/api/research/conversations/{}/artifacts",
            urlencoding::encode(&conversation_id)
        );
        self.client
            .send_ok(
                "POST",
                &path,
                json!({ "title": title, "kind": kind, "reference": reference }),
            )
            .await
            .unwrap_or_else(|e| {
                log_err("record_artifact", e);
                false
            })
    }

    async fn branch_conversation(
        &self,
        conversation_id: String,
        title: String,
    ) -> Option<ConversationRecord> {
        let path = format!(
            "/api/research/conversations/{}/branch",
            urlencoding::encode(&conversation_id)
        );
        match self
            .client
            .send_json("POST", &path, json!({ "title": title }))
            .await
        {
            Ok(v) => object_field(&v, &["conversation"]).or_else(|| serde_json::from_value(v).ok()),
            Err(e) => {
                log_err("branch_conversation", e);
                None
            }
        }
    }
}

pub struct HttpBackend {
    client: Arc<ImpartClient>,
}

impl HttpBackend {
    pub fn new(client: Arc<ImpartClient>) -> Self {
        Self { client }
    }
}

impl ImpartBackend for HttpBackend {
    fn service(&self) -> Arc<dyn ImpartService> {
        Arc::new(HttpImpartService::new(self.client.clone()))
    }
}

/// Probe impart and install the HTTP backend if it answers.
pub fn maybe_install_http_backend() -> bool {
    if std::env::var("IMPART_BACKEND").as_deref() == Ok("off") {
        eprintln!("[impart-service-http] IMPART_BACKEND=off — skipping probe");
        return false;
    }

    let base_url = std::env::var("IMPART_HTTP_URL")
        .ok()
        .and_then(|s| Url::parse(&s).ok())
        .unwrap_or_else(|| Url::parse(DEFAULT_BASE_URL).expect("default URL parses"));

    let client = Arc::new(ImpartClient::with_base_url(base_url));
    let reachable = block_on(async { client.get_text("/api/status").await.is_ok() });

    if reachable {
        eprintln!("[impart-service-http] impart reachable; using HTTP backend");
        register_backend(Box::new(HttpBackend::new(client)));
        true
    } else {
        eprintln!("[impart-service-http] impart unreachable; tools will refuse");
        false
    }
}

fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("current-thread runtime builds")
        .block_on(fut)
}
