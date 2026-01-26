//! Escalation categories and types

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::thread::ThreadId;

/// Category of escalation
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EscalationCategory {
    /// Decision required - multiple valid paths, human must choose
    Decision,
    /// Novelty detected - unprecedented situation requiring human judgment
    Novelty,
    /// Stuck - unable to make progress, need guidance
    Stuck,
    /// Scope - potential scope creep or boundary issues
    Scope,
    /// Quality - quality concerns requiring human review
    Quality,
    /// Checkpoint - regular progress checkpoint for human review
    Checkpoint,
}

impl EscalationCategory {
    /// Get a human-readable name for the category
    pub fn name(&self) -> &'static str {
        match self {
            EscalationCategory::Decision => "Decision",
            EscalationCategory::Novelty => "Novelty",
            EscalationCategory::Stuck => "Stuck",
            EscalationCategory::Scope => "Scope",
            EscalationCategory::Quality => "Quality",
            EscalationCategory::Checkpoint => "Checkpoint",
        }
    }

    /// Get a description of when this category should be used
    pub fn description(&self) -> &'static str {
        match self {
            EscalationCategory::Decision => {
                "Multiple valid paths exist, human must choose the direction"
            }
            EscalationCategory::Novelty => {
                "Unprecedented situation requiring human judgment and guidance"
            }
            EscalationCategory::Stuck => {
                "Unable to make progress, need human input or resources"
            }
            EscalationCategory::Scope => {
                "Potential scope creep or boundary issues detected"
            }
            EscalationCategory::Quality => {
                "Quality concerns that require human review and approval"
            }
            EscalationCategory::Checkpoint => {
                "Regular progress checkpoint for human review"
            }
        }
    }

    /// Get the default priority for this category
    pub fn default_priority(&self) -> EscalationPriority {
        match self {
            EscalationCategory::Decision => EscalationPriority::Medium,
            EscalationCategory::Novelty => EscalationPriority::High,
            EscalationCategory::Stuck => EscalationPriority::High,
            EscalationCategory::Scope => EscalationPriority::Medium,
            EscalationCategory::Quality => EscalationPriority::Medium,
            EscalationCategory::Checkpoint => EscalationPriority::Low,
        }
    }
}

impl std::fmt::Display for EscalationCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

/// Priority level for escalations
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EscalationPriority {
    /// Low priority - can wait for next review session
    Low = 0,
    /// Medium priority - should be addressed within a day
    Medium = 1,
    /// High priority - requires prompt attention
    High = 2,
    /// Critical - blocking progress, immediate attention needed
    Critical = 3,
}

impl EscalationPriority {
    /// Get a human-readable name
    pub fn name(&self) -> &'static str {
        match self {
            EscalationPriority::Low => "Low",
            EscalationPriority::Medium => "Medium",
            EscalationPriority::High => "High",
            EscalationPriority::Critical => "Critical",
        }
    }

    /// Get expected response time
    pub fn expected_response_time(&self) -> &'static str {
        match self {
            EscalationPriority::Low => "Next review session",
            EscalationPriority::Medium => "Within 24 hours",
            EscalationPriority::High => "Within a few hours",
            EscalationPriority::Critical => "Immediate",
        }
    }
}

impl std::fmt::Display for EscalationPriority {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

/// Status of an escalation
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EscalationStatus {
    /// Newly created, awaiting acknowledgment
    Pending,
    /// Acknowledged but not yet resolved
    Acknowledged,
    /// Resolved by human
    Resolved,
    /// Dismissed without action (e.g., superseded)
    Dismissed,
}

impl EscalationStatus {
    /// Check if the escalation is still open
    pub fn is_open(&self) -> bool {
        matches!(self, EscalationStatus::Pending | EscalationStatus::Acknowledged)
    }

    /// Check if the escalation has been handled
    pub fn is_handled(&self) -> bool {
        matches!(self, EscalationStatus::Resolved | EscalationStatus::Dismissed)
    }
}

impl std::fmt::Display for EscalationStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EscalationStatus::Pending => write!(f, "PENDING"),
            EscalationStatus::Acknowledged => write!(f, "ACKNOWLEDGED"),
            EscalationStatus::Resolved => write!(f, "RESOLVED"),
            EscalationStatus::Dismissed => write!(f, "DISMISSED"),
        }
    }
}

/// An escalation request for human attention
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Escalation {
    /// Unique identifier
    pub id: String,
    /// Category of escalation
    pub category: EscalationCategory,
    /// Priority level
    pub priority: EscalationPriority,
    /// Current status
    pub status: EscalationStatus,
    /// Title/summary
    pub title: String,
    /// Detailed description
    pub description: String,
    /// Related thread ID (if any)
    pub thread_id: Option<ThreadId>,
    /// Agent that created the escalation
    pub created_by: String,
    /// Creation timestamp
    pub created_at: DateTime<Utc>,
    /// Acknowledgment timestamp (if acknowledged)
    pub acknowledged_at: Option<DateTime<Utc>>,
    /// Acknowledger ID
    pub acknowledged_by: Option<String>,
    /// Resolution timestamp (if resolved)
    pub resolved_at: Option<DateTime<Utc>>,
    /// Resolver ID
    pub resolved_by: Option<String>,
    /// Resolution details
    pub resolution: Option<String>,
    /// Options presented to the human (for Decision category)
    pub options: Vec<EscalationOption>,
    /// Selected option index (if applicable)
    pub selected_option: Option<usize>,
}

