//! SQLite-backed append-only event store for provenance events.
//!
//! The store provides durable, ordered storage of provenance events with
//! efficient querying by conversation, entity, and time range.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use chrono::{DateTime, Utc};

use super::types::{ProvenanceEntityType, ProvenanceEvent, ProvenanceEventId, ProvenancePayload};
use crate::{ImpartError, Result};

// MARK: - Event Store Trait

/// Trait for provenance event storage backends.
pub trait EventStoreTrait: Send {
    /// Append an event to the store, returning the event with assigned sequence number.
    fn append(&mut self, event: ProvenanceEvent) -> Result<ProvenanceEvent>;

    /// Get an event by ID.
    fn get(&self, id: &ProvenanceEventId) -> Result<Option<ProvenanceEvent>>;

    /// Get all events for a conversation.
    fn events_for_conversation(&self, conversation_id: &str) -> Result<Vec<ProvenanceEvent>>;

    /// Get all events after a sequence number.
    fn events_after(&self, sequence: u64) -> Result<Vec<ProvenanceEvent>>;

    /// Get the current sequence number.
    fn current_sequence(&self) -> u64;

    /// Get all events in order.
    fn all_events(&self) -> Result<Vec<ProvenanceEvent>>;

    /// Get events by correlation ID.
    fn events_by_correlation(&self, correlation_id: &str) -> Result<Vec<ProvenanceEvent>>;

    /// Get events affecting a specific entity type.
    fn events_by_entity_type(&self, entity_type: ProvenanceEntityType)
        -> Result<Vec<ProvenanceEvent>>;
}

// MARK: - In-Memory Event Store

/// In-memory event store for testing and development.
#[derive(Debug, Default)]
pub struct InMemoryEventStore {
    events: Vec<ProvenanceEvent>,
    sequence: AtomicU64,
}

impl InMemoryEventStore {
    /// Create a new in-memory event store.
    pub fn new() -> Self {
        Self {
            events: Vec::new(),
            sequence: AtomicU64::new(0),
        }
    }

    /// Get the number of events in the store.
    pub fn len(&self) -> usize {
        self.events.len()
    }

    /// Check if the store is empty.
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}

impl EventStoreTrait for InMemoryEventStore {
    fn append(&mut self, mut event: ProvenanceEvent) -> Result<ProvenanceEvent> {
        let seq = self.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        event.sequence = seq;
        self.events.push(event.clone());
        Ok(event)
    }

    fn get(&self, id: &ProvenanceEventId) -> Result<Option<ProvenanceEvent>> {
        Ok(self.events.iter().find(|e| e.id == *id).cloned())
    }

    fn events_for_conversation(&self, conversation_id: &str) -> Result<Vec<ProvenanceEvent>> {
        Ok(self
            .events
            .iter()
            .filter(|e| e.conversation_id == conversation_id)
            .cloned()
            .collect())
    }

    fn events_after(&self, sequence: u64) -> Result<Vec<ProvenanceEvent>> {
        Ok(self
            .events
            .iter()
            .filter(|e| e.sequence > sequence)
            .cloned()
            .collect())
    }

    fn current_sequence(&self) -> u64 {
        self.sequence.load(Ordering::SeqCst)
    }

    fn all_events(&self) -> Result<Vec<ProvenanceEvent>> {
        Ok(self.events.clone())
    }

    fn events_by_correlation(&self, correlation_id: &str) -> Result<Vec<ProvenanceEvent>> {
        Ok(self
            .events
            .iter()
            .filter(|e| e.correlation_id.as_deref() == Some(correlation_id))
            .cloned()
            .collect())
    }

    fn events_by_entity_type(
        &self,
        entity_type: ProvenanceEntityType,
    ) -> Result<Vec<ProvenanceEvent>> {
        Ok(self
            .events
            .iter()
            .filter(|e| e.payload.entity_type() == entity_type)
            .cloned()
            .collect())
    }
}

// MARK: - SQLite Event Store

/// SQLite-backed event store for durable provenance storage.
pub struct SqliteEventStore {
    conn: rusqlite::Connection,
    sequence: AtomicU64,
}

impl SqliteEventStore {
    /// Create a new SQLite event store at the given path.
    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = rusqlite::Connection::open(path)
            .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?;

        Self::initialize_schema(&conn)?;

        // Get current sequence
        let sequence: u64 = conn
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM provenance_events",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);

