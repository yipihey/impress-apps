//! Provenance event types for research conversations.
//!
//! These types track the complete lineage of ideas, artifacts, and decisions
//! in research conversations for long-term reproducibility.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// MARK: - Event ID

/// Unique identifier for a provenance event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProvenanceEventId {
    /// The underlying UUID value.
    pub value: Uuid,
}

impl ProvenanceEventId {
    /// Create a new random event ID.
    pub fn new() -> Self {
        Self {
            value: Uuid::new_v4(),
        }
    }

    /// Create from a UUID.
    pub fn from_uuid(uuid: Uuid) -> Self {
        Self { value: uuid }
    }

    /// Parse from a string.
    pub fn parse(s: &str) -> Option<Self> {
        Uuid::parse_str(s).ok().map(Self::from_uuid)
    }
}

impl Default for ProvenanceEventId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for ProvenanceEventId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.value)
    }
}

// MARK: - Provenance Event

/// A provenance event in the impart research conversation system.
///
/// Events are immutable and append-only, forming a complete audit trail
/// of all activities in research conversations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvenanceEvent {
    /// Unique event ID.
    pub id: ProvenanceEventId,

    /// Sequence number for ordering (assigned by store).
    pub sequence: u64,

    /// Event timestamp.
    pub timestamp: DateTime<Utc>,

    /// ID of the conversation this event relates to.
    pub conversation_id: String,

    /// Event payload containing the actual data.
    pub payload: ProvenancePayload,

    /// ID of the actor (human or agent) that triggered this event.
    pub actor_id: String,

    /// Correlation ID for grouping related events across conversations.
    pub correlation_id: Option<String>,

    /// Causation ID (ID of the event that caused this one).
    pub causation_id: Option<ProvenanceEventId>,
}

impl ProvenanceEvent {
    /// Create a new provenance event.
    pub fn new(conversation_id: String, payload: ProvenancePayload, actor_id: String) -> Self {
        Self {
            id: ProvenanceEventId::new(),
            sequence: 0, // Set by EventStore
            timestamp: Utc::now(),
            conversation_id,
            payload,
            actor_id,
            correlation_id: None,
            causation_id: None,
        }
    }

    /// Set the correlation ID.
    pub fn with_correlation(mut self, correlation_id: String) -> Self {
        self.correlation_id = Some(correlation_id);
        self
    }

    /// Set the causation ID.
    pub fn with_causation(mut self, causation_id: ProvenanceEventId) -> Self {
        self.causation_id = Some(causation_id);
        self
    }

    /// Get a human-readable description of this event.
    pub fn description(&self) -> String {
        self.payload.description()
    }
}

// MARK: - Entity Type

/// Type of entity a provenance event affects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ProvenanceEntityType {
    /// Research conversation.
    Conversation,
    /// Research message.
    Message,
    /// Artifact reference.
    Artifact,
    /// Insight or conclusion.
    Insight,
    /// Decision made during research.
    Decision,
    /// System event.
    System,
}

impl std::fmt::Display for ProvenanceEntityType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProvenanceEntityType::Conversation => write!(f, "conversation"),
            ProvenanceEntityType::Message => write!(f, "message"),
            ProvenanceEntityType::Artifact => write!(f, "artifact"),
            ProvenanceEntityType::Insight => write!(f, "insight"),
            ProvenanceEntityType::Decision => write!(f, "decision"),
            ProvenanceEntityType::System => write!(f, "system"),
        }
    }
}

// MARK: - Provenance Payload