impl Escalation {
    /// Create a new escalation
    pub fn new(
        category: EscalationCategory,
        title: String,
        description: String,
        created_by: String,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            category,
            priority: category.default_priority(),
            status: EscalationStatus::Pending,
            title,
            description,
            thread_id: None,
            created_by,
            created_at: Utc::now(),
            acknowledged_at: None,
            acknowledged_by: None,
            resolved_at: None,
            resolved_by: None,
            resolution: None,
            options: Vec::new(),
            selected_option: None,
        }
    }

    /// Create a decision escalation with options
    pub fn decision(
        title: String,
        description: String,
        created_by: String,
        options: Vec<EscalationOption>,
    ) -> Self {
        let mut escalation = Self::new(EscalationCategory::Decision, title, description, created_by);
        escalation.options = options;
        escalation
    }

    /// Set the related thread
    pub fn with_thread(mut self, thread_id: ThreadId) -> Self {
        self.thread_id = Some(thread_id);
        self
    }

    /// Set the priority
    pub fn with_priority(mut self, priority: EscalationPriority) -> Self {
        self.priority = priority;
        self
    }

    /// Acknowledge the escalation
    pub fn acknowledge(&mut self, by: String) {
        if self.status == EscalationStatus::Pending {
            self.status = EscalationStatus::Acknowledged;
            self.acknowledged_at = Some(Utc::now());
            self.acknowledged_by = Some(by);
        }
    }

    /// Resolve the escalation
    pub fn resolve(&mut self, by: String, resolution: String) {
        if self.status.is_open() {
            self.status = EscalationStatus::Resolved;
            self.resolved_at = Some(Utc::now());
            self.resolved_by = Some(by);
            self.resolution = Some(resolution);
        }
    }

    /// Resolve with a selected option (for Decision escalations)
    pub fn resolve_with_option(&mut self, by: String, option_index: usize) {
        if self.status.is_open() && option_index < self.options.len() {
            let resolution = self.options[option_index].label.clone();
            self.selected_option = Some(option_index);
            self.resolve(by, resolution);
        }
    }

    /// Dismiss the escalation
    pub fn dismiss(&mut self, by: String, reason: String) {
        if self.status.is_open() {
            self.status = EscalationStatus::Dismissed;
            self.resolved_at = Some(Utc::now());
            self.resolved_by = Some(by);
            self.resolution = Some(format!("Dismissed: {}", reason));
        }
    }

    /// Get the time since creation
    pub fn age(&self) -> chrono::Duration {
        Utc::now() - self.created_at
    }

    /// Get the time since acknowledgment (if acknowledged)
    pub fn time_since_ack(&self) -> Option<chrono::Duration> {
        self.acknowledged_at.map(|ack| Utc::now() - ack)
    }
}

/// An option for a Decision escalation
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EscalationOption {
    /// Label for the option
    pub label: String,
    /// Description of what this option means
    pub description: String,
    /// Estimated impact or consequences
    pub impact: Option<String>,
}

impl EscalationOption {
    /// Create a new option
    pub fn new(label: String, description: String) -> Self {
        Self {
            label,
            description,
            impact: None,
        }
    }

    /// Set the impact description
    pub fn with_impact(mut self, impact: String) -> Self {
        self.impact = Some(impact);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_escalation_creation() {
        let escalation = Escalation::new(
            EscalationCategory::Stuck,
            "Cannot find data".to_string(),
            "The expected data source is unavailable".to_string(),
            "research-1".to_string(),
        );

        assert_eq!(escalation.category, EscalationCategory::Stuck);
        assert_eq!(escalation.status, EscalationStatus::Pending);
        assert_eq!(escalation.priority, EscalationPriority::High);
    }

    #[test]
    fn test_escalation_lifecycle() {
        let mut escalation = Escalation::new(
            EscalationCategory::Decision,
            "Choose approach".to_string(),
            "Two approaches are viable".to_string(),
            "code-1".to_string(),
        );

        assert!(escalation.status.is_open());

        escalation.acknowledge("human-1".to_string());
        assert_eq!(escalation.status, EscalationStatus::Acknowledged);
        assert!(escalation.acknowledged_by.is_some());

        escalation.resolve("human-1".to_string(), "Use approach A".to_string());
        assert_eq!(escalation.status, EscalationStatus::Resolved);
        assert!(!escalation.status.is_open());
    }

    #[test]
    fn test_decision_options() {
        let options = vec![
            EscalationOption::new("Approach A".to_string(), "Use machine learning".to_string()),
            EscalationOption::new("Approach B".to_string(), "Use heuristics".to_string()),
        ];

        let mut escalation = Escalation::decision(
            "Algorithm choice".to_string(),
            "Which approach should we use?".to_string(),
            "research-1".to_string(),
            options,
        );

        assert_eq!(escalation.options.len(), 2);

        escalation.resolve_with_option("human-1".to_string(), 0);
        assert_eq!(escalation.selected_option, Some(0));
        assert_eq!(escalation.resolution, Some("Approach A".to_string()));
    }
}
