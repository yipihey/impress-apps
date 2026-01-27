//! Repository for CRUD operations on impel entities

use std::path::Path;

use super::schema::{Schema, SCHEMA_VERSION};
use crate::agent::Agent;
use crate::error::{PersistenceError, Result};
use crate::escalation::Escalation;
use crate::event::Event;
use crate::message::MessageEnvelope;
use crate::thread::Thread;

/// Repository for persisting impel state
#[cfg(feature = "sqlite")]
pub struct Repository {
    conn: rusqlite::Connection,
}

#[cfg(feature = "sqlite")]
impl Repository {
    /// Create a new repository with the given database path
    pub fn new(path: impl AsRef<Path>) -> Result<Self> {
        let conn = rusqlite::Connection::open(path)?;
        let repo = Self { conn };
        repo.initialize()?;
        Ok(repo)
    }

    /// Create an in-memory repository (for testing)
    pub fn in_memory() -> Result<Self> {
        let conn = rusqlite::Connection::open_in_memory()?;
        let repo = Self { conn };
        repo.initialize()?;
        Ok(repo)
    }

    /// Initialize the database schema
    fn initialize(&self) -> Result<()> {
        // Check current schema version
        let current_version = self.get_schema_version().unwrap_or(0);

        if current_version == 0 {
            // Fresh database, create all tables
            self.conn.execute_batch(Schema::create_tables())?;
            self.set_schema_version(SCHEMA_VERSION)?;
        } else if current_version < SCHEMA_VERSION {
            // Run migrations
            for version in current_version..SCHEMA_VERSION {
                if let Some(migration) = Schema::migration(version, version + 1) {
                    self.conn.execute_batch(migration)?;
                }
            }
            self.set_schema_version(SCHEMA_VERSION)?;
        }

        Ok(())
    }

    fn get_schema_version(&self) -> Option<u32> {
        self.conn
            .query_row(
                "SELECT version FROM schema_version ORDER BY applied_at DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .ok()
    }

    fn set_schema_version(&self, version: u32) -> Result<()> {
        self.conn.execute(
            "INSERT INTO schema_version (version) VALUES (?1)",
            [version],
        )?;
        Ok(())
    }

    // ==================== Thread Operations ====================

    /// Save a thread to the database
    pub fn save_thread(&self, thread: &Thread) -> Result<()> {
        let metadata_json = serde_json::to_string(&thread.metadata)?;

        self.conn.execute(
            r#"
            INSERT OR REPLACE INTO threads
            (id, state, title, description, temperature, claimed_by, parent_id, created_at, updated_at, version, metadata)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            rusqlite::params![
                thread.id.to_string(),
                thread.state.to_string(),
                thread.metadata.title,
                thread.metadata.description,
                thread.temperature.value(),
                thread.claimed_by,
                thread.metadata.parent_id.map(|id| id.to_string()),
                thread.created_at.to_rfc3339(),
                thread.updated_at.to_rfc3339(),
                thread.version,
                metadata_json,
            ],
        )?;

        Ok(())
    }

    /// Get a thread by ID
    pub fn get_thread(&self, id: &str) -> Result<Option<Thread>> {
        let result = self.conn.query_row(
            "SELECT id, state, title, description, temperature, claimed_by, parent_id, created_at, updated_at, version, metadata FROM threads WHERE id = ?1",
            [id],
            Self::row_to_thread,
        );

        match result {
            Ok(thread) => Ok(Some(thread)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(PersistenceError::from(e).into()),
        }
    }

    /// Get all threads
    pub fn get_all_threads(&self) -> Result<Vec<Thread>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, state, title, description, temperature, claimed_by, parent_id, created_at, updated_at, version, metadata FROM threads ORDER BY temperature DESC",
        )?;

        let threads = stmt
            .query_map([], Self::row_to_thread)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(threads)
    }

