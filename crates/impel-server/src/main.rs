//! Impel Server Binary
//!
//! Standalone server for the impel agent API.

use std::sync::Arc;

use impel_server::{serve, AppState};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize logging
    tracing_subscriber::fmt::init();

    let state = Arc::new(AppState::new());
    let addr = std::env::var("IMPEL_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".to_string());

    serve(&addr, state).await
}
