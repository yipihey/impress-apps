//! Impel Core - Agent orchestration for autonomous research teams
//!
//! This crate provides the core functionality for the impel agent orchestration system:
//!
//! - **Thread**: Research thread management with state machine (Embryo→Active→Blocked→Review→Complete)
//! - **Agent**: Agent types (Research, Code, Verification, Adversarial, Review, Librarian)
//! - **Event**: Event sourcing with immutable event log and state projection
//! - **Escalation**: Human escalation categories (Decision, Novelty, Stuck, Scope, Quality, Checkpoint)
//! - **Message**: RFC 5322 email-style message envelopes with threading
//! - **Persistence**: SQLite-based storage for events, threads, agents, and messages
//! - **Coordination**: Stigmergic coordination via shared state and temperature-based attention
//! - **Integrations**: Adapters for imbib (references), imprint (documents), implore (data/viz)
//! - **Project**: Collection of related threads working toward shared deliverables
//! - **Program**: Collection of related projects (highest level of organization)
//! - **Config**: System-wide configuration for temperature, agents, and timing
//!
//! # Architecture
//!
//! Impel uses an artifact-centric design with stigmergic coordination:
//! - All state changes are recorded as immutable events
//! - Current state is projected from the event log
//! - Temperature-based attention gradients prioritize work
//! - Human intervention points are minimized but impactful
//!
//! # Four-Level Hierarchy
//!
//! ```text
//! Program → Project → Thread → Event
//!   L1        L2        L3       L4
//! ```

pub mod agent;
pub mod config;
pub mod coordination;
pub mod error;
pub mod escalation;
pub mod event;
pub mod integrations;
pub mod message;
pub mod persistence;
pub mod program;
pub mod project;
pub mod thread;

pub use agent::{Agent, AgentRegistry, AgentStatus, AgentType};
pub use config::{AgentConfig, EscalationConfig, ImpelConfig, TemperatureConfig, TimingConfig};
pub use coordination::{Command, CoordinationState};
pub use error::{ImpelError, Result};
pub use escalation::{Escalation, EscalationCategory, EscalationPriority, EscalationStatus};
pub use event::{Event, EventId, EventStore, Projection};
pub use message::{Attachment, MessageBody, MessageEnvelope, MessageId};
pub use persistence::{Repository, Schema};
pub use program::{Program, ProgramId, ProgramRegistry, ProgramStatus};
pub use project::{
    Deliverable, DeliverableKind, Project, ProjectId, ProjectRelation, ProjectStatus,
};
pub use thread::{Temperature, TemperatureCoefficients, Thread, ThreadId, ThreadState};

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

/// Returns the version of impel-core
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Hello world function to verify FFI setup
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn hello_from_impel() -> String {
    "Hello from impel-core (Rust)!".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_thread_state_transitions() {
        let mut state = ThreadState::Embryo;

        // Embryo can transition to Active
        assert!(state.can_transition_to(&ThreadState::Active));
        state = ThreadState::Active;

        // Active can transition to Blocked or Review
        assert!(state.can_transition_to(&ThreadState::Blocked));
        assert!(state.can_transition_to(&ThreadState::Review));

        // Active to Blocked
        state = ThreadState::Blocked;
        assert!(state.can_transition_to(&ThreadState::Active));
        assert!(state.can_transition_to(&ThreadState::Killed));

        // Active to Review
        state = ThreadState::Active;
        state = ThreadState::Review;
        assert!(state.can_transition_to(&ThreadState::Complete));
        assert!(state.can_transition_to(&ThreadState::Killed));
    }

    #[test]
    fn test_temperature_decay() {
        let mut temp = Temperature::new(1.0);
        let hours_24 = chrono::Duration::hours(24);

        // After 24 hours (one half-life), temperature should be ~0.5
        temp.decay(hours_24);
        assert!((temp.value() - 0.5).abs() < 0.01);
    }
}
