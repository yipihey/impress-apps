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
use impel_core::persona::ToolAccess;
use impel_core::thread::{ThreadId, ThreadState};

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
    let persona_count = state.personas.count();

    Json(serde_json::json!({
        "paused": coord.is_paused(),
        "threads": {
            "total": thread_count,
            "active": active_count
        },
        "agents": {
            "total": agent_count
        },
        "personas": {
            "total": persona_count
        },
        "escalations": {
            "open": escalation_count
        },
        "event_sequence": coord.current_sequence()
    }))
}

// ============================================================================
// Persona Endpoints
// ============================================================================

/// Summary of a persona for listing
#[derive(Debug, Serialize)]
pub struct PersonaSummary {
    pub id: String,
    pub name: String,
    pub archetype: String,
    pub role_description: String,
    pub builtin: bool,
}

/// Full persona detail
#[derive(Debug, Serialize)]
pub struct PersonaDetail {
    pub id: String,
    pub name: String,
    pub archetype: String,
    pub role_description: String,
    pub system_prompt: String,
    pub behavior: PersonaBehaviorResponse,
    pub domain: PersonaDomainResponse,
    pub model: PersonaModelResponse,
    pub tools: PersonaToolsResponse,
    pub builtin: bool,
    pub source_path: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PersonaBehaviorResponse {
    pub verbosity: f64,
    pub risk_tolerance: f64,
    pub citation_density: f64,
    pub escalation_tendency: f64,
    pub working_style: String,
    pub notes: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct PersonaDomainResponse {
    pub primary_domains: Vec<String>,
    pub methodologies: Vec<String>,
    pub data_sources: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct PersonaModelResponse {
    pub provider: String,
    pub model: String,
    pub temperature: f64,
    pub max_tokens: Option<u32>,
    pub top_p: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct PersonaToolsResponse {
    pub policies: Vec<ToolPolicyResponse>,
    pub default_access: String,
}

#[derive(Debug, Serialize)]
pub struct ToolPolicyResponse {
    pub tool: String,
    pub access: String,
    pub scope: Vec<String>,
    pub notes: Option<String>,
}

/// Response for persona list
#[derive(Debug, Serialize)]
pub struct PersonasResponse {
    pub personas: Vec<PersonaSummary>,
    pub count: usize,
}

/// List all available personas
pub async fn list_personas(State(state): State<Arc<AppState>>) -> Json<PersonasResponse> {
    let personas: Vec<PersonaSummary> = state
        .personas
        .all()
        .map(|p| PersonaSummary {
            id: p.id.to_string(),
            name: p.name.clone(),
            archetype: p.archetype.name().to_string(),
            role_description: p.role_description.clone(),
            builtin: p.builtin,
        })
        .collect();

    let count = personas.len();
    Json(PersonasResponse { personas, count })
}

/// Get a specific persona by ID
pub async fn get_persona(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<PersonaDetail>, StatusCode> {
    state
        .personas
        .get_by_str(&id)
        .map(|p| {
            Json(PersonaDetail {
                id: p.id.to_string(),
                name: p.name.clone(),
                archetype: p.archetype.name().to_string(),
                role_description: p.role_description.clone(),
                system_prompt: p.system_prompt.clone(),
                behavior: PersonaBehaviorResponse {
                    verbosity: p.behavior.verbosity,
                    risk_tolerance: p.behavior.risk_tolerance,
                    citation_density: p.behavior.citation_density,
                    escalation_tendency: p.behavior.escalation_tendency,
                    working_style: p.behavior.working_style.name().to_string(),
                    notes: p.behavior.notes.clone(),
                },
                domain: PersonaDomainResponse {
                    primary_domains: p.domain.primary_domains.clone(),
                    methodologies: p.domain.methodologies.clone(),
                    data_sources: p.domain.data_sources.clone(),
                },
                model: PersonaModelResponse {
                    provider: p.model.provider.clone(),
                    model: p.model.model.clone(),
                    temperature: p.model.temperature,
                    max_tokens: p.model.max_tokens,
                    top_p: p.model.top_p,
                },
                tools: PersonaToolsResponse {
                    policies: p
                        .tools
                        .policies
                        .iter()
                        .map(|tp| ToolPolicyResponse {
                            tool: tp.tool.clone(),
                            access: access_to_string(tp.access),
                            scope: tp.scope.clone(),
                            notes: tp.notes.clone(),
                        })
                        .collect(),
                    default_access: access_to_string(p.tools.default_access),
                },
                builtin: p.builtin,
                source_path: p.source_path.clone(),
            })
        })
        .ok_or(StatusCode::NOT_FOUND)
}

fn access_to_string(access: ToolAccess) -> String {
    match access {
        ToolAccess::None => "none".to_string(),
        ToolAccess::Read => "read".to_string(),
        ToolAccess::ReadWrite => "read_write".to_string(),
        ToolAccess::Full => "full".to_string(),
    }
}

// ============================================================================
// Extended Thread Endpoints
// ============================================================================

/// Response for list threads
#[derive(Debug, Serialize)]
pub struct ThreadsResponse {
    pub threads: Vec<ThreadSummary>,
    pub count: usize,
}

/// Query parameters for listing threads
#[derive(Debug, Deserialize)]
pub struct ListThreadsQuery {
    pub state: Option<String>,
    pub min_temperature: Option<f64>,
    pub max_temperature: Option<f64>,
}

/// List all threads with optional filters
pub async fn list_threads(
    State(state): State<Arc<AppState>>,
    axum::extract::Query(query): axum::extract::Query<ListThreadsQuery>,
) -> Json<ThreadsResponse> {
    let coord = state.coordination.read().await;

    let mut threads: Vec<ThreadSummary> = coord
        .threads()
        .filter(|t| {
            // Filter by state if specified
            if let Some(ref state_filter) = query.state {
                if t.state.to_string().to_lowercase() != state_filter.to_lowercase() {
                    return false;
                }
            }
            // Filter by temperature range
            if let Some(min) = query.min_temperature {
                if t.temperature.value() < min {
                    return false;
                }
            }
            if let Some(max) = query.max_temperature {
                if t.temperature.value() > max {
                    return false;
                }
            }
            true
        })
        .map(|t| ThreadSummary {
            id: t.id.to_string(),
            title: t.metadata.title.clone(),
            state: t.state.to_string(),
            temperature: t.temperature.value(),
            claimed_by: t.claimed_by.clone(),
        })
        .collect();

    // Sort by temperature (hottest first)
    threads.sort_by(|a, b| b.temperature.partial_cmp(&a.temperature).unwrap_or(std::cmp::Ordering::Equal));

    let count = threads.len();
    Json(ThreadsResponse { threads, count })
}

/// Full thread detail response
#[derive(Debug, Serialize)]
pub struct ThreadDetail {
    pub id: String,
    pub title: String,
    pub description: String,
    pub state: String,
    pub temperature: f64,
    pub claimed_by: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub parent_id: Option<String>,
    pub tags: Vec<String>,
    pub artifact_ids: Vec<String>,
}

/// Get full thread details
pub async fn get_thread_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<ThreadDetail>, StatusCode> {
    let coord = state.coordination.read().await;

    coord
        .get_thread(&id)
        .map(|t| {
            Json(ThreadDetail {
                id: t.id.to_string(),
                title: t.metadata.title.clone(),
                description: t.metadata.description.clone(),
                state: t.state.to_string(),
                temperature: t.temperature.value(),
                claimed_by: t.claimed_by.clone(),
                created_at: t.created_at.to_rfc3339(),
                updated_at: t.updated_at.to_rfc3339(),
                parent_id: t.metadata.parent_id.map(|id| id.to_string()),
                tags: t.metadata.tags.clone(),
                artifact_ids: t.artifact_ids.clone(),
            })
        })
        .ok_or(StatusCode::NOT_FOUND)
}

/// Request to create a thread
#[derive(Debug, Deserialize)]
pub struct CreateThreadRequest {
    pub title: String,
    pub description: String,
    pub parent_id: Option<String>,
    pub priority: Option<f64>,
}

/// Create a new thread
pub async fn create_thread(
    State(state): State<Arc<AppState>>,
    Json(request): Json<CreateThreadRequest>,
) -> Result<Json<ThreadDetail>, (StatusCode, String)> {
    let parent_id = if let Some(ref pid) = request.parent_id {
        Some(ThreadId::parse(pid).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?)
    } else {
        None
    };

    let mut coord = state.coordination.write().await;

    let events = Command::CreateThread {
        title: request.title.clone(),
        description: request.description.clone(),
        parent_id,
        priority: request.priority,
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let thread_id = &events[0].entity_id;
    let thread = coord
        .get_thread(thread_id)
        .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, "Thread not found after creation".to_string()))?;

    Ok(Json(ThreadDetail {
        id: thread.id.to_string(),
        title: thread.metadata.title.clone(),
        description: thread.metadata.description.clone(),
        state: thread.state.to_string(),
        temperature: thread.temperature.value(),
        claimed_by: thread.claimed_by.clone(),
        created_at: thread.created_at.to_rfc3339(),
        updated_at: thread.updated_at.to_rfc3339(),
        parent_id: thread.metadata.parent_id.map(|id| id.to_string()),
        tags: thread.metadata.tags.clone(),
        artifact_ids: thread.artifact_ids.clone(),
    }))
}

/// Activate a thread (Embryo -> Active)
pub async fn activate_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::ActivateThread { thread_id }
        .execute(&mut coord)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "state": "ACTIVE"
    })))
}

