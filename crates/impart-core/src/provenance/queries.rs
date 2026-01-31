//! Provenance query utilities for tracing lineage and history.
//!
//! This module provides high-level query functions for understanding
//! the provenance of ideas, artifacts, and decisions in research conversations.

use super::store::EventStore;
use super::types::{ProvenanceEntityType, ProvenanceEvent, ProvenanceEventId, ProvenancePayload};
use crate::Result;

// MARK: - Lineage Tracing

/// Trace the lineage of a message or event, showing the chain of causation.
///
/// Returns events in reverse chronological order (most recent first),
/// following the causation chain from the given event back to its origins.
pub fn trace_lineage(store: &EventStore, event_id: &ProvenanceEventId) -> Result<Vec<ProvenanceEvent>> {
    let mut lineage = Vec::new();
    let mut current_id = Some(*event_id);

    while let Some(id) = current_id {
        if let Some(event) = store.get(&id)? {
            current_id = event.causation_id;
            lineage.push(event);
        } else {
            break;
        }
    }

    Ok(lineage)
}

/// Trace forward from an event to find all events it caused.
///
/// Returns events in chronological order.
pub fn trace_effects(store: &EventStore, event_id: &ProvenanceEventId) -> Result<Vec<ProvenanceEvent>> {
    let all_events = store.all_events()?;

    let effects: Vec<ProvenanceEvent> = all_events
        .into_iter()
        .filter(|e| e.causation_id == Some(*event_id))
        .collect();

    Ok(effects)
}

// MARK: - Artifact History

/// Get the complete history of an artifact's mentions and references.
pub fn artifact_history(store: &EventStore, artifact_uri: &str) -> Result<Vec<ProvenanceEvent>> {
    let artifact_events = store.events_by_entity_type(ProvenanceEntityType::Artifact)?;

    let history: Vec<ProvenanceEvent> = artifact_events
        .into_iter()
        .filter(|e| match &e.payload {
            ProvenancePayload::ArtifactIntroduced { artifact_uri: uri, .. } => uri == artifact_uri,
            ProvenancePayload::ArtifactReferenced { artifact_uri: uri, .. } => uri == artifact_uri,
            ProvenancePayload::ArtifactMetadataUpdated { artifact_uri: uri, .. } => uri == artifact_uri,
            ProvenancePayload::ArtifactResolved { artifact_uri: uri, .. } => uri == artifact_uri,
            ProvenancePayload::ArtifactLinked { source_uri, target_uri, .. } => {
                source_uri == artifact_uri || target_uri == artifact_uri
            }
            _ => false,
        })
        .collect();

    Ok(history)
}

/// Find where an artifact was first introduced.
pub fn artifact_introduction(
    store: &EventStore,
    artifact_uri: &str,
) -> Result<Option<ProvenanceEvent>> {
    let history = artifact_history(store, artifact_uri)?;

    Ok(history.into_iter().find(|e| {
        matches!(
            e.payload,
            ProvenancePayload::ArtifactIntroduced { .. }
        )
    }))
}

/// Find all artifacts introduced in a conversation.
pub fn artifacts_in_conversation(
    store: &EventStore,
    conversation_id: &str,
) -> Result<Vec<String>> {
    let events = store.events_for_conversation(conversation_id)?;

    let artifact_uris: Vec<String> = events
        .into_iter()
        .filter_map(|e| match e.payload {
            ProvenancePayload::ArtifactIntroduced { artifact_uri, .. } => Some(artifact_uri),
            _ => None,
        })
        .collect();

    // Deduplicate while preserving order
    let mut seen = std::collections::HashSet::new();
    let unique: Vec<String> = artifact_uris
        .into_iter()
        .filter(|uri| seen.insert(uri.clone()))
        .collect();

    Ok(unique)
}

// MARK: - Decision History

/// Get all decisions made in a conversation.
pub fn decisions_in_conversation(
    store: &EventStore,
    conversation_id: &str,
) -> Result<Vec<ProvenanceEvent>> {
    let events = store.events_for_conversation(conversation_id)?;

    let decisions: Vec<ProvenanceEvent> = events
        .into_iter()
        .filter(|e| {
            matches!(
                e.payload,
                ProvenancePayload::DecisionMade { .. } | ProvenancePayload::DecisionRevised { .. }
            )
        })
        .collect();

    Ok(decisions)
}

