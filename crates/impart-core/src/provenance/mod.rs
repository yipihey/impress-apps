//! Provenance event sourcing for research conversations.
//!
//! This module provides event sourcing infrastructure for tracking the complete
//! provenance of ideas, artifacts, and decisions in research conversations.
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────┐
//! │                    Provenance System                        │
//! ├─────────────────────────────────────────────────────────────┤
//! │  types      │ Event types and payloads                      │
//! │  store      │ SQLite-backed append-only event store         │
//! │  queries    │ Lineage tracing and artifact history          │
//! └─────────────────────────────────────────────────────────────┘
//! ```
//!
//! # Example
//!
//! ```rust,ignore
//! use impart_core::provenance::{ProvenanceEvent, ProvenancePayload, EventStore};
//!
//! let mut store = EventStore::in_memory()?;
//!
//! let event = ProvenanceEvent::new(
//!     "conversation-123".to_string(),
//!     ProvenancePayload::ConversationCreated {
//!         title: "Surface Code Discussion".to_string(),
//!         participants: vec!["user@example.com".to_string(), "counsel-opus4.5@impart.local".to_string()],
//!     },
//! );
//!
//! store.append(event)?;
//! ```

mod types;
mod store;
mod queries;

pub use types::*;
pub use store::*;
pub use queries::*;
