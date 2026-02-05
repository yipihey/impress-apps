//! State projection from events
//!
//! Projections rebuild state by replaying events from the event store.

use std::collections::HashMap;

use super::types::{EntityType, Event, EventPayload};
use crate::agent::{Agent, AgentRegistry, AgentStatus};
use crate::error::Result;
use crate::thread::{Thread, ThreadId, ThreadMetadata, ThreadState};

/// Trait for projecting state from events
pub trait Projection {
    /// Apply an event to update the projected state
    fn apply(&mut self, event: &Event) -> Result<()>;

    /// Reset the projection to initial state
    fn reset(&mut self);
}

/// Projection of thread state from events
#[derive(Debug, Default)]
pub struct ThreadProjection {
    threads: HashMap<String, Thread>,
}

impl ThreadProjection {
    /// Create a new thread projection
    pub fn new() -> Self {
        Self {
            threads: HashMap::new(),
        }
    }

    /// Get a thread by ID
    pub fn get(&self, id: &str) -> Option<&Thread> {
        self.threads.get(id)
    }

    /// Get all threads
    pub fn all(&self) -> impl Iterator<Item = &Thread> {
        self.threads.values()
    }

    /// Get threads by state
    pub fn by_state(&self, state: ThreadState) -> impl Iterator<Item = &Thread> {
        self.threads.values().filter(move |t| t.state == state)
    }

    /// Get unclaimed threads
    pub fn unclaimed(&self) -> impl Iterator<Item = &Thread> {
        self.threads.values().filter(|t| t.claimed_by.is_none())
    }

    /// Get threads sorted by temperature (hottest first)
    pub fn by_temperature(&self) -> Vec<&Thread> {
        let mut threads: Vec<_> = self.threads.values().collect();
        threads.sort_by(|a, b| {
            b.temperature
                .value()
                .partial_cmp(&a.temperature.value())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        threads
    }

    /// Add a thread directly (for loading from persistence)
    ///
    /// This bypasses event sourcing and is intended for initial state loading.
    pub fn add_thread(&mut self, thread: Thread) {
        self.threads.insert(thread.id.to_string(), thread);
    }
}

impl Projection for ThreadProjection {
    fn apply(&mut self, event: &Event) -> Result<()> {
        if event.entity_type != EntityType::Thread {
            return Ok(());
        }

        match &event.payload {
            EventPayload::ThreadCreated {
                title,
                description,
                parent_id,
            } => {
                let metadata = ThreadMetadata {
                    title: title.clone(),
                    description: description.clone(),
                    parent_id: parent_id.as_ref().and_then(|s| ThreadId::parse(s).ok()),
                    ..Default::default()
                };

                let thread_id = ThreadId::parse(&event.entity_id)?;
                let thread = Thread::with_id(thread_id, metadata);
                self.threads.insert(event.entity_id.clone(), thread);
            }

            EventPayload::ThreadStateChanged { to, .. } => {
                if let Some(thread) = self.threads.get_mut(&event.entity_id) {
                    thread.state = *to;
                    thread.version += 1;
                }
            }

            EventPayload::ThreadClaimed { agent_id } => {
                if let Some(thread) = self.threads.get_mut(&event.entity_id) {
                    thread.claimed_by = Some(agent_id.clone());
                    thread.version += 1;
                }
            }

            EventPayload::ThreadReleased { .. } => {
                if let Some(thread) = self.threads.get_mut(&event.entity_id) {
                    thread.claimed_by = None;
                    thread.version += 1;
                }
            }

            EventPayload::ThreadTemperatureChanged { new_value, .. } => {
                if let Some(thread) = self.threads.get_mut(&event.entity_id) {
                    thread.temperature = crate::thread::Temperature::new(*new_value);
                    thread.version += 1;
                }
            }

            EventPayload::ThreadArtifactAdded { artifact_id, .. } => {
                if let Some(thread) = self.threads.get_mut(&event.entity_id) {
                    thread.artifact_ids.push(artifact_id.clone());
                    thread.version += 1;
                }
            }

            EventPayload::ThreadMerged { target_id, .. } => {
                // Mark source thread as killed when merged
                if let Some(thread) = self.threads.get_mut(&event.entity_id) {
                    thread.state = ThreadState::Killed;
                    thread
                        .metadata
                        .custom
                        .insert("merged_into".to_string(), target_id.clone());
                    thread.version += 1;
                }
            }

            _ => {}
        }

        // Update timestamp for any thread event
        if let Some(thread) = self.threads.get_mut(&event.entity_id) {
            thread.updated_at = event.timestamp;
        }

        Ok(())
    }

    fn reset(&mut self) {
        self.threads.clear();
    }
}

/// Projection of agent state from events
#[derive(Debug, Default)]
pub struct AgentProjection {
    registry: AgentRegistry,
}

impl AgentProjection {
    /// Create a new agent projection
    pub fn new() -> Self {
        Self {
            registry: AgentRegistry::new(),
        }
    }

    /// Get the agent registry
    pub fn registry(&self) -> &AgentRegistry {
        &self.registry
    }

    /// Get a mutable reference to the agent registry
    pub fn registry_mut(&mut self) -> &mut AgentRegistry {
        &mut self.registry
    }
}

impl Projection for AgentProjection {
    fn apply(&mut self, event: &Event) -> Result<()> {
        if event.entity_type != EntityType::Agent {
            return Ok(());
        }

        match &event.payload {
            EventPayload::AgentRegistered { agent_type, .. } => {
                let agent = Agent::new(event.entity_id.clone(), *agent_type);
                let _ = self.registry.register(agent);
            }

            EventPayload::AgentStatusChanged { to, .. } => {
                if let Some(agent) = self.registry.get_mut(&event.entity_id) {
                    agent.status = match to.as_str() {
                        "IDLE" => AgentStatus::Idle,
                        "WORKING" => AgentStatus::Working,
                        "PAUSED" => AgentStatus::Paused,
                        "TERMINATED" => AgentStatus::Terminated,
                        _ => agent.status,
                    };
                }
            }

            EventPayload::AgentTerminated { .. } => {
                if let Some(agent) = self.registry.get_mut(&event.entity_id) {
                    agent.terminate();
                }
            }

            _ => {}
        }

        // Update activity timestamp for any agent event
        if let Some(agent) = self.registry.get_mut(&event.entity_id) {
            agent.record_activity();
        }

        Ok(())
    }

    fn reset(&mut self) {
        self.registry = AgentRegistry::new();
    }
}

/// Combined projection for the entire system state
#[derive(Debug, Default)]
pub struct SystemProjection {
    pub threads: ThreadProjection,
    pub agents: AgentProjection,
    pub is_paused: bool,
    pub last_sequence: u64,
}

impl SystemProjection {
    /// Create a new system projection
    pub fn new() -> Self {
        Self {
            threads: ThreadProjection::new(),
            agents: AgentProjection::new(),
            is_paused: false,
            last_sequence: 0,
        }
    }

    /// Rebuild state from a list of events
    pub fn rebuild<'a>(&mut self, events: impl Iterator<Item = &'a Event>) -> Result<()> {
        self.reset();
        for event in events {
            self.apply(event)?;
        }
        Ok(())
    }
}

impl Projection for SystemProjection {
    fn apply(&mut self, event: &Event) -> Result<()> {
        // Update sequence tracking
        self.last_sequence = self.last_sequence.max(event.sequence);

        // Apply to sub-projections
        self.threads.apply(event)?;
        self.agents.apply(event)?;

        // Handle system-level events
        match &event.payload {
            EventPayload::SystemPaused { .. } => {
                self.is_paused = true;
            }
            EventPayload::SystemResumed => {
                self.is_paused = false;
            }
            _ => {}
        }

        Ok(())
    }

