//! MCP presentation of the pipeline's app ownership rules.
//!
//! AppTransport owns the live probe cache and invocation routing. This module
//! reads that cache for tools/list and connection reporting; it keeps no
//! second snapshot or cooldown. Store-backed verbs remain available offline.

use impress_service_core::pipeline::reachability as layer;
use std::sync::atomic::{AtomicBool, Ordering};

static CONFIGURED: AtomicBool = AtomicBool::new(false);

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum App {
    Imbib,
    Imprint,
    Implore,
    Impart,
}

#[cfg(test)]
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

/// Warm the shared transport cache before the initial tools/list.
pub fn refresh() {
    CONFIGURED.store(true, Ordering::Release);
    for app in ["imbib", "imprint", "implore", "impart"] {
        impress_app_transport::probe_app_blocking(app);
    }
}

pub fn current() -> Reachable {
    let up = |app| impress_app_transport::cached_reachability(app).unwrap_or(false);
    Reachable {
        imbib: up("imbib"),
        imprint: up("imprint"),
        implore: up("implore"),
        impart: up("impart"),
    }
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
    if std::env::var("IMPRESS_MCP_LIST_ALL").as_deref() == Ok("1") {
        return true;
    }
    layer::gated_app(tool_name).is_none_or(|app| {
        CONFIGURED.load(Ordering::Acquire) && impress_app_transport::probe_app_blocking(app)
    })
}

#[cfg(test)]
fn list_all() -> bool {
    std::env::var("IMPRESS_MCP_LIST_ALL").as_deref() == Ok("1")
}

/// Why a tool was withheld, for the `tools/call` error.
pub fn unavailable_reason(tool_name: &str) -> Option<String> {
    (!is_available(tool_name))
        .then(|| layer::reason_text(layer::gated_app(tool_name).unwrap(), tool_name))
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
