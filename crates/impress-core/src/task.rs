//! Task kernel: the canonical task state machine (ADR-0005 §2, ADR-0015 D1).
//!
//! It lives in koine now (`koine_tasks::state`, koine
//! docs/plan-koine-ai-tasks.md Q-D1), written against the item protocol this
//! crate re-exports; this path stays so every `impress_core::task::` caller
//! is unchanged. Its tests run there.

pub use koine_tasks::state::*;
