//! Event types for event sourcing

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::agent::AgentType;
use crate::escalation::EscalationCategory;
use crate::thread::{ThreadId, ThreadState};

/// Unique identifier for an event
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EventId(pub Uuid);

impl EventId {
    /// Create a new random event ID
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for EventId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for EventId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// An event in the impel system
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Event {
    /// Unique event ID
    pub id: EventId,
    /// Sequence number for ordering
    pub sequence: u64,
    /// Event timestamp
    pub timestamp: DateTime<Utc>,
    /// ID of the entity this event affects (thread, agent, etc.)
    pub entity_id: String,
    /// Type of entity
    pub entity_type: EntityType,
    /// Event payload
    pub payload: EventPayload,
    /// ID of the actor that triggered this event
    pub actor_id: Option<String>,
    /// Correlation ID for grouping related events
    pub correlation_id: Option<String>,
    /// Causation ID (ID of the event that caused this one)
    pub causation_id: Option<EventId>,
}

impl Event {
    /// Create a new event
    pub fn new(entity_id: String, entity_type: EntityType, payload: EventPayload) -> Self {
        Self {
            id: EventId::new(),
            sequence: 0, // Set by EventStore
            timestamp: Utc::now(),
            entity_id,
            entity_type,
            payload,
            actor_id: None,
            correlation_id: None,
            causation_id: None,
        }
    }

    /// Set the actor ID
    pub fn with_actor(mut self, actor_id: String) -> Self {
        self.actor_id = Some(actor_id);
        self
    }

    /// Set the correlation ID
    pub fn with_correlation(mut self, correlation_id: String) -> Self {
        self.correlation_id = Some(correlation_id);
        self
    }

    /// Set the causation ID
    pub fn with_causation(mut self, causation_id: EventId) -> Self {
        self.causation_id = Some(causation_id);
        self
    }
}

/// Type of entity an event affects
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EntityType {
    Thread,
    Agent,
    Message,
    Escalation,
    Artifact,
    System,
}

impl std::fmt::Display for EntityType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EntityType::Thread => write!(f, "thread"),
            EntityType::Agent => write!(f, "agent"),
            EntityType::Message => write!(f, "message"),
            EntityType::Escalation => write!(f, "escalation"),
            EntityType::Artifact => write!(f, "artifact"),
            EntityType::System => write!(f, "system"),
        }
    }
}

/// Event payload containing the actual event data
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EventPayload {
    // Thread events
    ThreadCreated {
        title: String,
        description: String,
        parent_id: Option<String>,
    },
    ThreadStateChanged {
        from: ThreadState,
        to: ThreadState,
        reason: Option<String>,
    },
    ThreadClaimed {
        agent_id: String,
    },
    ThreadReleased {
        agent_id: String,
    },
    ThreadTemperatureChanged {
        old_value: f64,
        new_value: f64,
        reason: String,
    },
    ThreadMerged {
        source_id: String,
        target_id: String,
    },
    ThreadArtifactAdded {
        artifact_id: String,
        artifact_type: String,
    },

    // Agent events
    AgentRegistered {
        agent_type: AgentType,
        capabilities: Vec<String>,
    },
    AgentStatusChanged {
        from: String,
        to: String,
    },
    AgentTerminated {
        reason: Option<String>,
    },

    // Message events
    MessageSent {
        from: String,
        to: Vec<String>,
        subject: String,
        thread_id: Option<String>,
    },
    MessageRead {
        reader_id: String,
    },

    // Escalation events
    EscalationCreated {
        category: EscalationCategory,
        title: String,
        thread_id: Option<String>,
    },
    EscalationAcknowledged {
        acknowledger_id: String,
    },
    EscalationResolved {
        resolver_id: String,
        resolution: String,
    },

    // Artifact events
    ArtifactCreated {
        artifact_type: String,
        path: String,
    },
    ArtifactModified {
        path: String,
        change_summary: String,
    },

    // System events
    SystemPaused {
        reason: Option<String>,
    },
    SystemResumed,
    SnapshotCreated {
        snapshot_id: String,
    },
}

impl EventPayload {
    /// Get a human-readable description of the event
    pub fn description(&self) -> String {
        match self {
            EventPayload::ThreadCreated { title, .. } => format!("Thread created: {}", title),
            EventPayload::ThreadStateChanged { from, to, .. } => {
                format!("State changed: {} → {}", from, to)
            }
            EventPayload::ThreadClaimed { agent_id } => {
                format!("Thread claimed by {}", agent_id)
            }
            EventPayload::ThreadReleased { agent_id } => {
                format!("Thread released by {}", agent_id)
            }
            EventPayload::ThreadTemperatureChanged {
                old_value,
                new_value,
                ..
            } => format!("Temperature: {:.2} → {:.2}", old_value, new_value),
            EventPayload::ThreadMerged {
                source_id,
                target_id,
            } => format!("Thread {} merged into {}", source_id, target_id),
            EventPayload::ThreadArtifactAdded { artifact_id, .. } => {
                format!("Artifact added: {}", artifact_id)
            }
            EventPayload::AgentRegistered { agent_type, .. } => {
                format!("Agent registered: {:?}", agent_type)
            }
            EventPayload::AgentStatusChanged { from, to } => {
                format!("Agent status: {} → {}", from, to)
            }
            EventPayload::AgentTerminated { reason } => format!(
                "Agent terminated{}",
                reason.as_ref().map(|r| format!(": {}", r)).unwrap_or_default()
            ),
            EventPayload::MessageSent { from, subject, .. } => {
                format!("Message from {}: {}", from, subject)
            }
            EventPayload::MessageRead { reader_id } => {
                format!("Message read by {}", reader_id)
            }
            EventPayload::EscalationCreated { category, title, .. } => {
                format!("Escalation ({:?}): {}", category, title)
            }
            EventPayload::EscalationAcknowledged { acknowledger_id } => {
                format!("Escalation acknowledged by {}", acknowledger_id)
            }
            EventPayload::EscalationResolved { resolver_id, .. } => {
                format!("Escalation resolved by {}", resolver_id)
            }
            EventPayload::ArtifactCreated { path, .. } => {
                format!("Artifact created: {}", path)
            }
            EventPayload::ArtifactModified { path, .. } => {
                format!("Artifact modified: {}", path)
            }
            EventPayload::SystemPaused { .. } => "System paused".to_string(),
            EventPayload::SystemResumed => "System resumed".to_string(),
            EventPayload::SnapshotCreated { snapshot_id } => {
                format!("Snapshot created: {}", snapshot_id)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_event_creation() {
        let event = Event::new(
            "thread-123".to_string(),
            EntityType::Thread,
            EventPayload::ThreadCreated {
                title: "Test Thread".to_string(),
                description: "A test thread".to_string(),
                parent_id: None,
            },
        );

        assert_eq!(event.entity_id, "thread-123");
        assert_eq!(event.entity_type, EntityType::Thread);
    }

    #[test]
    fn test_event_with_actor() {
        let event = Event::new(
            "thread-123".to_string(),
            EntityType::Thread,
            EventPayload::ThreadClaimed {
                agent_id: "agent-1".to_string(),
            },
        )
        .with_actor("agent-1".to_string());

        assert_eq!(event.actor_id, Some("agent-1".to_string()));
    }

    #[test]
    fn test_payload_description() {
        let payload = EventPayload::ThreadStateChanged {
            from: ThreadState::Embryo,
            to: ThreadState::Active,
            reason: None,
        };

        assert!(payload.description().contains("EMBRYO"));
        assert!(payload.description().contains("ACTIVE"));
    }
}
