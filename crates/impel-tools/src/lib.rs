//! The impress suite's tool surface, as impel's agent loop sees it.
//!
//! impel used to hand-write the model's view of the suite: 11 `AITool` literals,
//! a `switch` with one case per tool, and the same tool names again in prose in
//! the system prompt. Three copies, nothing checking that they agreed with each
//! other or with the suite. They didn't — 11 declared against 124 generated.
//!
//! This crate owns no capability of its own. It links the `*-service` crates so
//! their `#[impress_service]` methods land in the `McpToolDescriptor` inventory
//! at link time, and projects that inventory over UniFFI. Adding a capability
//! anywhere in the suite makes it available to impel with no impel change —
//! which is the entire point.
//!
//! The same inventory is what `crates/impress-mcp` serves over MCP, so agents
//! inside and outside impel see one surface.

use std::sync::OnceLock;

use impress_service_core::{runtime, McpToolDescriptor};

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// One tool as the model sees it. `input_schema_json` is a JSON Schema object,
/// passed through verbatim — impel re-parses it rather than re-deriving it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ToolDescriptor {
    pub name: String,
    /// The Rust trait method's doc comment. This is the prompt.
    pub description: String,
    pub input_schema_json: String,
    /// `imbib-library-service` for `imbib-library-service_create-collection`.
    /// Empty when the name carries no `<...>-service_` prefix.
    pub namespace: String,
}

/// Which backend actually installed for one sibling app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Backend {
    /// Calls route over HTTP to the running app. The only safe mode.
    Http,
    /// The app was not reachable. Calls would fall through to the shared
    /// SQLite store, behind the running app's back — refused, see below.
    Unavailable,
}

