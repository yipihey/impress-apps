//! `SettingsService` — the registry's verbs (ADR-0036 D5, plan R1), now
//! koine's.
//!
//! The six `settings-service_*` verbs, the process-wide settings store, the
//! `Synced` scope's store row ([`StoreSyncedBackend`]) and the wire envelope
//! live in `koine-settings-service`, over `impress-settings` and the store
//! port (docs/plan-koine-kit-moves.md KM4). They register from koine's
//! inventory, once; this module re-exports them so every
//! `impress_store_service::settings_service` path still resolves.
//!
//! The default settings directory is the process workspace
//! (`koine_store::process::workspace`), which this crate's store module sets to
//! the directory beside `impress.sqlite` when it opens the store.

pub use koine_settings_service::*;
