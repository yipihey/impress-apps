//! Imprint's native inventory and live-app bridge. Public verb signatures
//! remain defined only by `imprint-service`.

use impress_service_core::dispatch;
mod native;
pub use native::{install_native_host, ImprintVerbHost, NativeReply};

#[allow(unused_imports)]
use imprint_service as _force_link_imprint_service;

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

#[cfg_attr(feature = "native", uniffi::export)]
pub async fn dispatch_verb_async(
    name: String,
    args_json: String,
    caller_json: String,
) -> SharedVerbDispatchResult {
    dispatch::dispatch_foreign_async(&name, &args_json, &caller_json)
        .await
        .into()
}
