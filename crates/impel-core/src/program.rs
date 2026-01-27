//! Program domain model
//!
//! A program is a collection of related projects, representing the highest
//! level of organization in the impel hierarchy:
//!
//! Program -> Projects -> Threads -> Events

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::project::{Project, ProjectId, ProjectStatus};

/// Unique identifier for a program
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProgramId {
    /// The underlying UUID value
    pub value: Uuid,
}

impl ProgramId {
    /// Create a new random program ID
    pub fn new() -> Self {
        Self {
            value: Uuid::new_v4(),
        }
    }

    /// Create a program ID from a UUID
    pub fn from_uuid(uuid: Uuid) -> Self {
        Self { value: uuid }
    }

    /// Parse a program ID from a string
    pub fn parse(s: &str) -> Result<Self, uuid::Error> {
        Ok(Self {
            value: Uuid::parse_str(s)?,
        })
    }
}

impl Default for ProgramId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for ProgramId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.value)
    }
}

/// Status of a program
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ProgramStatus {
    /// Program is in setup phase
    Setup,
    /// Program is actively running
    Active,
    /// Program is under review
    Review,
    /// Program has been completed
    Complete,
    /// Program is on hold
    OnHold,
    /// Program has been archived
    Archived,
}

impl ProgramStatus {
    /// Get a human-readable name
    pub fn name(&self) -> &'static str {
        match self {
            ProgramStatus::Setup => "Setup",
            ProgramStatus::Active => "Active",
            ProgramStatus::Review => "Review",
            ProgramStatus::Complete => "Complete",
            ProgramStatus::OnHold => "On Hold",
            ProgramStatus::Archived => "Archived",
        }
    }

    /// Check if the program is in a terminal state
    pub fn is_terminal(&self) -> bool {
        matches!(self, ProgramStatus::Complete | ProgramStatus::Archived)
    }
}

impl std::fmt::Display for ProgramStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

/// Summary statistics for a program
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProgramStats {
    /// Total number of projects
    pub project_count: usize,
    /// Projects in active state
    pub active_projects: usize,
    /// Projects in completed state
    pub completed_projects: usize,
    /// Total number of threads across all projects
    pub total_threads: usize,
    /// Number of open escalations
    pub open_escalations: usize,
    /// Number of pending submissions
    pub pending_submissions: usize,
    /// Overall progress (0.0-1.0)
    pub overall_progress: f64,
}

/// A research program (collection of projects)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Program {
    /// Unique identifier
    pub id: ProgramId,
    /// Program name
    pub name: String,
    /// Program description
    pub description: String,
    /// Current status
    pub status: ProgramStatus,
    /// Projects in this program
    pub projects: Vec<ProjectId>,
    /// Creation timestamp
    pub created_at: DateTime<Utc>,
    /// Last activity timestamp
    pub updated_at: DateTime<Utc>,
    /// Program goals
    pub goals: Vec<String>,
    /// Custom metadata
    pub metadata: std::collections::HashMap<String, String>,
}

impl Program {
    /// Create a new program
    pub fn new(name: String, description: String) -> Self {
        let now = Utc::now();
        Self {
            id: ProgramId::new(),
            name,
            description,
            status: ProgramStatus::Setup,
            projects: Vec::new(),
            created_at: now,
            updated_at: now,
            goals: Vec::new(),
            metadata: std::collections::HashMap::new(),
        }
    }

    /// Add a project to the program
    pub fn add_project(&mut self, project_id: ProjectId) {
        if !self.projects.contains(&project_id) {
            self.projects.push(project_id);
            self.updated_at = Utc::now();
        }
    }

    /// Remove a project from the program
    pub fn remove_project(&mut self, project_id: &ProjectId) {
        self.projects.retain(|p| p != project_id);
        self.updated_at = Utc::now();
    }

    /// Set program status
    pub fn set_status(&mut self, status: ProgramStatus) {
        self.status = status;
        self.updated_at = Utc::now();
    }

    /// Get project count
    pub fn project_count(&self) -> usize {
        self.projects.len()
    }

    /// Calculate statistics from a slice of projects
    pub fn calculate_stats(&self, projects: &[Project]) -> ProgramStats {
        let our_projects: Vec<_> = projects
            .iter()
            .filter(|p| self.projects.contains(&p.id))
            .collect();

        let active_projects = our_projects
            .iter()
            .filter(|p| p.status == ProjectStatus::Active)
            .count();

        let completed_projects = our_projects
            .iter()
            .filter(|p| p.status == ProjectStatus::Complete)
            .count();

        let total_threads: usize = our_projects.iter().map(|p| p.thread_count()).sum();

        let overall_progress = if our_projects.is_empty() {
            0.0
        } else {
            let total: f64 = our_projects.iter().map(|p| p.overall_progress()).sum();
            total / our_projects.len() as f64
        };

        ProgramStats {
            project_count: our_projects.len(),
            active_projects,
            completed_projects,
            total_threads,
            open_escalations: 0,    // Would be computed from escalation state
            pending_submissions: 0, // Would be computed from submission queue
            overall_progress,
        }
    }
}

