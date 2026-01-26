//! Persistence layer for impel state
//!
//! Provides SQLite-backed storage for events, threads, agents, and messages.

mod repository;
mod schema;

pub use repository::Repository;
pub use schema::Schema;
