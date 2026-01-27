//! Command handlers for coordination operations

use crate::agent::AgentType;
use crate::error::{ImpelError, Result, ThreadError};
use crate::escalation::{Escalation, EscalationCategory};
use crate::event::{EntityType, Event, EventPayload};
use crate::thread::{ThreadId, ThreadMetadata, ThreadState};

use super::CoordinationState;

/// Commands that can be executed on the coordination state
#[derive(Debug, Clone)]
pub enum Command {
    /// Create a new thread
    CreateThread {
        title: String,
        description: String,
        parent_id: Option<ThreadId>,
        priority: Option<f64>,
    },

    /// Activate a thread (transition from Embryo to Active)
    ActivateThread { thread_id: ThreadId },

    /// Claim a thread for an agent
    ClaimThread {
        thread_id: ThreadId,
        agent_id: String,
    },

    /// Release a thread from an agent
    ReleaseThread {
        thread_id: ThreadId,
        agent_id: String,
    },

    /// Block a thread
    BlockThread {
        thread_id: ThreadId,
        reason: Option<String>,
    },

    /// Unblock a thread
    UnblockThread { thread_id: ThreadId },

    /// Submit thread for review
    SubmitForReview { thread_id: ThreadId },

    /// Complete a thread
    CompleteThread { thread_id: ThreadId },

    /// Kill a thread
    KillThread {
        thread_id: ThreadId,
        reason: Option<String>,
    },

    /// Merge two threads
    MergeThreads {
        source_id: ThreadId,
        target_id: ThreadId,
    },

    /// Update thread temperature
    SetTemperature {
        thread_id: ThreadId,
        temperature: f64,
        reason: String,
    },

    /// Register a new agent
    RegisterAgent {
        agent_id: String,
        agent_type: AgentType,
    },

    /// Terminate an agent
    TerminateAgent {
        agent_id: String,
        reason: Option<String>,
    },

    /// Create an escalation
    CreateEscalation {
        category: EscalationCategory,
        title: String,
        description: String,
        created_by: String,
        thread_id: Option<ThreadId>,
    },

    /// Acknowledge an escalation
    AcknowledgeEscalation { escalation_id: String, by: String },

    /// Resolve an escalation
    ResolveEscalation {
        escalation_id: String,
        by: String,
        resolution: String,
    },

    /// Pause the system
    PauseSystem { reason: Option<String> },

    /// Resume the system
    ResumeSystem,
}

