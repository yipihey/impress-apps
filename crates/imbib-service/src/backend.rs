//! Pluggable backend for the seven imbib service traits.
//!
//! The default backend is the existing SQLite-via-`ImbibStore` path (used
//! when running standalone or in tests). A separate `imbib-service-http`
//! crate provides an alternate backend that routes calls over HTTP to a
//! running imbib macOS app — install it at process startup via
//! [`register_backend`].
//!
//! All seven `#[impress_service]` `instance = ||` closures call into this
//! module to obtain an `Arc<dyn TraitName>`. The backend is resolved on
//! the first method call after `register_backend` (or lazily falls back
//! to SQLite if nothing was registered).

use std::sync::{Arc, OnceLock};

use crate::annotations_service::{DefaultImbibAnnotationsService, ImbibAnnotationsService};
use crate::app_service::{DefaultImbibAppService, ImbibAppService};
use crate::artifacts_service::{DefaultImbibArtifactsService, ImbibArtifactsService};
use crate::backup_service::{DefaultImbibBackupService, ImbibBackupService};
use crate::library_service::{DefaultImbibLibraryService, ImbibLibraryService};
use crate::scix_service::{DefaultImbibScixService, ImbibScixService};
use crate::search_service::{DefaultImbibSearchService, ImbibSearchService};
use crate::store_singleton::store_instance;
use crate::tags_service::{DefaultImbibTagsService, ImbibTagsService};
use crate::undo_service::{DefaultImbibUndoService, ImbibUndoService};

/// Implemented by alternate backends (e.g. `imbib-service-http`'s
/// `HttpBackend`). Each method returns an `Arc<dyn TraitName>` that the
/// macro's generated handler will dispatch through.
pub trait ImbibBackend: Send + Sync + 'static {
    fn library(&self) -> Arc<dyn ImbibLibraryService>;
    fn tags(&self) -> Arc<dyn ImbibTagsService>;
    fn search(&self) -> Arc<dyn ImbibSearchService>;
    fn undo(&self) -> Arc<dyn ImbibUndoService>;
    fn annotations(&self) -> Arc<dyn ImbibAnnotationsService>;
    fn artifacts(&self) -> Arc<dyn ImbibArtifactsService>;
    fn scix(&self) -> Arc<dyn ImbibScixService>;

    /// App-level capabilities (source search, sync, logs, activity).
    /// Defaulted to the refusing implementation: with imbib closed none of
    /// this exists, and saying so beats an empty list that reads like
    /// "you have no papers".
    fn app(&self) -> Arc<dyn ImbibAppService> {
        Arc::new(DefaultImbibAppService::new())
    }

    /// Backups. Defaulted so a backend can opt out: the store-backed
    /// implementation is correct for create/list/inspect/delete, and refuses
    /// restore (which needs the running app — see `backup_service`).
    fn backup(&self) -> Arc<dyn ImbibBackupService> {
        Arc::new(DefaultImbibBackupService::new(store_instance()))
    }
}

static BACKEND: OnceLock<Box<dyn ImbibBackend>> = OnceLock::new();

/// Install a non-default backend (typically HTTP). First call wins —
/// later calls are silently ignored. Call this at process startup,
/// BEFORE the first MCP/CLI/Python dispatch.
pub fn register_backend(backend: Box<dyn ImbibBackend>) {
    let _ = BACKEND.set(backend);
}

/// True iff a non-default backend has been installed.
pub fn has_custom_backend() -> bool {
    BACKEND.get().is_some()
}

// ---------------------------------------------------------------------------
// Per-service singleton getters
// ---------------------------------------------------------------------------
//
// Each of the seven `*_service.rs` files calls into these from its
// `impress_service_impl!` `instance = ||` closure. When a custom backend
// is installed the call routes through it; otherwise we fall back to the
// SQLite-backed defaults that hold a shared `Arc<ImbibStore>`.

pub fn library_service_instance() -> Arc<dyn ImbibLibraryService> {
    match BACKEND.get() {
        Some(b) => b.library(),
        None => Arc::new(DefaultImbibLibraryService::new(store_instance())),
    }
}

pub fn tags_service_instance() -> Arc<dyn ImbibTagsService> {
    match BACKEND.get() {
        Some(b) => b.tags(),
        None => Arc::new(DefaultImbibTagsService::new(store_instance())),
    }
}

pub fn search_service_instance() -> Arc<dyn ImbibSearchService> {
    match BACKEND.get() {
        Some(b) => b.search(),
        None => Arc::new(DefaultImbibSearchService::new(store_instance())),
    }
}

pub fn app_service_instance() -> Arc<dyn ImbibAppService> {
    match BACKEND.get() {
        Some(b) => b.app(),
        None => Arc::new(DefaultImbibAppService::new()),
    }
}

pub fn backup_service_instance() -> Arc<dyn ImbibBackupService> {
    match BACKEND.get() {
        Some(b) => b.backup(),
        None => Arc::new(DefaultImbibBackupService::new(store_instance())),
    }
}

pub fn undo_service_instance() -> Arc<dyn ImbibUndoService> {
    match BACKEND.get() {
        Some(b) => b.undo(),
        None => Arc::new(DefaultImbibUndoService::new(store_instance())),
    }
}

pub fn annotations_service_instance() -> Arc<dyn ImbibAnnotationsService> {
    match BACKEND.get() {
        Some(b) => b.annotations(),
        None => Arc::new(DefaultImbibAnnotationsService::new(store_instance())),
    }
}

pub fn artifacts_service_instance() -> Arc<dyn ImbibArtifactsService> {
    match BACKEND.get() {
        Some(b) => b.artifacts(),
        None => Arc::new(DefaultImbibArtifactsService::new(store_instance())),
    }
}

pub fn scix_service_instance() -> Arc<dyn ImbibScixService> {
    match BACKEND.get() {
        Some(b) => b.scix(),
        None => Arc::new(DefaultImbibScixService::new(store_instance())),
    }
}