/// Request to block a thread
#[derive(Debug, Deserialize)]
pub struct BlockThreadRequest {
    pub reason: Option<String>,
}

/// Block a thread
pub async fn block_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<BlockThreadRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::BlockThread {
        thread_id,
        reason: request.reason,
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "state": "BLOCKED"
    })))
}

/// Unblock a thread
pub async fn unblock_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::UnblockThread { thread_id }
        .execute(&mut coord)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "state": "ACTIVE"
    })))
}

/// Submit thread for review
pub async fn submit_for_review(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::SubmitForReview { thread_id }
        .execute(&mut coord)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "state": "REVIEW"
    })))
}

/// Complete a thread
pub async fn complete_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::CompleteThread { thread_id }
        .execute(&mut coord)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "state": "COMPLETE"
    })))
}

/// Request to kill a thread
#[derive(Debug, Deserialize)]
pub struct KillThreadRequest {
    pub reason: Option<String>,
}

/// Kill a thread
pub async fn kill_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<KillThreadRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::KillThread {
        thread_id,
        reason: request.reason,
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "state": "KILLED"
    })))
}

/// Request to set thread temperature
#[derive(Debug, Deserialize)]
pub struct SetTemperatureRequest {
    pub temperature: f64,
    pub reason: Option<String>,
}

