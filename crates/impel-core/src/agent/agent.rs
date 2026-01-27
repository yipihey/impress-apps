//! Agent struct and status

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::AgentType;
use crate::thread::ThreadId;

/// Status of an agent
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AgentStatus {
    /// Agent is available to claim work
    Idle,
    /// Agent is actively working on a thread
    Working,
    /// Agent is paused (not accepting work)
    Paused,
    /// Agent has been terminated
    Terminated,
}

impl AgentStatus {
    /// Check if the agent can accept work
    pub fn can_accept_work(&self) -> bool {
        matches!(self, AgentStatus::Idle)
    }

    /// Check if the agent is active (not terminated)
    pub fn is_active(&self) -> bool {
        !matches!(self, AgentStatus::Terminated)
    }
}

impl std::fmt::Display for AgentStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AgentStatus::Idle => write!(f, "IDLE"),
            AgentStatus::Working => write!(f, "WORKING"),
            AgentStatus::Paused => write!(f, "PAUSED"),
            AgentStatus::Terminated => write!(f, "TERMINATED"),
        }
    }
}

/// An agent in the impel system
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    /// Unique identifier (typically agent-type-number, e.g., "research-1")
    pub id: String,
    /// Type of agent
    pub agent_type: AgentType,
    /// Current status
    pub status: AgentStatus,
    /// ID of the thread currently being worked on (if any)
    pub current_thread: Option<ThreadId>,
    /// Authentication token for API access
    pub auth_token: Option<String>,
    /// Registration timestamp
    pub registered_at: DateTime<Utc>,
    /// Last activity timestamp
    pub last_active_at: DateTime<Utc>,
    /// Number of threads completed
    pub threads_completed: u64,
    /// Custom metadata
    pub metadata: std::collections::HashMap<String, String>,
}

impl Agent {
    /// Create a new agent
    pub fn new(id: String, agent_type: AgentType) -> Self {
        let now = Utc::now();
        Self {
            id,
            agent_type,
            status: AgentStatus::Idle,
            current_thread: None,
            auth_token: None,
            registered_at: now,
            last_active_at: now,
            threads_completed: 0,
            metadata: std::collections::HashMap::new(),
        }
    }

    /// Create an agent with an auto-generated ID
    pub fn new_with_type(agent_type: AgentType, instance_number: u32) -> Self {
        let id = format!("{}-{}", agent_type.name().to_lowercase(), instance_number);
        Self::new(id, agent_type)
    }

    /// Set the agent's authentication token
    pub fn with_auth_token(mut self, token: String) -> Self {
        self.auth_token = Some(token);
        self
    }

    /// Assign a thread to this agent
    pub fn assign_thread(&mut self, thread_id: ThreadId) {
        self.current_thread = Some(thread_id);
        self.status = AgentStatus::Working;
        self.last_active_at = Utc::now();
    }

    /// Release the current thread
    pub fn release_thread(&mut self) {
        self.current_thread = None;
        self.status = AgentStatus::Idle;
        self.last_active_at = Utc::now();
    }

    /// Mark thread as completed and release
    pub fn complete_thread(&mut self) {
        self.current_thread = None;
        self.status = AgentStatus::Idle;
        self.threads_completed += 1;
        self.last_active_at = Utc::now();
    }

    /// Pause the agent
    pub fn pause(&mut self) {
        if self.status != AgentStatus::Terminated {
            self.status = AgentStatus::Paused;
            self.last_active_at = Utc::now();
        }
    }

    /// Resume the agent
    pub fn resume(&mut self) {
        if self.status == AgentStatus::Paused {
            self.status = if self.current_thread.is_some() {
                AgentStatus::Working
            } else {
                AgentStatus::Idle
            };
            self.last_active_at = Utc::now();
        }
    }

    /// Terminate the agent
    pub fn terminate(&mut self) {
        self.status = AgentStatus::Terminated;
        self.current_thread = None;
        self.last_active_at = Utc::now();
    }

    /// Record activity
    pub fn record_activity(&mut self) {
        self.last_active_at = Utc::now();
    }

    /// Get the time since last activity
    pub fn time_since_activity(&self) -> chrono::Duration {
        Utc::now() - self.last_active_at
    }

    /// Check if the agent has been inactive for a specified duration
    pub fn is_inactive_for(&self, duration: chrono::Duration) -> bool {
        self.time_since_activity() >= duration
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_agent() {
        let agent = Agent::new("test-1".to_string(), AgentType::Research);
        assert_eq!(agent.id, "test-1");
        assert_eq!(agent.agent_type, AgentType::Research);
        assert_eq!(agent.status, AgentStatus::Idle);
        assert!(agent.current_thread.is_none());
    }

    #[test]
    fn test_auto_id() {
        let agent = Agent::new_with_type(AgentType::Code, 42);
        assert_eq!(agent.id, "code-42");
    }

    #[test]
    fn test_assign_thread() {
        let mut agent = Agent::new("test-1".to_string(), AgentType::Research);
        let thread_id = ThreadId::new();
        agent.assign_thread(thread_id);
        assert_eq!(agent.status, AgentStatus::Working);
        assert!(agent.current_thread.is_some());
    }

    #[test]
    fn test_complete_thread() {
        let mut agent = Agent::new("test-1".to_string(), AgentType::Research);
        agent.assign_thread(ThreadId::new());
        agent.complete_thread();
        assert_eq!(agent.status, AgentStatus::Idle);
        assert!(agent.current_thread.is_none());
        assert_eq!(agent.threads_completed, 1);
    }

    #[test]
    fn test_pause_resume() {
        let mut agent = Agent::new("test-1".to_string(), AgentType::Research);
        agent.pause();
        assert_eq!(agent.status, AgentStatus::Paused);
        agent.resume();
        assert_eq!(agent.status, AgentStatus::Idle);
    }
}