impl Command {
    /// Execute the command on the given state
    pub fn execute(self, state: &mut CoordinationState) -> Result<Vec<Event>> {
        match self {
            Command::CreateThread {
                title,
                description,
                parent_id,
                priority,
            } => {
                let thread_id = ThreadId::new();
                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadCreated {
                        title: title.clone(),
                        description: description.clone(),
                        parent_id: parent_id.map(|id| id.to_string()),
                    },
                );
                let event = state.apply_event(event)?;

                // If priority is specified, update temperature
                let mut events = vec![event];
                if let Some(temp) = priority {
                    let temp_event = Event::new(
                        thread_id.to_string(),
                        EntityType::Thread,
                        EventPayload::ThreadTemperatureChanged {
                            old_value: 0.5,
                            new_value: temp,
                            reason: "Initial priority".to_string(),
                        },
                    );
                    events.push(state.apply_event(temp_event)?);
                }

                Ok(events)
            }

            Command::ActivateThread { thread_id } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.state.can_transition_to(&ThreadState::Active) {
                    return Err(ThreadError::InvalidStateTransition {
                        from: thread.state.to_string(),
                        to: ThreadState::Active.to_string(),
                    }
                    .into());
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadStateChanged {
                        from: thread.state,
                        to: ThreadState::Active,
                        reason: None,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::ClaimThread {
                thread_id,
                agent_id,
            } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.state.is_claimable() {
                    return Err(ThreadError::NotClaimable(
                        thread_id.to_string(),
                        thread.state.to_string(),
                    )
                    .into());
                }

                if thread.is_claimed() {
                    return Err(ThreadError::AlreadyClaimed(
                        thread_id.to_string(),
                        thread.claimed_by.clone().unwrap_or_default(),
                    )
                    .into());
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadClaimed {
                        agent_id: agent_id.clone(),
                    },
                )
                .with_actor(agent_id);

                Ok(vec![state.apply_event(event)?])
            }

            Command::ReleaseThread {
                thread_id,
                agent_id,
            } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.is_claimed_by(&agent_id) {
                    return Err(ImpelError::InvalidOperation(format!(
                        "Agent {} does not own thread {}",
                        agent_id, thread_id
                    )));
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadReleased {
                        agent_id: agent_id.clone(),
                    },
                )
                .with_actor(agent_id);

                Ok(vec![state.apply_event(event)?])
            }

            Command::BlockThread { thread_id, reason } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.state.can_transition_to(&ThreadState::Blocked) {
                    return Err(ThreadError::InvalidStateTransition {
                        from: thread.state.to_string(),
                        to: ThreadState::Blocked.to_string(),
                    }
                    .into());
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadStateChanged {
                        from: thread.state,
                        to: ThreadState::Blocked,
                        reason,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::UnblockThread { thread_id } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if thread.state != ThreadState::Blocked {
                    return Err(ImpelError::InvalidOperation(format!(
                        "Thread {} is not blocked",
                        thread_id
                    )));
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadStateChanged {
                        from: ThreadState::Blocked,
                        to: ThreadState::Active,
                        reason: None,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::SubmitForReview { thread_id } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.state.can_transition_to(&ThreadState::Review) {
                    return Err(ThreadError::InvalidStateTransition {
                        from: thread.state.to_string(),
                        to: ThreadState::Review.to_string(),
                    }
                    .into());
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadStateChanged {
                        from: thread.state,
                        to: ThreadState::Review,
                        reason: None,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::CompleteThread { thread_id } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.state.can_transition_to(&ThreadState::Complete) {
                    return Err(ThreadError::InvalidStateTransition {
                        from: thread.state.to_string(),
                        to: ThreadState::Complete.to_string(),
                    }
                    .into());
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadStateChanged {
                        from: thread.state,
                        to: ThreadState::Complete,
                        reason: None,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::KillThread { thread_id, reason } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                if !thread.state.can_transition_to(&ThreadState::Killed) {
                    return Err(ThreadError::InvalidStateTransition {
                        from: thread.state.to_string(),
                        to: ThreadState::Killed.to_string(),
                    }
                    .into());
                }

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadStateChanged {
                        from: thread.state,
                        to: ThreadState::Killed,
                        reason,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::MergeThreads {
                source_id,
                target_id,
            } => {
                // Verify both threads exist
                let _ = state
                    .get_thread(&source_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Source thread {}", source_id)))?;
                let _ = state
                    .get_thread(&target_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Target thread {}", target_id)))?;

                let event = Event::new(
                    source_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadMerged {
                        source_id: source_id.to_string(),
                        target_id: target_id.to_string(),
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::SetTemperature {
                thread_id,
                temperature,
                reason,
            } => {
                let thread = state
                    .get_thread(&thread_id.to_string())
                    .ok_or_else(|| ImpelError::NotFound(format!("Thread {}", thread_id)))?;

                let event = Event::new(
                    thread_id.to_string(),
                    EntityType::Thread,
                    EventPayload::ThreadTemperatureChanged {
                        old_value: thread.temperature.value(),
                        new_value: temperature.clamp(0.0, 1.0),
                        reason,
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::RegisterAgent {
                agent_id,
                agent_type,
            } => {
                let event = Event::new(
                    agent_id.clone(),
                    EntityType::Agent,
                    EventPayload::AgentRegistered {
                        agent_type,
                        capabilities: agent_type
                            .capabilities()
                            .into_iter()
                            .map(|c| c.name().to_string())
                            .collect(),
                    },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::TerminateAgent { agent_id, reason } => {
                let event = Event::new(
                    agent_id.clone(),
                    EntityType::Agent,
                    EventPayload::AgentTerminated { reason },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::CreateEscalation {
                category,
                title,
                description,
                created_by,
                thread_id,
            } => {
                let mut escalation =
                    Escalation::new(category, title.clone(), description, created_by.clone());
                if let Some(tid) = thread_id {
                    escalation = escalation.with_thread(tid);
                }

                let event = Event::new(
                    escalation.id.clone(),
                    EntityType::Escalation,
                    EventPayload::EscalationCreated {
                        category,
                        title,
                        thread_id: escalation.thread_id.map(|t| t.to_string()),
                    },
                )
                .with_actor(created_by);

                state.add_escalation(escalation);

                Ok(vec![state.apply_event(event)?])
            }

            Command::AcknowledgeEscalation { escalation_id, by } => {
                let escalation = state
                    .get_escalation_mut(&escalation_id)
                    .ok_or_else(|| ImpelError::NotFound(format!("Escalation {}", escalation_id)))?;

                escalation.acknowledge(by.clone());

                let event = Event::new(
                    escalation_id,
                    EntityType::Escalation,
                    EventPayload::EscalationAcknowledged {
                        acknowledger_id: by.clone(),
                    },
                )
                .with_actor(by);

                Ok(vec![state.apply_event(event)?])
            }

            Command::ResolveEscalation {
                escalation_id,
                by,
                resolution,
            } => {
                let escalation = state
                    .get_escalation_mut(&escalation_id)
                    .ok_or_else(|| ImpelError::NotFound(format!("Escalation {}", escalation_id)))?;

                escalation.resolve(by.clone(), resolution.clone());

                let event = Event::new(
                    escalation_id,
                    EntityType::Escalation,
                    EventPayload::EscalationResolved {
                        resolver_id: by.clone(),
                        resolution,
                    },
                )
                .with_actor(by);

                Ok(vec![state.apply_event(event)?])
            }

            Command::PauseSystem { reason } => {
                let event = Event::new(
                    "system".to_string(),
                    EntityType::System,
                    EventPayload::SystemPaused { reason },
                );

                Ok(vec![state.apply_event(event)?])
            }

            Command::ResumeSystem => {
                let event = Event::new(
                    "system".to_string(),
                    EntityType::System,
                    EventPayload::SystemResumed,
                );

                Ok(vec![state.apply_event(event)?])
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_thread_command() {
        let mut state = CoordinationState::new();

        let events = Command::CreateThread {
            title: "Test Thread".to_string(),
            description: "A test".to_string(),
            parent_id: None,
            priority: None,
        }
        .execute(&mut state)
        .unwrap();

        assert_eq!(events.len(), 1);
        assert_eq!(state.threads().count(), 1);
    }

    #[test]
    fn test_thread_lifecycle_commands() {
        let mut state = CoordinationState::new();

        // Create
        let events = Command::CreateThread {
            title: "Test".to_string(),
            description: "".to_string(),
            parent_id: None,
            priority: None,
        }
        .execute(&mut state)
        .unwrap();

        let thread_id = ThreadId::parse(&events[0].entity_id).unwrap();

        // Activate
        Command::ActivateThread { thread_id }
            .execute(&mut state)
            .unwrap();

        let thread = state.get_thread(&thread_id.to_string()).unwrap();
        assert_eq!(thread.state, ThreadState::Active);

        // Block
        Command::BlockThread {
            thread_id,
            reason: Some("Need input".to_string()),
        }
        .execute(&mut state)
        .unwrap();

        let thread = state.get_thread(&thread_id.to_string()).unwrap();
        assert_eq!(thread.state, ThreadState::Blocked);

        // Unblock
        Command::UnblockThread { thread_id }
            .execute(&mut state)
            .unwrap();

        // Review
        Command::SubmitForReview { thread_id }
            .execute(&mut state)
            .unwrap();

        // Complete
        Command::CompleteThread { thread_id }
            .execute(&mut state)
            .unwrap();

        let thread = state.get_thread(&thread_id.to_string()).unwrap();
        assert_eq!(thread.state, ThreadState::Complete);
    }

    #[test]
    fn test_claim_thread_command() {
        let mut state = CoordinationState::new();

        // Create and activate thread
        let events = Command::CreateThread {
            title: "Test".to_string(),
            description: "".to_string(),
            parent_id: None,
            priority: None,
        }
        .execute(&mut state)
        .unwrap();

        let thread_id = ThreadId::parse(&events[0].entity_id).unwrap();
        Command::ActivateThread { thread_id }
            .execute(&mut state)
            .unwrap();

        // Claim
        Command::ClaimThread {
            thread_id,
            agent_id: "agent-1".to_string(),
        }
        .execute(&mut state)
        .unwrap();

        let thread = state.get_thread(&thread_id.to_string()).unwrap();
        assert!(thread.is_claimed_by("agent-1"));

        // Double claim should fail
        let result = Command::ClaimThread {
            thread_id,
            agent_id: "agent-2".to_string(),
        }
        .execute(&mut state);

        assert!(result.is_err());
    }
}