/// Set thread temperature
pub async fn set_thread_temperature(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<SetTemperatureRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    let old_temp = coord
        .get_thread(&id)
        .map(|t| t.temperature.value())
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Thread not found".to_string()))?;

    Command::SetTemperature {
        thread_id,
        temperature: request.temperature,
        reason: request.reason.unwrap_or_else(|| "Temperature adjustment".to_string()),
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "old_temperature": old_temp,
        "new_temperature": request.temperature.clamp(0.0, 1.0)
    })))
}

/// Release a thread (agent releases claim)
#[derive(Debug, Deserialize)]
pub struct ReleaseThreadRequest {
    pub agent_id: String,
}

/// Release a thread from an agent
pub async fn release_thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ReleaseThreadRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let thread_id = ThreadId::parse(&id).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut coord = state.coordination.write().await;

    Command::ReleaseThread {
        thread_id,
        agent_id: request.agent_id.clone(),
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "thread_id": id,
        "released_by": request.agent_id
    })))
}

/// Get events for a specific thread
pub async fn get_thread_events(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let coord = state.coordination.read().await;

    // Verify thread exists
    if coord.get_thread(&id).is_none() {
        return Err(StatusCode::NOT_FOUND);
    }

    let events: Vec<_> = coord
        .all_events()
        .iter()
        .filter(|e| e.entity_id == id)
        .map(|e| {
            serde_json::json!({
                "id": e.id.to_string(),
                "sequence": e.sequence,
                "timestamp": e.timestamp.to_rfc3339(),
                "entity_type": e.entity_type.to_string(),
                "description": e.payload.description(),
                "actor_id": e.actor_id
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "thread_id": id,
        "events": events,
        "count": events.len()
    })))
}

// ============================================================================
// Agent Endpoints
// ============================================================================

use impel_core::agent::AgentType;

