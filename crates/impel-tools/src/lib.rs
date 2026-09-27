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

use impress_service_core::McpToolDescriptor;

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

/// Configuration is explicit: an unconfigured host never probes siblings or
/// silently runs their store-backed defaults. Verdicts and cooldowns live only
/// in AppTransport; this flag records whether the host authorized routing.
static CONFIGURED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Configure the shared transport and report the two sibling app backends.
/// Passing `None` preserves the environment's URL override and default port.
#[uniffi::export]
pub fn configure(imbib_url: Option<String>, imprint_url: Option<String>) -> ToolBackends {
    static CONFIGURE: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = CONFIGURE.lock().unwrap_or_else(|error| error.into_inner());
    if !CONFIGURED.load(std::sync::atomic::Ordering::Acquire) {
        if let Some(url) = imbib_url {
            std::env::set_var("IMPRESS_IMBIB_HTTP_URL", url);
        }
        if let Some(url) = imprint_url {
            std::env::set_var("IMPRESS_IMPRINT_HTTP_URL", url);
        }
        impress_app_transport::install(false);
        CONFIGURED.store(true, std::sync::atomic::Ordering::Release);
    }
    ToolBackends {
        imbib: backend_of(impress_app_transport::probe_app_blocking("imbib")),
        imprint: backend_of(impress_app_transport::probe_app_blocking("imprint")),
    }
}

fn backend_for(app: &str, backends: &ToolBackends) -> Option<Backend> {
    match app {
        "imbib" => Some(backends.imbib),
        "imprint" => Some(backends.imprint),
        _ => None,
    }
}

fn backend_of(reachable: bool) -> Backend {
    if reachable {
        Backend::Http
    } else {
        Backend::Unavailable
    }
}

/// Listing refreshes through the same bounded, cached probe as invocation.
fn backends() -> ToolBackends {
    let configured = CONFIGURED.load(std::sync::atomic::Ordering::Acquire);
    ToolBackends {
        imbib: backend_of(configured && impress_app_transport::probe_app_blocking("imbib")),
        imprint: backend_of(configured && impress_app_transport::probe_app_blocking("imprint")),
    }
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
    impress_capabilities::force_link();
    McpToolDescriptor::iter()
        .map(|d| ToolDescriptor {
            name: d.name.to_string(),
            description: d.description.to_string(),
            input_schema_json: (d.input_schema)().to_string(),
            namespace: namespace_of(d.name).unwrap_or_default().to_string(),
        })
        .collect()
}

/// Only the tools impel can actually call right now: store-generic tools (no
/// owning app) are always included, and imbib-/imprint- tools are included
/// only when their app backend is reachable. This is what impel should
/// advertise: a tool the model cannot successfully call is worse than absent,
/// because it spends a round discovering that.
#[uniffi::export]
pub fn list_available_tools() -> Vec<ToolDescriptor> {
    let backends = backends();
    list_tools()
        .into_iter()
        .filter(|t| is_available(&t.name, &backends))
        .collect()
}

/// Namespace for a generated name: `imbib-library-service_create-collection`
/// yields `imbib-library-service`. `None` when the prefix is not a service.
fn namespace_of(name: &str) -> Option<&str> {
    let (prefix, _) = name.split_once('_')?;
    prefix.ends_with("-service").then_some(prefix)
}

/// The sibling app a tool belongs to (`imbib`, `imprint`), from its
/// namespace prefix — `None` for a tool no app owns (it runs against the
/// shared store and is never unavailable). Exported so a host (impress's
/// verb host) asks rather than keeps a copy of this rule (review RS-S19).
#[uniffi::export]
pub fn tool_app(name: String) -> Option<String> {
    app_of(&name).map(str::to_string)
}

/// The sibling app a tool belongs to, from its namespace prefix — the
/// pipeline's one ownership table, restricted to the two apps this crate
/// carries a backend for.
fn app_of(name: &str) -> Option<&'static str> {
    namespace_of(name)?;
    impress_service_core::pipeline::reachability::owner_of(name)
        .filter(|app| matches!(*app, "imbib" | "imprint"))
}