/// Event payload containing the actual provenance data.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ProvenancePayload {
    // Conversation lifecycle events
    /// A new research conversation was created.
    ConversationCreated {
        title: String,
        participants: Vec<String>,
    },

    /// A conversation was branched into a side conversation.
    ConversationBranched {
        from_message_id: String,
        reason: String,
        branch_title: String,
    },

    /// A conversation was archived.
    ConversationArchived { reason: Option<String> },

    /// A conversation was unarchived.
    ConversationUnarchived,

    /// Conversation title was updated.
    ConversationTitleUpdated {
        old_title: String,
        new_title: String,
    },

    /// Conversation summary was generated/updated.
    ConversationSummarized { summary: String },

    // Message events
    /// A message was sent in a conversation.
    MessageSent {
        message_id: String,
        role: String,         // "human", "counsel", "system"
        model_used: Option<String>,
        content_hash: String, // SHA256 of content for verification
    },

    /// A message was edited.
    MessageEdited {
        message_id: String,
        old_content_hash: String,
        new_content_hash: String,
        reason: Option<String>,
    },

    /// A side conversation was synthesized into a summary message.
    SideConversationSynthesized {
        side_conversation_id: String,
        synthesis_message_id: String,
        summary: String,
    },

    // Artifact events
    /// An artifact was first introduced to the conversation.
    ArtifactIntroduced {
        artifact_uri: String,
        artifact_type: String,
        version: Option<String>,
        display_name: String,
    },

    /// An artifact was referenced (after initial introduction).
    ArtifactReferenced {
        artifact_uri: String,
        message_id: String,
        context_snippet: String,
    },

    /// An artifact's metadata was updated.
    ArtifactMetadataUpdated {
        artifact_uri: String,
        field: String,
        old_value: Option<String>,
        new_value: Option<String>,
    },

    /// An artifact was resolved (content fetched/verified).
    ArtifactResolved {
        artifact_uri: String,
        resolution_details: String,
    },

    /// Two artifacts were linked as related.
    ArtifactLinked {
        source_uri: String,
        target_uri: String,
        relationship: String, // "cites", "extends", "contradicts", etc.
    },

    // Insight and decision events
    /// An insight was recorded during the conversation.
    InsightRecorded {
        insight_id: String,
        summary: String,
        derived_from: Vec<String>, // Message IDs or artifact URIs
        confidence: Option<f64>,
    },

    /// A decision was made during the conversation.
    DecisionMade {
        decision_id: String,
        description: String,
        rationale: String,
        alternatives_considered: Vec<String>,
    },

    /// A decision was revised.
    DecisionRevised {
        decision_id: String,
        old_description: String,
        new_description: String,
        revision_reason: String,
    },

    // System events
    /// System was paused.
    SystemPaused { reason: Option<String> },

    /// System was resumed.
    SystemResumed,

    /// A snapshot of the conversation state was created.
    SnapshotCreated {
        snapshot_id: String,
        format: String, // "impartarchive", "jsonl", etc.
    },

    /// Conversation was exported.
    ConversationExported {
        export_id: String,
        format: String,
        destination: String,
    },

    /// Conversation was imported.
    ConversationImported {
        import_id: String,
        source: String,
        original_conversation_id: Option<String>,
    },
}

impl ProvenancePayload {
    /// Get a human-readable description of the payload.
    pub fn description(&self) -> String {
        match self {
            ProvenancePayload::ConversationCreated { title, .. } => {
                format!("Conversation created: {}", title)
            }
            ProvenancePayload::ConversationBranched {
                branch_title,
                reason,
                ..
            } => {
                format!("Branched: {} ({})", branch_title, reason)
            }
            ProvenancePayload::ConversationArchived { .. } => "Conversation archived".to_string(),
            ProvenancePayload::ConversationUnarchived => "Conversation unarchived".to_string(),
            ProvenancePayload::ConversationTitleUpdated { new_title, .. } => {
                format!("Title updated: {}", new_title)
            }
            ProvenancePayload::ConversationSummarized { .. } => "Summary generated".to_string(),

            ProvenancePayload::MessageSent { role, model_used, .. } => {
                if let Some(model) = model_used {
                    format!("Message from {} ({})", role, model)
                } else {
                    format!("Message from {}", role)
                }
            }
            ProvenancePayload::MessageEdited { message_id, .. } => {
                format!("Message {} edited", message_id)
            }
            ProvenancePayload::SideConversationSynthesized { summary, .. } => {
                format!("Side conversation synthesized: {}", summary)
            }

            ProvenancePayload::ArtifactIntroduced {
                display_name,
                artifact_type,
                ..
            } => {
                format!("{} introduced: {}", artifact_type, display_name)
            }
            ProvenancePayload::ArtifactReferenced { artifact_uri, .. } => {
                format!("Artifact referenced: {}", artifact_uri)
            }
            ProvenancePayload::ArtifactMetadataUpdated { artifact_uri, field, .. } => {
                format!("Artifact {} updated: {}", artifact_uri, field)
            }
            ProvenancePayload::ArtifactResolved { artifact_uri, .. } => {
                format!("Artifact resolved: {}", artifact_uri)
            }
            ProvenancePayload::ArtifactLinked {
                source_uri,
                target_uri,
                relationship,
            } => {
                format!("{} {} {}", source_uri, relationship, target_uri)
            }

            ProvenancePayload::InsightRecorded { summary, .. } => {
                format!("Insight: {}", summary)
            }
            ProvenancePayload::DecisionMade { description, .. } => {
                format!("Decision: {}", description)
            }
            ProvenancePayload::DecisionRevised {
                new_description, ..
            } => {
                format!("Decision revised: {}", new_description)
            }

            ProvenancePayload::SystemPaused { reason } => {
                if let Some(r) = reason {
                    format!("System paused: {}", r)
                } else {
                    "System paused".to_string()
                }
            }
            ProvenancePayload::SystemResumed => "System resumed".to_string(),
            ProvenancePayload::SnapshotCreated { snapshot_id, .. } => {
                format!("Snapshot created: {}", snapshot_id)
            }
            ProvenancePayload::ConversationExported { format, .. } => {
                format!("Exported as {}", format)
            }
            ProvenancePayload::ConversationImported { source, .. } => {
                format!("Imported from {}", source)
            }
        }
    }

