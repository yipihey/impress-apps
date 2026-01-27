//! Project domain model
//!
//! A project is a collection of related threads working toward shared deliverables.
//! Projects have status, team assignments, and relationships with other projects.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::thread::ThreadId;

/// Unique identifier for a project
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProjectId {
    /// The underlying UUID value
    pub value: Uuid,
}

impl ProjectId {
    /// Create a new random project ID
    pub fn new() -> Self {
        Self {
            value: Uuid::new_v4(),
        }
    }

    /// Create a project ID from a UUID
    pub fn from_uuid(uuid: Uuid) -> Self {
        Self { value: uuid }
    }

    /// Parse a project ID from a string
    pub fn parse(s: &str) -> Result<Self, uuid::Error> {
        Ok(Self {
            value: Uuid::parse_str(s)?,
        })
    }
}

impl Default for ProjectId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for ProjectId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.value)
    }
}

/// Status of a project
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ProjectStatus {
    /// Project is in planning phase
    Planning,
    /// Project is actively being worked on
    Active,
    /// Project is under review
    Review,
    /// Project has been completed
    Complete,
    /// Project is temporarily paused
    Paused,
    /// Project has been cancelled
    Cancelled,
}

impl ProjectStatus {
    /// Get a human-readable name
    pub fn name(&self) -> &'static str {
        match self {
            ProjectStatus::Planning => "Planning",
            ProjectStatus::Active => "Active",
            ProjectStatus::Review => "Review",
            ProjectStatus::Complete => "Complete",
            ProjectStatus::Paused => "Paused",
            ProjectStatus::Cancelled => "Cancelled",
        }
    }

    /// Check if the project is in a terminal state
    pub fn is_terminal(&self) -> bool {
        matches!(self, ProjectStatus::Complete | ProjectStatus::Cancelled)
    }

    /// Check if work can be done on this project
    pub fn allows_work(&self) -> bool {
        matches!(self, ProjectStatus::Planning | ProjectStatus::Active)
    }
}

impl std::fmt::Display for ProjectStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

/// Relationship between projects
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProjectRelation {
    /// This project follows on from a predecessor
    FollowOn {
        predecessor: ProjectId,
        inherits: Vec<Inheritance>,
    },
    /// This project synthesizes results from multiple source projects
    Synthesis { sources: Vec<ProjectId> },
    /// Projects share scope and may exchange work
    Sibling { shared_scope: String },
    /// This project depends on artifacts from another
    Dependency { provides: Vec<String> },
}

/// What a follow-on project inherits from its predecessor
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum Inheritance {
    /// Inherit codebase
    Codebase,
    /// Inherit literature/references
    Literature,
    /// Inherit methods/approach
    Methods,
    /// Inherit team configuration
    Team,
}

/// A deliverable produced by a project
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Deliverable {
    /// Unique identifier
    pub id: String,
    /// Deliverable name
    pub name: String,
    /// Type of deliverable
    pub kind: DeliverableKind,
    /// Current progress (0.0-1.0)
    pub progress: f64,
    /// Associated thread IDs
    pub threads: Vec<ThreadId>,
    /// Path to artifact (if exists)
    pub artifact_path: Option<String>,
}

impl Deliverable {
    /// Create a new deliverable
    pub fn new(name: String, kind: DeliverableKind) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name,
            kind,
            progress: 0.0,
            threads: Vec::new(),
            artifact_path: None,
        }
    }

    /// Update progress
    pub fn set_progress(&mut self, progress: f64) {
        self.progress = progress.clamp(0.0, 1.0);
    }

    /// Check if deliverable is complete
    pub fn is_complete(&self) -> bool {
        (self.progress - 1.0).abs() < f64::EPSILON
    }
}

/// Type of deliverable
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum DeliverableKind {
    /// Research paper
    ResearchPaper {
        /// Target page count
        page_target: Option<u32>,
    },
    /// Code repository
    CodeRepository {
        /// Primary language
        language: String,
        /// Required test coverage (0.0-1.0)
        test_coverage: Option<f64>,
    },
    /// Dataset
    Dataset {
        /// Data format
        format: String,
    },
    /// Review article
    ReviewArticle {
        /// Number of input papers to synthesize
        input_papers: u32,
    },
    /// Other deliverable type
    Other {
        /// Description
        description: String,
    },
}