/// Summary of an agent for listing
#[derive(Debug, Serialize)]
pub struct AgentSummary {
    pub id: String,
    pub agent_type: String,
    pub status: String,
    pub current_thread: Option<String>,
    pub threads_completed: u64,
}

/// Full agent detail
#[derive(Debug, Serialize)]
pub struct AgentDetail {
    pub id: String,
    pub agent_type: String,
    pub status: String,
    pub current_thread: Option<String>,
    pub registered_at: String,
    pub last_active_at: String,
    pub threads_completed: u64,
    pub capabilities: Vec<String>,
}

/// Response for agent list
#[derive(Debug, Serialize)]
pub struct AgentsResponse {
    pub agents: Vec<AgentSummary>,
    pub count: usize,
}

/// List all agents
pub async fn list_agents(State(state): State<Arc<AppState>>) -> Json<AgentsResponse> {
    let coord = state.coordination.read().await;

    let agents: Vec<AgentSummary> = coord
        .agents()
        .all()
        .map(|a| AgentSummary {
            id: a.id.clone(),
            agent_type: a.agent_type.to_string(),
            status: a.status.to_string(),
            current_thread: a.current_thread.map(|t| t.to_string()),
            threads_completed: a.threads_completed,
        })
        .collect();

    let count = agents.len();
    Json(AgentsResponse { agents, count })
}

/// Get a specific agent
pub async fn get_agent(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<AgentDetail>, StatusCode> {
    let coord = state.coordination.read().await;

    coord
        .agents()
        .get(&id)
        .map(|a| {
            Json(AgentDetail {
                id: a.id.clone(),
                agent_type: a.agent_type.to_string(),
                status: a.status.to_string(),
                current_thread: a.current_thread.map(|t| t.to_string()),
                registered_at: a.registered_at.to_rfc3339(),
                last_active_at: a.last_active_at.to_rfc3339(),
                threads_completed: a.threads_completed,
                capabilities: a
                    .agent_type
                    .capabilities()
                    .into_iter()
                    .map(|c| c.name().to_string())
                    .collect(),
            })
        })
        .ok_or(StatusCode::NOT_FOUND)
}

/// Request to register an agent
#[derive(Debug, Deserialize)]
pub struct RegisterAgentRequest {
    pub agent_type: String,
    pub persona_id: Option<String>,
}

fn parse_agent_type(s: &str) -> Option<AgentType> {
    match s.to_lowercase().as_str() {
        "research" => Some(AgentType::Research),
        "code" => Some(AgentType::Code),
        "verification" => Some(AgentType::Verification),
        "adversarial" => Some(AgentType::Adversarial),
        "review" => Some(AgentType::Review),
        "librarian" => Some(AgentType::Librarian),
        _ => None,
    }
}

/// Register a new agent
pub async fn register_agent(
    State(state): State<Arc<AppState>>,
    Json(request): Json<RegisterAgentRequest>,
) -> Result<Json<AgentDetail>, (StatusCode, String)> {
    let agent_type = parse_agent_type(&request.agent_type)
        .ok_or_else(|| (StatusCode::BAD_REQUEST, format!("Invalid agent type: {}", request.agent_type)))?;

    let mut coord = state.coordination.write().await;

    // Create the agent using the registry
    let agent = coord.agents_mut().create_agent(agent_type)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    let agent_id = agent.id.clone();

    // Also record as event
    let _ = Command::RegisterAgent {
        agent_id: agent_id.clone(),
        agent_type,
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let agent = coord.agents().get(&agent_id)
        .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, "Agent not found after registration".to_string()))?;

    Ok(Json(AgentDetail {
        id: agent.id.clone(),
        agent_type: agent.agent_type.to_string(),
        status: agent.status.to_string(),
        current_thread: agent.current_thread.map(|t| t.to_string()),
        registered_at: agent.registered_at.to_rfc3339(),
        last_active_at: agent.last_active_at.to_rfc3339(),
        threads_completed: agent.threads_completed,
        capabilities: agent
            .agent_type
            .capabilities()
            .into_iter()
            .map(|c| c.name().to_string())
            .collect(),
    }))
}

/// Request to terminate an agent
#[derive(Debug, Deserialize)]
pub struct TerminateAgentRequest {
    pub reason: Option<String>,
}