    /// Get the entity type affected by this payload.
    pub fn entity_type(&self) -> ProvenanceEntityType {
        match self {
            ProvenancePayload::ConversationCreated { .. }
            | ProvenancePayload::ConversationBranched { .. }
            | ProvenancePayload::ConversationArchived { .. }
            | ProvenancePayload::ConversationUnarchived
            | ProvenancePayload::ConversationTitleUpdated { .. }
            | ProvenancePayload::ConversationSummarized { .. }
            | ProvenancePayload::ConversationExported { .. }
            | ProvenancePayload::ConversationImported { .. } => ProvenanceEntityType::Conversation,

            ProvenancePayload::MessageSent { .. }
            | ProvenancePayload::MessageEdited { .. }
            | ProvenancePayload::SideConversationSynthesized { .. } => ProvenanceEntityType::Message,

            ProvenancePayload::ArtifactIntroduced { .. }
            | ProvenancePayload::ArtifactReferenced { .. }
            | ProvenancePayload::ArtifactMetadataUpdated { .. }
            | ProvenancePayload::ArtifactResolved { .. }
            | ProvenancePayload::ArtifactLinked { .. } => ProvenanceEntityType::Artifact,

            ProvenancePayload::InsightRecorded { .. } => ProvenanceEntityType::Insight,

            ProvenancePayload::DecisionMade { .. }
            | ProvenancePayload::DecisionRevised { .. } => ProvenanceEntityType::Decision,

            ProvenancePayload::SystemPaused { .. }
            | ProvenancePayload::SystemResumed
            | ProvenancePayload::SnapshotCreated { .. } => ProvenanceEntityType::System,
        }
    }
}

// MARK: - Artifact Type

/// Types of artifacts that can be referenced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtifactType {
    /// Paper from imbib library.
    Paper,
    /// Document from imprint.
    Document,
    /// Git repository.
    Repository,
    /// Dataset.
    Dataset,
    /// Robot/hardware configuration.
    Robot,
    /// Real-time data stream.
    Stream,
    /// External URL.
    ExternalUrl,
    /// Unknown type.
    Unknown,
}

impl std::fmt::Display for ArtifactType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ArtifactType::Paper => write!(f, "paper"),
            ArtifactType::Document => write!(f, "document"),
            ArtifactType::Repository => write!(f, "repository"),
            ArtifactType::Dataset => write!(f, "dataset"),
            ArtifactType::Robot => write!(f, "robot"),
            ArtifactType::Stream => write!(f, "stream"),
            ArtifactType::ExternalUrl => write!(f, "external_url"),
            ArtifactType::Unknown => write!(f, "unknown"),
        }
    }
}

impl std::str::FromStr for ArtifactType {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "paper" => Ok(ArtifactType::Paper),
            "document" => Ok(ArtifactType::Document),
            "repository" | "repo" => Ok(ArtifactType::Repository),
            "dataset" | "data" => Ok(ArtifactType::Dataset),
            "robot" | "hardware" => Ok(ArtifactType::Robot),
            "stream" => Ok(ArtifactType::Stream),
            "external_url" | "url" | "external" => Ok(ArtifactType::ExternalUrl),
            _ => Ok(ArtifactType::Unknown),
        }
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_event_creation() {
        let event = ProvenanceEvent::new(
            "conv-123".to_string(),
            ProvenancePayload::ConversationCreated {
                title: "Test Conversation".to_string(),
                participants: vec!["user@example.com".to_string()],
            },
            "user@example.com".to_string(),
        );

        assert_eq!(event.conversation_id, "conv-123");
        assert!(event.description().contains("Test Conversation"));
    }

    #[test]
    fn test_event_with_causation() {
        let cause_id = ProvenanceEventId::new();
        let event = ProvenanceEvent::new(
            "conv-123".to_string(),
            ProvenancePayload::MessageSent {
                message_id: "msg-1".to_string(),
                role: "counsel".to_string(),
                model_used: Some("opus4.5".to_string()),
                content_hash: "abc123".to_string(),
            },
            "counsel-opus4.5@impart.local".to_string(),
        )
        .with_causation(cause_id);

        assert_eq!(event.causation_id, Some(cause_id));
    }

    #[test]
    fn test_payload_entity_type() {
        let artifact_payload = ProvenancePayload::ArtifactIntroduced {
            artifact_uri: "impress://imbib/papers/Fowler2012".to_string(),
            artifact_type: "paper".to_string(),
            version: None,
            display_name: "Fowler 2012".to_string(),
        };

        assert_eq!(artifact_payload.entity_type(), ProvenanceEntityType::Artifact);

        let decision_payload = ProvenancePayload::DecisionMade {
            decision_id: "d-1".to_string(),
            description: "Use surface codes".to_string(),
            rationale: "Better error correction".to_string(),
            alternatives_considered: vec![],
        };

        assert_eq!(decision_payload.entity_type(), ProvenanceEntityType::Decision);
    }

    #[test]
    fn test_artifact_type_parsing() {
        assert_eq!("paper".parse::<ArtifactType>().unwrap(), ArtifactType::Paper);
        assert_eq!("repo".parse::<ArtifactType>().unwrap(), ArtifactType::Repository);
        assert_eq!("DATASET".parse::<ArtifactType>().unwrap(), ArtifactType::Dataset);
    }
}
