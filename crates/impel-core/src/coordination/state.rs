//! Coordination state aggregate root

use std::collections::HashMap;

use crate::agent::AgentRegistry;
use crate::error::Result;
use crate::escalation::Escalation;
use crate::event::{Event, EventStore, InMemoryEventStore, Projection, SystemProjection};
use crate::thread::{Thread, ThreadId};

/// The aggregate root for the impel coordination state
pub struct CoordinationState {
    /// Event store for persisting events
    event_store: InMemoryEventStore,
    /// Projected state from events
    projection: SystemProjection,
    /// Active escalations (not persisted in projection)
    escalations: HashMap<String, Escalation>,
    /// Whether the system is paused
    paused: bool,
}

impl CoordinationState {
    /// Create a new coordination state
    pub fn new() -> Self {
        Self {
            event_store: InMemoryEventStore::new(),
            projection: SystemProjection::new(),
            escalations: HashMap::new(),
            paused: false,
        }
    }

    /// Record an event and update projections
    pub fn apply_event(&mut self, event: Event) -> Result<Event> {
        let event = self.event_store.append(event)?;
        self.projection.apply(&event)?;

        // Update paused state from system events
        if let crate::event::EventPayload::SystemPaused { .. } = event.payload {
            self.paused = true;
        } else if let crate::event::EventPayload::SystemResumed = event.payload {
            self.paused = false;
        }

        Ok(event)
    }

    /// Get the current sequence number
    pub fn current_sequence(&self) -> u64 {
        self.event_store.current_sequence()
    }

    /// Check if the system is paused
    pub fn is_paused(&self) -> bool {
        self.paused
    }

    /// Pause the system
    pub fn pause(&mut self) {
        self.paused = true;
    }

    /// Resume the system
    pub fn resume(&mut self) {
        self.paused = false;
    }

    // ==================== Thread Operations ====================

    /// Get a thread by ID
    pub fn get_thread(&self, id: &str) -> Option<&Thread> {
        self.projection.threads.get(id)
    }

    /// Get all threads
    pub fn threads(&self) -> impl Iterator<Item = &Thread> {
        self.projection.threads.all()
    }

    /// Get threads by state
    pub fn threads_by_state(
        &self,
        state: crate::thread::ThreadState,
    ) -> impl Iterator<Item = &Thread> {
        self.projection.threads.by_state(state)
    }

    /// Get available threads (unclaimed, workable)
    pub fn available_threads(&self) -> impl Iterator<Item = &Thread> {
        self.projection
            .threads
            .all()
            .filter(|t| !t.is_claimed() && t.state.is_claimable())
    }

    /// Get threads sorted by temperature (hottest first)
    pub fn threads_by_temperature(&self) -> Vec<&Thread> {
        self.projection.threads.by_temperature()
    }

    // ==================== Agent Operations ====================

    /// Get the agent registry
    pub fn agents(&self) -> &AgentRegistry {
        self.projection.agents.registry()
    }

    /// Get a mutable reference to the agent registry
    pub fn agents_mut(&mut self) -> &mut AgentRegistry {
        self.projection.agents.registry_mut()
    }

    // ==================== Escalation Operations ====================

    /// Add an escalation
    pub fn add_escalation(&mut self, escalation: Escalation) {
        self.escalations.insert(escalation.id.clone(), escalation);
    }

    /// Get an escalation by ID
    pub fn get_escalation(&self, id: &str) -> Option<&Escalation> {
        self.escalations.get(id)
    }

    /// Get a mutable escalation by ID
    pub fn get_escalation_mut(&mut self, id: &str) -> Option<&mut Escalation> {
        self.escalations.get_mut(id)
    }

    /// Get open escalations sorted by priority
    pub fn open_escalations(&self) -> Vec<&Escalation> {
        let mut escalations: Vec<_> = self
            .escalations
            .values()
            .filter(|e| e.status.is_open())
            .collect();
        escalations.sort_by(|a, b| {
            b.priority
                .cmp(&a.priority)
                .then_with(|| a.created_at.cmp(&b.created_at))
        });
        escalations
    }

    /// Get all escalations
    pub fn all_escalations(&self) -> impl Iterator<Item = &Escalation> {
        self.escalations.values()
    }

    // ==================== Event Operations ====================

    /// Get events since a sequence number
    pub fn events_since(&self, sequence: u64) -> Vec<&Event> {
        self.event_store.events_after(sequence)
    }

    /// Get all events
    pub fn all_events(&self) -> Vec<&Event> {
        self.event_store.all_events()
    }

