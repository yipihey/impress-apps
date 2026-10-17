//! The memory kernel — write, gate, rank and recall suite-scoped memory —
//! now koine's (`koine_memory::ops`, docs/plan-koine-kit-moves.md KM5).
//!
//! It runs over the store port: full-text retrieval is the port's
//! `search_text`, which `SqliteItemStore` answers from `items_fts` (bm25), so
//! the dedup gate and recall keep their FTS index here. This module
//! re-exports the kernel so every `impress_core::memory_ops` path still
//! resolves; `tests/prop_memory_ops.rs` keeps proving it over SQLite.

pub use koine_memory::ops::*;
