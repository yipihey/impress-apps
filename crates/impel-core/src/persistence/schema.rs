//! SQLite schema for impel state storage

/// Schema version for migrations
pub const SCHEMA_VERSION: u32 = 1;

/// SQLite schema definition
pub struct Schema;

impl Schema {
    /// Get the complete schema SQL
    pub fn create_tables() -> &'static str {
        r#"
-- Schema version tracking
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Events table (append-only event log)
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    sequence INTEGER NOT NULL UNIQUE,
    timestamp TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    actor_id TEXT,
    correlation_id TEXT,
    causation_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_sequence ON events(sequence);
CREATE INDEX IF NOT EXISTS idx_events_entity ON events(entity_id, entity_type);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_correlation ON events(correlation_id);
CREATE INDEX IF NOT EXISTS idx_events_actor ON events(actor_id);

-- Threads table (current state projection)
CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    state TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    temperature REAL NOT NULL DEFAULT 0.5,
    claimed_by TEXT,
    parent_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 0,
    metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_threads_state ON threads(state);
CREATE INDEX IF NOT EXISTS idx_threads_claimed ON threads(claimed_by);
CREATE INDEX IF NOT EXISTS idx_threads_temperature ON threads(temperature DESC);

-- Agents table
CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,
    agent_type TEXT NOT NULL,
    status TEXT NOT NULL,
    current_thread TEXT,
    auth_token TEXT,
    registered_at TEXT NOT NULL,
    last_active_at TEXT NOT NULL,
    threads_completed INTEGER NOT NULL DEFAULT 0,
    metadata TEXT,
    FOREIGN KEY (current_thread) REFERENCES threads(id)
);

CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
CREATE INDEX IF NOT EXISTS idx_agents_type ON agents(agent_type);
CREATE INDEX IF NOT EXISTS idx_agents_token ON agents(auth_token);

-- Messages table
CREATE TABLE IF NOT EXISTS messages (
    message_id TEXT PRIMARY KEY,
    from_address TEXT NOT NULL,
    to_addresses TEXT NOT NULL,
    cc_addresses TEXT,
    subject TEXT NOT NULL,
    date TEXT NOT NULL,
    in_reply_to TEXT,
    "references" TEXT,
    thread_id TEXT,
    temperature REAL,
    priority TEXT,
    body_text TEXT NOT NULL,
    body_html TEXT,
    attachments TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(date);
CREATE INDEX IF NOT EXISTS idx_messages_from ON messages(from_address);
CREATE INDEX IF NOT EXISTS idx_messages_reply ON messages(in_reply_to);

-- Escalations table
CREATE TABLE IF NOT EXISTS escalations (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    priority INTEGER NOT NULL,
    status TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    thread_id TEXT,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    acknowledged_at TEXT,
    acknowledged_by TEXT,
    resolved_at TEXT,
    resolved_by TEXT,
    resolution TEXT,
    options TEXT,
    selected_option INTEGER,
    FOREIGN KEY (thread_id) REFERENCES threads(id)
);

CREATE INDEX IF NOT EXISTS idx_escalations_status ON escalations(status);
CREATE INDEX IF NOT EXISTS idx_escalations_priority ON escalations(priority DESC);
CREATE INDEX IF NOT EXISTS idx_escalations_thread ON escalations(thread_id);
CREATE INDEX IF NOT EXISTS idx_escalations_created ON escalations(created_at);

-- Artifacts table
CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    artifact_type TEXT NOT NULL,
    path TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    metadata TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id)
);

CREATE INDEX IF NOT EXISTS idx_artifacts_thread ON artifacts(thread_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_type ON artifacts(artifact_type);

-- Snapshots table (for periodic state snapshots)
CREATE TABLE IF NOT EXISTS snapshots (
    id TEXT PRIMARY KEY,
    sequence INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    state_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_snapshots_sequence ON snapshots(sequence);

-- System state table
CREATE TABLE IF NOT EXISTS system_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
"#
    }

    /// Get migration SQL for a specific version
    pub fn migration(from_version: u32, to_version: u32) -> Option<&'static str> {
        match (from_version, to_version) {
            // Add migrations here as the schema evolves
            // (0, 1) => Some("ALTER TABLE ..."),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_schema_sql_valid() {
        // Just verify the SQL is valid by checking it's not empty
        let sql = Schema::create_tables();
        assert!(!sql.is_empty());
        assert!(sql.contains("CREATE TABLE"));
    }
}
