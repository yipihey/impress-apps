//! Thread struct and related types

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{Temperature, ThreadState};
use crate::error::{Result, ThreadError};

/// Unique identifier for a thread
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ThreadId(pub Uuid);

impl ThreadId {
    /// Create a new random thread ID
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    /// Create a thread ID from a UUID
    pub fn from_uuid(uuid: Uuid) -> Self {
        Self(uuid)
    }

    /// Parse a thread ID from a string
    pub fn parse(s: &str) -> Result<Self> {
        Uuid::parse_str(s)
            .map(Self)
            .map_err(|e| ThreadError::NotFound(e.to_string()).into())
    }
}

impl Default for ThreadId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for ThreadId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Metadata for a thread
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ThreadMetadata {
    /// Human-readable title
    pub title: String,
    /// Detailed description
    pub description: String,
    /// Tags for categorization
    pub tags: Vec<String>,
    /// Parent thread ID (for hierarchical threads)
    pub parent_id: Option<ThreadId>,
    /// Related thread IDs
    pub related_ids: Vec<ThreadId>,
    /// Custom key-value metadata
    pub custom: std::collections::HashMap<String, String>,
}

impl Default for ThreadMetadata {
    fn default() -> Self {
        Self {
            title: String::new(),
            description: String::new(),
            tags: Vec::new(),
            parent_id: None,
            related_ids: Vec::new(),
            custom: std::collections::HashMap::new(),
        }
    }
}

/// A research thread in the impel system
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Thread {
    /// Unique identifier
    pub id: ThreadId,
    /// Current state
    pub state: ThreadState,
    /// Temperature (attention priority)
    pub temperature: Temperature,
    /// Thread metadata
    pub metadata: ThreadMetadata,
    /// ID of the agent currently working on this thread (if any)
    pub claimed_by: Option<String>,
    /// IDs of artifacts produced by this thread
    pub artifact_ids: Vec<String>,
    /// Creation timestamp
    pub created_at: DateTime<Utc>,
    /// Last modification timestamp
    pub updated_at: DateTime<Utc>,
    /// Event sequence number for optimistic concurrency
    pub version: u64,
}

impl Thread {
    /// Create a new thread with the given metadata
    pub fn new(metadata: ThreadMetadata) -> Self {
        let now = Utc::now();
        Self {
            id: ThreadId::new(),
            state: ThreadState::Embryo,
            temperature: Temperature::with_priority(0.5),
            metadata,
            claimed_by: None,
            artifact_ids: Vec::new(),
            created_at: now,
            updated_at: now,
            version: 0,
        }
    }

    /// Create a thread with a specific ID
    pub fn with_id(id: ThreadId, metadata: ThreadMetadata) -> Self {
        let now = Utc::now();
        Self {
            id,
            state: ThreadState::Embryo,
            temperature: Temperature::with_priority(0.5),
            metadata,
            claimed_by: None,
            artifact_ids: Vec::new(),
            created_at: now,
            updated_at: now,
            version: 0,
        }
    }

    /// Attempt to transition to a new state
    pub fn transition_to(&mut self, new_state: ThreadState) -> Result<()> {
        if !self.state.can_transition_to(&new_state) {
            return Err(ThreadError::InvalidStateTransition {
                from: self.state.to_string(),
                to: new_state.to_string(),
            }
            .into());
        }
        self.state = new_state;
        self.updated_at = Utc::now();
        self.version += 1;
        Ok(())
    }

    /// Activate the thread (from Embryo state)
    pub fn activate(&mut self) -> Result<()> {
        self.transition_to(ThreadState::Active)
    }

    /// Block the thread
    pub fn block(&mut self) -> Result<()> {
        self.transition_to(ThreadState::Blocked)
    }

    /// Unblock the thread (return to Active)
    pub fn unblock(&mut self) -> Result<()> {
        self.transition_to(ThreadState::Active)
    }

    /// Submit for review
    pub fn submit_for_review(&mut self) -> Result<()> {
        self.transition_to(ThreadState::Review)
    }

    /// Mark as complete
    pub fn complete(&mut self) -> Result<()> {
        self.transition_to(ThreadState::Complete)
    }

    /// Kill the thread
    pub fn kill(&mut self) -> Result<()> {
        self.transition_to(ThreadState::Killed)
    }

    /// Claim the thread for an agent
    pub fn claim(&mut self, agent_id: &str) -> Result<()> {
        if !self.state.is_claimable() {
            return Err(
                ThreadError::NotClaimable(self.id.to_string(), self.state.to_string()).into(),
            );
        }
        if let Some(ref current) = self.claimed_by {
            return Err(ThreadError::AlreadyClaimed(self.id.to_string(), current.clone()).into());
        }
        self.claimed_by = Some(agent_id.to_string());
        self.updated_at = Utc::now();
        self.version += 1;
        Ok(())
    }

    /// Release the thread from the current agent
    pub fn release(&mut self) {
        self.claimed_by = None;
        self.updated_at = Utc::now();
        self.version += 1;
    }

    /// Add an artifact ID to this thread
    pub fn add_artifact(&mut self, artifact_id: String) {
        self.artifact_ids.push(artifact_id);
        self.updated_at = Utc::now();
        self.version += 1;
    }

    /// Check if the thread is claimed
    pub fn is_claimed(&self) -> bool {
        self.claimed_by.is_some()
    }

    /// Check if the thread is claimed by a specific agent
    pub fn is_claimed_by(&self, agent_id: &str) -> bool {
        self.claimed_by.as_deref() == Some(agent_id)
    }

    /// Get the thread's age
    pub fn age(&self) -> chrono::Duration {
        Utc::now() - self.created_at
    }

    /// Get the time since last update
    pub fn time_since_update(&self) -> chrono::Duration {
        Utc::now() - self.updated_at
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_thread() -> Thread {
        Thread::new(ThreadMetadata {
            title: "Test Thread".to_string(),
            description: "A test thread".to_string(),
            ..Default::default()
        })
    }

    #[test]
    fn test_new_thread() {
        let thread = create_test_thread();
        assert_eq!(thread.state, ThreadState::Embryo);
        assert!(thread.claimed_by.is_none());
        assert!(thread.artifact_ids.is_empty());
    }

    #[test]
    fn test_activate() {
        let mut thread = create_test_thread();
        assert!(thread.activate().is_ok());
        assert_eq!(thread.state, ThreadState::Active);
    }

    #[test]
    fn test_claim() {
        let mut thread = create_test_thread();
        thread.activate().unwrap();
        assert!(thread.claim("agent-1").is_ok());
        assert!(thread.is_claimed_by("agent-1"));
    }

    #[test]
    fn test_double_claim_fails() {
        let mut thread = create_test_thread();
        thread.activate().unwrap();
        thread.claim("agent-1").unwrap();
        assert!(thread.claim("agent-2").is_err());
    }

    #[test]
    fn test_full_lifecycle() {
        let mut thread = create_test_thread();
        assert!(thread.activate().is_ok());
        assert!(thread.block().is_ok());
        assert!(thread.unblock().is_ok());
        assert!(thread.submit_for_review().is_ok());
        assert!(thread.complete().is_ok());
        assert!(thread.state.is_terminal());
    }

    #[test]
    fn test_invalid_transition() {
        let mut thread = create_test_thread();
        // Cannot go directly from Embryo to Complete
        assert!(thread.complete().is_err());
    }
}