    fn reset(&mut self) {
        self.threads.reset();
        self.agents.reset();
        self.is_paused = false;
        self.last_sequence = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::AgentType;
    use crate::thread::ThreadId;

    #[test]
    fn test_thread_projection() {
        let mut projection = ThreadProjection::new();

        let thread_id = ThreadId::new();
        let event = Event::new(
            thread_id.to_string(),
            EntityType::Thread,
            EventPayload::ThreadCreated {
                title: "Test Thread".to_string(),
                description: "A test".to_string(),
                parent_id: None,
            },
        );

        projection.apply(&event).unwrap();
        assert!(projection.get(&thread_id.to_string()).is_some());
    }

    #[test]
    fn test_thread_state_changes() {
        let mut projection = ThreadProjection::new();

        let thread_id = ThreadId::new();

        // Create thread
        projection
            .apply(&Event::new(
                thread_id.to_string(),
                EntityType::Thread,
                EventPayload::ThreadCreated {
                    title: "Test".to_string(),
                    description: "".to_string(),
                    parent_id: None,
                },
            ))
            .unwrap();

        // Activate thread
        projection
            .apply(&Event::new(
                thread_id.to_string(),
                EntityType::Thread,
                EventPayload::ThreadStateChanged {
                    from: ThreadState::Embryo,
                    to: ThreadState::Active,
                    reason: None,
                },
            ))
            .unwrap();

        let thread = projection.get(&thread_id.to_string()).unwrap();
        assert_eq!(thread.state, ThreadState::Active);
    }

    #[test]
    fn test_agent_projection() {
        let mut projection = AgentProjection::new();

        let event = Event::new(
            "research-1".to_string(),
            EntityType::Agent,
            EventPayload::AgentRegistered {
                agent_type: AgentType::Research,
                capabilities: vec!["literature_search".to_string()],
            },
        );

        projection.apply(&event).unwrap();
        assert!(projection.registry().get("research-1").is_some());
    }

    #[test]
    fn test_system_projection() {
        let mut projection = SystemProjection::new();

        // System pause event
        projection
            .apply(&Event::new(
                "system".to_string(),
                EntityType::System,
                EventPayload::SystemPaused { reason: None },
            ))
            .unwrap();

        assert!(projection.is_paused);

        // System resume event
        projection
            .apply(&Event::new(
                "system".to_string(),
                EntityType::System,
                EventPayload::SystemResumed,
            ))
            .unwrap();

        assert!(!projection.is_paused);
    }
}
