//! Authenticated HTTP adapter for native Impart clients and Tailscale Serve.
//!
//! Mutations enqueue durable graph work. The NDJSON endpoint streams changes
//! from that durable task rather than creating a second conversation authority.

use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::header::{AUTHORIZATION, CACHE_CONTROL, CONTENT_SECURITY_POLICY, CONTENT_TYPE};
use axum::http::{HeaderMap, HeaderValue, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use impress_ai::{
    AiStore, BlobStore, ConversationDraft, InferenceProvider, MessageDraft, OmlxClient, ToolPolicy,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use uuid::Uuid;

const WEB_INDEX: &str = include_str!("../web/index.html");
const WEB_CSS: &str = include_str!("../web/app.css");
const WEB_JAVASCRIPT: &str = include_str!("../web/app.js");
const WEB_MATHJAX_CONFIG: &str = include_str!("../web/mathjax-config.js");
const WEB_MATHJAX: &str = include_str!("../web/vendor/mathjax/tex-svg-full.js");
const WEB_MANIFEST: &str = include_str!("../web/site.webmanifest");
const WEB_VW_MANIFEST: &str = include_str!("../web/vw-site.webmanifest");
const PAIRING_TICKET_TTL: Duration = Duration::from_secs(15 * 60);
const MAX_ACTIVE_PAIRING_TICKETS: usize = 8;

#[derive(Clone)]
pub struct AiHttpState {
    pub ai: Arc<AiStore>,
    pub provider: Arc<dyn InferenceProvider>,
    pub blobs: Arc<dyn BlobStore>,
    access_token: Arc<str>,
    pairing_tickets: Arc<Mutex<HashMap<[u8; 32], Instant>>>,
    /// Maintenance telemetry shared with the hygiene loop (`main.rs`).
    /// Defaults to an unwired instance so tests and embedded uses need no
    /// ceremony; the daemon attaches a real one via `with_maintenance`.
    pub maintenance: Arc<MaintenanceState>,
}

/// The daemon's maintenance telemetry: a capped in-memory log (the daemon's
/// stderr goes to /dev/null under launchd — this is how the suite's
/// console-first debugging reaches it) plus the last outcome of each hygiene
/// verb, served by `/api/health` and `/api/logs`.
pub struct MaintenanceState {
    /// Path of the shared store; empty when unwired (tests).
    pub store_path: std::path::PathBuf,
    entries: Mutex<std::collections::VecDeque<MaintenanceLogEntry>>,
    status: Mutex<MaintenanceStatus>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct MaintenanceLogEntry {
    pub at_ms: i64,
    pub message: String,
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct MaintenanceStatus {
    /// Whether THIS process held the maintenance lease on its last cycle.
    pub lease_owner: bool,
    pub last_checkpoint_ms: Option<i64>,
    pub last_checkpoint_completed: Option<bool>,
    pub last_checkpoint_frames: Option<u64>,
    pub last_compaction_ms: Option<i64>,
    pub last_compaction_removed: Option<u64>,
    pub last_demotion_ms: Option<i64>,
    pub last_demotion_count: Option<u64>,
    pub last_vacuum_ms: Option<i64>,
}

const MAINTENANCE_LOG_CAP: usize = 500;

impl MaintenanceState {
    pub fn new(store_path: std::path::PathBuf) -> Arc<Self> {
        Arc::new(Self {
            store_path,
            entries: Mutex::new(std::collections::VecDeque::new()),
            status: Mutex::new(MaintenanceStatus::default()),
        })
    }

    fn unwired() -> Arc<Self> {
        Self::new(std::path::PathBuf::new())
    }

    /// Log to stderr AND the in-memory ring (capped).
    pub fn log(&self, message: impl Into<String>) {
        let message = message.into();
        eprintln!("impress-ai-server: {message}");
        if let Ok(mut entries) = self.entries.lock() {
            if entries.len() >= MAINTENANCE_LOG_CAP {
                entries.pop_front();
            }
            entries.push_back(MaintenanceLogEntry {
                at_ms: chrono::Utc::now().timestamp_millis(),
                message,
            });
        }
    }

    pub fn update_status(&self, apply: impl FnOnce(&mut MaintenanceStatus)) {
        if let Ok(mut status) = self.status.lock() {
            apply(&mut status);
        }
    }

    pub fn status_snapshot(&self) -> MaintenanceStatus {
        self.status.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn recent_entries(&self, limit: usize) -> Vec<MaintenanceLogEntry> {
        self.entries
            .lock()
            .map(|entries| {
                entries
                    .iter()
                    .rev()
                    .take(limit)
                    .cloned()
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl AiHttpState {
    pub fn new(
        ai: Arc<AiStore>,
        omlx: OmlxClient,
        blobs: Arc<dyn BlobStore>,
        access_token: impl Into<String>,
    ) -> Result<Self, String> {
        Self::with_provider(ai, Arc::new(omlx), blobs, access_token)
    }

    pub fn with_provider(
        ai: Arc<AiStore>,
        provider: Arc<dyn InferenceProvider>,
        blobs: Arc<dyn BlobStore>,
        access_token: impl Into<String>,
    ) -> Result<Self, String> {
        let access_token = access_token.into();
        if access_token.len() < 24 {
            return Err("AI HTTP access token must contain at least 24 characters".into());
        }
        Ok(Self {
            ai,
            provider,
            blobs,
            access_token: access_token.into(),
            pairing_tickets: Arc::new(Mutex::new(HashMap::new())),
            maintenance: MaintenanceState::unwired(),
        })
    }

    /// Attach the daemon's maintenance telemetry (store path + shared log).
    pub fn with_maintenance(mut self, maintenance: Arc<MaintenanceState>) -> Self {
        self.maintenance = maintenance;
        self
    }

    fn issue_pairing_ticket(&self, ttl: Duration) -> Result<String, String> {
        let ticket = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let expiry = Instant::now() + ttl;
        let mut tickets = self
            .pairing_tickets
            .lock()
            .map_err(|_| "pairing ticket store is unavailable".to_string())?;
        let now = Instant::now();
        tickets.retain(|_, expires_at| *expires_at > now);
        if tickets.len() >= MAX_ACTIVE_PAIRING_TICKETS {
            if let Some(oldest) = tickets
                .iter()
                .min_by_key(|(_, expires_at)| **expires_at)
                .map(|(digest, _)| *digest)
            {
                tickets.remove(&oldest);
            }
        }
        tickets.insert(pairing_ticket_digest(&ticket), expiry);
        Ok(ticket)
    }

    fn redeem_pairing_ticket(&self, ticket: &str) -> Result<Arc<str>, ()> {
        if ticket.len() != 64 || !ticket.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(());
        }
        let digest = pairing_ticket_digest(ticket);
        let now = Instant::now();
        let mut tickets = self.pairing_tickets.lock().map_err(|_| ())?;
        tickets.retain(|_, expires_at| *expires_at > now);
        tickets
            .remove(&digest)
            .filter(|expires_at| *expires_at > now)
            .map(|_| self.access_token.clone())
            .ok_or(())
    }
}

fn pairing_ticket_digest(ticket: &str) -> [u8; 32] {
    Sha256::digest(ticket.as_bytes()).into()
}

pub fn router(state: AiHttpState) -> Router {
    let api = Router::new()
        .route("/api/status", get(status))
        .route("/api/models", get(models))
        .route("/api/pairing-tickets", post(create_pairing_ticket))
        .route(
            "/api/conversations",
            get(list_conversations).post(create_conversation),
        )
        .route(
            "/api/conversations/{id}",
            get(conversation).patch(update_conversation),
        )
        .route(
            "/api/conversations/{id}/title-suggestion",
            post(queue_title_suggestion),
        )
        .route("/api/conversations/{id}/messages", post(queue_message))
        .route("/api/blobs", post(upload_blob))
        .route("/api/tasks/{id}", get(task_progress))
        .route("/api/tasks/{id}/events", get(task_events))
        .route("/api/logs", get(maintenance_logs))
        .layer(DefaultBodyLimit::max(8 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), authorize));

    Router::new()
        .route("/", get(web_index))
        .route("/index.html", get(web_index))
        .route("/vw", get(web_index))
        .route("/vw/", get(web_index))
        .route("/app.css", get(web_css))
        .route("/app.js", get(web_javascript))
        .route("/mathjax-config.js", get(web_mathjax_config))
        .route("/vendor/mathjax/tex-svg-full.js", get(web_mathjax))
        .route("/site.webmanifest", get(web_manifest))
        .route("/vw/site.webmanifest", get(web_vw_manifest))
        .route("/api/pair", post(redeem_pairing_ticket))
        // Deliberately unauthenticated, like /api/pair: sizes and outcome
        // timestamps only — no ids, no content — so health probes (selftest,
        // sibling consoles) need no bearer.
        .route("/api/health", get(health))
        .merge(api)
        .layer(middleware::from_fn(secure_headers))
        .with_state(state)
}

async fn web_index() -> Response {
    static_response(WEB_INDEX, "text/html; charset=utf-8")
}

async fn web_css() -> Response {
    static_response(WEB_CSS, "text/css; charset=utf-8")
}

async fn web_javascript() -> Response {
    static_response(WEB_JAVASCRIPT, "text/javascript; charset=utf-8")
}

async fn web_mathjax_config() -> Response {
    static_response(WEB_MATHJAX_CONFIG, "text/javascript; charset=utf-8")
}

async fn web_mathjax() -> Response {
    static_response(WEB_MATHJAX, "text/javascript; charset=utf-8")
}

async fn web_manifest() -> Response {
    static_response(WEB_MANIFEST, "application/manifest+json")
}

async fn web_vw_manifest() -> Response {
    static_response(WEB_VW_MANIFEST, "application/manifest+json")
}

fn static_response(value: &'static str, content_type: &'static str) -> Response {
    (
        [(CONTENT_TYPE, HeaderValue::from_static(content_type))],
        value,
    )
        .into_response()
}

async fn secure_headers(request: Request<Body>, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert("x-frame-options", HeaderValue::from_static("DENY"));
    headers.insert(
        CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        ),
    );
    response
}

async fn authorize(
    State(state): State<AiHttpState>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let supplied = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if supplied
        .is_some_and(|token| constant_time_eq(token.as_bytes(), state.access_token.as_bytes()))
    {
        Ok(next.run(request).await)
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

async fn status() -> Json<Value> {
    Json(json!({ "service": "impress-ai", "status": "ok", "storage": "impress-item-graph" }))
}

/// GET /api/health — store hygiene at a glance: file sizes, freelist, and
/// the last outcome of each maintenance verb. Unauthenticated by design
/// (see the route comment); everything here is a size or a timestamp.
async fn health(
    State(state): State<AiHttpState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    let maintenance = state.maintenance.clone();
    let store_path = maintenance.store_path.clone();
    let (db_bytes, wal_bytes) = if store_path.as_os_str().is_empty() {
        (0, 0)
    } else {
        let wal_path = {
            let mut os = store_path.as_os_str().to_os_string();
            os.push("-wal");
            std::path::PathBuf::from(os)
        };
        (
            std::fs::metadata(&store_path).map(|m| m.len()).unwrap_or(0),
            std::fs::metadata(&wal_path).map(|m| m.len()).unwrap_or(0),
        )
    };
    // ?ops_window_minutes=N narrows the churn probes from their 24h default —
    // "is it STILL happening" needs a tight window, not a daily average.
    let window_minutes: i64 = query
        .get("ops_window_minutes")
        .and_then(|value| value.parse().ok())
        .filter(|m| *m > 0)
        .unwrap_or(24 * 60);
    let ai = state.ai.clone();
    let (freelist, ops_last_24h, ops_by_author, ops_by_target, manuscript_change_chunks) =
        tokio::task::spawn_blocking(move || {
            let store = ai.shared_store();
            let since = chrono::Utc::now().timestamp_millis() - window_minutes * 60 * 1000;
            (
                store.freelist_pages().unwrap_or(0),
                store.ops_minted_since(since).unwrap_or(0),
                store
                    .ops_minted_since_by_author(since, 8)
                    .unwrap_or_default(),
                store
                    .ops_minted_since_by_target_schema(since, 8)
                    .unwrap_or_default(),
                // ADR-0027 D3: chunk volume is a measured number. Inserts mint
                // no ops, so it needs its own line here.
                store
                    .count_items_of_schema(impress_core::schemas::MANUSCRIPT_CHANGE_SCHEMA_REF)
                    .unwrap_or(0),
            )
        })
        .await
        .unwrap_or((0, 0, Vec::new(), Vec::new(), 0));
    let ops_by_author: Vec<Value> = ops_by_author
        .into_iter()
        .map(|(author, kind, n)| json!({"author": author, "author_kind": kind, "ops": n}))
        .collect();
    let ops_by_target: Vec<Value> = ops_by_target
        .into_iter()
        .map(|(schema, n)| json!({"target_schema": schema, "ops": n}))
        .collect();
    Json(json!({
        "status": "ok",
        "db_bytes": db_bytes,
        "wal_bytes": wal_bytes,
        "wal_budget_bytes": impress_core::sqlite_store::SqliteItemStore::WAL_SIZE_BUDGET_BYTES,
        "freelist_pages": freelist,
        "ops_window_minutes": window_minutes,
        "ops_last_24h": ops_last_24h,
        "ops_last_24h_by_author": ops_by_author,
        "ops_by_target_schema": ops_by_target,
        "manuscript_change_chunks": manuscript_change_chunks,
        "maintenance": state.maintenance.status_snapshot(),
    }))
}

/// GET /api/logs?limit=N — the maintenance log ring, oldest first.
async fn maintenance_logs(
    State(state): State<AiHttpState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    let limit = query
        .get("limit")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(100)
        .min(MAINTENANCE_LOG_CAP);
    let entries = state.maintenance.recent_entries(limit);
    Json(json!({ "status": "ok", "count": entries.len(), "entries": entries }))
}

async fn create_pairing_ticket(
    State(state): State<AiHttpState>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let ticket = state
        .issue_pairing_ticket(PAIRING_TICKET_TTL)
        .map_err(ApiError::internal)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "ticket": ticket,
            "expires_in_seconds": PAIRING_TICKET_TTL.as_secs(),
            "single_use": true
        })),
    ))
}

#[derive(Debug, Deserialize)]
struct RedeemPairingTicketRequest {
    ticket: String,
}

async fn redeem_pairing_ticket(
    State(state): State<AiHttpState>,
    Json(input): Json<RedeemPairingTicketRequest>,
) -> ApiResult<Json<Value>> {
    let access_token = state
        .redeem_pairing_ticket(&input.ticket)
        .map_err(|_| ApiError::unauthorized("pairing link is invalid, expired, or already used"))?;
    Ok(Json(json!({ "access_token": access_token.as_ref() })))
}

async fn models(State(state): State<AiHttpState>) -> ApiResult<Json<Value>> {
    let models = state.provider.models().await.map_err(ApiError::from)?;
    Ok(Json(json!({ "models": models })))
}

async fn list_conversations(State(state): State<AiHttpState>) -> ApiResult<Json<Value>> {
    let rows = blocking(move || state.ai.conversation_rows(false)).await?;
    Ok(Json(json!({ "conversations": rows })))
}

#[derive(Debug, Deserialize)]
struct CreateConversationRequest {
    title: Option<String>,
    summary: Option<String>,
    system_prompt: Option<String>,
    provider: Option<String>,
    model: String,
    temperature: Option<f32>,
    max_tokens: Option<u32>,
    thinking: Option<bool>,
    web_access: Option<bool>,
    #[serde(default)]
    enabled_tools: Vec<String>,
}

async fn create_conversation(
    State(state): State<AiHttpState>,
    Json(input): Json<CreateConversationRequest>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let mut draft = ConversationDraft::default();
    draft.title = input.title.unwrap_or(draft.title);
    draft.summary = input.summary;
    if input.system_prompt.is_some() {
        draft.system_prompt = input.system_prompt;
    }
    draft.provider = input.provider.unwrap_or(draft.provider);
    draft.model = input.model;
    draft.temperature = input.temperature.unwrap_or(draft.temperature);
    draft.max_tokens = input.max_tokens.unwrap_or(draft.max_tokens);
    draft.thinking = input.thinking.unwrap_or(draft.thinking);
    draft.web_access = input.web_access.unwrap_or(false);
    if draft.web_access && !input.enabled_tools.iter().any(|tool| tool == "web") {
        draft.tool_policy.enabled.push("web".into());
    }
    draft.tool_policy.enabled.extend(input.enabled_tools);
    draft.tool_policy = ToolPolicy {
        enabled: draft.tool_policy.enabled,
    }
    .normalized();
    let id = blocking(move || state.ai.create_conversation(draft)).await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": id }))))
}

async fn conversation(
    State(state): State<AiHttpState>,
    Path(id): Path<Uuid>,
) -> ApiResult<Json<Value>> {
    let view = blocking(move || state.ai.conversation_view(id)).await?;
    Ok(Json(json!({ "view": view })))
}

#[derive(Debug, Deserialize)]
struct UpdateConversationRequest {
    title: Option<String>,
    model: Option<String>,
    enabled_tools: Option<Vec<String>>,
}

async fn update_conversation(
    State(state): State<AiHttpState>,
    Path(id): Path<Uuid>,
    Json(input): Json<UpdateConversationRequest>,
) -> ApiResult<Json<Value>> {
    if input.title.is_none() && input.model.is_none() && input.enabled_tools.is_none() {
        return Err(ApiError::bad_request(
            "provide title, model, or enabled_tools to update a conversation",
        ));
    }
    let ai = state.ai.clone();
    blocking(move || {
        if let Some(title) = input.title {
            ai.set_conversation_title(id, title)?;
        }
        if let Some(model) = input.model {
            ai.set_conversation_model(id, model)?;
        }
        if let Some(enabled_tools) = input.enabled_tools {
            ai.set_tool_policy(
                id,
                ToolPolicy {
                    enabled: enabled_tools,
                },
            )?;
        }
        Ok(())
    })
    .await?;
    let view = blocking(move || state.ai.conversation_view(id)).await?;
    Ok(Json(json!({ "view": view })))
}

async fn queue_title_suggestion(
    State(state): State<AiHttpState>,
    Path(conversation_id): Path<Uuid>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let task_id = blocking(move || state.ai.queue_title_suggestion(conversation_id)).await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({
            "conversation_id": conversation_id,
            "task_id": task_id,
            "events": format!("/api/tasks/{task_id}/events")
        })),
    ))
}

