//! Authentication and authorization

use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};

use crate::AppState;

/// Token-based authentication middleware
pub async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    // Get the Authorization header
    let auth_header = request
        .headers()
        .get("Authorization")
        .and_then(|h| h.to_str().ok());

    match auth_header {
        Some(header) if header.starts_with("Bearer ") => {
            let token = &header[7..];

            // Validate token against registered agents
            let coord = state.coordination.read().await;
            if coord.agents().authenticate(token).is_some() {
                drop(coord);
                return Ok(next.run(request).await);
            }

            // Also accept system tokens (TODO: implement proper system token validation)
            if token == "system" || token.starts_with("impel-") {
                drop(coord);
                return Ok(next.run(request).await);
            }

            Err(StatusCode::UNAUTHORIZED)
        }
        _ => {
            // For now, allow unauthenticated access for development
            // TODO: Make this configurable
            Ok(next.run(request).await)
        }
    }
}

/// Generate a new agent token
pub fn generate_agent_token(agent_id: &str) -> String {
    use uuid::Uuid;
    format!("impel-{}-{}", agent_id, Uuid::new_v4())
}

/// Validate an agent token format
pub fn validate_token_format(token: &str) -> bool {
    token.starts_with("impel-") && token.len() > 40
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_token() {
        let token = generate_agent_token("research-1");
        assert!(token.starts_with("impel-research-1-"));
        assert!(validate_token_format(&token));
    }

    #[test]
    fn test_validate_token() {
        assert!(!validate_token_format("invalid"));
        assert!(!validate_token_format("impel-"));
    }
}
