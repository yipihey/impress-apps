//! Which sibling apps answered at startup, and which tools that gates.
//!
//! Most `#[impress_service]` tools read the shared store and work with every
//! app closed. A minority cannot: source search needs imbib's keychain
//! credentials, manuscript edits need imprint's open editor, and implore's
//! datasets and impart's conversations exist only in those apps' memory.
//!
//! Those services have refusing default implementations, which is right as far
//! as it goes — but a method returning `Vec<T>` can only refuse by returning an
//! empty list, and an empty list is indistinguishable from "you have none".
//! That is not a hypothetical: it is the same shape as two real bugs found
//! while porting (imbib's nested `/api/logs` envelope and imprint's
//! non-existent per-document search route), both of which looked like success.
//!
//! So the honest fix is not to advertise them. A tool the model cannot
//! successfully call is worse than an absent one, because it spends a turn
//! discovering that and may believe the empty answer.
//!
//! Since plan-verb-pipeline P2 the *rule* — which namespaces need which app —
//! lives once, in `impress_service_core::pipeline::reachability`, and is the
//! pipeline's reachability layer on every path. This module keeps what is
//! this server's: the startup probe's record, installed as the layer's
//! configuration (store fallback on: an owned namespace that is not
//! app-gated runs against the shared store, as this server always did), and
//! the listing-time questions `tools/list` asks.

use std::sync::{Arc, OnceLock};

use impress_service_core::pipeline::reachability as layer;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum App {
    Imbib,
    Imprint,
    Implore,
    Impart,
}

impl App {
    fn parse(name: &str) -> Option<App> {
        match name {
            "imbib" => Some(App::Imbib),
            "imprint" => Some(App::Imprint),
            "implore" => Some(App::Implore),
            "impart" => Some(App::Impart),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Reachable {
    pub imbib: bool,
    pub imprint: bool,
    pub implore: bool,
    pub impart: bool,
}

impl Reachable {
    fn has(&self, app: App) -> bool {
        match app {
            App::Imbib => self.imbib,
            App::Imprint => self.imprint,
            App::Implore => self.implore,
            App::Impart => self.impart,
        }
    }
}

static REACHABLE: OnceLock<Reachable> = OnceLock::new();

/// Record what the startup probes found, and install it as the pipeline's
/// reachability configuration. Call once, before serving.
pub fn record(reachable: Reachable) {
    let _ = REACHABLE.set(reachable);
    install();
}

fn reachable() -> Reachable {
    REACHABLE.get().copied().unwrap_or_default()
}

/// The layer's configuration for this process: the recorded probe (nothing
/// recorded means every app down — refusing by default is the safe
/// direction), the shared store as the fallback for owned namespaces, and
/// `IMPRESS_MCP_LIST_ALL=1` disabling the gate for introspection.
fn install() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        layer::install(layer::Config {
            probe: Arc::new(|app: &str| App::parse(app).is_some_and(|app| reachable().has(app))),
            store_fallback: true,
            list_all: list_all(),
        });
    });
}

/// What the startup probes found, for reporting (`--help`).
pub fn current() -> Reachable {
    reachable()
}

/// The app a tool needs, if it needs one at all (the layer's table).
#[cfg(test)]
pub fn required_app(tool_name: &str) -> Option<App> {
    layer::gated_app(tool_name).and_then(App::parse)
}

/// Whether this tool should be advertised and dispatched right now.
///
/// `IMPRESS_MCP_LIST_ALL=1` disables the gate. Introspection — the migration
/// ledger, a capability audit — needs the full inventory, and it must not
/// depend on which apps happened to be open when it ran.
pub fn is_available(tool_name: &str) -> bool {
    install();
    layer::is_available(tool_name)
}

fn list_all() -> bool {
    std::env::var("IMPRESS_MCP_LIST_ALL").as_deref() == Ok("1")
}

/// Why a tool was withheld, for the `tools/call` error.
pub fn unavailable_reason(tool_name: &str) -> Option<String> {
    install();
    layer::unavailable_reason(tool_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_backed_tools_are_never_gated() {
        assert!(required_app("imbib-library-service_list-libraries").is_none());
        assert!(required_app("imbib-text-service_decode-latex").is_none());
        assert!(required_app("search_papers").is_none());
        // ADR-0022 WP G1: the collection and triage services open the shared
        // sqlite store directly, so they answer with every app closed. No new
        // mechanism was needed — an ungated namespace already means "always
        // available", and these simply are not in APP_GATED.
        assert!(required_app("collection-service_tree").is_none());
        assert!(required_app("collection-service_add-members").is_none());
        assert!(required_app("triage-service_set-status").is_none());
        assert!(is_available("collection-service_create"));
        assert!(is_available("triage-service_set-starred"));
    }

    #[test]
    fn app_gated_tools_name_their_app() {
        assert_eq!(
            required_app("imbib-app-service_search-sources"),
            Some(App::Imbib)
        );
        assert_eq!(
            required_app("imprint-app-service_get-pdf"),
            Some(App::Imprint)
        );
        assert_eq!(required_app("implore-service_status"), Some(App::Implore));
        assert_eq!(
            required_app("impart-service_add-message"),
            Some(App::Impart)
        );
    }

    /// With nothing recorded, gated tools are withheld — refusing by default is
    /// the safe direction.
    #[test]
    fn nothing_recorded_means_gated_tools_are_withheld() {
        if list_all() {
            return;
        }
        assert!(!is_available("implore-service_status"));
        assert!(is_available("imbib-library-service_list-libraries"));
        assert!(unavailable_reason("implore-service_status")
            .unwrap()
            .contains("implore is not running"));
    }
}
