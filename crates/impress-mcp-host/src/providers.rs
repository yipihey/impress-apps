//! Authenticated provider registration. Trust changes deliberately have no HTTP
//! route: provider/agent credentials cannot impersonate the person reviewing it.

use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use impress_service_core::pipeline::CallerIdentity;
use impress_service_core::provider::{RegistrationError, RegistrationRequest};
use impress_service_core::refusal::codes;
use impress_service_core::registry_runtime;
use impress_service_core::wire::WIRE_VERSION;
use serde::Deserialize;
use serde_json::json;

use super::{has_bearer_token, HttpState};

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

pub(super) fn identity(state: &HttpState, headers: &HeaderMap) -> Option<CallerIdentity> {
    if has_bearer_token(headers, &state.bearer_token) {
        return Some(CallerIdentity::agent(format!(
            "mcp-host:{}",
            state.config.server_name
        )));
    }
    let id = headers.get("x-impress-provider-id")?.to_str().ok()?;
    registry_runtime::current()
        .authenticate(id, bearer(headers)?)
        .then(|| CallerIdentity::Provider(id.to_owned()))
}

pub(super) fn unauthorized() -> Response {
    error_response(
        StatusCode::UNAUTHORIZED,
        "unauthorized",
        "a valid host or provider credential is required",
    )
}

fn error_response(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(json!({
            "ok": false,
            "wire_version": WIRE_VERSION,
            "code": code,
            "message": message,
        })),
    )
        .into_response()
}

fn registration_error(error: RegistrationError) -> Response {
    let (status, code) = match error {
        RegistrationError::Credential(_) => (StatusCode::FORBIDDEN, "forbidden"),
        RegistrationError::Persistence(_) => {
            (StatusCode::INTERNAL_SERVER_ERROR, codes::STORE_ERROR)
        }
        RegistrationError::ValidatorUnavailable => {
            (StatusCode::SERVICE_UNAVAILABLE, codes::HOST_UNAVAILABLE)
        }
        RegistrationError::Invalid(_) => (StatusCode::BAD_REQUEST, codes::INVALID_ARGUMENT),
    };
    error_response(status, code, &error.to_string())
}

