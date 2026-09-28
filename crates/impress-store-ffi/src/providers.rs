//! Native callback for the non-kit pieces of a runtime provider.
//!
//! The registry, exact GUI store, policy, catalogue, and audit stay in this
//! image. Swift forwards validation and raw network I/O to ImpelToolsFFI;
//! Swift never registers or dispatches a second provider pipeline. The
//! ImpelToolsFFI image has its own read-only inventory for agent tool menus.

use std::sync::Arc;

use impress_service_core::pipeline::context;
use impress_service_core::provider::{ProviderConnection, SchemaValidator};
use impress_service_core::refusal::{codes, Refusal};
use impress_service_core::registry_runtime::{HealthFuture, ProviderInvoker};
use impress_service_core::ServiceFuture;
use serde_json::Value;

use crate::{SharedStore, SharedStoreError};

#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SharedProviderReply {
    pub ok: bool,
    pub code: Option<String>,
    pub message: Option<String>,
    pub body_json: Option<String>,
}

#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
pub trait SharedProviderHost: Send + Sync {
    fn validate_endpoint(&self, endpoint: String) -> SharedProviderReply;
    fn validate_schema(&self, schema_json: String) -> SharedProviderReply;
    fn validate_instance(&self, schema_json: String, args_json: String) -> SharedProviderReply;
    fn health(&self, endpoint: String, token: String) -> SharedProviderReply;
    fn invoke(
        &self,
        endpoint: String,
        token: String,
        name: String,
        args_json: String,
        trace_id: Option<String>,
        parent_call_id: Option<String>,
    ) -> SharedProviderReply;
}

fn failure(reply: SharedProviderReply, fallback: &str) -> Refusal {
    Refusal::new(
        reply.code.unwrap_or_else(|| codes::HOST_UNAVAILABLE.into()),
        reply.message.unwrap_or_else(|| fallback.into()),
    )
}

struct HostValidator(Arc<dyn SharedProviderHost>);

impl SchemaValidator for HostValidator {
    fn validate(&self, schema: &Value) -> Result<(), String> {
        let schema = serde_json::to_string(schema).map_err(|_| "cannot encode schema")?;
        let reply = self.0.validate_schema(schema);
        if reply.ok {
            Ok(())
        } else {
            Err(failure(reply, "provider schema validation unavailable").message)
        }
    }

    fn validate_instance(&self, schema: &Value, args: &Value) -> Result<(), String> {
        let schema = serde_json::to_string(schema).map_err(|_| "cannot encode schema")?;
        let args = serde_json::to_string(args).map_err(|_| "cannot encode arguments")?;
        let reply = self.0.validate_instance(schema, args);
        if reply.ok {
            Ok(())
        } else {
            Err(failure(reply, "provider argument validation unavailable").message)
        }
    }
}

struct HostInvoker(Arc<dyn SharedProviderHost>);

impl ProviderInvoker for HostInvoker {
    fn validate_endpoint(&self, endpoint: &str) -> Result<(), String> {
        let reply = self.0.validate_endpoint(endpoint.into());
        if reply.ok {
            Ok(())
        } else {
            Err(failure(reply, "provider endpoint validation unavailable").message)
        }
    }

    fn health(&self, connection: ProviderConnection) -> HealthFuture {
        let host = self.0.clone();
        Box::pin(async move {
            tokio::task::spawn_blocking(move || {
                host.health(connection.endpoint().into(), connection.token().into())
                    .ok
            })
            .await
            .unwrap_or(false)
        })
    }

    fn invoke(&self, connection: ProviderConnection, name: String, args: Value) -> ServiceFuture {
        let host = self.0.clone();
        // The task-local context belongs to this Rust image. Capture before
        // crossing UniFFI; the transport image has a different task local.
        let call = context::current();
        Box::pin(async move {
            let args_json = serde_json::to_string(&args)?;
            let reply = tokio::task::spawn_blocking(move || {
                host.invoke(
                    connection.endpoint().into(),
                    connection.token().into(),
                    name,
                    args_json,
                    call.as_ref().map(|c| c.trace_id.clone()),
                    call.as_ref().map(|c| c.call_id.clone()),
                )
            })
            .await?;
            if !reply.ok {
                return Ok(impress_service_core::strict::refusal_value(&failure(
                    reply,
                    "provider transport unavailable",
                )));
            }
            let Some(body) = reply.body_json else {
                return Ok(impress_service_core::strict::refusal_value(&Refusal::new(
                    codes::VERB_FAILED,
                    "provider transport returned no result",
                )));
            };
            Ok(serde_json::from_str(&body)?)
        })
    }
}

pub(crate) fn install(
    store: &SharedStore,
    host: Arc<dyn SharedProviderHost>,
) -> Result<(), SharedStoreError> {
    let workspace = store
        .blob_root_parent()
        .ok_or_else(|| SharedStoreError::InvalidArgument {
            message: "provider registry requires a file-backed workspace".into(),
        })?;
    impress_store_service::providers::install_for_store(
        store.core(),
        &workspace,
        Arc::new(HostValidator(host.clone())),
    )
    .map_err(|error| SharedStoreError::Storage {
        message: error.to_string(),
    })?;
    impress_service_core::registry_runtime::install_invoker(Arc::new(HostInvoker(host)));
    Ok(())
}
