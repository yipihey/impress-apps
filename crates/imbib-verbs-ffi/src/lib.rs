//! Imbib's app-owned UniFFI target for service verbs.
//!
//! The shared store FFI links kit services only. This target links
//! `imbib-service` so its registered verbs are available to the GUI.

use std::path::PathBuf;
use std::sync::Mutex;

use impress_service_core::dispatch;

// Inventory registration is link-time work: retain imbib-service even though
// dispatch only names a verb at runtime.
#[allow(unused_imports)]
use imbib_service as _force_link_imbib_service;

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

#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, thiserror::Error)]
pub enum ImbibVerbStoreError {
    #[error("Invalid store path: {message}")]
    InvalidPath { message: String },
    #[error("Imbib verb store initialization failed: {message}")]
    Initialization { message: String },
    #[error("Imbib verb store was already initialized for a different path")]
    DifferentPath,
}

// Track only successful initialization through this FFI. Holding the mutex
// across init prevents two GUI calls from racing into the service singleton.
static INITIALIZED_PATH: Mutex<Option<String>> = Mutex::new(None);

#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

/// Open the service singleton at the GUI's exact database path before the
/// first verb dispatch. Repeating that path is safe; changing it is not.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn initialize_verb_store(path: String) -> Result<(), ImbibVerbStoreError> {
    if path.is_empty() {
        return Err(ImbibVerbStoreError::InvalidPath {
            message: "path is empty".into(),
        });
    }

    let mut initialized =
        INITIALIZED_PATH
            .lock()
            .map_err(|error| ImbibVerbStoreError::Initialization {
                message: error.to_string(),
            })?;
    match initialized.as_ref() {
        Some(existing) if existing == &path => return Ok(()),
        Some(_) => return Err(ImbibVerbStoreError::DifferentPath),
        None => {}
    }

    imbib_service::init_imbib_store(PathBuf::from(&path))
        .map_err(|message| ImbibVerbStoreError::Initialization { message })?;
    *initialized = Some(path);
    Ok(())
}

/// Dispatch one registered verb through the shared invoker pipeline.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn dispatch_verb(
    name: String,
    args_json: String,
    caller_json: String,
) -> SharedVerbDispatchResult {
    dispatch::dispatch(&name, &args_json, &caller_json).into()
}
