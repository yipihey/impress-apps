//! HTTP endpoint handlers

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use impel_core::coordination::Command;
use impel_core::event::{EntityType, Event, EventPayload};
use impel_core::thread::{Thread, ThreadId, ThreadState};

use crate::AppState;

/// Response for available threads
#[derive(Debug, Serialize)]
pub struct AvailableThreadsResponse {
    pub threads: Vec<ThreadSummary>,
}

/// Summary of a thread for listing
#[derive(Debug, Serialize)]
pub struct ThreadSummary {
    pub id: String,
    pub title: String,
    pub state: String,
    pub temperature: f64,
    pub claimed_by: Option<String>,
}

/// Get available threads (unclaimed, claimable)
pub async fn get_available_threads(
    State(state): State<Arc<AppState>>,
) -> Json<AvailableThreadsResponse> {
    let coord = state.coordination.read().await;
    let threads: Vec<ThreadSummary> = coord
        .available_threads()
        .map(|t| ThreadSummary {
            id: t.id.to_string(),
            title: t.metadata.title.clone(),
            state: t.state.to_string(),
            temperature: t.temperature.value(),
            claimed_by: t.claimed_by.clone(),
        })
        .collect();

    Json(AvailableThreadsResponse { threads })
}

/// Get a specific thread
pub async fn get_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<ThreadSummary>, StatusCode> {
    let coord = state.coordination.read().await;

    coord
        .get_thread(&id)
        .map(|t| {
            Json(ThreadSummary {
                id: t.id.to_string(),
                title: t.metadata.title.clone(),
                state: t.state.to_string(),
                temperature: t.temperature.value(),
                claimed_by: t.claimed_by.clone(),
            })
        })
        .ok_or(StatusCode::NOT_FOUND)
}

/// Request to claim a thread
#[derive(Debug, Deserialize)]
pub struct ClaimRequest {
    pub agent_id: String,
}

/// Claim a thread for an agent
pub async fn claim_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ClaimRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::ClaimThread {
        thread_id,
        agent_id: request.agent_id.clone(),
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "claimed_by": request.agent_id
    })))
}

/// Request to submit an event
#[derive(Debug, Deserialize)]
pub struct SubmitEventRequest {
    pub entity_id: String,
    pub entity_type: String,
    pub payload: serde_json::Value,
    pub actor_id: Option<String>,
}

/// Submit an event
pub async fn submit_event(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SubmitEventRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let entity_type = match request.entity_type.as_str() {
        "thread" => EntityType::Thread,
        "agent" => EntityType::Agent,
        "message" => EntityType::Message,
        "escalation" => EntityType::Escalation,
        "artifact" => EntityType::Artifact,
        "system" => EntityType::System,
        _ => return Err((StatusCode::BAD_REQUEST, "Invalid entity type".to_string())),
    };

    // Parse payload into EventPayload
    // For simplicity, we'll support a subset of events via JSON
    let payload: EventPayload = serde_json::from_value(request.payload)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid payload: {}", e)))?;

    let mut event = Event::new(request.entity_id, entity_type, payload);
    if let Some(actor) = request.actor_id {
        event = event.with_actor(actor);
    }

    let mut coord = state.coordination.write().await;
    let event = coord
        .apply_event(event)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "event_id": event.id.to_string(),
        "sequence": event.sequence
    })))
}

/// Request to get events
#[derive(Debug, Deserialize)]
pub struct GetEventsQuery {
    pub since: Option<u64>,
    pub limit: Option<usize>,
}

/// Get events
pub async fn get_events(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let coord = state.coordination.read().await;
    let events: Vec<_> = coord
        .all_events()
        .iter()
        .take(100) // Limit for now
        .map(|e| {
            serde_json::json!({
                "id": e.id.to_string(),
                "sequence": e.sequence,
                "timestamp": e.timestamp.to_rfc3339(),
                "entity_id": e.entity_id,
                "entity_type": e.entity_type.to_string(),
                "description": e.payload.description()
            })
        })
        .collect();

    Json(serde_json::json!({
        "events": events,
        "count": events.len()
    }))
}

/// Get the project constitution
pub async fn get_constitution() -> Json<serde_json::Value> {
    // TODO: Load from .impel/constitution/constitution.md
    Json(serde_json::json!({
        "title": "Project Constitution",
        "content": "# Constitution\n\nThis project aims to produce high-quality research...",
        "quality_standards": [
            "All code must have tests",
            "All claims must have citations",
            "All data must have provenance"
        ]
    }))
}

/// Get system status
pub async fn get_status(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let coord = state.coordination.read().await;

    let thread_count = coord.threads().count();
    let active_count = coord.threads_by_state(ThreadState::Active).count();
    let agent_count = coord.agents().count();
    let escalation_count = coord.open_escalations().len();

    Json(serde_json::json!({
        "paused": coord.is_paused(),
        "threads": {
            "total": thread_count,
            "active": active_count
        },
        "agents": {
            "total": agent_count
        },
        "escalations": {
            "open": escalation_count
        },
        "event_sequence": coord.current_sequence()
    }))
}