/// A research project
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    /// Unique identifier
    pub id: ProjectId,
    /// Program this project belongs to (if any)
    pub program_id: Option<super::program::ProgramId>,
    /// Project name
    pub name: String,
    /// Project description
    pub description: String,
    /// Current status
    pub status: ProjectStatus,
    /// Threads in this project
    pub threads: Vec<ThreadId>,
    /// Project deliverables
    pub deliverables: Vec<Deliverable>,
    /// Relationships with other projects
    pub relations: Vec<(ProjectId, ProjectRelation)>,
    /// Creation timestamp
    pub created_at: DateTime<Utc>,
    /// Last activity timestamp
    pub updated_at: DateTime<Utc>,
    /// Project goals
    pub goals: Vec<String>,
    /// Custom metadata
    pub metadata: std::collections::HashMap<String, String>,
}

impl Project {
    /// Create a new project
    pub fn new(name: String, description: String) -> Self {
        let now = Utc::now();
        Self {
            id: ProjectId::new(),
            program_id: None,
            name,
            description,
            status: ProjectStatus::Planning,
            threads: Vec::new(),
            deliverables: Vec::new(),
            relations: Vec::new(),
            created_at: now,
            updated_at: now,
            goals: Vec::new(),
            metadata: std::collections::HashMap::new(),
        }
    }

    /// Add a thread to the project
    pub fn add_thread(&mut self, thread_id: ThreadId) {
        if !self.threads.contains(&thread_id) {
            self.threads.push(thread_id);
            self.updated_at = Utc::now();
        }
    }

    /// Remove a thread from the project
    pub fn remove_thread(&mut self, thread_id: &ThreadId) {
        self.threads.retain(|t| t != thread_id);
        self.updated_at = Utc::now();
    }

    /// Add a deliverable
    pub fn add_deliverable(&mut self, deliverable: Deliverable) {
        self.deliverables.push(deliverable);
        self.updated_at = Utc::now();
    }

    /// Add a relationship to another project
    pub fn add_relation(&mut self, project_id: ProjectId, relation: ProjectRelation) {
        self.relations.push((project_id, relation));
        self.updated_at = Utc::now();
    }

    /// Transition to a new status
    pub fn set_status(&mut self, status: ProjectStatus) {
        self.status = status;
        self.updated_at = Utc::now();
    }

    /// Calculate overall project progress based on deliverables
    pub fn overall_progress(&self) -> f64 {
        if self.deliverables.is_empty() {
            return 0.0;
        }
        let total: f64 = self.deliverables.iter().map(|d| d.progress).sum();
        total / self.deliverables.len() as f64
    }

    /// Get thread count
    pub fn thread_count(&self) -> usize {
        self.threads.len()
    }

    /// Get deliverable count
    pub fn deliverable_count(&self) -> usize {
        self.deliverables.len()
    }

    /// Check if all deliverables are complete
    pub fn all_deliverables_complete(&self) -> bool {
        !self.deliverables.is_empty() && self.deliverables.iter().all(|d| d.is_complete())
    }
}

impl Default for Project {
    fn default() -> Self {
        Self::new("Untitled Project".to_string(), String::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_project_creation() {
        let project = Project::new("Test Project".to_string(), "A test project".to_string());
        assert_eq!(project.name, "Test Project");
        assert_eq!(project.status, ProjectStatus::Planning);
        assert!(project.threads.is_empty());
    }

    #[test]
    fn test_project_status() {
        assert!(ProjectStatus::Complete.is_terminal());
        assert!(ProjectStatus::Cancelled.is_terminal());
        assert!(!ProjectStatus::Active.is_terminal());

        assert!(ProjectStatus::Active.allows_work());
        assert!(!ProjectStatus::Paused.allows_work());
    }

    #[test]
    fn test_deliverable_progress() {
        let mut deliverable = Deliverable::new(
            "Paper".to_string(),
            DeliverableKind::ResearchPaper {
                page_target: Some(15),
            },
        );

        assert!(!deliverable.is_complete());
        deliverable.set_progress(1.0);
        assert!(deliverable.is_complete());
    }

    #[test]
    fn test_project_progress() {
        let mut project = Project::new("Test".to_string(), "Test".to_string());

        assert_eq!(project.overall_progress(), 0.0);

        let mut d1 = Deliverable::new(
            "Paper".to_string(),
            DeliverableKind::ResearchPaper { page_target: None },
        );
        d1.set_progress(0.5);

        let mut d2 = Deliverable::new(
            "Code".to_string(),
            DeliverableKind::CodeRepository {
                language: "Rust".to_string(),
                test_coverage: Some(0.8),
            },
        );
        d2.set_progress(1.0);

        project.add_deliverable(d1);
        project.add_deliverable(d2);

        assert!((project.overall_progress() - 0.75).abs() < f64::EPSILON);
    }
}