/// Get the history of a specific decision.
pub fn decision_history(store: &EventStore, decision_id: &str) -> Result<Vec<ProvenanceEvent>> {
    let decision_events = store.events_by_entity_type(ProvenanceEntityType::Decision)?;

    let history: Vec<ProvenanceEvent> = decision_events
        .into_iter()
        .filter(|e| match &e.payload {
            ProvenancePayload::DecisionMade {
                decision_id: id, ..
            } => id == decision_id,
            ProvenancePayload::DecisionRevised {
                decision_id: id, ..
            } => id == decision_id,
            _ => false,
        })
        .collect();

    Ok(history)
}

// MARK: - Insight History

/// Get all insights recorded in a conversation.
pub fn insights_in_conversation(
    store: &EventStore,
    conversation_id: &str,
) -> Result<Vec<ProvenanceEvent>> {
    let events = store.events_for_conversation(conversation_id)?;

    let insights: Vec<ProvenanceEvent> = events
        .into_iter()
        .filter(|e| matches!(e.payload, ProvenancePayload::InsightRecorded { .. }))
        .collect();

    Ok(insights)
}

/// Find insights derived from a specific artifact or message.
pub fn insights_derived_from(
    store: &EventStore,
    source_id: &str,
) -> Result<Vec<ProvenanceEvent>> {
    let insight_events = store.events_by_entity_type(ProvenanceEntityType::Insight)?;

    let derived: Vec<ProvenanceEvent> = insight_events
        .into_iter()
        .filter(|e| {
            if let ProvenancePayload::InsightRecorded { derived_from, .. } = &e.payload {
                derived_from.contains(&source_id.to_string())
            } else {
                false
            }
        })
        .collect();

    Ok(derived)
}

// MARK: - Actor History

/// Get all events triggered by a specific actor.
pub fn events_by_actor(store: &EventStore, actor_id: &str) -> Result<Vec<ProvenanceEvent>> {
    let all_events = store.all_events()?;

    let actor_events: Vec<ProvenanceEvent> = all_events
        .into_iter()
        .filter(|e| e.actor_id == actor_id)
        .collect();

    Ok(actor_events)
}

/// Get all unique actors in a conversation.
pub fn actors_in_conversation(
    store: &EventStore,
    conversation_id: &str,
) -> Result<Vec<String>> {
    let events = store.events_for_conversation(conversation_id)?;

    let mut seen = std::collections::HashSet::new();
    let actors: Vec<String> = events
        .into_iter()
        .map(|e| e.actor_id)
        .filter(|id| seen.insert(id.clone()))
        .collect();

    Ok(actors)
}

// MARK: - Time-Based Queries

/// Get events in a time range.
pub fn events_in_time_range(
    store: &EventStore,
    conversation_id: &str,
    start: chrono::DateTime<chrono::Utc>,
    end: chrono::DateTime<chrono::Utc>,
) -> Result<Vec<ProvenanceEvent>> {
    let events = store.events_for_conversation(conversation_id)?;

    let in_range: Vec<ProvenanceEvent> = events
        .into_iter()
        .filter(|e| e.timestamp >= start && e.timestamp <= end)
        .collect();

    Ok(in_range)
}

// MARK: - Conversation Statistics

/// Statistics about a conversation's provenance.
#[derive(Debug, Clone)]
pub struct ConversationProvenanceStats {
    /// Total number of provenance events.
    pub total_events: usize,
    /// Number of messages sent.
    pub message_count: usize,
    /// Number of unique artifacts referenced.
    pub artifact_count: usize,
    /// Number of decisions made.
    pub decision_count: usize,
    /// Number of insights recorded.
    pub insight_count: usize,
    /// Number of unique actors.
    pub actor_count: usize,
    /// Number of branch conversations.
    pub branch_count: usize,
}

