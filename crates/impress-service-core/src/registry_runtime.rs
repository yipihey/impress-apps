//! Process-owned runtime provider registry and transport hooks.
//!
//! The pure service crate never opens a store or makes an HTTP request. A host
//! installs the validated, persisted registry and its AppTransport adapter.
//! Merely listing linked descriptors (including documentation generation) does
//! not open the user's database.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, LazyLock, RwLock};

use serde_json::Value;

use crate::descriptor_handle::VerbHandle;
use crate::provider::{
    ProviderConnection, RegistrationError, RegistrationReceipt, RegistrationRequest, Registry,
};
use crate::refusal::Refusal;
use crate::ServiceFuture;

pub type HealthFuture = Pin<Box<dyn Future<Output = bool> + Send + 'static>>;

/// Implemented by AppTransport, outside the kit's pure dependency boundary.
pub trait ProviderInvoker: Send + Sync {
    fn validate_endpoint(&self, endpoint: &str) -> Result<(), String>;
    fn health(&self, connection: ProviderConnection) -> HealthFuture;
    fn invoke(&self, connection: ProviderConnection, name: String, args: Value) -> ServiceFuture;
}

static REGISTRY: LazyLock<RwLock<Arc<Registry>>> =
    LazyLock::new(|| RwLock::new(Arc::new(Registry::new())));
static INVOKER: RwLock<Option<Arc<dyn ProviderInvoker>>> = RwLock::new(None);

pub fn current() -> Arc<Registry> {
    REGISTRY.read().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn install(registry: Arc<Registry>) {
    *REGISTRY.write().unwrap_or_else(|e| e.into_inner()) = registry;
}

pub fn install_invoker(invoker: Arc<dyn ProviderInvoker>) {
    *INVOKER.write().unwrap_or_else(|e| e.into_inner()) = Some(invoker);
}

fn invoker() -> Option<Arc<dyn ProviderInvoker>> {
    INVOKER.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Endpoint validation is shared with the actual outbound client, before any
/// provider credential is issued or metadata persisted.
pub fn register(request: RegistrationRequest) -> Result<RegistrationReceipt, RegistrationError> {
    let transport = invoker()
        .ok_or_else(|| RegistrationError::Invalid("provider transport is not installed".into()))?;
    transport
        .validate_endpoint(&request.provider.endpoint)
        .map_err(RegistrationError::Invalid)?;
    current().register(request)
}

fn unavailable(verb: &VerbHandle) -> Refusal {
    Refusal::new(
        crate::refusal::codes::HOST_UNAVAILABLE,
        format!(
            "{}: provider {} is unavailable or its registration changed",
            verb.name(),
            verb.provider_id().unwrap_or("unknown")
        ),
    )
}

pub(crate) fn check_available(verb: &VerbHandle, args: &Value) -> Result<(), Refusal> {
    if let VerbHandle::Provider(provider) = verb {
        if invoker().is_none() || current().current_connection(provider).is_none() {
            return Err(unavailable(verb));
        }
        current().validate_args(provider, args)?;
    }
    Ok(())
}

/// Called only by the pipeline's invoke layer, under its identity/trace scope.
pub(crate) async fn invoke(verb: &VerbHandle, args: Value) -> Result<Value, crate::BoxError> {
    let VerbHandle::Provider(provider) = verb else {
        return Err("provider invoker received a linked descriptor".into());
    };
    let registry = current();
    let refresh = registry.clone();
    if !matches!(tokio::task::spawn_blocking(move || refresh.refresh_persisted()).await, Ok(Ok(()))) {
        return Ok(crate::strict::refusal_value(&unavailable(verb)));
    }
    let Some(connection) = registry.current_connection(provider) else {
        return Ok(crate::strict::refusal_value(&unavailable(verb)));
    };
    let Some(transport) = invoker() else {
        return Ok(crate::strict::refusal_value(&unavailable(verb)));
    };
    let result = transport
        .invoke(connection, verb.name().to_owned(), args)
        .await;
    // An old in-flight call must not change a newer registration's health.
    if result
        .as_ref()
        .ok()
        .and_then(|v| v.get("code"))
        .and_then(Value::as_str)
        == Some(crate::refusal::codes::HOST_UNAVAILABLE)
    {
        let _ = registry.set_health_if_current(&provider.provider_id, provider.generation, false);
    }
    result
}

/// Hosts probe on startup and periodically; a departed verb stays in the
/// catalogue and a restored registration becomes callable only after health.
pub async fn refresh_health() {
    let Some(transport) = invoker() else { return };
    let registry = current();
    let refresh = registry.clone();
    if !matches!(tokio::task::spawn_blocking(move || refresh.refresh_persisted()).await, Ok(Ok(()))) {
        tracing::warn!("provider persistence refresh failed; calls remain unavailable");
        return;
    }
    for (id, connection) in registry.health_connections() {
        let generation = connection.generation();
        let healthy = transport.health(connection).await;
        let _ = registry.set_health_if_current(&id, generation, healthy);
    }
}
