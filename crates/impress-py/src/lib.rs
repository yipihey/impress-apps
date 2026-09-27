//! `impress` Python module (plan-verb-pipeline-and-transport.md § P6, D-P8,
//! finding PY-1).
//!
//! One generic binding over the whole inventory — `list_verbs()` and
//! `call(verb, args)` — instead of a per-method shim for each of the
//! ~433 `#[impress_method]` signatures. It has **no path of its own**:
//!
//! * `list_verbs()` reads [`impress_service_core::descriptor::VerbDescriptor::iter`],
//!   the same linked inventory the CLI and MCP servers read.
//! * `call(verb, args)` with no `app` argument goes through
//!   [`impress_service_core::dispatch::dispatch`], the same by-name
//!   dispatch the FFI verb host and `implore-verbs-ffi` use — args parsed,
//!   looked up, run through `pipeline::invoke_blocking` with
//!   `CallerIdentity::App("python")` (this module speaks for the process
//!   it is imported into, exactly as the FFI host does; there is no
//!   sandboxed "the model asked for this" boundary here the way there is
//!   for an agent caller, so `App` is the honest identity, not `Agent`).
//! * `call(verb, args, app="impress")` goes over
//!   [`impress_app_transport::call`] to a running app's automation server
//!   instead — the P5 transport, unchanged.
//!
//! The logic above ([`list_verb_infos`], [`call_local`], [`call_remote`])
//! is plain Rust with no `pyo3` in its signature, so it is unit-tested
//! directly (`tests/dispatch.rs`) without a Python interpreter. The pyo3
//! wrappers that expose it as the `impress` module are behind the
//! `python` feature — the same gating `im-bibtex` and `im-identifiers`
//! already use for their pyo3 modules — so a plain `cargo build`/`cargo
//! test` of the workspace never needs the Python interpreter headers.

use impress_service_core::descriptor::VerbDescriptor;
use serde_json::Value;

/// One verb's public shape, as the catalogue and `docs/verbs/` show it —
/// enough for a caller to build a call without reading Rust source.
#[derive(Debug, Clone, PartialEq)]
pub struct VerbInfo {
    pub name: String,
    pub service: String,
    pub description: String,
    pub safety: String,
    pub input_schema: Value,
}

fn verb_info(verb: &'static VerbDescriptor) -> VerbInfo {
    VerbInfo {
        name: verb.name.to_string(),
        service: verb.service.to_string(),
        description: verb.description.to_string(),
        safety: verb.safety.class.to_string(),
        input_schema: (verb.input_schema)(),
    }
}

/// Every verb in the linked inventory: name, service, description, safety
/// class and input schema — the columns `docs/verbs/` generates from the
/// same descriptor. Force-links the inventory first (`force_link`'s own
/// doc comment: nothing else in this crate calls the service crates by
/// name, so the linker can otherwise strip them from a cdylib).
pub fn list_verb_infos() -> Vec<VerbInfo> {
    impress_capabilities::force_link();
    VerbDescriptor::iter().map(verb_info).collect()
}

/// `call(verb, args)` with no `app`: in-process, through
/// [`impress_service_core::dispatch::dispatch`] — the same generic by-name
/// dispatch the FFI verb host uses — with `CallerIdentity::App("python")`.
/// `Err` carries the pipeline's own message (a refusal's `message` field,
/// or a JSON-parse error).
pub fn call_local(verb: &str, args: Value) -> Result<Value, String> {
    impress_capabilities::force_link();
    let args_json = args.to_string();
    let caller_json = r#"{"kind": "app", "name": "python"}"#;
    let outcome = impress_service_core::dispatch::dispatch(verb, &args_json, caller_json);
    let body: Value = serde_json::from_str(&outcome.body_json).map_err(|e| e.to_string())?;
    if outcome.status >= 400 {
        let message = body
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("verb call failed")
            .to_string();
        return Err(message);
    }
    Ok(body)
}

