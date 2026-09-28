//! Impart's app-owned UniFFI target for service verbs and native app state.
//!
//! The shared store FFI links kit services only. This target links
//! `impart-service`, and the GUI installs an async backend backed by its
//! existing Core Data and log services.

use impress_service_core::dispatch;

// Keep the service's inventory entries linked for by-name dispatch.
#[allow(unused_imports)]
use impart_service as _force_link_impart_service;

mod native;

pub use native::{register_native_backend, ImpartNativeCallbacks, NativeCallResult};

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedVerbDispatchResult {
    pub status: u16,
    pub body_json: String,
}

impl From<dispatch::DispatchResult> for SharedVerbDispatchResult {
    fn from(result: dispatch::DispatchResult) -> Self {
        Self {
            status: result.status,
            body_json: result.body_json,
        }
    }
}

#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

/// Run an impart verb through the same async invoker used by the other routes.
#[cfg_attr(feature = "native", uniffi::export)]
pub async fn dispatch_verb(
    name: String,
    args_json: String,
    caller_json: String,
) -> SharedVerbDispatchResult {
    dispatch::dispatch_foreign_async(&name, &args_json, &caller_json)
        .await
        .into()
}