        Ok(Self {
            conn,
            sequence: AtomicU64::new(sequence),
        })
    }

    /// Create an in-memory SQLite event store (useful for testing).
    pub fn in_memory() -> Result<Self> {
        let conn = rusqlite::Connection::open_in_memory()
            .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?;

        Self::initialize_schema(&conn)?;

        Ok(Self {
            conn,
            sequence: AtomicU64::new(0),
        })
    }

    /// Initialize the database schema.
    fn initialize_schema(conn: &rusqlite::Connection) -> Result<()> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS provenance_events (
                id TEXT PRIMARY KEY,
                sequence INTEGER NOT NULL UNIQUE,
                timestamp TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                payload TEXT NOT NULL,
                actor_id TEXT NOT NULL,
                correlation_id TEXT,
                causation_id TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_provenance_conversation
                ON provenance_events(conversation_id);
            CREATE INDEX IF NOT EXISTS idx_provenance_sequence
                ON provenance_events(sequence);
            CREATE INDEX IF NOT EXISTS idx_provenance_correlation
                ON provenance_events(correlation_id);
            CREATE INDEX IF NOT EXISTS idx_provenance_entity_type
                ON provenance_events(entity_type);
            CREATE INDEX IF NOT EXISTS idx_provenance_actor
                ON provenance_events(actor_id);
            CREATE INDEX IF NOT EXISTS idx_provenance_timestamp
                ON provenance_events(timestamp);
            "#,
        )
        .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?;

        Ok(())
    }

    /// Parse an event from a database row.
    fn row_to_event(row: &rusqlite::Row) -> rusqlite::Result<ProvenanceEvent> {
        let id_str: String = row.get(0)?;
        let sequence: u64 = row.get(1)?;
        let timestamp_str: String = row.get(2)?;
        let conversation_id: String = row.get(3)?;
        let _entity_type_str: String = row.get(4)?;
        let payload_json: String = row.get(5)?;
        let actor_id: String = row.get(6)?;
        let correlation_id: Option<String> = row.get(7)?;
        let causation_id_str: Option<String> = row.get(8)?;

        let id = ProvenanceEventId::parse(&id_str).unwrap_or_default();
        let timestamp = DateTime::parse_from_rfc3339(&timestamp_str)
            .map(|dt| dt.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now());
        let payload: ProvenancePayload =
            serde_json::from_str(&payload_json).unwrap_or(ProvenancePayload::SystemResumed);
        let causation_id = causation_id_str.and_then(|s| ProvenanceEventId::parse(&s));

        Ok(ProvenanceEvent {
            id,
            sequence,
            timestamp,
            conversation_id,
            payload,
            actor_id,
            correlation_id,
            causation_id,
        })
    }

    /// Query events with a custom WHERE clause.
    fn query_events(&self, where_clause: &str, params: &[&dyn rusqlite::ToSql]) -> Result<Vec<ProvenanceEvent>> {
        let sql = format!(
            r#"
            SELECT id, sequence, timestamp, conversation_id, entity_type, payload, actor_id, correlation_id, causation_id
            FROM provenance_events
            WHERE {}
            ORDER BY sequence
            "#,
            where_clause
        );

        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?;

        let events = stmt
            .query_map(params, Self::row_to_event)
            .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?
            .filter_map(|r| r.ok())
            .collect();

        Ok(events)
    }
}

impl EventStoreTrait for SqliteEventStore {
    fn append(&mut self, mut event: ProvenanceEvent) -> Result<ProvenanceEvent> {
        let seq = self.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        event.sequence = seq;

        let payload_json = serde_json::to_string(&event.payload)
            .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?;

        self.conn
            .execute(
                r#"
                INSERT INTO provenance_events
                    (id, sequence, timestamp, conversation_id, entity_type, payload, actor_id, correlation_id, causation_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                "#,
                rusqlite::params![
                    event.id.to_string(),
                    event.sequence,
                    event.timestamp.to_rfc3339(),
                    event.conversation_id,
                    event.payload.entity_type().to_string(),
                    payload_json,
                    event.actor_id,
                    event.correlation_id,
                    event.causation_id.map(|id| id.to_string()),
                ],
            )
            .map_err(|e| ImpartError::Io(std::io::Error::other(e.to_string())))?;

        Ok(event)
    }

    fn get(&self, id: &ProvenanceEventId) -> Result<Option<ProvenanceEvent>> {
        let events = self.query_events("id = ?1", &[&id.to_string()])?;
        Ok(events.into_iter().next())
    }

    fn events_for_conversation(&self, conversation_id: &str) -> Result<Vec<ProvenanceEvent>> {
        self.query_events("conversation_id = ?1", &[&conversation_id])
    }

    fn events_after(&self, sequence: u64) -> Result<Vec<ProvenanceEvent>> {
        self.query_events("sequence > ?1", &[&(sequence as i64)])
    }

    fn current_sequence(&self) -> u64 {
        self.sequence.load(Ordering::SeqCst)
    }

    fn all_events(&self) -> Result<Vec<ProvenanceEvent>> {
        self.query_events("1=1", &[])
    }

    fn events_by_correlation(&self, correlation_id: &str) -> Result<Vec<ProvenanceEvent>> {
        self.query_events("correlation_id = ?1", &[&correlation_id])
    }

    fn events_by_entity_type(
        &self,
        entity_type: ProvenanceEntityType,
    ) -> Result<Vec<ProvenanceEvent>> {
        self.query_events("entity_type = ?1", &[&entity_type.to_string()])
    }
}

// MARK: - Event Store (Wrapper)

/// Event store that can use either in-memory or SQLite backend.
pub enum EventStore {
    /// In-memory store for testing.
    InMemory(InMemoryEventStore),
    /// SQLite store for production.
    Sqlite(SqliteEventStore),
}

impl EventStore {
    /// Create a new in-memory event store.
    pub fn in_memory() -> Self {
        EventStore::InMemory(InMemoryEventStore::new())
    }