/// What `configure` managed to wire up.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ToolBackends {
    pub imbib: Backend,
    pub imprint: Backend,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ToolError {
    #[error("unknown tool: {name}")]
    UnknownTool { name: String },
    #[error("{name} arguments are not a JSON object: {message}")]
    BadArguments { name: String, message: String },
    #[error("{name} failed: {message}")]
    Handler { name: String, message: String },
    /// The owning app is not running. Deliberately distinct from `Handler` so
    /// impel can drop the namespace for this round rather than surfacing a
    /// failure the model would retry.
    #[error("{app} is not running, so {name} is unavailable")]
    AppUnavailable { app: String, name: String },
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

static BACKENDS: OnceLock<ToolBackends> = OnceLock::new();

/// Point the service traits at the running sibling apps and report what
/// installed. Call once, before `call_tool`.
///
/// **Why the result matters.** `maybe_install_http_backend` falls back to the
/// default SQLite backend when its probe fails, and that fallback is silent.
/// impel writing the shared store directly would bypass every in-memory cache
/// in the running imbib and imprint — the failure class `apps/imbib/CLAUDE.md`
/// warns about, and one that shows up as stale UI long after the write. So a
/// failed probe is recorded as [`Backend::Unavailable`] and `call_tool` refuses
/// that app's tools outright. Falling back is never the quiet default.
///
/// Passing `None` for a URL leaves the corresponding env var alone, letting the
/// probe use its own default port.
#[uniffi::export]
pub fn configure(imbib_url: Option<String>, imprint_url: Option<String>) -> ToolBackends {
    BACKENDS
        .get_or_init(|| {
            if let Some(url) = imbib_url {
                std::env::set_var("IMBIB_HTTP_URL", url);
            }
            if let Some(url) = imprint_url {
                std::env::set_var("IMPRINT_HTTP_URL", url);
            }

            ToolBackends {
                imbib: backend_of(imbib_service_http::maybe_install_http_backend()),
                imprint: backend_of(imprint_service_http::maybe_install_http_backend()),
            }
        })
        .clone()
}

fn backend_of(http_installed: bool) -> Backend {
    if http_installed {
        Backend::Http
    } else {
        Backend::Unavailable
    }
}

/// What `configure` decided, or everything [`Backend::Unavailable`] if it was
/// never called — refusing by default is the safe direction.
fn backends() -> ToolBackends {
    BACKENDS.get().cloned().unwrap_or(ToolBackends {
        imbib: Backend::Unavailable,
        imprint: Backend::Unavailable,
    })
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

/// Every tool registered in this binary, from every linked `*-service` crate.
///
/// The three semantic-search tools that `crates/impress-mcp` also serves are
/// absent by construction: they live in that binary, not in the inventory, and
/// they need the fastembed model, which impel has no reason to carry.
#[uniffi::export]
pub fn list_tools() -> Vec<ToolDescriptor> {
    McpToolDescriptor::iter()
        .map(|d| ToolDescriptor {
            name: d.name.to_string(),
            description: d.description.to_string(),
            input_schema_json: (d.input_schema)().to_string(),
            namespace: namespace_of(d.name).unwrap_or_default().to_string(),
        })
        .collect()
}

/// Only the tools whose owning app is reachable. This is what impel should
/// advertise: a tool the model cannot successfully call is worse than absent,
/// because it spends a round discovering that.
#[uniffi::export]
pub fn list_available_tools() -> Vec<ToolDescriptor> {
    let backends = backends();
    list_tools()
        .into_iter()
        .filter(|t| app_backend(&t.name, &backends) == Some(Backend::Http))
        .collect()
}

/// Namespace for a generated name: `imbib-library-service_create-collection`
/// yields `imbib-library-service`. `None` when the prefix is not a service.
fn namespace_of(name: &str) -> Option<&str> {
    let (prefix, _) = name.split_once('_')?;
    prefix.ends_with("-service").then_some(prefix)
}

/// The sibling app a tool belongs to, from its namespace prefix.
fn app_of(name: &str) -> Option<&'static str> {
    let ns = namespace_of(name)?;
    if ns.starts_with("imbib-") {
        Some("imbib")
    } else if ns.starts_with("imprint-") {
        Some("imprint")
    } else {
        None
    }
}

fn app_backend(name: &str, backends: &ToolBackends) -> Option<Backend> {
    match app_of(name)? {
        "imbib" => Some(backends.imbib),
        "imprint" => Some(backends.imprint),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Invoke a tool by name with a JSON object of arguments; returns the handler's
/// JSON result as a string.
///
/// Dispatch is the descriptor's own handler — the same function
/// `crates/impress-mcp` calls — so impel and every MCP client run identical
/// code. There is no second implementation to drift.
#[uniffi::export]
pub fn call_tool(name: String, args_json: String) -> Result<String, ToolError> {
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == name)
        .ok_or_else(|| ToolError::UnknownTool { name: name.clone() })?;

    // Refuse before touching the handler: with no HTTP backend installed the
    // call would silently operate on the shared store instead of the app.
    if let Some(app) = app_of(&name) {
        if app_backend(&name, &backends()) != Some(Backend::Http) {
            return Err(ToolError::AppUnavailable {
                app: app.to_string(),
                name,
            });
        }
    }

    // MCP clients may omit arguments entirely; handlers deserialize from an
    // object, so an empty string and `null` both mean "no arguments".
    let trimmed = args_json.trim();
    let args = if trimmed.is_empty() || trimmed == "null" {
        serde_json::json!({})
    } else {
        serde_json::from_str(trimmed).map_err(|e| ToolError::BadArguments {
            name: name.clone(),
            message: e.to_string(),
        })?
    };

    let future = (descriptor.handler)(args);
    match runtime::block_on(future) {
        Ok(value) => Ok(value.to_string()),
        Err(e) => Err(ToolError::Handler {
            name,
            message: e.to_string(),
        }),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inventory_is_linked_in() {
        let tools = list_tools();
        assert!(
            tools.len() > 100,
            "expected the full service inventory, got {}",
            tools.len()
        );
        for expected in [
            "imbib-text-service_decode-latex",
            "imbib-library-service_create-collection",
            "imprint-manuscript-service_list-sections",
        ] {
            assert!(
                tools.iter().any(|t| t.name == expected),
                "expected {expected} in inventory",
            );
        }
    }

    /// The doc comment on `list_tools` claims the fastembed-backed semantic
    /// tools are absent by construction. Hold it to that — if they ever land in
    /// the inventory, impel would start advertising tools it cannot serve.
    #[test]
    fn semantic_search_tools_are_not_exposed() {
        let tools = list_tools();
        for legacy in ["search_papers", "get_paper_chunks", "list_indexed_papers"] {
            assert!(
                !tools.iter().any(|t| t.name == legacy),
                "{legacy} must not reach impel — it needs the embedding model",
            );
        }
        // Every exposed tool is a namespaced service method.
        for t in &tools {
            assert!(!t.namespace.is_empty(), "{} has no namespace", t.name);
        }
    }

    #[test]
    fn every_tool_carries_a_description_and_schema() {
        for t in list_tools() {
            assert!(!t.description.is_empty(), "{} has no description", t.name);
            let schema: serde_json::Value = serde_json::from_str(&t.input_schema_json)
                .unwrap_or_else(|e| panic!("{} has an unparseable schema: {e}", t.name));
            assert!(schema.is_object(), "{} schema is not an object", t.name);
        }
    }

    /// A ratchet on useless descriptions.
    ///
    /// The codegen only picks up `///` comments written **inside**
    /// `impress_service_impl! { methods = [...] }`. Doc comments on the trait
    /// itself are ignored, and those methods silently get
    /// `"Invoke ServiceName.method_name"` — which tells a model nothing, and
    /// which the earlier non-empty assertion happily accepted.
    ///
    /// Most of the inventory is still in that state. This does not fail the
    /// build over it; it stops the number growing, so new services are written
    /// with the docs in the place that reaches the model. Lower the bound as
    /// services are fixed — it may only go down.
    #[test]
    fn generic_descriptions_do_not_grow() {
        const BUDGET: usize = 113;

        let tools = list_tools();
        let generic: Vec<&str> = tools
            .iter()
            .filter(|t| t.description.starts_with("Invoke "))
            .map(|t| t.name.as_str())
            .collect();

        assert!(
            generic.len() <= BUDGET,
            "tools with a generic 'Invoke X.y' description rose to {} (budget {}). \
             Write the description inside impress_service_impl!'s methods = [...] \
             list, not on the trait method. Offenders include: {:?}",
            generic.len(),
            BUDGET,
            &generic[..generic.len().min(5)],
        );
    }

    #[test]
    fn namespaces_are_derived_for_service_tools() {
        assert_eq!(
            namespace_of("imbib-library-service_create-collection"),
            Some("imbib-library-service")
        );
        assert_eq!(
            app_of("imbib-library-service_create-collection"),
            Some("imbib")
        );
        assert_eq!(
            app_of("imprint-manuscript-service_list-sections"),
            Some("imprint")
        );
        // Legacy semantic-search names carry no service prefix.
        assert_eq!(namespace_of("search_papers"), None);
        assert_eq!(app_of("search_papers"), None);
    }

    #[test]
    fn unknown_tool_is_reported_as_such() {
        let err = call_tool("no-such-tool".into(), "{}".into()).unwrap_err();
        assert!(matches!(err, ToolError::UnknownTool { .. }), "got {err:?}");
    }

    /// The guard that matters: with no backend configured, a real tool must be
    /// refused rather than quietly falling through to the shared SQLite store.
    #[test]
    fn unconfigured_backend_refuses_rather_than_falling_back() {
        let err = call_tool(
            "imbib-library-service_create-collection".into(),
            "{}".into(),
        )
        .unwrap_err();
        assert!(
            matches!(err, ToolError::AppUnavailable { .. }),
            "expected a refusal, got {err:?}",
        );
    }

    #[test]
    fn available_tools_are_empty_when_nothing_is_reachable() {
        assert!(list_available_tools().is_empty());
    }
}
