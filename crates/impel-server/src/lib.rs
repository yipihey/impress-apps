//! Impel Server - Agent API Server
//!
//! HTTP/WebSocket server for agent communication.

pub mod auth;
pub mod http;
pub mod socket;
pub mod websocket;

use std::sync::Arc;

use axum::{
    extract::State,
    routing::{get, post},
    Router,
};
use tokio::sync::RwLock;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use impel_core::coordination::CoordinationState;

/// Shared application state
pub struct AppState {
    pub coordination: RwLock<CoordinationState>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            coordination: RwLock::new(CoordinationState::new()),
        }
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
        .route("/threads/available", get(http::get_available_threads))
        .route("/threads/:id", get(http::get_thread))
        .route("/threads/:id/claim", post(http::claim_thread))
        // Event endpoints
        .route("/events", post(http::submit_event))
        .route("/events", get(http::get_events))
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
