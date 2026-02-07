//! Impel Server - Agent API Server
//!
//! HTTP/WebSocket server for agent communication.

pub mod auth;
pub mod http;
pub mod socket;
pub mod websocket;

use std::path::Path;
use std::sync::Arc;

use axum::{
    routing::{delete, get, post, put},
    Router,
};
use tokio::sync::RwLock;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use impel_core::coordination::CoordinationState;
use impel_core::persona::PersonaRegistry;

/// Shared application state
pub struct AppState {
    pub coordination: RwLock<CoordinationState>,
    pub personas: PersonaRegistry,
    #[cfg(feature = "sqlite")]
    pub repository: Option<std::sync::Mutex<impel_core::persistence::Repository>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            coordination: RwLock::new(CoordinationState::new()),
            personas: PersonaRegistry::with_builtins(),
            #[cfg(feature = "sqlite")]
            repository: None,
        }
    }

    /// Create with personas loaded from standard locations
    pub fn with_project_root(project_root: Option<&Path>) -> Self {
        let personas = PersonaRegistry::load_standard(project_root).unwrap_or_else(|e| {
            tracing::warn!("Failed to load personas: {}, using builtins only", e);
            PersonaRegistry::with_builtins()
        });

        Self {
            coordination: RwLock::new(CoordinationState::new()),
            personas,
            #[cfg(feature = "sqlite")]
            repository: None,
        }
    }

    /// Create with persistence enabled
    ///
    /// Loads state from the database on startup if it exists.
    #[cfg(feature = "sqlite")]
    pub fn with_persistence(
        project_root: Option<&Path>,
        db_path: impl AsRef<Path>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let personas = PersonaRegistry::load_standard(project_root).unwrap_or_else(|e| {
            tracing::warn!("Failed to load personas: {}, using builtins only", e);
            PersonaRegistry::with_builtins()
        });

        let repository = impel_core::persistence::Repository::new(&db_path)?;
        let mut coordination = CoordinationState::new();

        // Load persisted state
        if let Err(e) = coordination.load_from_repository(&repository) {
            tracing::warn!("Failed to load persisted state: {}", e);
        } else {
            tracing::info!("Loaded persisted state from {:?}", db_path.as_ref());
        }

        Ok(Self {
            coordination: RwLock::new(coordination),
            personas,
            repository: Some(std::sync::Mutex::new(repository)),
        })
    }

    /// Save current state to persistence (if enabled)
    #[cfg(feature = "sqlite")]
    pub async fn save_state(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if let Some(ref repo_mutex) = self.repository {
            let coord = self.coordination.read().await;
            let repo = repo_mutex
                .lock()
                .map_err(|e| format!("Mutex poisoned: {}", e))?;
            coord.save_to_repository(&repo)?;
            tracing::debug!("Saved state to persistence");
        }
        Ok(())
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

/// Create the API router
pub fn create_router(state: Arc<AppState>) -> Router {
    Router::new()
        // Thread endpoints
        .route("/threads", get(http::list_threads))
        .route("/threads", post(http::create_thread))
        .route("/threads/available", get(http::get_available_threads))
        .route("/threads/{id}", get(http::get_thread_detail))
        .route("/threads/{id}/claim", post(http::claim_thread))
        .route("/threads/{id}/release", post(http::release_thread))
        .route("/threads/{id}/activate", put(http::activate_thread))
        .route("/threads/{id}/block", put(http::block_thread))
        .route("/threads/{id}/unblock", put(http::unblock_thread))
        .route("/threads/{id}/review", put(http::submit_for_review))
        .route("/threads/{id}/complete", put(http::complete_thread))
        .route("/threads/{id}/kill", put(http::kill_thread))
        .route(
            "/threads/{id}/temperature",
            put(http::set_thread_temperature),
        )
        .route("/threads/{id}/events", get(http::get_thread_events))
        // Agent endpoints
        .route("/agents", get(http::list_agents))
        .route("/agents", post(http::register_agent))
        .route("/agents/{id}", get(http::get_agent))
        .route("/agents/{id}", delete(http::terminate_agent))
        .route("/agents/{id}/next-thread", get(http::get_next_thread))
        // Escalation endpoints
        .route("/escalations", get(http::list_escalations))
        .route("/escalations", post(http::create_escalation))
        .route("/escalations/{id}", get(http::get_escalation))
        .route(
            "/escalations/{id}/acknowledge",
            put(http::acknowledge_escalation),
        )
        .route("/escalations/{id}/resolve", put(http::resolve_escalation))
        .route("/escalations/{id}/poll", get(http::poll_escalation))
        // Event endpoints
        .route("/events", post(http::submit_event))
        .route("/events", get(http::get_events))
        // Persona endpoints
        .route("/personas", get(http::list_personas))
        .route("/personas/{id}", get(http::get_persona))
        // System endpoints
        .route("/constitution", get(http::get_constitution))
        .route("/status", get(http::get_status))
        // WebSocket
        .route("/ws", get(websocket::ws_handler))
        // Middleware
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
        .with_state(state)
}

/// Start the server
pub async fn serve(addr: &str, state: Arc<AppState>) -> Result<(), Box<dyn std::error::Error>> {
    let app = create_router(state);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("Impel server listening on {}", addr);
    axum::serve(listener, app).await?;
    Ok(())
}