impl Default for Program {
    fn default() -> Self {
        Self::new("Untitled Program".to_string(), String::new())
    }
}

/// Manager for programs and their projects
#[derive(Debug, Clone, Default)]
pub struct ProgramRegistry {
    /// All programs
    programs: Vec<Program>,
    /// All projects (may belong to programs or be standalone)
    projects: Vec<Project>,
}

impl ProgramRegistry {
    /// Create a new empty registry
    pub fn new() -> Self {
        Self {
            programs: Vec::new(),
            projects: Vec::new(),
        }
    }

    /// Add a program
    pub fn add_program(&mut self, program: Program) {
        self.programs.push(program);
    }

    /// Get a program by ID
    pub fn get_program(&self, id: &ProgramId) -> Option<&Program> {
        self.programs.iter().find(|p| &p.id == id)
    }

    /// Get a mutable reference to a program
    pub fn get_program_mut(&mut self, id: &ProgramId) -> Option<&mut Program> {
        self.programs.iter_mut().find(|p| &p.id == id)
    }

    /// Add a project
    pub fn add_project(&mut self, project: Project) {
        self.projects.push(project);
    }

    /// Get a project by ID
    pub fn get_project(&self, id: &ProjectId) -> Option<&Project> {
        self.projects.iter().find(|p| &p.id == id)
    }

    /// Get a mutable reference to a project
    pub fn get_project_mut(&mut self, id: &ProjectId) -> Option<&mut Project> {
        self.projects.iter_mut().find(|p| &p.id == id)
    }

    /// Get all programs
    pub fn programs(&self) -> &[Program] {
        &self.programs
    }

    /// Get all projects
    pub fn projects(&self) -> &[Project] {
        &self.projects
    }

    /// Get projects for a specific program
    pub fn projects_for_program(&self, program_id: &ProgramId) -> Vec<&Project> {
        if let Some(program) = self.get_program(program_id) {
            self.projects
                .iter()
                .filter(|p| program.projects.contains(&p.id))
                .collect()
        } else {
            Vec::new()
        }
    }

    /// Get orphan projects (not in any program)
    pub fn orphan_projects(&self) -> Vec<&Project> {
        let all_program_projects: std::collections::HashSet<_> =
            self.programs.iter().flat_map(|p| &p.projects).collect();

        self.projects
            .iter()
            .filter(|p| !all_program_projects.contains(&p.id))
            .collect()
    }

    /// Calculate stats for a program
    pub fn program_stats(&self, program_id: &ProgramId) -> Option<ProgramStats> {
        self.get_program(program_id)
            .map(|program| program.calculate_stats(&self.projects))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_program_creation() {
        let program = Program::new(
            "Research 2024".to_string(),
            "Annual research program".to_string(),
        );
        assert_eq!(program.name, "Research 2024");
        assert_eq!(program.status, ProgramStatus::Setup);
        assert!(program.projects.is_empty());
    }

    #[test]
    fn test_program_status() {
        assert!(ProgramStatus::Complete.is_terminal());
        assert!(ProgramStatus::Archived.is_terminal());
        assert!(!ProgramStatus::Active.is_terminal());
    }

    #[test]
    fn test_program_registry() {
        let mut registry = ProgramRegistry::new();

        let mut program = Program::new("Test Program".to_string(), "".to_string());
        let program_id = program.id;

        let project1 = Project::new("Project 1".to_string(), "".to_string());
        let project1_id = project1.id;
        let project2 = Project::new("Project 2".to_string(), "".to_string());

        program.add_project(project1_id);

        registry.add_program(program);
        registry.add_project(project1);
        registry.add_project(project2);

        assert_eq!(registry.programs().len(), 1);
        assert_eq!(registry.projects().len(), 2);

        let program_projects = registry.projects_for_program(&program_id);
        assert_eq!(program_projects.len(), 1);

        let orphans = registry.orphan_projects();
        assert_eq!(orphans.len(), 1);
    }

    #[test]
    fn test_program_stats() {
        let mut registry = ProgramRegistry::new();

        let mut program = Program::new("Test".to_string(), "".to_string());
        let program_id = program.id;

        let mut project1 = Project::new("P1".to_string(), "".to_string());
        project1.status = ProjectStatus::Active;
        let project1_id = project1.id;

        let mut project2 = Project::new("P2".to_string(), "".to_string());
        project2.status = ProjectStatus::Complete;
        let project2_id = project2.id;

        program.add_project(project1_id);
        program.add_project(project2_id);

        registry.add_program(program);
        registry.add_project(project1);
        registry.add_project(project2);

        let stats = registry.program_stats(&program_id).unwrap();
        assert_eq!(stats.project_count, 2);
        assert_eq!(stats.active_projects, 1);
        assert_eq!(stats.completed_projects, 1);
    }
}