    /// Create a new SQLite event store.
    pub fn sqlite<P: AsRef<Path>>(path: P) -> Result<Self> {
        Ok(EventStore::Sqlite(SqliteEventStore::new(path)?))
    }

    /// Create a new in-memory SQLite store (for testing with SQL features).
    pub fn sqlite_in_memory() -> Result<Self> {
        Ok(EventStore::Sqlite(SqliteEventStore::in_memory()?))
    }

    /// Append an event.
    pub fn append(&mut self, event: ProvenanceEvent) -> Result<ProvenanceEvent> {
        match self {
            EventStore::InMemory(store) => store.append(event),
            EventStore::Sqlite(store) => store.append(event),
        }
    }

    /// Get an event by ID.
    pub fn get(&self, id: &ProvenanceEventId) -> Result<Option<ProvenanceEvent>> {
        match self {
            EventStore::InMemory(store) => store.get(id),
            EventStore::Sqlite(store) => store.get(id),
        }
    }

    /// Get events for a conversation.
    pub fn events_for_conversation(&self, conversation_id: &str) -> Result<Vec<ProvenanceEvent>> {
        match self {
            EventStore::InMemory(store) => store.events_for_conversation(conversation_id),
            EventStore::Sqlite(store) => store.events_for_conversation(conversation_id),
        }
    }

    /// Get events after a sequence number.
    pub fn events_after(&self, sequence: u64) -> Result<Vec<ProvenanceEvent>> {
        match self {
            EventStore::InMemory(store) => store.events_after(sequence),
            EventStore::Sqlite(store) => store.events_after(sequence),
        }
    }

    /// Get the current sequence number.
    pub fn current_sequence(&self) -> u64 {
        match self {
            EventStore::InMemory(store) => store.current_sequence(),
            EventStore::Sqlite(store) => store.current_sequence(),
        }
    }

    /// Get all events.
    pub fn all_events(&self) -> Result<Vec<ProvenanceEvent>> {
        match self {
            EventStore::InMemory(store) => store.all_events(),
            EventStore::Sqlite(store) => store.all_events(),
        }
    }

    /// Get events by correlation ID.
    pub fn events_by_correlation(&self, correlation_id: &str) -> Result<Vec<ProvenanceEvent>> {
        match self {
            EventStore::InMemory(store) => store.events_by_correlation(correlation_id),
            EventStore::Sqlite(store) => store.events_by_correlation(correlation_id),
        }
    }

    /// Get events by entity type.
    pub fn events_by_entity_type(
        &self,
        entity_type: ProvenanceEntityType,
    ) -> Result<Vec<ProvenanceEvent>> {
        match self {
            EventStore::InMemory(store) => store.events_by_entity_type(entity_type),
            EventStore::Sqlite(store) => store.events_by_entity_type(entity_type),
        }
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_event(conversation_id: &str) -> ProvenanceEvent {
        ProvenanceEvent::new(
            conversation_id.to_string(),
            ProvenancePayload::ConversationCreated {
                title: "Test".to_string(),
                participants: vec!["user@example.com".to_string()],
            },
            "user@example.com".to_string(),
        )
    }

    #[test]
    fn test_in_memory_append() {
        let mut store = InMemoryEventStore::new();
        let event = create_test_event("conv-1");

        let stored = store.append(event).unwrap();
        assert_eq!(stored.sequence, 1);
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn test_in_memory_query_by_conversation() {
        let mut store = InMemoryEventStore::new();

        store.append(create_test_event("conv-1")).unwrap();
        store.append(create_test_event("conv-2")).unwrap();
        store.append(create_test_event("conv-1")).unwrap();

        let events = store.events_for_conversation("conv-1").unwrap();
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn test_in_memory_events_after() {
        let mut store = InMemoryEventStore::new();

        for i in 0..5 {
            store
                .append(create_test_event(&format!("conv-{}", i)))
                .unwrap();
        }

        let after_3 = store.events_after(3).unwrap();
        assert_eq!(after_3.len(), 2); // Events 4 and 5
    }

    #[test]
    fn test_sqlite_append() {
        let mut store = SqliteEventStore::in_memory().unwrap();
        let event = create_test_event("conv-1");

        let stored = store.append(event).unwrap();
        assert_eq!(stored.sequence, 1);
    }

    #[test]
    fn test_sqlite_query() {
        let mut store = SqliteEventStore::in_memory().unwrap();

        store.append(create_test_event("conv-1")).unwrap();
        store.append(create_test_event("conv-2")).unwrap();
        store.append(create_test_event("conv-1")).unwrap();

        let events = store.events_for_conversation("conv-1").unwrap();
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn test_event_store_wrapper() {
        let mut store = EventStore::in_memory();

        let event = create_test_event("conv-1");
        let stored = store.append(event).unwrap();

        let retrieved = store.get(&stored.id).unwrap();
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().id, stored.id);
    }
}
