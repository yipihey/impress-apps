pub mod event;
pub mod item;
pub mod operation;
pub mod query;
pub mod reference;
pub mod registry;
pub mod schema;
pub mod schemas;
pub mod store;
pub mod task;

#[cfg(feature = "sqlite")]
pub mod backup;
#[cfg(feature = "sqlite")]
pub mod collection_migration;
#[cfg(feature = "sqlite")]
pub mod collection_ops;
/// The manuscript-format grammar table. Pure data + text heuristics, so it is
/// available without the `sqlite` feature (wasm/UI-only builds read it too).
pub mod manuscript_format;
#[cfg(feature = "sqlite")]
pub mod manuscript_ops;
#[cfg(feature = "sqlite")]
pub mod related_ops;
#[cfg(feature = "sqlite")]
pub mod search_ops;
#[cfg(feature = "sqlite")]
pub mod sql_query;
#[cfg(feature = "sqlite")]
pub mod sqlite_store;
#[cfg(feature = "sqlite")]
pub mod sync;
/// Task / agent-run schema-ref convergence (WP C4) — the flagged, reversible
/// data migration off the losing spellings. Gated by a `store_metadata` marker,
/// like `collection_migration`'s.
#[cfg(feature = "sqlite")]
pub mod task_schema_migration;
#[cfg(feature = "sqlite")]
pub mod triage_ops;

pub use event::*;
pub use item::*;
pub use operation::*;
pub use query::*;
pub use reference::*;
pub use registry::*;
pub use schema::*;
pub use store::*;

#[cfg(feature = "sqlite")]
pub use sqlite_store::SqliteItemStore;