/// Terminate an agent
pub async fn terminate_agent(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<TerminateAgentRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let mut coord = state.coordination.write().await;

    // Verify agent exists
    if coord.agents().get(&id).is_none() {
        return Err((StatusCode::NOT_FOUND, format!("Agent not found: {}", id)));
    }

    Command::TerminateAgent {
        agent_id: id.clone(),
        reason: request.reason.clone(),
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    // Mark as terminated in registry
    if let Some(agent) = coord.agents_mut().get_mut(&id) {
        agent.terminate();
    }

    Ok(Json(serde_json::json!({
        "success": true,
        "agent_id": id,
        "status": "TERMINATED"
    })))
}

// ============================================================================
// Escalation Endpoints
// ============================================================================

use impel_core::escalation::{Escalation, EscalationCategory, EscalationOption, EscalationPriority};

/// Summary of an escalation for listing
#[derive(Debug, Serialize)]
pub struct EscalationSummary {
    pub id: String,
    pub category: String,
    pub priority: String,
    pub status: String,
    pub title: String,
    pub thread_id: Option<String>,
    pub created_at: String,
    pub created_by: String,
}

/// Full escalation detail
#[derive(Debug, Serialize)]
pub struct EscalationDetail {
    pub id: String,
    pub category: String,
    pub priority: String,
    pub status: String,
    pub title: String,
    pub description: String,
    pub thread_id: Option<String>,
    pub created_by: String,
    pub created_at: String,
    pub acknowledged_at: Option<String>,
    pub acknowledged_by: Option<String>,
    pub resolved_at: Option<String>,
    pub resolved_by: Option<String>,
    pub resolution: Option<String>,
    pub options: Vec<EscalationOptionResponse>,
    pub selected_option: Option<usize>,
}

#[derive(Debug, Serialize)]
pub struct EscalationOptionResponse {
    pub label: String,
    pub description: String,
    pub impact: Option<String>,
}

/// Response for escalation list
#[derive(Debug, Serialize)]
pub struct EscalationsResponse {
    pub escalations: Vec<EscalationSummary>,
    pub count: usize,
}

/// Query parameters for listing escalations
#[derive(Debug, Deserialize)]
pub struct ListEscalationsQuery {
    pub open_only: Option<bool>,
}

/// List escalations
pub async fn list_escalations(
    State(state): State<Arc<AppState>>,
    axum::extract::Query(query): axum::extract::Query<ListEscalationsQuery>,
) -> Json<EscalationsResponse> {
    let coord = state.coordination.read().await;

    let open_only = query.open_only.unwrap_or(true);

    let escalations: Vec<EscalationSummary> = if open_only {
        coord
            .open_escalations()
            .into_iter()
            .map(|e| EscalationSummary {
                id: e.id.clone(),
                category: e.category.to_string(),
                priority: e.priority.to_string(),
                status: e.status.to_string(),
                title: e.title.clone(),
                thread_id: e.thread_id.map(|t| t.to_string()),
                created_at: e.created_at.to_rfc3339(),
                created_by: e.created_by.clone(),
            })
            .collect()
    } else {
        coord
            .all_escalations()
            .map(|e| EscalationSummary {
                id: e.id.clone(),
                category: e.category.to_string(),
                priority: e.priority.to_string(),
                status: e.status.to_string(),
                title: e.title.clone(),
                thread_id: e.thread_id.map(|t| t.to_string()),
                created_at: e.created_at.to_rfc3339(),
                created_by: e.created_by.clone(),
            })
            .collect()
    };

    let count = escalations.len();
    Json(EscalationsResponse { escalations, count })
}

/// Get a specific escalation
pub async fn get_escalation(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<EscalationDetail>, StatusCode> {
    let coord = state.coordination.read().await;

    coord
        .get_escalation(&id)
        .map(|e| {
            Json(EscalationDetail {
                id: e.id.clone(),
                category: e.category.to_string(),
                priority: e.priority.to_string(),
                status: e.status.to_string(),
                title: e.title.clone(),
                description: e.description.clone(),
                thread_id: e.thread_id.map(|t| t.to_string()),
                created_by: e.created_by.clone(),
                created_at: e.created_at.to_rfc3339(),
                acknowledged_at: e.acknowledged_at.map(|t| t.to_rfc3339()),
                acknowledged_by: e.acknowledged_by.clone(),
                resolved_at: e.resolved_at.map(|t| t.to_rfc3339()),
                resolved_by: e.resolved_by.clone(),
                resolution: e.resolution.clone(),
                options: e
                    .options
                    .iter()
                    .map(|o| EscalationOptionResponse {
                        label: o.label.clone(),
                        description: o.description.clone(),
                        impact: o.impact.clone(),
                    })
                    .collect(),
                selected_option: e.selected_option,
            })
        })
        .ok_or(StatusCode::NOT_FOUND)
}

/// Request to create an escalation
#[derive(Debug, Deserialize)]
pub struct CreateEscalationRequest {
    pub category: String,
    pub title: String,
    pub description: String,
    pub created_by: String,
    pub thread_id: Option<String>,
    pub priority: Option<String>,
    pub options: Option<Vec<CreateEscalationOption>>,
}

#[derive(Debug, Deserialize)]
pub struct CreateEscalationOption {
    pub label: String,
    pub description: String,
    pub impact: Option<String>,
}

fn parse_escalation_category(s: &str) -> Option<EscalationCategory> {
    match s.to_lowercase().as_str() {
        "decision" => Some(EscalationCategory::Decision),
        "novelty" => Some(EscalationCategory::Novelty),
        "stuck" => Some(EscalationCategory::Stuck),
        "scope" => Some(EscalationCategory::Scope),
        "quality" => Some(EscalationCategory::Quality),
        "checkpoint" => Some(EscalationCategory::Checkpoint),
        _ => None,
    }
}

fn parse_escalation_priority(s: &str) -> Option<EscalationPriority> {
    match s.to_lowercase().as_str() {
        "low" => Some(EscalationPriority::Low),
        "medium" => Some(EscalationPriority::Medium),
        "high" => Some(EscalationPriority::High),
        "critical" => Some(EscalationPriority::Critical),
        _ => None,
    }
}

/// Create a new escalation
pub async fn create_escalation(
    State(state): State<Arc<AppState>>,
    Json(request): Json<CreateEscalationRequest>,
) -> Result<Json<EscalationDetail>, (StatusCode, String)> {
    let category = parse_escalation_category(&request.category)
        .ok_or_else(|| (StatusCode::BAD_REQUEST, format!("Invalid category: {}", request.category)))?;

    let thread_id = if let Some(ref tid) = request.thread_id {
        Some(ThreadId::parse(tid).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?)
    } else {
        None
    };

    let mut coord = state.coordination.write().await;

    // Create escalation
    let mut escalation = Escalation::new(
        category,
        request.title.clone(),
        request.description.clone(),
        request.created_by.clone(),
    );

    if let Some(tid) = thread_id {
        escalation = escalation.with_thread(tid);
    }

    if let Some(ref priority_str) = request.priority {
        if let Some(priority) = parse_escalation_priority(priority_str) {
            escalation = escalation.with_priority(priority);
        }
    }

    if let Some(ref options) = request.options {
        escalation.options = options
            .iter()
            .map(|o| {
                let mut opt = EscalationOption::new(o.label.clone(), o.description.clone());
                if let Some(ref impact) = o.impact {
                    opt = opt.with_impact(impact.clone());
                }
                opt
            })
            .collect();
    }

    let escalation_id = escalation.id.clone();
    coord.add_escalation(escalation);

    // Record event
    let _ = Command::CreateEscalation {
        category,
        title: request.title,
        description: request.description,
        created_by: request.created_by,
        thread_id,
    }
    .execute(&mut coord);

    let escalation = coord
        .get_escalation(&escalation_id)
        .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, "Escalation not found after creation".to_string()))?;

    Ok(Json(EscalationDetail {
        id: escalation.id.clone(),
        category: escalation.category.to_string(),
        priority: escalation.priority.to_string(),
        status: escalation.status.to_string(),
        title: escalation.title.clone(),
        description: escalation.description.clone(),
        thread_id: escalation.thread_id.map(|t| t.to_string()),
        created_by: escalation.created_by.clone(),
        created_at: escalation.created_at.to_rfc3339(),
        acknowledged_at: None,
        acknowledged_by: None,
        resolved_at: None,
        resolved_by: None,
        resolution: None,
        options: escalation
            .options
            .iter()
            .map(|o| EscalationOptionResponse {
                label: o.label.clone(),
                description: o.description.clone(),
                impact: o.impact.clone(),
            })
            .collect(),
        selected_option: None,
    }))
}

