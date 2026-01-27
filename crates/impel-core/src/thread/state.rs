//! Thread state machine
//!
//! State transitions:
//! ```text
//! Embryo → Active ↔ Blocked → Review → Complete
//!                      ↓         ↓
//!                    Killed   Killed
//! ```

use serde::{Deserialize, Serialize};

/// The state of a research thread
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ThreadState {
    /// Thread is newly created, not yet started
    Embryo,
    /// Thread is actively being worked on
    Active,
    /// Thread is blocked waiting for input/resources
    Blocked,
    /// Thread is in review phase
    Review,
    /// Thread completed successfully
    Complete,
    /// Thread was terminated
    Killed,
}

impl ThreadState {
    /// Check if a state transition is valid
    pub fn can_transition_to(&self, target: &ThreadState) -> bool {
        match (self, target) {
            // Embryo can only become Active
            (ThreadState::Embryo, ThreadState::Active) => true,

            // Active can become Blocked, Review, or Killed
            (ThreadState::Active, ThreadState::Blocked) => true,
            (ThreadState::Active, ThreadState::Review) => true,
            (ThreadState::Active, ThreadState::Killed) => true,

            // Blocked can return to Active or be Killed
            (ThreadState::Blocked, ThreadState::Active) => true,
            (ThreadState::Blocked, ThreadState::Killed) => true,

            // Review can become Complete, return to Active, or be Killed
            (ThreadState::Review, ThreadState::Complete) => true,
            (ThreadState::Review, ThreadState::Active) => true,
            (ThreadState::Review, ThreadState::Killed) => true,

            // Complete and Killed are terminal states
            (ThreadState::Complete, _) => false,
            (ThreadState::Killed, _) => false,

            // All other transitions are invalid
            _ => false,
        }
    }

    /// Get valid next states from current state
    pub fn valid_transitions(&self) -> Vec<ThreadState> {
        match self {
            ThreadState::Embryo => vec![ThreadState::Active],
            ThreadState::Active => {
                vec![
                    ThreadState::Blocked,
                    ThreadState::Review,
                    ThreadState::Killed,
                ]
            }
            ThreadState::Blocked => vec![ThreadState::Active, ThreadState::Killed],
            ThreadState::Review => {
                vec![
                    ThreadState::Complete,
                    ThreadState::Active,
                    ThreadState::Killed,
                ]
            }
            ThreadState::Complete => vec![],
            ThreadState::Killed => vec![],
        }
    }

    /// Check if the thread is in a terminal state
    pub fn is_terminal(&self) -> bool {
        matches!(self, ThreadState::Complete | ThreadState::Killed)
    }

    /// Check if the thread can accept work
    pub fn is_workable(&self) -> bool {
        matches!(self, ThreadState::Active)
    }

    /// Check if the thread is claimable by an agent
    pub fn is_claimable(&self) -> bool {
        matches!(self, ThreadState::Embryo | ThreadState::Active)
    }

    /// Get a human-readable description of the state
    pub fn description(&self) -> &'static str {
        match self {
            ThreadState::Embryo => "Newly created, awaiting activation",
            ThreadState::Active => "Actively being worked on",
            ThreadState::Blocked => "Blocked, waiting for input or resources",
            ThreadState::Review => "In review phase",
            ThreadState::Complete => "Successfully completed",
            ThreadState::Killed => "Terminated",
        }
    }
}

impl Default for ThreadState {
    fn default() -> Self {
        ThreadState::Embryo
    }
}

impl std::fmt::Display for ThreadState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ThreadState::Embryo => write!(f, "EMBRYO"),
            ThreadState::Active => write!(f, "ACTIVE"),
            ThreadState::Blocked => write!(f, "BLOCKED"),
            ThreadState::Review => write!(f, "REVIEW"),
            ThreadState::Complete => write!(f, "COMPLETE"),
            ThreadState::Killed => write!(f, "KILLED"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_embryo_transitions() {
        let state = ThreadState::Embryo;
        assert!(state.can_transition_to(&ThreadState::Active));
        assert!(!state.can_transition_to(&ThreadState::Blocked));
        assert!(!state.can_transition_to(&ThreadState::Review));
        assert!(!state.can_transition_to(&ThreadState::Complete));
        assert!(!state.can_transition_to(&ThreadState::Killed));
    }

    #[test]
    fn test_active_transitions() {
        let state = ThreadState::Active;
        assert!(!state.can_transition_to(&ThreadState::Embryo));
        assert!(state.can_transition_to(&ThreadState::Blocked));
        assert!(state.can_transition_to(&ThreadState::Review));
        assert!(!state.can_transition_to(&ThreadState::Complete));
        assert!(state.can_transition_to(&ThreadState::Killed));
    }

    #[test]
    fn test_blocked_transitions() {
        let state = ThreadState::Blocked;
        assert!(state.can_transition_to(&ThreadState::Active));
        assert!(state.can_transition_to(&ThreadState::Killed));
        assert!(!state.can_transition_to(&ThreadState::Review));
    }

    #[test]
    fn test_terminal_states() {
        assert!(ThreadState::Complete.is_terminal());
        assert!(ThreadState::Killed.is_terminal());
        assert!(!ThreadState::Active.is_terminal());
        assert!(!ThreadState::Embryo.is_terminal());
    }

    #[test]
    fn test_claimable_states() {
        assert!(ThreadState::Embryo.is_claimable());
        assert!(ThreadState::Active.is_claimable());
        assert!(!ThreadState::Blocked.is_claimable());
        assert!(!ThreadState::Complete.is_claimable());
    }
}