pub(super) async fn register(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Json(request): Json<RegistrationRequest>,
) -> Response {
    match identity(&state, &headers) {
        Some(CallerIdentity::Agent(_)) => {}
        Some(CallerIdentity::Provider(id)) if id == request.provider.id => {}
        _ => return unauthorized(),
    }
    // Persistence is synchronous; it must not block the HTTP reactor.
    match tokio::task::spawn_blocking(move || registry_runtime::register(request)).await {
        Ok(Ok(receipt)) => (StatusCode::OK, Json(json!({
            "ok":true, "provider_id":receipt.provider_id, "token":receipt.token,
            "version":receipt.version, "registered":receipt.registered, "collisions":receipt.collisions,
        }))).into_response(),
        Ok(Err(error)) => registration_error(error),
        Err(_) => error_response(StatusCode::INTERNAL_SERVER_ERROR, codes::INTERNAL, "provider registration task failed"),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Deregister {
    provider_id: String,
}

pub(super) async fn deregister(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Json(request): Json<Deregister>,
) -> Response {
    if !matches!(identity(&state, &headers), Some(CallerIdentity::Provider(id)) if id == request.provider_id)
    {
        return unauthorized();
    }
    let token = bearer(&headers).unwrap_or_default().to_owned();
    match tokio::task::spawn_blocking(move || {
        registry_runtime::current().deregister(&request.provider_id, &token)
    })
    .await
    {
        Ok(Ok(())) => (StatusCode::OK, Json(json!({"ok":true}))).into_response(),
        Ok(Err(error)) => registration_error(error),
        Err(_) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            codes::INTERNAL,
            "provider deregistration task failed",
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::body::to_bytes;
    use axum::http::HeaderValue;
    use impress_service_core::provider::{
        ProviderConnection, ProviderExampleInput, ProviderIdentityInput, ProviderVerbInput,
        Registry, SafetyClaim, SchemaValidator,
    };
    use impress_service_core::registry_runtime::{HealthFuture, ProviderInvoker};
    use impress_service_core::ServiceFuture;
    use serde_json::{json, Value};

    use super::*;
    use crate::HostConfig;

    struct TestValidator;

    impl SchemaValidator for TestValidator {
        fn validate(&self, schema: &Value) -> Result<(), String> {
            schema
                .is_object()
                .then_some(())
                .ok_or_else(|| "schema must be an object".into())
        }

        fn validate_instance(&self, schema: &Value, value: &Value) -> Result<(), String> {
            let args = value.as_object().ok_or("arguments must be an object")?;
            for required in schema["required"].as_array().into_iter().flatten() {
                let name = required.as_str().ok_or("invalid required field")?;
                if !args.get(name).is_some_and(Value::is_string) {
                    return Err(format!("missing or invalid argument {name}"));
                }
            }
            Ok(())
        }
    }

    struct TestInvoker;

    impl ProviderInvoker for TestInvoker {
        fn validate_endpoint(&self, endpoint: &str) -> Result<(), String> {
            endpoint
                .starts_with("http://127.0.0.1:")
                .then_some(())
                .ok_or_else(|| "endpoint must be loopback".into())
        }

        fn health(&self, _connection: ProviderConnection) -> HealthFuture {
            Box::pin(async { true })
        }

        fn invoke(
            &self,
            _connection: ProviderConnection,
            _name: String,
            _args: Value,
        ) -> ServiceFuture {
            Box::pin(async { Ok(json!({"echo":"hello"})) })
        }
    }

    fn state() -> HttpState {
        HttpState {
            config: Arc::new(HostConfig {
                server_name: "test-host".into(),
                server_version: "0.1.0".into(),
                instructions: String::new(),
                allowed_tool_prefixes: vec![],
                resources: vec![],
                tool_ui: vec![],
                tool_file_params: vec![],
            }),
            bearer_token: Arc::from("host-secret"),
        }
    }

    fn headers(token: &str, provider_id: Option<&str>) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        if let Some(provider_id) = provider_id {
            headers.insert(
                "x-impress-provider-id",
                HeaderValue::from_str(provider_id).unwrap(),
            );
        }
        headers
    }

    fn request(prior_token: Option<String>, version: &str) -> RegistrationRequest {
        RegistrationRequest {
            provider: ProviderIdentityInput {
                id: "python-reference".into(),
                language: "python".into(),
                version: version.into(),
                endpoint: "http://127.0.0.1:23456".into(),
                token: prior_token,
            },
            verbs: vec![ProviderVerbInput {
                name: "python-reference-service_echo".into(),
                description: "Echo text".into(),
                input_schema: json!({
                    "type":"object",
                    "properties":{"text":{"type":"string","description":"Text to echo"}},
                    "required":["text"],
                    "additionalProperties":false
                }),
                output_schema: json!({
                    "type":"object",
                    "properties":{"echo":{"type":"string"}},
                    "required":["echo"],
                    "additionalProperties":false
                }),
                safety: SafetyClaim {
                    class: "read-only".into(),
                    idempotent: Some(true),
                },
                since: "1.0.0".into(),
                examples: vec![ProviderExampleInput {
                    name: "echo".into(),
                    args: json!({"text":"hello"}),
                    expect: Some(json!({"echo":"hello"})),
                }],
            }],
        }
    }

    async fn response_json(response: Response) -> (StatusCode, Value) {
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        (status, serde_json::from_slice(&bytes).unwrap())
    }

    #[tokio::test]
    async fn routes_scope_host_and_provider_credentials_and_rotate_them() {
        registry_runtime::install(Arc::new(
            Registry::new().with_validator(Arc::new(TestValidator)),
        ));
        registry_runtime::install_invoker(Arc::new(TestInvoker));
        let state = state();

        let mut malformed = request(None, "1.0.0");
        malformed.verbs.clear();
        let (status, body) = response_json(
            register(
                State(state.clone()),
                headers("host-secret", None),
                Json(malformed),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["code"], codes::INVALID_ARGUMENT);

        let mut remote = request(None, "1.0.0");
        remote.provider.endpoint = "http://example.com:23456".into();
        let (status, body) = response_json(
            register(
                State(state.clone()),
                headers("host-secret", None),
                Json(remote),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["code"], codes::INVALID_ARGUMENT);

        let (status, body) = response_json(
            register(
                State(state.clone()),
                HeaderMap::new(),
                Json(request(None, "1.0.0")),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["code"], "unauthorized");

        let mut claimed_person = headers("host-secret", Some("python-reference"));
        claimed_person.insert("x-impress-caller", HeaderValue::from_static("person"));
        assert!(matches!(
            identity(&state, &claimed_person),
            Some(CallerIdentity::Agent(_))
        ));
        let (status, body) = response_json(
            register(
                State(state.clone()),
                claimed_person,
                Json(request(None, "1.0.0")),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["provider_id"], "python-reference");
        let first = body["token"].as_str().unwrap().to_owned();

        let mut provider_headers = headers(&first, Some("python-reference"));
        provider_headers.insert("x-impress-caller", HeaderValue::from_static("person"));
        assert_eq!(
            identity(&state, &provider_headers),
            Some(CallerIdentity::Provider("python-reference".into()))
        );
        assert_eq!(identity(&state, &headers(&first, None)), None);
        assert_eq!(
            identity(&state, &headers(&first, Some("other-provider"))),
            None
        );
        let mut different_id = request(Some(first.clone()), "1.1.0");
        different_id.provider.id = "other-provider".into();
        let (status, _) = response_json(
            register(
                State(state.clone()),
                provider_headers.clone(),
                Json(different_id),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let (status, body) = response_json(
            register(
                State(state.clone()),
                provider_headers.clone(),
                Json(request(None, "1.1.0")),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body["code"], "forbidden");
        assert!(!body.to_string().contains(&first));

        let (status, body) = response_json(
            register(
                State(state.clone()),
                provider_headers,
                Json(request(Some(first.clone()), "1.1.0")),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let second = body["token"].as_str().unwrap().to_owned();
        assert_ne!(first, second);
        assert_eq!(
            identity(&state, &headers(&first, Some("python-reference"))),
            None
        );
        assert_eq!(
            identity(&state, &headers(&second, Some("python-reference"))),
            Some(CallerIdentity::Provider("python-reference".into()))
        );

        let (status, _) = response_json(
            deregister(
                State(state.clone()),
                headers("host-secret", None),
                Json(Deregister {
                    provider_id: "python-reference".into(),
                }),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, _) = response_json(
            deregister(
                State(state.clone()),
                headers(&first, Some("python-reference")),
                Json(Deregister {
                    provider_id: "python-reference".into(),
                }),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, body) = response_json(
            deregister(
                State(state.clone()),
                headers(&second, Some("python-reference")),
                Json(Deregister {
                    provider_id: "python-reference".into(),
                }),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["ok"], true);
        assert_eq!(
            identity(&state, &headers(&second, Some("python-reference"))),
            None
        );

        registry_runtime::install(Arc::new(Registry::new()));
    }

    #[tokio::test]
    async fn registration_errors_have_statuses_and_codes_matching_their_cause() {
        for (error, status, code) in [
            (
                RegistrationError::Invalid("bad descriptor".into()),
                StatusCode::BAD_REQUEST,
                codes::INVALID_ARGUMENT,
            ),
            (
                RegistrationError::Credential("bad prior credential".into()),
                StatusCode::FORBIDDEN,
                "forbidden",
            ),
            (
                RegistrationError::Persistence("database closed".into()),
                StatusCode::INTERNAL_SERVER_ERROR,
                codes::STORE_ERROR,
            ),
            (
                RegistrationError::ValidatorUnavailable,
                StatusCode::SERVICE_UNAVAILABLE,
                codes::HOST_UNAVAILABLE,
            ),
        ] {
            let (actual_status, body) = response_json(registration_error(error)).await;
            assert_eq!(actual_status, status);
            assert_eq!(body["code"], code);
            assert_eq!(body["wire_version"], WIRE_VERSION);
        }
    }
}