/// Request to acknowledge an escalation
#[derive(Debug, Deserialize)]
pub struct AcknowledgeEscalationRequest {
    pub by: String,
}

/// Acknowledge an escalation
pub async fn acknowledge_escalation(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<AcknowledgeEscalationRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let mut coord = state.coordination.write().await;

    Command::AcknowledgeEscalation {
        escalation_id: id.clone(),
        by: request.by.clone(),
    }
    .execute(&mut coord)
    .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

    Ok(Json(serde_json::json!({
        "success": true,
        "escalation_id": id,
        "acknowledged_by": request.by,
        "status": "ACKNOWLEDGED"
    })))
}

/// Request to resolve an escalation
#[derive(Debug, Deserialize)]
pub struct ResolveEscalationRequest {
    pub by: String,
    pub resolution: String,
    pub selected_option: Option<usize>,
}

/// Resolve an escalation
pub async fn resolve_escalation(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ResolveEscalationRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let mut coord = state.coordination.write().await;

    // If selected_option is provided, resolve with that option
    if let Some(option_idx) = request.selected_option {
        let escalation = coord
            .get_escalation_mut(&id)
            .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Escalation not found: {}", id)))?;
        escalation.resolve_with_option(request.by.clone(), option_idx);
    } else {
        Command::ResolveEscalation {
            escalation_id: id.clone(),
            by: request.by.clone(),
            resolution: request.resolution.clone(),
        }
        .execute(&mut coord)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;
    }

    Ok(Json(serde_json::json!({
        "success": true,
        "escalation_id": id,
        "resolved_by": request.by,
        "resolution": request.resolution,
        "status": "RESOLVED"
    })))
}