    // ==================== Rebuild ====================

    /// Rebuild state from the event log
    pub fn rebuild(&mut self) -> Result<()> {
        let events: Vec<_> = self.event_store.all_events().into_iter().cloned().collect();
        self.projection.rebuild(events.iter())?;
        self.paused = self.projection.is_paused;
        Ok(())
    }

    // ==================== Persistence Integration ====================

    /// Load state from a repository
    ///
    /// This loads threads, agents, and escalations from the given repository
    /// and populates the coordination state.
    #[cfg(feature = "sqlite")]
    pub fn load_from_repository(&mut self, repo: &crate::persistence::Repository) -> Result<()> {
        // Load threads
        let threads = repo.get_all_threads()?;
        for thread in threads {
            self.projection.threads.add_thread(thread);
        }

        // Load agents
        let agents = repo.get_all_agents()?;
        for agent in agents {
            self.projection.agents.registry_mut().add_agent(agent);
        }

        // Load escalations
        let escalations = repo.get_open_escalations()?;
        for escalation in escalations {
            self.escalations.insert(escalation.id.clone(), escalation);
        }

        // Load system state
        if let Some(paused_str) = repo.get_system_state("paused")? {
            self.paused = paused_str == "true";
        }

        Ok(())
    }

    /// Save current state to a repository
    ///
    /// This persists threads, agents, and escalations to the given repository.
    #[cfg(feature = "sqlite")]
    pub fn save_to_repository(&self, repo: &crate::persistence::Repository) -> Result<()> {
        // Save threads
        for thread in self.threads() {
            repo.save_thread(thread)?;
        }

        // Save agents
        for agent in self.agents().all() {
            repo.save_agent(agent)?;
        }

        // Save escalations
        for escalation in self.escalations.values() {
            repo.save_escalation(escalation)?;
        }

        // Save system state
        repo.set_system_state("paused", if self.paused { "true" } else { "false" })?;

        Ok(())
    }
}

impl Default for CoordinationState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::AgentType;
    use crate::event::{EntityType, EventPayload};
    use crate::thread::ThreadState;

    #[test]
    fn test_coordination_state_creation() {
        let state = CoordinationState::new();
        assert!(!state.is_paused());
        assert_eq!(state.current_sequence(), 0);
    }

    #[test]
    fn test_thread_lifecycle() {
        let mut state = CoordinationState::new();

        // Create thread
        let thread_id = ThreadId::new();
        state
            .apply_event(Event::new(
                thread_id.to_string(),
                EntityType::Thread,
                EventPayload::ThreadCreated {
                    title: "Test".to_string(),
                    description: "A test thread".to_string(),
                    parent_id: None,
                },
            ))
            .unwrap();

        assert!(state.get_thread(&thread_id.to_string()).is_some());

        // Activate thread
        state
            .apply_event(Event::new(
                thread_id.to_string(),
                EntityType::Thread,
                EventPayload::ThreadStateChanged {
                    from: ThreadState::Embryo,
                    to: ThreadState::Active,
                    reason: None,
                },
            ))
            .unwrap();

        let thread = state.get_thread(&thread_id.to_string()).unwrap();
        assert_eq!(thread.state, ThreadState::Active);
    }

    #[test]
    fn test_pause_resume() {
        let mut state = CoordinationState::new();

        state
            .apply_event(Event::new(
                "system".to_string(),
                EntityType::System,
                EventPayload::SystemPaused { reason: None },
            ))
            .unwrap();

        assert!(state.is_paused());

        state
            .apply_event(Event::new(
                "system".to_string(),
                EntityType::System,
                EventPayload::SystemResumed,
            ))
            .unwrap();

        assert!(!state.is_paused());
    }

    #[test]
    fn test_escalation_priority_ordering() {
        use crate::escalation::{EscalationCategory, EscalationPriority};

        let mut state = CoordinationState::new();

        let mut low = Escalation::new(
            EscalationCategory::Checkpoint,
            "Low".to_string(),
            "".to_string(),
            "agent".to_string(),
        );
        low.priority = EscalationPriority::Low;

        let mut high = Escalation::new(
            EscalationCategory::Stuck,
            "High".to_string(),
            "".to_string(),
            "agent".to_string(),
        );
        high.priority = EscalationPriority::High;

        state.add_escalation(low);
        state.add_escalation(high);

        let open = state.open_escalations();
        assert_eq!(open[0].title, "High");
        assert_eq!(open[1].title, "Low");
    }
}