    /// Get threads by state
    pub fn get_threads_by_state(&self, state: &str) -> Result<Vec<Thread>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, state, title, description, temperature, claimed_by, parent_id, created_at, updated_at, version, metadata FROM threads WHERE state = ?1 ORDER BY temperature DESC",
        )?;

        let threads = stmt
            .query_map([state], Self::row_to_thread)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(threads)
    }

    fn row_to_thread(row: &rusqlite::Row) -> rusqlite::Result<Thread> {
        use crate::thread::{Temperature, ThreadId, ThreadMetadata, ThreadState};
        use chrono::DateTime;
        use uuid::Uuid;

        let id_str: String = row.get(0)?;
        let state_str: String = row.get(1)?;
        let title: String = row.get(2)?;
        let description: Option<String> = row.get(3)?;
        let temperature_val: f64 = row.get(4)?;
        let claimed_by: Option<String> = row.get(5)?;
        let parent_id_str: Option<String> = row.get(6)?;
        let created_at_str: String = row.get(7)?;
        let updated_at_str: String = row.get(8)?;
        let version: u64 = row.get(9)?;

        let state = match state_str.as_str() {
            "EMBRYO" => ThreadState::Embryo,
            "ACTIVE" => ThreadState::Active,
            "BLOCKED" => ThreadState::Blocked,
            "REVIEW" => ThreadState::Review,
            "COMPLETE" => ThreadState::Complete,
            "KILLED" => ThreadState::Killed,
            _ => ThreadState::Embryo,
        };

        let metadata = ThreadMetadata {
            title,
            description: description.unwrap_or_default(),
            parent_id: parent_id_str
                .and_then(|s| Uuid::parse_str(&s).ok())
                .map(|uuid| ThreadId { value: uuid }),
            ..Default::default()
        };

        Ok(Thread {
            id: ThreadId {
                value: Uuid::parse_str(&id_str).unwrap(),
            },
            state,
            temperature: Temperature::new(temperature_val),
            metadata,
            claimed_by,
            artifact_ids: Vec::new(),
            created_at: DateTime::parse_from_rfc3339(&created_at_str)
                .unwrap()
                .with_timezone(&chrono::Utc),
            updated_at: DateTime::parse_from_rfc3339(&updated_at_str)
                .unwrap()
                .with_timezone(&chrono::Utc),
            version,
        })
    }

    // ==================== Agent Operations ====================

    /// Save an agent to the database
    pub fn save_agent(&self, agent: &Agent) -> Result<()> {
        let metadata_json = serde_json::to_string(&agent.metadata)?;

        self.conn.execute(
            r#"
            INSERT OR REPLACE INTO agents
            (id, agent_type, status, current_thread, auth_token, registered_at, last_active_at, threads_completed, metadata)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            rusqlite::params![
                agent.id,
                agent.agent_type.name(),
                agent.status.to_string(),
                agent.current_thread.map(|t| t.to_string()),
                agent.auth_token,
                agent.registered_at.to_rfc3339(),
                agent.last_active_at.to_rfc3339(),
                agent.threads_completed,
                metadata_json,
            ],
        )?;

        Ok(())
    }

    /// Get an agent by ID
    pub fn get_agent(&self, id: &str) -> Result<Option<Agent>> {
        let result = self.conn.query_row(
            "SELECT id, agent_type, status, current_thread, auth_token, registered_at, last_active_at, threads_completed, metadata FROM agents WHERE id = ?1",
            [id],
            Self::row_to_agent,
        );

        match result {
            Ok(agent) => Ok(Some(agent)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(PersistenceError::from(e).into()),
        }
    }

    /// Get all agents
    pub fn get_all_agents(&self) -> Result<Vec<Agent>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, agent_type, status, current_thread, auth_token, registered_at, last_active_at, threads_completed, metadata FROM agents",
        )?;

        let agents = stmt
            .query_map([], Self::row_to_agent)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(agents)
    }

    fn row_to_agent(row: &rusqlite::Row) -> rusqlite::Result<Agent> {
        use crate::agent::{AgentStatus, AgentType};
        use crate::thread::ThreadId;
        use chrono::DateTime;
        use uuid::Uuid;

        let id: String = row.get(0)?;
        let agent_type_str: String = row.get(1)?;
        let status_str: String = row.get(2)?;
        let current_thread_str: Option<String> = row.get(3)?;
        let auth_token: Option<String> = row.get(4)?;
        let registered_at_str: String = row.get(5)?;
        let last_active_at_str: String = row.get(6)?;
        let threads_completed: u64 = row.get(7)?;
        let metadata_json: Option<String> = row.get(8)?;

        let agent_type = match agent_type_str.as_str() {
            "Research" => AgentType::Research,
            "Code" => AgentType::Code,
            "Verification" => AgentType::Verification,
            "Adversarial" => AgentType::Adversarial,
            "Review" => AgentType::Review,
            "Librarian" => AgentType::Librarian,
            _ => AgentType::Research,
        };

        let status = match status_str.as_str() {
            "IDLE" => AgentStatus::Idle,
            "WORKING" => AgentStatus::Working,
            "PAUSED" => AgentStatus::Paused,
            "TERMINATED" => AgentStatus::Terminated,
            _ => AgentStatus::Idle,
        };

        let metadata = metadata_json
            .and_then(|j| serde_json::from_str(&j).ok())
            .unwrap_or_default();

        Ok(Agent {
            id,
            agent_type,
            status,
            current_thread: current_thread_str
                .and_then(|s| Uuid::parse_str(&s).ok())
                .map(|uuid| ThreadId { value: uuid }),
            auth_token,
            registered_at: DateTime::parse_from_rfc3339(&registered_at_str)
                .unwrap()
                .with_timezone(&chrono::Utc),
            last_active_at: DateTime::parse_from_rfc3339(&last_active_at_str)
                .unwrap()
                .with_timezone(&chrono::Utc),
            threads_completed,
            metadata,
        })
    }

    // ==================== Escalation Operations ====================

    /// Save an escalation to the database
    pub fn save_escalation(&self, escalation: &Escalation) -> Result<()> {
        let options_json = serde_json::to_string(&escalation.options)?;

        self.conn.execute(
            r#"
            INSERT OR REPLACE INTO escalations
            (id, category, priority, status, title, description, thread_id, created_by, created_at,
             acknowledged_at, acknowledged_by, resolved_at, resolved_by, resolution, options, selected_option)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            "#,
            rusqlite::params![
                escalation.id,
                escalation.category.name(),
                escalation.priority as i32,
                escalation.status.to_string(),
                escalation.title,
                escalation.description,
                escalation.thread_id.map(|t| t.to_string()),
                escalation.created_by,
                escalation.created_at.to_rfc3339(),
                escalation.acknowledged_at.map(|t| t.to_rfc3339()),
                escalation.acknowledged_by,
                escalation.resolved_at.map(|t| t.to_rfc3339()),
                escalation.resolved_by,
                escalation.resolution,
                options_json,
                escalation.selected_option.map(|i| i as i32),
            ],
        )?;

        Ok(())
    }

    /// Get open escalations sorted by priority
    pub fn get_open_escalations(&self) -> Result<Vec<Escalation>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, category, priority, status, title, description, thread_id, created_by, created_at,
                   acknowledged_at, acknowledged_by, resolved_at, resolved_by, resolution, options, selected_option
            FROM escalations
            WHERE status IN ('PENDING', 'ACKNOWLEDGED')
            ORDER BY priority DESC, created_at ASC
            "#,
        )?;

        let escalations = stmt
            .query_map([], Self::row_to_escalation)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(escalations)
    }

    fn row_to_escalation(row: &rusqlite::Row) -> rusqlite::Result<Escalation> {
        use crate::escalation::{
            EscalationCategory, EscalationOption, EscalationPriority, EscalationStatus,
        };
        use crate::thread::ThreadId;
        use chrono::DateTime;
        use uuid::Uuid;

        let id: String = row.get(0)?;
        let category_str: String = row.get(1)?;
        let priority_int: i32 = row.get(2)?;
        let status_str: String = row.get(3)?;
        let title: String = row.get(4)?;
        let description: String = row.get(5)?;
        let thread_id_str: Option<String> = row.get(6)?;
        let created_by: String = row.get(7)?;
        let created_at_str: String = row.get(8)?;
        let acknowledged_at_str: Option<String> = row.get(9)?;
        let acknowledged_by: Option<String> = row.get(10)?;
        let resolved_at_str: Option<String> = row.get(11)?;
        let resolved_by: Option<String> = row.get(12)?;
        let resolution: Option<String> = row.get(13)?;
        let options_json: String = row.get(14)?;
        let selected_option: Option<i32> = row.get(15)?;

        let category = match category_str.as_str() {
            "Decision" => EscalationCategory::Decision,
            "Novelty" => EscalationCategory::Novelty,
            "Stuck" => EscalationCategory::Stuck,
            "Scope" => EscalationCategory::Scope,
            "Quality" => EscalationCategory::Quality,
            "Checkpoint" => EscalationCategory::Checkpoint,
            _ => EscalationCategory::Stuck,
        };

        let priority = match priority_int {
            0 => EscalationPriority::Low,
            1 => EscalationPriority::Medium,
            2 => EscalationPriority::High,
            3 => EscalationPriority::Critical,
            _ => EscalationPriority::Medium,
        };

        let status = match status_str.as_str() {
            "PENDING" => EscalationStatus::Pending,
            "ACKNOWLEDGED" => EscalationStatus::Acknowledged,
            "RESOLVED" => EscalationStatus::Resolved,
            "DISMISSED" => EscalationStatus::Dismissed,
            _ => EscalationStatus::Pending,
        };

        let options: Vec<EscalationOption> =
            serde_json::from_str(&options_json).unwrap_or_default();

        Ok(Escalation {
            id,
            category,
            priority,
            status,
            title,
            description,
            thread_id: thread_id_str
                .and_then(|s| Uuid::parse_str(&s).ok())
                .map(|uuid| ThreadId { value: uuid }),
            created_by,
            created_at: DateTime::parse_from_rfc3339(&created_at_str)
                .unwrap()
                .with_timezone(&chrono::Utc),
            acknowledged_at: acknowledged_at_str.and_then(|s| {
                DateTime::parse_from_rfc3339(&s)
                    .ok()
                    .map(|dt| dt.with_timezone(&chrono::Utc))
            }),
            acknowledged_by,
            resolved_at: resolved_at_str.and_then(|s| {
                DateTime::parse_from_rfc3339(&s)
                    .ok()
                    .map(|dt| dt.with_timezone(&chrono::Utc))
            }),
            resolved_by,
            resolution,
            options,
            selected_option: selected_option.map(|i| i as usize),
        })
    }

    // ==================== System State Operations ====================

    /// Set a system state value
    pub fn set_system_state(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO system_state (key, value, updated_at) VALUES (?1, ?2, datetime('now'))",
            [key, value],
        )?;
        Ok(())
    }

    /// Get a system state value
    pub fn get_system_state(&self, key: &str) -> Result<Option<String>> {
        let result = self.conn.query_row(
            "SELECT value FROM system_state WHERE key = ?1",
            [key],
            |row| row.get(0),
        );

        match result {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(PersistenceError::from(e).into()),
        }
    }
}