/// Get provenance statistics for a conversation.
pub fn conversation_stats(
    store: &EventStore,
    conversation_id: &str,
) -> Result<ConversationProvenanceStats> {
    let events = store.events_for_conversation(conversation_id)?;

    let message_count = events
        .iter()
        .filter(|e| matches!(e.payload, ProvenancePayload::MessageSent { .. }))
        .count();

    let artifact_uris: std::collections::HashSet<String> = events
        .iter()
        .filter_map(|e| match &e.payload {
            ProvenancePayload::ArtifactIntroduced { artifact_uri, .. } => {
                Some(artifact_uri.clone())
            }
            _ => None,
        })
        .collect();

    let decision_count = events
        .iter()
        .filter(|e| matches!(e.payload, ProvenancePayload::DecisionMade { .. }))
        .count();

    let insight_count = events
        .iter()
        .filter(|e| matches!(e.payload, ProvenancePayload::InsightRecorded { .. }))
        .count();

    let actors: std::collections::HashSet<&String> =
        events.iter().map(|e| &e.actor_id).collect();

    let branch_count = events
        .iter()
        .filter(|e| matches!(e.payload, ProvenancePayload::ConversationBranched { .. }))
        .count();

    Ok(ConversationProvenanceStats {
        total_events: events.len(),
        message_count,
        artifact_count: artifact_uris.len(),
        decision_count,
        insight_count,
        actor_count: actors.len(),
        branch_count,
    })
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn create_store_with_events() -> EventStore {
        let mut store = EventStore::in_memory();

        // Create conversation
        let create_event = ProvenanceEvent::new(
            "conv-1".to_string(),
            ProvenancePayload::ConversationCreated {
                title: "Test".to_string(),
                participants: vec!["user@example.com".to_string()],
            },
            "user@example.com".to_string(),
        );
        let created = store.append(create_event).unwrap();

        // Send message
        let msg_event = ProvenanceEvent::new(
            "conv-1".to_string(),
            ProvenancePayload::MessageSent {
                message_id: "msg-1".to_string(),
                role: "human".to_string(),
                model_used: None,
                content_hash: "abc".to_string(),
            },
            "user@example.com".to_string(),
        )
        .with_causation(created.id);
        store.append(msg_event).unwrap();

        // Introduce artifact
        let artifact_event = ProvenanceEvent::new(
            "conv-1".to_string(),
            ProvenancePayload::ArtifactIntroduced {
                artifact_uri: "impress://imbib/papers/Fowler2012".to_string(),
                artifact_type: "paper".to_string(),
                version: None,
                display_name: "Fowler 2012".to_string(),
            },
            "user@example.com".to_string(),
        );
        store.append(artifact_event).unwrap();

        store
    }

    #[test]
    fn test_trace_lineage() {
        let store = create_store_with_events();
        let events = store.all_events().unwrap();
        let msg_event = &events[1]; // Message event

        let lineage = trace_lineage(&store, &msg_event.id).unwrap();
        assert_eq!(lineage.len(), 2); // Message + ConversationCreated
    }

    #[test]
    fn test_artifact_history() {
        let store = create_store_with_events();

        let history = artifact_history(&store, "impress://imbib/papers/Fowler2012").unwrap();
        assert_eq!(history.len(), 1);
    }

    #[test]
    fn test_artifacts_in_conversation() {
        let store = create_store_with_events();

        let artifacts = artifacts_in_conversation(&store, "conv-1").unwrap();
        assert_eq!(artifacts.len(), 1);
        assert_eq!(artifacts[0], "impress://imbib/papers/Fowler2012");
    }

    #[test]
    fn test_conversation_stats() {
        let store = create_store_with_events();

        let stats = conversation_stats(&store, "conv-1").unwrap();
        assert_eq!(stats.total_events, 3);
        assert_eq!(stats.message_count, 1);
        assert_eq!(stats.artifact_count, 1);
        assert_eq!(stats.actor_count, 1);
    }

    #[test]
    fn test_actors_in_conversation() {
        let store = create_store_with_events();

        let actors = actors_in_conversation(&store, "conv-1").unwrap();
        assert_eq!(actors.len(), 1);
        assert_eq!(actors[0], "user@example.com");
    }
}
