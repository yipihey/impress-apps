//! `TaskStoreApi` — the impress-core/impel boundary (ADR-0005 §6, ADR-0015 D5).
//!
//! The port is koine's now (`koine_tasks::store`, koine
//! docs/plan-koine-ai-tasks.md Q-D1); its SQLite implementation lives with
//! the type, in `impress_core::task_store`. This path stays so every
//! `impel_core::task_store::` caller is unchanged.

pub use koine_tasks::store::*;