#[derive(Debug, Deserialize)]
struct QueueMessageRequest {
    body: String,
    #[serde(default)]
    attachment_ids: Vec<Uuid>,
}

async fn queue_message(
    State(state): State<AiHttpState>,
    Path(conversation_id): Path<Uuid>,
    Json(input): Json<QueueMessageRequest>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let mut message = MessageDraft::user(input.body);
    message.attachment_ids = input.attachment_ids;
    let queued = blocking(move || state.ai.queue_user_turn(conversation_id, message)).await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({
            "conversation_id": queued.conversation_id,
            "message_id": queued.message_id,
            "task_id": queued.task_id,
            "events": format!("/api/tasks/{}/events", queued.task_id)
        })),
    ))
}

async fn upload_blob(
    State(state): State<AiHttpState>,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let mime_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();
    let file_name = headers
        .get("x-impress-file-name")
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);
    let ai = state.ai.clone();
    let blobs = state.blobs.clone();
    let attachment =
        blocking(move || ai.ingest_blob(blobs.as_ref(), &body, mime_type, file_name)).await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "attachment": attachment })),
    ))
}

async fn task_progress(
    State(state): State<AiHttpState>,
    Path(id): Path<Uuid>,
) -> ApiResult<Json<Value>> {
    let progress = blocking(move || state.ai.task_progress(id)).await?;
    Ok(Json(json!({ "task": progress })))
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum TaskEvent {
    Progress { task: impress_ai::TaskProgress },
    Timeout { task_id: Uuid },
    Error { message: String },
}

async fn task_events(State(state): State<AiHttpState>, Path(id): Path<Uuid>) -> Response {
    let (sender, receiver) = mpsc::channel::<Result<Bytes, Infallible>>(16);
    tokio::spawn(async move {
        let mut previous: Option<String> = None;
        for _ in 0..1_800 {
            let ai = state.ai.clone();
            let progress = blocking(move || ai.task_progress(id)).await;
            match progress {
                Ok(progress) => {
                    let terminal = progress.response_message_id.is_some()
                        || matches!(progress.state.as_str(), "done" | "failed" | "cancelled");
                    let encoded = serde_json::to_string(&TaskEvent::Progress {
                        task: progress.clone(),
                    })
                    .unwrap_or_else(|error| {
                        serde_json::to_string(&TaskEvent::Error {
                            message: error.to_string(),
                        })
                        .unwrap_or_default()
                    });
                    if previous.as_deref() != Some(encoded.as_str()) {
                        if sender
                            .send(Ok(Bytes::from(format!("{encoded}\n"))))
                            .await
                            .is_err()
                        {
                            return;
                        }
                        previous = Some(encoded);
                    }
                    if terminal {
                        return;
                    }
                }
                Err(error) => {
                    let encoded = serde_json::to_string(&TaskEvent::Error {
                        message: error.message,
                    })
                    .unwrap_or_default();
                    let _ = sender.send(Ok(Bytes::from(format!("{encoded}\n")))).await;
                    return;
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        let encoded =
            serde_json::to_string(&TaskEvent::Timeout { task_id: id }).unwrap_or_default();
        let _ = sender.send(Ok(Bytes::from(format!("{encoded}\n")))).await;
    });
    Response::builder()
        .header(CONTENT_TYPE, "application/x-ndjson; charset=utf-8")
        .header("cache-control", "no-store")
        .body(Body::from_stream(ReceiverStream::new(receiver)))
        .expect("static NDJSON response headers are valid")
}

async fn blocking<T: Send + 'static>(
    operation: impl FnOnce() -> impress_ai::Result<T> + Send + 'static,
) -> ApiResult<T> {
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|error| ApiError::internal(error.to_string()))?
        .map_err(ApiError::from)
}

type ApiResult<T> = Result<T, ApiError>;

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }

    fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
        }
    }
}

