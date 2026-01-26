//! Event sourcing for impel
//!
//! All state changes are recorded as immutable events. Current state is
//! projected from the event log, allowing for time-travel and audit trails.

mod projection;
mod store;
mod types;

pub use projection::{AgentProjection, Projection, SystemProjection, ThreadProjection};
pub use store::{EventStore, InMemoryEventStore};
pub use types::{EntityType, Event, EventId, EventPayload};
