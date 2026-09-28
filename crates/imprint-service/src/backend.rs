//! Pluggable backend for `ImprintManuscriptService` (and future imprint
//! service traits). Mirrors `imbib-service::backend`.
//!
//! Default backend opens the shared workspace SQLite directly (works in
//! standalone / test contexts). In the running app, `imprint-verbs-ffi`
//! registers native callbacks for editor-owned capabilities. Headless callers
//! reach those verbs through `impress-app-transport` and the pipeline.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use impress_service_core::BackendSlot;

use crate::handlers::DefaultImprintHttpHandlers;
use crate::manuscript_service::{DefaultImprintManuscriptService, ImprintManuscriptService};
use crate::project_service::{DefaultImprintProjectService, ImprintProjectService};
use crate::text_service::{DefaultImprintTextService, ImprintTextService};
use crate::throughline::ThroughlineStore;
use crate::throughline_service::{DefaultImprintThroughlineService, ImprintThroughlineService};

/// Implemented by alternate backends, including the app-owned native backend.
/// Each method returns an `Arc<dyn TraitName>` for the
/// generated dispatch.
pub trait ImprintBackend: Send + Sync + 'static {
    fn manuscript(&self) -> Arc<dyn ImprintManuscriptService>;
    /// Project operations use the configured workspace when a native host is
    /// installed; standalone callers retain the shared-store default.
    fn project(&self) -> Arc<dyn ImprintProjectService> {
        Arc::new(DefaultImprintProjectService::new())
    }
    /// App-level capabilities (comments, content edits, PDF, logs).
    /// Defaulted to the refusing implementation; the native app backend
    /// overrides it.
    fn app(&self) -> Arc<dyn crate::app_service::ImprintAppService> {
        Arc::new(crate::app_service::DefaultImprintAppService::new())
    }
    fn text(&self) -> Arc<dyn ImprintTextService>;
    /// Throughline service (ADR-0016). Default body falls back to the
    /// store-backed implementation; the native backend can override it
    /// when the editor owns throughline state.
    fn throughline(&self) -> Arc<dyn ImprintThroughlineService> {
        default_throughline_service()
    }
}

static BACKEND: BackendSlot<dyn ImprintBackend> = BackendSlot::new();
static DEFAULT_HANDLERS: OnceLock<Arc<DefaultImprintHttpHandlers>> = OnceLock::new();

/// Install (or replace) a non-default backend, as `imprint-verbs-ffi` does
/// when its native callbacks are ready.
pub fn register_backend(backend: Box<dyn ImprintBackend>) {
    BACKEND.install(Arc::from(backend));
}

/// Uninstall the current backend: dispatch returns to the defaults.
pub fn clear_backend() {
    BACKEND.clear();
}

pub fn has_custom_backend() -> bool {
    BACKEND.is_installed()
}

/// Path used when the default backend auto-opens the workspace. Override
/// with the `IMPRINT_WORKSPACE_ROOT` env var.
fn default_workspace_root() -> PathBuf {
    if let Ok(p) = std::env::var("IMPRINT_WORKSPACE_ROOT") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/")
}

/// Lazy-init the default handlers (SectionStore + ManuscriptSearchIndex)
/// from the shared workspace. Falls back to a tmp directory on failure so
/// service calls don't panic.
fn default_handlers() -> Arc<DefaultImprintHttpHandlers> {
    DEFAULT_HANDLERS
        .get_or_init(|| {
            let root = default_workspace_root();
            let svc = crate::open(&root).unwrap_or_else(|e| {
                eprintln!(
                    "[imprint-service] failed to open workspace at {}: {e}; falling back to /tmp",
                    root.display()
                );
                let tmp = std::env::temp_dir().join("impress-imprint-fallback");
                let _ = std::fs::create_dir_all(&tmp);
                crate::open(&tmp).expect("/tmp workspace always opens")
            });
            Arc::new(svc.handlers)
        })
        .clone()
}

// ---------------------------------------------------------------------------
// Per-service singleton getters
// ---------------------------------------------------------------------------

/// Store-backed throughline service over the default workspace handlers.
fn default_throughline_service() -> Arc<dyn ImprintThroughlineService> {
    let sections = Arc::new(default_handlers().sections().clone());
    Arc::new(DefaultImprintThroughlineService::new(Arc::new(
        ThroughlineStore::new(sections),
    )))
}

pub fn throughline_service_instance() -> Arc<dyn ImprintThroughlineService> {
    match BACKEND.get() {
        Some(b) => b.throughline(),
        None => default_throughline_service(),
    }
}

pub fn app_service_instance() -> Arc<dyn crate::app_service::ImprintAppService> {
    match BACKEND.get() {
        Some(b) => b.app(),
        None => Arc::new(crate::app_service::DefaultImprintAppService::new()),
    }
}

pub fn manuscript_service_instance() -> Arc<dyn ImprintManuscriptService> {
    match BACKEND.get() {
        Some(b) => b.manuscript(),
        None => Arc::new(DefaultImprintManuscriptService::new(default_handlers())),
    }
}

pub fn project_service_instance() -> Arc<dyn ImprintProjectService> {
    match BACKEND.get() {
        Some(b) => b.project(),
        None => Arc::new(DefaultImprintProjectService::new()),
    }
}

pub fn text_service_instance() -> Arc<dyn ImprintTextService> {
    match BACKEND.get() {
        Some(b) => b.text(),
        None => Arc::new(DefaultImprintTextService),
    }
}
