//! Event store for persisting events

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

use super::types::{EntityType, Event, EventId};
use crate::error::{EventError, Result};

/// Trait for event storage backends
pub trait EventStore: Send + Sync {
    /// Append an event to the store
    fn append(&mut self, event: Event) -> Result<Event>;

    /// Get an event by ID
    fn get(&self, id: &EventId) -> Option<&Event>;

    /// Get all events for an entity
    fn events_for_entity(&self, entity_id: &str, entity_type: EntityType) -> Vec<&Event>;

    /// Get all events after a sequence number
    fn events_after(&self, sequence: u64) -> Vec<&Event>;

    /// Get the current sequence number
    fn current_sequence(&self) -> u64;

    /// Get all events in order
    fn all_events(&self) -> Vec<&Event>;

    /// Get events by correlation ID
    fn events_by_correlation(&self, correlation_id: &str) -> Vec<&Event>;
}

/// In-memory event store implementation
#[derive(Debug, Default)]
pub struct InMemoryEventStore {
    events: Vec<Event>,
    index_by_id: HashMap<EventId, usize>,
    index_by_entity: HashMap<(String, EntityType), Vec<usize>>,
    index_by_correlation: HashMap<String, Vec<usize>>,
    sequence: AtomicU64,
}

impl InMemoryEventStore {
    /// Create a new in-memory event store
    pub fn new() -> Self {
        Self {
            events: Vec::new(),
            index_by_id: HashMap::new(),
            index_by_entity: HashMap::new(),
            index_by_correlation: HashMap::new(),
            sequence: AtomicU64::new(0),
        }
    }

    /// Get the number of events in the store
    pub fn len(&self) -> usize {
        self.events.len()
    }

    /// Check if the store is empty
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}

impl EventStore for InMemoryEventStore {
    fn append(&mut self, mut event: Event) -> Result<Event> {
        // Assign sequence number
        let seq = self.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        event.sequence = seq;

        let idx = self.events.len();

        // Update indices
        self.index_by_id.insert(event.id, idx);
        self.index_by_entity
            .entry((event.entity_id.clone(), event.entity_type))
            .or_default()
            .push(idx);

        if let Some(ref correlation_id) = event.correlation_id {
            self.index_by_correlation
                .entry(correlation_id.clone())
                .or_default()
                .push(idx);
        }

        self.events.push(event.clone());
        Ok(event)
    }

    fn get(&self, id: &EventId) -> Option<&Event> {
        self.index_by_id
            .get(id)
            .and_then(|&idx| self.events.get(idx))
    }