fn app_backend(name: &str, backends: &ToolBackends) -> Option<Backend> {
    backend_for(app_of(name)?, backends)
}

/// Whether a tool should be advertised as available under `backends`.
///
/// A namespace no app owns runs against the shared store directly and is
/// always available; a namespace an app owns needs that app's HTTP backend up.
fn is_available(name: &str, backends: &ToolBackends) -> bool {
    matches!(app_backend(name, backends), Some(Backend::Http) | None)
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
    impress_capabilities::force_link();
    let descriptor = McpToolDescriptor::iter()
        .find(|d| d.name == name)
        .ok_or_else(|| ToolError::UnknownTool { name: name.clone() })?;

    if let Some(app) = app_of(&name) {
        if !CONFIGURED.load(std::sync::atomic::Ordering::Acquire) {
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

    // impel's tool loop is an agent (ADR-0034 D3); the surface runtime in
    // the app reaches this through `ImpressVerbHost` and is one too.
    let outcome = impress_service_core::pipeline::invoke_blocking(
        descriptor.verb,
        impress_service_core::pipeline::Call::agent("impel", args),
    );
    match outcome {
        Ok(value)
            if value.get("code").and_then(serde_json::Value::as_str)
                == Some("host-unavailable") =>
        {
            Err(ToolError::AppUnavailable {
                app: app_of(&name).unwrap_or("app").to_string(),
                name,
            })
        }
        Ok(value) => Ok(value.to_string()),
        Err(impress_service_core::pipeline::PipelineError::Unavailable { app, .. }) => {
            Err(ToolError::AppUnavailable {
                app: app.to_string(),
                name,
            })
        }
        Err(impress_service_core::pipeline::PipelineError::Handler(e)) => Err(ToolError::Handler {
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
        const BUDGET: usize = 54;

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

    /// With both app backends unavailable, imbib-/imprint- tools are withheld
    /// — but a tool in a namespace no app owns (the store-generic services:
    /// ADR-0022 WP G1's `store-query-service`, `collection-service`,
    /// `triage-service`, and friends, e.g. the upcoming `memory-service`)
    /// stays available, because it reads the shared store directly rather
    /// than going through a running app.
    ///
    /// No store-generic `*-service` crate is linked into `impel-tools` today
    /// (see Cargo.toml: only imbib-service(-http) and imprint-service(-http)),
    /// so there is no real store-generic entry in `list_tools()` yet to
    /// assert against. Exercise `is_available` — the same predicate
    /// `list_available_tools` filters with — directly against names shaped
    /// like the real inventory instead.
    #[test]
    fn store_generic_tools_are_available_without_app_backends() {
        let backends = backends();

        // A namespace no app owns: always available, backends or not.
        for store_generic in [
            "store-query-service_search-all",
            "collection-service_tree",
            "triage-service_set-status",
        ] {
            assert!(
                is_available(store_generic, &backends),
                "{store_generic} has no owning app and must always be available",
            );
        }

        // Whatever is actually linked into this binary, every imbib-/imprint-
        // tool in it is withheld while both app backends are down. Checked
        // against the live inventory (not `is_empty()`) so this keeps holding
        // if a store-generic service crate is later added to Cargo.toml.
        let available = list_available_tools();
        for t in list_tools() {
            if app_of(&t.name).is_some() {
                assert!(
                    !available.iter().any(|a| a.name == t.name),
                    "{} is imbib-/imprint-owned and should be withheld with both backends down",
                    t.name,
                );
            }
        }
    }
}

#[cfg(test)]
mod transport_tests {
    use super::*;

    #[test]
    fn an_unconfigured_process_stays_refused_without_probing() {
        let verdict = backends();
        assert_eq!(verdict.imbib, Backend::Unavailable);
        assert_eq!(verdict.imprint, Backend::Unavailable);
    }

    #[test]
    fn the_app_of_a_tool_is_exported() {
        assert_eq!(
            tool_app("imbib-library-service_list-libraries".into()).as_deref(),
            Some("imbib")
        );
        assert_eq!(tool_app("triage-service_add-tag".into()), None);
    }
}
