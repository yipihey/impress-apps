//! Raw host-only provider primitives for the native store image.
//!
//! The store image owns native GUI policy and audit. This image separately
//! hydrates the same durable descriptors for impel's tool menus, but the raw
//! primitives below never enter a second verb pipeline.

use impress_app_transport::provider::{self, JsonSchemaValidator};
use impress_service_core::provider::SchemaValidator;
use impress_service_core::refusal::Refusal;
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

#[derive(Debug, Clone, uniffi::Record)]
pub struct ProviderPrimitiveReply {
    pub ok: bool,
    pub code: Option<String>,
    pub message: Option<String>,
    pub body_json: Option<String>,
}

static HEALTH_REFRESH: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);

/// Initialize this image's provider inventory from the same database the GUI
/// opened. A fallback or different already-selected store is a hard refusal.
#[uniffi::export]
pub fn configure_provider_store(path: String) -> ProviderPrimitiveReply {
    let requested = match Path::new(&path).canonicalize() {
        Ok(path) => path,
        Err(_) => {
            return ProviderPrimitiveReply::failure(Refusal::store_unavailable(
                "provider store path is unavailable",
            ))
        }
    };
    if impress_store_service::set_store_path(&requested).is_err() {
        let selected = impress_store_service::store_path().canonicalize();
        if selected.as_ref().ok() != Some(&requested) {
            return ProviderPrimitiveReply::failure(Refusal::store_unavailable(
                "provider store already selects a different database",
            ));
        }
    }
    let store = impress_store_service::store_instance();
    if impress_store_service::is_fallback_store(&store)
        || store
            .database_path()
            .and_then(|path| path.canonicalize().ok())
            .as_ref()
            != Some(&requested)
    {
        return ProviderPrimitiveReply::failure(Refusal::store_unavailable(
            "provider store is unavailable or differs from the GUI database",
        ));
    }
    let Some(workspace) = requested.parent() else {
        return ProviderPrimitiveReply::failure(Refusal::store_unavailable(
            "provider store has no workspace",
        ));
    };
    match impress_store_service::providers::install_for_store(
        store,
        workspace,
        Arc::new(JsonSchemaValidator),
    ) {
        Ok(_) => {
            // This image's registry is independent of ImpressRustCore's.
            // Install its raw transport even when sibling probing is skipped
            // (e.g. an isolated GUI test), then refresh immediately and every
            // five seconds so tool menus observe provider liveness.
            provider::install();
            let mut refresh = HEALTH_REFRESH
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            if let Some(previous) = refresh.take() {
                previous.abort();
            }
            *refresh = Some(impress_service_core::runtime::spawn(async {
                let mut interval = tokio::time::interval(Duration::from_secs(5));
                loop {
                    interval.tick().await;
                    impress_service_core::registry_runtime::refresh_health().await;
                }
            }));
            ProviderPrimitiveReply::success(None)
        }
        Err(error) => ProviderPrimitiveReply::failure(Refusal::store_unavailable(format!(
            "provider inventory unavailable: {error}"
        ))),
    }
}

impl ProviderPrimitiveReply {
    fn success(body_json: Option<String>) -> Self {
        Self {
            ok: true,
            code: None,
            message: None,
            body_json,
        }
    }

    fn failure(refusal: Refusal) -> Self {
        Self {
            ok: false,
            code: Some(refusal.code),
            message: Some(refusal.message),
            body_json: None,
        }
    }
}

fn parse_json(input: &str) -> Result<Value, Refusal> {
    serde_json::from_str(input)
        .map_err(|_| Refusal::invalid_argument("provider input is not valid JSON"))
}

#[uniffi::export]
pub fn provider_validate_schema(schema_json: String) -> ProviderPrimitiveReply {
    let result = parse_json(&schema_json).and_then(|schema| {
        JsonSchemaValidator
            .validate(&schema)
            .map_err(Refusal::invalid_argument)
    });
    match result {
        Ok(()) => ProviderPrimitiveReply::success(None),
        Err(refusal) => ProviderPrimitiveReply::failure(refusal),
    }
}

#[uniffi::export]
pub fn provider_validate_instance(
    schema_json: String,
    args_json: String,
) -> ProviderPrimitiveReply {
    let result = parse_json(&schema_json).and_then(|schema| {
        parse_json(&args_json).and_then(|args| {
            JsonSchemaValidator
                .validate_instance(&schema, &args)
                .map_err(Refusal::invalid_argument)
        })
    });
    match result {
        Ok(()) => ProviderPrimitiveReply::success(None),
        Err(refusal) => ProviderPrimitiveReply::failure(refusal),
    }
}

#[uniffi::export]
pub fn provider_validate_endpoint(endpoint: String) -> ProviderPrimitiveReply {
    match provider::validate_endpoint(&endpoint) {
        Ok(()) => ProviderPrimitiveReply::success(None),
        Err(refusal) => ProviderPrimitiveReply::failure(refusal),
    }
}

#[uniffi::export]
pub fn provider_health(endpoint: String, token: String) -> ProviderPrimitiveReply {
    match impress_service_core::runtime::block_on(provider::health(&endpoint, &token)) {
        Ok(()) => ProviderPrimitiveReply::success(None),
        Err(refusal) => ProviderPrimitiveReply::failure(refusal),
    }
}

#[uniffi::export]
pub fn provider_call(
    endpoint: String,
    token: String,
    name: String,
    args_json: String,
    trace_id: Option<String>,
    parent_call_id: Option<String>,
) -> ProviderPrimitiveReply {
    let result = impress_service_core::runtime::block_on(async {
        let args = parse_json(&args_json)?;
        let value = provider::call_with_parent(
            &endpoint,
            &token,
            &name,
            args,
            trace_id.as_deref(),
            parent_call_id.as_deref(),
        )
        .await?;
        serde_json::to_string(&value)
            .map_err(|_| Refusal::new("verb-failed", "cannot encode provider response"))
    });
    match result {
        Ok(body) => ProviderPrimitiveReply::success(Some(body)),
        Err(refusal) => ProviderPrimitiveReply::failure(refusal),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_primitives_reject_invalid_instances_without_echoing_values() {
        let schema = r#"{"type":"object","properties":{"secret":{"type":"string","minLength":4}},"required":["secret"]}"#;
        assert!(provider_validate_schema(schema.into()).ok);
        let reply = provider_validate_instance(schema.into(), r#"{"secret":"pii"}"#.into());
        assert!(!reply.ok);
        assert!(!reply.message.unwrap().contains("pii"));
    }
}