/// Query parameters for polling escalation resolution
#[derive(Debug, Deserialize)]
pub struct PollEscalationQuery {
    /// Timeout in seconds (default: 30, max: 120)
    pub timeout: Option<u64>,
}

/// Response for escalation poll
#[derive(Debug, Serialize)]
pub struct EscalationPollResponse {
    pub id: String,
    pub status: String,
    pub resolved: bool,
    pub resolution: Option<String>,
    pub resolved_by: Option<String>,
    pub resolved_at: Option<String>,
    pub selected_option: Option<usize>,
    pub timed_out: bool,
}

/// Poll for escalation resolution with long-polling support.
///
/// This endpoint allows agents to wait for a human to resolve an escalation.
/// The request will block until the escalation is resolved or the timeout expires.
pub async fn poll_escalation(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    axum::extract::Query(query): axum::extract::Query<PollEscalationQuery>,
) -> Result<Json<EscalationPollResponse>, (StatusCode, String)> {
    // Clamp timeout between 1 and 120 seconds
    let timeout_secs = query.timeout.unwrap_or(30).clamp(1, 120);
    let poll_interval = std::time::Duration::from_millis(500);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);

    loop {
        // Check current escalation status
        {
            let coord = state.coordination.read().await;
            let escalation = coord
                .get_escalation(&id)
                .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Escalation not found: {}", id)))?;

            // If resolved or dismissed, return immediately
            if escalation.status.is_handled() {
                return Ok(Json(EscalationPollResponse {
                    id: escalation.id.clone(),
                    status: escalation.status.to_string(),
                    resolved: true,
                    resolution: escalation.resolution.clone(),
                    resolved_by: escalation.resolved_by.clone(),
                    resolved_at: escalation.resolved_at.map(|t| t.to_rfc3339()),
                    selected_option: escalation.selected_option,
                    timed_out: false,
                }));
            }
        }

        // Check if we've exceeded the timeout
        if std::time::Instant::now() >= deadline {
            let coord = state.coordination.read().await;
            let escalation = coord
                .get_escalation(&id)
                .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Escalation not found: {}", id)))?;

            return Ok(Json(EscalationPollResponse {
                id: escalation.id.clone(),
                status: escalation.status.to_string(),
                resolved: false,
                resolution: None,
                resolved_by: None,
                resolved_at: None,
                selected_option: None,
                timed_out: true,
            }));
        }

        // Wait before polling again
        tokio::time::sleep(poll_interval).await;
    }
}

