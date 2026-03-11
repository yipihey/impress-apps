use axum::routing::{get, post};
use axum::Json;
use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use crate::discover::handle_discover;
use crate::execute::{handle_execute, handle_execute_file};
use crate::types::StatusResponse;

/// Create the Axum router with all endpoints.
pub fn create_router() -> Router {
    Router::new()
        .route("/status", get(handle_status))
        .route("/execute", post(handle_execute))
        .route("/execute/file", post(handle_execute_file))
        .route("/discover", post(handle_discover))
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
}

/// GET /status — health check.
async fn handle_status() -> Json<StatusResponse> {
    Json(StatusResponse {
        status: "ok".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: std::process::id(),
    })
}

/// Start the server on the given address.
pub async fn serve(bind_addr: &str) -> Result<(), Box<dyn std::error::Error>> {
    let app = create_router();
    let listener = tokio::net::TcpListener::bind(bind_addr).await?;
    tracing::info!("impress-toolbox listening on {}", bind_addr);
    axum::serve(listener, app).await?;
    Ok(())
}
