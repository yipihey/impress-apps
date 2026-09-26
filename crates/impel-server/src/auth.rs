//! Authentication: every request carries a registered agent's bearer.
//!
//! Until P0 (plan verb-pipeline, SEC-8) this middleware accepted any bearer
//! that merely *started with* `impel-`, accepted the literal `system`, let a
//! request with **no** `Authorization` header straight through ("for
//! development"), and was not wired into the router at all. Now:
//!
//! * a request must carry `Authorization: Bearer <token>` where `<token>` is
//!   the token a registered, still-present agent was issued by
//!   `POST /agents`; anything else is 401 with `WWW-Authenticate: Bearer`;
//! * exactly two routes are open, because nothing could bootstrap otherwise:
//!   `POST /agents` (registration is where a token comes from) and
//!   `GET /status` (liveness for a supervisor that holds no token);
//! * the middleware is a layer on the router (`create_router`), so a route
//!   added later is protected by default rather than open by default.

use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{header, HeaderValue, Method, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};

use crate::AppState;

/// The `(method, path)` pairs that need no bearer. Kept as a table so the
/// exemption is reviewable in one place; a route not listed here is
/// protected, whether or not its author thought about it.
const OPEN_ROUTES: &[(&str, &str)] = &[("POST", "/agents"), ("GET", "/status")];

fn is_open(method: &Method, path: &str) -> bool {
    OPEN_ROUTES
        .iter()
        .any(|(m, p)| method.as_str() == *m && path == *p)
}

/// Token-based authentication middleware. Fail-closed.
pub async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if is_open(request.method(), request.uri().path()) {
        return next.run(request).await;
    }

    let presented = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(bearer_of);

    let Some(token) = presented else {
        return unauthorized("missing bearer");
    };

    let known = {
        let coord = state.coordination.read().await;
        coord.agents().authenticate(token).is_some()
    };
    if known {
        next.run(request).await
    } else {
        unauthorized("unknown token")
    }
}

/// The token in `Bearer <token>` (scheme case-insensitive), or `None` for any
/// other shape, including an empty token.
fn bearer_of(header: &str) -> Option<&str> {
    let (scheme, rest) = header.trim().split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let token = rest.trim();
    (!token.is_empty()).then_some(token)
}

fn unauthorized(reason: &'static str) -> Response {
    let mut response = (
        StatusCode::UNAUTHORIZED,
        axum::Json(serde_json::json!({ "status": "error", "reason": reason })),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
    response
}

/// Generate a new agent token. Issued once, by `POST /agents`, and never
/// shown again; the prefix is a courtesy for logs, not something the
/// middleware trusts.
pub fn generate_agent_token(agent_id: &str) -> String {
    use uuid::Uuid;
    format!("impel-{}-{}", agent_id, Uuid::new_v4())
}

/// Validate an agent token's *shape* (what `generate_agent_token` produces).
/// This is a format check for callers that store tokens; it authorises
/// nothing — only a registered agent's token passes the middleware.
pub fn validate_token_format(token: &str) -> bool {
    token.starts_with("impel-") && token.len() > 40
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use tower::ServiceExt;

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

    #[test]
    fn bearer_parsing() {
        assert_eq!(bearer_of("Bearer abc"), Some("abc"));
        assert_eq!(bearer_of("bearer abc"), Some("abc"));
        assert_eq!(bearer_of("Bearer"), None);
        assert_eq!(bearer_of("Bearer "), None);
        assert_eq!(bearer_of("Basic abc"), None);
    }

    async fn register(app: &axum::Router) -> String {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/agents")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"agent_type":"research"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        json["auth_token"]
            .as_str()
            .expect("registration returns the agent's token")
            .to_string()
    }

    async fn status_of(app: &axum::Router, uri: &str, bearer: Option<&str>) -> StatusCode {
        let mut request = Request::builder().method("GET").uri(uri);
        if let Some(bearer) = bearer {
            request = request.header("authorization", bearer);
        }
        app.clone()
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap()
            .status()
    }

    #[tokio::test]
    async fn a_missing_bearer_is_refused_not_admitted() {
        let app = crate::create_router(Arc::new(AppState::new()));
        assert_eq!(
            status_of(&app, "/threads", None).await,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            status_of(&app, "/agents", None).await,
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn the_old_prefix_and_system_arms_are_gone() {
        let app = crate::create_router(Arc::new(AppState::new()));
        for bearer in [
            "Bearer system",
            "Bearer impel-anything-0123456789abcdef0123456789abcdef",
            "Basic abc",
        ] {
            assert_eq!(
                status_of(&app, "/threads", Some(bearer)).await,
                StatusCode::UNAUTHORIZED,
                "{bearer}"
            );
        }
    }

    #[tokio::test]
    async fn a_registered_agents_token_passes_and_the_open_routes_are_open() {
        let app = crate::create_router(Arc::new(AppState::new()));
        assert_eq!(status_of(&app, "/status", None).await, StatusCode::OK);
        let token = register(&app).await;
        assert!(validate_token_format(&token));
        assert_eq!(
            status_of(&app, "/threads", Some(&format!("Bearer {token}"))).await,
            StatusCode::OK
        );
        assert_eq!(
            status_of(&app, "/threads", Some(&format!("Bearer {token}x"))).await,
            StatusCode::UNAUTHORIZED
        );
    }
}