    fn events_for_entity(&self, entity_id: &str, entity_type: EntityType) -> Vec<&Event> {
        self.index_by_entity
            .get(&(entity_id.to_string(), entity_type))
            .map(|indices| {
                indices
                    .iter()
                    .filter_map(|&idx| self.events.get(idx))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn events_after(&self, sequence: u64) -> Vec<&Event> {
        self.events
            .iter()
            .filter(|e| e.sequence > sequence)
            .collect()
    }

    fn current_sequence(&self) -> u64 {
        self.sequence.load(Ordering::SeqCst)
    }

    fn all_events(&self) -> Vec<&Event> {
        self.events.iter().collect()
    }

    fn events_by_correlation(&self, correlation_id: &str) -> Vec<&Event> {
        self.index_by_correlation
            .get(correlation_id)
            .map(|indices| {
                indices
                    .iter()
                    .filter_map(|&idx| self.events.get(idx))
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// SQLite-backed event store (requires "sqlite" feature)
#[cfg(feature = "sqlite")]
pub struct SqliteEventStore {
    conn: rusqlite::Connection,
    sequence: AtomicU64,
}

#[cfg(feature = "sqlite")]
impl SqliteEventStore {
    /// Create a new SQLite event store
    pub fn new(path: &str) -> Result<Self> {
        let conn = rusqlite::Connection::open(path)?;
        Self::initialize_schema(&conn)?;

        // Get current sequence
        let sequence: u64 = conn
            .query_row("SELECT COALESCE(MAX(sequence), 0) FROM events", [], |row| {
                row.get(0)
            })
            .unwrap_or(0);

        Ok(Self {
            conn,
            sequence: AtomicU64::new(sequence),
        })
    }

    /// Create an in-memory SQLite event store
    pub fn in_memory() -> Result<Self> {
        Self::new(":memory:")
    }

    fn initialize_schema(conn: &rusqlite::Connection) -> Result<()> {
        conn.execute_batch(
            r#"
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

            CREATE INDEX IF NOT EXISTS idx_events_entity ON events(entity_id, entity_type);
            CREATE INDEX IF NOT EXISTS idx_events_sequence ON events(sequence);
            CREATE INDEX IF NOT EXISTS idx_events_correlation ON events(correlation_id);
            "#,
        )?;
        Ok(())
    }

    /// Append an event to the SQLite store
    pub fn append(&mut self, mut event: Event) -> Result<Event> {
        let seq = self.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        event.sequence = seq;

        let payload_json = serde_json::to_string(&event.payload)?;

        self.conn.execute(
            r#"
            INSERT INTO events (id, sequence, timestamp, entity_id, entity_type, payload, actor_id, correlation_id, causation_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            rusqlite::params![
                event.id.value.to_string(),
                event.sequence,
                event.timestamp.to_rfc3339(),
                event.entity_id,
                event.entity_type.to_string(),
                payload_json,
                event.actor_id,
                event.correlation_id,
                event.causation_id.map(|id| id.value.to_string()),
            ],
        )?;

        Ok(event)
    }

    /// Get all events for an entity from SQLite
    pub fn events_for_entity(
        &self,
        entity_id: &str,
        entity_type: EntityType,
    ) -> Result<Vec<Event>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, sequence, timestamp, entity_id, entity_type, payload, actor_id, correlation_id, causation_id
            FROM events
            WHERE entity_id = ?1 AND entity_type = ?2
            ORDER BY sequence
            "#,
        )?;

        let events = stmt
            .query_map(
                rusqlite::params![entity_id, entity_type.to_string()],
                Self::row_to_event,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(events)
    }

    /// Get all events after a sequence number from SQLite
    pub fn events_after(&self, sequence: u64) -> Result<Vec<Event>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, sequence, timestamp, entity_id, entity_type, payload, actor_id, correlation_id, causation_id
            FROM events
            WHERE sequence > ?1
            ORDER BY sequence
            "#,
        )?;

        let events = stmt
            .query_map([sequence], Self::row_to_event)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(events)
    }

    fn row_to_event(row: &rusqlite::Row) -> rusqlite::Result<Event> {
        use chrono::DateTime;
        use uuid::Uuid;

        let id_str: String = row.get(0)?;
        let sequence: u64 = row.get(1)?;
        let timestamp_str: String = row.get(2)?;
        let entity_id: String = row.get(3)?;
        let entity_type_str: String = row.get(4)?;
        let payload_json: String = row.get(5)?;
        let actor_id: Option<String> = row.get(6)?;
        let correlation_id: Option<String> = row.get(7)?;
        let causation_id_str: Option<String> = row.get(8)?;

        let entity_type = match entity_type_str.as_str() {
            "thread" => EntityType::Thread,
            "agent" => EntityType::Agent,
            "message" => EntityType::Message,
            "escalation" => EntityType::Escalation,
            "artifact" => EntityType::Artifact,
            _ => EntityType::System,
        };

        Ok(Event {
            id: EventId {
                value: Uuid::parse_str(&id_str).unwrap(),
            },
            sequence,
            timestamp: DateTime::parse_from_rfc3339(&timestamp_str)
                .unwrap()
                .with_timezone(&chrono::Utc),
            entity_id,
            entity_type,
            payload: serde_json::from_str(&payload_json).unwrap(),
            actor_id,
            correlation_id,
            causation_id: causation_id_str.map(|s| EventId {
                value: Uuid::parse_str(&s).unwrap(),
            }),
        })
    }

    /// Get the current sequence number
    pub fn current_sequence(&self) -> u64 {
        self.sequence.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::types::EventPayload;

    #[test]
    fn test_in_memory_append() {
        let mut store = InMemoryEventStore::new();
        let event = Event::new(
            "thread-1".to_string(),
            EntityType::Thread,
            EventPayload::ThreadCreated {
                title: "Test".to_string(),
                description: "Test".to_string(),
                parent_id: None,
            },
        );

        let stored = store.append(event).unwrap();
        assert_eq!(stored.sequence, 1);
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn test_in_memory_query() {
        let mut store = InMemoryEventStore::new();

        // Add events for different entities
        store
            .append(Event::new(
                "thread-1".to_string(),
                EntityType::Thread,
                EventPayload::ThreadCreated {
                    title: "Thread 1".to_string(),
                    description: "".to_string(),
                    parent_id: None,
                },
            ))
            .unwrap();

        store
            .append(Event::new(
                "thread-2".to_string(),
                EntityType::Thread,
                EventPayload::ThreadCreated {
                    title: "Thread 2".to_string(),
                    description: "".to_string(),
                    parent_id: None,
                },
            ))
            .unwrap();

        let events = store.events_for_entity("thread-1", EntityType::Thread);
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn test_sequence_numbers() {
        let mut store = InMemoryEventStore::new();

        for i in 0..5 {
            let event = Event::new(
                format!("thread-{}", i),
                EntityType::Thread,
                EventPayload::ThreadCreated {
                    title: format!("Thread {}", i),
                    description: "".to_string(),
                    parent_id: None,
                },
            );
            let stored = store.append(event).unwrap();
            assert_eq!(stored.sequence, (i + 1) as u64);
        }

        let after_3 = store.events_after(3);
        assert_eq!(after_3.len(), 2); // Events 4 and 5
    }
}
