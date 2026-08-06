//! Domain model for evidence-based VW diagnosis.
//!
//! This crate deliberately has no Impress, SQLite, MCP, HTTP, UI, or LLM
//! dependency. Adapters persist its aggregates and expose its commands.

pub mod applicability;
pub mod inference;
pub mod model;
pub mod repository;
pub mod session;

pub use applicability::*;
pub use inference::*;
pub use model::*;
pub use repository::*;
pub use session::*;