/// `call(verb, args, app=...)`: over the P5 transport to a running app's
/// automation server, unchanged — [`impress_app_transport::call`].
pub fn call_remote(app: &str, verb: &str, args: Value) -> Result<Value, String> {
    impress_service_core::runtime::block_on(impress_app_transport::call(app, verb, args))
        .map_err(|refusal| refusal.to_string())
}

#[cfg(feature = "python")]
mod py {
    use super::{call_local, call_remote, list_verb_infos, VerbInfo};
    use pyo3::exceptions::{PyRuntimeError, PyValueError};
    use pyo3::prelude::*;
    use pyo3::types::PyDict;
    use pythonize::{depythonize, pythonize};
    use serde_json::Value;

    #[pyclass(name = "VerbInfo")]
    pub struct PyVerbInfo {
        #[pyo3(get)]
        pub name: String,
        #[pyo3(get)]
        pub service: String,
        #[pyo3(get)]
        pub description: String,
        #[pyo3(get)]
        pub safety: String,
        #[pyo3(get)]
        pub input_schema: Py<PyAny>,
    }

    #[pymethods]
    impl PyVerbInfo {
        fn __repr__(&self) -> String {
            format!(
                "VerbInfo(name={:?}, service={:?}, safety={:?})",
                self.name, self.service, self.safety
            )
        }
    }

    fn to_py_verb_info(py: Python<'_>, info: VerbInfo) -> PyResult<PyVerbInfo> {
        Ok(PyVerbInfo {
            name: info.name,
            service: info.service,
            description: info.description,
            safety: info.safety,
            input_schema: pythonize(py, &info.input_schema)
                .map_err(|e| PyRuntimeError::new_err(e.to_string()))?
                .into(),
        })
    }

    /// Every verb in the linked inventory: name, service, description,
    /// safety class and input schema.
    #[pyfunction]
    fn list_verbs(py: Python<'_>) -> PyResult<Vec<PyVerbInfo>> {
        list_verb_infos()
            .into_iter()
            .map(|info| to_py_verb_info(py, info))
            .collect()
    }

    /// Call one verb, in-process (`app=None`, the default) or against a
    /// running app (`app="impress"`, `"imbib"`, …, over the P5 transport).
    ///
    /// `args` is a plain `dict`; the result is the wire envelope's `dict`
    /// (`{"ok": true, …}`) — a refusal raises `RuntimeError` rather than
    /// making every caller check `result["ok"]`.
    #[pyfunction]
    #[pyo3(signature = (verb, args=None, app=None))]
    fn call(
        py: Python<'_>,
        verb: &str,
        args: Option<Bound<'_, PyDict>>,
        app: Option<&str>,
    ) -> PyResult<Py<PyAny>> {
        let args_value: Value = match &args {
            Some(dict) => depythonize(dict).map_err(|e| PyValueError::new_err(e.to_string()))?,
            None => Value::Object(Default::default()),
        };

        let result = match app {
            Some(app_name) => {
                let app_name = app_name.to_string();
                let verb = verb.to_string();
                py.allow_threads(|| call_remote(&app_name, &verb, args_value))
                    .map_err(PyRuntimeError::new_err)?
            }
            None => {
                let verb = verb.to_string();
                py.allow_threads(|| call_local(&verb, args_value))
                    .map_err(PyRuntimeError::new_err)?
            }
        };

        pythonize(py, &result)
            .map(Into::into)
            .map_err(|e| PyRuntimeError::new_err(e.to_string()))
    }

    /// Python module: `impress`.
    #[pymodule]
    fn impress(m: &Bound<'_, PyModule>) -> PyResult<()> {
        m.add_class::<PyVerbInfo>()?;
        m.add_function(wrap_pyfunction!(list_verbs, m)?)?;
        m.add_function(wrap_pyfunction!(call, m)?)?;
        Ok(())
    }
}
