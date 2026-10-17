//! Runtime provider discovery and the person's explicit trust decision
//! (P8), now koine's (`koine_providers::service`, docs/plan-koine-kit-moves.md
//! KM12). This module re-exports it so every
//! `impress_store_service::provider_service` path still resolves.

pub use koine_providers::service::*;