// ============================================================================
// Agent Work Dispatch
// ============================================================================

/// Response for next thread endpoint
#[derive(Debug, Serialize)]
pub struct NextThreadResponse {
    pub thread: Option<ThreadDetail>,
    pub claimed: bool,
    pub message: String,
}

/// Get and optionally claim the next available thread for an agent.
///
/// Returns the highest-temperature available thread. If auto_claim is true,
/// the thread will be automatically claimed for the agent.
pub async fn get_next_thread(
    State(state): State<Arc<AppState>>,
    Path(agent_id): Path<String>,
    axum::extract::Query(query): axum::extract::Query<GetNextThreadQuery>,
) -> Result<Json<NextThreadResponse>, (StatusCode, String)> {
    let auto_claim = query.auto_claim.unwrap_or(false);

    // First, verify the agent exists and is not terminated
    {
        let coord = state.coordination.read().await;
        let agent = coord.agents().get(&agent_id)
            .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Agent not found: {}", agent_id)))?;

        if !agent.status.is_active() {
            return Err((StatusCode::CONFLICT, format!("Agent {} is terminated", agent_id)));
        }

        // Check if agent already has a thread
        if agent.current_thread.is_some() {
            return Err((StatusCode::CONFLICT, format!("Agent {} already has a thread claimed", agent_id)));
        }
    }

    // Get the hottest available thread
    let thread_to_claim: Option<ThreadId> = {
        let coord = state.coordination.read().await;
        coord.threads_by_temperature()
            .into_iter()
            .find(|t| t.state.is_claimable() && t.claimed_by.is_none())
            .map(|t| t.id.clone())
    };

    let Some(thread_id) = thread_to_claim else {
        return Ok(Json(NextThreadResponse {
            thread: None,
            claimed: false,
            message: "No threads available for claiming".to_string(),
        }));
    };

    // If auto_claim, claim the thread
    if auto_claim {
        let mut coord = state.coordination.write().await;

        Command::ClaimThread {
            thread_id: thread_id.clone(),
            agent_id: agent_id.clone(),
        }
        .execute(&mut coord)
        .map_err(|e| (StatusCode::CONFLICT, e.to_string()))?;

        let thread = coord.get_thread(&thread_id.to_string())
            .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, "Thread not found after claim".to_string()))?;

        return Ok(Json(NextThreadResponse {
            thread: Some(ThreadDetail {
                id: thread.id.to_string(),
                title: thread.metadata.title.clone(),
                description: thread.metadata.description.clone(),
                state: thread.state.to_string(),
                temperature: thread.temperature.value(),
                claimed_by: thread.claimed_by.clone(),
                created_at: thread.created_at.to_rfc3339(),
                updated_at: thread.updated_at.to_rfc3339(),
                parent_id: thread.metadata.parent_id.map(|id| id.to_string()),
                tags: thread.metadata.tags.clone(),
                artifact_ids: thread.artifact_ids.clone(),
            }),
            claimed: true,
            message: format!("Thread claimed by {}", agent_id),
        }));
    }

    // Just return the thread without claiming
    let coord = state.coordination.read().await;
    let thread = coord.get_thread(&thread_id.to_string())
        .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, "Thread not found".to_string()))?;

    Ok(Json(NextThreadResponse {
        thread: Some(ThreadDetail {
            id: thread.id.to_string(),
            title: thread.metadata.title.clone(),
            description: thread.metadata.description.clone(),
            state: thread.state.to_string(),
            temperature: thread.temperature.value(),
            claimed_by: thread.claimed_by.clone(),
            created_at: thread.created_at.to_rfc3339(),
            updated_at: thread.updated_at.to_rfc3339(),
            parent_id: thread.metadata.parent_id.map(|id| id.to_string()),
            tags: thread.metadata.tags.clone(),
            artifact_ids: thread.artifact_ids.clone(),
        }),
        claimed: false,
        message: "Thread available for claiming".to_string(),
    }))
}

/// Query parameters for get next thread
#[derive(Debug, Deserialize)]
pub struct GetNextThreadQuery {
    /// Automatically claim the thread (default: false)
    pub auto_claim: Option<bool>,
}
