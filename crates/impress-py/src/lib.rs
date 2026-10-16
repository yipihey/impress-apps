//! `impress` Python module (plan-verb-pipeline-and-transport.md § P6, D-P8,
//! finding PY-1), now a thin binding over `koine-py` (koine
//! docs/plan-koine-kit-moves.md KM1).
//!
//! The generic `list_verbs()` / `call(verb, args)` module, the in-process
//! dispatch and the P5 transport client all live in `koine_py`; what stays
//! here is what is impress's: **which inventory is linked**
//! (`impress-capabilities` with every service, force-linked by
//! [`force_link`]) and **which provider registry is refreshed**
//! (`impress-store-service`'s, from the selected workspace). The Python
//! module name (`impress`) and its behaviour are unchanged.
//!
//! The Rust functions are re-exported through wrappers that install the hooks
//! first, so `tests/dispatch.rs` exercises them without a Python interpreter.
//! The pyo3 module is behind the `python` feature, the same gating `im-bibtex`
//! and `im-identifiers` use, so a plain workspace build never needs the
//! interpreter headers.

use serde_json::Value;

pub use koine_py::VerbInfo;

fn force_link() {
    impress_capabilities::force_link();
}

/// An empty workspace leaves linked-only enumeration lazy: `Ok(false)`.
fn install_providers() -> Result<bool, String> {
    impress_store_service::providers::install_if_registered(std::sync::Arc::new(
        impress_app_transport::provider::JsonSchemaValidator,
    ))
    .map_err(|error| error.to_string())
}

fn hooks() -> koine_py::Hooks {
    koine_py::Hooks {
        force_link,
        reload_providers: install_providers,
    }
}

/// Every verb in the linked inventory: name, service, description, safety
/// class and input schema.
pub fn list_verb_infos() -> Vec<VerbInfo> {
    koine_py::set_hooks(hooks());
    koine_py::list_verb_infos()
}

/// `call(verb, args)` with no `app`: in-process, as `CallerIdentity::App("python")`.
pub fn call_local(verb: &str, args: Value) -> Result<Value, String> {
    koine_py::set_hooks(hooks());
    koine_py::call_local(verb, args)
}

/// `call(verb, args, app=...)`: over the P5 transport to a running app.
pub fn call_remote(app: &str, verb: &str, args: Value) -> Result<Value, String> {
    koine_py::call_remote(app, verb, args)
}

/// Refresh this process's runtime providers from its selected workspace.
pub fn reload_provider_registry() -> Result<(), String> {
    koine_py::set_hooks(hooks());
    koine_py::reload_provider_registry()
}

#[cfg(feature = "python")]
mod py {
    use pyo3::prelude::*;

    /// Python module: `impress`.
    #[pymodule]
    fn impress(m: &Bound<'_, PyModule>) -> PyResult<()> {
        koine_py::register(m, super::hooks())
    }
}
