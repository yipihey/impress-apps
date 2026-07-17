//! Pluggable backend for `ImprintManuscriptService` (and future imprint
//! service traits). Mirrors `imbib-service::backend`.
//!
//! Default backend opens the shared workspace SQLite directly (works in
//! standalone / test contexts). The `imprint-service-http` crate registers
//! an HTTP backend that routes calls to the running imprint macOS app
//! instead — that's what `impress-mcp` uses at runtime since the SQLite
//! path is sandbox-protected.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use crate::handlers::DefaultImprintHttpHandlers;
use crate::manuscript_service::{DefaultImprintManuscriptService, ImprintManuscriptService};
use crate::text_service::{DefaultImprintTextService, ImprintTextService};

/// Implemented by alternate backends (e.g. `imprint-service-http`'s
/// `HttpBackend`). Each method returns an `Arc<dyn TraitName>` for the
/// generated dispatch.
pub trait ImprintBackend: Send + Sync + 'static {
    fn manuscript(&self) -> Arc<dyn ImprintManuscriptService>;
    fn text(&self) -> Arc<dyn ImprintTextService>;
}

static BACKEND: OnceLock<Box<dyn ImprintBackend>> = OnceLock::new();
static DEFAULT_HANDLERS: OnceLock<Arc<DefaultImprintHttpHandlers>> = OnceLock::new();

/// Install a non-default backend (typically HTTP). First call wins.
pub fn register_backend(backend: Box<dyn ImprintBackend>) {
    let _ = BACKEND.set(backend);
}

pub fn has_custom_backend() -> bool {
    BACKEND.get().is_some()
}

/// Path used when the default backend auto-opens the workspace. Override
/// with the `IMPRINT_WORKSPACE_ROOT` env var.
fn default_workspace_root() -> PathBuf {
    if let Ok(p) = std::env::var("IMPRINT_WORKSPACE_ROOT") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join("Library/Group Containers/group.com.impress.suite/workspace/")
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

pub fn manuscript_service_instance() -> Arc<dyn ImprintManuscriptService> {
    match BACKEND.get() {
        Some(b) => b.manuscript(),
        None => Arc::new(DefaultImprintManuscriptService::new(default_handlers())),
    }
}

pub fn text_service_instance() -> Arc<dyn ImprintTextService> {
    match BACKEND.get() {
        Some(b) => b.text(),
        None => Arc::new(DefaultImprintTextService),
    }
}