// Stub implementation when sqlite feature is not enabled
#[cfg(not(feature = "sqlite"))]
pub struct Repository;

#[cfg(not(feature = "sqlite"))]
impl Repository {
    pub fn new(_path: impl AsRef<std::path::Path>) -> Result<Self> {
        Err(crate::error::ImpelError::InvalidOperation(
            "SQLite support not enabled. Enable the 'sqlite' feature.".to_string(),
        ))
    }

    pub fn in_memory() -> Result<Self> {
        Err(crate::error::ImpelError::InvalidOperation(
            "SQLite support not enabled. Enable the 'sqlite' feature.".to_string(),
        ))
    }
}

#[cfg(all(test, feature = "sqlite"))]
mod tests {
    use super::*;
    use crate::thread::{ThreadMetadata, ThreadState};

    #[test]
    fn test_repository_creation() {
        let repo = Repository::in_memory().unwrap();
        assert!(repo.get_all_threads().unwrap().is_empty());
    }

    #[test]
    fn test_thread_crud() {
        let repo = Repository::in_memory().unwrap();

        let metadata = ThreadMetadata {
            title: "Test Thread".to_string(),
            description: "A test".to_string(),
            ..Default::default()
        };
        let thread = Thread::new(metadata);
        let id = thread.id.to_string();

        // Save
        repo.save_thread(&thread).unwrap();

        // Get
        let loaded = repo.get_thread(&id).unwrap().unwrap();
        assert_eq!(loaded.metadata.title, "Test Thread");
        assert_eq!(loaded.state, ThreadState::Embryo);

        // Get all
        let all = repo.get_all_threads().unwrap();
        assert_eq!(all.len(), 1);
    }

    #[test]
    fn test_agent_crud() {
        use crate::agent::{Agent, AgentType};

        let repo = Repository::in_memory().unwrap();

        let agent = Agent::new("test-1".to_string(), AgentType::Research);

        // Save
        repo.save_agent(&agent).unwrap();

        // Get
        let loaded = repo.get_agent("test-1").unwrap().unwrap();
        assert_eq!(loaded.id, "test-1");
        assert_eq!(loaded.agent_type, AgentType::Research);

        // Get all
        let all = repo.get_all_agents().unwrap();
        assert_eq!(all.len(), 1);
    }

    #[test]
    fn test_system_state() {
        let repo = Repository::in_memory().unwrap();

        repo.set_system_state("paused", "true").unwrap();
        let value = repo.get_system_state("paused").unwrap();
        assert_eq!(value, Some("true".to_string()));

        let missing = repo.get_system_state("nonexistent").unwrap();
        assert!(missing.is_none());
    }
}