impl From<impress_ai::Error> for ApiError {
    fn from(error: impress_ai::Error) -> Self {
        let status = match error {
            impress_ai::Error::Invalid(_) | impress_ai::Error::UnsupportedContent(_) => {
                StatusCode::BAD_REQUEST
            }
            impress_ai::Error::Store(ref message) if message.contains("does not exist") => {
                StatusCode::NOT_FOUND
            }
            impress_ai::Error::Omlx(_) | impress_ai::Error::Http(_) => StatusCode::BAD_GATEWAY,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        };
        Self {
            status,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "error": self.message }))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_ai::FileBlobStore;
    use impress_core::item::ActorKind;
    use tower::ServiceExt;

    #[test]
    fn token_comparison_requires_exact_bytes() {
        assert!(constant_time_eq(b"same", b"same"));
        assert!(!constant_time_eq(b"same", b"diff"));
        assert!(!constant_time_eq(b"short", b"longer"));
    }

    #[tokio::test]
    async fn router_rejects_missing_token_and_accepts_the_configured_one() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let blobs = Arc::new(FileBlobStore::open(directory.path().join("blobs")).unwrap());
        let omlx = OmlxClient::new("http://127.0.0.1:8000", None).unwrap();
        let state = AiHttpState::new(ai, omlx, blobs, "a-secure-token-with-24-chars").unwrap();
        let app = router(state);

        let unauthorized = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);

        let authorized = app
            .oneshot(
                Request::builder()
                    .uri("/api/status")
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(authorized.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn pairing_tickets_are_authenticated_expiring_and_single_use() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let blobs = Arc::new(FileBlobStore::open(directory.path().join("blobs")).unwrap());
        let omlx = OmlxClient::new("http://127.0.0.1:8000", None).unwrap();
        let state = AiHttpState::new(ai, omlx, blobs, "a-secure-token-with-24-chars").unwrap();
        let app = router(state.clone());

        let unauthorized_issue = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pairing-tickets")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthorized_issue.status(), StatusCode::UNAUTHORIZED);

        let issued = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pairing-tickets")
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(issued.status(), StatusCode::CREATED);
        let issued_body = axum::body::to_bytes(issued.into_body(), usize::MAX)
            .await
            .unwrap();
        let issued_json: Value = serde_json::from_slice(&issued_body).unwrap();
        let ticket = issued_json["ticket"].as_str().unwrap();
        assert_eq!(ticket.len(), 64);
        assert_eq!(issued_json["expires_in_seconds"], 15 * 60);
        assert_eq!(issued_json["single_use"], true);
        assert!(issued_json.get("access_token").is_none());

        let redeem = |ticket: &str| {
            Request::builder()
                .method("POST")
                .uri("/api/pair")
                .header(CONTENT_TYPE, "application/json")
                .body(Body::from(json!({ "ticket": ticket }).to_string()))
                .unwrap()
        };
        let redeemed = app.clone().oneshot(redeem(ticket)).await.unwrap();
        assert_eq!(redeemed.status(), StatusCode::OK);
        let redeemed_body = axum::body::to_bytes(redeemed.into_body(), usize::MAX)
            .await
            .unwrap();
        let redeemed_json: Value = serde_json::from_slice(&redeemed_body).unwrap();
        assert_eq!(
            redeemed_json["access_token"],
            "a-secure-token-with-24-chars"
        );

        let replayed = app.clone().oneshot(redeem(ticket)).await.unwrap();
        assert_eq!(replayed.status(), StatusCode::UNAUTHORIZED);

        let expired_ticket = state.issue_pairing_ticket(Duration::ZERO).unwrap();
        let expired = app.clone().oneshot(redeem(&expired_ticket)).await.unwrap();
        assert_eq!(expired.status(), StatusCode::UNAUTHORIZED);

        let authorized = app
            .oneshot(
                Request::builder()
                    .uri("/api/status")
                    .header(
                        AUTHORIZATION,
                        format!("Bearer {}", redeemed_json["access_token"].as_str().unwrap()),
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(authorized.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn browser_routes_write_display_ready_canonical_threads() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let blobs = Arc::new(FileBlobStore::open(directory.path().join("blobs")).unwrap());
        let omlx = OmlxClient::new("http://127.0.0.1:8000", None).unwrap();
        let state = AiHttpState::new(ai, omlx, blobs, "a-secure-token-with-24-chars").unwrap();
        let app = router(state);

        let index = app
            .clone()
            .oneshot(Request::builder().uri("/").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(index.status(), StatusCode::OK);
        let index_body = axum::body::to_bytes(index.into_body(), usize::MAX)
            .await
            .unwrap();
        assert!(String::from_utf8_lossy(&index_body).contains("Impart threads"));

        let vw_index = app
            .clone()
            .oneshot(Request::builder().uri("/vw").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(vw_index.status(), StatusCode::OK);

        let vw_manifest = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/vw/site.webmanifest")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(vw_manifest.status(), StatusCode::OK);
        let vw_manifest_body = axum::body::to_bytes(vw_manifest.into_body(), usize::MAX)
            .await
            .unwrap();
        assert!(String::from_utf8_lossy(&vw_manifest_body).contains("VW Type 2 Knowledge"));

        let app_javascript = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/app.js")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let app_javascript_body = axum::body::to_bytes(app_javascript.into_body(), usize::MAX)
            .await
            .unwrap();
        let app_javascript_text = String::from_utf8_lossy(&app_javascript_body);
        assert!(app_javascript_text.contains("enabledTools: [\"vw\"]"));
        assert!(app_javascript_text.contains("location.pathname === \"/vw\""));

        let math_config = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/mathjax-config.js")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(math_config.status(), StatusCode::OK);
        let math_config_body = axum::body::to_bytes(math_config.into_body(), usize::MAX)
            .await
            .unwrap();
        assert!(String::from_utf8_lossy(&math_config_body).contains("window.MathJax"));

        let mathjax = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/vendor/mathjax/tex-svg-full.js")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(mathjax.status(), StatusCode::OK);
        assert!(mathjax
            .headers()
            .get(CONTENT_TYPE)
            .is_some_and(|value| value == "text/javascript; charset=utf-8"));

        let created = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/conversations")
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        json!({
                            "title": "Browser thread",
                            "model": "local-model",
                            "web_access": true,
                            "enabled_tools": ["scix"]
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(created.status(), StatusCode::CREATED);
        let created_body = axum::body::to_bytes(created.into_body(), usize::MAX)
            .await
            .unwrap();
        let created_json: Value = serde_json::from_slice(&created_body).unwrap();
        let conversation_id = created_json["id"].as_str().unwrap();

        let updated = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri(format!("/api/conversations/{conversation_id}"))
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        json!({
                            "title": "Renamed browser thread",
                            "model": "second-model",
                            "enabled_tools": ["web", "impress-mcp"]
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(updated.status(), StatusCode::OK);

        let queued = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/conversations/{conversation_id}/messages"))
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        json!({ "body": "Hello from the web" }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(queued.status(), StatusCode::ACCEPTED);

        let title_suggestion = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!(
                        "/api/conversations/{conversation_id}/title-suggestion"
                    ))
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(title_suggestion.status(), StatusCode::ACCEPTED);

        let conversation = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/conversations/{conversation_id}"))
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let conversation_body = axum::body::to_bytes(conversation.into_body(), usize::MAX)
            .await
            .unwrap();
        let conversation_json: Value = serde_json::from_slice(&conversation_body).unwrap();
        assert_eq!(
            conversation_json["view"]["conversation"]["model"],
            "second-model"
        );
        assert_eq!(
            conversation_json["view"]["conversation"]["title"],
            "Renamed browser thread"
        );
        assert_eq!(
            conversation_json["view"]["conversation"]["enabled_tools"],
            json!(["impress-mcp", "web"])
        );
        assert_eq!(
            conversation_json["view"]["messages"][0]["body"],
            "Hello from the web"
        );
        assert_eq!(conversation_json["view"]["tasks"][0]["state"], "pending");

        let listed = app
            .oneshot(
                Request::builder()
                    .uri("/api/conversations")
                    .header(AUTHORIZATION, "Bearer a-secure-token-with-24-chars")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let listed_body = axum::body::to_bytes(listed.into_body(), usize::MAX)
            .await
            .unwrap();
        let listed_json: Value = serde_json::from_slice(&listed_body).unwrap();
        assert_eq!(
            listed_json["conversations"][0]["title"],
            "Renamed browser thread"
        );
        assert_eq!(listed_json["conversations"][0]["message_count"], 1);
    }
}
